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
SSH_KEY="${SSH_KEY_DIR}/id_ed25519"

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
BRIDGE_NAME="mesha-br0"

ensure_ssh_key() {
    mkdir -p "${SSH_KEY_DIR}"

    if [ ! -f "${SSH_KEY}" ]; then
        echo "  Generating ED25519 SSH key pair..."
        ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "mesha-testbed" >/dev/null
    fi

    if [[ -n "${SUDO_USER:-}" ]]; then
        local sudo_gid="${SUDO_GID:-$(id -g "${SUDO_USER}")}"
        chown "${SUDO_USER}:${sudo_gid}" "${SSH_KEY}" "${SSH_KEY}.pub"
        chmod 600 "${SSH_KEY}"
        chmod 644 "${SSH_KEY}.pub"
    fi
}

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

# Start (or restart) the mesh routing daemon on a single VM, using whichever
# interfaces are present. Used twice: once on the initial configure pass and
# again as a re-verify step for bare-OpenWrt nodes where the daemon was
# started before wlan0 came up. Aligns the babeld invocation form with
# tests/qemu/common.sh:restart_mesh_protocol (-I /var/run/babeld.pid) so
# the lab and test paths produce equivalent processes.
#
# Args:
#   $1 — VM IP
#   $2 — mesh protocol: bmx7 | babeld
start_mesh_daemon_on_vm() {
    local ip="$1"
    local proto="$2"
    case "${proto}" in
        babeld|bmx7) ;;
        "") return 0 ;;
        *)
            echo "  [${ip}] WARN: refusing to start unsupported mesh protocol: ${proto}" >&2
            return 1
            ;;
    esac

    ssh_vm "$ip" "
        killall ${proto} 2>/dev/null || true
        if iw dev wlan0 info >/dev/null 2>&1; then
            case '${proto}' in
                babeld) babeld -D -I /var/run/babeld.pid wlan0 br-lan 2>&1 \
                            || babeld -D -I /var/run/babeld.pid br-lan 2>&1 || true ;;
                bmx7)   bmx7 dev=wlan0 dev=br-lan 2>&1 \
                            || bmx7 dev=br-lan 2>&1 || true ;;
            esac
        else
            case '${proto}' in
                babeld) babeld -D -I /var/run/babeld.pid br-lan 2>&1 || true ;;
                bmx7)   bmx7 dev=br-lan 2>&1 || true ;;
            esac
        fi
    " || true
}

# ─── SSH helper ───
# Tries key auth first (if SSH key exists), falls back to password auth.
# This makes the script work with both source-built (pre-baked keys) and
# prebuilt images (password auth) transparently.
ssh_target() {
    local host="$1"

    if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
        printf 'root@[%s]' "${host}"
    else
        printf 'root@%s' "${host}"
    fi
}

ssh_vm() {
    local ip="$1"
    shift
    local target
    target="$(ssh_target "${ip}")"

    # Try key-based auth first when key file exists (source-built images)
    if [[ -f "${SSH_KEY}" ]]; then
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o HostKeyAlgorithms=+ssh-rsa \
            -o BatchMode=yes \
            -o IdentitiesOnly=yes \
            -i "${SSH_KEY}" \
            -o ConnectTimeout="${SSH_BASE_TIMEOUT}" \
            "${target}" "$@" 2>/dev/null && return 0
    fi

    # Fallback: password auth via sshpass (empty password for source-built images)
    # Use PreferredAuthentications=password to avoid "none" auth masking key issues
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "" ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o HostKeyAlgorithms=+ssh-rsa \
            -o PreferredAuthentications=password \
            -o ConnectTimeout="${SSH_BASE_TIMEOUT}" \
            "${target}" "$@" 2>/dev/null && return 0
    fi

    # Last resort: try with password "root" (for prebuilt images)
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "root" ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o HostKeyAlgorithms=+ssh-rsa \
            -o PreferredAuthentications=password \
            -o ConnectTimeout="${SSH_BASE_TIMEOUT}" \
            "${target}" "$@" 2>/dev/null && return 0
    fi

    return 1
}

ssh_vm_with_key() {
    local ip="$1"
    shift
    local target
    target="$(ssh_target "${ip}")"

    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o HostKeyAlgorithms=+ssh-rsa \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o PreferredAuthentications=publickey \
        -i "${SSH_KEY}" \
        -o ConnectTimeout="${SSH_BASE_TIMEOUT}" \
        "${target}" "$@"
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

    # Detect which mesh routing protocol is available. Order matches
    # tests/qemu/common.sh:detect_mesh_protocol: babeld > bmx7. Used by both
    # the LibreMesh (post-lime-config repair) and bare-OpenWrt paths, and
    # by the unified re-verify block at the end of configure_vm.
    local mesh_proto="none"
    if ssh_vm "$ip" "which babeld >/dev/null 2>&1" 2>/dev/null; then
        mesh_proto="babeld"
    elif ssh_vm "$ip" "which bmx7 >/dev/null 2>&1" 2>/dev/null; then
        mesh_proto="bmx7"
    fi

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
            # babeld first to match the babeld-first detection in
            # the bare-OpenWrt branch below (see the detection block above in
            # the else-branch of the has_lime_config check).
            # bmx7 is kept as a fallback for pre-babeld images.
            uci set lime-community.network.protocols='babeld bmx7'
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

        # Post-lime-config verification: the rc.local in the image already
        # rewrote /etc/config/network to DHCP-on-br-lan and started babeld,
        # but lime-config may have re-clobbered either one. Verify and repair
        # here over SSH (the rc.local runs before SSH is up, so this is the
        # authoritative safety net).
        echo "  [${hostname}] Verifying post-lime-config network state..."
        local brlan_ip
        brlan_ip=$(ssh_vm "$ip" "ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print \$2; exit}'" 2>/dev/null) || brlan_ip=""
        if [[ -z "${brlan_ip}" || "${brlan_ip}" != "${ip}/"* ]]; then
            echo "  [${hostname}] WARN: br-lan has wrong IP ('${brlan_ip:-none}'), re-applying testbed network config"
            ssh_vm "$ip" "
                uci -q delete network.lan 2>/dev/null
                uci -q delete network.br_lan 2>/dev/null
                uci set network.br_lan=device
                uci set network.br_lan.name='br-lan'
                uci set network.br_lan.type='bridge'
                uci add_list network.br_lan.ports='eth0'
                uci set network.lan=interface
                uci set network.lan.device='br-lan'
                uci set network.lan.proto='static'
                uci set network.lan.ipaddr='${ip}'
                uci set network.lan.netmask='255.255.0.0'
                uci set network.lan.gateway='10.99.0.254'
                uci set network.lan.metric='100'
                uci commit network
                /etc/init.d/network restart >/tmp/network-restart.log 2>&1 || true
            " || echo "  [${hostname}] WARN: post-lime network repair failed"
            # Re-apply the IP immediately so subsequent SSH commands in this
            # function (and Phase 2/3) can reach the VM at the expected IP.
            ssh_vm "$ip" "ip addr replace ${ip}/16 dev br-lan 2>/dev/null || true" || true
        fi

        # Ensure babeld is running on br-lan. The rc.local should have done
        # this, but lime-config may have killed it or pointed it at a VLAN
        # interface. Verify via pgrep + UDP listener (matches the convergence
        # signal in tests/qemu/common.sh:count_mesh_neighbors).
        if [[ "${mesh_proto}" == "babeld" ]]; then
            local babeld_ok
            babeld_ok=$(ssh_vm "$ip" "pgrep -x babeld >/dev/null 2>&1 && (netstat -ulnp 2>/dev/null || ss -ulnp 2>/dev/null) | grep -q babeld && echo yes || echo no" 2>/dev/null | tr -d '[:space:]')
            if [[ "${babeld_ok}" != "yes" ]]; then
                echo "  [${hostname}] babeld not listening, restarting..."
                if ssh_vm "$ip" "[ -x /etc/init.d/babeld ]" 2>/dev/null; then
                    ssh_vm "$ip" "/etc/init.d/babeld enable 2>/dev/null; /etc/init.d/babeld restart 2>/dev/null || babeld -D -I /var/run/babeld.pid br-lan 2>/dev/null &" || true
                else
                    ssh_vm "$ip" "killall babeld 2>/dev/null; babeld -D -I /var/run/babeld.pid br-lan 2>/dev/null &" || true
                fi
            fi
        elif [[ "${mesh_proto}" == "bmx7" ]]; then
            if ! ssh_vm "$ip" "pgrep -x bmx7 >/dev/null 2>&1" 2>/dev/null; then
                echo "  [${hostname}] bmx7 not running, starting..."
                ssh_vm "$ip" "killall bmx7 2>/dev/null; bmx7 dev=br-lan 2>/dev/null &" || true
            fi
        fi
    else
        echo "  [${hostname}] Bare OpenWrt detected (no lime-config), configuring mesh routing directly..."

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
        ssh_vm "$ip" "iw dev wlan0 info >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null | grep -q yes && has_wlan=true || true

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
    fi

    # Unified mesh daemon re-verify (runs for BOTH LibreMesh and bare OpenWrt).
    # The LibreMesh path's inline babeld/bmx7 check above already repaired the
    # daemon if it was missing or running on the wrong interface; this
    # re-verify ensures the daemon has the correct dual-interface mode
    # (wlan0 + br-lan when wlan0 is present, br-lan otherwise) by killing
    # and restarting via start_mesh_daemon_on_vm. For bare OpenWrt this is
    # the primary start path; for LibreMesh it's a safety re-bind.
    if [[ "${mesh_proto}" != "none" ]]; then
        start_mesh_daemon_on_vm "$ip" "${mesh_proto}" || true
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

    # Generate the lab key if needed and keep permissions acceptable for
    # OpenSSH. Phase -1 may also call this before the normal injection phase.
    ensure_ssh_key

    # Extract the base64-encoded key material for the
    # pre-bake check. We use this instead of grepping the full pubkey line so
    # we don't have to interpolate untrusted key contents into a shell command
    # (a crafted key with shell metacharacters in the comment could break out
    # of the single-quoted grep pattern and execute arbitrary commands).
    local key_material
    key_material=$(awk '{print $2}' "${SSH_KEY}.pub")

    local idx=0
    for ip in "${NODE_IPS[@]}"; do
        local hostname="${NODE_HOSTNAMES[$idx]}"

        # Check if key is already present (pre-baked by prepare-source-image.sh).
        # The key material is base64 and has no shell metacharacters, so it is
        # safe to embed as a fixed grep pattern.
        if ssh_vm "$ip" "grep -qF '${key_material}' /root/.ssh/authorized_keys 2>/dev/null" &>/dev/null; then
            echo "  [${hostname}] SSH key already present (pre-baked)."
            # Lock down dropbear even when the key is pre-baked — the old
            # code always disabled password auth after key injection, and
            # skipping it here leaves blank-password root login enabled.
            if ssh_vm_with_key "$ip" "echo ok" &>/dev/null; then
                ssh_vm "$ip" "
                    uci set dropbear.@dropbear[0].PasswordAuth='off'
                    uci set dropbear.@dropbear[0].RootPasswordAuth='off'
                    uci commit dropbear
                    service dropbear restart
                " 2>/dev/null || echo "  [${hostname}] WARN: Could not lock dropbear"
                echo "  [${hostname}] Password auth disabled."
            else
                echo "  [${hostname}] WARN: Pre-baked key auth failed; keeping password auth enabled."
            fi
            idx=$((idx + 1))
            continue
        fi

        echo "  [${hostname}] Injecting SSH key..."

        # Inject public key to both locations dropbear checks:
        # /root/.ssh/authorized_keys (standard) and /etc/dropbear/authorized_keys (OpenWrt fallback).
        # The key is sent over the SSH channel as stdin (NOT embedded in the
        # remote command), so crafted key comments or base64 content cannot
        # break out of shell quoting on the VM.
        local injected=false
        local target
        target="$(ssh_target "${ip}")"
        # Try key-based auth first (source-built images with pre-baked keys).
        if [[ -f "${SSH_KEY}" ]]; then
            ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o HostKeyAlgorithms=+ssh-rsa \
                -o BatchMode=yes \
                -o IdentitiesOnly=yes \
                -i "${SSH_KEY}" \
                -o ConnectTimeout="${SSH_BASE_TIMEOUT}" \
                "${target}" \
                "mkdir -p /root/.ssh /etc/dropbear && cat >> /root/.ssh/authorized_keys && cp /root/.ssh/authorized_keys /etc/dropbear/authorized_keys && chmod 600 /root/.ssh/authorized_keys /etc/dropbear/authorized_keys && chmod 700 /root/.ssh" \
                < "${SSH_KEY}.pub" 2>/dev/null && injected=true
        fi
        # Fallback: password auth via sshpass (prebuilt images without keys yet).
        if ! $injected && command -v sshpass >/dev/null 2>&1; then
            sshpass -p "" ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o HostKeyAlgorithms=+ssh-rsa \
                -o PreferredAuthentications=password \
                -o ConnectTimeout="${SSH_BASE_TIMEOUT}" \
                "${target}" \
                "mkdir -p /root/.ssh /etc/dropbear && cat >> /root/.ssh/authorized_keys && cp /root/.ssh/authorized_keys /etc/dropbear/authorized_keys && chmod 600 /root/.ssh/authorized_keys /etc/dropbear/authorized_keys && chmod 700 /root/.ssh" \
                < "${SSH_KEY}.pub" 2>/dev/null && injected=true
        fi
        if ! $injected && command -v sshpass >/dev/null 2>&1; then
            sshpass -p "root" ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o HostKeyAlgorithms=+ssh-rsa \
                -o PreferredAuthentications=password \
                -o ConnectTimeout="${SSH_BASE_TIMEOUT}" \
                "${target}" \
                "mkdir -p /root/.ssh /etc/dropbear && cat >> /root/.ssh/authorized_keys && cp /root/.ssh/authorized_keys /etc/dropbear/authorized_keys && chmod 600 /root/.ssh/authorized_keys /etc/dropbear/authorized_keys && chmod 700 /root/.ssh" \
                < "${SSH_KEY}.pub" 2>/dev/null && injected=true
        fi
        if $injected; then
            :
        else
            echo "  [${hostname}] WARN: Key injection failed"
            idx=$((idx + 1))
            continue
        fi

        # Verify key auth works before disabling password auth
        if ssh_vm_with_key "$ip" "echo ok" &>/dev/null; then
            echo "  [${hostname}] Key auth verified, disabling password auth."
            ssh_vm "$ip" "
                uci set dropbear.@dropbear[0].PasswordAuth='off'
                uci set dropbear.@dropbear[0].RootPasswordAuth='off'
                uci commit dropbear
                service dropbear restart
            " 2>/dev/null || echo "  [${hostname}] WARN: Could not lock dropbear"
            echo "  [${hostname}] Key injected, password auth disabled."
        else
            echo "  [${hostname}] WARN: Key auth verification failed, keeping password auth enabled."
            echo "  [${hostname}] Key injected but password auth still on."
        fi
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
    ensure_ssh_key

    # Phase -1: Reconfigure VM IPs if LibreMesh auto-assigned wrong subnet
    # LibreMesh images auto-configure 10.13.x.x; we need 10.99.0.x
    echo "=== Phase -1: Detecting VM IP configuration ==="
    local need_ip_fix=false
    for ip in "${NODE_IPS[@]}"; do
        if ! ssh_vm "$ip" "echo ok" &>/dev/null; then
            need_ip_fix=true
            break
        fi
    done

    if ${need_ip_fix}; then
        echo "  VMs not reachable at expected IPs, trying IPv6 link-local reconfiguration..."
        local idx=0
        for ip in "${NODE_IPS[@]}"; do
            local hostname="${NODE_HOSTNAMES[$idx]}"
            local mac="${NODE_MACS[$idx]}"
            # Derive IPv6 link-local from MAC using EUI-64
            # Flip bit 6 (0x02) of first octet, insert FF:FE in middle
            # MAC format: XX:XX:XX:XX:XX:XX (positions 0,3,6,9,12,15)
            if [[ ! "${mac}" =~ ^([0-9a-fA-F]{2}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})$ ]]; then
                echo "  [${hostname}] WARN: bad MAC '${mac}', skipping EUI-64 derivation"
                idx=$((idx + 1))
                continue
            fi
            local m1="${BASH_REMATCH[1]}"
            local m2="${BASH_REMATCH[2]}"
            local m3="${BASH_REMATCH[3]}"
            local m4="${BASH_REMATCH[4]}"
            local m5="${BASH_REMATCH[5]}"
            local m6="${BASH_REMATCH[6]}"
            local m1_flipped
            m1_flipped=$(printf '%02x' "$(( 0x${m1} ^ 0x02 ))")
            local eui64="${m1_flipped}${m2}:${m3}ff:fe${m4}:${m5}${m6}"
            local ipv6_ll="fe80::${eui64}"
            echo -n "  [${hostname}] Trying ${ipv6_ll}%${BRIDGE_NAME}... "
            if ssh_vm "${ipv6_ll}%${BRIDGE_NAME}" \
                "uci set network.lan.proto='static' && uci set network.lan.ipaddr='${ip}' && uci set network.lan.netmask='255.255.0.0' && uci set network.lan.gateway='10.99.0.254' && uci commit network && ip addr replace ${ip}/16 dev br-lan" 2>/dev/null; then
                echo "OK (IP set to ${ip})"
            else
                echo "FAILED"
            fi
            idx=$((idx + 1))
        done
        # Brief wait for network to settle
        sleep 2
    else
        echo "  All VMs reachable at expected IPs."
    fi

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

    # Phase 3: Mesh convergence
    echo ""
    echo "=== Phase 3: Mesh convergence ==="
    local mesh_daemon="none"
    # Detect which mesh routing daemon is available
    if ssh_vm "${NODE_IPS[0]}" "which babeld >/dev/null 2>&1" 2>/dev/null; then
        mesh_daemon="babeld"
    elif ssh_vm "${NODE_IPS[0]}" "which bmx7 >/dev/null 2>&1" 2>/dev/null; then
        mesh_daemon="bmx7"
    fi

    if [[ "${mesh_daemon}" != "none" ]]; then
        echo "  ${mesh_daemon} detected — waiting for mesh convergence..."
        local convergence_ok=true
        for ip in "${NODE_IPS[@]}"; do
            local expected_peers=$(( ${#NODE_IPS[@]} - 1 ))
            if [[ "${mesh_daemon}" == "babeld" ]]; then
                # babeld baseline: daemon alive + UDP listener up.
                # count_mesh_neighbors (common.sh) may return higher if the
                # control socket or kernel routes confirm actual peers.
                expected_peers=1
            fi
            local attempt=0
            local max_attempts=24  # 120 seconds at 5s intervals (up from 90s)
            echo -n "  [${ip}] Waiting for ${expected_peers} ${mesh_daemon} peers..."
            while [ $attempt -lt $max_attempts ]; do
                local peer_count
                case "${mesh_daemon}" in
                    bmx7)
                        peer_count=$(ssh_vm "$ip" "bmx7 -c originators 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || echo "0")
                        ;;
                    babeld)
                        # Probe three independent signals and return the max:
                        # 1. babeld control socket (if present) — authoritative
                        # 2. kernel routes installed by babeld (proto babel)
                        # 3. babeld PID + UDP listener up — weak baseline
                        # The strongest signal wins. Mirrors the logic in
                        # tests/qemu/common.sh:count_mesh_neighbors; inlined
                        # here because configure-vms.sh does not source
                        # common.sh (common.sh has test-suite-specific setup
                        # like TAP). Keep the grep fallback as `|| true` so
                        # the listener baseline is not double-counted when
                        # the socket returns 0 neighbours.
                        peer_count=$(ssh_vm "$ip" "
                            pgrep -x babeld >/dev/null 2>&1 || { echo 0; exit 0; }
                            sock=0
                            for s in /var/run/babeld.sock /tmp/babeld.sock /var/run/babel/babeld.sock; do
                                if [ -S \"\${s}\" ]; then
                                    resp=\$(echo dump | nc -U -w 2 \"\${s}\" 2>/dev/null)
                                    if [ -n \"\${resp}\" ]; then
                                        # grep -c returns the count; exit 1 on 0
                                        # matches (which still prints 0). Use
                                        # || true so we don't trigger set -e in
                                        # the remote shell, and the printed 0
                                        # is the actual count.
                                        sock=\$(echo \"\${resp}\" | grep -cE '^(add|change) neighbour ' || true)
                                        sock=\$(echo \"\${sock}\" | head -1)
                                        break
                                    fi
                                fi
                            done
                            routes=\$(ip route show proto babel 2>/dev/null | wc -l)
                            listen=0
                            if (netstat -ulnp 2>/dev/null || ss -ulnp 2>/dev/null) | grep -q babeld; then
                                listen=1
                            fi
                            # Max of the three signals
                            max=\${sock}
                            [ \${routes} -gt \${max} ] && max=\${routes}
                            [ \${listen} -gt \${max} ] && max=\${listen}
                            echo \${max}
                        " 2>/dev/null || echo "0")
                        ;;
                esac
                peer_count=$(echo "$peer_count" | tr -d '[:space:]')
                if [ "${peer_count:-0}" -ge "${expected_peers}" ] 2>/dev/null; then
                    echo " OK (${peer_count} signals)"
                    break
                fi
                if [ $attempt -eq $((max_attempts - 1)) ]; then
                    echo " TIMEOUT (${peer_count:-0}/${expected_peers} signals)"
                    convergence_ok=false
                fi
                sleep 5
                attempt=$((attempt + 1))
            done
        done

        # Definitive cross-node reachability check: ping a peer from node-1.
        # count_mesh_neighbors can report "converged" when the daemon is up
        # but isolated; an actual ping confirms L3 reachability across the
        # shared bridge. NOTE: in a wired-bridge topology with static IPs
        # on br-lan, a successful ping only proves L2/L3 reachability, not
        # babeld neighbour exchange — but it IS the prerequisite for the
        # multi-hop and mesh-protocol test suites to function.
        if ${convergence_ok} && [ ${#NODE_IPS[@]} -ge 2 ]; then
            local src_ip="${NODE_IPS[0]}"
            local dst_ip="${NODE_IPS[1]}"
            echo -n "  Cross-node reachability: ${src_ip} → ${dst_ip}... "
            if ssh_vm "$src_ip" "ping -c 1 -W 5 ${dst_ip}" >/dev/null 2>&1; then
                echo "OK"
            else
                echo "FAILED (mesh signals present but no L3 reachability)"
                convergence_ok=false
            fi
        fi

        if ${convergence_ok}; then
            echo "  Mesh converged — all nodes see each other."
        else
            echo "  WARN: Mesh did not fully converge. Tests may still pass with partial connectivity."
        fi
    else
        echo "  No mesh routing daemon found (bmx7/babeld) — skipping mesh convergence."
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
