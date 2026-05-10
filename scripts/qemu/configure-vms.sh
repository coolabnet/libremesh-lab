#!/usr/bin/env bash
# configure-vms.sh — Post-boot configuration for LibreMesh Lab VMs
# Waits for SSH, configures mesh networking, injects SSH keys
#
# Supports two image types:
#   - Prebuilt: connects via password auth, injects keys
#   - Source-built (prepared): connects via key auth (keys pre-baked into image)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="${REPO_ROOT}/run"
TOPOLOGY_FILE="${REPO_ROOT}/config/topology.yaml"
SSH_KEY_DIR="${RUN_DIR}/ssh-keys"
SSH_KEY="${SSH_KEY_DIR}/id_rsa"

# Timeout multiplier for TCG mode
TIMEOUT_MULTIPLIER="${QEMU_TIMEOUT_MULTIPLIER:-1}"
SSH_BASE_TIMEOUT=$((5 * TIMEOUT_MULTIPLIER))
# BOOT_WAIT_TIMEOUT used for reference; actual wait is per-VM with retries
export BOOT_WAIT_TIMEOUT=$((120 * TIMEOUT_MULTIPLIER))
MAX_SSH_RETRIES=15

# Node definitions (fallback if no topology.yaml)
declare -a NODE_IPS=("10.99.0.11" "10.99.0.12" "10.99.0.13" "10.99.0.14")
declare -a NODE_HOSTNAMES=("lm-testbed-node-1" "lm-testbed-node-2" "lm-testbed-node-3" "lm-testbed-tester")
declare -a NODE_MACS=("52:54:00:00:00:01" "52:54:00:00:00:02" "52:54:00:00:00:03" "52:54:00:00:00:04")

VWIFI_SERVER_IP="10.99.0.254"
VWIFI_TCP_PORT="8212"
VWIFI_RADIOS="1"
VWIFI_SSID="MeshaTestBed"
VWIFI_FREQ="2462"

# ─── Parse topology ───
parse_topology() {
    if [ ! -f "$TOPOLOGY_FILE" ]; then
        return
    fi
    # Simplified topology parse: extract hostname/ip pairs in order
    NODE_IPS=()
    NODE_HOSTNAMES=()
    NODE_MACS=()
    while IFS= read -r line; do
        case "$line" in
            *"hostname:"*)
                NODE_HOSTNAMES+=("$(echo "$line" | awk -F': ' '{print $2}' | tr -d '"')")
                ;;
            *" ip:"*)
                NODE_IPS+=("$(echo "$line" | awk -F': ' '{print $2}' | tr -d '"')")
                ;;
            *"mac_mesh:"*)
                NODE_MACS+=("$(echo "$line" | awk -F': ' '{print $2}' | tr -d '"')")
                ;;
        esac
    done < <(awk '
        /^    - id:/ { in_node=1 }
        /^  vwifi:/ { in_node=0 }
        in_node && /hostname:/ { print }
        in_node && / ip:/ { print }
        in_node && /mac_mesh:/ { print }
    ' "$TOPOLOGY_FILE")

    local vwifi_server_ip vwifi_tcp_port
    vwifi_server_ip=$(awk -F': ' '/listen_address:/ {gsub(/"/, "", $2); print $2; exit}' "$TOPOLOGY_FILE")
    vwifi_tcp_port=$(awk -F': ' '/tcp_port:/ {gsub(/"/, "", $2); print $2; exit}' "$TOPOLOGY_FILE")
    [ -n "$vwifi_server_ip" ] && VWIFI_SERVER_IP="$vwifi_server_ip"
    [ -n "$vwifi_tcp_port" ] && VWIFI_TCP_PORT="$vwifi_tcp_port"
}

verify_vwifi_server() {
    if timeout 2 bash -c ":</dev/tcp/${VWIFI_SERVER_IP}/${VWIFI_TCP_PORT}" 2>/dev/null; then
        echo "  vwifi-server reachable at ${VWIFI_SERVER_IP}:${VWIFI_TCP_PORT}"
        return 0
    fi

    echo "  WARN: vwifi-server is not reachable at ${VWIFI_SERVER_IP}:${VWIFI_TCP_PORT}; wlan mesh may not form"
    return 1
}

# ─── SSH helper ───
# Tries key auth first (if SSH key exists), falls back to password auth.
# This makes the script work with both source-built (pre-baked keys) and
# prebuilt images (password auth) transparently.
ssh_vm() {
    local ip="$1"
    shift

    # Try key-based auth first when key file exists (source-built images)
    if [[ -f "${SSH_KEY}" ]]; then
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o HostKeyAlgorithms=+ssh-rsa \
            -o PubkeyAcceptedKeyTypes=+ssh-rsa \
            -o BatchMode=yes \
            -o IdentitiesOnly=yes \
            -i "${SSH_KEY}" \
            -o ConnectTimeout="${SSH_BASE_TIMEOUT}" \
            "root@${ip}" "$@" 2>/dev/null && return 0
    fi

    # Fallback: password auth via sshpass (empty password for source-built images)
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "" ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o HostKeyAlgorithms=+ssh-rsa \
            -o PubkeyAcceptedKeyTypes=+ssh-rsa \
            -o ConnectTimeout="${SSH_BASE_TIMEOUT}" \
            "root@${ip}" "$@" 2>/dev/null && return 0
    fi

    # Last resort: try without key (for prebuilt images with password)
    # Use NumberOfPasswordPrompts=0 to avoid hanging on interactive prompt
    sshpass -p "root" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o HostKeyAlgorithms=+ssh-rsa \
        -o PubkeyAcceptedKeyTypes=+ssh-rsa \
        -o ConnectTimeout="${SSH_BASE_TIMEOUT}" \
        -o NumberOfPasswordPrompts=0 \
        "root@${ip}" "$@" 2>/dev/null && return 0

    return 1
}

ssh_vm_with_key() {
    local ip="$1"
    shift
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o HostKeyAlgorithms=+ssh-rsa \
        -o PubkeyAcceptedKeyTypes=+ssh-rsa \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -i "${SSH_KEY}" \
        -o ConnectTimeout="${SSH_BASE_TIMEOUT}" \
        "root@${ip}" "$@"
}

# ─── Wait for SSH on a VM ───
wait_for_ssh() {
    local ip="$1"
    local hostname="$2"
    local attempt=1
    local delay=2

    echo -n "  [${hostname}] Waiting for SSH at ${ip}..."

    while [ $attempt -le $MAX_SSH_RETRIES ]; do
        if ssh_vm "$ip" "echo ok" &>/dev/null; then
            echo " OK (attempt ${attempt})"
            return 0
        fi
        echo -n "."
        sleep "$delay"
        delay=$((delay * 2 > 30 ? 30 : delay * 2))
        attempt=$((attempt + 1))
    done

    echo " FAILED"
    echo "  [${hostname}] ERROR: SSH not reachable after ${MAX_SSH_RETRIES} attempts"
    return 1
}

# ─── Configure a single VM ───
configure_vm() {
    local node_id="$1"
    local ip="$2"
    local hostname="$3"
    local mesh_mac="$4"
    echo "  [${hostname}] Phase 1: Basic LibreMesh configuration..."

    # Set hostname
    ssh_vm "$ip" "uci set system.@system[0].hostname='${hostname}' && uci commit system && echo '${hostname}' > /proc/sys/kernel/hostname" || true

    # Configure mesh interface IP on br-lan (set static for when DHCP lease expires;
    # for source-built images, dnsmasq already assigned the correct IP via DHCP)
    ssh_vm "$ip" "
        uci set network.lan.proto='static'
        uci set network.lan.ipaddr='${ip}'
        uci set network.lan.netmask='255.255.0.0'
        uci set network.lan.gateway='10.99.0.254'
        uci commit network
    " || true

    # Load mac80211_hwsim (remove real radios, replaced by vwifi)
    ssh_vm "$ip" "modprobe mac80211_hwsim radios=0 2>/dev/null || true" || true

    # vwifi-client can create mac80211_hwsim radios itself. This avoids
    # copying the host-built vwifi-add-interfaces binary into OpenWrt.
    local mac_prefix="${mesh_mac}"

    # Set vwifi UCI config (section name is 'config' per vwifi_cli_package README)
    ssh_vm "$ip" "
        uci -q get vwifi.config >/dev/null 2>&1 || uci set vwifi.config='vwifi'
        uci set vwifi.config.server_ip='${VWIFI_SERVER_IP}'
        uci set vwifi.config.mac_prefix='${mac_prefix}'
        uci set vwifi.config.enabled='1'
        uci commit vwifi
    " || true

    # Detect if lime-config is available (full LibreMesh vs bare OpenWrt)
    local has_lime_config
    has_lime_config=$(ssh_vm "$ip" "which lime-config 2>/dev/null && echo yes || echo no") || has_lime_config="no"

    if [[ "${has_lime_config}" == *"yes"* ]]; then
        echo "  [${hostname}] Full LibreMesh detected, using lime-config..."

        # Set lime-community UCI config
        ssh_vm "$ip" "
            uci get lime-community.wifi >/dev/null 2>&1 || uci set lime-community.wifi=lime
            uci set lime-community.wifi.ap_ssid='MeshaTestBed'
            uci set lime-community.wifi.apname='MeshaTestBed'
            uci set lime-community.wifi.mode='adhoc'
            uci set lime-community.wifi.channel='11'
            uci get lime-community.network >/dev/null 2>&1 || uci set lime-community.network=lime
            uci set lime-community.network.protocols='bmx7'
            uci set lime-community.network.domain='testbed.mesh'
            uci get lime-community.system >/dev/null 2>&1 || uci set lime-community.system=lime
            uci set lime-community.system.community_name='Mesha-Testbed'
            uci commit lime-community
        " || true

        # Set lime-node UCI config
        ssh_vm "$ip" "
            uci get lime-node.network >/dev/null 2>&1 || uci set lime-node.network=lime
            uci set lime-node.network.main_ipv4_address='${ip}/16'
            uci commit lime-node
        " || true

        # Run lime-config sequence
        # vwifi-client is started first to create the PHY radio, then we wait
        # for the PHY to appear before running wifi config (which needs the radio).
        echo "  [${hostname}] Running lime-config sequence..."
        ssh_vm "$ip" "
            service vwifi-client start 2>/dev/null || true
            killall vwifi-client 2>/dev/null || true
            vwifi-client --number ${VWIFI_RADIOS} --mac '${mac_prefix}' --port ${VWIFI_TCP_PORT} '${VWIFI_SERVER_IP}' >/tmp/vwifi-client.log 2>&1 &
            sleep 2
            wifi config && \
            lime-config && \
            wifi down && \
            sleep 7 && \
            wifi up
        " || echo "  [${hostname}] WARN: lime-config sequence had errors"
    else
        echo "  [${hostname}] Bare OpenWrt detected (no lime-config), configuring bmx7 directly..."

        # Start vwifi-client if vwifi is installed.
        # vwifi-client --number N creates PHY radios via mac80211_hwsim netlink,
        # but does NOT create wlan0 network interfaces.
        # We must create wlan0 manually with `iw phy <phy> interface add`.
        #
        # IMPORTANT: OpenWrt ash does not have `nohup`. Use plain `&` instead.
        #
        # The PHY created by vwifi-client is the LAST one in /sys/class/ieee80211/,
        # not phy0 (which is the placeholder from `modprobe mac80211_hwsim radios=0`).
        # shellcheck disable=SC2140
        ssh_vm "$ip" "
            killall vwifi-client 2>/dev/null || true
            modprobe mac80211_hwsim radios=0 2>/dev/null || true
            if command -v vwifi-client >/dev/null 2>&1; then
                # Record phys before vwifi-client starts
                _before=\$(ls /sys/class/ieee80211/ 2>/dev/null)
                vwifi-client --number ${VWIFI_RADIOS} --mac '${mac_prefix}' --port ${VWIFI_TCP_PORT} '${VWIFI_SERVER_IP}' >/tmp/vwifi-client.log 2>&1 &
                echo \$! >/var/run/vwifi-client.pid
                sleep 2

                # Find the NEW phy(s) created by vwifi-client
                _after=\$(ls /sys/class/ieee80211/ 2>/dev/null)
                _new_phy=
                for p in \$_after; do
                    echo \"\$_before\" | grep -q \"\$p\" || _new_phy=\"\$p\"
                done

                if [ -n \"\$_new_phy\" ]; then
                    # Create wlan0 on the vwifi-client-created PHY
                    iw phy \$_new_phy interface add wlan0 type ibss 2>/dev/null || true
                    # Wait for interface to appear
                    for _i in \$(seq 1 10); do
                        iw dev wlan0 info >/dev/null 2>&1 && break
                        sleep 1
                    done
                fi
            fi
        " || true

        # Check if wlan0 was created
        local has_wlan=false
        ssh_vm "$ip" "iw dev wlan0 info >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null | grep -q yes && has_wlan=true

        if ${has_wlan}; then
            echo "  [${hostname}] wlan0 created via vwifi, configuring IBSS mesh..."
            # Configure IBSS adhoc mesh on wlan0
            ssh_vm "$ip" "
                ip link set wlan0 down 2>/dev/null || true
                iw dev wlan0 set type ibss 2>/dev/null || true
                ip link set wlan0 up 2>/dev/null || true
                iw dev wlan0 ibss join '${VWIFI_SSID}' ${VWIFI_FREQ} 2>/dev/null || true
            " || true
        else
            echo "  [${hostname}] WARN: wlan0 not available, using wired br-lan fallback"
        fi

        # Configure and start bmx7.
        # Use BOTH wlan0 and br-lan when wlan0 is available:
        #   - wlan0 provides the WiFi/IBSS simulation for adapter testing
        #   - br-lan ensures BMX7 convergence (vwifi IBSS forwards beacons
        #     but not data frames, so OGMs need the wired path)
        ssh_vm "$ip" "
            killall bmx7 2>/dev/null || true
            if iw dev wlan0 info >/dev/null 2>&1; then
                bmx7 dev=wlan0 dev=br-lan 2>&1 || bmx7 dev=br-lan 2>&1 || true
            else
                bmx7 dev=br-lan 2>&1 || true
            fi
        " || true
    fi

    # For LibreMesh: lime-config + wifi up already started bmx7 via proto-bmx7,
    # so only ensure dual-interface mode for bare OpenWrt (where bmx7 was started
    # in the else branch above but may not have picked up wlan0 if timing was off).
    # For bare OpenWrt: re-verify bmx7 has both interfaces.
    if [[ "${has_lime_config}" != *"yes"* ]]; then
        ssh_vm "$ip" "
            if command -v bmx7 >/dev/null 2>&1; then
                killall bmx7 2>/dev/null || true
                if iw dev wlan0 info >/dev/null 2>&1; then
                    bmx7 dev=wlan0 dev=br-lan 2>&1 || bmx7 dev=br-lan 2>&1 || true
                else
                    bmx7 dev=br-lan 2>&1 || true
                fi
            fi
        " || true
    fi

    # Enable uhttpd
    ssh_vm "$ip" "
        uci set uhttpd.main.listen_http='0.0.0.0:80'
        uci commit uhttpd
        service uhttpd enable 2>/dev/null || true
        service uhttpd restart 2>/dev/null || true
    " || true

    # Set /etc/hosts with all node entries
    local hosts_entries=""
    local idx=0
    for node_ip in "${NODE_IPS[@]}"; do
        local hname="${NODE_HOSTNAMES[$idx]}"
        hosts_entries="${hosts_entries}${node_ip}	${hname}
"
        idx=$((idx + 1))
    done
    # Append to /etc/hosts (don't overwrite — keep localhost)
    ssh_vm "$ip" "cat >> /etc/hosts << 'HOSTSEOF'
${hosts_entries}HOSTSEOF" || true

    # Set /etc/openwrt_release with test firmware version
    ssh_vm "$ip" "sed -i 's/OPENWRT_RELEASE=.*/OPENWRT_RELEASE=\"Mesha Testbed v0.1.0 (LibreMesh)\"/' /etc/openwrt_release 2>/dev/null || true" || true

    echo "  [${hostname}] Phase 1 complete."
}

# ─── SSH key injection ───
generate_and_inject_keys() {
    echo ""
    echo "=== Phase 2: SSH key injection ==="

    mkdir -p "${SSH_KEY_DIR}"

    # Generate key pair if needed
    if [ ! -f "${SSH_KEY}" ]; then
        echo "  Generating RSA SSH key pair (compatible with prebuilt dropbear)..."
        ssh-keygen -t rsa -b 2048 -f "${SSH_KEY}" -N "" -C "mesha-testbed" >/dev/null
    fi

    local public_key
    public_key=$(cat "${SSH_KEY}.pub")

    local idx=0
    for ip in "${NODE_IPS[@]}"; do
        local hostname="${NODE_HOSTNAMES[$idx]}"

        # Check if key is already present (pre-baked by prepare-source-image.sh)
        if ssh_vm "$ip" "grep -qF '$(echo "${public_key}" | awk '{print $2}')' /root/.ssh/authorized_keys 2>/dev/null" &>/dev/null; then
            echo "  [${hostname}] SSH key already present (pre-baked), skipping injection."
            # Still lock down dropbear for consistency
            ssh_vm "$ip" "
                uci set dropbear.@dropbear[0].PasswordAuth='off'
                uci set dropbear.@dropbear[0].RootPasswordAuth='off'
                uci commit dropbear
                service dropbear restart
            " 2>/dev/null || echo "  [${hostname}] WARN: Could not lock dropbear"
            idx=$((idx + 1))
            continue
        fi

        echo "  [${hostname}] Injecting SSH key..."

        # Inject public key
        ssh_vm "$ip" "mkdir -p /root/.ssh && echo '${public_key}' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && chmod 700 /root/.ssh" || {
            echo "  [${hostname}] WARN: Key injection failed"
            idx=$((idx + 1))
            continue
        }

        # Lock down dropbear to key-only auth
        ssh_vm "$ip" "
            uci set dropbear.@dropbear[0].PasswordAuth='off'
            uci set dropbear.@dropbear[0].RootPasswordAuth='off'
            uci commit dropbear
            service dropbear restart
        " || echo "  [${hostname}] WARN: Could not lock dropbear"

        echo "  [${hostname}] Key injected, password auth disabled."
        idx=$((idx + 1))
    done
}

# ─── Verify key-based access ───
verify_key_access() {
    echo ""
    echo "=== Verifying key-based SSH access ==="
    local idx=0
    local ok=0
    for ip in "${NODE_IPS[@]}"; do
        local hostname="${NODE_HOSTNAMES[$idx]}"
        if ssh_vm_with_key "$ip" "echo 'key auth works'" &>/dev/null; then
            echo "  [${hostname}] OK — key-based SSH working"
            ok=$((ok + 1))
        else
            echo "  [${hostname}] WARN — key-based SSH not working"
        fi
        idx=$((idx + 1))
    done
    echo "  ${ok}/${#NODE_IPS[@]} VMs accessible via key-based SSH"
}

# ─── Main ───
main() {
    echo "=========================================="
    echo " Mesha VM Configuration"
    echo "=========================================="
    echo ""

    parse_topology
    verify_vwifi_server || true

    # Phase 0: Wait for all VMs to be SSH-reachable
    echo "=== Phase 0: Waiting for VMs to boot ==="
    local idx=0
    local failed=0
    for ip in "${NODE_IPS[@]}"; do
        local hostname="${NODE_HOSTNAMES[$idx]}"
        if ! wait_for_ssh "$ip" "$hostname"; then
            failed=$((failed + 1))
        fi
        idx=$((idx + 1))
    done

    if [ "$failed" -gt 0 ]; then
        echo ""
        echo "ERROR: ${failed} VM(s) not reachable via SSH. Aborting configuration."
        exit 1
    fi

    # Phase 1: Basic configuration
    echo ""
    echo "=== Phase 1: Configuring LibreMesh ==="
    idx=0
    for ip in "${NODE_IPS[@]}"; do
        local hostname="${NODE_HOSTNAMES[$idx]}"
        local node_id=$((idx + 1))
        local mesh_mac="${NODE_MACS[$idx]:-52:54:00:00:00:0${node_id}}"
        configure_vm "$node_id" "$ip" "$hostname" "$mesh_mac"
        idx=$((idx + 1))
    done

    # Configure thisnode.info on host (for discover-from-thisnode.sh)
    echo "Configuring thisnode.info resolution on host..."
    if [ -w /etc/hosts ]; then
        grep -q 'thisnode.info' /etc/hosts 2>/dev/null || \
            echo "10.99.0.11  thisnode.info" >> /etc/hosts
    else
        # Alternative: create HOSTALIASES file
        mkdir -p "${REPO_ROOT}/run"
        echo "thisnode.info 10.99.0.11" > "${REPO_ROOT}/run/host-aliases"
        echo "  Note: set HOSTALIASES=${REPO_ROOT}/run/host-aliases for thisnode.info resolution"
    fi

    # Phase 2: SSH keys
    generate_and_inject_keys

    # Phase 3: Mesh convergence (source-built images with bmx7)
    echo ""
    echo "=== Phase 3: Mesh convergence ==="
    local bmx7_available=false
    # Check if bmx7 is available on the first node
    if ssh_vm "${NODE_IPS[0]}" "which bmx7 >/dev/null 2>&1" 2>/dev/null; then
        bmx7_available=true
    fi

    if ${bmx7_available}; then
        echo "  BMX7 detected — waiting for mesh convergence..."
        local convergence_ok=true
        for ip in "${NODE_IPS[@]}"; do
            local expected_peers=$(( ${#NODE_IPS[@]} - 1 ))
            local attempt=0
            local max_attempts=18  # 90 seconds at 5s intervals
            echo -n "  [${ip}] Waiting for ${expected_peers} BMX7 peers..."
            while [ $attempt -lt $max_attempts ]; do
                local peer_count
                peer_count=$(ssh_vm "$ip" "bmx7 -c originators 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || echo "0")
                peer_count=$(echo "$peer_count" | tr -d '[:space:]')
                if [ "${peer_count}" -ge "${expected_peers}" ] 2>/dev/null; then
                    echo " OK (${peer_count} peers)"
                    break
                fi
                if [ $attempt -eq $((max_attempts - 1)) ]; then
                    echo " TIMEOUT (${peer_count}/${expected_peers} peers)"
                    convergence_ok=false
                fi
                sleep 5
                attempt=$((attempt + 1))
            done
        done

        if ${convergence_ok}; then
            echo "  Mesh converged — all nodes see each other."
        else
            echo "  WARN: Mesh did not fully converge. Tests may still pass with partial connectivity."
        fi
    else
        echo "  BMX7 not available (prebuilt image) — skipping mesh convergence."
    fi

    # Verification
    verify_key_access

    # Generate SSH config with absolute paths
    sed "s|__REPO_ROOT__|${REPO_ROOT}|g" \
        "${REPO_ROOT}/config/ssh-config" \
        > "${REPO_ROOT}/config/ssh-config.resolved"

    echo ""
    echo "=========================================="
    echo " Configuration complete!"
    echo " SSH key: ${SSH_KEY}"
    echo " Connect: ssh -i ${SSH_KEY} root@10.99.0.1{1,2,3,4}"
    echo "=========================================="
}

main "$@"
