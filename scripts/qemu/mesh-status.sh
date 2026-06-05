#!/usr/bin/env bash
# mesh-status.sh — Status reporting for LibreMesh Lab
# Outputs JSON for programmatic consumption

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="${REPO_ROOT}/run"
TOPOLOGY_FILE="${REPO_ROOT}/config/topology.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/topology.sh"
lab_topology_load "${TOPOLOGY_FILE}"

# ─── Helper: check if SSH is reachable ───
check_ssh() {
    local ip="$1"
    local ssh_opts=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o BatchMode=yes
        -o ConnectTimeout=3
    )
    # Use key auth if available
    local ssh_key="${RUN_DIR}/ssh-keys/id_ed25519"
    if [[ -f "${ssh_key}" ]]; then
        ssh_opts+=(
            -o IdentitiesOnly=yes
            -o PreferredAuthentications=publickey
            -i "${ssh_key}"
        )
    fi
    ssh "${ssh_opts[@]}" "root@${ip}" "echo ok" &>/dev/null
}

# Build VM JSON entries
vm_json_entries=""
first_entry=1
for ((i = 0; i < NODE_COUNT; i++)); do
    node_id=$((i + 1))
    hostname="${NODE_HOSTNAMES[$i]}"
    ip="${NODE_IPS[$i]}"
    pid_file="${RUN_DIR}/node-${node_id}.pid"
    running=false
    ssh_ok=false

    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file" 2>/dev/null || true)
        # Check process existence via /proc (works regardless of process owner)
        # and verify the PID actually points at a QEMU process — without the
        # cmdline check, PID reuse after a QEMU exit could report a stale PID
        # as running if some other process happens to land on the same number.
        if [[ "$pid" =~ ^[0-9]+$ ]] \
           && [ -d "/proc/$pid" ] \
           && grep -q "qemu-system" "/proc/$pid/cmdline" 2>/dev/null; then
            running=true
            if check_ssh "$ip"; then
                ssh_ok=true
            fi
        fi
    fi

    if [ "$first_entry" -eq 1 ]; then
        first_entry=0
    else
        vm_json_entries="${vm_json_entries},"
    fi
    vm_json_entries="${vm_json_entries}
    {\"id\": ${node_id}, \"hostname\": \"${hostname}\", \"ip\": \"${ip}\", \"running\": ${running}, \"ssh_ok\": ${ssh_ok}}"
done

# ─── vwifi-server status ───
vwifi_running=false
vwifi_pid=0
vwifi_pid_file="${RUN_DIR}/vwifi-server.pid"
if [ -f "$vwifi_pid_file" ]; then
    vwifi_pid=$(cat "$vwifi_pid_file" 2>/dev/null || true)
    if [[ "$vwifi_pid" =~ ^[0-9]+$ ]] \
       && [ -d "/proc/$vwifi_pid" ] \
       && grep -q "vwifi-server" "/proc/$vwifi_pid/cmdline" 2>/dev/null; then
        vwifi_running=true
    else
        vwifi_pid=0
    fi
fi

# ─── Bridge status ───
bridge_exists=false
if command -v ip >/dev/null 2>&1 && ip link show "${BRIDGE_NAME}" &>/dev/null; then
    bridge_exists=true
fi

# ─── TAP devices ───
tap_json=""
first_tap=1
for ((i = 0; i < NODE_COUNT; i++)); do
    tap="${TAP_PREFIX}${i}"
    if [ "$first_tap" -eq 1 ]; then
        first_tap=0
    else
        tap_json="${tap_json}, "
    fi
    tap_json="${tap_json}\"${tap}\""
done

# ─── Output JSON ───
cat <<EOF
{
  "vm_count": ${NODE_COUNT},
  "vms": [${vm_json_entries}
  ],
  "vwifi_server": {"running": ${vwifi_running}, "pid": ${vwifi_pid}},
  "bridge": {"exists": ${bridge_exists}, "ip": "${BRIDGE_CIDR}"},
  "tap_devices": [${tap_json}]
}
EOF
