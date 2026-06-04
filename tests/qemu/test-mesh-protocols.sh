#!/usr/bin/env bash
# Mesh protocol tests — protocol-agnostic convergence and routing.
# Detects which routing protocol the image ships (babeld, bmx7, or batman-adv)
# and tests convergence/neighbors against that protocol, not a hardcoded one.
# This matches the babeld-first default in configure-vms.sh
# (lime-community.network.protocols='babeld bmx7') and the three
# bare-OpenWrt detection sites there, all of which prefer babeld.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Mesh Protocol Tests"
tap_plan 4

GATEWAY=$(get_gateway)
NODE2="lm-testbed-node-2"
NODE3="lm-testbed-node-3"
CONVERGE_TIMEOUT="${CONVERGE_WAIT:-90}"

# ─── Detect primary protocol on the gateway ──────────────────────────────────
echo "# Detecting mesh protocol on ${GATEWAY}..."
PROTO=$(detect_mesh_protocol "$GATEWAY")
echo "# Primary protocol: ${PROTO:-none}"

if [ -z "$PROTO" ] || [ "$PROTO" = "none" ]; then
    echo "# No mesh protocol installed — only generic routing can be tested"
    skip "test_mesh_protocol_active" "no mesh protocol on ${GATEWAY}"
    skip "test_mesh_protocol_gateway_active" "no mesh protocol on ${GATEWAY}"
    if ! wait_for_ssh "$NODE3" 5 2>/dev/null; then
        skip "test_mesh_routing_works" "node-3 unreachable"
    elif ssh_vm "$NODE3" "ping -c 3 -W 5 10.99.0.11" >/dev/null 2>&1; then
        pass "test_mesh_routing_works"
    else
        fail "test_mesh_routing_works" "node-3 cannot reach node-1"
    fi
    skip "test_mesh_protocol_restart_works" "no mesh protocol installed"
    tap_summary
    exit 0
fi

# ─── Wait for convergence of the detected protocol ───────────────────────────
echo "# Waiting for ${PROTO} convergence (${CONVERGE_TIMEOUT}s timeout)..."
CONVERGED=false
WAIT_START=$(date +%s)
# For batman-adv we need at least 2 originators (gateway + 1 other).
# For babeld we accept >=1 babel route as a convergence signal.
# For bmx7 we accept >=2 originators (gateway + 1 other).
THRESHOLD=1
if [ "$PROTO" = "bmx7" ] || [ "$PROTO" = "batman-adv" ]; then
    THRESHOLD=2
fi

while true; do
    NEIGH_COUNT=$(count_mesh_neighbors "$GATEWAY" 2>/dev/null || echo 0)
    NEIGH_COUNT=$(echo "${NEIGH_COUNT}" | tr -d '[:space:]')
    if [ "${NEIGH_COUNT:-0}" -ge "${THRESHOLD}" ] 2>/dev/null; then
        CONVERGED=true
        break
    fi
    NOW=$(date +%s)
    if (( NOW - WAIT_START >= CONVERGE_TIMEOUT )); then
        break
    fi
    sleep 5
done

if [ "$CONVERGED" = "true" ]; then
    echo "# ${PROTO} converged: ${NEIGH_COUNT} neighbors/originators on gateway"
else
    echo "# ${PROTO} did NOT converge within ${CONVERGE_TIMEOUT}s (last count: ${NEIGH_COUNT:-0})"
fi

# ─── Test 1: each mesh node shows the protocol is active ──────────────────────
# For bmx7/batman-adv this counts originators/neighbors (>=1 means the
# node sees at least one other node via the mesh). For babeld the count
# is binary (1 = daemon alive and listening on UDP 6696) because babeld
# over a wired br-lan legitimately installs 0 kernel routes — see
# count_mesh_neighbors() in tests/qemu/common.sh. The test name reflects
# that we are verifying the protocol is up, not counting peers.
ALL_ACTIVE_OK=true
ACTIVE_REPORT=""
while IFS=' ' read -r host _ip; do
    [ -z "$host" ] && continue
    count=$(count_mesh_neighbors "$host" 2>/dev/null || echo 0)
    count=$(echo "${count}" | tr -d '[:space:]')
    ACTIVE_REPORT="${ACTIVE_REPORT} ${host}=${count:-0}"
    if [ "${count:-0}" -lt 1 ] 2>/dev/null; then
        ALL_ACTIVE_OK=false
    fi
done < <(get_node_ips | head -3)
if $ALL_ACTIVE_OK; then
    pass "test_mesh_protocol_active"
else
    fail "test_mesh_protocol_active" "${PROTO} active per node:${ACTIVE_REPORT}"
fi

# ─── Test 2: gateway shows >=THRESHOLD protocol activity ─────────────────────
# For bmx7/batman-adv THRESHOLD=2 means the gateway sees at least one
# other node. For babeld THRESHOLD=1 means the daemon is up and serving
# (no neighbor count is meaningful in wired-bridge topology).
ORIG_COUNT=$(count_mesh_neighbors "$GATEWAY" 2>/dev/null || echo 0)
ORIG_COUNT=$(echo "${ORIG_COUNT}" | tr -d '[:space:]')
if [ "${ORIG_COUNT:-0}" -ge "${THRESHOLD}" ] 2>/dev/null; then
    pass "test_mesh_protocol_gateway_active"
else
    fail "test_mesh_protocol_gateway_active" "gateway sees ${ORIG_COUNT:-0}/${THRESHOLD} ${PROTO} signals"
fi

# ─── Test 3: mesh routing works (node-3 -> node-1) ──────────────────────────
PING_OK=false
if ssh_vm "$NODE3" "ping -c 3 -W 5 10.99.0.11" >/dev/null 2>&1; then
    PING_OK=true
fi
if ! $PING_OK && ssh_vm "$NODE3" "echo test | nc -w 3 10.99.0.11 22 2>/dev/null | head -1" 2>/dev/null | grep -qi 'dropbear\|ssh'; then
    PING_OK=true
fi
if $PING_OK; then
    pass "test_mesh_routing_works"
else
    fail "test_mesh_routing_works" "node-3 cannot reach node-1 (ping and nc both failed)"
fi

# ─── Test 4: protocol restart — stop and restart on a relay node ────────────
# Note: this verifies the protocol can be cleanly restarted (signal handling,
# interface rebind) on the same node. It is not a true cross-protocol failover
# test; for that, configure both bmx7 and babeld on the image and verify the
# secondary takes over when the primary is killed.
echo "# Testing ${PROTO} restart on ${NODE2}..."
PROTO_BEFORE=$(detect_mesh_protocol "$NODE2")
ssh_vm "$NODE2" "killall bmx7 babeld batmand 2>/dev/null; true" || true
sleep 2
restart_mesh_protocol "$NODE2"
sleep 8
PROTO_AFTER=$(detect_mesh_protocol "$NODE2")
case "${PROTO}" in
    babeld) PROTO_PROCESS="babeld" ;;
    bmx7) PROTO_PROCESS="bmx7" ;;
    batman-adv) PROTO_PROCESS="batmand" ;;
    *) PROTO_PROCESS="" ;;
esac
if [ "${PROTO_BEFORE}" != "${PROTO_AFTER}" ]; then
    fail "test_mesh_protocol_restart_works" "protocol changed: ${PROTO_BEFORE} -> ${PROTO_AFTER}"
elif [ -z "${PROTO_PROCESS}" ] || ! ssh_vm "$NODE2" "pgrep -x ${PROTO_PROCESS} >/dev/null 2>&1 || pgrep -f /usr/sbin/${PROTO_PROCESS} >/dev/null 2>&1" 2>/dev/null; then
    fail "test_mesh_protocol_restart_works" "${PROTO} not running on ${NODE2} after restart"
elif ! ssh_vm "$NODE2" "ping -c 1 -W 5 10.99.0.11" >/dev/null 2>&1; then
    fail "test_mesh_protocol_restart_works" "${NODE2} cannot reach gateway after ${PROTO} restart"
else
    pass "test_mesh_protocol_restart_works"
fi

tap_summary
