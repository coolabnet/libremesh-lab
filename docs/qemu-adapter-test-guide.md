# QEMU Adapter Test Guide

This guide describes how to test all Mesha adapter scripts using the QEMU LibreMesh testbed.

## Overview

LibreMesh Lab provides a virtual environment to test adapter scripts against real LibreMesh firmware running in QEMU virtual machines. The testbed supports two modes:

1. **Quick Test**: Using a prebuilt LibreRouterOS image (faster setup, limited functionality)
2. **Full Test**: Building LibreMesh from source with vwifi-client (complete functionality, takes 2-4 hours)

Adapter tests verify JSON-over-SSH and HTTP functionality of scripts like:

- `collect-nodes.sh`
- `collect-topology.sh`
- `collect-services.sh`
- `collect-health.sh`
- `discover-from-thisnode.sh`
- `normalize.py`
- And others in the `adapters/` directory

## Prerequisites

- QEMU installed (`qemu-system-x86_64`)
- Docker (optional, for building from source)
- sudo privileges (required for image creation with `convert-prebuilt.sh` and some testbed operations)
- Git repository: `~/Dev/coolab/mesha`

### Installing QEMU

```bash
# Arch Linux
sudo pacman -S qemu-system-x86 qemu-utils

# Debian/Ubuntu
sudo apt-get install -y qemu-system-x86 qemu-utils

# Alpine Linux
sudo apk add qemu-system-x86_64 qemu-img

# macOS
brew install qemu
```

### Permission Requirements

| Step | Needs sudo? | Why |
|------|-------------|-----|
| `convert-prebuilt.sh` | Yes | Loop device mount for image creation |
| `start-mesh.sh` | Yes | TAP device + bridge creation |
| `start-vwifi.sh` | No | Userspace binary, no special perms |
| `configure-vms.sh` | No | SSH-based, runs as current user |
| `stop-mesh.sh` | Yes | TAP/bridge cleanup |
| `run-testbed-adapter.sh` | No | SSH-based adapter execution |

## Testbed Components

Key scripts in `scripts/qemu/`:

- `start-mesh.sh` - Launches VMs and vwifi-server
- `stop-mesh.sh` - Stops and cleans up the testbed
- `configure-vms.sh` - Configures VMs after boot (hostname, network, SSH keys)
- `convert-prebuilt.sh` - Creates bootable image from LibreRouterOS prebuilt files
- `build-libremesh-image.sh` - Builds LibreMesh image from source (2-4 hours)
- `run-testbed-adapter.sh` - Wrapper to run adapter scripts against testbed VMs

Test scripts in `tests/qemu/`:

- `test-adapters.sh` - TAP tests for adapter contracts (8 tests)
- `test-mesh-protocols.sh` - Mesh protocol validation
- `test-validate-node.sh` - Node validation tests
- `test-config-drift.sh` - Configuration drift detection
- `test-topology-manipulation.sh` - Topology change tests
- `test-firmware-upgrade.sh` - Firmware upgrade simulation
- `test-multi-hop.sh` - Multi-hop mesh routing tests
- `run-all.sh` - Runs all QEMU integration tests (7 test files)

## Quick Test Procedure (Recommended for Initial Validation)

### 1. Download Prebuilt Files (if needed)

**Option A: LibreRouterOS 1.5 (recommended)**

```bash
cd ~/Dev/coolab/mesha/images
# Download LibreRouterOS 1.5 prebuilt files (approx. 12MB total)
wget "https://repo.librerouter.org/lros/releases/1.5/targets/x86/64/librerouteros-1.5-r0%2B11434-e93615c947-x86-64-generic-rootfs.tar.gz"
wget -O generic-kernel.bin "https://repo.librerouter.org/lros/releases/1.5/targets/x86/64/librerouteros-1.5-r0%2B11434-e93615c947-x86-64-vmlinuz"
```

**Option B: Vanilla OpenWRT 23.05.1 (basic, no LibreMesh)**

```bash
cd ~/Dev/coolab/mesha/images
wget https://archive.openwrt.org/releases/23.05.1/targets/x86/64/openwrt-23.05.1-x86-64-generic-ext4-combined.img.gz
gunzip openwrt-23.05.1-x86-64-generic-ext4-combined.img.gz
```

> **Note**: Vanilla OpenWRT lacks LibreMesh packages (lime-config, BMX7, etc.). Use only for basic QEMU validation, not adapter testing.

### 2. Create Bootable Image (requires sudo)

```bash
cd ~/Dev/coolab/mesha
sudo ./scripts/qemu/convert-prebuilt.sh --skip-download
```

This creates:
`images/librerouteros-prebuilt.img`

> **Note**: The `--skip-download` flag assumes you already have the files in `images/`. If you just downloaded them in step 1, you can use this flag to skip re-downloading.

### 3. Make Image Available to Testbed Scripts

The testbed scripts expect the base image at `images/libremesh-x86-64.ext4`. Create a symlink:

```bash
cd ~/Dev/coolab/mesha
sudo ln -sf librerouteros-prebuilt.img images/libremesh-x86-64.ext4
```

### 4. Start the Testbed

```bash
cd ~/Dev/coolab/mesha
./scripts/qemu/start-mesh.sh &
```

Wait for the output to show:

```text
 All VMs launched. Waiting for boot...
 Run configure-vms.sh to set up LibreMesh
 Run stop-mesh.sh to tear down
```

### 5. Configure the VMs

```bash
cd ~/Dev/coolab/mesha
./scripts/qemu/configure-vms.sh
```

This script:

- Waits for SSH connectivity to all VMs (may take 30-60 seconds)
- Sets hostnames and network configuration
- Attempts to load kernel modules (may warn if missing in prebuilt image - this is expected)
- Configures UCI settings
- Injects SSH keys for passwordless access
- Generates resolved SSH config

### 5b. Inside the VM (optional manual checks)

```bash
# SSH into a VM
ssh -F config/ssh-config.resolved root@lm-testbed-node-1

# Configure default route if internet access needed (via QEMU user-mode wan0)
ip route add default via 10.0.2.2 dev eth1

# Test internet connectivity
ping -c 3 8.8.8.8
```

**Exiting QEMU console**: Press `Ctrl+A`, then `X` (only if attached to serial console, not needed for background mode).

### 6. Run Adapter Tests

```bash
cd ~/Dev/coolab/mesha
./tests/qemu/test-adapters.sh
```

Expected output (TAP format):

```text
TAP version 13
1..6
ok 1 - collect-nodes lm-testbed-node-1: reachable, hostname present, interfaces non-empty
ok 2 - collect-nodes lm-testbed-node-2: reachable, hostname present, interfaces non-empty
ok 3 - collect-nodes lm-testbed-node-3: reachable, hostname present, interfaces non-empty
ok 4 - collect-nodes lm-testbed-tester: reachable, hostname present, interfaces non-empty
ok 5 - collect-topology lm-testbed-node-1: node_count >= 1 (found 4)
ok 6 - discover-from-thisnode: output files exist
# Summary
# 6 passed, 0 failed out of 6 tests
```

Alternatively, run the full test suite:

```bash
cd ~/dev/coolab/mesha
./tests/qemu/run-all.sh
```

### 7. Stop the Testbed

When finished, stop the testbed to free resources:

```bash
cd ~/Dev/coolab/mesha
./scripts/qemu/stop-mesh.sh
```

Or press `Ctrl+C` in the terminal where `start-mesh.sh` is running.

## Full Test Procedure (Source Build)

For complete functionality including WiFi simulation:

### 1. Build LibreMesh Image (2-4 hours)

```bash
cd ~/Dev/coolab/mesha
./scripts/qemu/build-libremesh-image.sh
```

This creates:
`images/libremesh-x86-64-<hash>-<date>.img.gz`

### 2. Follow Steps 3-7 from Quick Test

The `start-mesh.sh` script automatically detects whether to use the prebuilt or source-built image (it looks for `libremesh-x86-64.ext4` by default, but the build script creates a similarly named file with hash and date; however, the testbed scripts use the latest image via symlink or direct reference - see `build-libremesh-image.sh` output for details).

## Testbed Networking Architecture

```text
                          ┌─────────────────────────────────┐
                          │        Host (10.99.0.254)        │
                          │                                   │
                          │  mesha-br0 (Linux bridge)         │
                          │  10.99.0.254/16                   │
                          │                                   │
                          │  mesha-tap0  mesha-tap1  mesha-tap2  mesha-tap3 │
                          └──┬──────────┬──────────┬──────────┬──┘
                             │          │          │          │
                     ┌───────┴──┐  ┌────┴─────┐  ┌─┴────────┐ ┌┴──────────┐
                     │  VM1     │  │  VM2     │  │  VM3     │ │  VM4      │
                     │  node-1  │  │  node-2  │  │  node-3  │ │  tester   │
                     │10.99.0.11│  │10.99.0.12│  │10.99.0.13│ │10.99.0.14 │
                     │          │  │          │  │          │ │           │
                     │ mesh0:   │  │ mesh0:   │  │ mesh0:   │ │ mesh0:    │
                     │  TAP     │  │  TAP     │  │  TAP     │ │  TAP      │
                     │ wan0:    │  │ wan0:    │  │ wan0:    │ │ wan0:     │
                     │  user    │  │  user    │  │  user    │ │  user     │
                     └──────────┘  └──────────┘  └──────────┘ └───────────┘
                             │          │          │          │
                             └────── All on same L2 via mesha-br0 ──────┘

                     vwifi-server on host (10.99.0.254:8212)
                     relays WiFi frames via TCP between VMs
                     (server binds INADDR_ANY — no bind-address config needed)
```

## Troubleshooting

### Common Issues

1. **"Base image not found"**
   - Ensure you have completed step 3 (symlink) from the Quick Test procedure
   - Verify file exists: `ls -l images/libremesh-x86-64.ext4`

2. **"sudo: a terminal is required"**
   - Run the convert-prebuilt.sh command with sudo directly (as shown in step 2)
   - If you get a password prompt, configure passwordless sudo for the specific command or enter your password

3. **VMs not reachable via SSH**
   - Wait longer for boot (the configure-vms.sh script waits for SSH with retries)
   - Check serial logs: `ls run/logs/` and examine the latest `.log` files
   - Verify bridge and TAP devices: `ip link show mesha-br0`
   - Check if VMs are running: `ps aux | grep qemu`

4. **Adapter tests fail with JSON errors**
   - Test manual SSH: `ssh -F config/ssh-config.resolved root@lm-testbed-node-1`
   - Run adapter manually: `./scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-nodes.sh lm-testbed-node-1`
   - Check adapter output format (must be valid JSON)
   - If you see "command not found" errors, the VM may be missing packages (expected with prebuilt image)

5. **Missing kernel modules in prebuilt image**
   - Expected limitation: LibreRouterOS prebuilt lacks `kmod-mac80211-hwsim` and `vwifi-client`
   - Adapter tests still work for wired BMX7 functionality over TAP/bridge
   - For full WiFi simulation, use source build (Full Test Procedure)

6. **"Another test bed instance is running"**
   - Run `./scripts/qemu/stop-mesh.sh` first, or remove `run/testbed.lock` manually

## Verification

After running tests, verify:

- All adapter tests exit with code 0
- TAP output shows expected number of tests passed
- You can SSH to each VM: `ssh -F config/ssh-config.resolved root@<hostname>`
- Basic mesh connectivity: `ping 10.99.0.12` from node-1 (should work over wired BMX7)

## Notes

### Prebuilt Image Fixes

The prebuilt LibreRouterOS image has several limitations that are automatically handled:

- **`/sbin/service` shim**: `convert-prebuilt.sh` injects a minimal shim that delegates to `/etc/init.d/`. This ensures `service dropbear restart`, `service uhttpd restart`, etc. work correctly.
- **HOSTALIASES**: Both `tests/qemu/common.sh` and `run-testbed-adapter.sh` export `HOSTALIASES` pointing to `run/host-aliases` for automatic `thisnode.info` resolution.
- **ip -j fallback**: Test 4 in `test-adapters.sh` gracefully skips when `ip-full` is not available (prebuilt images may lack JSON output support).

### Source-Built Images

Source-built images (via `build-libremesh-image.sh`) include:

- Bootloader (GRUB/Syslinux) — `start-mesh.sh` auto-detects this and skips `-kernel` args
- vwifi-client package for WiFi simulation
- mac80211_hwsim kernel module
- Full `ip-full` package with JSON output
- Proper `lime-config` and UCI sections

### Root Device

The root device is `/dev/sda` (not `/dev/vda`) because the QEMU VMs use the `q35` machine type with `virtio-net-pci` devices but raw/IDE disk drives.

### SSH Configuration

SSH connections require `ssh-rsa` algorithm support:

```text
HostKeyAlgorithms=+ssh-rsa
PubkeyAcceptedKeyTypes=+ssh-rsa
```

This is pre-configured in the generated `ssh-config.resolved`.

### General

- The prebuilt image approach is ideal for rapid iteration and CI/CD
- Source build provides complete functionality including WiFi simulation via vwifi
- Testbed automatically creates qcow2 overlays for fast VM reset
- SSH key injection enables passwordless access after initial configuration
- The `run-testbed-adapter.sh` script handles path translation so adapter scripts with hardcoded paths work against the testbed topology
- Total time for quick test: ~5-10 minutes for download/image creation + ~1 minute for VM boot + ~1 minute for configuration + ~1 minute for testing
- The testbed uses the management subnet 10.99.0.0/16 to avoid conflicts with other networks
- For a simpler single-VM OpenWRT setup (no mesh), see [scripts_guarita QEMU guide](https://github.com/is4bel4/scripts_guarita/blob/main/docs/QEMU.md)

## Reference

- [Lab README](README.md) — architecture, scripts table, requirements
- [Lab Troubleshooting](troubleshooting.md) — detailed debugging guide
- [Self-Hosted Runner](self-hosted-runner.md) — CI setup with KVM
- [scripts_guarita QEMU](https://github.com/is4bel4/scripts_guarita/blob/main/docs/QEMU.md) — simpler single-VM QEMU launcher (PT/EN)

---
*Guide maintained for LibreMesh Lab adapter validation*
