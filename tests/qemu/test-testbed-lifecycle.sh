#!/usr/bin/env bash
# Testbed lifecycle tests — stop, logs, status
# Destructive: test_stop_mesh_cleans_up stops the testbed.
# Gate behind RUN_LIFECYCLE_TESTS=1 to avoid accidental teardown.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Testbed Lifecycle Tests"
tap_plan 3


# Test 1: collect-logs captures output
LOG_DIR="${REPO_ROOT}/run/logs"
bash "${REPO_ROOT}/scripts/qemu/collect-logs.sh" >/dev/null 2>&1 || true
if [ -d "${LOG_DIR}" ] && [ "$(ls "${LOG_DIR}"/*.log 2>/dev/null | wc -l)" -ge 1 ]; then
    pass "test_collect_logs_captures_output"
else
    fail "test_collect_logs_captures_output" "no log files found in ${LOG_DIR}"
fi

# Test 2: mesh-status reports correctly
STATUS_OUTPUT=""
STATUS_EXIT=0
STATUS_OUTPUT="$(bash "${REPO_ROOT}/scripts/qemu/mesh-status.sh" 2>/dev/null)" || STATUS_EXIT=$?
if [ "${STATUS_EXIT}" -eq 0 ] && [ -n "${STATUS_OUTPUT}" ]; then
    VM_COUNT=$(echo "${STATUS_OUTPUT}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vm_count',0))" 2>/dev/null || echo "0")
    if [ "${VM_COUNT}" -ge 3 ]; then
        pass "test_mesh_status_reports_correctly"
    else
        fail "test_mesh_status_reports_correctly" "expected vm_count >= 3, got ${VM_COUNT}"
    fi
else
    fail "test_mesh_status_reports_correctly" "mesh-status.sh failed or returned empty"
fi

# Test 3: stop-mesh cleans up (destructive — only run when explicitly requested)
if [ "${RUN_LIFECYCLE_TESTS:-0}" = "1" ]; then
    sudo bash "${REPO_ROOT}/scripts/qemu/stop-mesh.sh" >/dev/null 2>&1 || true
    sleep 2

    CLEANUP_OK=true
    # Check no QEMU processes matching 'mesha'
    if pgrep -f "mesha" >/dev/null 2>&1; then
        CLEANUP_OK=false
    fi
    # Check no mesha-tap* TAP devices
    if ip link show 2>/dev/null | grep -q "mesha-tap"; then
        CLEANUP_OK=false
    fi
    # Check no mesha-br0 bridge
    if ip link show mesha-br0 >/dev/null 2>&1; then
        CLEANUP_OK=false
    fi
    # Check no stale PID files
    if ls "${REPO_ROOT}/run/"*.pid >/dev/null 2>&1; then
        CLEANUP_OK=false
    fi

    if [ "${CLEANUP_OK}" = true ]; then
        pass "test_stop_mesh_cleans_up"
    else
        fail "test_stop_mesh_cleans_up" "residual QEMU processes, TAP devices, bridge, or PID files remain"
    fi
else
    skip "test_stop_mesh_cleans_up" "set RUN_LIFECYCLE_TESTS=1 to run (destructive — stops testbed)"
fi

tap_summary
