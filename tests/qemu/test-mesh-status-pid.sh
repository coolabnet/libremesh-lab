#!/usr/bin/env bash
# Runtime test for mesh-status.sh /proc-based PID aliveness check.
# The staged code changed `kill -0 $pid` to `[ -d /proc/$pid ]` so that
# `bin/libremesh-lab status` correctly reports a VM as running even when
# the QEMU process is owned by a different user (e.g. started via sudo).
# A cmdline check (`grep -q "qemu-system" /proc/$pid/cmdline`) was also
# added to defeat PID-reuse false positives after a QEMU exit.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Mesh Status PID Tests"
tap_plan 5

RUN_DIR="${LAB_ROOT}/run"
PID_FILE="${RUN_DIR}/node-1.pid"
VWIFI_PID_FILE="${RUN_DIR}/vwifi-server.pid"

# Create run/ on demand so the test works on a fresh CI checkout (run/ is
# gitignored runtime state). We track whether we created it so the cleanup
# trap can remove it again and not leave noise in the working tree.
RUN_DIR_CREATED_BY_TEST=false
if [ ! -d "${RUN_DIR}" ]; then
    mkdir -p "${RUN_DIR}"
    RUN_DIR_CREATED_BY_TEST=true
fi

# Skip if any live lab pid file exists AND points at a real QEMU/vwifi
# process — we must not clobber a real running lab. Scan ALL node-*.pid
# files plus vwifi-server.pid (not just the first one); a same-user
# running lab usually has writable pid files and the first check alone
# would let us clobber node-2.pid while the live QEMU is running.
LIVE_LAB_PIDS=()
for pid_file in "${RUN_DIR}"/node-*.pid "${VWIFI_PID_FILE}"; do
    [ -f "${pid_file}" ] || continue
    pid=$(cat "${pid_file}" 2>/dev/null || true)
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    if [ -d "/proc/${pid}" ] && grep -qE "qemu-system|vwifi-server" "/proc/${pid}/cmdline" 2>/dev/null; then
        LIVE_LAB_PIDS+=("$(basename "${pid_file}")=${pid}")
    fi
done
if [ "${#LIVE_LAB_PIDS[@]}" -gt 0 ]; then
    skip "test_mesh_status_reports_live_pid_as_running" "live lab detected (${LIVE_LAB_PIDS[*]})"
    skip "test_mesh_status_reports_stale_pid_as_stopped" "live lab detected"
    skip "test_mesh_status_pid_check_survives_unreadable_pid_file" "live lab detected"
    skip "test_mesh_status_vwifi_pid_reports_live" "live lab detected"
    skip "test_mesh_status_vwifi_pid_reports_stale" "live lab detected"
    tap_summary
    exit 0
fi

# Pick a PID that does not exist on this system. Use pid_max-1 (the kernel
# never assigns the maximum PID to a live process), instead of a hardcoded
# value that may collide with real processes on busy CI runners.
if [ -r /proc/sys/kernel/pid_max ]; then
    STALE_PID=$(($(cat /proc/sys/kernel/pid_max) - 1))
else
    STALE_PID=999999
fi
if [ -d "/proc/${STALE_PID}" ]; then
    skip "test_mesh_status_reports_stale_pid_as_stopped" "PID ${STALE_PID} unexpectedly exists on this system"
    STALE_PID_UNAVAILABLE=true
else
    STALE_PID_UNAVAILABLE=false
fi

# Preserve any pre-existing pid file so the test is non-destructive.
HAD_BACKUP=false
BACKUP=""
if [ -f "${PID_FILE}" ]; then
    HAD_BACKUP=true
    BACKUP=$(mktemp)
    cp "${PID_FILE}" "${BACKUP}"
fi

VWIFI_HAD_BACKUP=false
VWIFI_BACKUP=""
if [ -f "${VWIFI_PID_FILE}" ]; then
    VWIFI_HAD_BACKUP=true
    VWIFI_BACKUP=$(mktemp)
    cp "${VWIFI_PID_FILE}" "${VWIFI_BACKUP}"
fi

cleanup() {
    if [ "${HAD_BACKUP}" = "true" ] && [ -f "${BACKUP}" ]; then
        cp "${BACKUP}" "${PID_FILE}"
        rm -f "${BACKUP}"
    else
        rm -f "${PID_FILE}"
    fi
    # Also restore any vwifi pid file we touched, and remove the run/ dir
    # if we created it.
    if [ "${VWIFI_HAD_BACKUP}" = "true" ] && [ -f "${VWIFI_BACKUP}" ]; then
        cp "${VWIFI_BACKUP}" "${VWIFI_PID_FILE}"
        rm -f "${VWIFI_BACKUP}"
    else
        rm -f "${VWIFI_PID_FILE}"
    fi
    if [ "${RUN_DIR_CREATED_BY_TEST}" = "true" ] && [ -d "${RUN_DIR}" ]; then
        rmdir "${RUN_DIR}" 2>/dev/null || true
    fi
    # Kill any fake QEMU/vwifi processes we spawned so they don't outlive
    # the test (e.g. on Ctrl-C before the inline kill at the end of each
    # test block). Best-effort: ignore failures if the process already
    # exited.
    for fake_pid in "${FAKE_QEMU_PID:-}" "${FAKE_VWIFI_PID:-}"; do
        [ -n "${fake_pid}" ] || continue
        [[ "${fake_pid}" =~ ^[0-9]+$ ]] || continue
        if [ -d "/proc/${fake_pid}" ]; then
            kill "${fake_pid}" 2>/dev/null || true
        fi
    done
    # Reap any backgrounded fake-process subshells (no-op if already done).
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ─── Live PID is reported as running ──────────────────────────────────────────
# Spawn a fake QEMU-shaped process (cmdline contains "qemu-system") and write
# its PID to the pid file. mesh-status.sh checks both /proc/$pid existence
# AND cmdline match, so a process whose cmdline doesn't look like QEMU would
# correctly be reported as stopped. Using `$$` (this script's own bash PID)
# would not satisfy the cmdline check, hence the fake process.
(
    exec -a "qemu-system-x86_64-fake-test" sleep 30
) &
FAKE_QEMU_PID=$!
# Give the kernel a moment to publish /proc/$FAKE_QEMU_PID
sleep 0.3
if ! [ -d "/proc/${FAKE_QEMU_PID}" ]; then
    kill "${FAKE_QEMU_PID}" 2>/dev/null || true
    wait 2>/dev/null || true
    skip "test_mesh_status_reports_live_pid_as_running" "could not spawn fake QEMU process"
else
    echo "${FAKE_QEMU_PID}" > "${PID_FILE}"
    STATUS_OUT=""
    STATUS_EXIT=0
    STATUS_OUT="$("${LAB_CLI}" status 2>/dev/null)" || STATUS_EXIT=$?
    if [ "${STATUS_EXIT}" -eq 0 ] && echo "${STATUS_OUT}" | ${PYTHON} -c '
import json, sys
data = json.load(sys.stdin)
vms = data.get("vms", [])
node1 = next((vm for vm in vms if vm.get("id") == 1), None)
assert node1 is not None, "node-1 missing from vms"
assert node1.get("running") is True, "expected node-1.running=True, got %r" % node1.get("running")
' 2>/dev/null; then
        pass "test_mesh_status_reports_live_pid_as_running"
    else
        fail "test_mesh_status_reports_live_pid_as_running" "exit=${STATUS_EXIT}; output=${STATUS_OUT}"
    fi
    kill "${FAKE_QEMU_PID}" 2>/dev/null || true
    wait 2>/dev/null || true
fi

# ─── Stale PID is reported as stopped ─────────────────────────────────────────
if [ "${STALE_PID_UNAVAILABLE}" = "true" ]; then
    skip "test_mesh_status_reports_stale_pid_as_stopped" "no available stale PID on this host"
else
    echo "${STALE_PID}" > "${PID_FILE}"
    STATUS_OUT=""
    STATUS_EXIT=0
    STATUS_OUT="$("${LAB_CLI}" status 2>/dev/null)" || STATUS_EXIT=$?
    if [ "${STATUS_EXIT}" -eq 0 ] && echo "${STATUS_OUT}" | ${PYTHON} -c '
import json, sys
data = json.load(sys.stdin)
vms = data.get("vms", [])
node1 = next((vm for vm in vms if vm.get("id") == 1), None)
assert node1 is not None, "node-1 missing from vms"
assert node1.get("running") is False, "expected node-1.running=False, got %r" % node1.get("running")
' 2>/dev/null; then
        pass "test_mesh_status_reports_stale_pid_as_stopped"
    else
        fail "test_mesh_status_reports_stale_pid_as_stopped" "exit=${STATUS_EXIT}; output=${STATUS_OUT}"
    fi
fi

# ─── Non-numeric pid file is handled gracefully ──────────────────────────────
# The script guards on `[[ "$pid" =~ ^[0-9]+$ ]]`; a non-numeric value
# must not crash mesh-status.sh and must report the VM as stopped.
echo "not-a-pid" > "${PID_FILE}"
STATUS_OUT=""
STATUS_EXIT=0
STATUS_OUT="$("${LAB_CLI}" status 2>/dev/null)" || STATUS_EXIT=$?
if [ "${STATUS_EXIT}" -eq 0 ] && echo "${STATUS_OUT}" | ${PYTHON} -c '
import json, sys
data = json.load(sys.stdin)
vms = data.get("vms", [])
node1 = next((vm for vm in vms if vm.get("id") == 1), None)
assert node1 is not None, "node-1 missing from vms"
assert node1.get("running") is False, "expected node-1.running=False, got %r" % node1.get("running")
' 2>/dev/null; then
    pass "test_mesh_status_pid_check_survives_unreadable_pid_file"
else
    fail "test_mesh_status_pid_check_survives_unreadable_pid_file" "exit=${STATUS_EXIT}; output=${STATUS_OUT}"
fi

# ─── vwifi-server pid file: same checks, different field ─────────────────────
# mesh-status.sh applies the same PID+cmdline aliveness check to
# vwifi-server.pid (via `grep -q "vwifi-server"`), but reports it under
# `vwifi_server.running` instead of `vms[].running`. A stale or non-numeric
# vwifi pid file must not crash status and must report vwifi_server.running=false.
(
    exec -a "vwifi-server-fake-test" sleep 30
) &
FAKE_VWIFI_PID=$!
sleep 0.3
if ! [ -d "/proc/${FAKE_VWIFI_PID}" ]; then
    kill "${FAKE_VWIFI_PID}" 2>/dev/null || true
    wait 2>/dev/null || true
    skip "test_mesh_status_vwifi_pid_reports_live" "could not spawn fake vwifi-server process"
else
    echo "${FAKE_VWIFI_PID}" > "${VWIFI_PID_FILE}"
    STATUS_OUT=""
    STATUS_OUT="$("${LAB_CLI}" status 2>/dev/null)" || true
    if echo "${STATUS_OUT}" | ${PYTHON} -c '
import json, sys
data = json.load(sys.stdin)
vwifi = data.get("vwifi_server", {})
assert vwifi.get("running") is True, "expected vwifi_server.running=True, got %r" % vwifi.get("running")
assert vwifi.get("pid") != 0, "expected vwifi_server.pid != 0, got %r" % vwifi.get("pid")
' 2>/dev/null; then
        pass "test_mesh_status_vwifi_pid_reports_live"
    else
        fail "test_mesh_status_vwifi_pid_reports_live" "output=${STATUS_OUT}"
    fi
    kill "${FAKE_VWIFI_PID}" 2>/dev/null || true
    wait 2>/dev/null || true
fi

# Stale vwifi pid: write pid_max-1, expect running=False and pid=0
# (mesh-status.sh resets pid=0 when the aliveness check fails).
if [ "${STALE_PID_UNAVAILABLE}" != "true" ]; then
    echo "${STALE_PID}" > "${VWIFI_PID_FILE}"
    STATUS_OUT=""
    STATUS_OUT="$("${LAB_CLI}" status 2>/dev/null)" || true
    if echo "${STATUS_OUT}" | ${PYTHON} -c '
import json, sys
data = json.load(sys.stdin)
vwifi = data.get("vwifi_server", {})
assert vwifi.get("running") is False, "expected vwifi_server.running=False, got %r" % vwifi.get("running")
assert vwifi.get("pid") == 0, "expected vwifi_server.pid=0, got %r" % vwifi.get("pid")
' 2>/dev/null; then
        pass "test_mesh_status_vwifi_pid_reports_stale"
    else
        fail "test_mesh_status_vwifi_pid_reports_stale" "output=${STATUS_OUT}"
    fi
else
    # If pid_max-1 happens to be a live PID, we cannot fabricate a stale
    # vwifi scenario without the mesh-status check treating it as live
    # (which would test the wrong thing). Skip with explanation so TAP
    # plan/result counts stay consistent.
    skip "test_mesh_status_vwifi_pid_reports_stale" \
        "no safe stale pid available (pid_max-1 is live in this container)"
fi

tap_summary
