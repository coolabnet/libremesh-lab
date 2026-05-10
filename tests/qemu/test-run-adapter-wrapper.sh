#!/usr/bin/env bash
# No-VM regression tests for run-adapter workspace isolation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Run Adapter Wrapper Tests"
tap_plan 3

if ! command -v git >/dev/null 2>&1; then
    skip "test_run_adapter_uses_temp_workspace" "git not available"
    skip "test_run_adapter_copies_repo_entries" "git not available"
    skip "test_run_adapter_prevents_source_writeback" "git not available"
    tap_summary
    exit 0
fi

FIXTURE_ROOT="$(mktemp -d /tmp/libremesh-lab-adapter-fixture.XXXXXX)"
cleanup_fixture() {
    rm -rf "${FIXTURE_ROOT}"
}
trap cleanup_fixture EXIT INT TERM

mkdir -p \
    "${FIXTURE_ROOT}/adapters/probe" \
    "${FIXTURE_ROOT}/config/desired-state" \
    "${FIXTURE_ROOT}/config/inventories" \
    "${FIXTURE_ROOT}/exports" \
    "${FIXTURE_ROOT}/scripts" \
    "${FIXTURE_ROOT}/skills" \
    "${FIXTURE_ROOT}/vendor/module/.git"
printf 'fixture marker\n' > "${FIXTURE_ROOT}/.adapter-root-marker"
printf 'adapter config\n' > "${FIXTURE_ROOT}/config/adapter-extra.conf"
printf 'source helper\n' > "${FIXTURE_ROOT}/scripts/source-write-target.txt"
printf 'nested git metadata\n' > "${FIXTURE_ROOT}/vendor/module/.git/config"
printf '[project]\nname = "adapter-fixture"\n' > "${FIXTURE_ROOT}/pyproject.toml"
printf 'fixture license\n' > "${FIXTURE_ROOT}/LICENSE"
git -C "${FIXTURE_ROOT}" init -q

HELPER_SCRIPT="${FIXTURE_ROOT}/scripts/helper.sh"
cat > "${HELPER_SCRIPT}" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
printf 'helper-ok\n'
HELPER
chmod +x "${HELPER_SCRIPT}"

ENV_PROBE_SCRIPT="${FIXTURE_ROOT}/adapters/probe/env-probe.sh"
cat > "${ENV_PROBE_SCRIPT}" <<'PROBE'
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
[ -L "${REPO_ROOT}/inventories" ] || { echo "inventories was not mapped" >&2; exit 19; }
[ -L "${REPO_ROOT}/desired-state" ] || { echo "desired-state was not mapped" >&2; exit 20; }
[ -L "${REPO_ROOT}/config/inventories" ] || { echo "config/inventories was not mapped" >&2; exit 21; }
[ -L "${REPO_ROOT}/config/desired-state" ] || { echo "config/desired-state was not mapped" >&2; exit 22; }
[ -f "${REPO_ROOT}/config/topology.yaml" ] || { echo "config/topology.yaml was not mapped" >&2; exit 23; }
[ "$(bash "${REPO_ROOT}/scripts/helper.sh")" = "helper-ok" ] || { echo "helper did not run from copied scripts" >&2; exit 24; }
PROBE
chmod +x "${ENV_PROBE_SCRIPT}"

COPY_PROBE_SCRIPT="${FIXTURE_ROOT}/adapters/probe/copy-probe.sh"
cat > "${COPY_PROBE_SCRIPT}" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail

[ -d "${REPO_ROOT}/adapters" ] && [ ! -L "${REPO_ROOT}/adapters" ] || { echo "adapters was not copied" >&2; exit 30; }
[ -d "${REPO_ROOT}/skills" ] && [ ! -L "${REPO_ROOT}/skills" ] || { echo "skills was not copied" >&2; exit 31; }
[ -d "${REPO_ROOT}/scripts" ] && [ ! -L "${REPO_ROOT}/scripts" ] || { echo "scripts was not copied" >&2; exit 32; }
[ -f "${REPO_ROOT}/pyproject.toml" ] && [ ! -L "${REPO_ROOT}/pyproject.toml" ] || { echo "pyproject.toml was not copied" >&2; exit 33; }
[ -f "${REPO_ROOT}/LICENSE" ] && [ ! -L "${REPO_ROOT}/LICENSE" ] || { echo "LICENSE was not copied" >&2; exit 34; }
[ -f "${REPO_ROOT}/.adapter-root-marker" ] || { echo "repo dotfile was not copied" >&2; exit 35; }
[ -f "${REPO_ROOT}/config/adapter-extra.conf" ] || { echo "adapter config file was not preserved" >&2; exit 36; }
[ ! -e "${REPO_ROOT}/.git" ] || { echo ".git leaked into temp workspace" >&2; exit 37; }
[ ! -e "${REPO_ROOT}/vendor/module/.git" ] || { echo "nested .git leaked into temp workspace" >&2; exit 38; }
PROBE
chmod +x "${COPY_PROBE_SCRIPT}"

WRITE_PROBE_SCRIPT="${FIXTURE_ROOT}/adapters/probe/write-probe.sh"
cat > "${WRITE_PROBE_SCRIPT}" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail

printf 'changed in temp\n' > "${REPO_ROOT}/scripts/source-write-target.txt"
printf 'generated in temp\n' > "${REPO_ROOT}/adapters/probe/generated.txt"
printf 'changed config in temp\n' > "${REPO_ROOT}/config/adapter-extra.conf"
printf 'changed pyproject in temp\n' > "${REPO_ROOT}/pyproject.toml"
printf 'probe\n' > "${REPO_ROOT}/exports/probe.txt"
PROBE
chmod +x "${WRITE_PROBE_SCRIPT}"

OUTPUT=""
ADAPTER_EXIT=0
OUTPUT="$("${LAB_CLI}" run-adapter "${ENV_PROBE_SCRIPT}" 2>&1)" || ADAPTER_EXIT=$?

if [ "${ADAPTER_EXIT}" -eq 0 ]; then
    pass "test_run_adapter_uses_temp_workspace"
else
    fail "test_run_adapter_uses_temp_workspace" "exit=${ADAPTER_EXIT}; output=${OUTPUT}"
fi

OUTPUT=""
ADAPTER_EXIT=0
OUTPUT="$("${LAB_CLI}" run-adapter "${COPY_PROBE_SCRIPT}" 2>&1)" || ADAPTER_EXIT=$?

if [ "${ADAPTER_EXIT}" -eq 0 ]; then
    pass "test_run_adapter_copies_repo_entries"
else
    fail "test_run_adapter_copies_repo_entries" "exit=${ADAPTER_EXIT}; output=${OUTPUT}"
fi

OUTPUT=""
ADAPTER_EXIT=0
OUTPUT="$("${LAB_CLI}" run-adapter "${WRITE_PROBE_SCRIPT}" 2>&1)" || ADAPTER_EXIT=$?

SOURCE_WRITEBACK="no"
if [ "$(cat "${FIXTURE_ROOT}/scripts/source-write-target.txt")" != "source helper" ]; then
    SOURCE_WRITEBACK="yes"
fi
if [ -e "${FIXTURE_ROOT}/adapters/probe/generated.txt" ]; then
    SOURCE_WRITEBACK="yes"
fi
if [ "$(cat "${FIXTURE_ROOT}/config/adapter-extra.conf")" != "adapter config" ]; then
    SOURCE_WRITEBACK="yes"
fi
if ! grep -q 'adapter-fixture' "${FIXTURE_ROOT}/pyproject.toml"; then
    SOURCE_WRITEBACK="yes"
fi
if [ -e "${FIXTURE_ROOT}/exports/probe.txt" ]; then
    SOURCE_WRITEBACK="yes"
fi

if [ "${ADAPTER_EXIT}" -eq 0 ] && [ "${SOURCE_WRITEBACK}" = "no" ]; then
    pass "test_run_adapter_prevents_source_writeback"
else
    fail "test_run_adapter_prevents_source_writeback" "exit=${ADAPTER_EXIT}; output=${OUTPUT}; source_writeback=${SOURCE_WRITEBACK}"
fi

tap_summary
