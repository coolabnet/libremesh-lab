#!/usr/bin/env bash
# configure-source-image.sh — Configure source-built OpenWrt image for testbed
#
# Mounts the rootfs partition of a source-built OpenWrt image and configures:
#   - Network: DHCP on br-lan (so dnsmasq on the bridge can assign IPs)
#   - SSH: injects authorized_keys for root login
#   - Drops root password
#
# Usage:
#   ./configure-source-image.sh [OPTIONS]
#
# Options:
#   -h, --help          — Show this help text
#   --image <path>      — Source-built image path (default: auto-detect)
#   --ssh-key <path>    — SSH public key (default: run/ssh-keys/id_rsa.pub)
#
# This script is the source-built equivalent of convert-prebuilt.sh.
# It must be run once after building the image with build-libremesh-image.sh.

set -euo pipefail

# ─── Help ───────────────────────────────────────────────────────────────────────
show_help() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

IMAGE_PATH=""
SSH_KEY_PATH=""

for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help ;;
        --image)
            shift
            IMAGE_PATH="${1:-}"
            [[ -z "${IMAGE_PATH}" ]] && { echo "[ERROR] --image requires a value" >&2; exit 1; }
            ;;
        --ssh-key)
            shift
            SSH_KEY_PATH="${1:-}"
            [[ -z "${SSH_KEY_PATH}" ]] && { echo "[ERROR] --ssh-key requires a value" >&2; exit 1; }
            ;;
    esac
done

# ─── Configuration ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect REPO_ROOT
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="${SCRIPT_DIR}"
    while [[ "${REPO_ROOT}" != "/" ]]; do
        if [[ -f "${REPO_ROOT}/.git" || -d "${REPO_ROOT}/.git" ]]; then
            break
        fi
        REPO_ROOT="$(dirname "${REPO_ROOT}")"
    done
fi

IMAGE_DIR="${REPO_ROOT}/images"
IMAGE_PATH="${IMAGE_PATH:-${IMAGE_DIR}/libremesh-x86-64-source-built.img}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${REPO_ROOT}/run/ssh-keys/id_rsa.pub}"

# ─── Helpers ────────────────────────────────────────────────────────────────────
log() { echo "[configure-source] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

# ─── Preflight ──────────────────────────────────────────────────────────────────
[[ -f "${IMAGE_PATH}" ]] || die "Image not found: ${IMAGE_PATH}"
command -v fdisk >/dev/null || die "fdisk is required (install fdisk)"

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
}
trap cleanup EXIT

# ─── Find rootfs partition offset ───────────────────────────────────────────────
# Source-built images can be:
#   1. Combined image (MBR with partition 1 = boot, partition 2 = rootfs)
#   2. Flat image (raw ext4, no partition table — like the prebuilt image)

log "Analyzing image format of ${IMAGE_PATH}..."

IS_FLAT=false
if file -L "${IMAGE_PATH}" | grep -q "DOS/MBR boot sector"; then
    # Combined image with partition table
    PART2_START=$(fdisk -l "${IMAGE_PATH}" 2>/dev/null | awk '
        /^\/dev/ && $1 ~ /2$/ {
            print $2
        }
    ')

    if [[ -z "${PART2_START}" ]]; then
        die "Could not find partition 2 (rootfs) in ${IMAGE_PATH}. Is this a source-built combined image?"
    fi

    SECTOR_SIZE=512
    ROOTFS_OFFSET=$((PART2_START * SECTOR_SIZE))
    log "Combined image: rootfs partition at sector ${PART2_START} (offset ${ROOTFS_OFFSET} bytes)"
else
    # Flat image — no partition table, mount directly
    IS_FLAT=true
    ROOTFS_OFFSET=0
    log "Flat image: mounting directly (no partition table)"
fi

# ─── Mount rootfs ───────────────────────────────────────────────────────────────
MOUNT_POINT="$(mktemp -d /tmp/source-rootfs.XXXXXX)"
log "Mounting rootfs at ${MOUNT_POINT}..."
if [[ "${IS_FLAT}" = "true" ]]; then
    sudo mount -o loop "${IMAGE_PATH}" "${MOUNT_POINT}"
else
    sudo mount -o loop,offset="${ROOTFS_OFFSET}" "${IMAGE_PATH}" "${MOUNT_POINT}"
fi

# ─── Configure network ─────────────────────────────────────────────────────────
log "Configuring network (DHCP on br-lan)..."

# Replace board.d/99-default_network to use DHCP instead of static 192.168.1.1
sudo tee "${MOUNT_POINT}/etc/board.d/99-default_network" > /dev/null << 'BOARDSCRIPT'
. /lib/functions/uci-defaults.sh

board_config_update

json_is_a network object && exit 0

ucidef_set_interface 'lan' device 'eth0' protocol 'dhcp'
[ -d /sys/class/net/eth1 ] && ucidef_set_interface 'wan' device 'eth1' protocol 'dhcp'

board_config_flush

exit 0
BOARDSCRIPT
sudo chmod +x "${MOUNT_POINT}/etc/board.d/99-default_network"

# Remove any existing network config so board.d regenerates it on first boot
sudo rm -f "${MOUNT_POINT}/etc/config/network"

# Also remove uci-defaults that might interfere
sudo rm -f "${MOUNT_POINT}/etc/uci-defaults/11_network-migrate-bridges" 2>/dev/null || true

log "  Network: DHCP on br-lan (eth0)"

# ─── Configure SSH ─────────────────────────────────────────────────────────────
if [[ -f "${SSH_KEY_PATH}" ]]; then
    log "Injecting SSH public key..."
    sudo mkdir -p "${MOUNT_POINT}/root/.ssh"
    sudo tee "${MOUNT_POINT}/root/.ssh/authorized_keys" > /dev/null < "${SSH_KEY_PATH}"
    sudo chmod 700 "${MOUNT_POINT}/root/.ssh"
    sudo chmod 600 "${MOUNT_POINT}/root/.ssh/authorized_keys"
    log "  SSH key: $(sudo head -1 "${MOUNT_POINT}/root/.ssh/authorized_keys" | cut -c1-40)..."
else
    log "  WARNING: SSH key not found at ${SSH_KEY_PATH}, skipping"
fi

# ─── Clear root password ───────────────────────────────────────────────────────
log "Clearing root password..."
sudo sed -i 's|^root:.*|root::0:0:99999:7:::|' "${MOUNT_POINT}/etc/shadow"

# ─── Ensure dropbear allows root login with blank password ──────────────────────
if [[ -f "${MOUNT_POINT}/etc/config/dropbear" ]]; then
    log "  Configuring dropbear for blank password login..."
    # Add BlankPasswordAuth option to dropbear config
    if ! sudo grep -q "BlankPasswordAuth" "${MOUNT_POINT}/etc/config/dropbear"; then
        echo "	option BlankPasswordAuth '1'" | sudo tee -a "${MOUNT_POINT}/etc/config/dropbear" > /dev/null
    fi

    # Patch dropbear init script to support -B flag (Allow blank passwords)
    DROPBEAR_INIT="${MOUNT_POINT}/etc/init.d/dropbear"
    if [[ -f "${DROPBEAR_INIT}" ]] && ! sudo grep -q "BlankPasswordAuth.*-B" "${DROPBEAR_INIT}"; then
        # Add -B flag handling after RootPasswordAuth handling
        sudo sed -i '/RootPasswordAuth.*-g/a\\t[ "${BlankPasswordAuth}" -eq 1 ] \&\& procd_append_param command -B' "${DROPBEAR_INIT}"
        # Add BlankPasswordAuth to the validate function
        sudo sed -i "/RootLogin:bool:1/a\\t\t'BlankPasswordAuth:bool:0' \\\\" "${DROPBEAR_INIT}"
        log "  Patched dropbear init script with -B (blank password) support"
    fi
fi

# ─── Done ───────────────────────────────────────────────────────────────────────
sync
sudo umount "${MOUNT_POINT}"
MOUNT_POINT=""  # prevent double-unmount in trap

log ""
log "Source-built image configured successfully."
log "  Image: ${IMAGE_PATH}"
log ""
log "To boot:"
log "  sudo bash scripts/qemu/start-mesh.sh"
log ""
log "The VMs will get IPs via DHCP from dnsmasq on the bridge."
log "Then run: bash scripts/qemu/configure-vms.sh"
