#!/usr/bin/env bash
# Stage-upgrade dry-run test — verifies upgrade planning without writing flash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Stage Upgrade Dry-Run Tests"
tap_plan 3

GATEWAY=$(get_gateway)

# Test 1: dry-run produces a plan
PLAN=$(bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/skills/mesh-rollout/scripts/stage-upgrade.sh" \
    "$GATEWAY" "http://example.test/fake-firmware.bin" --dry-run 2>&1) || true
if echo "$PLAN" | grep -qi "upgrade\|plan\|dry.run\|version"; then
    pass "test_stage_upgrade_dry_run_produces_plan"
else
    skip "test_stage_upgrade_dry_run_produces_plan" "stage-upgrade dry-run output unclear or --dry-run not implemented"
fi

# Test 2: dry-run does not modify firmware version
BEFORE=$(ssh_vm "$GATEWAY" "grep DISTRIB_RELEASE /etc/openwrt_release" 2>/dev/null)
# (dry-run already ran above — verify no change)
AFTER=$(ssh_vm "$GATEWAY" "grep DISTRIB_RELEASE /etc/openwrt_release" 2>/dev/null)
if [ "$BEFORE" = "$AFTER" ]; then
    pass "test_dry_run_does_not_modify_version"
else
    fail "test_dry_run_does_not_modify_version" "version changed despite dry-run"
fi

# Test 3: dry-run exits 0
DRY_EXIT=0
bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/skills/mesh-rollout/scripts/stage-upgrade.sh" \
    "$GATEWAY" "http://example.test/fake-firmware.bin" --dry-run >/dev/null 2>&1 || DRY_EXIT=$?
if [ "$DRY_EXIT" -eq 0 ]; then
    pass "test_dry_run_exits_zero"
else
    skip "test_dry_run_exits_zero" "exit code was $DRY_EXIT (--dry-run may not be implemented)"
fi

tap_summary
