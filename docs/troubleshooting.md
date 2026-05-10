# Test Bed Troubleshooting

## VM won't boot

**Symptoms:** No serial output, QEMU process exits immediately

**Checks:**

```bash
# Verify image exists
ls -lh images/*.img

# Check QEMU version
qemu-system-x86_64 --version

# Try with more RAM
# Edit topology.yaml: ram_mb: 512 for the failing node

# Check serial log
cat run/logs/node-N.serial.log
```

**Common causes:**

- Image file missing or corrupt — rebuild with `build-libremesh-image.sh`
- KVM not available — script auto-detects and falls back to TCG
- Insufficient RAM — increase in `topology.yaml`

## vwifi-server won't start

**Symptoms:** `vwifi-server failed to start`

**Checks:**

```bash
# Check dependencies
dpkg -l cmake g++ pkg-config libnl-3-dev libnl-genl-3-dev

# Check port availability
ss -tlnp | grep 8212

# Try manual compilation
cd src/vwifi/build && cmake .. && make

# Check if binary exists
ls -la bin/vwifi-server
```

## BMX7 not forming mesh

**Symptoms:** `bmx7 -c originators` shows only self

**Checks:**

```bash
# On a VM:
ssh -F config/ssh-config.resolved root@lm-testbed-node-1
bmx7 -c status
bmx7 -c interfaces
iw dev  # Check wlan interfaces exist
logread | grep bmx7 | tail -20

# Check vwifi-client
uci show vwifi
logread | grep vwifi | tail -10

# Check mac80211_hwsim
lsmod | grep mac80211
```

**Common causes:**

- vwifi-client not connected to server — check server_ip in UCI
- mac80211_hwsim loaded with wrong radio count — must be `radios=0`
- lime-config not run — re-run configure-vms.sh

## SSH connection refused

**Symptoms:** `ssh: Connection refused` to 10.99.0.x

**Checks:**

```bash
# Verify VM running
cat run/node-N.pid && kill -0 $(cat run/node-N.pid)

# Verify bridge
ip addr show mesha-br0

# Verify TAP
ip link show mesha-tap0

# Try from QEMU monitor
# Check if VM got an IP on its eth0
```

## `ip -j` not working

**Symptoms:** Empty or non-JSON output from `ip -j addr show`

**Fix:** Install `ip-full` package in the firmware image.
Add `CONFIG_PACKAGE_ip-full=y` to `libremesh-testbed.defconfig` and rebuild.

## Bridge/TAP issues

**Symptoms:** VMs can't communicate, bridge not visible

```bash
# Show bridge members
bridge link show

# Re-create networking
sudo bash scripts/qemu/stop-mesh.sh
sudo bash scripts/qemu/start-mesh.sh
```

## vwifi-ctrl issues

**Symptoms:** `vwifi-ctrl` commands fail or topology changes not taking effect

**Checks:**

```bash
# Verify vwifi-ctrl binary exists
ls -la bin/vwifi-ctrl

# Check vwifi-server is running
cat run/vwifi-server.pid
kill -0 $(cat run/vwifi-server.pid)

# Test basic connectivity
bin/vwifi-ctrl list    # list all connected VMs
bin/vwifi-ctrl get 1   # get coordinates of node 1

# Set coordinates and verify
bin/vwifi-ctrl set 1 0 0 0
bin/vwifi-ctrl get 1

# Enable/disable packet loss simulation
bin/vwifi-ctrl loss yes
bin/vwifi-ctrl loss no
```

**Common causes:**

- vwifi-server not running — run `bash scripts/qemu/start-vwifi.sh`
- Wrong control port — check `VWIFI_PORT` matches vwifi-server's TCP port
- vwifi-client not connected on VMs — check `uci show vwifi` inside a VM

## Reset mesh state

To completely reset the testbed (stop VMs, clean overlays, restart fresh):

```bash
# Full reset using stop-mesh.sh
sudo bash scripts/qemu/stop-mesh.sh

# Then restart
sudo bash scripts/qemu/start-mesh.sh
bash scripts/qemu/configure-vms.sh
```

This stops all QEMU VMs, vwifi-server, removes TAP devices and bridge,
deletes qcow2 overlays, and removes the lock file.

## Lock file stuck

**Symptoms:** "Test bed already running" but no VMs

```bash
# Remove stale lock
rm -rf run/testbed.lock

# Kill orphaned QEMU processes
pgrep -a qemu-system
kill $(pgrep qemu-system)
```

## Orphaned QEMU processes

```bash
# Find all QEMU processes
ps aux | grep qemu

# Kill specific VM
kill $(cat run/node-N.pid)

# Kill all
pkill -f qemu-system-x86_64

# Full cleanup
sudo bash scripts/qemu/stop-mesh.sh
```
