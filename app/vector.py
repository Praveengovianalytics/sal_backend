"""Phase 4 vector RAG grounding — Milvus (Lite) index over the FAQ/policy corpus with a pluggable
embedder. Milvus Lite is an embedded, file-backed build of Milvus (same API as a server cluster), so
local dev needs no extra container; the cloud build swaps `milvus_uri` for a Milvus cluster endpoint.

Embeddings are pluggable behind `embed()`:
  - "stub"  (default): deterministic, offline, hashed bag-of-words → cosine ≈ lexical overlap. Lets RAG
                       run with zero external calls; good enough to demonstrate retrieval locally.
  - "anthropic"/"voyage": real embeddings via Central Kitchen / a hosted model (wired later).

The collection is (re)built from cic.knowledge_doc at backend startup, so only the backend process ever
opens the Milvus Lite file (no multi-process contention).
"""
from __future__ import annotations

import hashlib
import math

from .config import settings

_COLLECTION = "sal_knowledge"
_client = None


# ───────────────────────── embedder (pluggable) ─────────────────────────
def _stub_embed(text: str) -> list[float]:
    """Deterministic hashed bag-of-words, L2-normalised so inner-product == cosine ≈ lexical overlap."""
    import re

    dim = settings.embed_dim
    vec = [0.0] * dim
    for tok in re.findall(r"[a-z0-9]+", (text or "").lower()):
        if len(tok) < 3:
            continue
        h = int(hashlib.md5(tok.encode()).hexdigest(), 16)
        vec[h % dim] += 1.0
    norm = math.sqrt(sum(v * v for v in vec)) or 1.0
    return [v / norm for v in vec]


def embed(text: str) -> list[float]:
    # Only the stub is implemented locally; real providers plug in here behind the same signature.
    return _stub_embed(text)


# ───────────────────────── Milvus Lite lifecycle ─────────────────────────
def client():
    global _client
    if _client is None:
        import time as _time

        from pymilvus import MilvusClient

        last = None
        for attempt in range(5):  # tolerate a brief file-lock race after a fast restart
            try:
                _client = MilvusClient(uri=settings.milvus_uri)
                break
            except Exception as e:
                last = e
                _time.sleep(1.0)
        if _client is None:
            raise last
    return _client


async def reindex(pool) -> int:
    """Rebuild the collection from every tenant's knowledge_doc. Returns the number of docs indexed."""
    if not settings.rag_enabled:
        return 0
    c = client()
    if c.has_collection(_COLLECTION):
        c.drop_collection(_COLLECTION)
    c.create_collection(
        collection_name=_COLLECTION,
        dimension=settings.embed_dim,
        metric_type="COSINE",
        auto_id=False,
        primary_field_name="id",
        vector_field_name="vector",
    )
    # Read the whole corpus across tenants via the relay-bypass policy. The flag is transaction-local,
    # so the read must run inside the same transaction that sets it.
    async with pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('sal.relay', 'on', true)")
            rows = await conn.fetch(
                "SELECT tenant_id::text AS tenant_id, title, body, category, source FROM cic.knowledge_doc"
            )
    docs = []
    for i, r in enumerate(rows):
        docs.append({
            "id": i,
            "vector": embed(f"{r['title']} {r['body']}"),
            "tenant_id": r["tenant_id"],
            "title": r["title"],
            "body": r["body"],
            "category": r["category"],
            "source": r["source"],
        })
    if docs:
        c.insert(collection_name=_COLLECTION, data=docs)
    return len(docs)


def search(query: str, tenant_id: str, limit: int = 3) -> list[dict]:
    if not settings.rag_enabled:
        return []
    c = client()
    if not c.has_collection(_COLLECTION):
        return []
    res = c.search(
        collection_name=_COLLECTION,
        data=[embed(query)],
        limit=limit,
        filter=f'tenant_id == "{tenant_id}"',
        output_fields=["title", "body", "category", "source"],
    )
    hits = res[0] if res else []
    out = []
    for h in hits:
        e = h.get("entity", {})
        out.append({
            "title": e.get("title"), "body": e.get("body"),
            "category": e.get("category"), "source": e.get("source"),
            "score": round(float(h.get("distance", 0.0)), 4),
        })
    return out
