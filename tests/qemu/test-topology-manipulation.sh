#!/usr/bin/env bash
# Topology manipulation tests — vwifi-ctrl distance-based loss and node removal
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Topology Manipulation Tests"
tap_plan 2

GATEWAY=$(get_gateway)
VWIFI_CTRL="${REPO_ROOT}/bin/vwifi-ctrl"

# Ensure BMX7 is stable on all nodes
echo "# Waiting for BMX7 convergence..."
BMX7_RESULT=0
wait_for_bmx7 "$GATEWAY" 2 90 || BMX7_RESULT=$?

if [ "${BMX7_RESULT}" -eq 2 ]; then
    echo "# BMX7 not installed — skipping topology manipulation tests"
    tap_plan 2
    skip "test_vwifi_ctrl_distance_based_loss" "BMX7 not installed on prebuilt image"
    skip "test_node_removal_detected" "BMX7 not installed on prebuilt image"
    tap_summary
    exit 0
elif [ "${BMX7_RESULT}" -ne 0 ]; then
    echo "Bail out! BMX7 not converged"
    exit 1
fi

# Ensure bmx7 is running on all mesh nodes (may have been stopped by prior tests)
for _node in lm-testbed-node-2 lm-testbed-node-3; do
    if ! ssh_vm "$_node" "bmx7 -c originators 2>/dev/null" >/dev/null 2>&1; then
        restart_bmx7 "$_node"
    fi
done
sleep 5

# Test 1: vwifi-ctrl distance-based loss degrades link quality
# vwifi-ctrl only supports global on/off loss, not per-link percentage
# Use distance-based approach: set coordinates far apart + enable loss + small scale
#
# NOTE: When BMX7 uses both wlan0 and br-lan (dual-interface mode), vwifi's
# distance-based loss only affects wlan0. BMX7 will prefer br-lan (wired) for
# routing since it has better metrics. This test is only meaningful when BMX7
# runs on wlan0 exclusively, which requires vwifi to forward data frames.
# Since vwifi IBSS forwards beacons but not data frames, this test is
# effectively untestable in the current dual-interface setup.
echo "# Testing vwifi-ctrl distance-based loss..."
# Check if BMX7 is running on a wireless interface (vwifi-ctrl only affects wireless)
BMX7_IFACE=$(bmx7_mesh_dev "$GATEWAY")
if echo "$BMX7_IFACE" | grep -qi "wlan\|wifi\|adhoc\|mesh0"; then
    # Wireless mesh — vwifi-ctrl distance simulation is applicable
    if [ -x "${VWIFI_CTRL}" ]; then
        mapfile -t VWIFI_CIDS < <("${VWIFI_CTRL}" ls 2>/dev/null | awk '/^[0-9]+[[:space:]]/ {print $1}')
        if [ "${#VWIFI_CIDS[@]}" -lt 2 ]; then
            fail "test_vwifi_ctrl_distance_based_loss" "vwifi-ctrl sees ${#VWIFI_CIDS[@]} connected clients"
        else
            # Check if BMX7 links are over wlan0 (data frames forwarded) or br-lan (dual-interface)
            BMX7_LINK_DEV=$(ssh_vm "$GATEWAY" \
                "bmx7 -c links 2>/dev/null | awk 'NR>1{print \$6}' | sort -u | head -1" 2>/dev/null || echo "")
            if [ "${BMX7_LINK_DEV}" = "br-lan" ]; then
                # Dual-interface mode: BMX7 uses br-lan for data, vwifi loss won't affect it
                skip "test_vwifi_ctrl_distance_based_loss" "BMX7 uses br-lan (dual-interface mode); vwifi distance simulation has no effect on wired links"
            else
                # Record baseline link quality
                BASELINE_QUALITY=$(ssh_vm "$GATEWAY" \
                    "bmx7 -c links 2>/dev/null | awk 'BEGIN{c=0} {for(i=1;i<=NF;i++) if(tolower(\$i)==\"tq\") c=i; if(c && \$c ~ /^-?[0-9.]+$/) print int(\$c)}' | sort -n | head -1" 2>/dev/null || echo "0")
                BASELINE_QUALITY="${BASELINE_QUALITY:-0}"

                # Spread connected clients apart so distance-based loss affects links
                _pos=0
                for _cid in "${VWIFI_CIDS[@]}"; do
                    "${VWIFI_CTRL}" set "$_cid" "$((_pos * 10000))" "$((_pos * 10000))" 0 2>/dev/null || true
                    _pos=$((_pos + 1))
                done
                "${VWIFI_CTRL}" loss yes 2>/dev/null || true
                "${VWIFI_CTRL}" scale 0.001 2>/dev/null || true

                echo "  # Waiting for link quality degradation..."
                sleep 45

                DEGRADED_QUALITY=$(ssh_vm "$GATEWAY" \
                    "bmx7 -c links 2>/dev/null | awk 'BEGIN{c=0} {for(i=1;i<=NF;i++) if(tolower(\$i)==\"tq\") c=i; if(c && \$c ~ /^-?[0-9.]+$/) print int(\$c)}' | sort -n | head -1" 2>/dev/null || echo "0")
                DEGRADED_QUALITY="${DEGRADED_QUALITY:-0}"

                # Reset: set coordinates close + disable loss.
                for _cid in "${VWIFI_CIDS[@]}"; do
                    "${VWIFI_CTRL}" set "$_cid" 0 0 0 2>/dev/null || true
                done
                "${VWIFI_CTRL}" loss no 2>/dev/null || true

                if [ "${DEGRADED_QUALITY}" -lt "${BASELINE_QUALITY}" ] 2>/dev/null; then
                    pass "test_vwifi_ctrl_distance_based_loss"
                else
                    fail "test_vwifi_ctrl_distance_based_loss" "quality did not degrade (baseline=${BASELINE_QUALITY} degraded=${DEGRADED_QUALITY})"
                fi
            fi
        fi
    else
        skip "test_vwifi_ctrl_distance_based_loss" "vwifi-ctrl not available"
    fi
else
    skip "test_vwifi_ctrl_distance_based_loss" "wired mesh (br-lan) not affected by vwifi distance simulation"
fi

# Test 2: Node removal detected — stop bmx7 on node-3 and verify mesh change
echo "# Testing node removal detection..."
# QEMU runs as root (started via sudo), so we can't kill the process.
# Instead, stop bmx7 on node-3 to simulate removal from the mesh,
# then verify the topology adapter detects fewer active links.
BASELINE_LINKS=$(bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/adapters/mesh/collect-topology.sh" "$GATEWAY" 2>/dev/null \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('links', [])))" 2>/dev/null || echo "0")

# Stop bmx7 on node-3 (simulates node leaving the mesh)
if ssh_vm "lm-testbed-node-3" "killall bmx7 2>/dev/null || true" 2>/dev/null; then
    # Wait for BMX7 to detect the missing hello messages and expire the link
    echo "  # Waiting 45s for BMX7 to detect node-3 absence..."
    sleep 45

    # Check topology — link count should decrease
    AFTER_LINKS=$(bash "${LAB_CLI}" run-adapter \
        "${MESHA_ROOT}/adapters/mesh/collect-topology.sh" "$GATEWAY" 2>/dev/null \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('links', [])))" 2>/dev/null || echo "$BASELINE_LINKS")

    if [ "${AFTER_LINKS}" -lt "${BASELINE_LINKS}" ] 2>/dev/null; then
        pass "test_node_removal_detected"
    else
        fail "test_node_removal_detected" "link count unchanged (${BASELINE_LINKS} -> ${AFTER_LINKS})"
    fi

    # Restart bmx7 on node-3
    echo "  # Restarting bmx7 on node-3..."
    restart_bmx7 "lm-testbed-node-3"
    echo "  # bmx7 restarted on node-3"
else
    skip "test_node_removal_detected" "could not stop bmx7 on node-3"
fi

tap_summary
