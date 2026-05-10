#!/usr/bin/env bash
# Failure path tests — verifies graceful handling of error conditions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Failure Path Tests"
tap_plan 5

GATEWAY=$(get_gateway)

# Test 1: Adapter timeout on unreachable node
RESULT=""
RESULT_EXIT=0
RESULT="$(timeout 15 bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/adapters/mesh/collect-nodes.sh" "10.99.0.99" 2>/dev/null)" || RESULT_EXIT=$?
if [ "${RESULT_EXIT}" -ne 0 ] || [ -z "${RESULT}" ]; then
    pass "test_adapter_timeout_on_unreachable_node"
else
    # Non-empty output is also acceptable if it indicates failure
    if echo "${RESULT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert data.get('reachable') is not True
" 2>/dev/null; then
        pass "test_adapter_timeout_on_unreachable_node"
    else
        fail "test_adapter_timeout_on_unreachable_node" "expected non-zero exit or empty/unreachable output, got exit=${RESULT_EXIT}"
    fi
fi

# Test 2: Validate node unreachable
VALIDATE_OUTPUT=""
VALIDATE_EXIT=0
VALIDATE_OUTPUT="$(timeout 15 bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/skills/mesh-rollout/scripts/validate-node.sh" "10.99.0.99" 2>/dev/null)" || VALIDATE_EXIT=$?
if [ "${VALIDATE_EXIT}" -ne 0 ] && echo "${VALIDATE_OUTPUT}" | grep -qi "unreachable\|timed out\|cannot connect\|cannot reach"; then
    pass "test_validate_node_unreachable"
else
    fail "test_validate_node_unreachable" "expected exit 1 with unreachable message, got exit=${VALIDATE_EXIT}"
fi

# Test 3: Collect topology partial failure (one node rebooted mid-collection)
# Reboot node-3 to simulate partial failure, collect topology, then recover node-3
ssh_vm "lm-testbed-node-3" "reboot" 2>/dev/null || true
sleep 2

TOPO_RESULT=""
TOPO_RESULT="$(timeout 30 bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/adapters/mesh/collect-topology.sh" "$GATEWAY" 2>/dev/null)" || true

if [ -n "${TOPO_RESULT}" ]; then
    pass "test_collect_topology_partial_failure"
else
    fail "test_collect_topology_partial_failure" "collect-topology returned empty output during partial failure"
fi

# Recovery: wait up to 60s for node-3 SSH to return
RECOVERED=0
for _i in $(seq 1 12); do
    if ssh_vm "lm-testbed-node-3" "true" 2>/dev/null; then
        RECOVERED=1; break
    fi
    sleep 5
done
if [ "${RECOVERED}" -eq 0 ]; then
    echo "  # WARNING: node-3 did not recover in 60s; subsequent BMX7 tests may fail" >&2
else
    # Wait for BMX7 to reconverge with at least 2 peers visible from node-3
    wait_for_bmx7 "lm-testbed-node-3" 2 60 || true
fi

# Test 4: Adapter handles empty output gracefully
# Run collect-nodes against a host that accepts SSH but may return minimal data
EMPTY_EXIT=0
timeout 15 bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/adapters/mesh/collect-nodes.sh" "10.99.0.99" >/dev/null 2>&1 || EMPTY_EXIT=$?
# The test passes if it doesn't hang (we used timeout) and doesn't crash with a signal
if [ "${EMPTY_EXIT}" -ne 124 ]; then
    pass "test_adapter_handles_empty_output"
else
    fail "test_adapter_handles_empty_output" "adapter hung (timeout exit 124)"
fi

# Test 5: Check drift with no desired-state directory
# Temporarily move desired-state aside, run check-drift, verify error handling
DS_TARGET="${REPO_ROOT}/config/desired-state"
if [ -d "${DS_TARGET}" ]; then
    DS_BACKUP="$(mktemp -d /tmp/desired-state-backup-XXXXXX)"
    mv "${DS_TARGET}" "${DS_BACKUP}/desired-state"

    DRIFT_EXIT=0
    timeout 15 bash "${LAB_CLI}" run-adapter \
        "${MESHA_ROOT}/skills/mesh-rollout/scripts/check-drift.sh" --node "$GATEWAY" >/dev/null 2>&1 || DRIFT_EXIT=$?

    # Restore desired-state
    mv "${DS_BACKUP}/desired-state" "${DS_TARGET}"
    rmdir "${DS_BACKUP}"

    # Script should fail gracefully (non-zero exit, not a crash/signal)
    if [ "${DRIFT_EXIT}" -ne 0 ] && [ "${DRIFT_EXIT}" -ne 124 ]; then
        pass "test_check_drift_no_desired_state"
    else
        fail "test_check_drift_no_desired_state" "expected non-zero exit (not timeout), got ${DRIFT_EXIT}"
    fi
else
    skip "test_check_drift_no_desired_state" "desired-state directory not found at ${DS_TARGET}"
fi

tap_summary
