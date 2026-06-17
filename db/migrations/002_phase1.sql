-- SAL Phase 1 (Sales Coach MVP) — L9 engagement (sessions, interactions, objections, outcomes)
-- + a grounded-FAQ knowledge store (Postgres full-text search; Milvus replaces/augments this later).
-- Write tables use FOR ALL RLS (USING + WITH CHECK) so the app role can insert within its tenant.

-- ── L9 · Engagement ──────────────────────────────────────────────────────
CREATE TABLE cic.sal_session (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES cic.tenants(id),
    customer_id     UUID REFERENCES cic.customers(id),
    staff_user_ref  VARCHAR(64),
    owner_agent_code VARCHAR(64),
    channel_code    VARCHAR(32) NOT NULL DEFAULT 'retail',
    intent          VARCHAR(64),
    status          VARCHAR(32) NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','completed','abandoned','handed_off')),
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at        TIMESTAMPTZ,
    meta            JSONB NOT NULL DEFAULT '{}'
);
CREATE INDEX ix_session_customer ON cic.sal_session(tenant_id, customer_id, started_at DESC);

CREATE TABLE cic.interaction_event (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL REFERENCES cic.tenants(id),
    customer_id  UUID NOT NULL REFERENCES cic.customers(id) ON DELETE CASCADE,
    channel_code VARCHAR(32) NOT NULL,
    type         VARCHAR(64),
    subject      VARCHAR(512),
    sentiment    NUMERIC(4,3),
    resolved     BOOLEAN,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_int_customer_time ON cic.interaction_event(tenant_id, customer_id, occurred_at DESC);

CREATE TABLE cic.objection (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      UUID NOT NULL REFERENCES cic.tenants(id),
    session_id     UUID REFERENCES cic.sal_session(id) ON DELETE CASCADE,
    customer_id    UUID,
    objection_code VARCHAR(64),
    detail         TEXT,
    captured_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE cic.outcome_feedback (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL REFERENCES cic.tenants(id),
    session_id   UUID REFERENCES cic.sal_session(id) ON DELETE CASCADE,
    customer_id  UUID,
    rec_id       UUID,                       -- populated from Phase 2a (recommendations)
    outcome      VARCHAR(16) NOT NULL CHECK (outcome IN ('accepted','rejected','deferred','overridden','ineligible')),
    reason_code  VARCHAR(64),
    boid_tagged  TEXT[],
    captured_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Grounded FAQ knowledge (Postgres FTS; Milvus added later) ─────────────
CREATE TABLE cic.knowledge_doc (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  UUID NOT NULL REFERENCES cic.tenants(id),
    title      VARCHAR(255) NOT NULL,
    body       TEXT NOT NULL,
    category   VARCHAR(64),
    source     VARCHAR(128),
    ts         TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', coalesce(title,'') || ' ' || coalesce(body,''))) STORED,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_kdoc_fts ON cic.knowledge_doc USING GIN (ts);

-- ── RLS ───────────────────────────────────────────────────────────────────
ALTER TABLE cic.sal_session       ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.interaction_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.objection         ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.outcome_feedback  ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.knowledge_doc     ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_session_all ON cic.sal_session FOR ALL
  USING (tenant_id = current_setting('app.current_tenant', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_int_all ON cic.interaction_event FOR ALL
  USING (tenant_id = current_setting('app.current_tenant', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_obj_all ON cic.objection FOR ALL
  USING (tenant_id = current_setting('app.current_tenant', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_out_all ON cic.outcome_feedback FOR ALL
  USING (tenant_id = current_setting('app.current_tenant', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_kdoc_read ON cic.knowledge_doc FOR SELECT
  USING (tenant_id = current_setting('app.current_tenant', true)::uuid);

-- ── Grants ─────────────────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA cic TO sal_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA cic TO sal_app;

-- ── Phase 1 agents + tool bindings ──────────────────────────────────────────
INSERT INTO cic.agents (tenant_id, code, display_name, version, runtime) VALUES
  (NULL,'sales_coach','Sales Coach','1.0.0','agentic_layer_python'),
  (NULL,'faq_knowledge','FAQ & Knowledge','1.0.0','agentic_layer_python'),
  (NULL,'consent_checker','Consent Checker','1.0.0','agentic_layer_python')
ON CONFLICT DO NOTHING;

INSERT INTO cic.agent_mcp_tool_bindings (agent_code, mcp_tool, access, purpose_scope) VALUES
  ('sales_coach','mcp_assemble_context','read','{personalisation}'),
  ('sales_coach','mcp_get_interactions','read','{personalisation}'),
  ('sales_coach','mcp_capture_objection','write','{personalisation}'),
  ('faq_knowledge','mcp_knowledge_search','read','{personalisation}'),
  ('faq_knowledge','mcp_get_customer_360','read','{personalisation}'),
  ('context_assembler','mcp_get_interactions','read','{personalisation}'),
  ('context_assembler','mcp_open_session','write','{personalisation}'),
  ('context_assembler','mcp_record_outcome','write','{personalisation}')
ON CONFLICT DO NOTHING;
