"""RIM order-submission adapter (stub for local dev). Cloud: real RIM/MTPOS API + circuit breakers."""

def submit(*, seed: str, boid, total) -> dict:
    # Deterministic external order reference; real RIM returns an order id + accept/reject.
    return {"external_ref": "RIM-" + seed.replace("-", "")[:10].upper(), "accepted": True, "boid": boid, "total": total}
