"""Phase 4 event backbone — transactional outbox + pluggable Kafka producer.

Write tools call `emit(conn, topic, key, payload)` INSIDE their request transaction, so the event is
durably staged in `cic.event_outbox` atomically with the business write (no dual-write race). A relay
(`app.event_relay`) later publishes unrelayed rows to Kafka/Redpanda and stamps `published_at` — so if
the broker is down, nothing is lost; events simply accumulate and flush on the next relay run.

The Kafka client is optional: with no `SAL_KAFKA_BOOTSTRAP` set (or aiokafka not installed) the producer
is a no-op and the platform runs purely on the outbox — the same code path used in cloud, just unflushed.
"""
from __future__ import annotations

import json

from .config import settings


async def emit(conn, topic: str, key: str | None, payload: dict) -> None:
    """Stage a domain event in the outbox within the caller's transaction.

    `topic` is the short suffix (e.g. "recommendation"); the relay prefixes it with kafka_topic_prefix.
    """
    await conn.execute(
        """INSERT INTO cic.event_outbox (tenant_id, topic, msg_key, payload)
           VALUES (current_setting('app.current_tenant')::uuid, $1, $2, $3::jsonb)""",
        topic, key, json.dumps(payload, default=str),
    )


# ───────────────────────── Kafka producer (optional) ─────────────────────────
_producer = None


async def kafka_producer():
    """Lazily create an aiokafka producer if a bootstrap server is configured. Returns None when Kafka
    is not wired (so callers degrade to outbox-only)."""
    global _producer
    if not settings.kafka_bootstrap:
        return None
    if _producer is not None:
        return _producer
    try:
        from aiokafka import AIOKafkaProducer
    except ImportError:
        return None
    _producer = AIOKafkaProducer(bootstrap_servers=settings.kafka_bootstrap)
    await _producer.start()
    return _producer


async def kafka_close() -> None:
    global _producer
    if _producer is not None:
        await _producer.stop()
        _producer = None


def full_topic(topic: str) -> str:
    return f"{settings.kafka_topic_prefix}{topic}"
