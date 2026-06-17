"""Postgres access. Connects as the RLS-enforced `sal_app` role and applies tenant + purpose
per request via SET LOCAL (set_config), so row-level security and consent scoping are honoured."""
from contextlib import asynccontextmanager

import asyncpg

from .config import settings

_pool: asyncpg.Pool | None = None


async def init_pool() -> None:
    global _pool
    # statement_cache_size=0 keeps the pool compatible with PgBouncer transaction pooling (scale path);
    # harmless against a direct Postgres connection.
    _pool = await asyncpg.create_pool(
        settings.db_dsn, min_size=settings.db_pool_min, max_size=settings.db_pool_max,
        statement_cache_size=0,
    )


async def close_pool() -> None:
    if _pool is not None:
        await _pool.close()


def get_pool() -> asyncpg.Pool:
    assert _pool is not None, "pool not initialised"
    return _pool


async def run_audit(query: str, *args) -> None:
    """Write an audit row on its OWN connection (autocommit) so it persists even when the request
    transaction rolls back (e.g. on a consent denial / 403). agent_runs has no RLS."""
    assert _pool is not None, "pool not initialised"
    async with _pool.acquire() as conn:
        await conn.execute(query, *args)


@asynccontextmanager
async def tenant_conn(tenant_id: str, purpose: str | None = None):
    """Yield a connection inside a transaction with app.current_tenant (+ optional sal.purpose) set
    locally — the values RLS policies read. Fail-secure: no tenant ⇒ RLS returns no rows."""
    assert _pool is not None, "pool not initialised"
    async with _pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('app.current_tenant', $1, true)", tenant_id)
            if purpose:
                await conn.execute("SELECT set_config('sal.purpose', $1, true)", purpose)
            yield conn
