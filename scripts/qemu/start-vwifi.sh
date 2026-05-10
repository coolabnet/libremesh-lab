#!/usr/bin/env bash
# Compiles and launches vwifi-server from https://github.com/Raizo62/vwifi
# TCP mode with -u flag (use-port-in-hash for multi-VM)
# Server binds INADDR_ANY by default — no bind-address flag needed
# PID tracked in run/vwifi-server.pid

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VWIFI_DIR="${REPO_ROOT}/bin"
VWIFI_SRC="${REPO_ROOT}/src/vwifi"
PID_FILE="${REPO_ROOT}/run/vwifi-server.pid"
LOG_FILE="${REPO_ROOT}/run/logs/vwifi-server.log"
VWIFI_PORT="${VWIFI_PORT:-8212}"  # TCP primary port

mkdir -p "${VWIFI_DIR}" "${REPO_ROOT}/run" "${REPO_ROOT}/run/logs"

pid_is_vwifi_server() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    ps -p "$pid" -o comm= 2>/dev/null | grep -qx "vwifi-server"
}

# Check and clean up stale processes holding vwifi ports
clean_stale_vwifi() {
    # First check if PID file points to a live vwifi-server
    if [ -f "$PID_FILE" ]; then
        existing_pid=$(cat "$PID_FILE")
        if pid_is_vwifi_server "$existing_pid"; then
            echo "vwifi-server already running (PID ${existing_pid})"
            exit 0
        fi
        rm -f "$PID_FILE"
    fi

    # Check if any process is holding the vwifi TCP port
    if ss -tlnp 2>/dev/null | grep -q ":${VWIFI_PORT} "; then
        local stale_pid
        stale_pid=$(ss -tlnp 2>/dev/null | grep ":${VWIFI_PORT} " | grep -oP 'pid=\K[0-9]+' | head -1)
        if [ -n "$stale_pid" ] && pid_is_vwifi_server "$stale_pid"; then
            echo "Killing stale vwifi-server (PID ${stale_pid}) holding port ${VWIFI_PORT}"
            kill -9 "$stale_pid" 2>/dev/null || true
            sleep 1
        fi
    fi
}

clean_stale_vwifi

# Compile if needed
if [ ! -x "${VWIFI_DIR}/vwifi-server" ]; then
    echo "Compiling vwifi-server..."
    if [ ! -d "${VWIFI_SRC}" ]; then
        git clone https://github.com/Raizo62/vwifi.git "${VWIFI_SRC}"
    fi
    cd "${VWIFI_SRC}"
    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release
    make -j"$(nproc)"
    cp vwifi-server "${VWIFI_DIR}/vwifi-server"
    cp vwifi-ctrl "${VWIFI_DIR}/vwifi-ctrl" 2>/dev/null || true
    cp vwifi-add-interfaces "${VWIFI_DIR}/vwifi-add-interfaces" 2>/dev/null || true
fi

# Launch
echo "Starting vwifi-server (TCP mode, port ${VWIFI_PORT})..."
nohup "${VWIFI_DIR}/vwifi-server" -u -t "${VWIFI_PORT}" </dev/null >"${LOG_FILE}" 2>&1 &
VWIFI_PID=$!
echo "$VWIFI_PID" > "$PID_FILE"

# Wait for readiness
sleep 1
if kill -0 "$VWIFI_PID" 2>/dev/null; then
    echo "vwifi-server started (PID $VWIFI_PID)"
    echo "vwifi-server log: ${LOG_FILE}"
    echo "vwifi-server will be stopped by stop-mesh.sh or start-mesh.sh cleanup."
else
    echo "ERROR: vwifi-server failed to start"
    rm -f "$PID_FILE"
    exit 1
fi
