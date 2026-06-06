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

# IMPORTANT: this must be a while loop with explicit shifts. The previous
# `for arg in "$@"; shift; ...` pattern was broken: `for` iterates over the
# original argument list (so `shift` inside the loop body had no effect on
# the next iteration), and `--image foo` was parsed as two separate cases,
# with `foo` falling through silently.
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

# Auto-detect REPO_ROOT
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
# Source-built images can be:
#   1. Combined image (MBR with partition 1 = boot, partition 2 = rootfs)
#   2. Flat image (raw ext4, no partition table — like the prebuilt image)

log "Analyzing image format of ${IMAGE_PATH}..."

IS_FLAT=false
if file -L "${IMAGE_PATH}" | grep -q "DOS/MBR boot sector"; then
    # Combined image with partition table
    # fdisk output varies: /dev/loop0p2 when using loop devices,
    # or images/file.img2 when run on a plain file. The '2' at the end of
    # the device field must be partition 2, not a higher-numbered partition
    # like loop0p12 — anchor with non-digit prefix.
    #
    # util-linux fdisk column layout has changed across versions:
    #   Old (pre-2.38): Boot StartCHS EndCHS StartLBA EndLBA ...
    #   New (≥2.38):    Boot StartLBA EndLBA Sectors Size Id Type
    # In both layouts, the first purely-numeric field after the device
    # is the partition's start sector (LBA). Old fdisk's StartCHS is
    # comma-separated (e.g. "0,32,33") and is therefore skipped; its
    # StartLBA (the next field) is what we want. New fdisk puts the start
    # LBA in $3 directly. This logic is exercised by
    # tests/qemu/test-qemu-script-units.sh against both formats.
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
    # Flat image — no partition table, mount directly
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

# Replace board.d/99-default_network to use DHCP instead of static 192.168.1.1
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

# Remove any existing network config so board.d regenerates it on first boot
sudo rm -f "${MOUNT_POINT}/etc/config/network"

# Also remove uci-defaults that might interfere
sudo rm -f "${MOUNT_POINT}/etc/uci-defaults/11_network-migrate-bridges" 2>/dev/null || true

log "  Network: DHCP on br-lan (eth0)"

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
    # Add BlankPasswordAuth option to dropbear config
    if ! sudo grep -q "BlankPasswordAuth" "${MOUNT_POINT}/etc/config/dropbear"; then
        echo "	option BlankPasswordAuth '1'" | sudo tee -a "${MOUNT_POINT}/etc/config/dropbear" > /dev/null
    fi

    # Patch dropbear init script to support -B flag (Allow blank passwords)
    DROPBEAR_INIT="${MOUNT_POINT}/etc/init.d/dropbear"
    if [[ -f "${DROPBEAR_INIT}" ]] && ! sudo grep -q "BlankPasswordAuth.*-B" "${DROPBEAR_INIT}"; then
        # Add -B flag handling after RootPasswordAuth handling
        sudo sed -i '/RootPasswordAuth.*-g/a\\t[ "${BlankPasswordAuth}" -eq 1 ] \&\& procd_append_param command -B' "${DROPBEAR_INIT}"
        # Add BlankPasswordAuth to the validate function
        sudo sed -i "/RootLogin:bool:1/a\\t\t'BlankPasswordAuth:bool:0' \\\\" "${DROPBEAR_INIT}"
        log "  Patched dropbear init script with -B (blank password) support"
    fi
fi

# ─── Pre-create babeld UCI config (defense in depth) ───────────────────────────
# lime-config may set up babeld to run on VLAN interfaces that don't exist in
# the QEMU testbed. Pre-create a minimal babeld config that runs on br-lan so
# that even if rc.local fails, babeld has a valid autostart configuration.
# OpenWrt babeld's documented UCI shape:
#   config general    — global settings (no enabled flag; babeld is enabled
#                       by the /etc/init.d/babeld init script, controlled
#                       via /etc/rc.d/S*babeld symlink)
#   config interface  — one per interface babeld should run on
BABELD_CONFIG="${MOUNT_POINT}/etc/config/babeld"
if [[ ! -f "${BABELD_CONFIG}" ]] || ! sudo grep -q "br-lan" "${BABELD_CONFIG}"; then
    log "  Pre-creating /etc/config/babeld with br-lan interface..."
    sudo tee "${BABELD_CONFIG}" > /dev/null << 'BABELDEOF'
config general

config interface
	option 'ifname' 'br-lan'
BABELDEOF
    # Enable babeld init script (rc.d symlink) so it auto-starts on subsequent boots
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
# thisnode.info and shared-state), then use rc.local (runs after all init
# scripts and uci-defaults) to rewrite the network config to plain DHCP on
# br-lan and restart netifd + babeld. This is the same wired-bridge approach
# the bare-OpenWrt path uses in configure-vms.sh.
log "  Injecting rc.local testbed override..."

# Re-enable all uci-defaults (undo any previous disabling) so lime-config runs.
for f in "${MOUNT_POINT}/etc/uci-defaults/"*; do
    [[ -f "$f" ]] || continue
    sudo chmod +x "$f" 2>/dev/null || true
done
# Restore lime-config if it was renamed/disabled
if [[ -f "${MOUNT_POINT}/etc/uci-defaults/91_lime-config.disabled" ]]; then
    sudo mv "${MOUNT_POINT}/etc/uci-defaults/91_lime-config.disabled" \
             "${MOUNT_POINT}/etc/uci-defaults/91_lime-config" 2>/dev/null || true
fi
log "  Re-enabled all LibreMesh uci-defaults"

# Write rc.local. This runs LAST, after all init scripts and uci-defaults.
# Uses UCI/netifd (not raw ip/udhcpc) so network state stays consistent.
# Atomically replaces /etc/config/network (instead of section-by-section
# deletion) to avoid leaving dangling references to lime-config VLANs.
# The marker file is only created after the mesh daemon is verified
# listening, so a failed first boot will retry on the next boot.
sudo tee "${MOUNT_POINT}/etc/rc.local" > /dev/null << 'RCLOCALEOF'
#!/bin/sh
# /etc/rc.local — LibreMesh Lab testbed override
# Runs after all init scripts and uci-defaults. Overrides lime-config's
# network (VLAN-tagged batman-adv) with a plain DHCP-on-br-lan setup that
# works on the QEMU testbed bridge. Idempotent via the marker file.

MARKER="/etc/.mesha-testbed-configured"
[ -f "${MARKER}" ] && exit 0

# Wait for uci-defaults (including 91_lime-config) to finish.
# uci-defaults scripts remove themselves after run, so a non-empty
# directory means some are still pending. Timeout: 120s.
WAIT=0
while [ -n "$(ls /etc/uci-defaults/ 2>/dev/null)" ] && [ ${WAIT} -lt 120 ]; do
    sleep 1
    WAIT=$((WAIT + 1))
done

# Stop any mesh daemons that lime-config may have started on the wrong
# interface. They will be restarted on br-lan below.
killall babeld bmx7 batmand 2>/dev/null || true
sleep 1

# Stop netifd so it doesn't hold a lock on /etc/config/network while we
# rewrite it. /etc/init.d/network restart is not enough — netifd caches the
# config in memory and a hot-rewrite can produce an inconsistent state.
/etc/init.d/network stop 2>/dev/null || true
sleep 1

# Atomically replace /etc/config/network with a known-good testbed config.
# This avoids the index-shifting problem of section-by-section deletion
# (anonymous @device[0], @interface[0] reindex while deleting) and
# guarantees no stale VLAN/batman references remain. lime-config's network
# config is preserved as .lime-config.bak in case we need to inspect it.
# Use temp files in /etc/config (same filesystem) + mv for true atomicity;
# /tmp is tmpfs on OpenWrt so a /tmp→/etc/config mv would degrade to
# copy/unlink and break the atomic-replace guarantee.
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

# Replace /etc/config/babeld so the init script can manage babeld on
# subsequent boots (lime-config may have pointed it at a VLAN interface).
cat > /etc/config/.babeld.new << 'BABELDEOF'
config general

config interface
	option ifname 'br-lan'
BABELDEOF
mv -f /etc/config/.babeld.new /etc/config/babeld

# Restart networking. /etc/init.d/network start will pick up the new
# /etc/config/network and bring up br-lan, then DHCP via udhcpc.
# Restart in background and wait for br-lan to actually come up before
# starting the mesh daemon.
(/etc/init.d/network start) >/tmp/network-start.log 2>&1 &

# Wait up to 30s for br-lan to be UP and RUNNING. We require both: the
# interface must exist AND its link state must be UP (not DOWN or UNKNOWN).
# If this times out, the mesh daemon start below is still attempted as a
# best-effort, but the marker gating at the end will refuse to mark the
# boot as configured, so the next boot retries.
BRLAN_UP=0
WAIT_BR=0
while [ ${WAIT_BR} -lt 30 ]; do
    if [ -d /sys/class/net/br-lan ] && \
       ip link show br-lan 2>/dev/null | grep -q 'state UP'; then
        BRLAN_UP=1
        break
    fi
    sleep 1
    WAIT_BR=$((WAIT_BR + 1))
done

# Start babeld on br-lan via its init script (so it inherits the UCI config
# and the pid file is properly managed). Prefer babeld, fall back to bmx7.
# MESH_UP requires BOTH the daemon process AND the UDP listener to be
# present; either alone is not enough to declare the mesh up.
MESH_UP=0
if [ ${BRLAN_UP} -eq 1 ] && ([ -x /etc/init.d/babeld ] || [ -x /usr/sbin/babeld ] || which babeld >/dev/null 2>&1); then
    if [ -x /etc/init.d/babeld ]; then
        /etc/init.d/babeld enable 2>/dev/null
        /etc/init.d/babeld restart >/tmp/babeld-start.log 2>&1 || true
    else
        # Init script missing — start babeld directly (matches the form used
        # by configure-vms.sh:start_mesh_daemon_on_vm).
        killall babeld 2>/dev/null || true
        babeld -D -I /var/run/babeld.pid br-lan >/tmp/babeld-start.log 2>&1 &
    fi
    # Give babeld a moment to bind its UDP socket.
    sleep 2
    if pgrep -x babeld >/dev/null 2>&1 && \
       (netstat -ulnp 2>/dev/null || ss -ulnp 2>/dev/null) | grep -q babeld; then
        MESH_UP=1
    fi
fi
if [ ${MESH_UP} -eq 0 ] && [ ${BRLAN_UP} -eq 1 ] && ([ -x /usr/sbin/bmx7 ] || which bmx7 >/dev/null 2>&1); then
    if [ -x /etc/init.d/bmx7 ]; then
        /etc/init.d/bmx7 enable 2>/dev/null
        /etc/init.d/bmx7 restart >/tmp/bmx7-start.log 2>&1 || true
    else
        killall bmx7 2>/dev/null || true
        bmx7 dev=br-lan >/tmp/bmx7.log 2>&1 &
    fi
    sleep 2
    if pgrep -x bmx7 >/dev/null 2>&1; then
        MESH_UP=1
    fi
fi

# Ensure dropbear is running. The first-boot dropbear enable is also done
# by configure-source-image.sh (S19dropbear), but this is a safety net in
# case the symlink was overwritten by lime-config.
/etc/init.d/dropbear enable 2>/dev/null || true
/etc/init.d/dropbear start 2>/dev/null || true

# Only mark as configured when br-lan is UP AND the mesh daemon is verified
# listening. A failed first boot leaves the marker unset so the next boot
# retries the full reconfiguration.
if [ ${BRLAN_UP} -eq 1 ] && [ ${MESH_UP} -eq 1 ]; then
    touch "${MARKER}"
fi

exit 0
RCLOCALEOF
sudo chmod +x "${MOUNT_POINT}/etc/rc.local"
log "  rc.local: atomic network rewrite + babeld init restart (idempotent, retryable)"

# ─── Ensure /sbin/service shim is present (needed by mesha adapters) ──────────
# OpenWrt doesn't ship a SysV-style `service` command; mesha adapters and some
# testbed helpers shell out to `service <name> <action>`. Inject a minimal
# shim that maps to /etc/init.d/<name> <action>.
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
