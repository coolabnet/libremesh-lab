#!/usr/bin/env bash
# Safe, non-mutating host preflight for future namespace/wmediumd tests.
set -euo pipefail

HWSIM_MODULE="${LIBREMESH_LAB_HWSIM_MODULE:-mac80211_hwsim}"
SYS_MODULE_DIR="${LIBREMESH_LAB_SYS_MODULE_DIR:-/sys/module}"
MODULES_DIR="${LIBREMESH_LAB_MODULES_DIR:-/lib/modules/$(uname -r)}"
RESULT=0

ok() {
    echo "  ok: $1"
}

missing() {
    echo "  missing: $1"
    RESULT=1
}

check_command() {
    local name="$1"
    if command -v "${name}" >/dev/null 2>&1; then
        ok "${name}: $(command -v "${name}")"
    else
        missing "${name} not found in PATH"
    fi
}

check_namespace_tool() {
    if command -v ip >/dev/null 2>&1 && ip netns list >/dev/null 2>&1; then
        ok "namespace tool: ip netns"
        return
    fi

    missing "namespace tool unavailable; install iproute2 with ip netns support"
}

check_hwsim_module() {
    if [ -d "${SYS_MODULE_DIR}/${HWSIM_MODULE}" ]; then
        ok "${HWSIM_MODULE}: module already loaded"
        return
    fi

    if [ -d "${MODULES_DIR}" ]; then
        local module_file
        module_file="$(find "${MODULES_DIR}" -type f \( -name "${HWSIM_MODULE}.ko" -o -name "${HWSIM_MODULE}.ko.*" \) -print -quit 2>/dev/null || true)"
        if [ -n "${module_file}" ]; then
            ok "${HWSIM_MODULE}: available at ${module_file}"
            return
        fi
    fi

    if command -v modprobe >/dev/null 2>&1; then
        if modprobe --show-depends "${HWSIM_MODULE}" >/dev/null 2>&1 || modprobe -n "${HWSIM_MODULE}" >/dev/null 2>&1; then
            ok "${HWSIM_MODULE}: available via modprobe dry-run"
            return
        fi
        missing "${HWSIM_MODULE} unavailable; modprobe dry-run could not resolve it"
        return
    fi

    missing "${HWSIM_MODULE} availability could not be checked because modprobe is missing"
}

echo "=== Namespace/wmediumd preflight ==="
echo "This check does not create namespaces, load modules, or require root."

check_command ip
check_command iw
check_command wmediumd
check_command modprobe
check_command ping
check_command timeout
check_namespace_tool
check_hwsim_module

if [ "${RESULT}" -eq 0 ]; then
    echo "Namespace/wmediumd preflight: ready"
else
    echo "Namespace/wmediumd preflight: missing requirements"
fi

exit "${RESULT}"
