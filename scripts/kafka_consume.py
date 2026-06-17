"""One-shot Kafka consumer for verification — reads all currently-available messages on the given
topics from the beginning and prints a JSON summary, then exits. Used by smoke_phase4.sh.

  uv run python scripts/kafka_consume.py sal.recommendation sal.exposure
"""
from __future__ import annotations

import asyncio
import json
import os
import sys

BOOTSTRAP = os.environ.get("SAL_KAFKA_BOOTSTRAP", "localhost:19092")


async def main(topics: list[str]) -> None:
    from aiokafka import AIOKafkaConsumer

    consumer = AIOKafkaConsumer(
        *topics,
        bootstrap_servers=BOOTSTRAP,
        auto_offset_reset="earliest",
        enable_auto_commit=False,
        group_id=None,
    )
    await consumer.start()
    counts: dict[str, int] = {t: 0 for t in topics}
    samples: dict[str, dict] = {}
    try:
        # Drain with explicit timeouts; stop after two consecutive empty polls.
        empty = 0
        while empty < 2:
            batches = await consumer.getmany(timeout_ms=1500)
            if not batches:
                empty += 1
                continue
            empty = 0
            for tp, msgs in batches.items():
                for m in msgs:
                    counts[tp.topic] = counts.get(tp.topic, 0) + 1
                    if tp.topic not in samples:
                        try:
                            samples[tp.topic] = json.loads(m.value)
                        except Exception:
                            samples[tp.topic] = {"raw": m.value.decode(errors="replace")[:120]}
    finally:
        await consumer.stop()
    print(json.dumps({"counts": counts, "total": sum(counts.values()), "samples": samples}))


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:] or ["sal.recommendation", "sal.exposure"]))
