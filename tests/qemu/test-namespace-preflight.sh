#!/usr/bin/env bash
# No-root regression tests for namespace/wmediumd preflight behavior.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

PREFLIGHT="${LAB_ROOT}/scripts/qemu/preflight-namespace.sh"
RUN_ALL="${LAB_ROOT}/tests/qemu/run-all.sh"
BASH_BIN="$(command -v bash)"

echo "# Namespace Preflight Tests"
tap_plan 6

FIXTURE_ROOT="$(mktemp -d /tmp/libremesh-lab-namespace-preflight.XXXXXX)"
cleanup_fixture() {
    rm -rf "${FIXTURE_ROOT}"
}
trap cleanup_fixture EXIT INT TERM

make_cmd() {
    local root="$1"
    local name="$2"
    local body="${3:-exit 0}"
    printf '#!/bin/sh\n%s\n' "${body}" > "${root}/${name}"
    chmod +x "${root}/${name}"
}

make_executable() {
    local path="$1"
    local body="$2"
    printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "${body}" > "${path}"
    chmod +x "${path}"
}

make_fake_host() {
    local root="$1"
    mkdir -p "${root}/bin" "${root}/sys/module/mac80211_hwsim" "${root}/modules"
    # shellcheck disable=SC2016 # The body is written literally into the fake command.
    make_cmd "${root}/bin" ip 'if [ "$1" = "netns" ]; then exit 0; fi; exit 0'
    make_cmd "${root}/bin" iw
    make_cmd "${root}/bin" wmediumd
    make_cmd "${root}/bin" modprobe
    make_cmd "${root}/bin" ping
    make_cmd "${root}/bin" timeout
}

GOOD_HOST="${FIXTURE_ROOT}/good"
make_fake_host "${GOOD_HOST}"
GOOD_OUTPUT=""
GOOD_EXIT=0
GOOD_OUTPUT="$(PATH="${GOOD_HOST}/bin" LIBREMESH_LAB_SYS_MODULE_DIR="${GOOD_HOST}/sys/module" LIBREMESH_LAB_MODULES_DIR="${GOOD_HOST}/modules" "${BASH_BIN}" "${PREFLIGHT}" 2>&1)" || GOOD_EXIT=$?
if [ "${GOOD_EXIT}" -eq 0 ] && echo "${GOOD_OUTPUT}" | grep -q "Namespace/wmediumd preflight: ready"; then
    pass "test_namespace_preflight_passes_with_required_tools"
else
    fail "test_namespace_preflight_passes_with_required_tools" "exit=${GOOD_EXIT}; output=${GOOD_OUTPUT}"
fi

MISSING_HOST="${FIXTURE_ROOT}/missing-wmediumd"
make_fake_host "${MISSING_HOST}"
rm -f "${MISSING_HOST}/bin/wmediumd"
MISSING_OUTPUT=""
MISSING_EXIT=0
MISSING_OUTPUT="$(PATH="${MISSING_HOST}/bin" LIBREMESH_LAB_SYS_MODULE_DIR="${MISSING_HOST}/sys/module" LIBREMESH_LAB_MODULES_DIR="${MISSING_HOST}/modules" "${BASH_BIN}" "${PREFLIGHT}" 2>&1)" || MISSING_EXIT=$?
if [ "${MISSING_EXIT}" -ne 0 ] && echo "${MISSING_OUTPUT}" | grep -q "missing: wmediumd not found"; then
    pass "test_namespace_preflight_reports_missing_wmediumd"
else
    fail "test_namespace_preflight_reports_missing_wmediumd" "exit=${MISSING_EXIT}; output=${MISSING_OUTPUT}"
fi

IP_NETNS_HOST="${FIXTURE_ROOT}/ip-netns"
make_fake_host "${IP_NETNS_HOST}"
IP_NETNS_OUTPUT=""
IP_NETNS_EXIT=0
IP_NETNS_OUTPUT="$(PATH="${IP_NETNS_HOST}/bin" LIBREMESH_LAB_SYS_MODULE_DIR="${IP_NETNS_HOST}/sys/module" LIBREMESH_LAB_MODULES_DIR="${IP_NETNS_HOST}/modules" "${BASH_BIN}" "${PREFLIGHT}" 2>&1)" || IP_NETNS_EXIT=$?
if [ "${IP_NETNS_EXIT}" -eq 0 ] && echo "${IP_NETNS_OUTPUT}" | grep -q "namespace tool: ip netns"; then
    pass "test_namespace_preflight_requires_ip_netns"
else
    fail "test_namespace_preflight_requires_ip_netns" "exit=${IP_NETNS_EXIT}; output=${IP_NETNS_OUTPUT}"
fi

DEFAULT_OUTPUT=""
DEFAULT_EXIT=0
DEFAULT_OUTPUT="$("${BASH_BIN}" "${RUN_ALL}" --suite namespace 2>&1)" || DEFAULT_EXIT=$?
if [ "${DEFAULT_EXIT}" -eq 0 ] && echo "${DEFAULT_OUTPUT}" | grep -q "Namespace/wmediumd preflight" && echo "${DEFAULT_OUTPUT}" | grep -q "Namespace smoke skipped"; then
    pass "test_namespace_suite_default_reports_preflight_and_exits_zero"
else
    fail "test_namespace_suite_default_reports_preflight_and_exits_zero" "exit=${DEFAULT_EXIT}; output=${DEFAULT_OUTPUT}"
fi

ENABLED_OUTPUT=""
ENABLED_EXIT=0
FAKE_PREFLIGHT="${FIXTURE_ROOT}/fake-preflight.sh"
FAKE_NAMESPACE_TEST="${FIXTURE_ROOT}/fake-namespace-test.sh"
make_executable "${FAKE_PREFLIGHT}" 'echo "fake preflight ok"'
make_executable "${FAKE_NAMESPACE_TEST}" 'echo "fake namespace test ok"'
ENABLED_OUTPUT="$(RUN_NAMESPACE_TESTS=1 LIBREMESH_LAB_NAMESPACE_PREFLIGHT="${FAKE_PREFLIGHT}" LIBREMESH_LAB_NAMESPACE_TEST="${FAKE_NAMESPACE_TEST}" "${BASH_BIN}" "${RUN_ALL}" --suite namespace 2>&1)" || ENABLED_EXIT=$?
if [ "${ENABLED_EXIT}" -eq 0 ] && echo "${ENABLED_OUTPUT}" | grep -q "fake namespace test ok"; then
    pass "test_namespace_suite_enabled_runs_namespace_test"
else
    fail "test_namespace_suite_enabled_runs_namespace_test" "exit=${ENABLED_EXIT}; output=${ENABLED_OUTPUT}"
fi

FAILING_PREFLIGHT="${FIXTURE_ROOT}/failing-preflight.sh"
SHOULD_NOT_RUN="${FIXTURE_ROOT}/should-not-run.sh"
make_executable "${FAILING_PREFLIGHT}" 'echo "fake preflight failed"; exit 1'
make_executable "${SHOULD_NOT_RUN}" 'echo "namespace test should not run"; exit 7'
PREFLIGHT_FAIL_OUTPUT=""
PREFLIGHT_FAIL_EXIT=0
PREFLIGHT_FAIL_OUTPUT="$(RUN_NAMESPACE_TESTS=1 LIBREMESH_LAB_NAMESPACE_PREFLIGHT="${FAILING_PREFLIGHT}" LIBREMESH_LAB_NAMESPACE_TEST="${SHOULD_NOT_RUN}" "${BASH_BIN}" "${RUN_ALL}" --suite namespace 2>&1)" || PREFLIGHT_FAIL_EXIT=$?
if [ "${PREFLIGHT_FAIL_EXIT}" -ne 0 ] && echo "${PREFLIGHT_FAIL_OUTPUT}" | grep -q "preflight requirements are missing" && ! echo "${PREFLIGHT_FAIL_OUTPUT}" | grep -q "namespace test should not run"; then
    pass "test_namespace_suite_enabled_stops_on_failed_preflight"
else
    fail "test_namespace_suite_enabled_stops_on_failed_preflight" "exit=${PREFLIGHT_FAIL_EXIT}; output=${PREFLIGHT_FAIL_OUTPUT}"
fi

tap_summary
