# sal_backend — Core services + MCP layer + PostgreSQL Customer Intelligence Cube

Backend layer (Tier 2 → Tier 3) of SAL. Hosts the **PostgreSQL Customer Intelligence Cube**, the
**MCP layer (backend services)** over it, and integration adapters. Agents reach data **only** through
the MCP tools here — consent + RLS + audit at the boundary. See root [`../../CLAUDE.md`](../../CLAUDE.md)
and the design docs in [`../../docs/`](../../docs).

## Stack (local dev)
- **Python ≥3.11** managed by **`uv`** · **FastAPI** + **uvicorn** · **asyncpg** (Postgres) · **redis**.
- **PostgreSQL 16** (the cube) + **Redis 7** — run via `../../infra/docker-compose.yml`.

## Layout
```
db/migrations/001_cube_schema.sql   # cube DDL (L1 tenancy · L2 identity · L3 consent · L4 agents+audit · L6 customer · L8 value) + RLS
db/seed.sql                         # Phase-0 seed (tenant + customer "Aisha V." + holdings/value/consent/identifiers/agents)
app/config.py                       # settings (SAL_ env prefix)
app/db.py                           # asyncpg pool; tenant_conn() sets app.current_tenant + sal.purpose (RLS); run_audit() (independent conn)
app/cache.py                        # Redis read-through cache
app/mcp/tools.py                    # MCP tool impls: resolve_identity, check_consent, get_customer_360, get_holdings, assemble_context
app/main.py                         # FastAPI MCP endpoints (binding check + consent gate + audit + freshness)
```

## Run (local)
```bash
# 1) infra (from repo root ../../):  docker compose -f infra/docker-compose.yml up -d
# 2) migrate + seed (psql via the postgres container):
docker exec -i sal_postgres psql -v ON_ERROR_STOP=1 -U sal -d sal_cube < db/migrations/001_cube_schema.sql
docker exec -i sal_postgres psql -v ON_ERROR_STOP=1 -U sal -d sal_cube < db/seed.sql
# 3) deps + run:
uv sync
uv run uvicorn app.main:app --host 0.0.0.0 --port 8081
# 4) smoke:  bash scripts/smoke.sh
```

## MCP tools (Phase 0, HTTP)
`POST /mcp/resolve_identity {id_type,id_value}` · `POST /mcp/get_customer_360 {customer_id}` ·
`POST /mcp/assemble_context {customer_id,intent}` · `GET /health`.
Headers carry context: `X-Tenant-Id`, `X-Agent-Code`, `X-Purpose` (dev defaults: seeded tenant /
`context_assembler` / `personalisation`).

## Key invariants (don't break)
- **App connects as `sal_app`** (non-superuser) so **RLS is enforced**; migrations run as `sal`.
- **Every tool**: agent↔tool binding (`cic.agent_mcp_tool_bindings`) → consent (`cic.consent`, fail-secure)
  → tenant-scoped query → freshness → **audit row** (`cic.agent_runs`, written on an independent
  connection so denials are still recorded).
- **No raw SQL from agents** — only via these MCP endpoints. **PII is tokenised** (`*_token`).
- MC360 features are **not** stored here — resolved on demand from Databricks by the ML-Agent (Phase 2a).

## Status
**✅ Phase 0 + Phase 1 complete & verified.** Phase 1 added: cube L9 (sessions/interactions/objections/
outcomes) + grounded-FAQ `knowledge_doc` (Postgres FTS, OR-recall); MCP tools `get_holdings`,
`get_interactions`, `knowledge_search`, and write tools `open_session`, `capture_objection`,
`record_outcome` (RLS WITH CHECK). Migrations `db/migrations/00{1,2}_*.sql` + `db/seed*.sql`.
**✅ Phase 2a added:** L7 offer_catalogue (BOID/dedup/DQ) + voucher + competitor_price; L8 propensity_score,
eligibility, mc360_feature_catalog + mc360_feature_resolved + local Databricks stand-in; L9 recommendation
(+candidates). Tools: get_value_propensity, get_eligibility, get_vouchers, search_offers (DQ-excludes),
get_competitor_price, resolve_features, log_recommendation; record_outcome now BOID-tagged. Migrations
001/002/003 + seeds. **✅ Phase 2b:** L11 `bundle_gap` (upsert-aggregated, distinct-customer count) +
`v_bundle_gap_board`; tools `flag_bundle_gap` / `get_bundle_gaps` (migration 004).
**✅ Phase 3 (Fulfilment) complete & verified:** L10 `inventory`, `sales_order` (NB: not `order` — reserved
word), `order_event`; tools `validate_offer` (bookable + BOID gate; parses JSONB `meta.product_code`),
`check_inventory`, `ekyc_checklist`, `submit_order` (validate → reserve inventory atomically → RIM submit;
out-of-stock ⇒ **FALLOUT** + recovery_action; not-bookable ⇒ **rejected**), `get_order`; `fulfilment_agent`
+ bindings; RIM/eKYC integration stubs (`app/integrations/`). Migration 005; smoke `make smoke-p3`.
**✅ Phase 4 (Omnichannel & scale) complete & verified:** L8 `exposure_ledger` (cross-channel fatigue) +
`event_outbox` (transactional outbox); tools `get_exposures`, `record_exposure`, `knowledge_search_vector`;
write tools (`log_recommendation`/`record_outcome`/`submit_order`/`record_exposure`) emit to the outbox
in-txn via `app/events.py`; `app/event_relay.py` publishes outbox→Redpanda (`python -m app.event_relay
--once`). `app/vector.py` = Milvus Lite RAG (pluggable embedder; rebuilt from `knowledge_doc` at startup,
relay-bypass RLS policy). asyncpg pool now `statement_cache_size=0` (PgBouncer-ready) + configurable size.
Migration 006; smoke `make smoke-p4` + `make loadtest`. **Gotcha:** Milvus Lite holds an exclusive file
lock on `sal_milvus.db/` — run only ONE backend process (a stale one blocks RAG with "Open local milvus
failed"). Next (Phase 5+): cloud migration.
