"""MCP tool implementations over the Customer Intelligence Cube.

Every tool runs inside a tenant-scoped transaction (RLS enforced), checks consent for the purpose,
returns freshness metadata, and is audited by the caller (see main.py). UUID params use ::uuid casts
so plain strings can be passed from the API layer.
"""
import asyncpg

from .. import events as _events
from .. import vector as _vector


class ConsentDenied(Exception):
    """Raised when the customer has not consented to the processing purpose."""


class NotFound(Exception):
    pass


async def resolve_identity(conn: asyncpg.Connection, id_type: str, id_value: str) -> str:
    row = await conn.fetchrow(
        "SELECT customer_id FROM cic.customer_identifiers WHERE id_type=$1 AND id_value=$2",
        id_type, id_value,
    )
    if not row:
        raise NotFound(f"no customer for {id_type}={id_value}")
    return str(row["customer_id"])


async def check_consent(conn: asyncpg.Connection, customer_id: str, purpose: str) -> bool:
    row = await conn.fetchrow(
        "SELECT status FROM cic.consent WHERE customer_id=$1::uuid AND purpose=$2",
        customer_id, purpose,
    )
    return bool(row) and row["status"] == "opted_in"


async def _freshness(conn: asyncpg.Connection) -> dict:
    rows = await conn.fetch("SELECT entity_type, recency_target, is_stale FROM cic.data_freshness")
    return {r["entity_type"]: {"recency": r["recency_target"], "stale": r["is_stale"]} for r in rows}


async def get_customer_360(conn: asyncpg.Connection, customer_id: str) -> dict:
    cust = await conn.fetchrow(
        """SELECT id, name_token, age_band, segment_code, tenure_months, tenure_range,
                  loyalty_tier_code, loyalty_prestige_status, clv_band, value_segment, lifecycle_code,
                  lob_description, customer_type, active_subscription_count, is_multiservice,
                  circle3_eligible, last_interaction_at
           FROM cic.customers WHERE id=$1::uuid""",
        customer_id,
    )
    if not cust:
        raise NotFound(f"customer {customer_id} not visible")
    value = await conn.fetchrow(
        "SELECT arpu, arpu_band, clv, margin_band FROM cic.value_metrics WHERE customer_id=$1::uuid",
        customer_id,
    )
    consent = {
        r["purpose"]: r["status"]
        for r in await conn.fetch("SELECT purpose, status FROM cic.consent WHERE customer_id=$1::uuid", customer_id)
    }
    return {
        "customer_id": str(cust["id"]),
        "profile": {
            "name_token": cust["name_token"],
            "age_band": cust["age_band"],
            "segment": cust["segment_code"],
            "tenure_months": cust["tenure_months"],
            "tenure_range": cust["tenure_range"],
            "loyalty_tier": cust["loyalty_tier_code"],
            "loyalty_prestige": cust["loyalty_prestige_status"],
            "customer_type": cust["customer_type"],
            "lob": cust["lob_description"],
            "lifecycle": cust["lifecycle_code"],
            "active_subscriptions": cust["active_subscription_count"],
            "is_multiservice": cust["is_multiservice"],
            "circle3_eligible": cust["circle3_eligible"],
            "last_interaction_at": cust["last_interaction_at"],
        },
        "value": dict(value) if value else None,
        "consent": consent,
    }


async def get_holdings(conn: asyncpg.Connection, customer_id: str) -> list[dict]:
    rows = await conn.fetch(
        """SELECT service_type_code, plan_code, plan_name, mrc, currency_code, status_code, is_legacy
           FROM cic.subscriptions WHERE customer_id=$1::uuid AND status_code='active'
           ORDER BY service_type_code""",
        customer_id,
    )
    return [dict(r) for r in rows]


async def assemble_context(conn: asyncpg.Connection, customer_id: str, intent: str | None = None) -> dict:
    """The orchestrator tool: the 3-lens bundle (prescriptive stub + predictive + longitudinal-light)."""
    c360 = await get_customer_360(conn, customer_id)
    holdings = await get_holdings(conn, customer_id)
    return {
        "customer_360": c360["profile"],
        "predictive": c360["value"],          # ARPU/CLV (propensity/uplift land in Phase 2a)
        "prescriptive": {"holdings": holdings, "intent": intent},
        "consent": c360["consent"],
        "_freshness": await _freshness(conn),
    }


# ───────────────────────── Phase 1 tools ─────────────────────────

async def get_interactions(conn, customer_id: str, limit: int = 10) -> list[dict]:
    rows = await conn.fetch(
        """SELECT channel_code, type, subject, sentiment, resolved, occurred_at
           FROM cic.interaction_event WHERE customer_id=$1::uuid
           ORDER BY occurred_at DESC LIMIT $2""",
        customer_id, limit,
    )
    return [dict(r) for r in rows]


_STOP = {"how", "does", "do", "the", "what", "when", "why", "for", "and", "you", "your", "can", "is", "are", "with", "about"}


def _or_query(query: str) -> str:
    """OR-join meaningful terms for recall (AND from plain/websearch tsquery is too strict for NL FAQ)."""
    import re
    words = [w for w in re.findall(r"[a-zA-Z0-9]+", query.lower()) if len(w) > 2 and w not in _STOP]
    return " or ".join(words) if words else query


async def knowledge_search(conn, query: str, limit: int = 3) -> list[dict]:
    tsq = _or_query(query)
    rows = await conn.fetch(
        """SELECT title, body, category, source,
                  ts_rank(ts, websearch_to_tsquery('english', $1)) AS rank
           FROM cic.knowledge_doc
           WHERE ts @@ websearch_to_tsquery('english', $1)
           ORDER BY rank DESC LIMIT $2""",
        tsq, limit,
    )
    return [dict(r) for r in rows]


async def open_session(conn, customer_id, channel_code, intent, owner_agent_code, staff_user_ref) -> str:
    row = await conn.fetchrow(
        """INSERT INTO cic.sal_session (tenant_id, customer_id, channel_code, intent, owner_agent_code, staff_user_ref)
           VALUES (current_setting('app.current_tenant')::uuid, $1::uuid, $2, $3, $4, $5) RETURNING id""",
        customer_id, channel_code, intent, owner_agent_code, staff_user_ref,
    )
    return str(row["id"])


async def capture_objection(conn, session_id, customer_id, objection_code, detail) -> str:
    row = await conn.fetchrow(
        """INSERT INTO cic.objection (tenant_id, session_id, customer_id, objection_code, detail)
           VALUES (current_setting('app.current_tenant')::uuid, $1::uuid, $2::uuid, $3, $4) RETURNING id""",
        session_id, customer_id, objection_code, detail,
    )
    return str(row["id"])


async def record_outcome(conn, session_id, customer_id, outcome, reason_code, rec_id=None, boid_tagged=None) -> str:
    row = await conn.fetchrow(
        """INSERT INTO cic.outcome_feedback (tenant_id, session_id, customer_id, outcome, reason_code, rec_id, boid_tagged)
           VALUES (current_setting('app.current_tenant')::uuid, $1::uuid, $2::uuid, $3, $4, $5::uuid, $6) RETURNING id""",
        session_id, customer_id, outcome, reason_code, rec_id, boid_tagged,
    )
    # Phase 4: BOID-tagged outcome → outbox → Kafka → Ascend feedback loop (closes the in-store gap).
    await _events.emit(conn, "outcome", customer_id, {
        "outcome_id": str(row["id"]), "customer_id": customer_id, "outcome": outcome,
        "reason_code": reason_code, "rec_id": rec_id, "boid_tagged": boid_tagged,
    })
    return str(row["id"])


# ───────────────────────── Phase 2a tools ─────────────────────────
import json as _json


async def get_value_propensity(conn, customer_id: str) -> dict:
    v = await conn.fetchrow("SELECT arpu, arpu_band, clv, margin_band FROM cic.value_metrics WHERE customer_id=$1::uuid", customer_id)
    p = await conn.fetchrow(
        """SELECT churn_risk, accept_propensity, attach_propensity, uplift_segment, model_version, scored_at
           FROM cic.propensity_score WHERE customer_id=$1::uuid ORDER BY scored_at DESC LIMIT 1""",
        customer_id,
    )
    return {"value": dict(v) if v else None, "propensity": dict(p) if p else None}


async def get_eligibility(conn, customer_id: str, scenario: str | None = None) -> list[dict]:
    if scenario:
        rows = await conn.fetch("SELECT scenario_code, eligible, reason_codes, valid_until FROM cic.eligibility WHERE customer_id=$1::uuid AND scenario_code=$2", customer_id, scenario)
    else:
        rows = await conn.fetch("SELECT scenario_code, eligible, reason_codes, valid_until FROM cic.eligibility WHERE customer_id=$1::uuid", customer_id)
    return [dict(r) for r in rows]


async def get_vouchers(conn, customer_id: str) -> list[dict]:
    rows = await conn.fetch(
        """SELECT voucher_code, type, value, expiry, applicable FROM cic.voucher
           WHERE customer_id=$1::uuid AND (expiry IS NULL OR expiry >= current_date) ORDER BY expiry""",
        customer_id,
    )
    return [dict(r) for r in rows]


async def search_offers(conn, scenario: str | None = None, service_type: str | None = None) -> list[dict]:
    rows = await conn.fetch(
        """SELECT offer_id, title, family_code, service_type_code, scenario_code, price, usual_price, discount_pct, boid, meta
           FROM cic.offer_catalogue
           WHERE status_code='active' AND (valid_to IS NULL OR valid_to >= current_date)
             AND NOT (coalesce(dq_flags,'{}') && array['missing_bo_ids'])   -- never surface not-bookable
             AND ($1::text IS NULL OR scenario_code = $1)
             AND ($2::text IS NULL OR service_type_code = $2)
           ORDER BY price""",
        scenario, service_type,
    )
    out = []
    for r in rows:
        d = dict(r)
        m = d.pop("meta", None)
        if isinstance(m, str):                 # asyncpg returns jsonb as text
            m = _json.loads(m or "{}")
        m = m or {}
        d["media"] = m.get("media")            # v0.2 image-led cards (UX-FR-IMG)
        d["product_code"] = m.get("product_code")
        d["qualifiers"] = m.get("qualifiers")  # v0.3 eligibility qualifiers (FR-QUAL)
        d["tnc"] = m.get("tnc")                # v0.3 simple T&C (FR-TNC)
        out.append(d)
    return out


async def get_competitor_price(conn, plan_ref: str) -> list[dict]:
    rows = await conn.fetch("SELECT plan_ref, competitor, monthly_price FROM cic.competitor_price WHERE plan_ref=$1 ORDER BY monthly_price", plan_ref)
    return [dict(r) for r in rows]


async def resolve_features(conn, entity_grain: str, entity_ref: str, feature_codes: list[str]) -> list[dict]:
    """ML-Agent path: read MC360 features (local stand-in for Databricks) and cache the resolved subset."""
    rows = await conn.fetch(
        "SELECT feature_code, value, period_key FROM cic.mc360_feature_store_local WHERE entity_grain=$1 AND entity_ref=$2::uuid AND feature_code = ANY($3::text[])",
        entity_grain, entity_ref, feature_codes,
    )
    for r in rows:
        await conn.execute(
            """INSERT INTO cic.mc360_feature_resolved (tenant_id, entity_grain, entity_ref, feature_code, value, period_key, ttl_expires_at)
               VALUES (current_setting('app.current_tenant')::uuid,$1,$2::uuid,$3,$4,$5, now()+interval '1 hour')
               ON CONFLICT (tenant_id, entity_grain, entity_ref, feature_code, period_key)
               DO UPDATE SET value=EXCLUDED.value, resolved_at=now()""",
            entity_grain, entity_ref, r["feature_code"], r["value"], r["period_key"],
        )
    return [dict(r) for r in rows]


async def log_recommendation(conn, session_id, customer_id, agent_code, top_pick_offer_id, scores, rationale, candidates, channel_code="retail") -> str:
    rec = await conn.fetchrow(
        """INSERT INTO cic.recommendation (tenant_id, session_id, customer_id, recommended_by_agent_code, top_pick_offer_id, scores, rationale, channel_code)
           VALUES (current_setting('app.current_tenant')::uuid, $1::uuid, $2::uuid, $3, $4, $5::jsonb, $6, $7) RETURNING id""",
        session_id, customer_id, agent_code, top_pick_offer_id, _json.dumps(scores or {}), rationale, channel_code,
    )
    rec_id = str(rec["id"])
    for i, c in enumerate(candidates, start=1):
        await conn.execute(
            """INSERT INTO cic.recommendation_candidate
                 (recommendation_id, rank, offer_id, kind, fit_score, arpu_delta, consumer_value, commercial_value, propensity, guardrail_pass, competitor_delta)
               VALUES ($1::uuid,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)""",
            rec_id, i, c.get("offer_id"), c.get("kind"), c.get("fit_score"), c.get("arpu_delta"),
            c.get("consumer_value"), c.get("commercial_value"), c.get("propensity"),
            bool(c.get("guardrail_pass", True)), c.get("competitor_delta"),
        )
    # Phase 4: stage a domain event on the outbox (→ Kafka via relay → Ascend learning loop).
    await _events.emit(conn, "recommendation", customer_id, {
        "rec_id": rec_id, "customer_id": customer_id, "channel": channel_code,
        "top_pick_offer_id": top_pick_offer_id, "agent": agent_code,
    })
    return rec_id


# ───────────────────────── Phase 2b tools ─────────────────────────

async def flag_bundle_gap(conn, pattern: str, customer_id: str | None, source_signal: str) -> dict:
    """Upsert an unmet-demand pattern; counts DISTINCT customers across flags."""
    row = await conn.fetchrow(
        """INSERT INTO cic.bundle_gap (tenant_id, pattern, source_signal, customer_count, sample_customer_ids)
           VALUES (current_setting('app.current_tenant')::uuid, $1, $2,
                   CASE WHEN $3::uuid IS NULL THEN 0 ELSE 1 END,
                   CASE WHEN $3::uuid IS NULL THEN '{}'::uuid[] ELSE ARRAY[$3::uuid] END)
           ON CONFLICT (tenant_id, pattern) DO UPDATE SET
             sample_customer_ids = (SELECT coalesce(array_agg(DISTINCT e), '{}') FROM unnest(cic.bundle_gap.sample_customer_ids || EXCLUDED.sample_customer_ids) e),
             customer_count = (SELECT count(DISTINCT e) FROM unnest(cic.bundle_gap.sample_customer_ids || EXCLUDED.sample_customer_ids) e),
             last_seen = now(), source_signal = EXCLUDED.source_signal
           RETURNING id, customer_count""",
        pattern, source_signal, customer_id,
    )
    return {"gap_id": str(row["id"]), "pattern": pattern, "customer_count": row["customer_count"]}


async def get_bundle_gaps(conn, limit: int = 20) -> list[dict]:
    rows = await conn.fetch(
        "SELECT pattern, source_signal, customer_count, status, first_seen, last_seen FROM cic.v_bundle_gap_board LIMIT $1",
        limit,
    )
    return [dict(r) for r in rows]


# ───────────────────────── Phase 3 tools (fulfilment) ─────────────────────────
from ..integrations import ekyc as _ekyc, rim as _rim


async def _offer_row(conn, offer_id):
    return await conn.fetchrow(
        "SELECT offer_id, title, scenario_code, price, boid, dq_flags, meta FROM cic.offer_catalogue WHERE offer_id=$1 AND status_code='active'",
        offer_id,
    )


async def validate_offer(conn, customer_id: str, offer_id: str, voucher_code: str | None = None) -> dict:
    reasons, valid = [], True
    o = await _offer_row(conn, offer_id)
    if not o:
        return {"valid": False, "reasons": ["offer_not_found_or_inactive"]}
    if o["dq_flags"] and "missing_bo_ids" in o["dq_flags"]:
        valid = False; reasons.append("not_bookable_missing_boid")
    if not o["boid"]:
        valid = False; reasons.append("no_boid")
    elig = await conn.fetchrow("SELECT eligible FROM cic.eligibility WHERE customer_id=$1::uuid AND scenario_code=$2", customer_id, o["scenario_code"])
    if not (elig and elig["eligible"]):
        valid = False; reasons.append(f"not_eligible_for_{o['scenario_code']}")
    if voucher_code:
        v = await conn.fetchrow("SELECT applicable, expiry FROM cic.voucher WHERE customer_id=$1::uuid AND voucher_code=$2", customer_id, voucher_code)
        if not v or not v["applicable"]:
            valid = False; reasons.append("voucher_not_applicable")
    meta = o["meta"]
    if isinstance(meta, str):          # asyncpg returns jsonb as text by default
        meta = _json.loads(meta or "{}")
    product_code = meta.get("product_code") if isinstance(meta, dict) else None
    return {"valid": valid, "reasons": reasons, "offer_id": offer_id, "title": o["title"],
            "scenario": o["scenario_code"], "price": float(o["price"] or 0), "boid": list(o["boid"] or []),
            "product_code": product_code}


async def check_inventory(conn, product_code: str) -> dict:
    r = await conn.fetchrow("SELECT available, store_ref, description FROM cic.inventory WHERE product_code=$1", product_code)
    return {"product_code": product_code, "available": (r["available"] if r else 0),
            "store_ref": (r["store_ref"] if r else None), "description": (r["description"] if r else None)}


async def ekyc_checklist(scenario: str) -> list[str]:
    return _ekyc.checklist(scenario)


async def _order_event(conn, order_id, event_type, detail):
    await conn.execute(
        "INSERT INTO cic.order_event (tenant_id, order_id, event_type, detail) VALUES (current_setting('app.current_tenant')::uuid, $1::uuid, $2, $3::jsonb)",
        order_id, event_type, _json.dumps(detail or {}),
    )


async def submit_order(conn, session_id, customer_id, rec_id, offer_id, voucher_code=None) -> dict:
    val = await validate_offer(conn, customer_id, offer_id, voucher_code)
    row = await conn.fetchrow(
        """INSERT INTO cic.sales_order (tenant_id, session_id, customer_id, rec_id, offer_id, product_code, boid, total, status)
           VALUES (current_setting('app.current_tenant')::uuid,$1::uuid,$2::uuid,$3::uuid,$4,$5,$6,$7,'pending') RETURNING id""",
        session_id, customer_id, rec_id, offer_id, val.get("product_code"), val.get("boid"), val.get("price"),
    )
    oid = str(row["id"])

    if not val["valid"]:
        await conn.execute("UPDATE cic.sales_order SET status='rejected', fallout_reason=$2, updated_at=now() WHERE id=$1::uuid",
                           oid, ",".join(val["reasons"])[:64])
        await _order_event(conn, oid, "validation_failed", {"reasons": val["reasons"]})
        await _events.emit(conn, "order", customer_id, {"order_id": oid, "customer_id": customer_id, "offer_id": offer_id, "status": "rejected", "boid": val["boid"]})
        return await get_order(conn, oid)
    await _order_event(conn, oid, "validated", {"boid": val["boid"]})

    # Inventory reservation (only for physical-device offers).
    pc = val.get("product_code")
    if pc:
        reserved = await conn.fetchrow(
            "UPDATE cic.inventory SET available=available-1, updated_at=now() WHERE product_code=$1 AND available>0 RETURNING available, store_ref", pc)
        if not reserved:  # out of stock → FALLOUT + recovery
            await conn.execute(
                "UPDATE cic.sales_order SET status='fallout', fallout_reason='out_of_stock', recovery_action=$2, updated_at=now() WHERE id=$1::uuid",
                oid, "Reserve at a nearby store or backorder via One Inventory; offer collection/delivery.")
            await _order_event(conn, oid, "fallout", {"reason": "out_of_stock", "product_code": pc})
            await _events.emit(conn, "order", customer_id, {"order_id": oid, "customer_id": customer_id, "offer_id": offer_id, "status": "fallout", "reason": "out_of_stock", "boid": val["boid"]})
            return await get_order(conn, oid)
        await _order_event(conn, oid, "inventory_reserved", {"product_code": pc, "remaining": reserved["available"], "store_ref": reserved["store_ref"]})

    # Submit via RIM (stub) → fulfilled.
    rim = _rim.submit(seed=oid, boid=val["boid"], total=val["price"])
    await conn.execute("UPDATE cic.sales_order SET status='fulfilled', external_ref=$2, updated_at=now() WHERE id=$1::uuid", oid, rim["external_ref"])
    await _order_event(conn, oid, "submitted", {"external_ref": rim["external_ref"]})
    await _order_event(conn, oid, "fulfilled", {})
    await _events.emit(conn, "order", customer_id, {"order_id": oid, "customer_id": customer_id, "offer_id": offer_id, "status": "fulfilled", "external_ref": rim["external_ref"], "boid": val["boid"]})
    return await get_order(conn, oid)


async def get_order(conn, order_id: str) -> dict:
    o = await conn.fetchrow(
        "SELECT id, customer_id, offer_id, product_code, boid, total, status, fallout_reason, recovery_action, external_ref, created_at FROM cic.sales_order WHERE id=$1::uuid", order_id)
    if not o:
        raise NotFound(f"order {order_id} not found")
    events = await conn.fetch("SELECT event_type, detail, at FROM cic.order_event WHERE order_id=$1::uuid ORDER BY at", order_id)
    d = dict(o); d["id"] = str(o["id"]); d["customer_id"] = str(o["customer_id"]); d["boid"] = list(o["boid"] or [])
    d["events"] = [dict(e) for e in events]
    return d


# ───────────────────────── Phase 4 tools (omnichannel + RAG) ─────────────────────────
async def get_exposures(conn, customer_id: str, within_hours: int = 72) -> list[dict]:
    """Cross-channel exposures for a customer within a window — drives fatigue / double-tap suppression."""
    rows = await conn.fetch(
        """SELECT offer_id, boid, channel_code, surfaced_by_agent_code, surfaced_at
           FROM cic.exposure_ledger
           WHERE customer_id=$1::uuid AND surfaced_at >= now() - make_interval(hours => $2)
           ORDER BY surfaced_at DESC""",
        customer_id, within_hours,
    )
    return [dict(r) for r in rows]


async def record_exposure(conn, customer_id, offer_id, boid, channel_code, agent_code, rec_id=None) -> str:
    """Record that an offer was surfaced on a channel (+ emit sal.exposure for cross-channel decisioning)."""
    row = await conn.fetchrow(
        """INSERT INTO cic.exposure_ledger (tenant_id, customer_id, offer_id, boid, channel_code, surfaced_by_agent_code, rec_id)
           VALUES (current_setting('app.current_tenant')::uuid, $1::uuid, $2, $3::text[], $4, $5, $6::uuid) RETURNING id""",
        customer_id, offer_id, list(boid or []), channel_code, agent_code, rec_id,
    )
    await _events.emit(conn, "exposure", customer_id, {
        "exposure_id": str(row["id"]), "customer_id": customer_id, "offer_id": offer_id,
        "channel": channel_code, "boid": list(boid or []), "rec_id": rec_id,
    })
    return str(row["id"])


def knowledge_search_vector(query: str, tenant_id: str, limit: int = 3) -> list[dict]:
    """Milvus RAG retrieval over the FAQ/policy corpus (cube-independent; embeddings via app.vector)."""
    return _vector.search(query, tenant_id, limit)
