#!/usr/bin/env bash
# rollback-lab.sh — Comprehensive undo for the lab start/configure/test sequence.
# Idempotent: safe to run multiple times. Run as root (uses sudo internally).
#
# What it undoes:
#   1. Stops the lab (kills QEMU VMs, vwifi-server, dnsmasq)
#   2. Removes TAP devices (mesha-tap0..3)
#   3. Removes the bridge (mesha-br0)
#   4. Removes runtime state in run/ (pid files, dhcp leases, start.log)
#   5. Removes the testbed lock directory
#
# What it does NOT undo (intentional — these are user-requested changes):
#   - Passwordless sudo rule at /etc/sudoers.d/libremesh-lab-nopasswd
#   - Vendored bin/wmediumd and bin/lib/libconfig.so.9
#   - Image files under images/
#   - Ssh keys under run/ssh-keys/ (id_ed25519 was generated for this host)
#
# To undo those too, run with: sudo bin/rollback-lab.sh --full

set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${LAB_ROOT}/run"
BRIDGE_NAME="mesha-br0"
TAP_PREFIX="mesha-tap"
NODE_COUNT=4
# Extra scoping tokens to make process cleanup safe on shared/developer
# hosts where other QEMU VMs, vwifi instances, or dnsmasq servers may be
# running. We only target processes that reference one of these tokens in
# their cmdline — that way `pgrep -f` cannot hit unrelated host services.
LAB_SCOPE_TOKENS=("mesha-" "${BRIDGE_NAME}" "${TAP_PREFIX}" "${LAB_ROOT}/run" "vwifi")

FULL_UNDO=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full) FULL_UNDO=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "[ERROR] Unknown option: $1" >&2
            exit 2
            ;;
        *)
            echo "[ERROR] Unexpected positional argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "Re-running with sudo..."
    # Drop PATH from the preserved set so the re-exec'd root script cannot
    # pick up attacker-controlled binaries from the invoking user's PATH.
    # PATH is intentionally not preserved: every command uses bare names
    # (`ip`, `pgrep`, `kill`, `tr`, `sleep`, `sort`, `printf`), which sudo
    # resolves via its default `secure_path` (set in /etc/sudoers).
    # Not preserving PATH prevents a maliciously-set PATH in the calling
    # shell from redirecting `ip`/`pgrep`/`kill` to a trojaned binary
    # under the privileged context. LAB_ROOT is recomputed from
    # BASH_SOURCE[0] at line 22 on the re-exec, so it does not need
    # to be preserved; we use bare `sudo --` with no --preserve-env.
    exec sudo -- "$0" "$@"
fi

echo "=========================================="
echo " LibreMesh Lab Rollback"
echo "=========================================="

# ─── 1. Stop the lab via the CLI (uses pid files) ────────────────────────────
echo ""
echo "--- Stopping lab via libremesh-lab stop ---"
if [ -x "${LAB_ROOT}/bin/libremesh-lab" ]; then
    "${LAB_ROOT}/bin/libremesh-lab" stop 2>&1 || true
fi

# ─── 2. Force-kill any lab-scoped QEMU/vwifi/dnsmasq leftovers ──────────────
# A naked `pgrep -f qemu-system` would kill unrelated QEMU VMs on a host
# that runs more than one lab. We only target processes whose cmdline
# references one of LAB_SCOPE_TOKENS — that anchors the kill to processes
# that touch this lab's bridge, TAPs, or runtime directory.
echo ""
echo "--- Force-killing any leftover lab-scoped processes ---"
for pattern in qemu-system vwifi-server dnsmasq; do
    pids=""
    for token in "${LAB_SCOPE_TOKENS[@]}"; do
        token_pids=$(pgrep -f "${pattern}.*${token}" 2>/dev/null || true)
        # pgrep matches either the pattern before or after the token; require
        # both substrings to co-occur in the cmdline to avoid false positives.
        for pid in ${token_pids}; do
            if [ -r "/proc/${pid}/cmdline" ]; then
                cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)
                if [[ "${cmdline}" == *"${pattern}"* ]] \
                   && [[ "${cmdline}" == *"${token}"* ]]; then
                    pids="${pids:+${pids} }${pid}"
                fi
            fi
        done
    done
    # De-dupe. The unquoted ${pids} is intentional: word-splitting turns
    # the space-separated list into one argv per PID, so `sort -u` sees
    # one line per PID and can collapse duplicates. Quoting would pass
    # the whole string as one argv and break dedup.
    if [ -n "${pids}" ]; then
        # shellcheck disable=SC2086
        pids=$(printf '%s\n' ${pids} | sort -u | tr '\n' ' ')
    fi
    if [ -n "${pids}" ]; then
        echo "  Killing ${pattern} PIDs: ${pids}"
        for pid in ${pids}; do
            kill -TERM "${pid}" 2>/dev/null || true
        done
        sleep 1
        # Re-validate each PID against the same scoping rule before KILL.
        # A TERM'd process can exit and its PID can be reused by an
        # unrelated process before we get a chance to KILL; verifying the
        # cmdline still matches prevents root from killing the wrong PID.
        for pid in ${pids}; do
            still_ours=false
            if [ -r "/proc/${pid}/cmdline" ]; then
                cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)
                if [[ "${cmdline}" == *"${pattern}"* ]]; then
                    for token in "${LAB_SCOPE_TOKENS[@]}"; do
                        if [[ "${cmdline}" == *"${token}"* ]]; then
                            still_ours=true
                            break
                        fi
                    done
                fi
            fi
            if [ "${still_ours}" = "true" ]; then
                kill -KILL "${pid}" 2>/dev/null || true
            fi
        done
    fi
done

# ─── 3. Remove TAP devices ──────────────────────────────────────────────────
echo ""
echo "--- Removing TAP devices ---"
for i in $(seq 0 $((NODE_COUNT - 1))); do
    tap="${TAP_PREFIX}${i}"
    if ip link show "${tap}" &>/dev/null; then
        echo "  Removing ${tap}..."
        ip link set "${tap}" down 2>/dev/null || true
        ip link set "${tap}" nomaster 2>/dev/null || true
        ip tuntap del dev "${tap}" mode tap 2>/dev/null || true
    fi
done

# ─── 4. Remove the bridge ───────────────────────────────────────────────────
echo ""
echo "--- Removing bridge ---"
if ip link show "${BRIDGE_NAME}" &>/dev/null; then
    echo "  Removing ${BRIDGE_NAME}..."
    ip link set "${BRIDGE_NAME}" down 2>/dev/null || true
    ip link del "${BRIDGE_NAME}" 2>/dev/null || true
fi

# ─── 5. Clean runtime state ─────────────────────────────────────────────────
echo ""
echo "--- Cleaning runtime state in ${RUN_DIR} ---"
if [ -d "${RUN_DIR}" ]; then
    # Remove lock dir (will fail if non-empty, that's fine)
    rm -rf "${RUN_DIR}/testbed.lock" 2>/dev/null || true
    # Remove pid files and DHCP lease files
    rm -f "${RUN_DIR}"/node-*.pid \
          "${RUN_DIR}"/vwifi-server.pid \
          "${RUN_DIR}"/dnsmasq-dhcp.pid \
          "${RUN_DIR}"/dnsmasq-dhcp.leases 2>/dev/null || true
    # Rotate (don't delete) the start log so the user can see what happened.
    # Use a counter suffix to avoid collisions on rapid successive rollbacks.
    if [ -f "${RUN_DIR}/start.log" ]; then
        base="${RUN_DIR}/start.log.$(date +%Y%m%d-%H%M%S).bak"
        rotated="${base}"
        n=0
        while [ -e "${rotated}" ]; do
            n=$((n + 1))
            rotated="${base}.${n}"
        done
        mv "${RUN_DIR}/start.log" "${rotated}" 2>/dev/null || true
    fi
fi

# ─── 6. Verify clean state ──────────────────────────────────────────────────
# Count only lab-scoped stragglers (same cmdline token rule as the
# kill pass), so a host that legitimately runs other QEMU VMs / dnsmasq
# instances does not produce false-positive "dirty" results.
echo ""
echo "--- Verifying clean state ---"
count_scoped() {
    local pattern="$1"
    local count=0
    for pid in $(pgrep -f "${pattern}" 2>/dev/null || true); do
        [ -r "/proc/${pid}/cmdline" ] || continue
        local cmdline
        cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)
        for token in "${LAB_SCOPE_TOKENS[@]}"; do
            if [[ "${cmdline}" == *"${pattern}"* ]] && [[ "${cmdline}" == *"${token}"* ]]; then
                count=$((count + 1))
                break
            fi
        done
    done
    echo "${count}"
}
REMAINING_QEMU=$(count_scoped "qemu-system")
REMAINING_VWIFI=$(count_scoped "vwifi-server")
# dnsmasq is checked via the same cmdline-token rule as QEMU/vwifi.
# The script's kill pass targets dnsmasq (line 83) and the verification
# pass must check it too, otherwise a stuck dnsmasq holding the bridge's
# DHCP state would be reported as "clean".
REMAINING_DNSMASQ=$(count_scoped "dnsmasq")
REMAINING_TAPS=0
# Bridge and TAPs are looked up by exact name, not by cmdline scan, so a
# simple `ip link show` is sufficient and avoids the wc -l "lines vs
# devices" pitfall (ip link show prints multi-line output per device).
REMAINING_BRIDGE=0
if ip link show "${BRIDGE_NAME}" &>/dev/null; then
    echo "  FAILED to clean up bridge ${BRIDGE_NAME}"
    REMAINING_BRIDGE=1
fi
# TAP removal above iterates `seq 0 $((NODE_COUNT-1))`; verify the same range.
for i in $(seq 0 $((NODE_COUNT - 1))); do
    if ip link show "${TAP_PREFIX}${i}" &>/dev/null; then
        REMAINING_TAPS=$((REMAINING_TAPS + 1))
    fi
done

echo "  QEMU processes:        ${REMAINING_QEMU}"
echo "  vwifi processes:       ${REMAINING_VWIFI}"
echo "  dnsmasq processes:     ${REMAINING_DNSMASQ}"
echo "  Bridge ${BRIDGE_NAME}:       $([ "${REMAINING_BRIDGE}" -gt 0 ] && echo "PRESENT" || echo "absent")"
echo "  TAP ${TAP_PREFIX}* devices:  ${REMAINING_TAPS}"

CLEAN_OK=true
if [ "${REMAINING_QEMU}" -gt 0 ] || [ "${REMAINING_VWIFI}" -gt 0 ] \
   || [ "${REMAINING_DNSMASQ}" -gt 0 ] \
   || [ "${REMAINING_BRIDGE}" -gt 0 ] || [ "${REMAINING_TAPS}" -gt 0 ]; then
    CLEAN_OK=false
fi

# ─── 7. Optional full undo ──────────────────────────────────────────────────
if [ "${FULL_UNDO}" = "true" ]; then
    echo ""
    echo "--- Full undo: removing sudo rule and build artifacts ---"
    if [ -f /etc/sudoers.d/libremesh-lab-nopasswd ]; then
        rm -f /etc/sudoers.d/libremesh-lab-nopasswd
        echo "  Removed /etc/sudoers.d/libremesh-lab-nopasswd"
    else
        echo "  /etc/sudoers.d/libremesh-lab-nopasswd not present (no-op)"
    fi
    # bin/wmediumd and bin/lib/* are gitignored build artifacts. Remove them
    # so the tree is fully back to a clean checkout. The user will need to
    # re-run scripts/qemu/build-wmediumd.sh to rebuild wmediumd on next use.
    if [ -f "${LAB_ROOT}/bin/wmediumd" ]; then
        rm -f "${LAB_ROOT}/bin/wmediumd"
        echo "  Removed bin/wmediumd"
    fi
    if [ -d "${LAB_ROOT}/bin/lib" ]; then
        rm -rf "${LAB_ROOT}/bin/lib"
        echo "  Removed bin/lib/"
    fi
fi

echo ""
echo "=========================================="
if [ "${CLEAN_OK}" = "true" ]; then
    echo " Rollback: clean"
    echo "=========================================="
    exit 0
else
    echo " Rollback: DIRTY (some stragglers remain — see above)"
    echo "=========================================="
    # Non-zero exit so automation (CI, mesha adapter, etc.) treats a
    # partial teardown as a failure. The caller can inspect the
    # verification counts above to identify what was left behind.
    exit 1
fi
