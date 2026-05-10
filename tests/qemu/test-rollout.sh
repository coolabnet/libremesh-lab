#!/usr/bin/env bash
# Run-rollout dry-run integration test — verifies ring planning and ordering logic
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Rollout Dry-Run Tests"
tap_plan 3

FIXTURE_DIR="${SCRIPT_DIR}/fixtures"

# Test 1: dry-run produces ring plan with testbed nodes
# Install fixtures into lab config; run-adapter exposes them through a temp workspace.
ORIG_POLICY="${REPO_ROOT}/config/desired-state/mesh/community-profile/rollout-policy.yaml"
ORIG_INV="${REPO_ROOT}/config/inventories/mesh-nodes.yaml"
FIXTURE_POLICY="${FIXTURE_DIR}/rollout-policy-testbed.yaml"
FIXTURE_INV="${FIXTURE_DIR}/mesh-nodes-testbed.yaml"

if [ ! -f "${FIXTURE_POLICY}" ] || [ ! -f "${FIXTURE_INV}" ]; then
    skip "test_dry_run_produces_ring_plan" "fixture files not found"
    skip "test_dry_run_lists_testbed_nodes" "fixture files not found"
    skip "test_dry_run_does_not_modify_state" "fixture files not found"
    tap_summary
    exit 0
fi

# Back up originals
POLICY_BACKUP="$(mktemp /tmp/rollout-policy-real-XXXXXX.yaml)"
INV_BACKUP="$(mktemp /tmp/mesh-nodes-real-XXXXXX.yaml)"
cp "${ORIG_POLICY}" "${POLICY_BACKUP}"
cp "${ORIG_INV}" "${INV_BACKUP}"

# Create a dummy firmware file for dry-run (local path avoids HTTP download)
DUMMY_FIRMWARE="$(mktemp /tmp/dry-run-firmware-XXXXXX.bin)"
dd if=/dev/zero of="${DUMMY_FIRMWARE}" bs=1K count=64 2>/dev/null
cleanup_firmware() {
    cp "${POLICY_BACKUP}" "${ORIG_POLICY}" 2>/dev/null || true
    cp "${INV_BACKUP}" "${ORIG_INV}" 2>/dev/null || true
    rm -f "${POLICY_BACKUP}" "${INV_BACKUP}" "${DUMMY_FIRMWARE}"
}
trap cleanup_firmware EXIT INT TERM

# Install fixtures
cp "${FIXTURE_POLICY}" "${ORIG_POLICY}"
cp "${FIXTURE_INV}" "${ORIG_INV}"

# Run dry-run using local file path (avoids HTTP download which fails on fake URLs)
ROLLOUT_OUTPUT=""
ROLLOUT_EXIT=0
ROLLOUT_OUTPUT="$(bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/skills/mesh-rollout/scripts/run-rollout.sh" \
    --firmware-url "${DUMMY_FIRMWARE}" \
    --dry-run 2>&1)" || ROLLOUT_EXIT=$?

if [ "${ROLLOUT_EXIT}" -eq 0 ]; then
    pass "test_dry_run_produces_ring_plan"
else
    fail "test_dry_run_produces_ring_plan" "run-rollout --dry-run exited with code ${ROLLOUT_EXIT}"
fi

# Test 2: output lists testbed node hostnames
if echo "${ROLLOUT_OUTPUT}" | grep -q "lm-testbed-node-1" && \
   echo "${ROLLOUT_OUTPUT}" | grep -q "lm-testbed-node-2" && \
   echo "${ROLLOUT_OUTPUT}" | grep -q "lm-testbed-node-3"; then
    pass "test_dry_run_lists_testbed_nodes"
else
    fail "test_dry_run_lists_testbed_nodes" "output missing expected testbed hostnames"
fi

# Test 3: dry-run does not modify rollout-state.yaml
STATE_FILE="${REPO_ROOT}/config/desired-state/mesh/rollout-state.yaml"
if [ ! -f "${STATE_FILE}" ] || [ ! -s "${STATE_FILE}" ]; then
    # State file doesn't exist or is empty — dry-run correctly didn't create it
    pass "test_dry_run_does_not_modify_state"
else
    # State file exists — check the actual status line is not in_progress
    # (grep only the non-comment status line, not the schema comments)
    STATE_STATUS=$(grep -v '^#' "${STATE_FILE}" | grep '^status:' | head -1 | awk '{print $2}' 2>/dev/null || echo "")
    if [ "${STATE_STATUS}" != "in_progress" ]; then
        pass "test_dry_run_does_not_modify_state"
    else
        fail "test_dry_run_does_not_modify_state" "rollout-state.yaml status is in_progress after dry-run"
    fi
fi

tap_summary
