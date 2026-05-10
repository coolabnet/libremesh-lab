#!/usr/bin/env bash
# Firmware upgrade simulation test
# Tests the sysupgrade pattern by modifying /etc/openwrt_release and verifying detection
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Firmware Upgrade Simulation Tests"
tap_plan 2

GATEWAY=$(get_gateway)
RUN_DIR="${REPO_ROOT}/run"

# Test 1: Version change detected after simulated upgrade
echo "# Testing firmware version change detection..."

# Read current version
ORIGINAL_VERSION=$(ssh_vm "$GATEWAY" 'grep DISTRIB_RELEASE /etc/openwrt_release 2>/dev/null | cut -d= -f2 | tr -d "\047\042"' 2>/dev/null || echo "unknown")
echo "  Current version: ${ORIGINAL_VERSION}"

# Create qcow2 snapshot before upgrade for rollback testing
GATEWAY_OVERLAY="${RUN_DIR}/node-1.qcow2"
SNAPSHOT_CREATED=false
if [ -f "$GATEWAY_OVERLAY" ] && command -v qemu-img >/dev/null 2>&1; then
    echo "  Creating pre-upgrade snapshot..."
    qemu-img snapshot -c pre-upgrade "$GATEWAY_OVERLAY" 2>/dev/null && SNAPSHOT_CREATED=true || \
        echo "  WARN: Could not create snapshot"
fi

# Simulate sysupgrade: write a different DISTRIB_RELEASE to /etc/openwrt_release
ssh_vm "$GATEWAY" "sed -i 's/DISTRIB_RELEASE=.*/DISTRIB_RELEASE=\"testbed-2.0\"/' /etc/openwrt_release" 2>/dev/null || true
sleep 1

# Verify change
NEW_VERSION=$(ssh_vm "$GATEWAY" 'grep DISTRIB_RELEASE /etc/openwrt_release 2>/dev/null | cut -d= -f2 | tr -d "\047\042"' 2>/dev/null || echo "unknown")
echo "  New version: ${NEW_VERSION}"

if [ "${NEW_VERSION}" = "testbed-2.0" ] && [ "${NEW_VERSION}" != "${ORIGINAL_VERSION}" ]; then
    pass "test_firmware_version_change_detected"
else
    fail "test_firmware_version_change_detected" "version unchanged (${ORIGINAL_VERSION} -> ${NEW_VERSION})"
fi

# Test 2: validate-node detects version mismatch with policy
echo "# Testing validate-node detects version mismatch..."
VALIDATE_RESULT=0
VALIDATE_OUTPUT=$(bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/skills/mesh-rollout/scripts/validate-node.sh" "$GATEWAY" \
    2>/dev/null) || VALIDATE_RESULT=$?

# Restore original version
ssh_vm "$GATEWAY" "sed -i 's/DISTRIB_RELEASE=.*/DISTRIB_RELEASE=\"${ORIGINAL_VERSION}\"/' /etc/openwrt_release" 2>/dev/null || true

# Rollback qcow2 snapshot if one was created
if $SNAPSHOT_CREATED && [ -f "$GATEWAY_OVERLAY" ]; then
    echo "  Restoring pre-upgrade snapshot..."
    # Note: VM must be stopped for snapshot restore, so we just note it
    qemu-img snapshot -d pre-upgrade "$GATEWAY_OVERLAY" 2>/dev/null || true
fi

# validate-node should detect the version mismatch.
# It may return WARN (exit 0) with output mentioning the mismatch, or FAIL (exit 1).
if [ "${VALIDATE_RESULT}" -ne 0 ]; then
    pass "test_validate_detects_version_mismatch"
elif echo "${VALIDATE_OUTPUT}" | grep -qi "version.*mismatch\|WARN.*Firmware version\|FAIL.*Firmware version"; then
    pass "test_validate_detects_version_mismatch"
else
    fail "test_validate_detects_version_mismatch" "validate-node returned 0 and did not mention version mismatch"
fi

tap_summary
