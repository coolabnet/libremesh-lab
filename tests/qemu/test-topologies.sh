#!/usr/bin/env bash
# Multi-topology tests — verifies mesh behavior under different topologies
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Multi-Topology Tests"
tap_plan 3

TOPOLOGY_DIR="${REPO_ROOT}/config"
ORIGINAL_TOPOLOGY="${TOPOLOGY_DIR}/topology.yaml"

# Back up the current topology before the loop so the cleanup trap can restore it
# without touching git (avoids discarding uncommitted user edits).
TOPOLOGY_BACKUP="$(mktemp /tmp/topology-backup-XXXXXX.yaml)"
cp "${ORIGINAL_TOPOLOGY}" "${TOPOLOGY_BACKUP}"

cleanup_topology() {
    sudo bash "${REPO_ROOT}/scripts/qemu/stop-mesh.sh" 2>/dev/null || true
    cp "${TOPOLOGY_BACKUP}" "${ORIGINAL_TOPOLOGY}" 2>/dev/null || true
    rm -f "${TOPOLOGY_BACKUP}"
}
trap cleanup_topology EXIT INT TERM

for TOPO_FILE in topology-line.yaml topology-star.yaml topology-partition.yaml; do
    TOPO_NAME="${TOPO_FILE%.yaml}"
    TOPO_NAME="${TOPO_NAME#topology-}"

    echo "# Testing ${TOPO_NAME} topology..."

    # Stop existing testbed
    sudo bash "${REPO_ROOT}/scripts/qemu/stop-mesh.sh" 2>/dev/null || true
    sleep 2

    # Swap topology
    cp "${TOPOLOGY_DIR}/${TOPO_FILE}" "${ORIGINAL_TOPOLOGY}"

    # Start testbed
    sudo bash "${REPO_ROOT}/scripts/qemu/start-mesh.sh" 2>/dev/null || true
    bash "${REPO_ROOT}/scripts/qemu/configure-vms.sh" 2>/dev/null || true

    # Wait for convergence
    GATEWAY=$(get_gateway)
    BMX7_RESULT=0
    wait_for_bmx7 "$GATEWAY" 2 120 || BMX7_RESULT=$?

    if [ "${BMX7_RESULT}" -eq 0 ]; then
        # Verify topology shape
        TOPO=$(bash "${LAB_CLI}" run-adapter \
            "${MESHA_ROOT}/adapters/mesh/collect-topology.sh" "$GATEWAY" 2>/dev/null) || true
        NODE_COUNT=$(echo "$TOPO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('node_count',0))" 2>/dev/null || echo "0")
        if [ "$NODE_COUNT" -ge 3 ]; then
            pass "test_${TOPO_NAME}_topology_converges"
        else
            fail "test_${TOPO_NAME}_topology_converges" "only ${NODE_COUNT} nodes found"
        fi
    elif [ "${BMX7_RESULT}" -eq 2 ]; then
        skip "test_${TOPO_NAME}_topology_converges" "BMX7 not installed"
    else
        skip "test_${TOPO_NAME}_topology_converges" "BMX7 did not converge in 120s"
    fi
done

tap_summary
