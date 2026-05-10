#!/usr/bin/env bash
# inject-keys-serial.sh — Inject SSH keys into running VMs via serial console
#
# This script connects to the QEMU serial console sockets and injects
# SSH keys into the running VMs without needing to restart them.
#
# Usage: sudo bash scripts/qemu/inject-keys-serial.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH_KEY_DIR="${REPO_ROOT}/run/ssh-keys"
SSH_KEY="${SSH_KEY_DIR}/id_rsa"
SERIAL_BASE="/tmp/node"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)"
    exit 1
fi

if [ ! -f "${SSH_KEY}.pub" ]; then
    echo "ERROR: SSH public key not found at ${SSH_KEY}.pub"
    exit 1
fi

PUBLIC_KEY=$(cat "${SSH_KEY}.pub")

# Send a command to a VM via serial console and wait for response
send_serial() {
    local sock="$1"
    local cmd="$2"
    local wait="${3:-2}"

    {
        echo ""
        sleep 0.5
        echo "${cmd}"
        sleep "${wait}"
    } | socat - UNIX-CONNECT:"${sock}" 2>/dev/null || \
    {
        echo ""
        sleep 0.5
        echo "${cmd}"
        sleep "${wait}"
    } | nc -U "${sock}" 2>/dev/null
}

for node_id in 1 2 3 4; do
    sock="${SERIAL_BASE}-${node_id}-serial.sock"
    if [ ! -S "${sock}" ]; then
        echo "  [Node ${node_id}] Serial socket not found: ${sock}"
        continue
    fi

    echo "  [Node ${node_id}] Injecting SSH key via serial console..."

    # Wait for login prompt and log in
    send_serial "${sock}" "root" 2 >/dev/null

    # Create .ssh directory and inject key
    send_serial "${sock}" "mkdir -p /root/.ssh && chmod 700 /root/.ssh" 1 >/dev/null
    send_serial "${sock}" "echo '${PUBLIC_KEY}' > /root/.ssh/authorized_keys" 1 >/dev/null
    send_serial "${sock}" "chmod 600 /root/.ssh/authorized_keys" 1 >/dev/null

    # Also inject into dropbear authorized_keys
    send_serial "${sock}" "echo '${PUBLIC_KEY}' > /etc/dropbear/authorized_keys" 1 >/dev/null
    send_serial "${sock}" "chmod 600 /etc/dropbear/authorized_keys" 1 >/dev/null

    # Clear root password
    send_serial "${sock}" "sed -i 's/^root:[^:]*:/root::/' /etc/shadow" 1 >/dev/null

    # Ensure dropbear allows root login with password
    send_serial "${sock}" "uci set dropbear.@dropbear[0].RootLogin='1'" 1 >/dev/null
    send_serial "${sock}" "uci set dropbear.@dropbear[0].PasswordAuth='on'" 1 >/dev/null
    send_serial "${sock}" "uci commit dropbear" 1 >/dev/null
    send_serial "${sock}" "/etc/init.d/dropbear restart" 2 >/dev/null

    # Log out
    send_serial "${sock}" "exit" 1 >/dev/null

    echo "  [Node ${node_id}] Done."
done

echo ""
echo "SSH key injection complete. Testing key auth..."

# Test key auth
for ip in 10.99.0.11 10.99.0.12 10.99.0.13 10.99.0.14; do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa \
        -o BatchMode=yes -i "${SSH_KEY}" \
        -o ConnectTimeout=3 "root@${ip}" "hostname" 2>/dev/null; then
        echo "  ${ip}: OK"
    else
        echo "  ${ip}: FAILED"
    fi
done
