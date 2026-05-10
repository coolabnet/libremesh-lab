#!/usr/bin/env bash
# convert-prebuilt.sh — Download and convert LibreRouterOS pre-built images for QEMU
#
# Fast-path alternative to building from source. Downloads official LibreRouterOS
# x86-64 images and converts them to a raw disk image suitable for QEMU.
#
# Usage:
#   ./convert-prebuilt.sh [OPTIONS]
#
# Options:
#   -h, --help          — Show this help text
#   --skip-download     — Reuse already-downloaded files
#   --output <path>     — Output image path (default: <repo-root>/images/librerouteros-prebuilt.img)
#
# Limitations of pre-built images:
#   - No mac80211_hwsim kernel module (no simulated WiFi)
#   - No vwifi-client package
#   - BMX7 mesh routing works over wired interfaces only
#   - Cannot add custom packages without rebuilding from source
#
# For full WiFi simulation support, use build-libremesh-image.sh instead.

set -euo pipefail

# ─── Help ───────────────────────────────────────────────────────────────────────
show_help() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

SKIP_DOWNLOAD=false
OUTPUT_PATH=""

for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help ;;
        --skip-download) SKIP_DOWNLOAD=true ;;
        --output)
            shift
            OUTPUT_PATH="${1:-}"
            if [[ -z "${OUTPUT_PATH}" ]]; then
                echo "[ERROR] --output requires a value" >&2
                exit 1
            fi
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

BASE_URL="https://repo.librerouter.org/lros/releases/1.5/targets/x86/64"
DOWNLOAD_DIR="${REPO_ROOT}/images"
OUTPUT_PATH="${OUTPUT_PATH:-${DOWNLOAD_DIR}/librerouteros-prebuilt.img}"

ROOTFS_FILE="generic-rootfs.tar.gz"
KERNEL_FILE="generic-kernel.bin"
IMAGE_SIZE="256M"

# ─── Helpers ────────────────────────────────────────────────────────────────────
log() { echo "[convert] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

# ─── Cleanup trap ───────────────────────────────────────────────────────────────
MOUNT_POINT=""
LOOP_DEV=""

cleanup() {
    if [[ -n "${MOUNT_POINT}" ]] && mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        log "Unmounting ${MOUNT_POINT}..."
        sudo umount "${MOUNT_POINT}" || true
    fi
    if [[ -n "${LOOP_DEV}" ]] && [[ -e "${LOOP_DEV}" ]]; then
        log "Detaching loop device ${LOOP_DEV}..."
        sudo losetup -d "${LOOP_DEV}" || true
    fi
    if [[ -n "${MOUNT_POINT}" ]] && [[ -d "${MOUNT_POINT}" ]]; then
        rmdir "${MOUNT_POINT}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─── Preflight checks ──────────────────────────────────────────────────────────
command -v qemu-img >/dev/null  || die "qemu-img is required (install qemu-utils)"
command -v mkfs.ext4 >/dev/null || die "mkfs.ext4 is required (install e2fsprogs)"

# Check mount capability
if ! mount --version >/dev/null 2>&1; then
    die "mount command not available"
fi

mkdir -p "${DOWNLOAD_DIR}"

# ─── Download ───────────────────────────────────────────────────────────────────
if [[ "${SKIP_DOWNLOAD}" == "true" ]]; then
    log "Skipping download (--skip-download), using existing files..."
    [[ -f "${DOWNLOAD_DIR}/${ROOTFS_FILE}" ]] || die "Rootfs not found: ${DOWNLOAD_DIR}/${ROOTFS_FILE}"
    [[ -f "${DOWNLOAD_DIR}/${KERNEL_FILE}" ]] || die "Kernel not found: ${DOWNLOAD_DIR}/${KERNEL_FILE}"
else
    log "Downloading rootfs..."
    wget -q --show-progress -O "${DOWNLOAD_DIR}/${ROOTFS_FILE}" "${BASE_URL}/${ROOTFS_FILE}"

    log "Downloading kernel..."
    wget -q --show-progress -O "${DOWNLOAD_DIR}/${KERNEL_FILE}" "${BASE_URL}/${KERNEL_FILE}"
fi

log "Downloads complete."
log "  Rootfs: $(du -h "${DOWNLOAD_DIR}/${ROOTFS_FILE}" | cut -f1)"
log "  Kernel: $(du -h "${DOWNLOAD_DIR}/${KERNEL_FILE}" | cut -f1)"

# ─── Create disk image ─────────────────────────────────────────────────────────
log "Creating ${IMAGE_SIZE} ext4 disk image at ${OUTPUT_PATH}..."
qemu-img create -f raw "${OUTPUT_PATH}" "${IMAGE_SIZE}"

# Find an available loop device
LOOP_DEV="$(sudo losetup -f)"
sudo losetup "${LOOP_DEV}" "${OUTPUT_PATH}"

log "Formatting with ext4..."
sudo mkfs.ext4 -F "${LOOP_DEV}"

# ─── Mount and extract ─────────────────────────────────────────────────────────
MOUNT_POINT="$(mktemp -d /tmp/librerouteros-mnt.XXXXXX)"
log "Mounting at ${MOUNT_POINT}..."
sudo mount "${LOOP_DEV}" "${MOUNT_POINT}"

log "Extracting rootfs..."
sudo tar -xzf "${DOWNLOAD_DIR}/${ROOTFS_FILE}" -C "${MOUNT_POINT}"

log "Copying kernel..."
sudo mkdir -p "${MOUNT_POINT}/boot"
sudo cp "${DOWNLOAD_DIR}/${KERNEL_FILE}" "${MOUNT_POINT}/boot/vmlinuz"

# Inject /sbin/service shim for prebuilt images
cat > "${MOUNT_POINT}/sbin/service" << 'SERVICEEOF'
#!/bin/sh
# Minimal /sbin/service shim for LibreRouterOS prebuilt
/etc/init.d/"$@"
SERVICEEOF
chmod +x "${MOUNT_POINT}/sbin/service"
log "  Injected /sbin/service shim"

log "Syncing and unmounting..."
sync
sudo umount "${MOUNT_POINT}"
MOUNT_POINT=""  # prevent double-unmount in trap

sudo losetup -d "${LOOP_DEV}"
LOOP_DEV=""  # prevent double-detach in trap

log "Image created: ${OUTPUT_PATH}"
log "  Size: $(du -h "${OUTPUT_PATH}" | cut -f1)"
log ""
log "To boot with QEMU:"
log "  qemu-system-x86_64 -m 256 -drive file=${OUTPUT_PATH},format=raw \\"
log "    -kernel ${DOWNLOAD_DIR}/${KERNEL_FILE} -nographic \\"
log "    -append 'root=/dev/sda rootfstype=ext4 rootwait console=ttyS0'"
log ""
log "Note: Pre-built images do NOT include mac80211_hwsim or vwifi-client."
log "      BMX7 mesh will only work over wired (tap) interfaces."
