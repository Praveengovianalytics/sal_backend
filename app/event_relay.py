"""Phase 4 outbox → Kafka relay. Reads unpublished rows from cic.event_outbox, publishes them to
Kafka/Redpanda, and stamps published_at. Idempotent and crash-safe: a row is only marked published
after the broker acks, so at-least-once delivery holds; consumers must dedupe on the event id.

Run:
  uv run python -m app.event_relay --once     # drain once (used by smoke)
  uv run python -m app.event_relay            # poll forever (every 1s)
"""
from __future__ import annotations

import argparse
import asyncio
import json

import asyncpg

from .config import settings
from .events import full_topic


async def _connect() -> asyncpg.Connection:
    conn = await asyncpg.connect(settings.db_dsn)
    # Enable the relay RLS bypass so we can see/flush every tenant's outbox on one connection.
    await conn.execute("SELECT set_config('sal.relay', 'on', false)")
    return conn


async def drain_once(conn, producer) -> int:
    rows = await conn.fetch(
        "SELECT id, topic, msg_key, payload FROM cic.event_outbox WHERE published_at IS NULL ORDER BY created_at LIMIT 500"
    )
    sent = 0
    for r in rows:
        payload = r["payload"]
        body = payload if isinstance(payload, (bytes, bytearray)) else str(payload).encode()
        try:
            if producer is not None:
                await producer.send_and_wait(
                    full_topic(r["topic"]),
                    value=body,
                    key=(r["msg_key"] or str(r["id"])).encode(),
                )
            await conn.execute("UPDATE cic.event_outbox SET published_at=now() WHERE id=$1", r["id"])
            sent += 1
        except Exception as e:  # leave unpublished; retry next pass
            await conn.execute(
                "UPDATE cic.event_outbox SET attempts=attempts+1, last_error=$2 WHERE id=$1", r["id"], str(e)[:240]
            )
    return sent


async def main(once: bool) -> None:
    conn = await _connect()
    producer = None
    if settings.kafka_bootstrap:
        try:
            from aiokafka import AIOKafkaProducer
            producer = AIOKafkaProducer(bootstrap_servers=settings.kafka_bootstrap)
            await producer.start()
        except Exception as e:
            print(json.dumps({"relay": "kafka_unavailable", "error": str(e)}))
            producer = None
    try:
        if once:
            n = await drain_once(conn, producer)
            print(json.dumps({"relay": "drained", "published": n, "kafka": bool(producer)}))
        else:
            while True:
                await drain_once(conn, producer)
                await asyncio.sleep(1.0)
    finally:
        if producer is not None:
            await producer.stop()
        await conn.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true", help="drain the outbox once and exit")
    args = ap.parse_args()
    asyncio.run(main(args.once))
