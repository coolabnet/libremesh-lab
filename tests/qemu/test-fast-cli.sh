#!/usr/bin/env bash
# Fast standalone CLI tests. These must not require VMs or a Mesha checkout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Fast CLI Tests"
tap_plan 5

STATUS_OUTPUT=""
STATUS_EXIT=0
STATUS_OUTPUT="$("${LAB_CLI}" status 2>/dev/null)" || STATUS_EXIT=$?
if [ "${STATUS_EXIT}" -eq 0 ] && [ -n "${STATUS_OUTPUT}" ]; then
    pass "test_status_exits_zero"
else
    fail "test_status_exits_zero" "status exited ${STATUS_EXIT}"
fi

STATUS_JSON_OK=false
if echo "${STATUS_OUTPUT}" | python3 -m json.tool >/dev/null 2>&1; then
    STATUS_JSON_OK=true
    pass "test_status_outputs_json"
else
    fail "test_status_outputs_json" "status output did not parse as JSON"
fi

ACTIVE_LAB=false
if "${STATUS_JSON_OK}" && echo "${STATUS_OUTPUT}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
active = data.get("bridge", {}).get("exists") or data.get("vwifi_server", {}).get("running")
active = active or any(vm.get("running") for vm in data.get("vms", []))
sys.exit(0 if active else 1)
' 2>/dev/null; then
    ACTIVE_LAB=true
fi

if ! "${STATUS_JSON_OK}"; then
    skip "test_status_reports_all_vms_stopped_when_clean" "status JSON did not parse"
elif "${ACTIVE_LAB}"; then
    skip "test_status_reports_all_vms_stopped_when_clean" "lab appears to be running"
else
    if echo "${STATUS_OUTPUT}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data.get("vm_count", 0) == len(data.get("vms", []))
assert all(vm.get("running") is False for vm in data.get("vms", []))
' 2>/dev/null; then
        pass "test_status_reports_all_vms_stopped_when_clean"
    else
        fail "test_status_reports_all_vms_stopped_when_clean" "one or more VMs reported running in clean state"
    fi
fi

if ! "${STATUS_JSON_OK}"; then
    skip "test_stop_clean_path_exits_zero" "status JSON did not parse"
elif "${ACTIVE_LAB}"; then
    skip "test_stop_clean_path_exits_zero" "lab appears to be running"
else
    STOP_EXIT=0
    "${LAB_CLI}" stop >/dev/null 2>&1 || STOP_EXIT=$?
    if [ "${STOP_EXIT}" -eq 0 ]; then
        pass "test_stop_clean_path_exits_zero"
    else
        fail "test_stop_clean_path_exits_zero" "stop exited ${STOP_EXIT}"
    fi
fi

SUITE_ERROR_OUTPUT=""
SUITE_ERROR_EXIT=0
SUITE_ERROR_OUTPUT="$("${LAB_CLI}" test --suite 2>&1)" || SUITE_ERROR_EXIT=$?
if [ "${SUITE_ERROR_EXIT}" -ne 0 ] && echo "${SUITE_ERROR_OUTPUT}" | grep -q -- "--suite requires"; then
    pass "test_missing_suite_argument_reports_error"
else
    fail "test_missing_suite_argument_reports_error" "exit=${SUITE_ERROR_EXIT}; output=${SUITE_ERROR_OUTPUT}"
fi

tap_summary
