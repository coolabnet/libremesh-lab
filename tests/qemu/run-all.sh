#!/usr/bin/env bash
# Run all QEMU integration tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional: wait time for BMX7 convergence (seconds)
CONVERGE_WAIT="${CONVERGE_WAIT:-30}"

echo "=========================================="
echo "LibreMesh Lab QEMU Integration Test Suite"
echo "=========================================="
echo ""

OVERALL_RESULT=0
FAILED_TESTS=""
TOTAL_PASS=0
TOTAL_FAIL=0

run_test_file() {
    local name="$1"
    local file="$2"
    shift 2
    echo "--- Running: ${name} ---"
    if bash "$file" "$@" 2>&1; then
        TOTAL_PASS=$((TOTAL_PASS + 1))
        echo "  [PASS] ${name}"
    else
        OVERALL_RESULT=1
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        FAILED_TESTS="${FAILED_TESTS} ${name}"
        echo "  [FAIL] ${name}"
    fi
    echo ""
}

# Run each test file
# Server adapters first (no VMs needed)
run_test_file "Server Adapters" "${SCRIPT_DIR}/test-server-adapters.sh"

# Core adapter and protocol tests (require running testbed)
run_test_file "Adapter Contract" "${SCRIPT_DIR}/test-adapters.sh" "${CONVERGE_WAIT}"
run_test_file "Mesh Protocols" "${SCRIPT_DIR}/test-mesh-protocols.sh"
run_test_file "Validate Node" "${SCRIPT_DIR}/test-validate-node.sh"
run_test_file "Config Drift" "${SCRIPT_DIR}/test-config-drift.sh"
run_test_file "Topology Manipulation" "${SCRIPT_DIR}/test-topology-manipulation.sh"
run_test_file "Firmware Upgrade" "${SCRIPT_DIR}/test-firmware-upgrade.sh"
run_test_file "Multi-Hop Mesh" "${SCRIPT_DIR}/test-multi-hop.sh"

# Skill script tests (dry-run only — no destructive changes)
run_test_file "Stage Upgrade" "${SCRIPT_DIR}/test-stage-upgrade.sh"
run_test_file "Rollout Dry-Run" "${SCRIPT_DIR}/test-rollout.sh"
run_test_file "Maintenance Windows" "${SCRIPT_DIR}/test-maintenance.sh"
run_test_file "Mesh Readonly" "${SCRIPT_DIR}/test-mesh-readonly.sh"

# Failure path and robustness tests
run_test_file "Failure Paths" "${SCRIPT_DIR}/test-failure-paths.sh"

# Rollback test (modifies node config — restores via qcow2 snapshot)
run_test_file "Rollback Node" "${SCRIPT_DIR}/test-rollback.sh"

# Lifecycle tests (destructive — stops testbed; gated behind RUN_LIFECYCLE_TESTS=1)
run_test_file "Testbed Lifecycle" "${SCRIPT_DIR}/test-testbed-lifecycle.sh"

echo "=========================================="
echo "Results: ${TOTAL_PASS} passed, ${TOTAL_FAIL} failed"
if [ -n "${FAILED_TESTS}" ]; then
    echo "Failed:${FAILED_TESTS}"
fi
echo "=========================================="

exit $OVERALL_RESULT
