-- SAL Customer Intelligence Cube — Phase 0 schema (subset of L1–L11)
-- Layers built here: L1 tenancy, L2 identity crosswalk, L3 consent, L4 agents+audit, L6 customer core, L8 value.
-- Conventions: schema `cic`; UUID PKs; provenance + universal columns; tenant RLS; consent at read.
-- Run as superuser `sal`; the app connects as non-superuser `sal_app` so RLS is enforced.

CREATE SCHEMA IF NOT EXISTS cic;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Application role (RLS applies to it; it is NOT the table owner and NOT a superuser)
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'sal_app') THEN
    CREATE ROLE sal_app LOGIN PASSWORD 'sal_app';
  END IF;
END $$;
GRANT USAGE ON SCHEMA cic TO sal_app;

CREATE OR REPLACE FUNCTION cic.tg_set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$ LANGUAGE plpgsql;

-- ───────────────────────────── L1 · Tenancy & taxonomy ─────────────────────────────
CREATE TABLE cic.tenants (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code          VARCHAR(64) NOT NULL UNIQUE,
    display_name  VARCHAR(255) NOT NULL,
    status        VARCHAR(16) NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended','archived')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE cic.customer_taxonomy (
    tenant_id     UUID,
    facet         VARCHAR(32) NOT NULL,
    code          VARCHAR(64) NOT NULL,
    label         VARCHAR(128) NOT NULL,
    display_order INT NOT NULL DEFAULT 0,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE
);
-- system rows have tenant_id NULL; a unique index (expressions allowed) enforces uniqueness incl. system rows
CREATE UNIQUE INDEX uq_taxonomy ON cic.customer_taxonomy
  (COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), facet, code);

-- ───────────────────────────── L2 · Source & identity crosswalk ─────────────────────
CREATE TABLE cic.source_systems (
    code         VARCHAR(64) PRIMARY KEY,
    display_name VARCHAR(128) NOT NULL,
    kind         VARCHAR(32) NOT NULL
);

CREATE TABLE cic.customers (
    id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                 UUID NOT NULL REFERENCES cic.tenants(id),
    mcp_party_uid             UUID NOT NULL,
    name_token                VARCHAR(128),
    age_band                  VARCHAR(16),
    gender                    VARCHAR(16),
    segment_code              VARCHAR(32),
    household_id              UUID,
    tenure_months             INT CHECK (tenure_months >= 0),
    loyalty_tier_code         VARCHAR(32),
    clv_band                  VARCHAR(16),
    value_segment             VARCHAR(32),
    lifecycle_code            VARCHAR(32),
    primary_language          VARCHAR(16),
    customer_type             VARCHAR(32),
    lob_description           VARCHAR(255),
    tenure_range              VARCHAR(32),
    lifecycle_value           VARCHAR(8),
    loyalty_prestige_status   VARCHAR(32),
    active_subscription_count INT NOT NULL DEFAULT 0,
    is_multiservice           BOOLEAN NOT NULL DEFAULT FALSE,
    circle3_eligible          BOOLEAN,
    last_interaction_at        TIMESTAMPTZ,
    source_system             VARCHAR(64) NOT NULL DEFAULT 'mcp',
    as_of                     TIMESTAMPTZ,
    sync_state                VARCHAR(16) NOT NULL DEFAULT 'in_sync',
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    meta                      JSONB NOT NULL DEFAULT '{}',
    CONSTRAINT uq_customers_party UNIQUE (tenant_id, mcp_party_uid)
);
CREATE INDEX ix_customers_lifecycle ON cic.customers(tenant_id, lifecycle_code);

CREATE TABLE cic.customer_identifiers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES cic.tenants(id),
    customer_id     UUID NOT NULL REFERENCES cic.customers(id) ON DELETE CASCADE,
    subscription_id UUID,
    id_type         VARCHAR(32) NOT NULL CHECK (id_type IN
                      ('mcp_party_uid','nric_token','service_no','service_no_hmac','ctct_id','msta_id','eshop_id','billing_account')),
    id_value        VARCHAR(255) NOT NULL,
    confidence      NUMERIC(4,3) NOT NULL DEFAULT 1.000,
    verified_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_xwalk UNIQUE (tenant_id, id_type, id_value)
);
CREATE INDEX ix_xwalk_customer ON cic.customer_identifiers(customer_id);

-- ───────────────────────────── L6 · Customer detail (MCP) ──────────────────────────
CREATE TABLE cic.households (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL REFERENCES cic.tenants(id),
    postal_token VARCHAR(32),
    size         INT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE cic.customer_address (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL REFERENCES cic.tenants(id),
    customer_id       UUID NOT NULL REFERENCES cic.customers(id) ON DELETE CASCADE,
    address_type      VARCHAR(15) NOT NULL,
    block_house_id    VARCHAR(255),
    street_name       VARCHAR(120),
    floor_unit        VARCHAR(60),
    building_name     VARCHAR(255),
    city              VARCHAR(60) DEFAULT 'Singapore',
    postal_code_token VARCHAR(32),
    country           VARCHAR(60) DEFAULT 'Singapore',
    developer_name    VARCHAR(255),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_addr UNIQUE (tenant_id, customer_id, address_type)
);

CREATE TABLE cic.customer_billing_profile (
    customer_id           UUID PRIMARY KEY REFERENCES cic.customers(id) ON DELETE CASCADE,
    tenant_id             UUID NOT NULL,
    credit_class          VARCHAR(60),
    credit_rating         VARCHAR(16),
    account_category      VARCHAR(60),
    billing_cycle         VARCHAR(32),
    blacklist_reason      VARCHAR(8),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE cic.customer_preference (
    customer_id              UUID PRIMARY KEY REFERENCES cic.customers(id) ON DELETE CASCADE,
    tenant_id                UUID NOT NULL,
    dn_bill_mailer_internal  BOOLEAN NOT NULL DEFAULT FALSE,
    dn_bill_mailer_external  BOOLEAN NOT NULL DEFAULT FALSE,
    dn_survey                BOOLEAN NOT NULL DEFAULT FALSE,
    dn_direct_mailer         BOOLEAN NOT NULL DEFAULT FALSE,
    dn_email_internal        BOOLEAN NOT NULL DEFAULT FALSE,
    dn_email_external        BOOLEAN NOT NULL DEFAULT FALSE,
    dn_banner_internal       BOOLEAN NOT NULL DEFAULT FALSE,
    dn_aggregate             BOOLEAN NOT NULL DEFAULT FALSE,
    dn_canvass               BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE cic.subscriptions (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                UUID NOT NULL REFERENCES cic.tenants(id),
    customer_id              UUID NOT NULL REFERENCES cic.customers(id) ON DELETE CASCADE,
    subscription_external_id VARCHAR(64) NOT NULL,
    service_type_code        VARCHAR(64) NOT NULL,
    plan_code                VARCHAR(64),
    plan_name                VARCHAR(255),
    is_legacy                BOOLEAN NOT NULL DEFAULT FALSE,
    status_code              VARCHAR(32) NOT NULL DEFAULT 'active' CHECK (status_code IN ('active','suspended','pending','terminated')),
    mrc                      NUMERIC(18,2),
    currency_code            CHAR(3) NOT NULL DEFAULT 'SGD',
    activated_at             TIMESTAMPTZ,
    source_system            VARCHAR(64) NOT NULL DEFAULT 'udp_lakehouse',
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_sub_ext UNIQUE (tenant_id, source_system, subscription_external_id)
);
CREATE INDEX ix_sub_customer ON cic.subscriptions(tenant_id, customer_id);
CREATE INDEX ix_sub_active   ON cic.subscriptions(tenant_id, service_type_code) WHERE status_code = 'active';

-- ───────────────────────────── L8 · Value (decisioning input) ──────────────────────
CREATE TABLE cic.value_metrics (
    customer_id UUID PRIMARY KEY REFERENCES cic.customers(id) ON DELETE CASCADE,
    tenant_id   UUID NOT NULL,
    arpu        NUMERIC(18,2),
    arpu_band   VARCHAR(16),
    clv         NUMERIC(18,2),
    margin_band VARCHAR(16),
    as_of       TIMESTAMPTZ,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ───────────────────────────── L3 · Consent (PDPA) ─────────────────────────────────
CREATE TABLE cic.consent (
    tenant_id     UUID NOT NULL,
    customer_id   UUID NOT NULL REFERENCES cic.customers(id) ON DELETE CASCADE,
    purpose       VARCHAR(64) NOT NULL,
    status        VARCHAR(16) NOT NULL CHECK (status IN ('opted_in','opted_out','pending','unknown','expired')),
    consent_basis VARCHAR(32),
    valid_from    TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_to      TIMESTAMPTZ,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id, purpose)
);

-- ───────────────────────────── L4 · Agent army + MCP audit ─────────────────────────
CREATE TABLE cic.agents (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID,
    code         VARCHAR(64) NOT NULL,
    display_name VARCHAR(255) NOT NULL,
    version      VARCHAR(32) NOT NULL,
    runtime      VARCHAR(32) NOT NULL,
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    config       JSONB NOT NULL DEFAULT '{}',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_agent UNIQUE (tenant_id, code, version)
);

CREATE TABLE cic.agent_mcp_tool_bindings (
    agent_code         VARCHAR(64) NOT NULL,
    mcp_tool           VARCHAR(64) NOT NULL,
    access             VARCHAR(8) NOT NULL CHECK (access IN ('read','write')),
    purpose_scope      TEXT[],
    rate_limit_per_min INT,
    PRIMARY KEY (agent_code, mcp_tool)
);

CREATE TABLE cic.agent_runs (        -- == mcp_access_log
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     UUID NOT NULL,
    agent_code    VARCHAR(64) NOT NULL,
    session_id    UUID,
    mcp_tool      VARCHAR(64) NOT NULL,
    customer_id   UUID,
    op            VARCHAR(8) NOT NULL CHECK (op IN ('read','write')),
    consent_ok    BOOLEAN,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at  TIMESTAMPTZ,
    status        VARCHAR(16) NOT NULL DEFAULT 'succeeded',
    rows_returned INT,
    latency_ms    INT,
    detail        JSONB NOT NULL DEFAULT '{}'
);
CREATE INDEX ix_runs_agent_time ON cic.agent_runs(tenant_id, agent_code, started_at DESC);

CREATE TABLE cic.data_freshness (
    tenant_id      UUID NOT NULL,
    entity_type    VARCHAR(64) NOT NULL,
    source_system  VARCHAR(64) NOT NULL,
    last_loaded_at TIMESTAMPTZ NOT NULL,
    recency_target VARCHAR(16),
    is_stale       BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (tenant_id, entity_type, source_system)
);

-- ───────────────────────────── updated_at triggers ─────────────────────────────────
CREATE TRIGGER tg_customers_upd BEFORE UPDATE ON cic.customers FOR EACH ROW EXECUTE FUNCTION cic.tg_set_updated_at();
CREATE TRIGGER tg_sub_upd       BEFORE UPDATE ON cic.subscriptions FOR EACH ROW EXECUTE FUNCTION cic.tg_set_updated_at();

-- ───────────────────────────── Row-level security (tenant scope) ───────────────────
ALTER TABLE cic.customers              ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.customer_identifiers   ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.customer_address       ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.subscriptions          ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.value_metrics          ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.consent                ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_cust_tenant   ON cic.customers            USING (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_xwalk_tenant  ON cic.customer_identifiers USING (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_addr_tenant   ON cic.customer_address     USING (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_sub_tenant    ON cic.subscriptions        USING (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_value_tenant  ON cic.value_metrics        USING (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_consent_tenant ON cic.consent             USING (tenant_id = current_setting('app.current_tenant', true)::uuid);

-- ───────────────────────────── Grants to the app role ──────────────────────────────
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA cic TO sal_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA cic TO sal_app;
