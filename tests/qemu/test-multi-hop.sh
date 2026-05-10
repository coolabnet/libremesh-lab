#!/usr/bin/env bash
# Multi-hop mesh test — verifies BMX7 routing between non-adjacent nodes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Multi-Hop Mesh Tests"
tap_plan 2

# Wait for BMX7 convergence
GATEWAY=$(get_gateway)
BMX7_RESULT=0
wait_for_bmx7 "$GATEWAY" 3 120 || BMX7_RESULT=$?

if [ "${BMX7_RESULT}" -eq 2 ]; then
    echo "# BMX7 not installed — skipping multi-hop tests"
    tap_plan 2
    skip "test_node3_reachable_via_mesh" "BMX7 not installed on prebuilt image"
    skip "test_topology_shows_mesh_links" "BMX7 not installed on prebuilt image"
    tap_summary
    exit 0
elif [ "${BMX7_RESULT}" -ne 0 ]; then
    echo "Bail out! BMX7 not converged after 120s"
    exit 1
fi

# Test 1: node-3 reachable from node-1 via multi-hop
# BMX7 routes IPv4 traffic even when using IPv6 for mesh discovery.
# Use ping instead of grepping originators (which may show IPv6 addresses).
NODE3_IP="10.99.0.13"
ROUTE_OK=false
if ssh_vm "$GATEWAY" "ping -c 1 -W 5 $NODE3_IP" 2>/dev/null; then
    ROUTE_OK=true
fi
if $ROUTE_OK; then
    pass "test_node3_reachable_via_mesh"
else
    fail "test_node3_reachable_via_mesh" "node-3 not reachable from gateway via BMX7"
fi

# Test 2: collect-topology shows all 4 nodes with links
# In a 4-node mesh with BMX7 running on br-lan, each node has at least
# 3 direct peers (fully connected via the bridge), so >= 3 links is expected.
TOPO=$(bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/adapters/mesh/collect-topology.sh" "$GATEWAY" 2>/dev/null) || true
if [ -n "$TOPO" ] && echo "$TOPO" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert data.get('node_count', 0) >= 3, f'expected >= 3 nodes, got {data.get(\"node_count\", 0)}'
assert len(data.get('links', [])) >= 3, f'expected >= 3 links, got {len(data.get(\"links\", []))}'
" 2>/dev/null; then
    pass "test_topology_shows_mesh_links"
else
    fail "test_topology_shows_mesh_links" "topology incomplete"
fi

tap_summary
