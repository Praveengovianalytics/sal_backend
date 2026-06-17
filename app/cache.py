"""Redis buffer/cache — read-through for the assembled customer-360 (sub-ms hot reads)."""
import json

import redis.asyncio as aioredis

from .config import settings

_redis: aioredis.Redis | None = None


async def init_cache() -> None:
    global _redis
    _redis = aioredis.from_url(settings.redis_url, decode_responses=True)


async def close_cache() -> None:
    if _redis is not None:
        await _redis.aclose()


async def cache_get(key: str):
    if _redis is None:
        return None
    raw = await _redis.get(key)
    return json.loads(raw) if raw else None


async def cache_set(key: str, value: dict, ttl: int | None = None) -> None:
    if _redis is None:
        return
    await _redis.set(key, json.dumps(value, default=str), ex=ttl or settings.cache_ttl_seconds)
