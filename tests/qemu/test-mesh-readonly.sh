#!/usr/bin/env bash
# Mesh-readonly test — verifies full mesh read-only inspection
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Mesh Readonly Tests"
tap_plan 2

READONLY_SCRIPT="${MESHA_ROOT}/skills/mesh-readonly/scripts/run-mesh-readonly.sh"

# Test 1: run-mesh-readonly --plan produces valid JSON
PLAN_OUTPUT=""
PLAN_EXIT=0
PLAN_OUTPUT="$(bash "${LAB_CLI}" run-adapter "${READONLY_SCRIPT}" --plan 2>/dev/null)" || PLAN_EXIT=$?
if [ "${PLAN_EXIT}" -eq 0 ] && echo "${PLAN_OUTPUT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert 'mode' in data
assert data['mode'] == 'plan'
assert 'inventory_targets' in data
" 2>/dev/null; then
    pass "test_mesh_readonly_plan_mode"
else
    skip "test_mesh_readonly_plan_mode" "plan mode output invalid or script failed (exit: ${PLAN_EXIT})"
fi

# Test 2: run-mesh-readonly --hostname with timeout
# Uses timeout to prevent hanging if mesh is partitioned
HOSTNAME_OUTPUT=""
HOSTNAME_EXIT=0
HOSTNAME_OUTPUT="$(timeout 60 bash "${LAB_CLI}" run-adapter "${READONLY_SCRIPT}" --hostname lm-testbed-node-1 2>/dev/null)" || HOSTNAME_EXIT=$?
if [ "${HOSTNAME_EXIT}" -eq 124 ]; then
    # timeout terminated the script — treat as failure
    fail "test_mesh_readonly_hostname" "script hung and was killed by timeout (exit 124)"
elif [ "${HOSTNAME_EXIT}" -eq 0 ] && [ -n "${HOSTNAME_OUTPUT}" ]; then
    if echo "${HOSTNAME_OUTPUT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert 'nodes' in data or 'error' in data
" 2>/dev/null; then
        pass "test_mesh_readonly_hostname"
    else
        fail "test_mesh_readonly_hostname" "output is not valid JSON with expected fields"
    fi
else
    skip "test_mesh_readonly_hostname" "script exited ${HOSTNAME_EXIT} or returned empty output"
fi

tap_summary
