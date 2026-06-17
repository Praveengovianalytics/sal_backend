-- SAL Phase 4 (Omnichannel & scale) — cross-channel exposure ledger (fatigue/double-tap prevention),
-- transactional event outbox (Kafka backbone), channel awareness on recommendations.
-- Kafka (Redpanda) + Milvus (Lite) are wired in the app layer; this migration is cube-only.

-- ── Cross-channel exposure ledger (L8 decisioning) ──
-- Every offer surfaced to a customer is recorded with its channel so the recommender can suppress
-- fatigue / double-taps consistently across store, care, digital and DS3 self-serve.
CREATE TABLE cic.exposure_ledger (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id              UUID NOT NULL REFERENCES cic.tenants(id),
    customer_id            UUID NOT NULL,
    offer_id               VARCHAR(64),
    boid                   TEXT[] NOT NULL DEFAULT '{}',
    channel_code           VARCHAR(24) NOT NULL,
    surfaced_by_agent_code VARCHAR(64),
    rec_id                 UUID,
    surfaced_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_exposure_recent ON cic.exposure_ledger (tenant_id, customer_id, surfaced_at DESC);

-- ── Transactional outbox → Kafka relay (event backbone) ──
-- Write tools insert here in the SAME transaction as the business write; app/event_relay.py
-- publishes unrelayed rows to Kafka and stamps published_at. No data loss if Kafka is down.
CREATE TABLE cic.event_outbox (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL REFERENCES cic.tenants(id),
    topic        VARCHAR(64) NOT NULL,
    msg_key      VARCHAR(128),
    payload      JSONB NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at TIMESTAMPTZ,
    attempts     INT NOT NULL DEFAULT 0,
    last_error   TEXT
);
CREATE INDEX ix_outbox_unpublished ON cic.event_outbox (created_at) WHERE published_at IS NULL;

-- Channel awareness on recommendations (sal_session already carries channel_code).
ALTER TABLE cic.recommendation ADD COLUMN IF NOT EXISTS channel_code VARCHAR(24) NOT NULL DEFAULT 'retail';

-- RLS (tenant-scoped, fail-secure) + grants for the app role.
ALTER TABLE cic.exposure_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE cic.event_outbox    ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_expo  ON cic.exposure_ledger FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
CREATE POLICY p_outbx ON cic.event_outbox    FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant', true)::uuid);
GRANT SELECT, INSERT, UPDATE ON cic.exposure_ledger, cic.event_outbox TO sal_app;

-- The relay reads/updates the outbox across tenants on its own connection — give it a bypass policy.
-- (Local dev: sal_app runs the relay; in cloud this is a dedicated relay role.)
CREATE POLICY p_outbx_relay ON cic.event_outbox FOR ALL TO sal_app
  USING (current_setting('sal.relay', true) = 'on') WITH CHECK (current_setting('sal.relay', true) = 'on');

-- The RAG indexer reads the whole knowledge corpus across tenants on the relay-bypass flag.
CREATE POLICY p_kdoc_relay ON cic.knowledge_doc FOR SELECT TO sal_app
  USING (current_setting('sal.relay', true) = 'on');

-- ── Phase 4 agents + bindings ──
INSERT INTO cic.agents (tenant_id, code, display_name, version, runtime) VALUES
  (NULL,'channel_router','Channel Router','1.0.0','agentic_layer_python')
ON CONFLICT DO NOTHING;

-- recommender gains exposure read/write (fatigue) + vector knowledge search; faq gains vector search.
INSERT INTO cic.agent_mcp_tool_bindings (agent_code, mcp_tool, access, purpose_scope) VALUES
  ('recommender','mcp_get_exposures','read','{personalisation}'),
  ('recommender','mcp_record_exposure','write','{personalisation}'),
  ('recommender','mcp_knowledge_search_vector','read','{personalisation}'),
  ('faq_knowledge','mcp_knowledge_search_vector','read','{knowledge}'),
  ('context_assembler','mcp_get_exposures','read','{personalisation}')
ON CONFLICT DO NOTHING;
