#!/usr/bin/env bash
# Phase-0 backend smoke test: exercises the MCP layer end-to-end against the seeded cube.
set -euo pipefail
BASE="${SAL_BACKEND_URL:-http://localhost:8081}"
CID="33333333-3333-3333-3333-333333333333"

echo "1) health"
curl -fsS "$BASE/health"; echo

echo "2) resolve_identity (msta_id → customer_id)"
curl -fsS -X POST "$BASE/mcp/resolve_identity" -H 'content-type: application/json' \
  -d '{"id_type":"msta_id","id_value":"msta_aisha_001"}'; echo

echo "3) assemble_context (3-lens bundle)"
curl -fsS -X POST "$BASE/mcp/assemble_context" -H 'content-type: application/json' \
  -d "{\"customer_id\":\"$CID\",\"intent\":\"recon\"}" | python3 -m json.tool | head -20

echo "4) consent gate — marketing (opted_out) must be 403"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/mcp/get_customer_360" \
  -H 'content-type: application/json' -H 'x-purpose: marketing' -d "{\"customer_id\":\"$CID\"}")
[ "$code" = "403" ] && echo "  OK (403)" || { echo "  FAIL (got $code)"; exit 1; }

echo "5) binding gate — unbound agent must be 403"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/mcp/assemble_context" \
  -H 'content-type: application/json' -H 'x-agent-code: rogue_agent' -d "{\"customer_id\":\"$CID\"}")
[ "$code" = "403" ] && echo "  OK (403)" || { echo "  FAIL (got $code)"; exit 1; }

echo "ALL SMOKE CHECKS PASSED"
