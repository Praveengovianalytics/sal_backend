-- SAL Phase 2a (Recommender & bundling) — L7 offers, L8 decisioning (Ascend) + MC360 feature store,
-- L9 recommendations. Locally we SEED the Ascend/MC360 feeds; in cloud they arrive via Kafka/Databricks.

-- ── L7 · Offers & strategy ──────────────────────────────────────────────
CREATE TABLE cic.offer_catalogue (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES cic.tenants(id),
    offer_id            VARCHAR(64) NOT NULL,
    title               VARCHAR(512) NOT NULL,
    family_code         VARCHAR(64),
    service_type_code   VARCHAR(64),
    scenario_code       VARCHAR(32),                 -- recon/ga/circle3/sweetch/addon/salvage
    price               NUMERIC(18,2),
    usual_price         NUMERIC(18,2),
    discount_pct        NUMERIC(6,4),
    status_code         VARCHAR(16) NOT NULL CHECK (status_code IN ('active','upcoming','expired')),
    valid_from          DATE,
    valid_to            DATE,
    boid                TEXT[],
    eligibility_rule_id VARCHAR(64),
    dq_flags            TEXT[],
    source_system       VARCHAR(64) NOT NULL DEFAULT 'ascend',
    as_of               TIMESTAMPTZ,
    meta                JSONB NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_offer UNIQUE (tenant_id, offer_id)
);
CREATE INDEX ix_offer_active ON cic.offer_catalogue(tenant_id, scenario_code) WHERE status_code = 'active';

CREATE TABLE cic.voucher (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL REFERENCES cic.tenants(id),
    voucher_code VARCHAR(64) NOT NULL,
    customer_id UUID NOT NULL REFERENCES cic.customers(id) ON DELETE CASCADE,
    type        VARCHAR(64),
    value       NUMERIC(18,2),
    expiry      DATE,
    conditions  JSONB NOT NULL DEFAULT '{}',
    applicable  BOOLEAN,
    as_of       TIMESTAMPTZ,
    CONSTRAINT uq_voucher UNIQUE (tenant_id, voucher_code)
);
CREATE INDEX ix_voucher_customer ON cic.voucher(tenant_id, customer_id, expiry);

CREATE TABLE cic.competitor_price (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL REFERENCES cic.tenants(id),
    plan_ref     VARCHAR(64) NOT NULL,
    competitor   VARCHAR(64) NOT NULL,
    monthly_price NUMERIC(18,2),
    source_feed  VARCHAR(64),
    as_of        TIMESTAMPTZ
);

-- ── L8 · Decisioning inputs (from Ascend) ───────────────────────────────
CREATE TABLE cic.propensity_score (
    customer_id       UUID NOT NULL REFERENCES cic.customers(id) ON DELETE CASCADE,
    tenant_id         UUID NOT NULL,
    churn_risk        NUMERIC(6,5) CHECK (churn_risk BETWEEN 0 AND 1),
    accept_propensity NUMERIC(6,5) CHECK (accept_propensity BETWEEN 0 AND 1),
    attach_propensity NUMERIC(6,5) CHECK (attach_propensity BETWEEN 0 AND 1),
    uplift_segment    VARCHAR(32) CHECK (uplift_segment IN ('persuadable','loyalist','lost_cause','do_not_disturb')),
    model_version     VARCHAR(32) NOT NULL,
    scored_at         TIMESTAMPTZ NOT NULL,
    source_system     VARCHAR(64) NOT NULL DEFAULT 'ascend',
    PRIMARY KEY (customer_id, model_version)
);

CREATE TABLE cic.eligibility (
    customer_id  UUID NOT NULL REFERENCES cic.customers(id) ON DELETE CASCADE,
    tenant_id    UUID NOT NULL,
    scenario_code VARCHAR(32) NOT NULL,
    eligible     BOOLEAN NOT NULL,
    reason_codes TEXT[],
    valid_until  TIMESTAMPTZ,
    as_of        TIMESTAMPTZ,
    PRIMARY KEY (customer_id, scenario_code)
);

-- ── L8 · MC360 feature store (metadata + small cache; mart stays in Databricks) ──
CREATE TABLE cic.mc360_feature_catalog (
    feature_code    VARCHAR(160) PRIMARY KEY,
    grain           VARCHAR(8) NOT NULL,
    domain          VARCHAR(32),
    data_type       VARCHAR(24),
    unit            VARCHAR(16),
    is_pii          BOOLEAN NOT NULL DEFAULT FALSE,
    databricks_view VARCHAR(120)
);

-- Local stand-in for the Databricks MC360 mart (cloud: the ML-Agent reads Databricks, not this table).
CREATE TABLE cic.mc360_feature_store_local (
    entity_grain VARCHAR(8) NOT NULL,
    entity_ref   UUID NOT NULL,
    feature_code VARCHAR(160) NOT NULL,
    value        TEXT,
    period_key   VARCHAR(8),
    PRIMARY KEY (entity_grain, entity_ref, feature_code)
);

CREATE TABLE cic.mc360_feature_resolved (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     UUID NOT NULL,
    entity_grain  VARCHAR(8) NOT NULL,
    entity_ref    UUID NOT NULL,
    feature_code  VARCHAR(160) NOT NULL REFERENCES cic.mc360_feature_catalog(feature_code),
    value         TEXT,
    period_key    VARCHAR(8),
    resolved_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    ttl_expires_at TIMESTAMPTZ,
    resolved_by_agent VARCHAR(64) NOT NULL DEFAULT 'ml_agent',
    source_system VARCHAR(64) NOT NULL DEFAULT 'databricks_mc360',
    CONSTRAINT uq_resolved UNIQUE (tenant_id, entity_grain, entity_ref, feature_code, period_key)
);

-- ── L9 · Recommendations ────────────────────────────────────────────────
CREATE TABLE cic.recommendation (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL REFERENCES cic.tenants(id),
    session_id              UUID,
    customer_id             UUID NOT NULL,
    recommended_by_agent_code VARCHAR(64),
    top_pick_offer_id       VARCHAR(64),
    scores                  JSONB NOT NULL DEFAULT '{}',
    rationale               TEXT,
    shown_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_rec_customer ON cic.recommendation(tenant_id, customer_id, shown_at DESC);

CREATE TABLE cic.recommendation_candidate (
    recommendation_id UUID NOT NULL REFERENCES cic.recommendation(id) ON DELETE CASCADE,
    rank              INT NOT NULL,
    offer_id          VARCHAR(64),
    kind              VARCHAR(32),
    fit_score         NUMERIC(5,2),
    arpu_delta        NUMERIC(18,2),
    consumer_value    NUMERIC(5,2),
    commercial_value  NUMERIC(5,2),
    propensity        NUMERIC(5,2),
    guardrail_pass    BOOLEAN NOT NULL,
    competitor_delta  NUMERIC(18,2),
    PRIMARY KEY (recommendation_id, rank)
);

-- ── RLS + grants ────────────────────────────────────────────────────────
ALTER TABLE cic.offer_catalogue        ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.voucher                ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.competitor_price       ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.propensity_score       ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.eligibility            ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.mc360_feature_resolved ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.recommendation         ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_offer   ON cic.offer_catalogue  FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_vouch   ON cic.voucher          FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_comp    ON cic.competitor_price FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_prop    ON cic.propensity_score FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_elig    ON cic.eligibility      FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_mcres   ON cic.mc360_feature_resolved FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_rec     ON cic.recommendation   FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);

GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA cic TO sal_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA cic TO sal_app;

-- recommendation_candidate inherits access through its parent; grant explicit + no RLS (child of RLS'd rec).
-- mc360_feature_catalog and mc360_feature_store_local are reference/lakehouse-stub (no tenant) — readable.

-- ── Phase 2a agents + tool bindings ─────────────────────────────────────
INSERT INTO cic.agents (tenant_id, code, display_name, version, runtime) VALUES
  (NULL,'recommender','Sales Recommender','1.0.0','agentic_layer_python'),
  (NULL,'smart_bundler','Smart Bundler','1.0.0','agentic_layer_python'),
  (NULL,'eligibility_governor','Eligibility Governor','1.0.0','agentic_layer_python'),
  (NULL,'ml_agent','ML Feature Agent','1.0.0','agentic_layer_python'),
  (NULL,'feedback_writer','Feedback Writer','1.0.0','agentic_layer_python')
ON CONFLICT DO NOTHING;

INSERT INTO cic.agent_mcp_tool_bindings (agent_code, mcp_tool, access, purpose_scope) VALUES
  ('recommender','mcp_assemble_context','read','{personalisation}'),
  ('recommender','mcp_get_value_propensity','read','{personalisation}'),
  ('recommender','mcp_get_eligibility','read','{personalisation}'),
  ('recommender','mcp_get_vouchers','read','{personalisation}'),
  ('recommender','mcp_search_offers','read','{personalisation}'),
  ('recommender','mcp_get_competitor_price','read','{personalisation}'),
  ('recommender','mcp_log_recommendation','write','{personalisation}'),
  ('smart_bundler','mcp_assemble_context','read','{personalisation}'),
  ('smart_bundler','mcp_search_offers','read','{personalisation}'),
  ('smart_bundler','mcp_get_competitor_price','read','{personalisation}'),
  ('smart_bundler','mcp_log_recommendation','write','{personalisation}'),
  ('eligibility_governor','mcp_get_eligibility','read','{personalisation}'),
  ('ml_agent','mcp_resolve_features','read','{personalisation}'),
  ('ml_agent','mcp_get_value_propensity','read','{personalisation}'),
  ('feedback_writer','mcp_record_outcome','write','{personalisation}'),
  ('recommender','mcp_get_customer_360','read','{personalisation}')
ON CONFLICT DO NOTHING;
