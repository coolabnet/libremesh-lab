#!/usr/bin/env bash
# start-mesh.sh — Main orchestrator for LibreMesh Lab
# Launches vwifi-server, sets up host networking, and boots 4 VMs

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="${REPO_ROOT}/run"
LOG_DIR="${RUN_DIR}/logs"
LOCK_DIR="${RUN_DIR}/testbed.lock"
TOPOLOGY_FILE="${REPO_ROOT}/config/topology.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults (overridden by topology.yaml if present)
BRIDGE_NAME="mesha-br0"
BRIDGE_IP="10.99.0.254/16"
TAP_PREFIX="mesha-tap"
NODE_COUNT=4
BASE_IMAGE="${REPO_ROOT}/images/libremesh-x86-64.ext4"
KERNEL_IMAGE="${REPO_ROOT}/images/generic-kernel.bin"

mkdir -p "${RUN_DIR}" "${LOG_DIR}"

# ─── Concurrent run protection (mkdir-based lock) ───
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_PID=$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo "unknown")
    echo "ERROR: Another test bed instance is running (PID ${LOCK_PID}, lock: ${LOCK_DIR})"
    exit 1
fi
echo $$ > "${LOCK_DIR}/pid"

# ─── Cleanup state ───
CLEANUP_DONE=0
declare -a QEMU_PIDS=()

cleanup() {
    if [ "$CLEANUP_DONE" -eq 1 ]; then
        return
    fi
    CLEANUP_DONE=1
    echo ""
    echo "=== Cleaning up test bed ==="

    # Kill QEMU VMs
    for pid_file in "${RUN_DIR}"/node-*.pid; do
        [ -f "$pid_file" ] || continue
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "  Stopping QEMU PID $pid..."
            kill "$pid" 2>/dev/null || true
            # Wait briefly for graceful shutdown
            for i in $(seq 1 10); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.5
            done
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$pid_file"
    done

    # Kill vwifi-server
    local vwifi_pid_file="${RUN_DIR}/vwifi-server.pid"
    if [ -f "$vwifi_pid_file" ]; then
        local vwifi_pid
        vwifi_pid=$(cat "$vwifi_pid_file")
        if kill -0 "$vwifi_pid" 2>/dev/null && ps -p "$vwifi_pid" -o comm= 2>/dev/null | grep -qx "vwifi-server"; then
            echo "  Stopping vwifi-server PID $vwifi_pid..."
            kill "$vwifi_pid" 2>/dev/null || true
        fi
        rm -f "$vwifi_pid_file"
    fi

    # Cleanup TAP devices
    for i in $(seq 0 $((NODE_COUNT - 1))); do
        local tap="${TAP_PREFIX}${i}"
        ip link set "$tap" down 2>/dev/null || true
        ip link set "$tap" nomaster 2>/dev/null || true
        ip tuntap del dev "$tap" mode tap 2>/dev/null || true
    done

    # Kill DHCP server (dnsmasq)
    local dhcp_pid_file="${RUN_DIR}/dnsmasq-dhcp.pid"
    if [ -f "$dhcp_pid_file" ]; then
        local dhcp_pid
        dhcp_pid=$(cat "$dhcp_pid_file")
        if kill -0 "$dhcp_pid" 2>/dev/null; then
            echo "  Stopping DHCP server PID $dhcp_pid..."
            kill "$dhcp_pid" 2>/dev/null || true
        fi
        rm -f "$dhcp_pid_file"
    fi

    # Delete bridge
    ip link set "${BRIDGE_NAME}" down 2>/dev/null || true
    ip link del "${BRIDGE_NAME}" 2>/dev/null || true

    # Remove serial/monitor sockets
    rm -f /tmp/node-*-serial.sock /tmp/node-*-monitor.sock 2>/dev/null

    # Remove lock
    rm -rf "$LOCK_DIR"

    echo "=== Cleanup complete ==="
}

trap cleanup EXIT INT TERM HUP

# ─── Parse topology (simple YAML key extraction) ───
parse_topology() {
    if [ ! -f "$TOPOLOGY_FILE" ]; then
        echo "WARN: topology.yaml not found, using defaults"
        return
    fi
    # Extract bridge_name and bridge_ip from YAML
    local bridge_name bridge_ip tap_prefix
    bridge_name=$(grep 'bridge_name:' "$TOPOLOGY_FILE" | head -1 | awk '{print $2}' | tr -d '"')
    bridge_ip=$(grep 'bridge_ip:' "$TOPOLOGY_FILE" | head -1 | awk '{print $2}' | tr -d '"')
    tap_prefix=$(grep 'tap_prefix:' "$TOPOLOGY_FILE" | head -1 | awk '{print $2}' | tr -d '"')

    [ -n "$bridge_name" ] && BRIDGE_NAME="$bridge_name"
    # Strip existing CIDR suffix before appending subnet mask
    [ -n "$bridge_ip" ] && BRIDGE_IP="${bridge_ip%%/*}/16"
    [ -n "$tap_prefix" ] && TAP_PREFIX="$tap_prefix"
}

# ─── Extract node definitions from topology ───
get_node_field() {
    local node_id="$1"
    local field="$2"
    # Parse the YAML section for the matching node id
    # Use word-boundary-aware matching to avoid e.g. "ip:" matching "bridge_ip:"
    awk -v id="$node_id" -v fld="$field" '
        /^    - id:/ { current_id=$3 }
        current_id == id && $0 ~ "(^| )(" fld ")" { gsub(/"/, "", $2); print $2; exit }
    ' "$TOPOLOGY_FILE"
}

# ─── Host networking setup ───
setup_host_networking() {
    echo "=== Setting up host networking ==="

    # Create bridge (idempotent)
    ip link add name "${BRIDGE_NAME}" type bridge 2>/dev/null || true
    ip link set "${BRIDGE_NAME}" type bridge stp_state 0
    ip link set "${BRIDGE_NAME}" type bridge forward_delay 0
    ip addr add "${BRIDGE_IP}" dev "${BRIDGE_NAME}" 2>/dev/null || true
    ip link set "${BRIDGE_NAME}" up

    # Create TAP devices and attach to bridge
    for i in $(seq 0 $((NODE_COUNT - 1))); do
        local tap="${TAP_PREFIX}${i}"
        echo "  Creating TAP device: ${tap}"
        ip tuntap add dev "$tap" mode tap user "$(whoami)" 2>/dev/null || true
        ip link set "$tap" master "${BRIDGE_NAME}" 2>/dev/null || true
        ip link set "$tap" up 2>/dev/null || true
    done

    echo "  Bridge ${BRIDGE_NAME}: $(ip -4 addr show "${BRIDGE_NAME}" | grep inet | awk '{print $2}')"

    # Start DHCP server on bridge for source-built images
    if command -v dnsmasq &>/dev/null; then
        echo "  Starting DHCP server on ${BRIDGE_NAME}..."
        # Kill any existing dnsmasq on this interface
        pkill -f "dnsmasq.*${BRIDGE_NAME}" 2>/dev/null || true
        sleep 0.5

        # Build --dhcp-host entries from topology for deterministic IP assignment
        # Each VM gets a fixed IP based on its MAC address, so configure-vms.sh
        # can reach all nodes at their expected IPs from first boot.
        local -a DHCP_HOST_OPTS=()
        if [ -f "$TOPOLOGY_FILE" ]; then
            for node_id in $(awk '/^    - id:/ {print $3}' "$TOPOLOGY_FILE"); do
                local node_mac node_ip
                node_mac=$(get_node_field "$node_id" "mac_mesh:")
                node_ip=$(get_node_field "$node_id" "ip:")
                if [ -n "$node_mac" ] && [ -n "$node_ip" ]; then
                    DHCP_HOST_OPTS+=(--dhcp-host="${node_mac},${node_ip}")
                fi
            done
        else
            # Fallback defaults
            DHCP_HOST_OPTS=(
                --dhcp-host="52:54:00:00:00:01,10.99.0.11"
                --dhcp-host="52:54:00:00:00:02,10.99.0.12"
                --dhcp-host="52:54:00:00:00:03,10.99.0.13"
                --dhcp-host="52:54:00:00:00:04,10.99.0.14"
            )
        fi

        dnsmasq \
            --keep-in-foreground \
            --no-hosts \
            --no-resolv \
            --bind-interfaces \
            --interface="${BRIDGE_NAME}" \
            --listen-address="${BRIDGE_IP%%/*}" \
            --dhcp-range=10.99.0.11,10.99.0.20,255.255.0.0,12h \
            "${DHCP_HOST_OPTS[@]}" \
            --dhcp-option=3,"${BRIDGE_IP%%/*}" \
            --dhcp-option=6,"${BRIDGE_IP%%/*}" \
            --pid-file="${RUN_DIR}/dnsmasq-dhcp.pid" \
            &
        local dhcp_pid=$!
        echo $dhcp_pid > "${RUN_DIR}/dnsmasq-dhcp.pid"
        sleep 1  # Wait for dnsmasq to bind
        echo "  DHCP server started (PID $dhcp_pid, range 10.99.0.11-20, ${#DHCP_HOST_OPTS[@]} host reservations)"
    else
        echo "  WARNING: dnsmasq not found — DHCP not available for source-built images"
    fi
}

# ─── KVM / TCG detection ───
detect_acceleration() {
    if [ -w /dev/kvm ]; then
        ACCEL="-enable-kvm"
        CPU="-cpu host"
        echo "=== KVM detected — using hardware acceleration ==="
    else
        ACCEL="-accel tcg"
        CPU="-cpu qemu64"
        export QEMU_TIMEOUT_MULTIPLIER=3
        echo "=== No KVM — using TCG (software emulation, slower) ==="
    fi
}

# ─── Pre-flight checks ───
preflight_checks() {
    echo "=== Pre-flight checks ==="

    if ! command -v qemu-system-x86_64 &>/dev/null; then
        echo "ERROR: qemu-system-x86_64 not found in PATH"
        exit 1
    fi
    echo "  qemu-system-x86_64: $(which qemu-system-x86_64)"

    if [ ! -f "${BASE_IMAGE}" ]; then
        echo "ERROR: Base image not found: ${BASE_IMAGE}"
        echo "  Run Phase 1 build pipeline first (scripts/qemu/build-libremesh-image.sh)"
        exit 1
    fi
    echo "  Base image: ${BASE_IMAGE} ($(stat -c%s "${BASE_IMAGE}" 2>/dev/null || stat -f%z "${BASE_IMAGE}") bytes)"
}

# ─── Launch a single VM ───
launch_vm() {
    local node_id="$1"
    local hostname="$2"
    local ip="$3"
    local tap_index="$4"
    local mac_mesh="$5"
    local mac_wan="$6"
    local ram_mb="$7"

    local overlay="${RUN_DIR}/node-${node_id}.qcow2"
    local pid_file="${RUN_DIR}/node-${node_id}.pid"

    echo "  [Node ${node_id}] ${hostname} (${ip}) — creating overlay..."
    rm -f "$overlay"
    qemu-img create -f qcow2 -b "${BASE_IMAGE}" -F raw "$overlay" >/dev/null

    # Build kernel boot args if prebuilt kernel exists
    local -a KERNEL_OPTS=()

    # Detect if image has its own bootloader (source-built images do)
    local HAS_BOOTLOADER=false
    if command -v file &>/dev/null; then
        # Source-built images have a partition table; prebuilt are raw ext4
        if file -L "${BASE_IMAGE}" | grep -q "DOS/MBR boot sector\|partition table"; then
            HAS_BOOTLOADER=true
        fi
    fi

    echo "  [Node ${node_id}] Kernel: ${KERNEL_IMAGE} (exists=$([ -f "${KERNEL_IMAGE}" ] && echo yes || echo no)), HAS_BOOTLOADER=${HAS_BOOTLOADER}"
    if [ -f "${KERNEL_IMAGE}" ] && [ "${HAS_BOOTLOADER}" = "false" ]; then
        KERNEL_OPTS+=(-kernel "${KERNEL_IMAGE}" -append "root=/dev/sda rootfstype=ext4 rootwait console=ttyS0")
        echo "  [Node ${node_id}] Using kernel boot"
    else
        echo "  [Node ${node_id}] Booting from image directly"
    fi

    # Add serial sockets for all nodes (needed for source-built image configuration)
    local serial_arg="unix:/tmp/node-${node_id}-serial.sock,server,nowait"

    echo "  [Node ${node_id}] Launching QEMU..."
    if [[ ${#KERNEL_OPTS[@]} -gt 0 ]]; then
        qemu-system-x86_64 \
            ${ACCEL} \
            -M q35 \
            ${CPU} \
            -smp 2 \
            -m "${ram_mb}M" \
            -nographic \
            -drive "file=${overlay},format=qcow2" \
            "${KERNEL_OPTS[@]}" \
            -device virtio-net-pci,netdev=mesh0,mac="${mac_mesh}" \
            -netdev "tap,id=mesh0,ifname=${TAP_PREFIX}${tap_index},script=no,downscript=no" \
            -device virtio-net-pci,netdev=wan0,mac="${mac_wan}" \
            -netdev user,id=wan0 \
            -serial "${serial_arg}" \
            &
    else
        qemu-system-x86_64 \
            ${ACCEL} \
            -M q35 \
            ${CPU} \
            -smp 2 \
            -m "${ram_mb}M" \
            -nographic \
            -drive "file=${overlay},format=qcow2" \
            -device virtio-net-pci,netdev=mesh0,mac="${mac_mesh}" \
            -netdev "tap,id=mesh0,ifname=${TAP_PREFIX}${tap_index},script=no,downscript=no" \
            -device virtio-net-pci,netdev=wan0,mac="${mac_wan}" \
            -netdev user,id=wan0 \
            -serial "${serial_arg}" \
            &
    fi
    local qemu_pid=$!
    echo "$qemu_pid" > "$pid_file"
    QEMU_PIDS+=("$qemu_pid")
    echo "  [Node ${node_id}] QEMU started (PID ${qemu_pid})"
}

# ─── Main ───
main() {
    echo "=========================================="
    echo " LibreMesh Lab Launcher"
    echo "=========================================="
    echo ""

    parse_topology
    preflight_checks
    detect_acceleration

    # Start vwifi-server
    echo ""
    echo "=== Starting vwifi-server ==="
    "${SCRIPT_DIR}/start-vwifi.sh"

    # Setup networking
    echo ""
    setup_host_networking

    # Launch VMs
    echo ""
    echo "=== Launching VMs ==="
    if [ -f "$TOPOLOGY_FILE" ]; then
        for node_id in $(awk '/^    - id:/ {print $3}' "$TOPOLOGY_FILE"); do
            local hostname ip tap_index mac_mesh mac_wan ram_mb
            hostname=$(get_node_field "$node_id" "hostname:")
            ip=$(get_node_field "$node_id" "ip:")
            tap_index=$(get_node_field "$node_id" "tap_index:")
            mac_mesh=$(get_node_field "$node_id" "mac_mesh:")
            mac_wan=$(get_node_field "$node_id" "mac_wan:")
            ram_mb=$(get_node_field "$node_id" "ram_mb:")
            ram_mb="${ram_mb:-256}"
            launch_vm "$node_id" "$hostname" "$ip" "$tap_index" "$mac_mesh" "$mac_wan" "$ram_mb"
        done
    else
        # Fallback defaults
        launch_vm 1 "lm-testbed-node-1" "10.99.0.11" 0 "52:54:00:00:00:01" "52:54:00:01:00:01" 256
        launch_vm 2 "lm-testbed-node-2" "10.99.0.12" 1 "52:54:00:00:00:02" "52:54:00:01:00:02" 256
        launch_vm 3 "lm-testbed-node-3" "10.99.0.13" 2 "52:54:00:00:00:03" "52:54:00:01:00:03" 256
        launch_vm 4 "lm-testbed-tester" "10.99.0.14" 3 "52:54:00:00:00:04" "52:54:00:01:00:04" 512
    fi

    echo ""
    echo "=========================================="
    echo " All VMs launched. Waiting for boot..."
    echo " Run configure-vms.sh to set up LibreMesh"
    echo " Run stop-mesh.sh to tear down"
    echo "=========================================="
    echo ""
    echo "VM PIDs: ${QEMU_PIDS[*]}"
    echo "Press Ctrl+C to stop all VMs and clean up."

    # Wait for any child process to exit (keeps script alive for trap)
    wait
}

main "$@"
