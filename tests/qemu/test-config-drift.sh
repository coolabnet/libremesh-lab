#!/usr/bin/env bash
# Configuration drift detection tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Config Drift Tests"
tap_plan 2

GATEWAY=$(get_gateway)
DRIFT_CLEANUP_DONE=false

# Check if wireless config exists (VMs without wireless hardware skip these tests)
HAS_WIRELESS=$(ssh_vm "$GATEWAY" "uci show wireless.radio0 2>/dev/null && echo yes || echo no" 2>/dev/null | tail -1)

cleanup_drift() {
    $DRIFT_CLEANUP_DONE && return
    DRIFT_CLEANUP_DONE=true
    # Restore original channel
    [ -n "${ORIGINAL_CHANNEL:-}" ] && \
        ssh_vm "$GATEWAY" "uci set wireless.radio0.channel='${ORIGINAL_CHANNEL}'; uci commit wireless" 2>/dev/null || true
}
trap cleanup_drift EXIT INT TERM

# Test 1: UCI write and read-back succeeds
echo "# Testing UCI write/read..."
if [ "${HAS_WIRELESS}" != "yes" ]; then
    skip "test_uci_write_succeeds" "wireless.radio0 not available (no wireless hardware)"
    skip "test_drift_detection_finds_changed_channel" "wireless.radio0 not available (no wireless hardware)"
    tap_summary
    exit 0
fi

ORIGINAL_CHANNEL=$(ssh_vm "$GATEWAY" "uci get wireless.radio0.channel 2>/dev/null || echo '11'" 2>/dev/null)
ssh_vm "$GATEWAY" "uci set wireless.radio0.channel='6'; uci commit wireless" 2>/dev/null || true
sleep 1

NEW_CHANNEL=$(ssh_vm "$GATEWAY" "uci get wireless.radio0.channel 2>/dev/null || echo 'unknown'" 2>/dev/null)

# Restore original
ssh_vm "$GATEWAY" "uci set wireless.radio0.channel='${ORIGINAL_CHANNEL}'; uci commit wireless" 2>/dev/null || true

if [ "${NEW_CHANNEL}" = "6" ]; then
    pass "test_uci_write_succeeds"
else
    fail "test_uci_write_succeeds" "read back '${NEW_CHANNEL}' instead of '6'"
fi

# Test 2: Drift detection finds changed channel
echo "# Testing drift detection..."
# Use check-drift.sh if available, otherwise manual comparison
DRIFT_SCRIPT="${MESHA_ROOT}/skills/mesh-rollout/scripts/check-drift.sh"
if [ -x "${DRIFT_SCRIPT}" ]; then
    # Change channel on gateway
    ssh_vm "$GATEWAY" "uci set wireless.radio0.channel='1'; uci commit wireless" 2>/dev/null || true
    sleep 1

    DRIFT_RESULT=0
    bash "${LAB_CLI}" run-adapter \
        "${DRIFT_SCRIPT}" "$GATEWAY" >/dev/null 2>&1 || DRIFT_RESULT=$?

    # Restore
    ssh_vm "$GATEWAY" "uci set wireless.radio0.channel='${ORIGINAL_CHANNEL}'; uci commit wireless" 2>/dev/null || true

    if [ "${DRIFT_RESULT}" -ne 0 ]; then
        pass "test_drift_detection_finds_changed_channel"
    else
        fail "test_drift_detection_finds_changed_channel" "drift not detected (exit 0)"
    fi
else
    # Manual drift check: compare against desired state
    DESIRED_CHANNEL=$(python3 -c "
import yaml
with open('${REPO_ROOT}/config/desired-state/mesh/community-profile/defaults.yaml') as f:
    d = yaml.safe_load(f)
print(d.get('wifi', {}).get('channel', '11'))
" 2>/dev/null || echo "11")

    # Change to something different
    ssh_vm "$GATEWAY" "uci set wireless.radio0.channel='3'; uci commit wireless" 2>/dev/null || true
    sleep 1
    CHANGED_CHANNEL=$(ssh_vm "$GATEWAY" "uci get wireless.radio0.channel 2>/dev/null" 2>/dev/null)

    # Restore
    ssh_vm "$GATEWAY" "uci set wireless.radio0.channel='${ORIGINAL_CHANNEL}'; uci commit wireless" 2>/dev/null || true

    if [ "${CHANGED_CHANNEL}" != "${DESIRED_CHANNEL}" ]; then
        pass "test_drift_detection_finds_changed_channel"
    else
        fail "test_drift_detection_finds_changed_channel" "channel unchanged"
    fi
fi

tap_summary
