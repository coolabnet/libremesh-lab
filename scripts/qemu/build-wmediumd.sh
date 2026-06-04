#!/usr/bin/env bash
# Build and install wmediumd into the project's bin/ directory.
# Linux-only (uses nproc and ELF RPATH).
#
# Dependencies: libnl-3-dev, libnl-genl-3-dev, libconfig-dev (Debian/Ubuntu)
#              or equivalent pkg-config packages on other distros.
#
# Reproducibility: pin a commit (WMEDIUMD_REF) so a self-hosted runner
# cannot silently rebuild against a mutated upstream. Override with
# WMEDIUMD_REPO=... WMEDIUMD_REF=... to test a fork or branch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BIN_DIR="${LAB_ROOT}/bin"
LIB_DIR="${BIN_DIR}/lib"

# mktemp -d avoids reusing a stale /tmp/libremesh-lab-wmediumd-build left
# behind by a previous interrupted run, and makes the script safe on
# shared hosts (no fixed /tmp path that a co-tenant could pre-create).
BUILD_DIR="$(mktemp -d /tmp/libremesh-lab-wmediumd-XXXXXX)"
trap 'rm -rf "${BUILD_DIR}"' EXIT INT TERM

# Pin a specific ref (branch, tag, or commit SHA). Override via env to
# test forks; the default is the upstream `master` branch, which is a
# MOVING TARGET. For reproducible CI/self-hosted-runner builds, set
# WMEDIUMD_REF to a specific commit SHA (recommended) or a tag. Bump
# this when upgrading and verify the namespace smoke test still passes
# on a self-hosted runner before relying on the new build.
WMEDIUMD_REPO="${WMEDIUMD_REPO:-https://github.com/cozybit/wmediumd.git}"
WMEDIUMD_REF="${WMEDIUMD_REF:-master}"

echo "=== Building wmediumd (${WMEDIUMD_REPO} @ ${WMEDIUMD_REF}) ==="
echo "  Build dir: ${BUILD_DIR}"

# Clone the ref. A 40-char hex string is treated as a commit SHA (full
# clone, then checkout); anything else is treated as a branch/tag
# (shallow clone of just that ref). This lets the caller pin to a
# specific commit for reproducibility while still supporting `master` /
# tag-based defaults in development.
if [[ "${WMEDIUMD_REF}" =~ ^[0-9a-f]{40}$ ]]; then
    git clone "${WMEDIUMD_REPO}" "${BUILD_DIR}/src"
    git -C "${BUILD_DIR}/src" checkout "${WMEDIUMD_REF}"
else
    git clone --depth 1 --branch "${WMEDIUMD_REF}" "${WMEDIUMD_REPO}" "${BUILD_DIR}/src"
fi

# Compile. RPATH uses $ORIGIN so the binary is relocatable (works no
# matter where bin/ ends up in the filesystem, e.g. after a `make
# install` into a different prefix). Single-quoted to prevent shell
# expansion; make passes the value to the linker verbatim.
cd "${BUILD_DIR}/src/wmediumd"
CFLAGS="-I/usr/include" \
    LDFLAGS='-Wl,-rpath,$ORIGIN/lib' \
    make -j"$(nproc)" 2>&1

# Install binary
mkdir -p "${BIN_DIR}"
cp wmediumd "${BIN_DIR}/wmediumd"
chmod +x "${BIN_DIR}/wmediumd"
echo "  Installed: ${BIN_DIR}/wmediumd"

# Bundle libconfig runtime if the dynamic binary needs it. Detect the
# SONAME from ldd output (not hard-coded to .9) so the script keeps
# working when distros ship a newer libconfig ABI.
if ldd "${BIN_DIR}/wmediumd" 2>/dev/null | grep -q 'libconfig'; then
    LIBCONFIG_SO=""
    SONAME=$(ldd "${BIN_DIR}/wmediumd" 2>/dev/null \
             | awk '/libconfig/ {print $1}' | head -1 || true)
    if [ -n "${SONAME}" ]; then
        # Resolve the SONAME to an actual file on disk
        LIBCONFIG_SO="$(ldconfig -p 2>/dev/null | awk -v s="${SONAME}" '$1 == s {print $NF; exit}')"
    fi
    if [ -z "${LIBCONFIG_SO}" ] || [ ! -f "${LIBCONFIG_SO}" ]; then
        # Fallback: search common paths for any libconfig.so.*
        LIBCONFIG_SO="$(find /usr/lib /usr/lib64 /lib /lib64 -name 'libconfig.so*' -print -quit 2>/dev/null || true)"
    fi
    if [ -n "${LIBCONFIG_SO}" ] && [ -f "${LIBCONFIG_SO}" ]; then
        mkdir -p "${LIB_DIR}"
        cp "${LIBCONFIG_SO}" "${LIB_DIR}/"
        LIBCONFIG_BASENAME="$(basename "${LIBCONFIG_SO}")"
        # SONAME looks like "libconfig.so.9"; extract the trailing version.
        # An unversioned SONAME ("libconfig.so" with no dot) is unusual but
        # possible if the system lib has no ABI version; skip the SONAME
        # symlink in that case — the basename already matches the SONAME
        # the loader expects.
        LIBCONFIG_SONAME_VER="${SONAME##*.}"
        if [ -n "${LIBCONFIG_SONAME_VER}" ] && [ "${SONAME}" != "${LIBCONFIG_SONAME_VER}" ]; then
            LIBCONFIG_SONAME_FILE="libconfig.so.${LIBCONFIG_SONAME_VER}"
            # Only create the SONAME symlink when the copied file's basename
            # actually differs from it. Otherwise the symlink would point at
            # itself (ELOOP) — cp dereferences any source symlink, so even if
            # LIBCONFIG_SO was the SONAME symlink path itself, basename() is
            # whatever ldconfig -p reported; defensive guard either way.
            if [ "${LIBCONFIG_BASENAME}" != "${LIBCONFIG_SONAME_FILE}" ]; then
                ln -sf "${LIBCONFIG_BASENAME}" "${LIB_DIR}/${LIBCONFIG_SONAME_FILE}"
            fi
        fi
        # The unversioned .so symlink is always needed for the dynamic
        # linker; it always points at the versioned file we just copied.
        ln -sf "${LIBCONFIG_BASENAME}" "${LIB_DIR}/libconfig.so"
        echo "  Bundled: ${LIB_DIR}/${LIBCONFIG_BASENAME}"
    else
        echo "  ERROR: libconfig.so not found on system (install libconfig-dev)" >&2
        echo "  wmediumd will not run without it" >&2
        exit 1
    fi
fi

# Verify (RPATH is baked in via $ORIGIN, so no LD_LIBRARY_PATH is needed
# when the binary is run from ${BIN_DIR}). Exit non-zero on failure so
# the script does not silently leave a broken binary in place.
echo ""
echo "=== Verification ==="
if "${BIN_DIR}/wmediumd" -h >/dev/null 2>&1; then
    echo "wmediumd is ready"
else
    rc=$?
    echo "ERROR: ${BIN_DIR}/wmediumd failed verification (rc=${rc})." >&2
    echo "  Check the build log above and ensure libnl-3-dev and" >&2
    echo "  libconfig-dev (or distro equivalents) are installed." >&2
    exit 1
fi
