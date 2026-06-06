#!/usr/bin/env bash
# configure-source-image.sh — Configure source-built OpenWrt image for testbed
#
# Mounts the rootfs partition of a source-built OpenWrt image and configures:
#   - Network: DHCP on br-lan (so dnsmasq on the bridge can assign IPs)
#   - SSH: injects authorized_keys for root login
#   - Drops root password
#
# Usage:
#   ./configure-source-image.sh [OPTIONS]
#
# Options:
#   -h, --help          — Show this help text
#   --image <path>      — Source-built image path (default: auto-detect)
#   --ssh-key <path>    — SSH public key (default: run/ssh-keys/id_ed25519.pub)
#
# This script is the source-built equivalent of convert-prebuilt.sh.
# It must be run once after building the image with build-libremesh-image.sh.

set -euo pipefail

# ─── Help ───────────────────────────────────────────────────────────────────────
show_help() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

IMAGE_PATH=""
SSH_KEY_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help ;;
        --image)
            [[ $# -ge 2 ]] || { echo "[ERROR] --image requires a value" >&2; exit 1; }
            IMAGE_PATH="$2"
            shift 2
            ;;
        --ssh-key)
            [[ $# -ge 2 ]] || { echo "[ERROR] --ssh-key requires a value" >&2; exit 1; }
            SSH_KEY_PATH="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "[ERROR] Unknown option: $1" >&2
            exit 1
            ;;
        *)
            echo "[ERROR] Unexpected positional argument: $1" >&2
            exit 1
            ;;
    esac
done

# ─── Configuration ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="${SCRIPT_DIR}"
    while [[ "${REPO_ROOT}" != "/" ]]; do
        if [[ -f "${REPO_ROOT}/.git" || -d "${REPO_ROOT}/.git" ]]; then
            break
        fi
        REPO_ROOT="$(dirname "${REPO_ROOT}")"
    done
fi

IMAGE_DIR="${REPO_ROOT}/images"
IMAGE_PATH="${IMAGE_PATH:-${IMAGE_DIR}/libremesh-x86-64-source-built.img}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${REPO_ROOT}/run/ssh-keys/id_ed25519.pub}"

# ─── Helpers ────────────────────────────────────────────────────────────────────
log() { echo "[configure-source] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

# ─── Preflight ──────────────────────────────────────────────────────────────────
[[ -f "${IMAGE_PATH}" ]] || die "Image not found: ${IMAGE_PATH}"
command -v fdisk >/dev/null || die "fdisk is required (install fdisk)"

# ─── Cleanup trap ───────────────────────────────────────────────────────────────
MOUNT_POINT=""

cleanup() {
    if [[ -n "${MOUNT_POINT}" ]] && mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        log "Unmounting ${MOUNT_POINT}..."
        sudo umount "${MOUNT_POINT}" || true
    fi
    if [[ -n "${MOUNT_POINT}" ]] && [[ -d "${MOUNT_POINT}" ]]; then
        rmdir "${MOUNT_POINT}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─── Find rootfs partition offset ───────────────────────────────────────────────
log "Analyzing image format of ${IMAGE_PATH}..."

IS_FLAT=false
if file -L "${IMAGE_PATH}" | grep -q "DOS/MBR boot sector"; then
    PART2_START=$(fdisk -l "${IMAGE_PATH}" 2>/dev/null \
        | awk -f "${SCRIPT_DIR}/parse-fdisk-partition.awk" \
        | tail -1)

    if [[ -z "${PART2_START}" ]]; then
        die "Could not find partition 2 (rootfs) in ${IMAGE_PATH}. Is this a source-built combined image?"
    fi

    SECTOR_SIZE=512
    ROOTFS_OFFSET=$((PART2_START * SECTOR_SIZE))
    log "Combined image: rootfs partition at sector ${PART2_START} (offset ${ROOTFS_OFFSET} bytes)"
else
    IS_FLAT=true
    ROOTFS_OFFSET=0
    log "Flat image: mounting directly (no partition table)"
fi

# ─── Mount rootfs ───────────────────────────────────────────────────────────────
MOUNT_POINT="$(mktemp -d /tmp/source-rootfs.XXXXXX)"
log "Mounting rootfs at ${MOUNT_POINT}..."
if [[ "${IS_FLAT}" = "true" ]]; then
    sudo mount -o loop "${IMAGE_PATH}" "${MOUNT_POINT}"
else
    sudo mount -o loop,offset="${ROOTFS_OFFSET}" "${IMAGE_PATH}" "${MOUNT_POINT}"
fi

# ─── Configure network ─────────────────────────────────────────────────────────
log "Configuring network (DHCP on br-lan)..."

sudo tee "${MOUNT_POINT}/etc/board.d/99-default_network" > /dev/null << 'BOARDSCRIPT'
. /lib/functions/uci-defaults.sh

board_config_update

json_is_a network object && exit 0

ucidef_set_interface 'lan' device 'eth0' protocol 'dhcp'
[ -d /sys/class/net/eth1 ] && ucidef_set_interface 'wan' device 'eth1' protocol 'dhcp'

board_config_flush

exit 0
BOARDSCRIPT
sudo chmod +x "${MOUNT_POINT}/etc/board.d/99-default_network"

sudo rm -f "${MOUNT_POINT}/etc/config/network"
sudo rm -f "${MOUNT_POINT}/etc/uci-defaults/11_network-migrate-bridges" 2>/dev/null || true

log "  Network: DHCP on br-lan (eth0)"

# ─── Inject S99testbed init script (procd-compatible) ──────────────────────────
# CRITICAL: procd (PID 1) does NOT use /etc/init.d/rcS from inittab. Instead,
# procd has a built-in rcS handler that directly scans /etc/rc.d/S* and executes
# each script. Each S* script uses "#!/bin/sh /etc/rc.common" as its shebang,
# and since rc.common is missing from this LibreMesh prebuilt image, ALL init.d
# scripts fail silently — including S95done (which normally calls rc.local).
#
# Solution: create a plain #!/bin/sh init script (no rc.common dependency) that
# procd will execute during boot. This script calls /etc/rc.local which handles
# all testbed setup: network rewrite, netifd, babeld, dropbear.
log "  Creating S99testbed init script (procd-compatible, no rc.common dependency)..."
sudo mkdir -p "${MOUNT_POINT}/etc/init.d" "${MOUNT_POINT}/etc/rc.d"
sudo tee "${MOUNT_POINT}/etc/init.d/testbed" > /dev/null << 'TESTBEDEOF'
#!/bin/sh
# /etc/init.d/testbed — Mesha testbed setup (no rc.common dependency)
# Called by procd as S99testbed during boot. Procd's built-in rcS handler
# executes each /etc/rc.d/S* script directly. This script uses plain #!/bin/sh
# (not #!/bin/sh /etc/rc.common) so it works even when rc.common is missing.
/etc/rc.local >>/etc/rc.local.boot.log 2>&1
TESTBEDEOF
sudo chmod +x "${MOUNT_POINT}/etc/init.d/testbed"
sudo ln -sf "../init.d/testbed" "${MOUNT_POINT}/etc/rc.d/S99testbed"
log "  S99testbed init script created"

# ─── Configure SSH ─────────────────────────────────────────────────────────────
if [[ -f "${SSH_KEY_PATH}" ]]; then
    log "Injecting SSH public key..."
    sudo mkdir -p "${MOUNT_POINT}/root/.ssh"
    sudo tee "${MOUNT_POINT}/root/.ssh/authorized_keys" > /dev/null < "${SSH_KEY_PATH}"
    sudo chmod 700 "${MOUNT_POINT}/root/.ssh"
    sudo chmod 600 "${MOUNT_POINT}/root/.ssh/authorized_keys"
    log "  SSH key: $(sudo head -1 "${MOUNT_POINT}/root/.ssh/authorized_keys" | cut -c1-40)..."
else
    log "  WARNING: SSH key not found at ${SSH_KEY_PATH}, skipping"
fi

# ─── Clear root password ───────────────────────────────────────────────────────
log "Clearing root password..."
sudo sed -i 's|^root:.*|root::0:0:99999:7:::|' "${MOUNT_POINT}/etc/shadow"

# ─── Ensure dropbear allows root login with blank password ──────────────────────
if [[ -f "${MOUNT_POINT}/etc/config/dropbear" ]]; then
    log "  Configuring dropbear for blank password login..."
    if ! sudo grep -q "BlankPasswordAuth" "${MOUNT_POINT}/etc/config/dropbear"; then
        echo "	option BlankPasswordAuth '1'" | sudo tee -a "${MOUNT_POINT}/etc/config/dropbear" > /dev/null
    fi

    DROPBEAR_INIT="${MOUNT_POINT}/etc/init.d/dropbear"
    if [[ -f "${DROPBEAR_INIT}" ]] && ! sudo grep -q "BlankPasswordAuth.*-B" "${DROPBEAR_INIT}"; then
        sudo sed -i '/RootPasswordAuth.*-g/a\\t[ "${BlankPasswordAuth}" -eq 1 ] \&\& procd_append_param command -B' "${DROPBEAR_INIT}"
        sudo sed -i "/RootLogin:bool:1/a\\t\t'BlankPasswordAuth:bool:0' \\\\" "${DROPBEAR_INIT}"
        log "  Patched dropbear init script with -B (blank password) support"
    fi
fi

# ─── Pre-create babeld UCI config (defense in depth) ───────────────────────────
BABELD_CONFIG="${MOUNT_POINT}/etc/config/babeld"
if [[ ! -f "${BABELD_CONFIG}" ]] || ! sudo grep -q "br-lan" "${BABELD_CONFIG}"; then
    log "  Pre-creating /etc/config/babeld with br-lan interface..."
    sudo tee "${BABELD_CONFIG}" > /dev/null << 'BABELDEOF'
config general

config interface
	option 'ifname' 'br-lan'
BABELDEOF
    if [[ -f "${MOUNT_POINT}/etc/init.d/babeld" ]]; then
        sudo mkdir -p "${MOUNT_POINT}/etc/rc.d"
        if ! ls "${MOUNT_POINT}/etc/rc.d"/S*babeld >/dev/null 2>&1; then
            sudo ln -sf "../init.d/babeld" "${MOUNT_POINT}/etc/rc.d/S60babeld"
        fi
    fi
fi

# ─── Override LibreMesh networking via rc.local ────────────────────────────────
# LibreMesh's lime-config regenerates /etc/config/network at first boot with
# VLAN-tagged batman-adv interfaces that don't work with the QEMU testbed bridge.
# Strategy: let LibreMesh boot normally (preserving lime-services like
# thisnode.info and shared-state), then use rc.local (called by S99testbed)
# to rewrite the network config to plain DHCP on br-lan and restart netifd + babeld.
#
# rc.local uses direct binary calls (netifd, dropbear, babeld) instead of
# init.d scripts because /etc/rc.common is missing from this image.
log "  Injecting rc.local testbed override..."

# Re-enable all uci-defaults (undo any previous disabling) so lime-config runs.
for f in "${MOUNT_POINT}/etc/uci-defaults/"*; do
    [[ -f "$f" ]] || continue
    sudo chmod +x "$f" 2>/dev/null || true
done
if [[ -f "${MOUNT_POINT}/etc/uci-defaults/91_lime-config.disabled" ]]; then
    sudo mv "${MOUNT_POINT}/etc/uci-defaults/91_lime-config.disabled" \
             "${MOUNT_POINT}/etc/uci-defaults/91_lime-config" 2>/dev/null || true
fi
log "  Re-enabled all LibreMesh uci-defaults"

# Write rc.local. Called by S99testbed during boot (last S* script procd runs).
# Uses direct binary calls (netifd, dropbear, babeld) instead of init scripts
# because /etc/rc.common is missing from this LibreMesh prebuilt image.
# Idempotent via the marker file — retries on next boot if anything fails.
sudo tee "${MOUNT_POINT}/etc/rc.local" > /dev/null << 'RCLOCALEOF'
#!/bin/sh
# /etc/rc.local — LibreMesh Lab testbed override
# Called by S99testbed during boot (last S* script procd runs).
# Overrides lime-config's network (VLAN-tagged batman-adv) with a plain
# DHCP-on-br-lan setup that works on the QEMU testbed bridge.
# Idempotent via the marker file — retries on next boot if anything fails.

LOG="/etc/rc.local.boot.log"
_echo() { echo "$(date '+%H:%M:%S') $*" >> "${LOG}"; }

_echo "=== rc.local starting ==="

MARKER="/etc/.mesha-testbed-configured"
if [ -f "${MARKER}" ]; then
    _echo "Marker exists, exiting."
    exit 0
fi

_echo "Waiting 5s for procd to settle..."
sleep 5

# Stop any mesh daemons that lime-config may have started on the wrong
# interface. They will be restarted on br-lan below.
killall babeld bmx7 batmand 2>/dev/null || true
sleep 1

# Stop netifd so it doesn't hold a lock on /etc/config/network while we
# rewrite it. Kill the process directly — /etc/init.d/network stop may
# fail if /etc/rc.common is missing from the overlay.
killall netifd 2>/dev/null || true
sleep 1

# Atomically replace /etc/config/network with a known-good testbed config.
cp -f /etc/config/network /etc/config/network.lime-config.bak 2>/dev/null || true
cat > /etc/config/.network.new << 'NETEOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix 'fd00:dead:beef::/48'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option device 'br-lan'
	option proto 'dhcp'
	option metric '100'
NETEOF
mv -f /etc/config/.network.new /etc/config/network
_echo "Network config rewritten."

# Replace /etc/config/babeld so the init script can manage babeld on
# subsequent boots (lime-config may have pointed it at a VLAN interface).
cat > /etc/config/.babeld.new << 'BABELDEOF'
config general

config interface
	option ifname 'br-lan'
BABELDEOF
mv -f /etc/config/.babeld.new /etc/config/babeld

# Start netifd directly. It reads /etc/config/network and creates br-lan
# with eth0 as a bridge port, then starts udhcpc for DHCP.
# We do NOT use /etc/init.d/network start because /etc/rc.common is missing
# from this LibreMesh prebuilt image, causing all init.d scripts to fail.
_echo "Starting netifd..."
netifd >>"${LOG}" 2>&1 &

# Wait up to 30s for br-lan to be UP and RUNNING.
BRLAN_UP=0
WAIT_BR=0
while [ ${WAIT_BR} -lt 30 ]; do
    if [ -d /sys/class/net/br-lan ] && \
       ip link show br-lan 2>/dev/null | grep -q 'state UP'; then
        BRLAN_UP=1
        _echo "br-lan UP after ${WAIT_BR}s."
        break
    fi
    sleep 1
    WAIT_BR=$((WAIT_BR + 1))
done
[ ${BRLAN_UP} -eq 0 ] && _echo "WARNING: br-lan not UP after 30s."

# Start babeld on br-lan directly (not via init script — rc.common is missing).
# Prefer babeld, fall back to bmx7.
MESH_UP=0
if [ ${BRLAN_UP} -eq 1 ] && ([ -x /usr/sbin/babeld ] || which babeld >/dev/null 2>&1); then
    killall babeld 2>/dev/null || true
    babeld -D -I /var/run/babeld.pid br-lan >>"${LOG}" 2>&1
    sleep 2
    if pgrep -x babeld >/dev/null 2>&1 && \
       (netstat -ulnp 2>/dev/null || ss -ulnp 2>/dev/null) | grep -q babeld; then
        MESH_UP=1
        _echo "babeld running on br-lan."
    fi
fi
if [ ${MESH_UP} -eq 0 ] && [ ${BRLAN_UP} -eq 1 ] && ([ -x /usr/sbin/bmx7 ] || which bmx7 >/dev/null 2>&1); then
    killall bmx7 2>/dev/null || true
    bmx7 dev=br-lan >>"${LOG}" 2>&1 &
    sleep 2
    if pgrep -x bmx7 >/dev/null 2>&1; then
        MESH_UP=1
        _echo "bmx7 running on br-lan."
    fi
fi
[ ${MESH_UP} -eq 0 ] && _echo "WARNING: no mesh daemon running."

# Ensure dropbear is running. Start directly (not via init script) since
# rc.common is missing. The -R flag generates host keys on first run,
# -B allows blank password login.
dropbear -R -B 2>/dev/null || true
_echo "dropbear started."

# Only mark as configured when br-lan is UP AND the mesh daemon is verified
# listening. A failed first boot leaves the marker unset so the next boot
# retries the full reconfiguration.
if [ ${BRLAN_UP} -eq 1 ] && [ ${MESH_UP} -eq 1 ]; then
    touch "${MARKER}"
    _echo "SUCCESS: marker set."
else
    _echo "FAILED: br-lan=${BRLAN_UP} mesh=${MESH_UP}. Marker NOT set."
fi

_echo "=== rc.local done ==="
exit 0
RCLOCALEOF
sudo chmod +x "${MOUNT_POINT}/etc/rc.local"
log "  rc.local: atomic network rewrite + direct netifd/babeld/dropbear (idempotent, retryable)"

# ─── Ensure /sbin/service shim is present (needed by mesha adapters) ──────────
SERVICE_SHIM="${MOUNT_POINT}/sbin/service"
if ! sudo grep -q 'service shim for OpenWrt' "${SERVICE_SHIM}" 2>/dev/null; then
    sudo mkdir -p "${MOUNT_POINT}/sbin"
    sudo tee "${SERVICE_SHIM}" >/dev/null <<'SERVICEEOF'
#!/bin/sh
# /sbin/service shim for OpenWrt — maps `service <name> <action>` to
# `/etc/init.d/<name> <action>`. Used by mesha adapters and similar tools.
if [ $# -lt 2 ]; then
    echo "Usage: service <name> <action> [args...]" >&2
    exit 64
fi
NAME="$1"
shift
INITD="/etc/init.d/${NAME}"
if [ ! -x "${INITD}" ]; then
    echo "service: ${NAME} not found (no ${INITD})" >&2
    exit 5
fi
exec "${INITD}" "$@"
SERVICEEOF
    sudo chmod +x "${SERVICE_SHIM}"
    log "  /sbin/service shim created"
fi

# ─── Done ───────────────────────────────────────────────────────────────────────
sync
sudo umount "${MOUNT_POINT}"
MOUNT_POINT=""  # prevent double-unmount in trap

log ""
log "Source-built image configured successfully."
log "  Image: ${IMAGE_PATH}"
log ""
log "To boot:"
log "  sudo bash scripts/qemu/start-mesh.sh"
log ""
log "The VMs will get IPs via DHCP from dnsmasq on the bridge."
log "Then run: bash scripts/qemu/configure-vms.sh"
