-- SAL Phase 3 (Fulfilment) — order submission (BOID-mapped), inventory, fallout recovery, tracking.
-- Integrations (RIM/MTPOS/One Inventory/eKYC/LMS) are stubbed in app/integrations for local dev.
-- NB: "order" is a reserved word → table is cic.sales_order.

CREATE TABLE cic.inventory (
    tenant_id    UUID NOT NULL REFERENCES cic.tenants(id),
    product_code VARCHAR(64) NOT NULL,
    description  VARCHAR(255),
    available    INT NOT NULL DEFAULT 0,
    store_ref    VARCHAR(64),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, product_code)
);

CREATE TABLE cic.sales_order (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES cic.tenants(id),
    session_id      UUID,
    customer_id     UUID NOT NULL,
    rec_id          UUID,
    offer_id        VARCHAR(64),
    product_code    VARCHAR(64),
    boid            TEXT[],
    total           NUMERIC(18,2),
    channel         VARCHAR(32) NOT NULL DEFAULT 'retail',
    status          VARCHAR(24) NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','validated','submitted','fulfilled','fallout','rejected','cancelled')),
    fallout_reason  VARCHAR(64),
    recovery_action VARCHAR(255),
    external_ref    VARCHAR(64),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_order_customer ON cic.sales_order(tenant_id, customer_id, created_at DESC);

CREATE TABLE cic.order_event (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  UUID NOT NULL REFERENCES cic.tenants(id),
    order_id   UUID NOT NULL REFERENCES cic.sales_order(id) ON DELETE CASCADE,
    event_type VARCHAR(48) NOT NULL,
    detail     JSONB NOT NULL DEFAULT '{}',
    at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_order_event ON cic.order_event(order_id, at);

ALTER TABLE cic.inventory    ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.sales_order  ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.order_event  ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_inv   ON cic.inventory   FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_order ON cic.sales_order FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_oevt  ON cic.order_event FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);

GRANT SELECT, INSERT, UPDATE ON cic.inventory, cic.sales_order, cic.order_event TO sal_app;

-- Map the device offer to a product code + seed inventory (iPhone 16: 1 unit → enables a fallout demo on the 2nd order).
UPDATE cic.offer_catalogue SET meta = jsonb_set(meta, '{product_code}', '"iphone16_128"')
  WHERE tenant_id='11111111-1111-1111-1111-111111111111' AND offer_id='OFFER_RECON_DEVICE';
INSERT INTO cic.inventory (tenant_id, product_code, description, available, store_ref) VALUES
  ('11111111-1111-1111-1111-111111111111','iphone16_128','iPhone 16 128GB', 1, 'STORE_TAMPINES')
ON CONFLICT DO NOTHING;

-- Phase 3 agent + bindings
INSERT INTO cic.agents (tenant_id, code, display_name, version, runtime) VALUES
  (NULL,'fulfilment_agent','Fulfilment Agent','1.0.0','agentic_layer_python')
ON CONFLICT DO NOTHING;
INSERT INTO cic.agent_mcp_tool_bindings (agent_code, mcp_tool, access, purpose_scope) VALUES
  ('fulfilment_agent','mcp_validate_offer','read','{personalisation}'),
  ('fulfilment_agent','mcp_check_inventory','read','{personalisation}'),
  ('fulfilment_agent','mcp_ekyc_checklist','read','{personalisation}'),
  ('fulfilment_agent','mcp_submit_order','write','{personalisation}'),
  ('fulfilment_agent','mcp_get_order','read','{personalisation}')
ON CONFLICT DO NOTHING;
