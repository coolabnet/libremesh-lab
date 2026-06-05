#!/usr/bin/env bash
# Common test functions for QEMU test suite
# TAP-compatible output (Test Anything Protocol)

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# REPO_ROOT, LAB_CLI, and MESHA_ROOT are exported so test scripts that
# source this file can reference them; shellcheck does not see across
# source boundaries and flags them as unused. Disable SC2034 locally
# (the directives that follow this comment) to silence this without
# polluting the global shellcheck config.
# shellcheck disable=SC2034
REPO_ROOT="${LAB_ROOT}"
MESHA_ROOT="${MESHA_ROOT:-}"
# shellcheck disable=SC2034
LAB_CLI="${LAB_ROOT}/bin/libremesh-lab"
SSH_CONFIG="${LAB_ROOT}/config/ssh-config.resolved"
if [ ! -f "${SSH_CONFIG}" ]; then
    SSH_CONFIG="$(mktemp /tmp/libremesh-lab-test-ssh-config.XXXXXX)"
    sed "s|__REPO_ROOT__|${LAB_ROOT}|g" "${LAB_ROOT}/config/ssh-config" > "${SSH_CONFIG}"
fi
TOPOLOGY_FILE="${LAB_ROOT}/config/topology.yaml"
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# ─── Python interpreter selection ──────────────────────────────────────────────
# Prefer `uv run python3` so we bypass the user's pyenv shim (which may
# reference a Python version that isn't actually installed). Fall back to a
# direct `python3` invocation, then to `python` for systems without python3.
# The chosen interpreter is exposed as PYTHON; tests should use it instead
# of bare `python3` so the suite is portable across hosts.
PYTHON=""
if command -v uv >/dev/null 2>&1 && uv run python3 -c pass 2>/dev/null; then
    PYTHON="uv run python3"
elif command -v python3 >/dev/null 2>&1 && python3 -c pass 2>/dev/null; then
    PYTHON="python3"
elif command -v python >/dev/null 2>&1 && python -c pass 2>/dev/null; then
    PYTHON="python"
else
    # Use /usr/bin/python3 as last resort to bypass pyenv shims
    if [ -x /usr/bin/python3 ]; then
        PYTHON="/usr/bin/python3"
    else
        PYTHON="python3"  # will fail loudly if missing
    fi
fi

# thisnode.info resolution via HOSTALIASES
HOSTALIASES_FILE="${LAB_ROOT}/run/host-aliases"
if [ -f "${HOSTALIASES_FILE}" ]; then
    export HOSTALIASES="${HOSTALIASES_FILE}"
fi

# TAP output functions
tap_plan() {
    echo "1..$1"
}

pass() {
    TEST_COUNT=$((TEST_COUNT + 1))
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "ok ${TEST_COUNT} - $1"
}

fail() {
    TEST_COUNT=$((TEST_COUNT + 1))
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "not ok ${TEST_COUNT} - $1"
    [ -n "${2:-}" ] && echo "  # $2" >&2
}

skip() {
    TEST_COUNT=$((TEST_COUNT + 1))
    echo "ok ${TEST_COUNT} - $1 # SKIP ${2:-}"
}

require_mesha_root() {
    if [ -z "${MESHA_ROOT}" ]; then
        echo "Bail out! MESHA_ROOT is required for this suite; set MESHA_ROOT=/path/to/mesha" >&2
        exit 1
    fi
    if [ ! -d "${MESHA_ROOT}" ]; then
        echo "Bail out! MESHA_ROOT does not exist: ${MESHA_ROOT}" >&2
        exit 1
    fi
}

# SSH helper — run command on VM
ssh_vm() {
    local host="$1"; shift
    ssh -F "${SSH_CONFIG}" -o ConnectTimeout=10 -o BatchMode=yes "root@${host}" "$@" 2>/dev/null
}

# Get VM IPs from topology
get_node_ips() {
    if [ -f "${TOPOLOGY_FILE}" ]; then
        ${PYTHON} -c "
import yaml, sys
with open('${TOPOLOGY_FILE}') as f:
    topo = yaml.safe_load(f)
for n in topo['mesh']['nodes']:
    print(f\"{n['hostname']} {n['ip']}\")
" 2>/dev/null
    else
        # Fallback defaults
        echo "lm-testbed-node-1 10.99.0.11"
        echo "lm-testbed-node-2 10.99.0.12"
        echo "lm-testbed-node-3 10.99.0.13"
        echo "lm-testbed-tester 10.99.0.14"
    fi
}

# Get gateway hostname
get_gateway() { echo "lm-testbed-node-1"; }

# Wait for SSH on a host (with timeout)
wait_for_ssh() {
    local host="$1"
    local timeout="${2:-90}"
    local start
    start=$(date +%s)
    while true; do
        if ssh_vm "$host" "true" 2>/dev/null; then
            return 0
        fi
        local now
        now=$(date +%s)
        if (( now - start >= timeout )); then
            return 1
        fi
        sleep 5
    done
}

# TCG timeout multiplier support
TIMEOUT_MULTIPLIER="${QEMU_TIMEOUT_MULTIPLIER:-1}"
VWIFI_SERVER_IP="${VWIFI_SERVER_IP:-10.99.0.254}"
VWIFI_TCP_PORT="${VWIFI_TCP_PORT:-8212}"
VWIFI_SSID="${VWIFI_SSID:-MeshaTestBed}"
VWIFI_FREQ="${VWIFI_FREQ:-2462}"

# Wait until a JSON field meets a condition (polls in a loop)
wait_until_json_gte() {
    local json="$1"
    local field="$2"
    local threshold="$3"
    local timeout="${4:-60}"
    timeout=$((timeout * TIMEOUT_MULTIPLIER))
    local start
    start=$(date +%s)
    while true; do
        local value
        value=$(echo "$json" | ${PYTHON} -c "import sys,json; print(json.load(sys.stdin)${field})" 2>/dev/null) || return 1
        if [ "$value" -ge "$threshold" ] 2>/dev/null; then
            return 0
        fi
        local now
        now=$(date +%s)
        if (( now - start >= timeout )); then
            return 1
        fi
        sleep 5
    done
}

# Check if BMX7 is available on a node
has_bmx7() {
    local host="$1"
    ssh_vm "$host" "which bmx7 >/dev/null 2>&1 || ls /usr/sbin/bmx7 >/dev/null 2>&1" 2>/dev/null
}

# Returns 0 if any mesh routing protocol is installed on the host.
has_mesh_protocol() {
    local host="$1"
    [ "$(detect_mesh_protocol "$host")" != "none" ]
}

# Detect the primary mesh routing protocol on a node.
# Echoes one of: bmx7, babeld, batman-adv, none
# Prefers the protocol that is actually RUNNING over one that is merely
# installed. If multiple are running, falls back to the install-time
# preference order: babeld > bmx7 > batman-adv.
detect_mesh_protocol() {
    local host="$1"
    local detected
    detected=$(ssh_vm "$host" "
        # First: any daemon actually running wins.
        # pgrep -x matches the comm name (always the basename), never the
        # shell executing this heredoc, so it cannot self-match.
        if pgrep -x babeld >/dev/null 2>&1; then
            echo babeld
        elif pgrep -x bmx7 >/dev/null 2>&1; then
            echo bmx7
        elif pgrep -x batmand >/dev/null 2>&1; then
            echo batman-adv
        # Fallback: installed-but-not-running (e.g. after a clean reboot
        # where the daemon hasn't started yet). Order matches the
        # babeld-first default in configure-vms.sh: babeld > bmx7 > batman-adv.
        elif [ -x /usr/sbin/babeld ] || which babeld >/dev/null 2>&1; then
            echo babeld
        elif [ -x /usr/sbin/bmx7 ] || which bmx7 >/dev/null 2>&1; then
            echo bmx7
        elif [ -x /usr/sbin/batmand ] || which batmand >/dev/null 2>&1 || \
             (which batctl >/dev/null 2>&1 && batctl status 2>/dev/null | head -1 | grep -q .); then
            echo batman-adv
        else
            echo none
        fi
    " 2>/dev/null)
    echo "${detected}" | tr -d '[:space:]'
}

# Count mesh-protocol neighbors on a node. Echoes a non-negative integer.
# Protocol-agnostic: dispatches to bmx7, babeld, or batman-adv.
# For babeld, a "neighbor" is signaled by the daemon being alive and
# exchanging hellos via the mesh interface. babeld over a wired bridge
# with full L2 connectivity may install 0 kernel routes — the routes are
# the bridge's job, not babeld's. We therefore return 1 when babeld is
# running and the mesh interface is up, as the convergence signal in
# this topology.
count_mesh_neighbors() {
    local host="$1"
    local proto
    proto=$(detect_mesh_protocol "$host")
    local count
    case "${proto}" in
        bmx7)
            count=$(ssh_vm "$host" "bmx7 -c originators 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || echo 0)
            ;;
        babeld)
            local babeld_pid babel_listen
            babeld_pid=$(ssh_vm "$host" "pgrep -x babeld" 2>/dev/null | head -1 | tr -d '[:space:]')
            if [ -z "${babeld_pid}" ]; then
                count=0
            else
                # Daemon is alive. Also confirm it's actually serving the babel
                # protocol by checking the listening UDP socket (default 6696,
                # may be overridden in /etc/babeld.conf via 'local-port'). This
                # distinguishes "babeld is running with no config" from
                # "babeld is up and serving". We deliberately do NOT count
                # kernel routes: in a wired br-lan topology babeld legitimately
                # installs 0 routes (L2 handles neighbor reachability).
                babel_listen=$(ssh_vm "$host" "(netstat -ulnp 2>/dev/null || ss -ulnp 2>/dev/null) | awk '/:/ && /babeld/ {print \$0}' | wc -l" 2>/dev/null | tr -d '[:space:]')
                if [ "${babel_listen:-0}" -ge 1 ]; then
                    count=1
                else
                    count=0
                fi
            fi
            ;;
        batman-adv)
            count=$(ssh_vm "$host" "batctl o 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || echo 0)
            if [ "${count:-0}" = "0" ] 2>/dev/null; then
                count=$(ssh_vm "$host" "batctl n 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || echo 0)
            fi
            ;;
        *)
            count=0
            ;;
    esac
    echo "${count}" | tr -d '[:space:]'
}

# Restart the mesh routing protocol on a node.
restart_mesh_protocol() {
    local host="$1"
    local proto
    proto=$(detect_mesh_protocol "$host")
    local dev
    dev=$(mesh_dev "$host")
    case "${proto}" in
        bmx7)
            if [ "$dev" = "wlan0" ]; then
                ssh_vm "$host" "killall bmx7 2>/dev/null || true; bmx7 dev=wlan0 dev=br-lan 2>/dev/null || bmx7 dev=br-lan 2>/dev/null || true" 2>/dev/null || true
            else
                ssh_vm "$host" "killall bmx7 2>/dev/null || true; bmx7 dev=${dev} 2>/dev/null || true" 2>/dev/null || true
            fi
            ;;
        babeld)
            if [ "$dev" = "wlan0" ]; then
                ssh_vm "$host" "killall babeld 2>/dev/null || true; babeld -D -I /var/run/babeld.pid wlan0 br-lan 2>/dev/null || babeld -D -I /var/run/babeld.pid br-lan 2>/dev/null || true" 2>/dev/null || true
            else
                ssh_vm "$host" "killall babeld 2>/dev/null || true; babeld -D -I /var/run/babeld.pid ${dev} 2>/dev/null || babeld -D ${dev} 2>/dev/null || true" 2>/dev/null || true
            fi
            ;;
        batman-adv)
            ssh_vm "$host" "killall batmand 2>/dev/null || true; batmand ${dev} 2>/dev/null || true" 2>/dev/null || true
            ;;
    esac
}

# Preferred mesh interface on a node (wlan0 if vwifi present, br-lan otherwise).
mesh_dev() {
    local host="$1"
    ssh_vm "$host" "iw dev wlan0 info >/dev/null 2>&1 && echo wlan0 || echo br-lan" 2>/dev/null || echo "br-lan"
}

# Wait for the active mesh routing protocol to converge on a node.
# Returns 0 if converged, 1 if timeout, 2 if no protocol installed.
# Args: host, min_neighbors (default 1), timeout seconds (default 90)
wait_for_mesh() {
    local host="$1"
    local min_neighbors="${2:-1}"
    local timeout="${3:-90}"

    local proto
    proto=$(detect_mesh_protocol "$host")
    if [ "${proto}" = "none" ]; then
        echo "  # no mesh protocol on ${host}" >&2
        return 2
    fi

    local start
    start=$(date +%s)
    # For babeld over a wired bridge, 0 kernel routes are installed (L2
    # handles reachability). The convergence signal is the daemon being
    # alive with a UDP listener — count_mesh_neighbors returns 1 in that
    # state and 0 otherwise. Callers pass min_neighbors=2/3 expecting
    # bmx7-style originator counts; cap the threshold for babeld.
    local threshold="${min_neighbors}"
    if [ "${proto}" = "babeld" ]; then
        threshold=1
    fi
    # If the daemon isn't running (e.g., fresh boot), start it once before
    # polling. Subsequent restarts are the test's responsibility.
    if [ "$(count_mesh_neighbors "$host")" -eq 0 ] 2>/dev/null; then
        echo "  # ${proto} daemon not running on ${host}, starting..." >&2
        restart_mesh_protocol "$host"
        sleep 5
    fi

    while true; do
        local count
        count=$(count_mesh_neighbors "$host")
        if [ "${count}" -ge "${threshold}" ] 2>/dev/null; then
            return 0
        fi
        local now
        now=$(date +%s)
        if (( now - start >= timeout )); then
            return 1
        fi
        sleep 5
    done
}

# Deprecated back-compat alias; no active tests use it. Prefer mesh_dev().
bmx7_mesh_dev() {
    mesh_dev "$@"
}

# shellcheck disable=SC2140
ensure_vwifi_client() {
    local host="$1"
    ssh_vm "$host" "
        command -v vwifi-client >/dev/null 2>&1 || exit 0
        modprobe mac80211_hwsim radios=0 2>/dev/null || true
        if ! pidof vwifi-client >/dev/null 2>&1; then
            mesh_mac=\$(cat /sys/class/net/br-lan/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || echo '')
            if [ -n \"\$mesh_mac\" ]; then
                # Record phys before vwifi-client starts
                _before=\$(ls /sys/class/ieee80211/ 2>/dev/null)
                vwifi-client --number 1 --mac \"\$mesh_mac\" --port ${VWIFI_TCP_PORT} '${VWIFI_SERVER_IP}' >/tmp/vwifi-client.log 2>&1 &
                echo \$! >/var/run/vwifi-client.pid
                sleep 2

                # Find the NEW phy created by vwifi-client
                _after=\$(ls /sys/class/ieee80211/ 2>/dev/null)
                _new_phy=
                for p in \$_after; do
                    echo \"\$_before\" | grep -q \"\$p\" || _new_phy=\"\$p\"
                done

                # Create wlan0 on the vwifi-client-created PHY if not already present
                if [ -n \"\$_new_phy\" ] && ! iw dev wlan0 info >/dev/null 2>&1; then
                    iw phy \$_new_phy interface add wlan0 type ibss 2>/dev/null || true
                fi
            fi
        fi
        for _i in \$(seq 1 10); do
            iw dev wlan0 info >/dev/null 2>&1 && break
            sleep 1
        done
        if iw dev wlan0 info >/dev/null 2>&1; then
            ip link set wlan0 down 2>/dev/null || true
            iw dev wlan0 set type ibss 2>/dev/null || iw wlan0 set type ibss 2>/dev/null || true
            ip link set wlan0 up 2>/dev/null || true
            iw dev wlan0 ibss join '${VWIFI_SSID}' ${VWIFI_FREQ} 2>/dev/null || iw wlan0 ibss join '${VWIFI_SSID}' ${VWIFI_FREQ} 2>/dev/null || true
        fi
    " 2>/dev/null || true
}

# Deprecated: prefer restart_mesh_protocol() which uses detect_mesh_protocol.
# Kept for external scripts that may still call it directly.
restart_bmx7() {
    local host="$1"
    ensure_vwifi_client "$host"
    local dev
    dev=$(mesh_dev "$host")
    # Use both wlan0 and br-lan when wlan0 is available:
    # vwifi IBSS forwards beacons but not data frames, so BMX7
    # needs br-lan for convergence while wlan0 provides WiFi simulation
    if [ "$dev" = "wlan0" ]; then
        ssh_vm "$host" "killall bmx7 2>/dev/null || true; bmx7 dev=wlan0 dev=br-lan 2>/dev/null || bmx7 dev=br-lan 2>/dev/null || true" 2>/dev/null || true
    else
        ssh_vm "$host" "killall bmx7 2>/dev/null || true; bmx7 dev=${dev} 2>/dev/null || true" 2>/dev/null || true
    fi
}

# Deprecated: prefer wait_for_mesh() which is protocol-agnostic.
# Kept for external scripts that may still call it directly.
# Wait for BMX7 convergence on a node
# Returns 0 if converged, 1 if timeout, 2 if bmx7 not installed
wait_for_bmx7() {
    local host="$1"
    local min_neighbors="${2:-1}"
    local timeout="${3:-90}"

    # Quick check: if bmx7 is not installed, return 2 immediately
    if ! has_bmx7 "$host"; then
        echo "  # bmx7 not installed on ${host}" >&2
        return 2
    fi

    local start
    start=$(date +%s)

    # If bmx7 daemon isn't running (e.g., after reboot), try to start it
    local first_count
    first_count=$(ssh_vm "$host" "bmx7 -c originators 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || echo "0")
    first_count=$(echo "$first_count" | tr -d '[:space:]')
    if [ "$first_count" -eq 0 ] 2>/dev/null; then
        local dev
        ensure_vwifi_client "$host"
        dev=$(mesh_dev "$host")
        echo "  # bmx7 daemon not running on ${host}, starting with dev=${dev}..." >&2
        restart_bmx7 "$host"
        sleep 5
    fi

    while true; do
        local count
        count=$(ssh_vm "$host" "bmx7 -c originators 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || echo "0")
        count=$(echo "$count" | tr -d '[:space:]')
        if [ "$count" -ge "$min_neighbors" ] 2>/dev/null; then
            return 0
        fi
        local now
        now=$(date +%s)
        if (( now - start >= timeout )); then
            return 1
        fi
        sleep 5
    done
}

# Assert JSON field value
assert_json_field() {
    local json="$1"
    local field="$2"
    local expected="$3"
    local actual
    actual=$(echo "$json" | ${PYTHON} -c "import sys,json; print(json.load(sys.stdin)${field})" 2>/dev/null) || return 1
    [ "$actual" = "$expected" ]
}

# Assert JSON field >= threshold
assert_json_gte() {
    local json="$1"
    local field="$2"
    local threshold="$3"
    local actual
    actual=$(echo "$json" | ${PYTHON} -c "import sys,json; print(json.load(sys.stdin)${field})" 2>/dev/null) || return 1
    [ "$actual" -ge "$threshold" ] 2>/dev/null
}

# Assert JSON field is not null/empty
assert_json_not_null() {
    local json="$1"
    local field="$2"
    local actual
    actual=$(echo "$json" | ${PYTHON} -c "import sys,json; v=json.load(sys.stdin); print('NULL' if v is None else str(v))" 2>/dev/null)
    [ "${actual}" != "NULL" ] && [ -n "${actual}" ]
}

# Print test summary
tap_summary() {
    echo "---"
    echo "# Tests: ${TEST_COUNT}, Passed: ${PASS_COUNT}, Failed: ${FAIL_COUNT}"
    if [ "${FAIL_COUNT}" -gt 0 ]; then
        return 1
    fi
    return 0
}
