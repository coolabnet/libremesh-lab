#!/usr/bin/env bash
# configure-source-vms.sh — Configure source-built VMs via serial console
# Sets static IPs, injects SSH keys, and starts bmx7 on each node
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SSH_KEY_FILE="${REPO_ROOT}/run/ssh-keys/id_rsa.pub"
NODE_IPS=("10.99.0.11" "10.99.0.12" "10.99.0.13" "10.99.0.14")
NODE_HOSTNAMES=("lm-testbed-node-1" "lm-testbed-node-2" "lm-testbed-node-3" "lm-testbed-node-4")
TIMEOUT="${CONFIGURE_TIMEOUT:-30}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}OK${NC} $*"; }
fail() { echo -e "  ${RED}FAIL${NC} $*" >&2; }
info() { echo -e "  ${YELLOW}...${NC} $*"; }

# Send a command via serial socket. Handles the login sequence automatically.
# Usage: send_serial_cmd NODE_ID "command" [WAIT_SECONDS]
send_serial_cmd() {
    local node_id="$1"
    local cmd="$2"
    local wait="${3:-2}"
    local sock="/tmp/node-${node_id}-serial.sock"

    if [[ ! -S "${sock}" ]]; then
        fail "Serial socket not found: ${sock}"
        return 1
    fi

    sudo python3 -c "
import socket, time, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('${sock}')
s.settimeout(5)
# Flush pending output
try: s.recv(65536)
except: pass
# Send command + newline
s.send(('${cmd}' + '\n').encode())
time.sleep(${wait})
try:
    data = s.recv(65536)
    sys.stdout.write(data.decode('utf-8', errors='replace'))
except: pass
s.close()
" 2>/dev/null
}

# Log into the serial console of a node.
# OpenWrt shows "Please press Enter to activate this console"
# then a login prompt. We press Enter, type "root", press Enter.
login_serial() {
    local node_id="$1"
    local sock="/tmp/node-${node_id}-serial.sock"

    if [[ ! -S "${sock}" ]]; then
        return 1
    fi

    sudo SERIAL_SOCK="${sock}" python3 << 'PYEOF'
import socket, time, sys, os

sock_path = os.environ.get('SERIAL_SOCK', '')
if not sock_path:
    print("LOGIN_FAIL")
    sys.exit(1)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.settimeout(3)

# Flush any pending output
try: s.recv(65536)
except: pass

# Press Enter to activate the console
s.send(b'\n')
time.sleep(1)
try: s.recv(65536)
except: pass

# Send "root" to log in (OpenWrt has no password by default)
s.send(b'root\n')
time.sleep(2)
try:
    data = s.recv(65536)
    output = data.decode('utf-8', errors='replace')
    # Check if we got a shell prompt
    if '#' in output or '$' in output or 'root@' in output:
        print("LOGIN_OK")
    else:
        # Maybe already logged in, try sending Enter
        s.send(b'\n')
        time.sleep(1)
        try:
            data2 = s.recv(65536)
            output2 = data2.decode('utf-8', errors='replace')
            if '#' in output2 or '$' in output2 or 'root@' in output2:
                print("LOGIN_OK")
            else:
                print("LOGIN_MAYBE")
        except:
            print("LOGIN_MAYBE")
except:
    # No data yet, try one more time
    s.send(b'\n')
    time.sleep(1)
    try:
        data = s.recv(65536)
        print("LOGIN_MAYBE")
    except:
        print("LOGIN_FAIL")

s.close()
PYEOF
}

configure_node() {
    local node_id="$1"
    local ip="${NODE_IPS[$((node_id-1))]}"
    local hostname="${NODE_HOSTNAMES[$((node_id-1))]}"

    echo ""
    echo "=== Configuring node-${node_id} (${hostname} / ${ip}) ==="

    # 1. Wait for boot and log in via serial
    info "Waiting for boot and logging in..."
    local boot_ok=false
    for i in $(seq 1 ${TIMEOUT}); do
        if [[ -S "/tmp/node-${node_id}-serial.sock" ]]; then
            result=$(login_serial "${node_id}" 2>/dev/null || true)
            if echo "${result}" | grep -q "LOGIN_OK\|LOGIN_MAYBE"; then
                boot_ok=true
                break
            fi
        fi
        sleep 2
    done
    if ! ${boot_ok}; then
        fail "Node ${node_id} did not boot within $((TIMEOUT * 2))s"
        return 1
    fi
    pass "Booted and logged in"

    # 2. Set static IP
    info "Setting static IP ${ip}..."
    send_serial_cmd "${node_id}" "uci set network.lan.proto='static'" 1 >/dev/null
    send_serial_cmd "${node_id}" "uci set network.lan.ipaddr='${ip}'" 1 >/dev/null
    send_serial_cmd "${node_id}" "uci set network.lan.netmask='255.255.0.0'" 1 >/dev/null
    send_serial_cmd "${node_id}" "uci set network.lan.gateway='10.99.0.254'" 1 >/dev/null
    send_serial_cmd "${node_id}" "uci delete network.lan.hostname 2>/dev/null; true" 1 >/dev/null
    send_serial_cmd "${node_id}" "uci commit network" 1 >/dev/null
    send_serial_cmd "${node_id}" "/etc/init.d/network restart" 5 >/dev/null
    pass "Static IP set"

    # 3. Set hostname
    info "Setting hostname ${hostname}..."
    send_serial_cmd "${node_id}" "uci set system.@system[0].hostname='${hostname}'" 1 >/dev/null
    send_serial_cmd "${node_id}" "uci commit system" 1 >/dev/null
    send_serial_cmd "${node_id}" "hostname '${hostname}'" 1 >/dev/null
    pass "Hostname set"

    # 4. Inject SSH key
    info "Injecting SSH key..."
    local pubkey
    pubkey=$(cat "${SSH_KEY_FILE}" 2>/dev/null || true)
    if [[ -z "${pubkey}" ]]; then
        fail "SSH public key not found: ${SSH_KEY_FILE}"
        return 1
    fi
    send_serial_cmd "${node_id}" "mkdir -p /root/.ssh && chmod 700 /root/.ssh" 1 >/dev/null
    send_serial_cmd "${node_id}" "echo '${pubkey}' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" 1 >/dev/null
    # Also add to /etc/dropbear for good measure
    send_serial_cmd "${node_id}" "echo '${pubkey}' > /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys" 1 >/dev/null
    pass "SSH key injected"

    # 5. Load mac80211_hwsim module
    info "Loading mac80211_hwsim..."
    send_serial_cmd "${node_id}" "modprobe mac80211_hwsim 2>/dev/null; true" 2 >/dev/null
    pass "mac80211_hwsim loaded"

    # 6. Start bmx7
    info "Starting bmx7..."
    send_serial_cmd "${node_id}" "bmx7 -d --nodeTtlBuffer 10000 2>/dev/null &" 2 >/dev/null
    pass "bmx7 started"

    # 7. Wait for SSH to be reachable
    info "Waiting for SSH at ${ip}..."
    local ssh_ok=false
    for i in $(seq 1 15); do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
            -o ConnectTimeout=2 -o BatchMode=yes \
            root@${ip} "true" 2>/dev/null; then
            ssh_ok=true
            break
        fi
        sleep 2
    done
    if ${ssh_ok}; then
        pass "SSH accessible at ${ip}"
    else
        fail "SSH not reachable at ${ip}"
        return 1
    fi

    return 0
}

# ─── Main ───
echo "=========================================="
echo " Configure Source-Built VMs"
echo "=========================================="

configured=0
failed=0
for node_id in 1 2 3 4; do
    if configure_node "${node_id}"; then
        configured=$((configured + 1))
    else
        failed=$((failed + 1))
    fi
done

echo ""
echo "=========================================="
echo " Configured: ${configured}/4"
echo " Failed:     ${failed}"
echo "=========================================="

if [[ ${failed} -gt 0 ]]; then
    exit 1
fi

# Generate SSH config
info "Generating SSH config..."
SSH_CONFIG="${REPO_ROOT}/config/ssh-config.resolved"
cat > "${SSH_CONFIG}" << 'HEADER'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
    IdentityFile IDENTITY_FILE_PLACEHOLDER
    LogLevel ERROR
HEADER

for i in 0 1 2 3; do
    cat >> "${SSH_CONFIG}" << EOF

Host ${NODE_HOSTNAMES[$i]}
    HostName ${NODE_IPS[$i]}
    User root
EOF
done

sed -i "s|IDENTITY_FILE_PLACEHOLDER|${REPO_ROOT}/run/ssh-keys/id_rsa|" "${SSH_CONFIG}"
pass "SSH config written to ${SSH_CONFIG}"

echo ""
echo "Done! All VMs configured."
exit 0
