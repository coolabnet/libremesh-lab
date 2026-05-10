#!/usr/bin/env bash
# No-VM regression tests for run-adapter workspace isolation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Run Adapter Wrapper Tests"
tap_plan 1

if ! command -v git >/dev/null 2>&1; then
    skip "test_run_adapter_uses_temp_workspace" "git not available"
    tap_summary
    exit 0
fi

FIXTURE_ROOT="$(mktemp -d /tmp/libremesh-lab-adapter-fixture.XXXXXX)"
cleanup_fixture() {
    rm -rf "${FIXTURE_ROOT}"
}
trap cleanup_fixture EXIT INT TERM

mkdir -p "${FIXTURE_ROOT}/adapters/probe" "${FIXTURE_ROOT}/skills" "${FIXTURE_ROOT}/scripts"
touch "${FIXTURE_ROOT}/pyproject.toml" "${FIXTURE_ROOT}/LICENSE"
git -C "${FIXTURE_ROOT}" init -q

PROBE_SCRIPT="${FIXTURE_ROOT}/adapters/probe/write-probe.sh"
cat > "${PROBE_SCRIPT}" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail

[ "${PWD}" = "${REPO_ROOT}" ] || { echo "PWD was not REPO_ROOT" >&2; exit 10; }
[ "${WORKSPACE_ROOT}" = "${REPO_ROOT}" ] || { echo "WORKSPACE_ROOT mismatch" >&2; exit 11; }
[ "${HOME}" = "${REPO_ROOT}/home" ] || { echo "HOME was not isolated" >&2; exit 12; }
[ -n "${LIBREMESH_LAB_ROOT:-}" ] && [ -d "${LIBREMESH_LAB_ROOT}" ] || exit 13
[ -n "${LIBREMESH_LAB_CONFIG:-}" ] && [ -d "${LIBREMESH_LAB_CONFIG}" ] || exit 14
[ -n "${LIBREMESH_LAB_INVENTORIES:-}" ] && [ -e "${LIBREMESH_LAB_INVENTORIES}" ] || exit 15
[ -n "${LIBREMESH_LAB_DESIRED_STATE:-}" ] && [ -e "${LIBREMESH_LAB_DESIRED_STATE}" ] || exit 16
[ -n "${SOURCE_WORKSPACE_ROOT:-}" ] && [ -d "${SOURCE_WORKSPACE_ROOT}/.git" ] || exit 17
[ ! -e "${REPO_ROOT}/.git" ] || { echo ".git leaked into temp workspace" >&2; exit 18; }
[ -L "${REPO_ROOT}/adapters" ] || { echo "adapters was not mapped" >&2; exit 19; }
[ -L "${REPO_ROOT}/skills" ] || { echo "skills was not mapped" >&2; exit 20; }
[ -L "${REPO_ROOT}/scripts" ] || { echo "scripts was not mapped" >&2; exit 21; }
[ -L "${REPO_ROOT}/pyproject.toml" ] || { echo "pyproject.toml was not mapped" >&2; exit 22; }
[ -L "${REPO_ROOT}/LICENSE" ] || { echo "LICENSE was not mapped" >&2; exit 23; }

mkdir -p "${REPO_ROOT}/exports"
printf 'probe\n' > "${REPO_ROOT}/exports/probe.txt"
[ -f "${REPO_ROOT}/exports/probe.txt" ] || exit 24
PROBE
chmod +x "${PROBE_SCRIPT}"

OUTPUT=""
ADAPTER_EXIT=0
OUTPUT="$("${LAB_CLI}" run-adapter "${PROBE_SCRIPT}" 2>&1)" || ADAPTER_EXIT=$?

if [ "${ADAPTER_EXIT}" -eq 0 ] && [ ! -e "${FIXTURE_ROOT}/exports/probe.txt" ]; then
    pass "test_run_adapter_uses_temp_workspace"
else
    fail "test_run_adapter_uses_temp_workspace" "exit=${ADAPTER_EXIT}; output=${OUTPUT}; source export exists=$([ -e "${FIXTURE_ROOT}/exports/probe.txt" ] && echo yes || echo no)"
fi

tap_summary
