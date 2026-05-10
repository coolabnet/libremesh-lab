#!/usr/bin/env bash
# validate-adapters.sh — Adapter validation for the QEMU LibreMesh test bed
#
# Runs each adapter script against the test bed VMs and validates output.
# Produces TAP-compatible test results.
#
# Usage: validate-adapters.sh [--wait-seconds N]
#
# Options:
#   --wait-seconds N   Wait N seconds for BMX7 convergence before testing (default: 15)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="${REPO_ROOT}/scripts/qemu"
TESTBED_CONFIG="${REPO_ROOT}/config"

WAIT_SECONDS=15
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# ─── Parse arguments ───
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait-seconds)
            WAIT_SECONDS="${2:-15}"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--wait-seconds N]"
            echo ""
            echo "Validates adapter scripts against the QEMU test bed."
            echo "Produces TAP-compatible output."
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ─── TAP helpers ───
tap_plan() {
    echo "TAP version 13"
    echo "1..$1"
}

tap_ok() {
    local test_num="$1"
    local description="$2"
    echo "ok ${test_num} - ${description}"
    PASS_COUNT=$((PASS_COUNT + 1))
    TEST_COUNT=$((TEST_COUNT + 1))
}

tap_not_ok() {
    local test_num="$1"
    local description="$2"
    local diagnostic="${3:-}"
    echo "not ok ${test_num} - ${description}"
    if [[ -n "$diagnostic" ]]; then
        echo "  ---"
        echo "  message: ${diagnostic}"
        echo "  ..."
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TEST_COUNT=$((TEST_COUNT + 1))
}

# ─── Node hostnames for testing ───
declare -a NODE_HOSTNAMES=(
    "lm-testbed-node-1"
    "lm-testbed-node-2"
    "lm-testbed-node-3"
    "lm-testbed-tester"
)

GATEWAY_HOSTNAME="lm-testbed-node-1"

# ─── Prerequisite checks ───
SSH_CONFIG="${TESTBED_CONFIG}/ssh-config.resolved"
if [[ ! -f "$SSH_CONFIG" ]]; then
    SSH_CONFIG="${TESTBED_CONFIG}/ssh-config"
fi

check_prerequisites() {
    echo "# Checking prerequisites..."

    # Check SSH config
    if [[ ! -f "${TESTBED_CONFIG}/ssh-config" ]]; then
        echo "Bail out! SSH config template not found at ${TESTBED_CONFIG}/ssh-config"
        exit 1
    fi

    # Check inventories
    if [[ ! -f "${TESTBED_CONFIG}/inventories/mesh-nodes.yaml" ]]; then
        echo "Bail out! mesh-nodes.yaml not found at ${TESTBED_CONFIG}/inventories/mesh-nodes.yaml"
        exit 1
    fi

    # Check adapter scripts exist
    if [[ ! -f "${REPO_ROOT}/adapters/mesh/collect-nodes.sh" ]]; then
        echo "Bail out! collect-nodes.sh not found"
        exit 1
    fi
    if [[ ! -f "${REPO_ROOT}/adapters/mesh/collect-topology.sh" ]]; then
        echo "Bail out! collect-topology.sh not found"
        exit 1
    fi
    if [[ ! -f "${REPO_ROOT}/scripts/discover-from-thisnode.sh" ]]; then
        echo "Bail out! discover-from-thisnode.sh not found"
        exit 1
    fi

    # Check VMs are reachable via SSH
    echo "# Checking VM reachability..."
    local unreachable=0
    for hostname in "${NODE_HOSTNAMES[@]}"; do
        if ! ssh -F "$SSH_CONFIG" -o ConnectTimeout=5 -o BatchMode=yes "root@${hostname}" "true" 2>/dev/null; then
            echo "# WARNING: ${hostname} is not reachable"
            unreachable=$((unreachable + 1))
        fi
    done

    if [[ $unreachable -eq ${#NODE_HOSTNAMES[@]} ]]; then
        echo "Bail out! No VMs are reachable. Start the test bed first."
        exit 1
    fi

    echo "# Prerequisites OK"
}

# ─── Wait for BMX7 convergence ───
echo "# Waiting ${WAIT_SECONDS}s for BMX7 convergence..."
sleep "$WAIT_SECONDS"

check_prerequisites

# ─── Count tests: collect-nodes x4 + collect-topology x1 + discover-from-thisnode x1 = 6 ───
TOTAL_TESTS=6
tap_plan "$TOTAL_TESTS"

# ─── Test 1-4: collect-nodes.sh against each VM ───
echo ""
echo "# === collect-nodes.sh tests ==="

node_test_num=1
for hostname in "${NODE_HOSTNAMES[@]}"; do
    echo "# Testing collect-nodes.sh against ${hostname}..."

    OUTPUT=$("${SCRIPT_DIR}/run-testbed-adapter.sh" \
        "${REPO_ROOT}/adapters/mesh/collect-nodes.sh" \
        "$hostname" 2>/dev/null) || true

    # Validate JSON output
    if echo "$OUTPUT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        # Check reachable=true
        REACHABLE=$(echo "$OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reachable',False))" 2>/dev/null || echo "False")
        HOSTNAME_OUT=$(echo "$OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('hostname',''))" 2>/dev/null || echo "")
        INTERFACES=$(echo "$OUTPUT" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('interfaces',[])))" 2>/dev/null || echo "0")

        if [[ "$REACHABLE" == "True" ]] && [[ -n "$HOSTNAME_OUT" ]] && [[ "$INTERFACES" -gt 0 ]]; then
            tap_ok "$node_test_num" "collect-nodes ${hostname}: reachable, hostname present, interfaces non-empty"
        else
            DIAG="reachable=${REACHABLE}, hostname='${HOSTNAME_OUT}', interfaces=${INTERFACES}"
            tap_not_ok "$node_test_num" "collect-nodes ${hostname}: validation failed" "$DIAG"
        fi
    else
        tap_not_ok "$node_test_num" "collect-nodes ${hostname}: invalid JSON output" "Output was not valid JSON"
    fi

    node_test_num=$((node_test_num + 1))
done

# ─── Test 5: collect-topology.sh against gateway ───
echo ""
echo "# === collect-topology.sh test ==="
echo "# Testing collect-topology.sh against ${GATEWAY_HOSTNAME}..."

TOPO_OUTPUT=$("${SCRIPT_DIR}/run-testbed-adapter.sh" \
    "${REPO_ROOT}/adapters/mesh/collect-topology.sh" \
    "$GATEWAY_HOSTNAME" 2>/dev/null) || true

if echo "$TOPO_OUTPUT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    NODE_COUNT=$(echo "$TOPO_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('node_count',0))" 2>/dev/null || echo "0")

    if [[ "$NODE_COUNT" -ge 1 ]]; then
        tap_ok "5" "collect-topology ${GATEWAY_HOSTNAME}: node_count >= 1 (found ${NODE_COUNT})"
    else
        tap_not_ok "5" "collect-topology ${GATEWAY_HOSTNAME}: node_count is 0" "Expected at least 1 node in topology"
    fi
else
    tap_not_ok "5" "collect-topology ${GATEWAY_HOSTNAME}: invalid JSON output" "Output was not valid JSON"
fi

# ─── Test 6: discover-from-thisnode.sh ───
echo ""
echo "# === discover-from-thisnode.sh test ==="
echo "# Testing discover-from-thisnode.sh..."

# Ensure thisnode.info resolves (use testbed config if available)
if [[ -f "${REPO_ROOT}/run/host-aliases" ]]; then
    export HOSTALIASES="${REPO_ROOT}/run/host-aliases"
    echo "# Using HOSTALIASES=${HOSTALIASES}"
fi

DISCOVER_OUTPUT=$("${SCRIPT_DIR}/run-testbed-adapter.sh" \
    "${REPO_ROOT}/scripts/discover-from-thisnode.sh" 2>/dev/null) || {
    # discover-from-thisnode may fail if thisnode.info doesn't resolve
    DISCOVER_OUTPUT=""
}

# Validate discover output is JSON (if we got any)
if [[ -n "$DISCOVER_OUTPUT" ]]; then
    echo "$DISCOVER_OUTPUT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null || true
fi

# Check output files exist
LATEST_JSON="${REPO_ROOT}/exports/discovery/latest.json"
LATEST_SUMMARY="${REPO_ROOT}/exports/discovery/latest-summary.txt"

# With run-testbed-adapter, REPO_ROOT is remapped so exports go to testbed config
ALT_LATEST_JSON="${TESTBED_CONFIG}/exports/discovery/latest.json"
ALT_LATEST_SUMMARY="${TESTBED_CONFIG}/exports/discovery/latest-summary.txt"

FOUND_JSON=false
if [[ -f "$LATEST_JSON" ]] || [[ -f "$ALT_LATEST_JSON" ]]; then
    FOUND_JSON=true
fi

FOUND_SUMMARY=false
if [[ -f "$LATEST_SUMMARY" ]] || [[ -f "$ALT_LATEST_SUMMARY" ]]; then
    FOUND_SUMMARY=true
fi

if $FOUND_JSON && $FOUND_SUMMARY; then
    tap_ok "6" "discover-from-thisnode: output files exist"
else
    DIAG="latest.json=$FOUND_JSON, latest-summary.txt=$FOUND_SUMMARY"
    tap_not_ok "6" "discover-from-thisnode: output files missing" "$DIAG"
fi

# ─── Summary ───
echo ""
echo "# === Summary ==="
echo "# ${PASS_COUNT} passed, ${FAIL_COUNT} failed out of ${TEST_COUNT} tests"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi

exit 0
