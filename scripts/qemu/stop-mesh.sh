#!/usr/bin/env bash
# stop-mesh.sh — Teardown script for LibreMesh Lab
# Idempotent: safe to run multiple times

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="${REPO_ROOT}/run"
LOCK_DIR="${RUN_DIR}/testbed.lock"
TOPOLOGY_FILE="${REPO_ROOT}/config/topology.yaml"

# Defaults
BRIDGE_NAME="mesha-br0"
TAP_PREFIX="mesha-tap"
NODE_COUNT=4

echo "=========================================="
echo " LibreMesh Lab Teardown"
echo "=========================================="

# Parse topology for bridge/tap names
if [ -f "$TOPOLOGY_FILE" ]; then
    _bn=$(grep 'bridge_name:' "$TOPOLOGY_FILE" | head -1 | awk '{print $2}' | tr -d '"')
    _tp=$(grep 'tap_prefix:' "$TOPOLOGY_FILE" | head -1 | awk '{print $2}' | tr -d '"')
    [ -n "$_bn" ] && BRIDGE_NAME="$_bn"
    [ -n "$_tp" ] && TAP_PREFIX="$_tp"
fi

cleaned_something=0

# ─── Kill processes from PID files ───
echo ""
echo "--- Stopping processes ---"

for pid_file in "${RUN_DIR}"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null)
    # Skip empty or invalid PID files
    [ -z "$pid" ] && { echo "  [$(basename "$pid_file" .pid)] Empty PID file, removing"; rm -f "$pid_file"; continue; }
    label=$(basename "$pid_file" .pid)

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
    if ip link show "$tap" &>/dev/null; then
        echo "  Removing ${tap}..."
        ip link set "$tap" down 2>/dev/null || true
        ip link set "$tap" nomaster 2>/dev/null || true
        ip tuntap del dev "$tap" mode tap 2>/dev/null || true
        cleaned_something=1
    else
        echo "  ${tap} not found (already cleaned)."
    fi
done

# ─── Delete bridge ───
echo ""
echo "--- Cleaning up bridge ---"

if ip link show "${BRIDGE_NAME}" &>/dev/null; then
    echo "  Removing bridge ${BRIDGE_NAME}..."
    ip link set "${BRIDGE_NAME}" down 2>/dev/null || true
    ip link del "${BRIDGE_NAME}" 2>/dev/null || true
    cleaned_something=1
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
