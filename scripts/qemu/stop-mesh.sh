#!/usr/bin/env bash
# stop-mesh.sh — Teardown script for LibreMesh Lab
# Idempotent: safe to run multiple times

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="${REPO_ROOT}/run"
LOCK_DIR="${RUN_DIR}/testbed.lock"
TOPOLOGY_FILE="${REPO_ROOT}/config/topology.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/topology.sh"
lab_topology_load "${TOPOLOGY_FILE}"

echo "=========================================="
echo " LibreMesh Lab Teardown"
echo "=========================================="

cleaned_something=0
have_ip=0
if command -v ip >/dev/null 2>&1; then
    have_ip=1
fi

# ─── Kill processes from PID files ───
echo ""
echo "--- Stopping processes ---"

for pid_file in "${RUN_DIR}"/node-*.pid "${RUN_DIR}/vwifi-server.pid" "${RUN_DIR}/dnsmasq-dhcp.pid"; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true)
    # Skip empty or invalid PID files
    label=$(basename "$pid_file" .pid)
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        echo "  [${label}] Empty or invalid PID file, removing"
        rm -f "$pid_file"
        cleaned_something=1
        continue
    fi

    if kill -0 "$pid" 2>/dev/null; then
        echo "  [${label}] Sending SIGTERM to PID ${pid}..."
        kill "$pid" 2>/dev/null || true

        # Wait up to 5 seconds for graceful termination
        local_wait=0
        while [ $local_wait -lt 10 ]; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
            local_wait=$((local_wait + 1))
        done

        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            echo "  [${label}] Sending SIGKILL to PID ${pid}..."
            kill -9 "$pid" 2>/dev/null || true
        fi
        echo "  [${label}] Stopped."
    else
        echo "  [${label}] PID ${pid} not running (stale PID file)."
    fi

    rm -f "$pid_file"
    cleaned_something=1
done

# ─── Cleanup TAP devices ───
echo ""
echo "--- Cleaning up TAP devices ---"

for i in $(seq 0 $((NODE_COUNT - 1))); do
    tap="${TAP_PREFIX}${i}"
    if [ "$have_ip" -eq 1 ] && ip link show "$tap" &>/dev/null; then
        echo "  Removing ${tap}..."
        ip link set "$tap" down 2>/dev/null || true
        ip link set "$tap" nomaster 2>/dev/null || true
        ip tuntap del dev "$tap" mode tap 2>/dev/null || true
        cleaned_something=1
    elif [ "$have_ip" -eq 0 ]; then
        echo "  ip command not found; skipping ${tap}."
    else
        echo "  ${tap} not found (already cleaned)."
    fi
done

# ─── Delete bridge ───
echo ""
echo "--- Cleaning up bridge ---"

if [ "$have_ip" -eq 1 ] && ip link show "${BRIDGE_NAME}" &>/dev/null; then
    echo "  Removing bridge ${BRIDGE_NAME}..."
    ip link set "${BRIDGE_NAME}" down 2>/dev/null || true
    ip link del "${BRIDGE_NAME}" 2>/dev/null || true
    cleaned_something=1
elif [ "$have_ip" -eq 0 ]; then
    echo "  ip command not found; skipping bridge cleanup."
else
    echo "  Bridge ${BRIDGE_NAME} not found (already cleaned)."
fi

# ─── Remove qcow2 overlays ───
echo ""
echo "--- Removing qcow2 overlays ---"

count=0
for overlay in "${RUN_DIR}"/node-*.qcow2; do
    [ -f "$overlay" ] || continue
    rm -f "$overlay"
    echo "  Removed $(basename "$overlay")"
    count=$((count + 1))
    cleaned_something=1
done
[ "$count" -eq 0 ] && echo "  No overlays found."

# ─── Remove lock file ───
if [ -d "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR"
    echo ""
    echo "  Removed lock directory."
    cleaned_something=1
fi

# ─── Summary ───
echo ""
if [ "$cleaned_something" -eq 1 ]; then
    echo "=========================================="
    echo " Teardown complete — resources cleaned up."
    echo "=========================================="
else
    echo "=========================================="
    echo " Nothing to clean up (already clean)."
    echo "=========================================="
fi
