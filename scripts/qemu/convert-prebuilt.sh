#!/usr/bin/env bash
# convert-prebuilt.sh — Download and prepare LibreMesh pre-built images for QEMU
#
# Fast-path alternative to building from source. Downloads official LibreMesh
# x86-64 combined images from the antennine firmware mirror and prepares them
# for use with the QEMU testbed.
#
# Usage:
#   ./convert-prebuilt.sh [OPTIONS]
#
# Options:
#   -h, --help          — Show this help text
#   --skip-download     — Reuse already-downloaded files
#   --output <path>     — Output image path (default: <repo-root>/images/libremesh-prebuilt.img)
#   --profile <name>    — Firmware profile: default or mini (default: default)
#   --release <version> — LibreMesh release version (default: 2024.1-ow23.05.5)
#
# Limitations of pre-built images:
#   - No mac80211_hwsim kernel module (no simulated WiFi)
#   - No vwifi-client package
#   - Uses babeld/batman-adv (not bmx7) for mesh routing
#   - Mesh routing works over wired interfaces only
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
PROFILE="default"
RELEASE="2024.1-ow23.05.5"

# IMPORTANT: this must be a while loop with explicit shifts. The previous
# `for arg in "$@"; shift; ...` pattern was broken: `for` iterates over the
# original argument list (so `shift` inside the loop body had no effect on
# the next iteration), and `--output foo` was parsed as two separate cases,
# with `foo` falling through into the default (no-match) arm silently.
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help ;;
        --skip-download) SKIP_DOWNLOAD=true; shift ;;
        --output)
            [[ $# -ge 2 ]] || { echo "[ERROR] --output requires a value" >&2; exit 1; }
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --profile)
            [[ $# -ge 2 ]] || { echo "[ERROR] --profile requires a value" >&2; exit 1; }
            PROFILE="$2"
            shift 2
            ;;
        --release)
            [[ $# -ge 2 ]] || { echo "[ERROR] --release requires a value" >&2; exit 1; }
            RELEASE="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "[ERROR] Unknown option: $1" >&2
            exit 1
            ;;
        *)
            echo "[ERROR] Unexpected positional argument: $1" >&2
            exit 1
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

BASE_URL="https://firmware-libremesh.antennine.org/releases/${RELEASE}/targets/x86/64/${PROFILE}"
DOWNLOAD_DIR="${REPO_ROOT}/images"
OUTPUT_PATH="${OUTPUT_PATH:-${DOWNLOAD_DIR}/libremesh-prebuilt.img}"

# Remote filename (actual name on the server)
COMBINED_REMOTE="libremesh-${RELEASE}-${PROFILE}-x86-64-generic-ext4-combined.img.gz"
# Local filename (short name for downloaded file)
COMBINED_FILE="libremesh-combined.img.gz"

# ─── Helpers ────────────────────────────────────────────────────────────────────
log() { echo "[convert] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

# ─── Preflight checks ──────────────────────────────────────────────────────────
command -v gunzip >/dev/null || die "gunzip is required"

mkdir -p "${DOWNLOAD_DIR}"

# ─── Download ───────────────────────────────────────────────────────────────────
if [[ "${SKIP_DOWNLOAD}" == "true" ]]; then
    log "Skipping download (--skip-download), using existing files..."
    [[ -f "${DOWNLOAD_DIR}/${COMBINED_FILE}" ]] || die "Combined image not found: ${DOWNLOAD_DIR}/${COMBINED_FILE}"
else
    log "Downloading LibreMesh ${RELEASE} (${PROFILE} profile)..."
    log "  URL: ${BASE_URL}/${COMBINED_REMOTE}"
    wget -q --show-progress -O "${DOWNLOAD_DIR}/${COMBINED_FILE}" "${BASE_URL}/${COMBINED_REMOTE}"
fi

log "Download complete."
log "  Combined image: $(du -h "${DOWNLOAD_DIR}/${COMBINED_FILE}" | cut -f1)"

# ─── Decompress ─────────────────────────────────────────────────────────────────
log "Decompressing combined image..."
DECOMPRESSED="${DOWNLOAD_DIR}/${COMBINED_FILE%.gz}"
gunzip -fk "${DOWNLOAD_DIR}/${COMBINED_FILE}" 2>/dev/null || {
    # gunzip may warn about "trailing garbage" but still decompress correctly
    [[ -f "${DECOMPRESSED}" ]] || die "Decompression failed: ${DECOMPRESSED} not created"
    log "  (gunzip warning suppressed — decompression succeeded)"
}
log "Decompressed: ${DECOMPRESSED} ($(du -h "${DECOMPRESSED}" | cut -f1))"

# ─── Verify image has partition table ───────────────────────────────────────────
# Reject obviously-wrong downloads (404 HTML pages saved as .img.gz, truncated
# files, etc.) before we waste time trying to mount a corrupt image.
if ! file -L "${DECOMPRESSED}" | grep -qE "DOS/MBR boot sector|partition table|ext[234] filesystem|Squashfs|ROM filesystem|XZ compressed"; then
    die "Decompressed file does not look like a firmware image. Check the release/profile URL: ${BASE_URL}/${COMBINED_REMOTE}"
fi
if file -L "${DECOMPRESSED}" | grep -q "DOS/MBR boot sector\|partition table"; then
    log "Image has partition table — will boot directly in QEMU (no -kernel needed)."
else
    log "WARN: Image does not have a partition table. May need -kernel flag."
fi

# ─── Configure image for testbed ────────────────────────────────────────────────
# Mount the rootfs partition and inject testbed configuration:
#   - Network: DHCP on br-lan (so dnsmasq on the bridge can assign IPs)
#   - SSH: inject authorized_keys for root login
#   - Clear root password
log "Configuring image for testbed..."
if ! bash "${SCRIPT_DIR}/configure-source-image.sh" --image "${DECOMPRESSED}"; then
    die "Image configuration failed. The image would be unconfigured (no SSH keys, no DHCP), which makes the testbed unusable. Re-run configure-source-image.sh manually after fixing the underlying error: bash scripts/qemu/configure-source-image.sh --image ${DECOMPRESSED}"
fi

# ─── Create output symlink ──────────────────────────────────────────────────────
# Copy to output path if different from decompressed path
if [[ "${DECOMPRESSED}" != "${OUTPUT_PATH}" ]]; then
    cp "${DECOMPRESSED}" "${OUTPUT_PATH}"
    log "Copied to: ${OUTPUT_PATH}"
fi

# Create symlink expected by start-mesh.sh.
# Resolve relative paths to their absolute form before symlinking so
# `--output prebuilt.img` (from repo root) and `--output /tmp/x.img`
# both produce valid links.
OUTPUT_PATH="$(cd "$(dirname "${OUTPUT_PATH}")" && pwd)/$(basename "${OUTPUT_PATH}")"
ln -sf "${OUTPUT_PATH}" "${DOWNLOAD_DIR}/libremesh-x86-64.ext4"
log "Symlink created: libremesh-x86-64.ext4 -> ${OUTPUT_PATH}"

log ""
log "Image ready: ${OUTPUT_PATH}"
log "  Size: $(du -h "${OUTPUT_PATH}" | cut -f1)"
log ""
log "To boot with QEMU:"
log "  sudo bash scripts/qemu/start-mesh.sh"
log ""
log "Note: Pre-built images do NOT include mac80211_hwsim or vwifi-client."
log "      Mesh will use babeld/batman-adv over wired (tap) interfaces."
log "      For WiFi simulation, use build-libremesh-image.sh instead."
