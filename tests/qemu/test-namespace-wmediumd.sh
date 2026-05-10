#!/usr/bin/env bash
# Root-gated namespace/wmediumd smoke test using two mac80211_hwsim radios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Namespace Wmediumd Tests"
tap_plan 5

TEST_ID="${LIBREMESH_LAB_NAMESPACE_TEST_ID:-libremesh-lab-ns-$$}"
NS_NAME="${LIBREMESH_LAB_NAMESPACE_NAME:-${TEST_ID}-node2}"
MESH_ID="${LIBREMESH_LAB_NAMESPACE_MESH_ID:-libremesh-lab-mesh}"
CHANNEL="${LIBREMESH_LAB_NAMESPACE_CHANNEL:-149}"
IP1_CIDR="${LIBREMESH_LAB_NAMESPACE_IP1:-10.230.0.1/24}"
IP2_CIDR="${LIBREMESH_LAB_NAMESPACE_IP2:-10.230.0.2/24}"
IP2="${IP2_CIDR%%/*}"
MAC1="${LIBREMESH_LAB_NAMESPACE_MAC1:-42:00:00:00:00:00}"
MAC2="${LIBREMESH_LAB_NAMESPACE_MAC2:-42:00:00:00:01:00}"
PING_TIMEOUT="${LIBREMESH_LAB_NAMESPACE_PING_TIMEOUT:-30}"
RESET_HWSIM="${LIBREMESH_LAB_NAMESPACE_RESET_HWSIM:-0}"
TMP_DIR="$(mktemp -d /tmp/libremesh-lab-namespace.XXXXXX)"
WMEDIUMD_PID=""
NS_KEEPER_PID=""
LOADED_HWSIM=0
IF1=""
IF2=""

cleanup() {
    set +e
    if [ -n "${IF1}" ]; then
        iw dev "${IF1}" mesh leave >/dev/null 2>&1 || true
        ip link set "${IF1}" down >/dev/null 2>&1 || true
    fi
    if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "${NS_NAME}"; then
        if [ -n "${IF2}" ]; then
            ip netns exec "${NS_NAME}" iw dev "${IF2}" mesh leave >/dev/null 2>&1 || true
            ip netns exec "${NS_NAME}" ip link set "${IF2}" down >/dev/null 2>&1 || true
        fi
    fi
    if [ -n "${WMEDIUMD_PID}" ]; then
        kill "${WMEDIUMD_PID}" >/dev/null 2>&1 || true
        wait "${WMEDIUMD_PID}" >/dev/null 2>&1 || true
    fi
    if [ -n "${NS_KEEPER_PID}" ]; then
        kill "${NS_KEEPER_PID}" >/dev/null 2>&1 || true
        wait "${NS_KEEPER_PID}" >/dev/null 2>&1 || true
    fi
    ip netns del "${NS_NAME}" >/dev/null 2>&1 || true
    if [ "${LOADED_HWSIM}" -eq 1 ]; then
        modprobe -r mac80211_hwsim >/dev/null 2>&1 || true
    fi
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

require_root_and_tools() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "test_namespace_requires_root" "run with sudo or as root"
        tap_summary
        exit 1
    fi

    local missing_tools=""
    for tool in ip iw modprobe wmediumd ping timeout awk find readlink; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            missing_tools="${missing_tools} ${tool}"
        fi
    done
    if [ -n "${missing_tools}" ]; then
        fail "test_namespace_has_required_tools" "missing:${missing_tools}"
        tap_summary
        exit 1
    fi
    pass "test_namespace_has_required_tools"
}

hwsim_loaded() {
    [ -d /sys/module/mac80211_hwsim ]
}

hwsim_phys() {
    local driver phy phy_path
    for phy_path in /sys/class/ieee80211/*; do
        [ -e "${phy_path}" ] || continue
        phy="$(basename "${phy_path}")"
        driver="$(basename "$(readlink -f "${phy_path}/device/driver" 2>/dev/null)" 2>/dev/null || true)"
        if [ "${driver}" = "mac80211_hwsim" ]; then
            printf '%s\n' "${phy}"
        fi
    done
}

wait_for_hwsim_phys() {
    local timeout="${1:-10}"
    local start now count
    start="$(date +%s)"
    while true; do
        count="$(hwsim_phys | wc -l | tr -d '[:space:]')"
        if [ "${count}" -ge 2 ]; then
            return 0
        fi
        now="$(date +%s)"
        if (( now - start >= timeout )); then
            return 1
        fi
        sleep 1
    done
}

phy_interface() {
    local phy="$1"
    iw phy "${phy}" info | awk '/Interface/ {print $2; exit}'
}

setup_hwsim() {
    if hwsim_loaded; then
        if [ "${RESET_HWSIM}" != "1" ]; then
            fail "test_namespace_loads_disposable_hwsim" "mac80211_hwsim already loaded; use an isolated host or set LIBREMESH_LAB_NAMESPACE_RESET_HWSIM=1"
            tap_summary
            exit 1
        fi
        modprobe -r mac80211_hwsim
    fi

    modprobe mac80211_hwsim radios=2
    LOADED_HWSIM=1
    if wait_for_hwsim_phys 10; then
        pass "test_namespace_loads_disposable_hwsim"
    else
        fail "test_namespace_loads_disposable_hwsim" "did not find two mac80211_hwsim phys"
        tap_summary
        exit 1
    fi
}

write_wmediumd_config() {
    cat > "${TMP_DIR}/wmediumd.cfg" <<CFG
ifaces :
{
    ids = [
        "${MAC1}",
        "${MAC2}"
    ];
};
model :
{
    type = "prob";
    default_prob = 0.0;
};
CFG
}

configure_mesh_interfaces() {
    local phys phy1 phy2
    mapfile -t phys < <(hwsim_phys)
    phy1="${phys[0]}"
    phy2="${phys[1]}"
    IF1="$(phy_interface "${phy1}")"
    if [ -z "${IF1}" ]; then
        fail "test_namespace_configures_mesh_interfaces" "no interface found for ${phy1}"
        tap_summary
        exit 1
    fi

    ip netns add "${NS_NAME}"
    ip netns exec "${NS_NAME}" sh -c 'sleep 600' &
    NS_KEEPER_PID="$!"
    sleep 1
    iw phy "${phy2}" set netns "${NS_KEEPER_PID}"
    IF2="$(ip netns exec "${NS_NAME}" iw dev | awk '/Interface/ {print $2; exit}')"
    if [ -z "${IF2}" ]; then
        fail "test_namespace_configures_mesh_interfaces" "no interface found inside ${NS_NAME}"
        tap_summary
        exit 1
    fi

    ip link set "${IF1}" down
    iw dev "${IF1}" set type mp
    ip link set dev "${IF1}" address "${MAC1}"

    ip netns exec "${NS_NAME}" ip link set lo up
    ip netns exec "${NS_NAME}" ip link set "${IF2}" down
    ip netns exec "${NS_NAME}" iw dev "${IF2}" set type mp
    ip netns exec "${NS_NAME}" ip link set dev "${IF2}" address "${MAC2}"

    pass "test_namespace_configures_mesh_interfaces"
}

start_wmediumd() {
    write_wmediumd_config
    wmediumd -c "${TMP_DIR}/wmediumd.cfg" > "${TMP_DIR}/wmediumd.log" 2>&1 &
    WMEDIUMD_PID="$!"
    sleep 1
    if kill -0 "${WMEDIUMD_PID}" >/dev/null 2>&1; then
        pass "test_namespace_starts_wmediumd"
    else
        fail "test_namespace_starts_wmediumd" "$(cat "${TMP_DIR}/wmediumd.log" 2>/dev/null)"
        tap_summary
        exit 1
    fi
}

join_and_ping_mesh() {
    ip link set "${IF1}" up
    ip addr add "${IP1_CIDR}" dev "${IF1}"
    iw dev "${IF1}" set channel "${CHANNEL}"
    iw dev "${IF1}" mesh join "${MESH_ID}"

    ip netns exec "${NS_NAME}" ip link set "${IF2}" up
    ip netns exec "${NS_NAME}" ip addr add "${IP2_CIDR}" dev "${IF2}"
    ip netns exec "${NS_NAME}" iw dev "${IF2}" set channel "${CHANNEL}"
    ip netns exec "${NS_NAME}" iw dev "${IF2}" mesh join "${MESH_ID}"

    if timeout "${PING_TIMEOUT}" bash -c "until ping -c 1 -W 1 '${IP2}' >/dev/null 2>&1; do sleep 1; done"; then
        pass "test_namespace_mesh_ping_over_wmediumd"
    else
        echo "  # root namespace interface:" >&2
        ip addr show dev "${IF1}" >&2 || true
        echo "  # namespace interface:" >&2
        ip netns exec "${NS_NAME}" ip addr show dev "${IF2}" >&2 || true
        echo "  # wmediumd log:" >&2
        sed 's/^/  # /' "${TMP_DIR}/wmediumd.log" >&2 || true
        fail "test_namespace_mesh_ping_over_wmediumd" "ping to ${IP2} timed out"
        tap_summary
        exit 1
    fi
}

require_root_and_tools
setup_hwsim
configure_mesh_interfaces
start_wmediumd
join_and_ping_mesh
tap_summary
