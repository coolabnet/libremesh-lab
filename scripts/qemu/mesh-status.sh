#!/usr/bin/env bash
# mesh-status.sh — Status reporting for LibreMesh Lab
# Outputs JSON for programmatic consumption

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="${REPO_ROOT}/run"
TOPOLOGY_FILE="${REPO_ROOT}/config/topology.yaml"

# Defaults
BRIDGE_NAME="mesha-br0"
BRIDGE_IP="10.99.0.254/16"
TAP_PREFIX="mesha-tap"

# Parse topology for bridge/tap settings
if [ -f "$TOPOLOGY_FILE" ]; then
    _bn=$(grep 'bridge_name:' "$TOPOLOGY_FILE" | head -1 | awk '{print $2}' | tr -d '"')
    _bi=$(grep 'bridge_ip:' "$TOPOLOGY_FILE" | head -1 | awk '{print $2}' | tr -d '"')
    _tp=$(grep 'tap_prefix:' "$TOPOLOGY_FILE" | head -1 | awk '{print $2}' | tr -d '"')
    [ -n "$_bn" ] && BRIDGE_NAME="$_bn"
    [ -n "$_bi" ] && BRIDGE_IP="${_bi}/16"
    [ -n "$_tp" ] && TAP_PREFIX="$_tp"
fi

# ─── Helper: check if SSH is reachable ───
check_ssh() {
    local ip="$1"
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes \
        -o ConnectTimeout=3 \
        "root@${ip}" "echo ok" &>/dev/null
}

# ─── Gather VM status ───
# Node definitions: read from topology or use defaults
declare -a NODE_IPS=()
declare -a NODE_HOSTNAMES=()
NODE_COUNT=0

if [ -f "$TOPOLOGY_FILE" ]; then
    # Extract hostname/ip pairs from YAML node entries
    while IFS= read -r hostname; do
        NODE_HOSTNAMES+=("$hostname")
    done < <(grep 'hostname:' "$TOPOLOGY_FILE" | grep -v 'tap_prefix\|thisnode' | awk -F': ' '{print $2}' | tr -d '"')
    while IFS= read -r ip; do
        NODE_IPS+=("$ip")
    done < <(grep 'ip:' "$TOPOLOGY_FILE" | grep -v 'bridge_ip\|server_ip\|management' | awk -F': ' '{print $2}' | tr -d '"')
    NODE_COUNT=${#NODE_HOSTNAMES[@]}
fi

# Fallback defaults
if [ "$NODE_COUNT" -eq 0 ]; then
    NODE_HOSTNAMES=("lm-testbed-node-1" "lm-testbed-node-2" "lm-testbed-node-3" "lm-testbed-tester")
    NODE_IPS=("10.99.0.11" "10.99.0.12" "10.99.0.13" "10.99.0.14")
    NODE_COUNT=4
fi

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
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
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
    vwifi_pid=$(cat "$vwifi_pid_file")
    if kill -0 "$vwifi_pid" 2>/dev/null; then
        vwifi_running=true
    fi
fi

# ─── Bridge status ───
bridge_exists=false
if ip link show "${BRIDGE_NAME}" &>/dev/null; then
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
  "bridge": {"exists": ${bridge_exists}, "ip": "${BRIDGE_IP}"},
  "tap_devices": [${tap_json}]
}
EOF
