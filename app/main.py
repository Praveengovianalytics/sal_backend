"""SAL backend — the MCP layer (backend services) over the Customer Intelligence Cube.

Exposes MCP read tools as HTTP endpoints. Every call: resolves the tenant/agent/purpose context,
enforces the agent↔tool binding, runs in a tenant-scoped (RLS) transaction, checks consent,
returns freshness, and writes an audit row (cic.agent_runs == mcp_access_log).
"""
import json
import time
import uuid as uuidlib

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

from . import events, vector
from .cache import cache_get, cache_set, close_cache, init_cache
from .config import settings
from .db import close_pool, get_pool, init_pool, run_audit, tenant_conn
from .mcp import tools

app = FastAPI(title="SAL Backend · MCP layer", version="0.1.0")


@app.on_event("startup")
async def _startup() -> None:
    await init_pool()
    await init_cache()
    # Phase 4: build the Milvus RAG index from the knowledge corpus (best-effort — degrade to FTS).
    try:
        n = await vector.reindex(get_pool())
        print(json.dumps({"rag_index": "built", "docs": n, "provider": settings.embed_provider}))
    except Exception as e:
        print(json.dumps({"rag_index": "skipped", "error": str(e)}))


@app.on_event("shutdown")
async def _shutdown() -> None:
    await events.kafka_close()
    await close_pool()
    await close_cache()


# ── request/response models ─────────────────────────────────────────────
class ResolveIdentityReq(BaseModel):
    id_type: str
    id_value: str


class CustomerReq(BaseModel):
    customer_id: str


class AssembleReq(BaseModel):
    customer_id: str
    intent: str | None = None


def _ctx(tenant_id: str | None, agent_code: str | None, purpose: str | None):
    return (
        tenant_id or settings.default_tenant_id,
        agent_code or "context_assembler",
        purpose or "personalisation",
    )


async def _binding_ok(conn, agent_code: str, tool_name: str) -> bool:
    row = await conn.fetchrow(
        "SELECT 1 FROM cic.agent_mcp_tool_bindings WHERE agent_code=$1 AND mcp_tool=$2",
        agent_code, tool_name,
    )
    return row is not None


async def _audit(*, tenant_id, agent_code, tool_name, customer_id, consent_ok, rows, latency_ms, op="read", status="succeeded", detail=None):
    await run_audit(
        """INSERT INTO cic.agent_runs
             (tenant_id, agent_code, mcp_tool, customer_id, op, consent_ok, completed_at, status, rows_returned, latency_ms, detail)
           VALUES ($1::uuid,$2,$3,$4::uuid,$5,$6, now(), $7, $8, $9, $10::jsonb)""",
        tenant_id, agent_code, tool_name, customer_id, op, consent_ok, status, rows, latency_ms, json.dumps(detail or {}),
    )


@app.get("/health")
async def health():
    async with tenant_conn(settings.default_tenant_id) as conn:
        await conn.fetchval("SELECT 1")
    return {"status": "ok", "service": "sal_backend", "layer": "mcp"}


@app.post("/mcp/resolve_identity")
async def resolve_identity(
    req: ResolveIdentityReq,
    x_tenant_id: str | None = Header(default=None),
    x_agent_code: str | None = Header(default=None),
    x_purpose: str | None = Header(default=None),
):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_resolve_identity"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_resolve_identity")
        try:
            customer_id = await tools.resolve_identity(conn, req.id_type, req.id_value)
        except tools.NotFound as e:
            await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_resolve_identity",
                         customer_id=None, consent_ok=None, rows=0,
                         latency_ms=int((time.perf_counter() - t0) * 1000), status="not_found")
            raise HTTPException(404, str(e))
        await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_resolve_identity",
                     customer_id=customer_id, consent_ok=None, rows=1,
                     latency_ms=int((time.perf_counter() - t0) * 1000))
    return {"customer_id": customer_id}


@app.post("/mcp/get_customer_360")
async def get_customer_360(
    req: CustomerReq,
    x_tenant_id: str | None = Header(default=None),
    x_agent_code: str | None = Header(default=None),
    x_purpose: str | None = Header(default=None),
):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_get_customer_360"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_get_customer_360")
        consent_ok = await tools.check_consent(conn, req.customer_id, purpose)
        if not consent_ok:
            await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_get_customer_360",
                         customer_id=req.customer_id, consent_ok=False, rows=0,
                         latency_ms=int((time.perf_counter() - t0) * 1000), status="consent_denied")
            raise HTTPException(403, f"no consent for purpose '{purpose}'")
        try:
            result = await tools.get_customer_360(conn, req.customer_id)
        except tools.NotFound as e:
            raise HTTPException(404, str(e))
        await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_get_customer_360",
                     customer_id=req.customer_id, consent_ok=True, rows=1,
                     latency_ms=int((time.perf_counter() - t0) * 1000))
    return result


@app.post("/mcp/assemble_context")
async def assemble_context(
    req: AssembleReq,
    x_tenant_id: str | None = Header(default=None),
    x_agent_code: str | None = Header(default=None),
    x_purpose: str | None = Header(default=None),
):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    cache_key = f"ctx:{tenant_id}:{req.customer_id}:{purpose}"
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_assemble_context"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_assemble_context")
        consent_ok = await tools.check_consent(conn, req.customer_id, purpose)
        if not consent_ok:
            await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_assemble_context",
                         customer_id=req.customer_id, consent_ok=False, rows=0,
                         latency_ms=int((time.perf_counter() - t0) * 1000), status="consent_denied")
            raise HTTPException(403, f"no consent for purpose '{purpose}'")
        cached = await cache_get(cache_key)
        if cached:
            await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_assemble_context",
                         customer_id=req.customer_id, consent_ok=True, rows=1,
                         latency_ms=int((time.perf_counter() - t0) * 1000), detail={"cache": "hit"})
            cached["_cache"] = "hit"
            return cached
        try:
            result = await tools.assemble_context(conn, req.customer_id, req.intent)
        except tools.NotFound as e:
            raise HTTPException(404, str(e))
        await cache_set(cache_key, result)
        await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_assemble_context",
                     customer_id=req.customer_id, consent_ok=True, rows=1,
                     latency_ms=int((time.perf_counter() - t0) * 1000), detail={"cache": "miss"})
    result["_cache"] = "miss"
    return result


# ── Phase 1 models ──────────────────────────────────────────────────────
class InteractionsReq(BaseModel):
    customer_id: str
    limit: int = 10


class KnowledgeReq(BaseModel):
    query: str
    limit: int = 3


class OpenSessionReq(BaseModel):
    customer_id: str | None = None
    channel_code: str = "retail"
    intent: str | None = None
    staff_user_ref: str | None = None


class ObjectionReq(BaseModel):
    session_id: str
    customer_id: str | None = None
    objection_code: str | None = None
    detail: str | None = None


class OutcomeReq(BaseModel):
    session_id: str | None = None
    customer_id: str | None = None
    outcome: str
    reason_code: str | None = None
    rec_id: str | None = None
    boid_tagged: list[str] | None = None


# ── Phase 2a models ─────────────────────────────────────────────────────
class OffersReq(BaseModel):
    scenario: str | None = None
    service_type: str | None = None


class CompetitorReq(BaseModel):
    plan_ref: str


class ResolveFeaturesReq(BaseModel):
    entity_grain: str = "ctct"
    entity_ref: str
    feature_codes: list[str]


class LogRecReq(BaseModel):
    session_id: str | None = None
    customer_id: str
    top_pick_offer_id: str | None = None
    scores: dict = {}
    rationale: str | None = None
    candidates: list[dict] = []
    channel_code: str = "retail"


@app.post("/mcp/get_holdings")
async def get_holdings(req: CustomerReq, x_tenant_id: str | None = Header(default=None),
                       x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_get_holdings"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_get_holdings")
        if not await tools.check_consent(conn, req.customer_id, purpose):
            await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_get_holdings",
                         customer_id=req.customer_id, consent_ok=False, rows=0,
                         latency_ms=int((time.perf_counter()-t0)*1000), status="consent_denied")
            raise HTTPException(403, f"no consent for purpose '{purpose}'")
        result = await tools.get_holdings(conn, req.customer_id)
        await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_get_holdings",
                     customer_id=req.customer_id, consent_ok=True, rows=len(result),
                     latency_ms=int((time.perf_counter()-t0)*1000))
    return {"holdings": result}


@app.post("/mcp/get_interactions")
async def get_interactions(req: InteractionsReq, x_tenant_id: str | None = Header(default=None),
                           x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_get_interactions"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_get_interactions")
        if not await tools.check_consent(conn, req.customer_id, purpose):
            await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_get_interactions",
                         customer_id=req.customer_id, consent_ok=False, rows=0,
                         latency_ms=int((time.perf_counter()-t0)*1000), status="consent_denied")
            raise HTTPException(403, f"no consent for purpose '{purpose}'")
        result = await tools.get_interactions(conn, req.customer_id, req.limit)
        await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_get_interactions",
                     customer_id=req.customer_id, consent_ok=True, rows=len(result),
                     latency_ms=int((time.perf_counter()-t0)*1000))
    return {"interactions": result}


@app.post("/mcp/knowledge_search")
async def knowledge_search(req: KnowledgeReq, x_tenant_id: str | None = Header(default=None),
                           x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_knowledge_search"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_knowledge_search")
        result = await tools.knowledge_search(conn, req.query, req.limit)
        await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_knowledge_search",
                     customer_id=None, consent_ok=None, rows=len(result),
                     latency_ms=int((time.perf_counter()-t0)*1000))
    return {"results": result}


@app.post("/mcp/open_session")
async def open_session(req: OpenSessionReq, x_tenant_id: str | None = Header(default=None),
                       x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_open_session"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_open_session")
        sid = await tools.open_session(conn, req.customer_id, req.channel_code, req.intent, agent_code, req.staff_user_ref)
    await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_open_session",
                 customer_id=req.customer_id, consent_ok=None, rows=1, op="write",
                 latency_ms=int((time.perf_counter()-t0)*1000))
    return {"session_id": sid}


@app.post("/mcp/capture_objection")
async def capture_objection(req: ObjectionReq, x_tenant_id: str | None = Header(default=None),
                            x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_capture_objection"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_capture_objection")
        oid = await tools.capture_objection(conn, req.session_id, req.customer_id, req.objection_code, req.detail)
    await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_capture_objection",
                 customer_id=req.customer_id, consent_ok=None, rows=1, op="write",
                 latency_ms=int((time.perf_counter()-t0)*1000))
    return {"objection_id": oid}


@app.post("/mcp/record_outcome")
async def record_outcome(req: OutcomeReq, x_tenant_id: str | None = Header(default=None),
                         x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_record_outcome"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_record_outcome")
        rid = await tools.record_outcome(conn, req.session_id, req.customer_id, req.outcome, req.reason_code, req.rec_id, req.boid_tagged)
    await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_record_outcome",
                 customer_id=req.customer_id, consent_ok=None, rows=1, op="write",
                 latency_ms=int((time.perf_counter()-t0)*1000))
    return {"outcome_id": rid}


async def _read_tool(tool_name, agent_code, tenant_id, purpose, consent_customer, coro_factory):
    """Shared read-endpoint flow: binding → (optional consent) → run → audit."""
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, tool_name):
            raise HTTPException(403, f"agent {agent_code} not bound to {tool_name}")
        if consent_customer is not None and not await tools.check_consent(conn, consent_customer, purpose):
            await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name=tool_name, customer_id=consent_customer,
                         consent_ok=False, rows=0, latency_ms=int((time.perf_counter()-t0)*1000), status="consent_denied")
            raise HTTPException(403, f"no consent for purpose '{purpose}'")
        result = await coro_factory(conn)
        n = len(result) if isinstance(result, list) else 1
        await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name=tool_name, customer_id=consent_customer,
                     consent_ok=(True if consent_customer is not None else None), rows=n,
                     latency_ms=int((time.perf_counter()-t0)*1000))
    return result


@app.post("/mcp/get_value_propensity")
async def get_value_propensity(req: CustomerReq, x_tenant_id: str | None = Header(default=None),
                               x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    return await _read_tool("mcp_get_value_propensity", agent_code, tenant_id, purpose, req.customer_id,
                            lambda conn: tools.get_value_propensity(conn, req.customer_id))


@app.post("/mcp/get_eligibility")
async def get_eligibility(req: CustomerReq, scenario: str | None = None, x_tenant_id: str | None = Header(default=None),
                          x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    res = await _read_tool("mcp_get_eligibility", agent_code, tenant_id, purpose, req.customer_id,
                           lambda conn: tools.get_eligibility(conn, req.customer_id, scenario))
    return {"eligibility": res}


@app.post("/mcp/get_vouchers")
async def get_vouchers(req: CustomerReq, x_tenant_id: str | None = Header(default=None),
                       x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    res = await _read_tool("mcp_get_vouchers", agent_code, tenant_id, purpose, req.customer_id,
                           lambda conn: tools.get_vouchers(conn, req.customer_id))
    return {"vouchers": res}


@app.post("/mcp/search_offers")
async def search_offers(req: OffersReq, x_tenant_id: str | None = Header(default=None),
                        x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    res = await _read_tool("mcp_search_offers", agent_code, tenant_id, purpose, None,
                           lambda conn: tools.search_offers(conn, req.scenario, req.service_type))
    return {"offers": res}


@app.post("/mcp/get_competitor_price")
async def get_competitor_price(req: CompetitorReq, x_tenant_id: str | None = Header(default=None),
                               x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    res = await _read_tool("mcp_get_competitor_price", agent_code, tenant_id, purpose, None,
                           lambda conn: tools.get_competitor_price(conn, req.plan_ref))
    return {"competitor_prices": res}


@app.post("/mcp/resolve_features")
async def resolve_features(req: ResolveFeaturesReq, x_tenant_id: str | None = Header(default=None),
                           x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    res = await _read_tool("mcp_resolve_features", agent_code, tenant_id, purpose, None,
                           lambda conn: tools.resolve_features(conn, req.entity_grain, req.entity_ref, req.feature_codes))
    return {"features": res, "source": "databricks_mc360"}


@app.post("/mcp/log_recommendation")
async def log_recommendation(req: LogRecReq, x_tenant_id: str | None = Header(default=None),
                             x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_log_recommendation"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_log_recommendation")
        rec_id = await tools.log_recommendation(conn, req.session_id, req.customer_id, agent_code,
                                                req.top_pick_offer_id, req.scores, req.rationale, req.candidates,
                                                req.channel_code)
    await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_log_recommendation",
                 customer_id=req.customer_id, consent_ok=None, rows=len(req.candidates), op="write",
                 latency_ms=int((time.perf_counter()-t0)*1000))
    return {"rec_id": rec_id}


# ── Phase 2b models + endpoints ─────────────────────────────────────────
class FlagGapReq(BaseModel):
    pattern: str
    customer_id: str | None = None
    source_signal: str = "unmet_ask"


class GapsReq(BaseModel):
    limit: int = 20


@app.post("/mcp/flag_bundle_gap")
async def flag_bundle_gap(req: FlagGapReq, x_tenant_id: str | None = Header(default=None),
                          x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_flag_bundle_gap"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_flag_bundle_gap")
        res = await tools.flag_bundle_gap(conn, req.pattern, req.customer_id, req.source_signal)
    await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_flag_bundle_gap",
                 customer_id=req.customer_id, consent_ok=None, rows=1, op="write",
                 latency_ms=int((time.perf_counter()-t0)*1000), detail={"pattern": req.pattern})
    return res


@app.post("/mcp/get_bundle_gaps")
async def get_bundle_gaps(req: GapsReq, x_tenant_id: str | None = Header(default=None),
                          x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    res = await _read_tool("mcp_get_bundle_gaps", agent_code, tenant_id, purpose, None,
                           lambda conn: tools.get_bundle_gaps(conn, req.limit))
    return {"gaps": res}


# ── Phase 3 models + endpoints (fulfilment) ─────────────────────────────
class ValidateOfferReq(BaseModel):
    customer_id: str
    offer_id: str
    voucher_code: str | None = None


class InventoryReq(BaseModel):
    product_code: str


class EkycReq(BaseModel):
    scenario: str = "recon"


class SubmitOrderReq(BaseModel):
    session_id: str | None = None
    customer_id: str
    rec_id: str | None = None
    offer_id: str
    voucher_code: str | None = None


class OrderReq(BaseModel):
    order_id: str


@app.post("/mcp/validate_offer")
async def validate_offer(req: ValidateOfferReq, x_tenant_id: str | None = Header(default=None),
                         x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    return await _read_tool("mcp_validate_offer", agent_code, tenant_id, purpose, req.customer_id,
                            lambda conn: tools.validate_offer(conn, req.customer_id, req.offer_id, req.voucher_code))


@app.post("/mcp/check_inventory")
async def check_inventory(req: InventoryReq, x_tenant_id: str | None = Header(default=None),
                          x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    return await _read_tool("mcp_check_inventory", agent_code, tenant_id, purpose, None,
                            lambda conn: tools.check_inventory(conn, req.product_code))


@app.post("/mcp/ekyc_checklist")
async def ekyc_checklist(req: EkycReq, x_tenant_id: str | None = Header(default=None),
                         x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    res = await _read_tool("mcp_ekyc_checklist", agent_code, tenant_id, purpose, None,
                           lambda conn: tools.ekyc_checklist(req.scenario))
    return {"checklist": res}


@app.post("/mcp/submit_order")
async def submit_order(req: SubmitOrderReq, x_tenant_id: str | None = Header(default=None),
                       x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_submit_order"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_submit_order")
        result = await tools.submit_order(conn, req.session_id, req.customer_id, req.rec_id, req.offer_id, req.voucher_code)
    await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_submit_order",
                 customer_id=req.customer_id, consent_ok=None, rows=1, op="write",
                 latency_ms=int((time.perf_counter()-t0)*1000), detail={"status": result["status"], "offer": req.offer_id})
    return result


@app.post("/mcp/get_order")
async def get_order(req: OrderReq, x_tenant_id: str | None = Header(default=None),
                    x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    return await _read_tool("mcp_get_order", agent_code, tenant_id, purpose, None,
                            lambda conn: tools.get_order(conn, req.order_id))


# ── Phase 4 models + endpoints (omnichannel exposure ledger + vector RAG) ──
class ExposuresReq(BaseModel):
    customer_id: str
    within_hours: int = 72


class RecordExposureReq(BaseModel):
    customer_id: str
    offer_id: str | None = None
    boid: list[str] = []
    channel_code: str = "retail"
    rec_id: str | None = None


class VectorSearchReq(BaseModel):
    query: str
    limit: int = 3


@app.post("/mcp/get_exposures")
async def get_exposures(req: ExposuresReq, x_tenant_id: str | None = Header(default=None),
                        x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    res = await _read_tool("mcp_get_exposures", agent_code, tenant_id, purpose, req.customer_id,
                           lambda conn: tools.get_exposures(conn, req.customer_id, req.within_hours))
    return {"exposures": res}


@app.post("/mcp/record_exposure")
async def record_exposure(req: RecordExposureReq, x_tenant_id: str | None = Header(default=None),
                          x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_record_exposure"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_record_exposure")
        eid = await tools.record_exposure(conn, req.customer_id, req.offer_id, req.boid, req.channel_code, agent_code, req.rec_id)
    await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_record_exposure",
                 customer_id=req.customer_id, consent_ok=None, rows=1, op="write",
                 latency_ms=int((time.perf_counter()-t0)*1000), detail={"channel": req.channel_code, "offer": req.offer_id})
    return {"exposure_id": eid}


@app.post("/mcp/knowledge_search_vector")
async def knowledge_search_vector(req: VectorSearchReq, x_tenant_id: str | None = Header(default=None),
                                  x_agent_code: str | None = Header(default=None), x_purpose: str | None = Header(default=None)):
    tenant_id, agent_code, purpose = _ctx(x_tenant_id, x_agent_code, x_purpose)
    t0 = time.perf_counter()
    # No cube transaction needed — Milvus is queried directly; still binding-checked + audited.
    async with tenant_conn(tenant_id, purpose) as conn:
        if not await _binding_ok(conn, agent_code, "mcp_knowledge_search_vector"):
            raise HTTPException(403, f"agent {agent_code} not bound to mcp_knowledge_search_vector")
    result = tools.knowledge_search_vector(req.query, tenant_id, req.limit)
    await _audit(tenant_id=tenant_id, agent_code=agent_code, tool_name="mcp_knowledge_search_vector",
                 customer_id=None, consent_ok=None, rows=len(result),
                 latency_ms=int((time.perf_counter()-t0)*1000))
    return {"results": result}


@app.post("/mcp/reindex_knowledge")
async def reindex_knowledge():
    """Admin: rebuild the Milvus RAG index from the knowledge corpus."""
    n = await vector.reindex(get_pool())
    return {"indexed": n}


def main():
    import uvicorn
    uvicorn.run("app.main:app", host="0.0.0.0", port=settings.port, reload=False)
