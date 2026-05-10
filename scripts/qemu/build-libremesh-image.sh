#!/usr/bin/env bash
# build-libremesh-image.sh — Build a LibreMesh x86-64 image for QEMU test bed
#
# Clones the OpenWrt buildroot, adds lime-packages and vwifi as feeds,
# and produces a bootable disk image with mac80211_hwsim support.
#
# Usage:
#   ./build-libremesh-image.sh [OPTIONS]
#
# Environment variables:
#   BUILD_DIR        — Working directory for the build (default: /tmp/libremesh-build)
#   OUTPUT_DIR       — Where to copy the final image (default: <repo-root>/images)
#   REPO_ROOT        — Root of the mesha repository (auto-detected if unset)
#   VWIFI_FEED_URL   — Git URL for the vwifi feed (default: https://github.com/javierbrk/vwifi_cli_package.git)
#   VWIFI_FEED_COMMIT — Git ref for the vwifi feed (default: HEAD)
#   OPENWRT_VERSION  — OpenWrt branch or tag to build (default: v24.10.6)
#
# Options:
#   -h, --help       — Show this help text
#   --skip-if-cached — Skip build if build-inputs.hash matches (default behaviour when hash exists)
#   --force          — Force rebuild even if hash matches
#
# Docker usage:
#   docker build -t mesha-qemu-builder -f docker/qemu-builder/Dockerfile .
#   docker run --rm -v $(pwd)/images:/output mesha-qemu-builder
#
# The build produces:
#   - libremesh-x86-64-<short-hash>-<date>.img.gz  — Compressed disk image
#   - build-manifest.yaml                           — Build metadata
#   - build-inputs.hash                             — Input hash for caching

set -euo pipefail

# ─── Help ───────────────────────────────────────────────────────────────────────
show_help() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

FORCE_REBUILD=false
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help ;;
        --force) FORCE_REBUILD=true ;;
        --skip-if-cached) ;; # default behaviour
    esac
done

# ─── Configuration ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect REPO_ROOT: walk up from script dir until we find a marker
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="${SCRIPT_DIR}"
    while [[ "${REPO_ROOT}" != "/" ]]; do
        if [[ -f "${REPO_ROOT}/.git" || -d "${REPO_ROOT}/.git" ]]; then
            break
        fi
        REPO_ROOT="$(dirname "${REPO_ROOT}")"
    done
fi

BUILD_DIR="${BUILD_DIR:-/tmp/libremesh-build}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/images}"
VWIFI_FEED_URL="${VWIFI_FEED_URL:-https://github.com/javierbrk/vwifi_cli_package.git}"
VWIFI_FEED_COMMIT="${VWIFI_FEED_COMMIT:-HEAD}"
OPENWRT_VERSION="${OPENWRT_VERSION:-v24.10.6}"

LIME_REPO_URL="https://github.com/libremesh/lime-packages.git"
OPENWRT_REPO_URL="https://github.com/openwrt/openwrt.git"
DEFCONFIG="${REPO_ROOT}/scripts/qemu/libremesh-testbed.defconfig"
DOCKERFILE="${REPO_ROOT}/docker/qemu-builder/Dockerfile"

# ─── Helpers ────────────────────────────────────────────────────────────────────
log()   { echo "[build] $*"; }
err()   { echo "[ERROR] $*" >&2; }
die()   { err "$*"; exit 1; }

# ─── Preflight checks ──────────────────────────────────────────────────────────
[[ -f "${DEFCONFIG}" ]]  || die "Defconfig not found: ${DEFCONFIG}"
[[ -f "${DOCKERFILE}" ]] || die "Dockerfile not found: ${DOCKERFILE}"

command -v git >/dev/null   || die "git is required"
command -v make >/dev/null  || die "make is required"

mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"

# ─── Step 1: Clone OpenWrt buildroot ────────────────────────────────────────────
log "Step 1: Cloning OpenWrt ${OPENWRT_VERSION}..."
OPENWRT_DIR="${BUILD_DIR}/openwrt"
if [[ ! -d "${OPENWRT_DIR}" ]]; then
    git clone --branch "${OPENWRT_VERSION}" --single-branch --depth 1 \
        "${OPENWRT_REPO_URL}" "${OPENWRT_DIR}"
else
    log "  OpenWrt already cloned at ${OPENWRT_DIR}, fetching ${OPENWRT_VERSION}..."
    (cd "${OPENWRT_DIR}" && git fetch origin "${OPENWRT_VERSION}" && git checkout "${OPENWRT_VERSION}" || true)
fi

OPENWRT_COMMIT="$(cd "${OPENWRT_DIR}" && git rev-parse HEAD)"
log "  OpenWrt commit: ${OPENWRT_COMMIT:0:12}"

cd "${OPENWRT_DIR}"

# ─── Step 2: Clone lime-packages feed ───────────────────────────────────────────
log "Step 2: Cloning lime-packages feed..."
LIME_FEED_DIR="${BUILD_DIR}/lime-packages"
if [[ ! -d "${LIME_FEED_DIR}" ]]; then
    git clone "${LIME_REPO_URL}" "${LIME_FEED_DIR}"
else
    log "  lime-packages already cloned, pulling latest..."
    (cd "${LIME_FEED_DIR}" && git pull --ff-only || true)
fi

LIME_COMMIT="$(cd "${LIME_FEED_DIR}" && git rev-parse HEAD)"
log "  lime-packages commit: ${LIME_COMMIT:0:12}"

# ─── Step 3: Add feeds to feeds.conf ────────────────────────────────────────────
log "Step 3: Adding lime-packages and vwifi feeds to feeds.conf..."

# Start with default feeds.conf if feeds.conf doesn't exist
if [[ ! -f feeds.conf ]]; then
    cp feeds.conf.default feeds.conf 2>/dev/null || true
fi

# Add lime-packages feed
if ! grep -q "src-git lime" feeds.conf 2>/dev/null; then
    echo "src-git lime ${LIME_FEED_DIR}" >> feeds.conf
    log "  Added lime feed"
else
    log "  lime feed already in feeds.conf"
fi

# Add vwifi feed
if ! grep -q "src-git vwifi" feeds.conf 2>/dev/null; then
    echo "src-git vwifi ${VWIFI_FEED_URL}" >> feeds.conf
    log "  Added vwifi feed"
else
    log "  vwifi feed already in feeds.conf"
fi

# ─── Step 4: Update and install feeds ──────────────────────────────────────────
log "Step 4: Updating and installing feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

# Pin vwifi feed to specific commit if requested
if [[ -n "${VWIFI_FEED_COMMIT}" && "${VWIFI_FEED_COMMIT}" != "HEAD" ]]; then
    log "  Pinning vwifi feed to commit: ${VWIFI_FEED_COMMIT}"
    (cd "${OPENWRT_DIR}/feeds/vwifi" && git checkout "${VWIFI_FEED_COMMIT}" 2>/dev/null) || \
        log "  WARN: Could not pin vwifi feed to ${VWIFI_FEED_COMMIT}"
fi

# ─── Compute input hash AFTER feeds are cloned/updated ─────────────────────────
compute_input_hash() {
    local hash_input=""
    hash_input+="$(cat "$0")"
    hash_input+=$(cat "${DEFCONFIG}")
    hash_input+=$(cat "${DOCKERFILE}")

    # Include feed commit hashes (now available after clone/update)
    hash_input+=$(cd "${LIME_FEED_DIR}" && git rev-parse HEAD 2>/dev/null || echo "unknown")
    hash_input+=$(cd "${OPENWRT_DIR}" && git rev-parse HEAD 2>/dev/null || echo "unknown")
    if [[ -d "${OPENWRT_DIR}/feeds/vwifi" ]]; then
        hash_input+=$(cd "${OPENWRT_DIR}/feeds/vwifi" && git rev-parse HEAD 2>/dev/null || echo "unknown")
    fi

    echo -n "${hash_input}" | sha256sum | awk '{print $1}'
}

CURRENT_HASH="$(compute_input_hash)"
CACHED_HASH_FILE="${OUTPUT_DIR}/build-inputs.hash"

if [[ "${FORCE_REBUILD}" == "false" ]] && [[ -f "${CACHED_HASH_FILE}" ]]; then
    CACHED_HASH="$(cat "${CACHED_HASH_FILE}")"
    if [[ "${CURRENT_HASH}" == "${CACHED_HASH}" ]]; then
        log "Build inputs unchanged (hash: ${CURRENT_HASH:0:12}). Skipping build."
        log "Use --force to rebuild."
        exit 0
    fi
fi

log "Build input hash: ${CURRENT_HASH:0:12}"

# ─── Fix host Python (prevent WASM/Pyodide Python from breaking builds) ────────
# Some environments have a pyodide/emscripten WASM Python in PATH that cannot
# access the local filesystem. Detect and fix it before compilation starts.
SYSTEM_PYTHON="$(command -v python3 2>/dev/null || true)"
if [[ -n "${SYSTEM_PYTHON}" ]]; then
    PYTHON_TYPE="$(file "${SYSTEM_PYTHON}" 2>/dev/null || true)"
    if echo "${PYTHON_TYPE}" | grep -qi "wasm\|emscripten\|pyodide"; then
        log "  WARNING: Detected WASM Python at ${SYSTEM_PYTHON}"
        REAL_PYTHON="$(command -v python3.12 2>/dev/null || command -v python3.11 2>/dev/null || command -v /usr/bin/python3 2>/dev/null || true)"
        if [[ -n "${REAL_PYTHON}" && "${REAL_PYTHON}" != "${SYSTEM_PYTHON}" ]]; then
            log "  Using native Python instead: ${REAL_PYTHON}"
            export PYTHON="${REAL_PYTHON}"
        fi
    fi
fi

# ─── Step 5: Copy defconfig ────────────────────────────────────────────────────
log "Step 5: Applying defconfig..."
cp "${DEFCONFIG}" .config

# ─── Step 6: Expand defconfig ──────────────────────────────────────────────────
log "Step 6: Expanding defconfig..."
make defconfig

# ─── Step 7: Verify vwifi is enabled ───────────────────────────────────────────
log "Step 7: Verifying vwifi package..."
VWIFI_LINE="$(grep 'CONFIG_PACKAGE_vwifi=' .config || true)"
if echo "${VWIFI_LINE}" | grep -q 'is not set' || [[ -z "${VWIFI_LINE}" ]]; then
    err "vwifi package is NOT enabled in .config!"
    err "  Got: ${VWIFI_LINE:-'(not found)'}"
    die "Cannot build without vwifi. Check that the vwifi feed was added correctly."
fi
log "  vwifi: ${VWIFI_LINE}"

# ─── Step 8: Build ─────────────────────────────────────────────────────────────
log "Step 8: Building (this will take 2-4 hours)..."
# First pass: tools and target with -j1 to avoid race conditions
log "  Phase 1: tools and target (single-threaded to avoid races)..."
make -j1 tools/install toolchain/install target/compile || { err "Tools/toolchain/target build failed."; exit 1; }

# Fix staging_dir python3 symlink if it points to a WASM build
STAGING_PYTHON="${OPENWRT_DIR}/staging_dir/host/bin/python3"
if [[ -L "${STAGING_PYTHON}" ]]; then
    PYTHON_TARGET="$(readlink -f "${STAGING_PYTHON}" 2>/dev/null || true)"
    if [[ -n "${PYTHON_TARGET}" ]]; then
        PYTHON_FILE="$(file "${PYTHON_TARGET}" 2>/dev/null || true)"
        if echo "${PYTHON_FILE}" | grep -qi "wasm\|emscripten\|pyodide"; then
            log "  Fixing WASM python3 symlink in staging_dir..."
            NATIVE_PYTHON="$(command -v python3.12 2>/dev/null || command -v python3.11 2>/dev/null || command -v /usr/bin/python3 2>/dev/null || true)"
            if [[ -n "${NATIVE_PYTHON}" ]]; then
                rm -f "${STAGING_PYTHON}"
                ln -s "${NATIVE_PYTHON}" "${STAGING_PYTHON}"
                log "  Fixed: ${STAGING_PYTHON} -> ${NATIVE_PYTHON}"
            fi
        fi
    fi
fi
# Second pass: packages with parallelism
log "  Phase 2: packages ($(nproc) parallel jobs)..."
make -j"$(nproc)" package/compile || { err "Package build failed."; exit 1; }
log "  Phase 2b: installing packages to rootfs..."
make -j1 package/install || { err "Package install failed."; exit 1; }
# Final: assemble image
log "  Phase 3: assembling image..."
make -j1 package/index target/install || { err "Image assembly failed."; exit 1; }

# ─── Post-build: copy image ────────────────────────────────────────────────────
log "Copying image to output directory..."
SOURCE_IMG="${OPENWRT_DIR}/bin/targets/x86/64/openwrt-x86-64-generic-ext4-rootfs.img.gz"
if [[ ! -f "${SOURCE_IMG}" ]]; then
    # Try alternative names (combined ext4 image)
    SOURCE_IMG="$(find "${OPENWRT_DIR}/bin/targets/x86/64/" -name '*-ext4-rootfs.img.gz' -o -name '*-combined-ext4.img.gz' 2>/dev/null | head -1)"
fi
[[ -f "${SOURCE_IMG}" ]] || die "Built image not found in bin/targets/x86/64/"

SHORT_HASH="${CURRENT_HASH:0:12}"
DATE_STAMP="$(date +%Y%m%d)"
DEST_NAME="libremesh-x86-64-${SHORT_HASH}-${DATE_STAMP}.img.gz"

cp "${SOURCE_IMG}" "${OUTPUT_DIR}/${DEST_NAME}"
log "Image copied: ${OUTPUT_DIR}/${DEST_NAME}"

# ─── Image size verification (Gate 1.1: must be >50MB) ────────────────────────
IMAGE_SIZE=$(stat -c%s "${OUTPUT_DIR}/${DEST_NAME}" 2>/dev/null || stat -f%z "${OUTPUT_DIR}/${DEST_NAME}")
MIN_IMAGE_SIZE=$((50 * 1024 * 1024))  # 50 MB
if [[ "${IMAGE_SIZE}" -lt "${MIN_IMAGE_SIZE}" ]]; then
    die "Image size verification FAILED: ${IMAGE_SIZE} bytes < 50MB minimum (Gate 1.1)"
fi
log "Image size verification passed: $((IMAGE_SIZE / 1024 / 1024)) MB >= 50 MB"

# ─── Generate build-manifest.yaml ──────────────────────────────────────────────
log "Generating build-manifest.yaml..."

# Get vwifi commit
VWIFI_COMMIT="unknown"
VWIFI_FEED_DIR="${OPENWRT_DIR}/feeds/vwifi"
if [[ -d "${VWIFI_FEED_DIR}" ]]; then
    VWIFI_COMMIT="$(cd "${VWIFI_FEED_DIR}" && git rev-parse HEAD 2>/dev/null || echo "unknown")"
fi

PACKAGE_LIST="$(grep '=y' .config | sort)"

cat > "${OUTPUT_DIR}/build-manifest.yaml" <<EOF
# LibreMesh QEMU test bed — build manifest
# Auto-generated by build-libremesh-image.sh

build_date: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
image_file: "${DEST_NAME}"
lime_packages_commit: "${LIME_COMMIT}"
openwrt_version: "${OPENWRT_COMMIT}"
vwifi_commit: "${VWIFI_COMMIT}"
build_input_hash: "${CURRENT_HASH}"

package_list:
$(echo "${PACKAGE_LIST}" | sed 's/^/  - /')
EOF

log "Manifest written: ${OUTPUT_DIR}/build-manifest.yaml"

# ─── Write build-inputs.hash ───────────────────────────────────────────────────
echo "${CURRENT_HASH}" > "${CACHED_HASH_FILE}"
log "Hash file written: ${CACHED_HASH_FILE}"

log "Build complete!"
log "  Image: ${OUTPUT_DIR}/${DEST_NAME}"
log "  Manifest: ${OUTPUT_DIR}/build-manifest.yaml"

# ─── Post-build: configure image for testbed ────────────────────────────────────
# Decompress and configure the image for QEMU testbed use
log "Decompressing image..."
gunzip -fk "${OUTPUT_DIR}/${DEST_NAME}"
DEST_IMG="${OUTPUT_DIR}/${DEST_NAME%.gz}"

log "Configuring image for testbed..."
bash "${SCRIPT_DIR}/configure-source-image.sh" --image "${DEST_IMG}" || {
    err "Image configuration failed. You can run configure-source-image.sh manually."
    err "  bash scripts/qemu/configure-source-image.sh --image ${DEST_IMG}"
}

# Update symlink
ln -sf "$(basename "${DEST_IMG}")" "${OUTPUT_DIR}/libremesh-x86-64.ext4"
log "Symlink updated: libremesh-x86-64.ext4 -> $(basename "${DEST_IMG}")"

log ""
log "Image is ready for testbed use."
log "  To boot: sudo bash scripts/qemu/start-mesh.sh"
log "  Then:    bash scripts/qemu/configure-vms.sh"
