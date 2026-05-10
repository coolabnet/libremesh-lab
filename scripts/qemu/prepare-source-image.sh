#!/usr/bin/env bash
# prepare-source-image.sh — Pre-bake SSH keys and network config into source-built flat image
#
# Mounts the source-built flat image and injects:
#   - SSH public key into /root/.ssh/authorized_keys and /etc/dropbear/authorized_keys
#   - DHCP network config (dnsmasq assigns IPs by MAC on bridge)
#   - Empty root password
#   - Dropbear configured for password + root login
#   - /sbin/service shim (needed by mesha adapters)
#
# This eliminates the dropbear blank-password-auth problem by enabling
# SSH key auth from first boot. dnsmasq on the bridge assigns deterministic IPs
# based on MAC address (configured in start-mesh.sh with --dhcp-host entries).
#
# Usage:
#   ./prepare-source-image.sh [OPTIONS]
#
# Options:
#   -h, --help          — Show this help text
#   --image <path>      — Flat image path (default: auto-detect)
#   --ssh-key <path>    — SSH public key (default: run/ssh-keys/id_rsa.pub)
#   --force             — Re-prepare even if image appears already prepared

set -euo pipefail

# ─── Help ───────────────────────────────────────────────────────────────────────
show_help() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

IMAGE_PATH=""
SSH_KEY_PATH=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help ;;
        --image)   shift; IMAGE_PATH="${1:-}"; [[ -z "${IMAGE_PATH}" ]] && { echo "[ERROR] --image requires a value" >&2; exit 1; } ;;
        --ssh-key) shift; SSH_KEY_PATH="${1:-}"; [[ -z "${SSH_KEY_PATH}" ]] && { echo "[ERROR] --ssh-key requires a value" >&2; exit 1; } ;;
        --force)   FORCE=true ;;
        *)         echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# ─── Configuration ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
REPO_ROOT="$(cd "${REPO_ROOT}" && pwd)"

IMAGE_DIR="${REPO_ROOT}/images"
IMAGE_PATH="${IMAGE_PATH:-${IMAGE_DIR}/libremesh-x86-64-source-built-flat.img}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${REPO_ROOT}/run/ssh-keys/id_rsa.pub}"
SSH_KEY_DIR="${REPO_ROOT}/run/ssh-keys"

# ─── Helpers ────────────────────────────────────────────────────────────────────
log() { echo "[prepare-source-image] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

# ─── Preflight ──────────────────────────────────────────────────────────────────
[[ -f "${IMAGE_PATH}" ]] || die "Flat image not found: ${IMAGE_PATH}

Build it first:
  bash scripts/qemu/build-libremesh-image.sh --flat-only"

# Verify it's actually a flat image (raw ext4, no partition table)
if file -L "${IMAGE_PATH}" | grep -q "DOS/MBR boot sector"; then
    die "Image appears to be a combined image (has partition table), not a flat image.

Use the flat image instead:
  ${IMAGE_DIR}/libremesh-x86-64-source-built-flat.img

Or build it:
  bash scripts/qemu/build-libremesh-image.sh --flat-only"
fi

# ─── Generate SSH key pair if needed ────────────────────────────────────────────
if [[ ! -f "${SSH_KEY_PATH}" ]]; then
    log "SSH key not found, generating RSA key pair..."
    mkdir -p "${SSH_KEY_DIR}"
    ssh-keygen -t rsa -b 2048 -f "${SSH_KEY_DIR}/id_rsa" -N "" -C "mesha-testbed" >/dev/null
    log "  Generated: ${SSH_KEY_DIR}/id_rsa"
fi

PUBLIC_KEY="$(cat "${SSH_KEY_PATH}")"

# ─── Cleanup trap ───────────────────────────────────────────────────────────────
MOUNT_POINT=""

cleanup() {
    if [[ -n "${MOUNT_POINT}" ]] && mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        log "Unmounting ${MOUNT_POINT}..."
        sudo umount "${MOUNT_POINT}" || true
    fi
    if [[ -n "${MOUNT_POINT}" ]] && [[ -d "${MOUNT_POINT}" ]]; then
        rmdir "${MOUNT_POINT}" 2>/dev/null || true
    fi
    # Release loop device if we allocated one
    if [[ -n "${LOOP_DEV:-}" ]] && [[ -e "${LOOP_DEV}" ]]; then
        sudo losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─── Mount flat image ───────────────────────────────────────────────────────────
MOUNT_POINT="$(mktemp -d /tmp/source-rootfs.XXXXXX)"
log "Mounting flat image at ${MOUNT_POINT}..."

# Flat image is raw ext4, mount directly with loop
sudo mount -o loop "${IMAGE_PATH}" "${MOUNT_POINT}"

# ─── Check if already prepared ──────────────────────────────────────────────────
if [[ -f "${MOUNT_POINT}/root/.ssh/authorized_keys" ]] && ! ${FORCE}; then
    EXISTING_KEY="$(sudo head -1 "${MOUNT_POINT}/root/.ssh/authorized_keys" 2>/dev/null || true)"
    if echo "${EXISTING_KEY}" | grep -qF "$(echo "${PUBLIC_KEY}" | awk '{print $2}')"; then
        log "Image already prepared (SSH key found). Use --force to re-prepare."
        log "Unmounting..."
        sudo umount "${MOUNT_POINT}"
        MOUNT_POINT=""
        exit 0
    fi
fi

# ─── Inject SSH public key ──────────────────────────────────────────────────────
log "Injecting SSH public key..."

# /root/.ssh/authorized_keys
sudo mkdir -p "${MOUNT_POINT}/root/.ssh"
if [[ -f "${MOUNT_POINT}/root/.ssh/authorized_keys" ]]; then
    EXISTING="$(sudo cat "${MOUNT_POINT}/root/.ssh/authorized_keys" 2>/dev/null || true)"
    if echo "${EXISTING}" | grep -qF "$(echo "${PUBLIC_KEY}" | awk '{print $2}')"; then
        log "  /root/.ssh/authorized_keys already contains the key — skipping"
    else
        echo "${PUBLIC_KEY}" | sudo tee -a "${MOUNT_POINT}/root/.ssh/authorized_keys" > /dev/null
        sudo chmod 600 "${MOUNT_POINT}/root/.ssh/authorized_keys"
        log "  Appended to /root/.ssh/authorized_keys"
    fi
else
    echo "${PUBLIC_KEY}" | sudo tee "${MOUNT_POINT}/root/.ssh/authorized_keys" > /dev/null
    sudo chmod 600 "${MOUNT_POINT}/root/.ssh/authorized_keys"
    log "  Written to /root/.ssh/authorized_keys"
fi
sudo chmod 700 "${MOUNT_POINT}/root/.ssh"

# /etc/dropbear/authorized_keys (for dropbear key auth)
sudo mkdir -p "${MOUNT_POINT}/etc/dropbear"
if [[ -f "${MOUNT_POINT}/etc/dropbear/authorized_keys" ]]; then
    EXISTING_DB="$(sudo cat "${MOUNT_POINT}/etc/dropbear/authorized_keys" 2>/dev/null || true)"
    if echo "${EXISTING_DB}" | grep -qF "$(echo "${PUBLIC_KEY}" | awk '{print $2}')"; then
        log "  /etc/dropbear/authorized_keys already contains the key — skipping"
    else
        echo "${PUBLIC_KEY}" | sudo tee -a "${MOUNT_POINT}/etc/dropbear/authorized_keys" > /dev/null
        sudo chmod 600 "${MOUNT_POINT}/etc/dropbear/authorized_keys"
        log "  Appended to /etc/dropbear/authorized_keys"
    fi
else
    echo "${PUBLIC_KEY}" | sudo tee "${MOUNT_POINT}/etc/dropbear/authorized_keys" > /dev/null
    sudo chmod 600 "${MOUNT_POINT}/etc/dropbear/authorized_keys"
    log "  Written to /etc/dropbear/authorized_keys"
fi

# ─── Configure network (DHCP on br-lan) ─────────────────────────────────────────
# Use DHCP because all 4 VMs share the same base image.
# dnsmasq on the bridge assigns deterministic IPs based on MAC address
# (configured in start-mesh.sh with --dhcp-host entries).
log "Configuring network (DHCP on br-lan)..."

# Check if network config already matches
NET_FILE="${MOUNT_POINT}/etc/config/network"
if [[ -f "${NET_FILE}" ]] && sudo grep -q "option proto '"'"'dhcp'"'"'" "${NET_FILE}" 2>/dev/null \
   && sudo grep -q "option name '"'"'br-lan'"'"'" "${NET_FILE}" 2>/dev/null; then
    log "  Network config already has DHCP on br-lan — skipping"
else
    sudo tee "${NET_FILE}" > /dev/null << 'NETEOF'
config interface 'loopback'
    option device 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config globals 'globals'
    option ula_prefix 'fd00:dead:beef::/48'

config device
    option name 'br-lan'
    option type 'bridge'
    list ports 'eth0'

config interface 'lan'
    option device 'br-lan'
    option proto 'dhcp'
NETEOF
    log "  Network: DHCP on br-lan (eth0 bridged, dnsmasq assigns IPs by MAC)"
fi

# ─── Clear root password ───────────────────────────────────────────────────────
log "Clearing root password..."
if sudo grep -q '^root::' "${MOUNT_POINT}/etc/shadow" 2>/dev/null; then
    log "  Root password already cleared — skipping"
else
    sudo sed -i 's|^root:.*|root::0:0:99999:7:::|' "${MOUNT_POINT}/etc/shadow"
    log "  Root password cleared"
fi

# ─── Configure dropbear ────────────────────────────────────────────────────────
log "Configuring dropbear for key + password auth..."
if [[ -f "${MOUNT_POINT}/etc/config/dropbear" ]]; then
    # Ensure PasswordAuth is on and RootLogin is enabled
    sudo sed -i "s/option PasswordAuth 'off'/option PasswordAuth 'on'/" "${MOUNT_POINT}/etc/config/dropbear" 2>/dev/null || true
    sudo sed -i "s/option RootLogin '0'/option RootLogin '1'/" "${MOUNT_POINT}/etc/config/dropbear" 2>/dev/null || true
    sudo sed -i "s/option RootPasswordAuth 'off'/option RootPasswordAuth 'on'/" "${MOUNT_POINT}/etc/config/dropbear" 2>/dev/null || true

    # Ensure these options exist
    if ! sudo grep -q "PasswordAuth" "${MOUNT_POINT}/etc/config/dropbear"; then
        echo "	option PasswordAuth 'on'" | sudo tee -a "${MOUNT_POINT}/etc/config/dropbear" > /dev/null
    fi
    if ! sudo grep -q "RootLogin" "${MOUNT_POINT}/etc/config/dropbear"; then
        echo "	option RootLogin '1'" | sudo tee -a "${MOUNT_POINT}/etc/config/dropbear" > /dev/null
    fi
    log "  Dropbear: PasswordAuth=on, RootLogin=1"
else
    log "  WARN: No dropbear config found, creating one..."
    sudo tee "${MOUNT_POINT}/etc/config/dropbear" > /dev/null << 'DBEOF'
config dropbear
    option PasswordAuth 'on'
    option RootLogin '1'
    option RootPasswordAuth 'on'
    option Port '22'
DBEOF
fi

# ─── Create /sbin/service shim ──────────────────────────────────────────────────
# Mesha adapters use `service <name> <action>` which doesn't exist on OpenWrt
# by default (they use /etc/init.d/<name> directly)
log "Creating /sbin/service shim..."
SERVICE_SHIM="${MOUNT_POINT}/sbin/service"
if [[ -f "${SERVICE_SHIM}" ]] && sudo head -1 "${SERVICE_SHIM}" 2>/dev/null | grep -q 'service shim'; then
    log "  /sbin/service shim already exists — skipping"
else
    sudo tee "${SERVICE_SHIM}" > /dev/null << 'SERVICEEOF'
#!/bin/sh
# /sbin/service shim — maps `service <name> <action>` to `/etc/init.d/<name> <action>`
# Needed by mesha adapters that expect service(8) behavior

if [ $# -lt 2 ]; then
    echo "Usage: service <name> <action> [args...]"
    echo "Maps to: /etc/init.d/<name> <action> [args...]"
    exit 1
fi

NAME="$1"
shift

INITD="/etc/init.d/${NAME}"
if [ -x "${INITD}" ]; then
    "${INITD}" "$@"
else
    echo "service: ${NAME} not found (no ${INITD})"
    exit 1
fi
SERVICEEOF
    sudo chmod +x "${SERVICE_SHIM}"
    log "  /sbin/service shim created"
fi

# ─── Disable board.d network regeneration ───────────────────────────────────────
# Prevent first-boot scripts from overwriting our DHCP config
BOARD_NET="${MOUNT_POINT}/etc/board.d/99-default_network"
if [[ -f "${BOARD_NET}" ]]; then
    if sudo head -3 "${BOARD_NET}" 2>/dev/null | grep -q 'Disabled'; then
        log "  board.d network already disabled — skipping"
    else
        log "Disabling board.d network auto-generation..."
        # Replace with a no-op that preserves our DHCP config
        sudo tee "${BOARD_NET}" > /dev/null << 'BOARDEOF'
#!/bin/sh
# Disabled — network config pre-baked by prepare-source-image.sh
exit 0
BOARDEOF
        sudo chmod +x "${BOARD_NET}"
    fi
fi

# Also remove any uci-defaults that might reset network config
for f in "${MOUNT_POINT}"/etc/uci-defaults/*network*; do
    [[ -f "$f" ]] || continue
    log "  Removing conflicting uci-defaults: $(basename "$f")"
    sudo rm -f "$f"
done

# ─── Done ───────────────────────────────────────────────────────────────────────
sync
log "Unmounting..."
sudo umount "${MOUNT_POINT}"
MOUNT_POINT=""  # prevent double-unmount in trap

log ""
log "=========================================="
log " Source-built image prepared successfully"
log "=========================================="
log "  Image:     ${IMAGE_PATH}"
log "  SSH key:   ${SSH_KEY_PATH}"
log "  Network:   DHCP (dnsmasq assigns IPs by MAC)"
log ""
log "Next steps:"
log "  1. sudo bash scripts/qemu/start-mesh.sh"
log "  2. bash scripts/qemu/configure-vms.sh"
log ""
log "The SSH key auth will work from first boot."
log "dnsmasq assigns deterministic IPs based on MAC address."
