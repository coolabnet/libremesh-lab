#!/usr/bin/env bash
# Collect logs from QEMU test bed for CI artifact upload
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${REPO_ROOT}/run/logs"
SSH_CONFIG="${REPO_ROOT}/config/ssh-config.resolved"

mkdir -p "${LOG_DIR}"

echo "Collecting test bed logs..."

# Collect QEMU serial output (already written to files by start-mesh.sh)
echo "  Serial logs: $(ls "${LOG_DIR}"/node-*.serial.log 2>/dev/null | wc -l) files"

# Collect host networking state
{
    echo "=== Bridge ==="
    ip link show mesha-br0 2>/dev/null || echo "bridge not found"
    echo "=== TAP devices ==="
    for i in 0 1 2 3; do
        ip link show "mesha-tap${i}" 2>/dev/null || echo "mesha-tap${i} not found"
    done
} > "${LOG_DIR}/host-network.log" 2>&1

# Collect vwifi-server log
if [ -f "${REPO_ROOT}/run/vwifi-server.pid" ]; then
    VWIFI_PID=$(cat "${REPO_ROOT}/run/vwifi-server.pid")
    echo "vwifi-server PID: ${VWIFI_PID} ($(kill -0 "${VWIFI_PID}" 2>/dev/null && echo 'running' || echo 'stopped'))" \
        > "${LOG_DIR}/vwifi-server.log"
fi

# Collect VM logs via SSH (if VMs are reachable)
if [ ! -f "${SSH_CONFIG}" ]; then
    echo "WARN: SSH config not found at ${SSH_CONFIG} — skipping VM log collection"
    echo "  Run configure-vms.sh first to generate the SSH config"
else
    for entry in lm-testbed-node-1 lm-testbed-node-2 lm-testbed-node-3 lm-testbed-tester; do
        {
            echo "=== ${entry}: dmesg ==="
            ssh -F "${SSH_CONFIG}" -o ConnectTimeout=5 -o BatchMode=yes "root@${entry}" "dmesg" 2>&1 || echo "unreachable"
            echo ""
            echo "=== ${entry}: logread (last 50) ==="
            ssh -F "${SSH_CONFIG}" -o ConnectTimeout=5 -o BatchMode=yes "root@${entry}" "logread | tail -50" 2>&1 || echo "unreachable"
            echo ""
            echo "=== ${entry}: BMX7 status ==="
            ssh -F "${SSH_CONFIG}" -o ConnectTimeout=5 -o BatchMode=yes "root@${entry}" "bmx7 -c status 2>/dev/null || echo 'bmx7 not running'" 2>&1 || echo "unreachable"
        } > "${LOG_DIR}/${entry}.log" 2>&1
    done
fi

echo "Logs collected in ${LOG_DIR}/"
ls -la "${LOG_DIR}/"
