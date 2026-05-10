#!/usr/bin/env bash
# Schedule-maintenance tests — verifies maintenance window CRUD operations
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Schedule Maintenance Tests"
tap_plan 3

MAINT_SCRIPT="${MESHA_ROOT}/skills/mesh-rollout/scripts/schedule-maintenance.sh"
WINDOWS_FILE="${REPO_ROOT}/config/desired-state/mesh/maintenance-windows.yaml"

# Back up existing maintenance windows file
BACKUP_FILE=""
if [ -f "${WINDOWS_FILE}" ]; then
    BACKUP_FILE="$(mktemp /tmp/maintenance-windows-backup-XXXXXX.yaml)"
    cp "${WINDOWS_FILE}" "${BACKUP_FILE}"
fi

cleanup_maintenance() {
    if [ -n "${BACKUP_FILE}" ] && [ -f "${BACKUP_FILE}" ]; then
        cp "${BACKUP_FILE}" "${WINDOWS_FILE}"
        rm -f "${BACKUP_FILE}"
    else
        # Remove the file if it didn't exist before
        rm -f "${WINDOWS_FILE}" 2>/dev/null || true
    fi
}
trap cleanup_maintenance EXIT INT TERM

# Test 1: Create a maintenance window
WINDOW_ID="maint-20990101T0200"
bash "${LAB_CLI}" run-adapter "${MAINT_SCRIPT}" add \
    --date "2099-01-01 02:00" \
    --duration 2h \
    --scope all \
    --description "test window for automated test suite" \
    >/dev/null 2>&1
ADD_EXIT=$?
if [ "${ADD_EXIT}" -eq 0 ] && grep -q "${WINDOW_ID}" "${WINDOWS_FILE}" 2>/dev/null; then
    pass "test_maintenance_window_add"
else
    fail "test_maintenance_window_add" "failed to add maintenance window (exit: ${ADD_EXIT})"
fi

# Test 2: List shows the window
LIST_OUTPUT=""
LIST_OUTPUT="$(bash "${LAB_CLI}" run-adapter "${MAINT_SCRIPT}" list 2>/dev/null)" || true
if echo "${LIST_OUTPUT}" | grep -q "2099-01-01"; then
    pass "test_maintenance_window_list"
else
    fail "test_maintenance_window_list" "list output missing scheduled window"
fi

# Test 3: Cancel the window
bash "${LAB_CLI}" run-adapter "${MAINT_SCRIPT}" cancel "${WINDOW_ID}" >/dev/null 2>&1
CANCEL_EXIT=$?
if [ "${CANCEL_EXIT}" -eq 0 ] && grep -A10 "${WINDOW_ID}" "${WINDOWS_FILE}" 2>/dev/null | grep -q "cancelled"; then
    pass "test_maintenance_window_cancel"
else
    fail "test_maintenance_window_cancel" "failed to cancel window (exit: ${CANCEL_EXIT})"
fi

tap_summary
