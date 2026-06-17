-- SAL Phase 2b (New-bundle discovery) — capture unmet demand → product-config signal.
-- bundle_gap is upsert-aggregated per pattern (distinct customers counted); a view powers the board.

CREATE TABLE cic.bundle_gap (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES cic.tenants(id),
    pattern             VARCHAR(255) NOT NULL,
    source_signal       VARCHAR(32) CHECK (source_signal IN ('rejection','unmet_ask','abandoned_cart','ineligible')),
    customer_count      INT NOT NULL DEFAULT 0,
    sample_customer_ids UUID[] NOT NULL DEFAULT '{}',
    status              VARCHAR(16) NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_review','productised','dismissed')),
    first_seen          TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen           TIMESTAMPTZ NOT NULL DEFAULT now(),
    meta                JSONB NOT NULL DEFAULT '{}',
    CONSTRAINT uq_bundle_gap UNIQUE (tenant_id, pattern)
);
CREATE INDEX ix_bundle_gap_board ON cic.bundle_gap(tenant_id, status, customer_count DESC);

-- Discovery board (L11 rollup) — ranked unmet demand for product/CLM.
CREATE VIEW cic.v_bundle_gap_board AS
SELECT tenant_id, pattern, source_signal, customer_count, status, first_seen, last_seen
FROM cic.bundle_gap
ORDER BY (status = 'open') DESC, customer_count DESC, last_seen DESC;

ALTER TABLE cic.bundle_gap ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_gap ON cic.bundle_gap FOR ALL
  USING (tenant_id = current_setting('app.current_tenant', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);

GRANT SELECT, INSERT, UPDATE ON cic.bundle_gap TO sal_app;
GRANT SELECT ON cic.v_bundle_gap_board TO sal_app;

-- Phase 2b agent + bindings
INSERT INTO cic.agents (tenant_id, code, display_name, version, runtime) VALUES
  (NULL,'discovery','New-Bundle Discovery','1.0.0','agentic_layer_python')
ON CONFLICT DO NOTHING;

INSERT INTO cic.agent_mcp_tool_bindings (agent_code, mcp_tool, access, purpose_scope) VALUES
  ('recommender','mcp_flag_bundle_gap','write','{personalisation}'),
  ('smart_bundler','mcp_flag_bundle_gap','write','{personalisation}'),
  ('feedback_writer','mcp_flag_bundle_gap','write','{personalisation}'),
  ('discovery','mcp_get_bundle_gaps','read','{personalisation}')
ON CONFLICT DO NOTHING;
