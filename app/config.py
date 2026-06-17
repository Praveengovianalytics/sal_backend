"""Backend settings (env-overridable with SAL_ prefix). Local-dev defaults point at the Docker infra."""
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SAL_", env_file=".env", extra="ignore")

    # App role (RLS-enforced); migrations use the superuser `sal`.
    db_dsn: str = "postgresql://sal_app:sal_app@localhost:5433/sal_cube"
    db_pool_min: int = 4
    db_pool_max: int = 32           # Phase 4: headroom for concurrent agents; raise the cap behind PgBouncer
    redis_url: str = "redis://localhost:6380/0"
    default_tenant_id: str = "11111111-1111-1111-1111-111111111111"
    cache_ttl_seconds: int = 60
    port: int = 8081

    # Phase 4 — event backbone (Kafka/Redpanda). Empty ⇒ outbox accumulates, relay is a no-op.
    kafka_bootstrap: str = ""          # e.g. "localhost:19092"
    kafka_topic_prefix: str = "sal."   # topics: sal.recommendation / sal.exposure / sal.outcome / sal.order
    # Phase 4 — vector RAG (Milvus Lite, embedded local file). Pluggable embedder.
    milvus_uri: str = "./sal_milvus.db"
    embed_provider: str = "stub"       # "stub" (deterministic lexical) | "anthropic"/"voyage" later
    embed_dim: int = 256
    rag_enabled: bool = True


settings = Settings()
