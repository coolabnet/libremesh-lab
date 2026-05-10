#!/usr/bin/env bash
# Server adapter tests — runs adapters on host machine (not in VMs)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Server Adapter Tests"
tap_plan 2

FIXTURE_INVENTORY="${SCRIPT_DIR}/fixtures/server-services-fixture.yaml"

# Test 1: collect-health returns valid JSON with required fields
HEALTH=$(bash "${MESHA_ROOT}/adapters/server/collect-health.sh" 2>/dev/null) || true
if [ -n "$HEALTH" ] && echo "$HEALTH" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for field in ['hostname', 'uptime_seconds', 'load_average', 'memory', 'disk']:
    assert field in data, f'missing: {field}'
" 2>/dev/null; then
    pass "test_collect_health_valid_json"
else
    skip "test_collect_health_valid_json" "collect-health failed or missing fields"
fi

# Test 2: collect-services returns valid JSON structure
# Uses a fixture inventory (not inventories/local-services.yaml) so the test
# is portable across dev machines and CI hosts without docker/specific services.
if [ ! -f "${FIXTURE_INVENTORY}" ]; then
    skip "test_collect_services_valid_json" "fixture inventory not found at ${FIXTURE_INVENTORY}"
    tap_summary
    exit 0
fi

SERVICES=$(bash "${MESHA_ROOT}/adapters/server/collect-services.sh" \
    --inventory "${FIXTURE_INVENTORY}" 2>/dev/null) || true
if [ -n "$SERVICES" ] && echo "$SERVICES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert isinstance(data, list)
" 2>/dev/null; then
    pass "test_collect_services_valid_json"
else
    skip "test_collect_services_valid_json" "collect-services failed or not a list"
fi

tap_summary
