#!/usr/bin/env bash
# Topology manipulation tests — vwifi-ctrl distance-based loss and node removal.
# Protocol-agnostic: uses the active mesh daemon (babeld/bmx7/batman-adv)
# and falls back to skipping protocol-specific assertions when the daemon
# doesn't expose the required telemetry (e.g. bmx7 `bmx7 -c links` TQ).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Topology Manipulation Tests"
tap_plan 2

GATEWAY=$(get_gateway)
VWIFI_CTRL="${REPO_ROOT}/bin/vwifi-ctrl"
MESH_PROTO=$(detect_mesh_protocol "$GATEWAY")

if [ "${MESH_PROTO}" = "none" ]; then
    echo "# No mesh protocol installed — skipping topology manipulation tests"
    skip "test_vwifi_ctrl_distance_based_loss" "no mesh protocol on prebuilt image"
    skip "test_node_removal_detected" "no mesh protocol on prebuilt image"
    tap_summary
    exit 0
fi

# Ensure the active mesh daemon is stable on all nodes.
echo "# Waiting for ${MESH_PROTO} convergence..."
MESH_RESULT=0
wait_for_mesh "$GATEWAY" 2 90 || MESH_RESULT=$?

if [ "${MESH_RESULT}" -eq 1 ]; then
    echo "Bail out! ${MESH_PROTO} not converged"
    exit 1
fi

# Ensure the daemon is running on all mesh nodes (may have been stopped by
# prior tests). Use the protocol-agnostic restart helper.
for _node in lm-testbed-node-2 lm-testbed-node-3; do
    if [ "$(count_mesh_neighbors "$_node")" -eq 0 ] 2>/dev/null; then
        restart_mesh_protocol "$_node"
    fi
done
sleep 5

# Test 1: vwifi-ctrl distance-based loss degrades link quality.
# Only bmx7 exposes per-link TQ (transmit quality) metrics suitable for
# measuring wireless degradation. babeld reports neighbours but no TQ
# value, and batman-adv uses a different metric entirely. Skip the
# quality measurement on non-bmx7 protocols; the topology-removal test
# below covers the generic case.
echo "# Testing vwifi-ctrl distance-based loss..."
MESH_IFACE=$(mesh_dev "$GATEWAY")
if [ "${MESH_PROTO}" != "bmx7" ]; then
    skip "test_vwifi_ctrl_distance_based_loss" \
        "${MESH_PROTO} does not expose per-link TQ for distance-based loss measurement (bmx7-specific)"
elif echo "${MESH_IFACE}" | grep -qi "wlan\|wifi\|adhoc\|mesh0"; then
    if [ ! -x "${VWIFI_CTRL}" ]; then
        skip "test_vwifi_ctrl_distance_based_loss" "vwifi-ctrl not available"
    else
        mapfile -t VWIFI_CIDS < <("${VWIFI_CTRL}" ls 2>/dev/null | awk '/^[0-9]+[[:space:]]/ {print $1}')
        if [ "${#VWIFI_CIDS[@]}" -lt 2 ]; then
            fail "test_vwifi_ctrl_distance_based_loss" "vwifi-ctrl sees ${#VWIFI_CIDS[@]} connected clients"
        else
            # Check if bmx7 links are over wlan0 (data frames forwarded) or br-lan (dual-interface)
            BMX7_LINK_DEV=$(ssh_vm "$GATEWAY" \
                "bmx7 -c links 2>/dev/null | awk 'NR>1{print \$6}' | sort -u | head -1" 2>/dev/null || echo "")
            if [ "${BMX7_LINK_DEV}" = "br-lan" ]; then
                # Dual-interface mode: bmx7 uses br-lan for data, vwifi loss won't affect it
                skip "test_vwifi_ctrl_distance_based_loss" \
                    "bmx7 uses br-lan (dual-interface mode); vwifi distance simulation has no effect on wired links"
            else
                # Record baseline link quality (bmx7 TQ).
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
    fi
else
    skip "test_vwifi_ctrl_distance_based_loss" "wired mesh (br-lan) not affected by vwifi distance simulation"
fi

# Test 2: Node removal detected — stop the active daemon on node-3 and
# verify the topology adapter reflects fewer active links. Works for any
# protocol because we observe the topology, not the daemon.
echo "# Testing node removal detection..."
BASELINE_LINKS=$(bash "${LAB_CLI}" run-adapter \
    "${MESHA_ROOT}/adapters/mesh/collect-topology.sh" "$GATEWAY" 2>/dev/null \
    | ${PYTHON} -c "import sys,json; print(len(json.load(sys.stdin).get('links', [])))" 2>/dev/null || echo "0")

# Stop the active daemon on node-3 (simulates node leaving the mesh).
# detect_mesh_protocol returns the protocol name (babeld, bmx7, batman-adv);
# killall needs the daemon binary name (batmand for batman-adv).
MESH_BIN="${MESH_PROTO}"
[ "${MESH_PROTO}" = "batman-adv" ] && MESH_BIN="batmand"
if ssh_vm "lm-testbed-node-3" "killall ${MESH_BIN} 2>/dev/null || true" 2>/dev/null; then
    # Wait for the protocol to detect the missing hello messages and expire the link.
    echo "  # Waiting 45s for ${MESH_PROTO} to detect node-3 absence..."
    sleep 45

    AFTER_LINKS=$(bash "${LAB_CLI}" run-adapter \
        "${MESHA_ROOT}/adapters/mesh/collect-topology.sh" "$GATEWAY" 2>/dev/null \
        | ${PYTHON} -c "import sys,json; print(len(json.load(sys.stdin).get('links', [])))" 2>/dev/null || echo "$BASELINE_LINKS")

    if [ "${AFTER_LINKS}" -lt "${BASELINE_LINKS}" ] 2>/dev/null; then
        pass "test_node_removal_detected"
    else
        fail "test_node_removal_detected" "link count unchanged (${BASELINE_LINKS} -> ${AFTER_LINKS})"
    fi

    # Restart the daemon on node-3 using the protocol-agnostic helper.
    echo "  # Restarting ${MESH_PROTO} on node-3..."
    restart_mesh_protocol "lm-testbed-node-3"
    echo "  # ${MESH_PROTO} restarted on node-3"
else
    skip "test_node_removal_detected" "could not stop ${MESH_PROTO} on node-3"
fi

tap_summary
