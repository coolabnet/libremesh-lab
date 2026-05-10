#!/usr/bin/env bash
# Run LibreMesh Lab test suites.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="fast"
NAMESPACE_PREFLIGHT="${LIBREMESH_LAB_NAMESPACE_PREFLIGHT:-${SCRIPT_DIR}/../../scripts/qemu/preflight-namespace.sh}"
NAMESPACE_TEST="${LIBREMESH_LAB_NAMESPACE_TEST:-${SCRIPT_DIR}/test-namespace-wmediumd.sh}"

# Optional: wait time for BMX7 convergence (seconds)
CONVERGE_WAIT="${CONVERGE_WAIT:-30}"

usage() {
    cat <<USAGE
Usage: run-all.sh [--suite fast|lab|adapter|lifecycle|namespace]

Suites:
  fast        Standalone checks, no VMs and no Mesha checkout required (default)
  lab         Tests that require an already running/configured QEMU lab
  adapter     Adapter tests that require a running lab and MESHA_ROOT
  lifecycle   Destructive start/stop/topology lifecycle tests; requires RUN_LIFECYCLE_TESTS=1
  namespace   Safe preflight by default; root hwsim/wmediumd smoke with RUN_NAMESPACE_TESTS=1
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --suite)
            if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
                echo "ERROR: --suite requires one of: fast, lab, adapter, lifecycle, namespace" >&2
                usage >&2
                exit 1
            fi
            SUITE="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

echo "=========================================="
echo "LibreMesh Lab Test Suite: ${SUITE}"
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

require_mesha_root_for_suite() {
    if [ -z "${MESHA_ROOT:-}" ]; then
        echo "ERROR: --suite ${SUITE} requires MESHA_ROOT=/path/to/mesha" >&2
        exit 1
    fi
    if [ ! -d "${MESHA_ROOT}" ]; then
        echo "ERROR: MESHA_ROOT does not exist: ${MESHA_ROOT}" >&2
        exit 1
    fi
}

case "${SUITE}" in
    fast)
        run_test_file "Fast CLI" "${SCRIPT_DIR}/test-fast-cli.sh"
        run_test_file "Run Adapter Wrapper" "${SCRIPT_DIR}/test-run-adapter-wrapper.sh"
        run_test_file "Namespace Preflight" "${SCRIPT_DIR}/test-namespace-preflight.sh"
        ;;
    lab)
        run_test_file "Mesh Protocols" "${SCRIPT_DIR}/test-mesh-protocols.sh"
        run_test_file "Rollback Node" "${SCRIPT_DIR}/test-rollback.sh"
        ;;
    adapter)
        require_mesha_root_for_suite
        run_test_file "Server Adapters" "${SCRIPT_DIR}/test-server-adapters.sh"
        run_test_file "Adapter Contract" "${SCRIPT_DIR}/test-adapters.sh" "${CONVERGE_WAIT}"
        run_test_file "Topology Manipulation" "${SCRIPT_DIR}/test-topology-manipulation.sh"
        run_test_file "Firmware Upgrade" "${SCRIPT_DIR}/test-firmware-upgrade.sh"
        run_test_file "Multi-Hop Mesh" "${SCRIPT_DIR}/test-multi-hop.sh"
        run_test_file "Validate Node" "${SCRIPT_DIR}/test-validate-node.sh"
        run_test_file "Config Drift" "${SCRIPT_DIR}/test-config-drift.sh"
        run_test_file "Stage Upgrade" "${SCRIPT_DIR}/test-stage-upgrade.sh"
        run_test_file "Rollout Dry-Run" "${SCRIPT_DIR}/test-rollout.sh"
        run_test_file "Maintenance Windows" "${SCRIPT_DIR}/test-maintenance.sh"
        run_test_file "Mesh Readonly" "${SCRIPT_DIR}/test-mesh-readonly.sh"
        run_test_file "Failure Paths" "${SCRIPT_DIR}/test-failure-paths.sh"
        ;;
    lifecycle)
        if [ "${RUN_LIFECYCLE_TESTS:-0}" != "1" ]; then
            echo "ERROR: --suite lifecycle is destructive; set RUN_LIFECYCLE_TESTS=1 to run it" >&2
            exit 1
        fi
        run_test_file "Testbed Lifecycle" "${SCRIPT_DIR}/test-testbed-lifecycle.sh"
        if [ -n "${MESHA_ROOT:-}" ] && [ -d "${MESHA_ROOT}" ]; then
            run_test_file "Topology Tests" "${SCRIPT_DIR}/test-topologies.sh"
        else
            echo "--- Skipping: Topology Tests (requires MESHA_ROOT) ---"
            echo ""
        fi
        ;;
    namespace)
        PREFLIGHT_EXIT=0
        echo "--- Running: Namespace Preflight ---"
        if bash "${NAMESPACE_PREFLIGHT}" 2>&1; then
            echo "Namespace preflight completed successfully."
        else
            PREFLIGHT_EXIT=$?
            echo "Namespace preflight reported missing requirements (exit ${PREFLIGHT_EXIT})." >&2
        fi
        echo ""

        if [ "${RUN_NAMESPACE_TESTS:-0}" != "1" ]; then
            echo "Namespace smoke skipped; set RUN_NAMESPACE_TESTS=1 on an isolated root-capable host to run it."
        elif [ "${PREFLIGHT_EXIT}" -ne 0 ]; then
            echo "ERROR: Namespace suite requested, but preflight requirements are missing." >&2
            OVERALL_RESULT=1
        else
            run_test_file "Namespace Wmediumd" "${NAMESPACE_TEST}"
        fi
        ;;
    *)
        echo "Unknown suite: ${SUITE}" >&2
        usage >&2
        exit 1
        ;;
esac

echo "=========================================="
echo "Results: ${TOTAL_PASS} passed, ${TOTAL_FAIL} failed"
if [ -n "${FAILED_TESTS}" ]; then
    echo "Failed:${FAILED_TESTS}"
fi
echo "=========================================="

exit $OVERALL_RESULT
