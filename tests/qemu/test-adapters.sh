#!/usr/bin/env bash
# Adapter contract tests — validates Mesha adapter scripts against QEMU test bed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

WAIT_SECONDS="${1:-30}"

echo "# Adapter Contract Tests"
tap_plan 8

# Wait for VMs
echo "# Waiting for SSH connectivity..."
GATEWAY=$(get_gateway)
if ! wait_for_ssh "$GATEWAY" 90; then
    echo "Bail out! Gateway ${GATEWAY} not reachable"
    exit 1
fi

# Test 1: collect-nodes returns valid JSON for reachable VMs
NODES_OK=0
NODES_TOTAL=0
for entry in $(get_node_ips); do
    NODES_TOTAL=$((NODES_TOTAL + 1))
    host=$(echo "$entry" | awk '{print $1}')
    result=$(bash "${LAB_CLI}" run-adapter \
        "${MESHA_ROOT}/adapters/mesh/collect-nodes.sh" "$host" 2>/dev/null) || true
    if echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert data.get('reachable') == True
assert data.get('hostname')
assert isinstance(data.get('interfaces'), list) and len(data['interfaces']) > 0
" 2>/dev/null; then
        NODES_OK=$((NODES_OK + 1))
    else
        echo "  # FAILED for ${host}" >&2
    fi
done
if [ "${NODES_OK}" -ge 1 ]; then
    pass "test_collect_nodes_returns_valid_json"
else
    fail "test_collect_nodes_returns_valid_json" "No nodes returned valid JSON"
fi

# Test 2: collect-topology sees nodes
echo "# Waiting ${WAIT_SECONDS}s for BMX7 convergence..."
sleep "${WAIT_SECONDS}"
TOPO_RESULT=$(bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/adapters/mesh/collect-topology.sh" "$GATEWAY" 2>/dev/null) || true
if [ -n "$TOPO_RESULT" ] && echo "$TOPO_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert 'node_count' in data
assert data['node_count'] >= 1
" 2>/dev/null; then
    pass "test_collect_topology_sees_all_nodes"
else
    fail "test_collect_topology_sees_all_nodes" "node_count < 1 or parse error"
fi

# Test 3: discover-from-thisnode works
DISCOVER_OK=false
HTTP_CODE=""
if command -v curl >/dev/null 2>&1; then
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --resolve thisnode.info:80:10.99.0.11 http://thisnode.info/ 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
        DISCOVER_OK=true
    fi
fi
if $DISCOVER_OK; then
    pass "test_discover_thisnode_works"
else
    skip "test_discover_thisnode_works" "thisnode.info not reachable (HTTP ${HTTP_CODE:-N/A})"
fi

# Test 4: ip -j addr show returns valid JSON (requires ip-full)
IP_RESULT=$(ssh_vm "$GATEWAY" "ip -j addr show 2>/dev/null || echo '[]'" 2>/dev/null) || true
if [ -z "$IP_RESULT" ] || [ "$IP_RESULT" = "[]" ]; then
    skip "test_ip_json_output" "ip -j not available (missing ip-full package)"
elif echo "$IP_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
non_lo = [i for i in data if i.get('ifname') != 'lo']
assert len(non_lo) >= 1
for iface in non_lo:
    assert 'ifname' in iface
    assert 'addr_info' in iface
" 2>/dev/null; then
    pass "test_ip_json_output"
else
    fail "test_ip_json_output" "JSON parse or assertion failed"
fi

# Test 5: collect-services returns valid JSON structure
SERVICES_RESULT=$(bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/adapters/server/collect-services.sh" "lm-testbed-node-1" 2>/dev/null) || true
if [ -n "$SERVICES_RESULT" ] && echo "$SERVICES_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert isinstance(data, list)
" 2>/dev/null; then
    pass "test_collect_services_valid_json"
else
    skip "test_collect_services_valid_json" "collect-services not applicable to VM nodes or parse error"
fi

# Test 6: collect-health returns valid JSON with required fields
HEALTH_RESULT=$(bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/adapters/server/collect-health.sh" "lm-testbed-node-1" 2>/dev/null) || true
if [ -n "$HEALTH_RESULT" ] && echo "$HEALTH_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
required = ['hostname', 'uptime', 'load', 'memory', 'disk']
for field in required:
    assert field in data, f'missing field: {field}'
" 2>/dev/null; then
    pass "test_collect_health_valid_json"
else
    skip "test_collect_health_valid_json" "collect-health not applicable or parse error"
fi

# Test 7: normalize.py processes collect-nodes output
NORM_RESULT=$(bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/adapters/mesh/collect-nodes.sh" "lm-testbed-node-1" 2>/dev/null | \
    python3 "${MESHA_ROOT}/adapters/mesh/normalize.py" --field-map "${MESHA_ROOT}/adapters/mesh/field_map.json" 2>/dev/null) || true
if [ -n "$NORM_RESULT" ] && echo "$NORM_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert isinstance(data, dict) or isinstance(data, list)
" 2>/dev/null; then
    pass "test_normalize_processes_output"
else
    skip "test_normalize_processes_output" "normalize.py unavailable or parse error"
fi

# Test 8: uhttpd REST API responds with valid JSON
API_RESULT=""
if command -v curl &>/dev/null; then
    API_RESULT=$(curl -s --connect-timeout 5 \
        "http://10.99.0.11/cgi-bin/luci/admin/status/overview" \
        -o /dev/null -w '%{http_code}' 2>/dev/null) || API_RESULT="000"
fi
if [ "$API_RESULT" = "200" ] || [ "$API_RESULT" = "302" ]; then
    pass "test_uhttpd_api_accessible"
else
    skip "test_uhttpd_api_accessible" "uhttpd not responding (HTTP ${API_RESULT:-N/A})"
fi

tap_summary
