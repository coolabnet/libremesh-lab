# QEMU LibreMesh Test Bed — Final Implementation Plan

**Date:** 2026-05-03
**Version:** v3.4 final (corrected — upstream-verified)
**Status:** Ready for Implementation
**Author:** Muse + Forge (Technical Review)
**Merges:** v3.4 plan + verified corrections research + application checklist

---

## Objective

Build a fully working QEMU-based test bed that runs real LibreMesh firmware images in virtual machines, connected via TAP/bridge networking for L2-direct inter-VM communication and vwifi for simulated WiFi mesh links, integrated with Mesha's existing adapter scripts (`collect-nodes.sh`, `collect-topology.sh`), agent architecture, and CI pipeline. The test bed must enable testing of real mesh protocols (BMX7/Babel), UCI configuration writes, firmware upgrade simulation, and WiFi topology changes — none of which the current Docker-based stub approach can validate.

The plan preserves the existing Docker onboarding test (`docker-compose.onboarding-test.yml`) as the fast CI gate and layers the QEMU test bed on top for integration testing.

### Critical Fix from v1

v1 used QEMU user-mode networking (`-netdev user`) for the mesh0 interface on each VM. This creates **separate NAT domains per VM** — VMs cannot see each other, making the core value proposition (multi-VM mesh) impossible. v2 switched mesh0 to **TAP/bridge networking** so all VMs share a single L2 segment where they can directly communicate. The wan0 interface remains user-mode for internet access.

### v2 → v3 Corrections

v2 had several technical inaccuracies discovered during deep codebase review against upstream sources (Raizo62/vwifi, javierbrk/vwifi_cli_package, VIRTUALIZING.md) and Mesha's actual adapter scripts:

1. **vwifi TCP mode (not VHOST)** — v2 mixed VHOST and TCP concepts. With TAP/bridge networking, TCP mode is correct (VMs have their own IPs). VHOST requires `vhost_vsock` kernel module and `-device vhost-vsock-pci` QEMU args, which is unnecessary complexity.
2. **vwifi-client uses UCI config inside OpenWrt** — v2 said "start vwifi-client connecting to host" but the actual vwifi_cli_package uses `uci set vwifi.config.server_ip=...` + `service vwifi-client start`.
3. **Missing `vwifi-add-interfaces` step** — vwifi requires creating wlan interfaces with `vwifi-add-interfaces` BEFORE starting vwifi-client. v2 omitted this.
4. **mac80211_hwsim radios=0** — vwifi needs `mac80211_hwsim` loaded with `radios=0` (zero radios) because vwifi-client creates its own interfaces. v2 didn't specify this.
5. **Missing build dependencies** — vwifi-server needs `pkg-config` and `make` (not just cmake/g++). Docker builder also needs `pkg-config`.
6. **Adapter script path assumptions** — `run-mesh-readonly.sh` reads inventories from `$REPO_ROOT/inventories/` (hardcoded). `discover-from-thisnode.sh` hardcodes `TARGET_HOST="thisnode.info"`. `validate-node.sh` reads `${WORKSPACE_ROOT}/desired-state/mesh/firmware-policy.yaml`. The plan needs a testbed wrapper that sets up the correct paths.
7. **Host-side thisnode.info resolution** — The host machine (where discover-from-thisnode.sh runs) also needs `thisnode.info → 10.99.0.11` in /etc/hosts, not just the VMs.

---

## Architectural Decision: Multi-VM Approach (GAP 17)

**Decision:** Use 3 LibreMesh VMs + 1 tester VM (4 total), each running real LibreMesh x86-64 firmware with vwifi-client inside, connected through a Linux bridge on the host (TAP devices) for management/mesh traffic and vwifi-server for WiFi simulation.

**Justification against Single-VM approach (openwrt-tests-libremesh):**
- The single-VM approach (1 VM + vwifi simulating 3 peers) only tests WiFi driver simulation, not real inter-node mesh protocol behavior. BMX7/Babel convergence, link-quality metrics, and multi-hop routing require separate network stacks.
- Mesha's `collect-nodes.sh` SSHes into individual nodes by hostname — this maps naturally to separate VMs with distinct IPs.
- The multi-VM approach tests the actual Mesha workflow: SSH into node A, collect data, SSH into node B, collect data, merge topology.
- Resource cost is manageable: 3x256MB + 1x512MB = ~1.3GB RAM, within GitHub Actions runner limits.

**Trade-off accepted:** Higher resource usage and longer boot time (~60s) compared to single-VM. Mitigated by qcow2 overlay snapshots for fast reset.

---

## Networking Architecture

### Overview

```
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

### Interface Assignment per VM

| Interface | Backend | Purpose | Network |
|-----------|---------|---------|---------|
| mesh0 (eth0) | TAP via mesha-br0 | Management SSH + wired mesh traffic | 10.99.0.0/16 |
| wan0 (eth1) | QEMU user-mode | Internet access (NAT via host) | 10.0.2.0/24 (QEMU default) |
| wlan0 (simulated) | vwifi-client → vwifi-server | WiFi mesh simulation (BMX7/Babel) | Relay via 10.99.0.254:8212 |

### Why TAP/Bridge Instead of User-Mode

1. **Inter-VM direct communication**: User-mode networking creates per-VM NAT domains. VMs cannot reach each other. TAP/bridge puts all VMs on the same L2 segment.
2. **Host-to-VM SSH**: Host at 10.99.0.254 can SSH to any VM directly without port forwarding.
3. **VM-to-VM SSH**: VMs can SSH to each other using 10.99.0.x addresses — required for mesh protocol operation and Mesha adapter testing.
4. **Tester VM reachability**: The tester VM (node-4) can reach all other VMs, enabling end-to-end adapter testing from within the mesh.
5. **vwifi relay**: vwifi-server on the host binds INADDR_ANY, reachable from all VMs at 10.99.0.254:8212 for WiFi frame relay.

### Subnet Choice: 10.99.0.0/16

The management subnet uses 10.99.0.0/16 to avoid collision with:
- LibreMesh's internal mesh subnet (typically 10.13.0.0/16 as seen in Docker fixtures at `docker/onboarding-test/fixtures/gateway/uci-network.txt:6-9`)
- Common private ranges (10.0.0.0/8 subnets, 172.16.0.0/12, 192.168.0.0/16)
- The QEMU user-mode default (10.0.2.0/24)

---

## Gap Resolution Summary

| Gap | Resolution | Phase |
|-----|-----------|-------|
| GAP 1: Build Pipeline | BuildRoot with vwifi feed + 802.11ax patch; cache images as CI artifacts | Phase 1 |
| GAP 2: vwifi-server | Compile from Raizo62/vwifi on host; TCP mode (not VHOST) with `-u` flag for multi-VM identification; server binds INADDR_ANY by default — no bind-address flag exists | Phase 2 |
| GAP 3: QEMU Configuration | q35 machine, 2 NICs per VM (TAP+user), qcow2 overlays, bridge networking | Phase 2 |
| GAP 4: Mesha Adapter Integration | Install ip-full in images; configure /etc/hosts; validate marker protocol | Phase 3 |
| GAP 5: Labgrid/openwrt-tests | Reference for test patterns but don't adopt the framework — Mesha uses shell adapters, not pytest+labgrid | Phase 4 |
| GAP 6: 802.11ax Patch | Cherry-pick commit 89bc4284bb0b into lime-packages before build | Phase 1 |
| GAP 7: CI Resources | 4-VM mesh at 1.3GB fits GitHub Actions 7GB; use TCG fallback with 3x timeout | Phase 5 |
| GAP 8: Known Limitations | IPv6 link-local still used for inter-VM ping; ICMPv4 now works over bridge too | Phase 3 |
| GAP 9: Topology Configuration | vwifi-server defaults to full mesh; use vwifi-ctrl for selective link manipulation in tests | Phase 4 |
| GAP 10: Docker vs QEMU Bridge | Coexist: Docker for fast CI (<30s), QEMU for integration tests (~5min) | Phase 5 |
| GAP 11: tmux Dependency | Replace tmux with background processes with PID tracking and trap-based cleanup | Phase 2 |
| GAP 12: Image Versioning | Cache built images as GitHub Actions artifacts (7-day retention); version-tag in filename | Phase 1 |
| GAP 13: KVM Availability | Detect /dev/kvm at runtime; fall back to `-accel tcg` with 3x SSH timeouts | Phase 2 |
| GAP 14: SSH Key Management | OpenWrt default passwordless root + first-SSH key injection (resolved, no TBD) | Phase 2 |
| GAP 15: Test Assertions | Use range/presence assertions ('BMX7 has >=2 originators') not exact-match; parameterize by VM count | Phase 4 |
| GAP 16: discover-from-thisnode.sh | Configure uhttpd on VM1 to respond at thisnode.info; add DNS alias via /etc/hosts | Phase 3 |
| GAP 17: Multi-VM vs Single-VM | Multi-VM chosen (see architectural decision above) | Phase 2 |

---

## Implementation Plan

### Phase 1: LibreMesh Image Build Pipeline

**Goal:** Produce a reproducible LibreMesh x86-64 firmware image with WiFi simulation support that can boot in QEMU.

- [ ] **1.1 Create build script** at `scripts/qemu/build-libremesh-image.sh` that:
  - Follows the LibreMesh build process from https://github.com/libremesh/lime-packages:
    1. `git clone https://github.com/libremesh/lime-packages.git`
    2. `cd lime-packages && make` — this clones OpenWrt and applies lime-packages as a feed automatically
  - **Pin vwifi feed** (proven during GSoC 2025, from `libremesh-virtual-mesh/.gitmodules`):
    ```
    echo 'src-git vwifi https://github.com/javierbrk/vwifi_cli_package.git' >> feeds.conf
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    ```
    - **Note:** The GSoC project used whatever was at HEAD. If the feed breaks at latest, pin to a commit from August-September 2025.
  - The 802.11ax fix (commit `89bc4284bb0b`) is already in lime-packages master as of September 2025. Verify with: `git log --oneline | grep 89bc428`
  - **Creates a defconfig** at `scripts/qemu/libremesh-testbed.defconfig` (NOT interactive `make menuconfig`):
    ```
    CONFIG_TARGET_x86=y
    CONFIG_TARGET_x86_64=y
    CONFIG_TARGET_x86_64_DEVICE_generic=y
    CONFIG_PACKAGE_kmod-mac80211-hwsim=y
    CONFIG_PACKAGE_vwifi-client=y
    CONFIG_PACKAGE_bmx7=y
    CONFIG_PACKAGE_babeld=y
    CONFIG_PACKAGE_ip-full=y
    CONFIG_PACKAGE_iwinfo=y
    CONFIG_PACKAGE_uc=y
    CONFIG_PACKAGE_ubus=y
    CONFIG_PACKAGE_uhttpd=y
    CONFIG_PACKAGE_python3-light=y
    CONFIG_PACKAGE_netcat=y
    CONFIG_PACKAGE_iw=y
    CONFIG_PACKAGE_lime-system=y
    CONFIG_PACKAGE_lime-proto-bmx7=y
    CONFIG_CCACHE=y
    ```
  - **Note:** `openssh-server` is intentionally omitted — OpenWrt base images include `dropbear` for SSH, which is sufficient for adapter scripts. Adding openssh-server wastes ~500KB and may conflict on port 22.
  - **Note:** `netcat` is needed by adapter scripts for babeld fallback (`collect-nodes.sh:139`, `collect-topology.sh:118`). Busybox `nc` on OpenWrt may not support the `-q` flag — adapter scripts should use the `sleep 1` pipe pattern from `validate-node.sh:151` as a fallback: `( echo 'cmd'; sleep 1 ) | nc host port`. `lime-system` and `lime-proto-bmx7` are needed for LibreMesh community config that `validate-node.sh` checks. The defconfig `CONFIG_PACKAGE_*` names may need adjustment — run `make defconfig` and verify with `grep CONFIG_PACKAGE_ .config`.
  - Build sequence (CRITICAL ORDER: feeds must be installed BEFORE `make defconfig` so `CONFIG_PACKAGE_*` symbols for feed packages like vwifi-client are resolvable):
    ```bash
    # 1. Clone and enter build dir
    git clone https://github.com/libremesh/lime-packages.git
    cd lime-packages && make  # clones OpenWrt, applies lime-packages as feed

    # 2. Add vwifi feed BEFORE feeds update
    echo 'src-git vwifi https://github.com/javierbrk/vwifi_cli_package.git' >> feeds.conf

    # 3. Update and install ALL feeds (including vwifi)
    ./scripts/feeds update -a
    ./scripts/feeds install -a

    # 4. NOW apply defconfig — feeds are available for symbol resolution
    cp scripts/qemu/libremesh-testbed.defconfig .config
    make defconfig  # expands defconfig; vwifi symbols now resolvable

    # 5. Verify critical packages resolved
    grep CONFIG_PACKAGE_vwifi-client .config  # must NOT be '# ... is not set'

    # 6. Build
    make -j$(nproc)
    ```
  - After `make defconfig`, verify vwifi appears: `grep CONFIG_PACKAGE_vwifi-client .config`
  - Outputs `openwrt-x86-64-generic-ext4-combined.img.gz` to `images/`
  - Records build manifest (package list, commit hashes) in `images/build-manifest.yaml`
  - **Fallback strategy:** If the LibreMesh+vwifi build combination fails:
    1. Use the `libremesh-virtual-mesh` repo's exact build instructions (clone into OpenWrt build dir)
    2. Use a pre-built LibreRouterOS image (see Phase 1.5)

- [ ] **1.2 Create Docker-based build environment** at `docker/qemu-builder/Dockerfile`:
  - Based on `ubuntu:22.04` with build dependencies: `build-essential`, `cmake`, `g++`, `pkg-config`, `libncurses-dev`, `zlib1g-dev`, `gawk`, `git`, `gettext`, `libssl-dev`, `rsync`, `swig`, `unzip`, `wget`, `python3`, `libnl-3-dev`, `libnl-genl-3-dev`, `qemu-utils`, `ccache`
  - Entry point: runs the build script from 1.1
  - Enables reproducible builds on any host with Docker

- [ ] **1.3 Create image versioning and caching strategy:**
  - Filename pattern: `libremesh-x86-64-{short-commit-hash}-{date}.img.gz`
  - Creates `images/build-inputs.hash` containing pinned commit hashes for lime-packages, openwrt, and vwifi_cli_package. This file is included in the CI cache key to ensure cache invalidation when upstream sources change.
  - Build script checks if cached image matches current source hashes before rebuilding
  - GitHub Actions artifact upload/download steps for CI caching (7-day retention)

- [ ] **1.4 Create `images/README.md`** documenting:
  - How to build from scratch
  - How to use pre-built images from LibreRouterOS releases (noting WiFi limitation)
  - Where cached images are stored
  - What packages are included and why


- [ ] **1.5 Create fast-path setup** for parallel development (use while Phase 1 custom build runs):
  - Download LibreRouterOS 1.5 pre-built image:
    ```bash
    mkdir -p images
    curl -L -o images/generic-rootfs.tar.gz \
      https://repo.librerouter.org/lros/releases/1.5/targets/x86/64/generic-rootfs.tar.gz
    curl -L -o images/generic-kernel.bin \
      https://repo.librerouter.org/lros/releases/1.5/targets/x86/64/generic-kernel.bin
    ```
  - Create a conversion script at `scripts/qemu/convert-prebuilt.sh` that creates a bootable ext4 disk image from `generic-rootfs.tar.gz` + `generic-kernel.bin`:
    ```bash
    dd if=/dev/zero of=images/rootfs.ext4 bs=1M count=256
    mkfs.ext4 images/rootfs.ext4
    mkdir -p /tmp/rootfs-mount
    mount -o loop images/rootfs.ext4 /tmp/rootfs-mount
    tar -xzf images/generic-rootfs.tar.gz -C /tmp/rootfs-mount
    umount /tmp/rootfs-mount
    ```
  - QEMU launch with pre-built uses `-kernel` approach:
    ```bash
    qemu-system-x86_64 -enable-kvm -M q35 -m 256M -nographic \
      -kernel images/generic-kernel.bin \
      -drive file=images/rootfs.ext4,if=virtio,format=raw \
      -append "root=/dev/vda rootfstype=ext4 rootwait console=ttyS0" \
      ...
    ```
  - **Limitations of pre-built images:**
    - No `kmod-mac80211-hwsim` — WiFi simulation not possible
    - No `vwifi-client` — inter-VM WiFi relay not possible
    - BMX7 over wired TAP/bridge interfaces still works for basic testing
    - `validate-node.sh` Check 4 (community SSID) will work since LibreRouterOS includes lime-packages
    - `collect-nodes.sh` and `collect-topology.sh` will work for wired mesh topology
  - **Purpose:** Enable Phase 2-3 development in parallel with Phase 1's 2-4 hour build
  - **Important:** `start-mesh.sh` should detect which format is available and use appropriate QEMU arguments
### Step-by-Step Test Gates: Phase 1

Each gate must PASS before proceeding to the next step. If a gate fails, the specific diagnosis command helps identify the root cause.

**Gate 1.1: Build script produces image file**
- **Action:** Run `bash scripts/qemu/build-libremesh-image.sh`
- **Expected:** File `images/openwrt-x86-64-generic-ext4-combined.img.gz` exists and is > 50MB
- **Test command:** `ls -lh images/openwrt-x86-64-generic-ext4-combined.img.gz`
- **Diagnosis on failure:**
  - Check `images/build-manifest.yaml` exists — if not, build script didn't complete
  - Check BuildRoot logs for compilation errors: `grep -i 'error:' build.log`
  - Verify feed URLs are reachable: `git ls-remote https://github.com/javierbrk/vwifi_cli_package.git`
  - Verify OpenWrt tag exists: `git ls-remote https://github.com/openwrt/openwrt.git refs/tags/v23.05.*`

**Gate 1.2: Docker build environment produces same image**
- **Action:** Run `docker build -t mesha-qemu-builder -f docker/qemu-builder/Dockerfile . && docker run --rm -v $(pwd)/images:/output mesha-qemu-builder`
- **Expected:** Same image file produced; `build-manifest.yaml` lists all required packages
- **Test command:** `grep -E 'vwifi-client|mac80211-hwsim|bmx7|ip-full|python3-light|dropbear' images/build-manifest.yaml`
- **Each package must appear:** If any is missing, the BuildRoot `.config` is wrong
- **Diagnosis on failure:**
  - Missing package: check `scripts/qemu/build-libremesh-image.sh` has correct `CONFIG_PACKAGE_<name>=y` lines
  - vwifi-client missing: verify feed was added (`grep vwifi feeds.conf`)
  - mac80211-hwsim missing: verify target is `x86/64` (not a subtarget that excludes kernel modules)

**Gate 1.3: Image boots to login prompt in QEMU**
- **Action:** Launch single VM with the built image (using user-mode networking for isolated test):
  ```bash
  gunzip -k images/openwrt-x86-64-generic-ext4-combined.img.gz
  qemu-system-x86_64 -enable-kvm -M q35 -m 256M -nographic \
    -drive file=images/openwrt-x86-64-generic-ext4-combined.img,format=raw \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -serial mon:stdio 2>&1 | tee /tmp/qemu-boot-test.log &
  QEMU_PID=$!
  # Wait for boot prompt in background
  timeout 90 grep -q 'root@OpenWrt' <(tail -f /tmp/qemu-boot-test.log) 2>/dev/null
  kill $QEMU_PID 2>/dev/null
  ```
- **Expected:** `/tmp/qemu-boot-test.log` contains `root@OpenWrt` within 90 seconds
- **Test command:** `grep -q 'root@OpenWrt' /tmp/qemu-boot-test.log && echo 'OK: booted' || echo 'FAIL: no prompt'`
- **Diagnosis on failure:**
  - No output at all: image file is corrupt or empty; verify with `file images/openwrt-x86-64-generic-ext4-combined.img`
  - Kernel panic: check `/tmp/qemu-boot-test.log` for panic message; likely missing driver for q35 machine type
  - Hangs during boot: try `-accel tcg` instead of `-enable-kvm`; increase RAM to 512M
  - Prompt never appears: OpenWrt didn't finish init; check for missing filesystem modules
  - **Note:** Do NOT use `echo 'root' | qemu...` — QEMU's serial console does not read from stdin like a terminal. Use log file capture + grep instead.

**Gate 1.4: SSH server accepts connections**
- **Action:** Boot single VM with user-mode networking + port forwarding, then test SSH:
  ```bash
  qemu-system-x86_64 -enable-kvm -M q35 -m 256M -nographic \
    -drive file=images/openwrt-x86-64-generic-ext4-combined.img,format=raw \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -serial mon:stdio 2>&1 | tee /tmp/qemu-ssh-test.log &
  QEMU_PID=$!
  # Wait for boot
  timeout 90 grep -q 'root@OpenWrt' <(tail -f /tmp/qemu-ssh-test.log) 2>/dev/null
  # OpenWrt default LAN is 192.168.1.1 — QEMU user-mode forwards host:2222 to guest:22
  sleep 5  # Wait for sshd to start
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes -p 2222 root@127.0.0.1 'echo SSH_OK'
  kill $QEMU_PID 2>/dev/null
  ```
- **Expected:** `SSH_OK` printed on host terminal
- **Diagnosis on failure:**
  - Connection refused: dropbear not running; try `/etc/init.d/dropbear start` via serial console
  - Connection timeout: sshd not listening; boot may not have completed
  - Host key error: remove `~/.ssh/known_hosts` entry for `[127.0.0.1]:2222`
  - **Note:** OpenWrt default LAN IP is 192.168.1.1. The QEMU user-mode `hostfwd` maps host port 2222 to guest port 22, bypassing the need to know the guest IP.

**Gate 1.5: Required packages are functional**
- **Action:** SSH into the VM and run:
  ```bash
  ssh root@127.0.0.1 -p 2222 '
    echo "=== ip-full ==="; ip -j addr show | python3 -c "import sys,json; json.load(sys.stdin); print(chr(79)+chr(75))";
    echo "=== mac80211_hwsim ==="; modprobe mac80211_hwsim radios=0 && echo "OK";
    echo "=== vwifi ==="; which vwifi-add-interfaces && which vwifi-client && echo "OK";
    echo "=== bmx7 ==="; which bmx7 && echo "OK";
    echo "=== python3 ==="; python3 --version;
    echo "=== ubus ==="; ubus list | head -3;
    echo "=== uci ==="; uci show network.lan.ipaddr;
    echo "=== nc ==="; which nc && echo "OK";
  '
  ```
- **Expected:** Each section prints `OK` or valid output
- **Diagnosis on failure:**
  - `ip -j` returns empty: `ip-full` not installed, BusyBox `ip` is being used instead
  - `modprobe` fails: `kmod-mac80211-hwsim` not in image; rebuild with correct `.config`
  - `vwifi-add-interfaces` not found: vwifi feed not integrated; check `feeds.conf` in build dir
  - `python3` not found: `python3-light` not in image; add to package list
  - `nc` not found: `netcat` or `netcat-openbsd` not in image; needed by adapter scripts for babeld fallback
  - **Note:** The `print(chr(79)+chr(75))` avoids nested quote issues in the SSH command.

**Gate 1.6: Image versioning and caching works**
- **Action:** Run build script with source hash check
- **Expected:** Script computes hash of build inputs (feed commits, build script, Dockerfile) and compares against `.cache-version`. If match, skips build.
- **Test command:** `cat images/.cache-version` shows commit hashes and build input hash
- **Diagnosis on failure:** Cache invalidation logic in build script is broken; check hash computation
- **Note:** A full BuildRoot build takes 2-4 hours. The caching mechanism must detect unchanged inputs and skip the build entirely, not rebuild faster.

**Risks:**
1. **Build time (2-4 hours)** — Mitigation: CI artifact caching; only rebuild when source changes
2. **vwifi-client compilation failure on OpenWrt** — Mitigation: Use exact commits from GSoC 2025 proven configuration; fallback to mac80211_hwsim alone without vwifi inter-VM WiFi

---

### Phase 2: QEMU Orchestration Layer

**Goal:** Create scripts that launch, manage, and tear down a 4-VM mesh network with TAP/bridge networking and vwifi-server, with full process supervision and cleanup.

- [ ] **2.1 Create vwifi-server management script** at `scripts/qemu/start-vwifi.sh`:
  - Detects or compiles vwifi-server from `https://github.com/Raizo62/vwifi`
  - Host dependencies: `cmake`, `make`, `g++`, `pkg-config`, `libnl-3-dev`, `libnl-genl-3-dev`
  - Compiles to `bin/vwifi-server` (cached)
  - Launches in TCP mode: `bin/vwifi-server -u` (`-u`: use-port-in-hash for multi-VM identification; vwifi-server binds INADDR_ANY by default per `csocketserverfunctionitcp.cc` — no bind-address flag needed, VMs connect via 10.99.0.254:8212)
  - PID tracked in `run/vwifi-server.pid`
  - Default ports (from `src/config.h`): 8211 (VHOST, unused in TCP mode), 8212 (TCP primary), 8213 (spy), 8214 (control)
  - Optional: `-l 0.01` for 1% packet loss simulation (configurable via env var)
  - **Important:** vwifi-server has no `-a` flag for bind address. The server binds `INADDR_ANY` (0.0.0.0) on all ports — this is hardcoded in `csocketserverfunctionitcp.cc`. The `DEFAULT_ADDRESS_IP "127.0.0.1"` in `config.h` is only used by the CLIENT (`vwifi-client`, `vwifi-ctrl`), not the server. No config.h patching needed.
  - **Important**: We use TCP mode (not VHOST) because VMs have their own IPs on the TAP/bridge network. VHOST mode requires `vhost_vsock` kernel module and per-VM CID numbers, which adds unnecessary complexity.

- [ ] **2.2 Create host networking setup function** in `scripts/qemu/start-mesh.sh`:
  - Creates the Linux bridge and TAP devices before launching VMs:
    ```bash
    setup_host_networking() {
      # Create bridge for test bed management subnet
      ip link add name mesha-br0 type bridge 2>/dev/null || true
      ip link set mesha-br0 type bridge stp_state 0 forward_delay 0 2>/dev/null || true
      ip addr add 10.99.0.254/16 dev mesha-br0 2>/dev/null || true
      ip link set mesha-br0 up

      # Create TAP devices for each VM (4 VMs)
      for i in 0 1 2 3; do
        ip tuntap add dev mesha-tap${i} mode tap user $(whoami) 2>/dev/null || true
        ip link set mesha-tap${i} master mesha-br0 2>/dev/null || true
        ip link set mesha-tap${i} up
      done
    }
    ```
  - Requires the user running the script to have `CAP_NET_ADMIN` (typically via `sudo` for these operations, or run as root in CI)
  - Idempotent: uses `2>/dev/null || true` to avoid errors if devices already exist
  - The host IP 10.99.0.254 serves as:
    - SSH gateway to reach any VM
    - vwifi-server relay endpoint at 10.99.0.254:8212 (TCP primary port, server binds INADDR_ANY)
    - Default gateway for VMs if needed

- [ ] **2.3 Create VM launch script** at `scripts/qemu/start-mesh.sh`:
  - Reads topology from `config/topology.yaml` (3 LibreMesh nodes + 1 tester)
  - Calls `setup_host_networking()` before launching VMs
  - For each VM, creates a qcow2 overlay backed by the base image:
    ```bash
    qemu-img create -f qcow2 -b images/libremesh-x86-64-base.img \
      -F raw run/node-{N}.qcow2
    ```
    (Base image from BuildRoot is raw ext4, not qcow2 — must specify `-F raw`)
  - Launches each VM with TAP networking for mesh0 and user-mode for wan0:
    ```bash
    qemu-system-x86_64 \
      ${ACCEL} -M q35 ${CPU} -smp 2 -m ${RAM_MB}M \
      -nographic \
      -drive file=run/node-${N}.qcow2,format=qcow2 \
      -device virtio-net-pci,netdev=mesh0,mac=${MAC_MESH} \
      -netdev tap,id=mesh0,ifname=mesha-tap${TAP_INDEX},script=no,downscript=no \
      -device virtio-net-pci,netdev=wan0,mac=${MAC_WAN} \
      -netdev user,id=wan0
    ```
  - KVM/TCG detection and CPU selection:
    ```bash
    if [ -w /dev/kvm ]; then
      ACCEL="-enable-kvm"
      CPU="-cpu host"
    else
      ACCEL="-accel tcg"
      CPU="-cpu qemu64"  # -cpu host requires KVM, will fail with TCG
      QEMU_TIMEOUT_MULTIPLIER=3
    fi
    ```
  - Key differences from v1:
    - mesh0 uses `-netdev tap` instead of `-netdev user` — VMs share L2 via bridge
    - No `hostfwd` port forwarding needed — host reaches VMs directly at 10.99.0.x
    - No `net=` parameter on mesh0 — IP addressing is configured inside each VM
  - KVM detection: if `/dev/kvm` unavailable, uses `-accel tcg` with `-cpu qemu64` (not `-cpu host` which requires KVM) and sets `QEMU_TIMEOUT_MULTIPLIER=3`
  - Each VM runs in background with PID tracked in `run/node-{N}.pid`

- [ ] **2.4 Create concurrent run protection** at the top of `start-mesh.sh`:
  - Uses `mkdir`-based lock file (atomic on all Linux filesystems):
    ```bash
    LOCKFILE=run/testbed.lock
    if ! mkdir "$LOCKFILE" 2>/dev/null; then
      echo "ERROR: Test bed already running (PID $(cat $LOCKFILE/pid 2>/dev/null || echo 'unknown'))"
      echo "Run 'bash scripts/qemu/stop-mesh.sh' first, or remove $LOCKFILE manually."
      exit 1
    fi
    echo $$ > "$LOCKFILE/pid"
    trap 'rm -rf "$LOCKFILE"' EXIT
    ```
  - The lock is automatically released when the script exits (any reason)
  - `stop-mesh.sh` also removes the lock as part of cleanup
  - Prevents port conflicts, duplicate TAP devices, and resource exhaustion
  - Lock file persists across reboots (stored in repo workspace, not `/tmp`)

- [ ] **2.5 Create process supervision and cleanup** in `start-mesh.sh`:
  - Tracks all QEMU PIDs and vwifi-server PID in an array
  - Sets up comprehensive trap handler for cleanup on any exit:
    ```bash
    QEMU_PIDS=()
    VWIFI_PID=""
    CLEANUP_DONE=false

    cleanup() {
      if $CLEANUP_DONE; then return; fi
      CLEANUP_DONE=true
      echo "Cleaning up test bed..."

      # Kill all QEMU VMs
      for pid in "${QEMU_PIDS[@]}"; do
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
      done

      # Kill vwifi-server
      [ -n "$VWIFI_PID" ] && kill "$VWIFI_PID" 2>/dev/null

      # Clean up TAP devices and bridge
      for i in 0 1 2 3; do
        ip link set mesha-tap${i} down 2>/dev/null || true
        ip link set mesha-tap${i} nomaster 2>/dev/null || true
        ip tuntap del dev mesha-tap${i} mode tap 2>/dev/null || true
      done
      ip link del mesha-br0 2>/dev/null || true

      # Clean up PID files
      rm -f run/*.pid

      # Remove lock
      rm -rf run/testbed.lock

      echo "Cleanup complete."
    }
    trap cleanup EXIT INT TERM HUP
    ```
  - Cleanup is idempotent — safe to call multiple times
  - `CLEANUP_DONE` flag prevents double-cleanup on nested signals

- [ ] **2.6 Create VM configuration injection script** at `scripts/qemu/configure-vms.sh`:
  - Waits for SSH availability on each VM at its 10.99.0.x address (with timeout, adjusted for TCG)
  - OpenWrt default: root login with no password over SSH — no key injection needed for initial connection
  - First SSH connection configures each VM:
    - Sets hostname (`lm-testbed-node-{N}`)
    - Configures mesh interface IP: `10.99.0.{10+N}/16` on the TAP-connected interface
    - Loads mac80211_hwsim with zero radios: `modprobe mac80211_hwsim radios=0`
    - Creates virtual WiFi interfaces: `vwifi-add-interfaces 2 52:54:00:02:{N}:00` (2 interfaces per VM, unique MAC prefix — vwifi-add-interfaces uses this as a base MAC and appends/increments per interface)
    - Configures vwifi-client via UCI (not direct CLI):
      ```
      uci set vwifi.config.server_ip='10.99.0.254'
      uci set vwifi.config.mac_prefix='52:54:00:02:{N}'
      uci set vwifi.config.enabled='1'
      uci commit vwifi
      ```
    - Starts vwifi-client service: `service vwifi-client start`
    - Creates lime-community UCI config template (shared across all VMs):
      ```
      uci set lime-community.wifi.ap_ssid='MeshaTestBed'
      uci set lime-community.wifi.apname='MeshaTestBed'
      uci set lime-community.wifi.mode='adhoc'
      uci set lime-community.wifi.channel='11'
      uci set lime-community.network.protocols='bmx7'
      uci set lime-community.system.domain='testbed.mesh'
      uci set lime-community.system.hostname='lm-testbed-node-{N}'
      uci commit lime-community
      ```
    - Creates lime-node UCI config (per-node overrides):
      ```
      uci set lime-node.network.main_ipv4_address="10.99.0.{10+N}/16"
      uci commit lime-node
      ```
    - Runs the LibreMesh configuration sequence (CRITICAL — matches upstream `setup-vm.sh` from `VGDSpehar/libremesh-virtual-mesh`):
      ```bash
      service vwifi-client start
      wifi config
      lime-config
      wifi down
      sleep 7
      wifi up
      ```
    - **Why this sequence matters:** `lime-config` reads `lime-community` + `lime-node` templates and generates ALL UCI sections for network, wireless, and BMX7. Without it: BMX7 won't be configured on any interface, WiFi interfaces won't have mesh settings, and `validate-node.sh` Check 4 will fail. The upstream `setup-vm.sh` uses this exact sequence.
    - Enables uhttpd for HTTP access
    - Sets up `/etc/openwrt_release` with test firmware version
    - Sets up `/etc/hosts` with all mesh node entries:
      ```
      10.99.0.11  lm-testbed-node-1
      10.99.0.12  lm-testbed-node-2
      10.99.0.13  lm-testbed-node-3
      10.99.0.14  lm-testbed-tester
      ```
  - After basic config, injects SSH key for passwordless key-based access going forward:
    ```bash
    # Generate test key pair (gitignored)
    mkdir -p run/ssh-keys
    ssh-keygen -t ed25519 -f run/ssh-keys/id_ed25519 -N "" -C "mesha-testbed"

    # Inject public key into each VM via password SSH
    for N in 1 2 3 4; do
      IP="10.99.0.$((10+N))"
      ssh -o StrictHostKeyChecking=no -o BatchMode=no root@${IP} \
        "mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
         echo '$(cat run/ssh-keys/id_ed25519.pub)' >> /root/.ssh/authorized_keys && \
         chmod 600 /root/.ssh/authorized_keys && \
         uci set dropbear.@dropbear[0].PasswordAuth='off' && \
         uci commit dropbear && \
         /etc/init.d/dropbear restart"
    done
    ```
  - This two-phase approach (password first, then key) works because:
    1. OpenWrt ships with dropbear allowing root login with empty password by default
    2. First SSH uses password auth (empty password)
    3. After key injection, lock down to key-only auth via dropbear UCI (`PasswordAuth='off'`)
    - **Note:** OpenWrt uses dropbear, not openssh-server. Dropbear doesn't use `/etc/ssh/sshd_config` — it's configured via UCI (`uci set dropbear.@dropbear[0].PasswordAuth='off'`).
    - Installs `jq`, `python3`, `ssh`, `curl`, `ip-full`
    - Deploys Mesha workspace (or relevant adapter subset)
    - Tester VM can reach all other VMs via 10.99.0.x (TAP/bridge)

- [ ] **2.7 Create teardown script** at `scripts/qemu/stop-mesh.sh`:
  - Kills all QEMU processes by PID from `run/*.pid`
  - Kills vwifi-server
  - Cleans up TAP devices and bridge (same cleanup function as start-mesh.sh trap)
  - Removes qcow2 overlays and PID files
  - Removes lock file
  - Preserves base image and any logs
  - Idempotent — safe to run even if nothing is running

- [ ] **2.8 Create status script** at `scripts/qemu/mesh-status.sh`:
  - Reports which VMs are running (checks PID files and process existence)
  - Tests SSH connectivity to each VM at 10.99.0.x
  - Shows vwifi-server status
  - Shows bridge and TAP device status
  - Outputs JSON for programmatic consumption

- [ ] **2.9 Create topology configuration file** at `config/topology.yaml`:
  ```yaml
  mesh:
    nodes:
      - id: 1
        hostname: lm-testbed-node-1
        ip: 10.99.0.11
        tap_index: 0
        mac_mesh: "52:54:00:00:00:01"
        mac_wan: "52:54:00:01:00:01"
        role: gateway
        ram_mb: 256
      - id: 2
        hostname: lm-testbed-node-2
        ip: 10.99.0.12
        tap_index: 1
        mac_mesh: "52:54:00:00:00:02"
        mac_wan: "52:54:00:01:00:02"
        role: relay
        ram_mb: 256
      - id: 3
        hostname: lm-testbed-node-3
        ip: 10.99.0.13
        tap_index: 2
        mac_mesh: "52:54:00:00:00:03"
        mac_wan: "52:54:00:01:00:03"
        role: leaf
        ram_mb: 256
      - id: 4
        hostname: lm-testbed-tester
        ip: 10.99.0.14
        tap_index: 3
        mac_mesh: "52:54:00:00:00:04"
        mac_wan: "52:54:00:01:00:04"
        role: tester
        ram_mb: 512
    vwifi:
      server_port: 8211  # VHOST port (unused in TCP mode)
      tcp_port: 8212     # TCP primary (vwifi-server default)
      spy_port: 8213     # Spy port
      control_port: 8214 # Control port
      listen_address: "10.99.0.254"  # Host bridge IP — informational only; vwifi-server binds INADDR_ANY
      packet_loss: 0.0  # 0.0 to 1.0 (global, set via -l flag at launch)
    network:
      bridge_name: "mesha-br0"
      bridge_ip: "10.99.0.254"
      management_subnet: "10.99.0.0/16"
      tap_prefix: "mesha-tap"
      thisnode_alias: "lm-testbed-node-1"  # VM1 acts as thisnode.info
  ```

- [ ] **2.10 Create `testbed/.gitignore`** to exclude:
  ```
  run/
  images/*.img
  images/*.img.gz
  bin/
  ssh-keys/
  ```

### Step-by-Step Test Gates: Phase 2

**Gate 2.1: vwifi-server compiles and starts**
- **Action:** Run `bash scripts/qemu/start-vwifi.sh`
- **Expected:** `bin/vwifi-server` exists and process is listening on port 8212 (TCP primary)
- **Test command:** `ss -tlnp | grep 8212` shows LISTEN state (TCP primary port)
- **Diagnosis on failure:**
  - Compilation error: check `cmake`, `g++`, `pkg-config`, `libnl-3-dev`, `libnl-genl-3-dev` are installed
  - `pkg-config` not found: `sudo apt install pkg-config`
  - Binary not created: check `bin/` directory permissions
  - Port bind error: another process using 8212; `lsof -i :8212` to find it
  - PID file not created: check `run/` directory exists

**Gate 2.2: Host networking is configured**
- **Action:** Run `setup_host_networking()` from `start-mesh.sh` (or the full script)
- **Expected:** Bridge `mesha-br0` exists with IP 10.99.0.254/16; 4 TAP devices attached
- **Test command:**
  ```bash
  ip addr show mesha-br0 | grep '10.99.0.254/16'
  ip link show mesha-tap0 | grep 'master mesha-br0'
  ip link show mesha-tap1 | grep 'master mesha-br0'
  ip link show mesha-tap2 | grep 'master mesha-br0'
  ip link show mesha-tap3 | grep 'master mesha-br0'
  ```
- **Expected:** All 5 commands succeed
- **Diagnosis on failure:**
  - `Operation not permitted`: need `sudo` or `CAP_NET_ADMIN`
  - Bridge already exists: idempotent — should succeed with `|| true`
  - TAP not attached to bridge: check `ip link set mesha-tap0 master mesha-br0` manually

**Gate 2.3: All 4 VMs boot and get IPs**
- **Action:** Run `bash scripts/qemu/start-mesh.sh` (after Gate 2.1 and 2.2)
- **Expected:** 4 QEMU processes running; each VM's serial log shows boot completion
- **Test command:**
  ```bash
  # Check all PIDs exist
  for i in 1 2 3 4; do
    pid=$(cat run/node-${i}.pid 2>/dev/null)
    kill -0 $pid 2>/dev/null && echo "VM${i}: RUNNING (PID $pid)" || echo "VM${i}: NOT RUNNING"
  done
  # Verify serial logs are being captured
  for i in 1 2 3 4; do
    test -s run/logs/node-${i}.serial.log && echo "VM${i}: serial log OK" || echo "VM${i}: serial log MISSING"
  done
  ```
- **Expected:** All 4 report RUNNING and all 4 have non-empty serial logs
- **Timeout:** 90 seconds with KVM, 270 seconds with TCG
- **Diagnosis on failure:**
  - VM not running: check serial output in `run/logs/node-{N}.serial.log`
  - Boot timeout: increase timeout or reduce VM RAM; check KVM availability (`ls /dev/kvm`)
  - Image not found: verify Gate 1.1 passed; check qcow2 overlay creation
  - Serial log empty: QEMU launch missing `-serial file:run/logs/node-{N}.serial.log` argument

**Gate 2.4: SSH connectivity from host to all VMs**
- **Action:** Run `bash scripts/qemu/configure-vms.sh`
- **Expected:** Script configures IPs and injects SSH keys; all VMs respond to SSH
- **Test command:**
  ```bash
  for ip in 10.99.0.11 10.99.0.12 10.99.0.13 10.99.0.14; do
    ssh -o StrictHostKeyChecking=no -i run/ssh-keys/id_ed25519 root@${ip} 'hostname' 2>/dev/null \
      && echo "${ip}: SSH OK" || echo "${ip}: SSH FAIL"
  done
  ```
- **Expected:** `lm-testbed-node-1`, `lm-testbed-node-2`, `lm-testbed-node-3`, `lm-testbed-tester` printed
- **Diagnosis on failure:**
  - All fail: bridge not configured (Gate 2.2 failed); check `ip addr show mesha-br0`
  - Some fail: specific VM didn't get IP; SSH into it via QEMU monitor and check `uci show network`
  - Key rejected: re-run `configure-vms.sh` key injection step
  - Connection refused: dropbear not running in VM; `ssh root@${ip} '/etc/init.d/dropbear start'`

**Gate 2.5: Inter-VM connectivity works**
- **Action:** SSH into VM1 and test connectivity to VM2 via both IPv4 and IPv6
- **Test command:**
  ```bash
  # IPv4 test (works over TAP/bridge — ICMPv4 limitation only applies to QEMU user-mode networking)
  ssh -i run/ssh-keys/id_ed25519 root@10.99.0.11 'ping -c 3 10.99.0.12' 2>/dev/null
  # IPv6 test (always works between QEMU nodes per VIRTUALIZING.md)
  ssh -i run/ssh-keys/id_ed25519 root@10.99.0.11 'ping6 -c 3 -I eth0 fe80::5054:00ff:fe00:2' 2>/dev/null || true
  ```
- **Expected:** IPv4 ping: `3 packets transmitted, 3 received, 0% packet loss`
- **Note:** IPv6 link-local addresses use the MAC-based EUI-64 format. For VM2's MAC `52:54:00:00:00:02`: split at byte 3 (`52:54:00` | `00:00:02`), insert `ff:fe` (`52:54:00:ff:fe:00:00:02`), flip U/L bit (`52` XOR `0x02` = `50`), giving link-local `fe80::5054:00ff:fe00:2`. If IPv4 ping fails but SSH works, the issue is likely firewall rules on the management interface — LibreMesh may have iptables rules that block ICMP. In that case, SSH connectivity is sufficient proof of inter-VM communication.
- **Important:** The ICMPv4 limitation documented in VIRTUALIZING.md only applies to QEMU user-mode networking. Our TAP/bridge approach should support ICMPv4 because all VMs are on the same real L2 segment. If ICMPv4 doesn't work, SSH connectivity is the alternative proof.
- **Diagnosis on failure:**
  - 100% packet loss: VMs not on same L2; verify bridge: `brctl show mesha-br0`
  - SSH works but ping fails: iptables/firewall blocking ICMP; this is acceptable — use SSH as connectivity proof
  - Network unreachable: VM's mesh interface not configured; check `ssh root@10.99.0.11 'ip addr show eth0'`
**Gate 2.6: vwifi-client connects to vwifi-server**
- **Action:** Check vwifi-client status on each VM
- **Test command:**
  ```bash
  for ip in 10.99.0.11 10.99.0.12 10.99.0.13; do
    echo "--- ${ip} ---"
    ssh -i run/ssh-keys/id_ed25519 root@${ip} '
      uci show vwifi.config.server_ip;
      logread | grep vwifi | tail -3;
      iw dev | grep -i Interface || iwconfig 2>/dev/null | grep -i wlan;
    ' 2>/dev/null
  done
  ```
- **Expected:** Each VM shows `vwifi.config.server_ip='10.99.0.254'`, recent vwifi log entries, and wlan interfaces
- **Diagnosis on failure:**
  - `uci: entry not found`: vwifi-client package not installed (Gate 1.5 failed)
  - No wlan interfaces: `vwifi-add-interfaces` didn't run; check `lsmod | grep mac80211`
  - Connection refused to server: vwifi-server not running (Gate 2.1 failed)
  - `mac80211_hwsim` loaded with radios > 0: reload with `modprobe -r mac80211_hwsim && modprobe mac80211_hwsim radios=0`
  - **Note:** Use `iw dev` (not `iwconfig`) as OpenWrt typically has `iw` but not `iwconfig`. Fallback to `iwconfig` if `iw` is unavailable.
  - **Note:** vwifi-client connects to the server at port 8212 (TCP/INET), not 8211 (VHOST). The UCI `server_ip` config only sets the IP address; the port is determined by vwifi-client's default (`DEFAULT_WIFI_CLIENT_PORT_INET = 8212`).

**Gate 2.7: Concurrent run protection works**
- **Action:** Run `start-mesh.sh` a second time while first instance is running
- **Expected:** Second run exits immediately with error: "Test bed already running"
- **Test command:** `bash scripts/qemu/start-mesh.sh 2>&1 | grep -q 'already running'`
- **Diagnosis on failure:** Lock directory `run/testbed.lock` not created or removed prematurely

**Gate 2.8: Teardown cleans up everything**
- **Action:** Run `bash scripts/qemu/stop-mesh.sh`
- **Expected:**
  - No QEMU processes running: `pgrep -c qemu-system` returns 0
  - No vwifi-server running: `pgrep -c vwifi-server` returns 0
  - No TAP devices: `ip link show mesha-tap0` fails with "Device not found"
  - No bridge: `ip link show mesha-br0` fails with "Device not found"
  - Lock removed: `test -d run/testbed.lock` returns 1
- **Test command:**
  ```bash
  bash scripts/qemu/stop-mesh.sh
  pgrep qemu-system && echo "FAIL: orphaned QEMU" || echo "OK: no QEMU"
  pgrep vwifi-server && echo "FAIL: orphaned vwifi" || echo "OK: no vwifi"
  ip link show mesha-br0 2>/dev/null && echo "FAIL: bridge remains" || echo "OK: bridge gone"
  test -d run/testbed.lock && echo "FAIL: lock remains" || echo "OK: lock gone"
  ```
- **Diagnosis on failure:**
  - Orphaned QEMU: `kill $(cat run/*.pid)` manually; then `stop-mesh.sh` again
  - Bridge remains: `sudo ip link del mesha-br0` manually
  - Lock remains: `rm -rf run/testbed.lock` manually

**Risks:**
1. **vwifi-server compilation issues** — Mitigation: Pre-compile for common platforms; cache binary in `bin/`
2. **TCG performance too slow** — Mitigation: Reduce to 2 LibreMesh VMs + 1 tester in TCG mode; document minimum viable topology
3. **TAP/bridge setup requires root/CAP_NET_ADMIN** — Mitigation: Document requirement; CI runners typically have this capability; provide `sudo` wrapper for local dev
4. **Bridge/TAP cleanup fails after crash** — Mitigation: `stop-mesh.sh` performs force cleanup; trap handler covers normal exits; document manual cleanup command

---

### Phase 3: Mesha Adapter Integration

**Goal:** Make Mesha's existing adapter scripts (`collect-nodes.sh`, `collect-topology.sh`, `discover-from-thisnode.sh`, `validate-node.sh`) work against the QEMU test bed VMs.

- [ ] **3.1 Create test bed inventory files** at `config/inventories/`:
  - `mesh-nodes.yaml` with hostnames and IPs matching VM configuration (10.99.0.x)
  - `gateways.yaml` pointing to node-1 as gateway
  - `sites.yaml` with test bed site definition
  - These replace the Docker fixture inventories for QEMU tests

- [ ] **3.1b Create test bed path wrapper** at `scripts/qemu/run-testbed-adapter.sh`:
  - Mesha's adapter scripts have hardcoded paths:
    - `run-mesh-readonly.sh:23-24` reads `$REPO_ROOT/inventories/mesh-nodes.yaml`
    - `skills/mesh-rollout/scripts/validate-node.sh:68` reads `${WORKSPACE_ROOT}/desired-state/mesh/firmware-policy.yaml` (firmware version check at lines 109-121)
    - `scripts/discover-from-thisnode.sh:19` hardcodes `TARGET_HOST="thisnode.info"`
  - This wrapper:
    - Symlinks or copies testbed inventories to `$REPO_ROOT/inventories/` (backing up originals)
    - Symlinks testbed desired-state to `$REPO_ROOT/desired-state/mesh/`
    - Restores originals on exit via trap handler
  - Alternative: set `REPO_ROOT` env var and use testbed config dir directly (if adapter scripts support it)

- [ ] **3.2 Configure DNS/hostname resolution:**
  - Each VM already has `/etc/hosts` configured (Phase 2.6) with all mesh node entries
  - Create `config/ssh-config` for host-side access:
    ```
    Host lm-testbed-node-1
      HostName 10.99.0.11
      User root
      IdentityFile ABSOLUTE_PATH/run/ssh-keys/id_ed25519  # Generate at runtime with $(pwd)/run/ssh-keys/id_ed25519
      StrictHostKeyChecking no

    Host lm-testbed-node-2
      HostName 10.99.0.12
      User root
      IdentityFile ABSOLUTE_PATH/run/ssh-keys/id_ed25519
      StrictHostKeyChecking no

    Host lm-testbed-node-3
      HostName 10.99.0.13
      User root
      IdentityFile ABSOLUTE_PATH/run/ssh-keys/id_ed25519
      StrictHostKeyChecking no

    Host lm-testbed-tester
      HostName 10.99.0.14
      User root
      IdentityFile ABSOLUTE_PATH/run/ssh-keys/id_ed25519
      StrictHostKeyChecking no
    ```
  - No port forwarding needed — direct IP access via bridge

- [ ] **3.3 Ensure `ip -j addr show` works in VMs (GAP 4 critical fix):**
  - Verify `ip-full` package is included in the build (Phase 1)
  - Add test assertion that `ip -j addr show` returns valid JSON
  - If BusyBox ip is the only option, create a wrapper script at `/usr/local/bin/ip` that calls the real binary

- [ ] **3.4 Configure thisnode.info HTTP discovery (GAP 16):**
  - On VM1 (`lm-testbed-node-1`), configure uhttpd to listen on port 80
  - Add `thisnode.info` to VM1's `/etc/hosts` pointing to 10.99.0.11
  - **Also add `thisnode.info → 10.99.0.11` to the HOST machine's `/etc/hosts`** — `discover-from-thisnode.sh:19` hardcodes `TARGET_HOST="thisnode.info"` and runs from the host
  - **Alternative (no sudo):** Use `HOSTALIASES` env var (`echo "thisnode.info 10.99.0.11" > run/host-aliases && export HOSTALIASES=run/host-aliases`) or `curl --resolve thisnode.info:80:10.99.0.11` for HTTP tests. Note: `HOSTALIASES` doesn't work with all commands (e.g., `ping` ignores it).
  - From the tester VM or host, `curl http://thisnode.info/` returns a page from VM1's uhttpd
  - Configure tester VM's `/etc/hosts` with `thisnode.info → 10.99.0.11`

- [ ] **3.5 Create adapter validation script** at `scripts/qemu/validate-adapters.sh`:
  - Runs `collect-nodes.sh` against each VM hostname (using test bed inventories)
  - Runs `collect-topology.sh` against the gateway VM
  - Runs `discover-from-thisnode.sh` against VM1's thisnode.info
  - Validates that each adapter returns valid JSON with expected fields
  - Reports PASS/FAIL per adapter

- [ ] **3.6 Create test bed desired-state files** at `config/desired-state/`:
  - `mesh/firmware-policy.yaml` matching the built firmware version
  - `mesh/community-profile/` with test community settings
  - These enable testing `validate-node.sh` drift detection

### Step-by-Step Test Gates: Phase 3

**Gate 3.1: Test bed inventory files are valid**
- **Action:** Create `config/inventories/mesh-nodes.yaml` with 4 nodes
- **Expected:** YAML parses correctly and matches VM IPs from `topology.yaml`
- **Prerequisite:** Host has `python3` and `pyyaml` installed (`pip install pyyaml` or `sudo apt install python3-yaml`)
- **Test command:**
  ```bash
  python3 -c "
  import yaml, sys
  inv = yaml.safe_load(open('config/inventories/mesh-nodes.yaml'))
  topo = yaml.safe_load(open('config/topology.yaml'))
  inv_ips = {n['hostname']: n['ip'] for n in inv['nodes']}
  topo_ips = {n['hostname']: n['ip'] for n in topo['mesh']['nodes']}
  assert inv_ips == topo_ips, f'Mismatch: {inv_ips} vs {topo_ips}'
  print('OK: inventory matches topology')
  "
  ```
- **Diagnosis on failure:** Hostnames or IPs in inventory don't match `topology.yaml`; align them

**Gate 3.1b: Host dependencies are available**
- **Action:** Verify all host-side tools needed by adapter scripts are installed
- **Test command:**
  ```bash
  # collect-nodes.sh needs: ssh, jq, python3
  which ssh && echo 'ssh: OK' || echo 'ssh: MISSING'
  which jq && echo 'jq: OK' || echo 'jq: MISSING'
  which python3 && echo 'python3: OK' || echo 'python3: MISSING'
  # discover-from-thisnode.sh needs: curl, ssh, python3
  which curl && echo 'curl: OK' || echo 'curl: MISSING'
  ```
- **Expected:** All 4 commands found
- **Diagnosis on failure:** Install missing tools: `sudo apt install openssh-client jq python3 curl`

**Gate 3.2: SSH config works for all VMs**
- **Action:** Use `config/ssh-config` to connect to each VM
- **Test command:**
  ```bash
  for host in lm-testbed-node-1 lm-testbed-node-2 lm-testbed-node-3 lm-testbed-tester; do
    ssh -F config/ssh-config ${host} 'hostname' 2>/dev/null \
      && echo "${host}: OK" || echo "${host}: FAIL"
  done
  ```
- **Expected:** Each host returns its hostname
- **Diagnosis on failure:**
  - `Could not resolve hostname`: add entries to `/etc/hosts` or use IP directly in ssh-config
  - `Connection refused`: VM not running or SSH not started
  - `Permission denied`: SSH key not injected; re-run `configure-vms.sh`

**Gate 3.3: `ip -j addr show` returns valid JSON**
- **Action:** SSH into VM1 and run `ip -j addr show`
- **Test command:**
  ```bash
  ssh -F config/ssh-config lm-testbed-node-1 'ip -j addr show' 2>/dev/null \
    | python3 -c "import sys,json; data=json.load(sys.stdin); assert len(data) > 1; print(f'OK: {len(data)} interfaces')"
  ```
- **Expected:** `OK: N interfaces` where N >= 2 (lo + at least one real interface)
- **Diagnosis on failure:**
  - Empty output: `ip-full` not installed; BusyBox `ip` doesn't support JSON
  - `python3` error: JSON parse failed; `ip -j` returned malformed output
  - Fix: rebuild image with `CONFIG_PACKAGE_ip-full=y` (Phase 1)

**Gate 3.4: `collect-nodes.sh` returns valid data**
- **Action:** Run adapter against VM1 using test bed inventory
- **Test command:**
  ```bash
  bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-nodes.sh lm-testbed-node-1
  ```
- **Expected:** JSON output with `reachable: true`, `hostname: lm-testbed-node-1`, non-empty `interfaces` array
- **Test command (parse result):**
  ```bash
  RESULT=$(bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-nodes.sh lm-testbed-node-1)
  echo "$RESULT" | python3 -c "
  import sys, json
  data = json.load(sys.stdin)
  assert data.get('reachable') == True, f'Not reachable: {data}'
  assert 'hostname' in data, f'Missing hostname: {data}'
  assert 'interfaces' in data and len(data['interfaces']) > 0, f'Missing interfaces: {data}'
  print(f'OK: hostname={data["hostname"]}, interfaces={len(data["interfaces"])}')
  "
  ```
- **Diagnosis on failure:**
  - `reachable: false`: SSH connection failed; check Gate 3.2
  - Empty interfaces: `ip -j addr show` not working; check Gate 3.3
  - Script error: check `run-testbed-adapter.sh` symlinked inventories correctly

**Gate 3.5: `collect-topology.sh` returns valid data**
- **Action:** Run topology collection against gateway (VM1)
- **Test command:**
  ```bash
  RESULT=$(bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-topology.sh lm-testbed-node-1)
  echo "$RESULT" | python3 -c "
  import sys, json
  data = json.load(sys.stdin)
  assert 'node_count' in data, f'Missing node_count: {data}'
  assert data['node_count'] >= 1, f'No nodes in topology: {data}'
  print(f'OK: {data["node_count"]} nodes in topology')
  "
  ```
- **Expected:** `node_count >= 1` (may not see all 3 nodes yet if BMX7 hasn't converged)
- **Note:** Full mesh convergence (`node_count >= 3`) is tested in Phase 4; Phase 3 just validates the adapter can connect and parse output
- **Note:** `collect-topology.sh` uses `python3` (not `jq`) for JSON construction (`collect-topology.sh:70,153`). It also uses `nc` for babeld fallback (`collect-topology.sh:118`). Verify both are available.
- **IPv6 parser fix required:** `collect-topology.sh:203` and `collect-topology.sh:222` only match IPv4 (`\d+.\d+.\d+.\d+`). BMX7 in LibreMesh may use IPv6 link-local addresses for both originators and links. If `node_count` stays at 1 (self only), apply this fix to both locations in the adapter script:
  ```bash
  # Current (IPv4 only):
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
  # Fixed (IPv4 + IPv6):
  grep -oE '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|[0-9a-fA-F:]+:[0-9a-fA-F]+)'
  ```
  Alternatively, use `bmx7 -c --jshow originators` (JSON output) if available in the installed BMX7 version, which avoids regex parsing entirely. This fix should be a separate commit to the adapter script, not a test bed workaround.
- **Diagnosis on failure:**
  - `node_count: 0`: BMX7 not running or no neighbors; check `ssh root@10.99.0.11 'bmx7 -c originators'`
  - `node_count: 1` (only self): BMX7 hasn't converged yet; wait 30-60s and re-run. If persistent, check if BMX7 uses IPv6 addresses the parser doesn't match
  - Script error: check BMX7 is installed and running on VM1
  - JSON parse error: adapter output format changed; examine raw output

**Gate 3.6: `discover-from-thisnode.sh` works**
- **Action:** Run discovery against VM1's thisnode.info
- **Prerequisite:** Host `/etc/hosts` has `10.99.0.11 thisnode.info`; VM1 uhttpd is running on port 80; host has `curl` installed
- **Test command:**
  ```bash
  # Verify host resolution first
  ping -c 1 thisnode.info 2>/dev/null | grep '10.99.0.11'
  # Verify HTTP response
  curl -s -o /dev/null -w '%{http_code}' http://thisnode.info/ 2>/dev/null
  # Run the actual discovery script
  bash scripts/discover-from-thisnode.sh 2>&1 | tail -5
  # Verify output files were created
  test -f exports/discovery/latest.json && echo 'OK: latest.json created' || echo 'FAIL: no output'
  cat exports/discovery/latest.json | python3 -c "
  import sys, json
  data = json.load(sys.stdin)
  assert data.get('http_ok') or data.get('ssh_ok'), f'Neither HTTP nor SSH worked: {data}'
  print(f'OK: http_ok={data.get("http_ok")}, ssh_ok={data.get("ssh_ok")}')
  "
  ```
- **Expected:** `thisnode.info` resolves to 10.99.0.11; HTTP returns 200 or 302; discovery script completes; `exports/discovery/latest.json` has `http_ok: true` or `ssh_ok: true`
- **Diagnosis on failure:**
  - `ping` fails: add `10.99.0.11 thisnode.info` to host `/etc/hosts`, or use `HOSTALIASES` env var / `curl --resolve` alternative (see Phase 3.4)
  - HTTP 000: uhttpd not running on VM1; `ssh root@10.99.0.11 '/etc/init.d/uhttpd start'`
  - Discovery script fails: check `TARGET_HOST` variable in script matches `thisnode.info`
  - `latest.json` not created: check `exports/discovery/` directory permissions

**Gate 3.7: `validate-node.sh` reports health**
- **Action:** Run node validation against VM1
- **Prerequisite:** VM1 has LibreMesh lime-packages installed and `lime-community` UCI config applied. Without this, Check 4 (Community SSID) will FAIL because `validate-node.sh:170` checks `uci get lime-community.wifi.ap_ssid`. For the test bed, configure a minimal lime-community config during `configure-vms.sh`.
- **Test command:**
  ```bash
  bash scripts/qemu/run-testbed-adapter.sh skills/mesh-rollout/scripts/validate-node.sh lm-testbed-node-1
  echo "Exit code: $?"
  ```
- **Expected:** Exit code 0 (all checks pass) or exit code 0 with WARN (if non-critical checks like error logs flag something). Exit code 1 means a FAIL.
- **Note:** `validate-node.sh` performs 6 checks (SSH, firmware version, mesh neighbors, community SSID, error logs, uptime). All must pass for exit 0. The firmware check (`validate-node.sh:109-121`) compares against `desired-state/mesh/firmware-policy.yaml` — the test bed copy must match the built image's `DISTRIB_RELEASE`.
- **Diagnosis on failure:**
  - SSH FAIL: check Gate 3.2
  - Firmware WARN/FAIL: `desired-state/mesh/firmware-policy.yaml` `approved_version` doesn't match VM's `/etc/openwrt_release` `DISTRIB_RELEASE`; update test bed copy
  - Mesh neighbors FAIL: BMX7 not running or no neighbors; wait for convergence
  - Community SSID FAIL: `lime-community` config not applied to VM; run `configure-vms.sh` lime-community setup
  - Error logs WARN: normal for fresh boot with vwifi; review log entries
  - Uptime WARN: VM just booted; wait > 60 seconds

**Risks:**
1. **BMX7 convergence takes longer in TCG mode** — Mitigation: Add configurable wait time before topology collection; retry with backoff
2. **vwifi-client doesn't create usable WiFi interfaces** — Mitigation: Fall back to wired mesh over TAP/bridge (BMX7 over ethernet works fine); test basic BMX7 without WiFi simulation
3. **Marker-delimited text protocol breaks with large output** — Mitigation: Limit output sizes in adapter scripts (already using `head -60` etc.)

---

### Phase 4: Test Suite

**Goal:** Create a comprehensive test suite that exercises Mesha's mesh operations against the QEMU test bed, with assertions appropriate for real mesh behavior (GAP 15).

- [ ] **4.1 Create test framework** at `tests/qemu/`:
  - `tests/qemu/common.sh` — shared functions: `wait_for_ssh()`, `wait_for_bmx7()`, `assert_json_field()`, `assert_json_gte()`
  - `tests/qemu/run-all.sh` — orchestrates all QEMU tests with setup/teardown

- [ ] **4.2 Create test: adapter contract tests** at `tests/qemu/test-adapters.sh`:
  - `test_collect_nodes_returns_valid_json` — runs `collect-nodes.sh` against each VM, asserts `reachable: true`, non-null hostname, valid interfaces array
  - `test_collect_topology_sees_all_nodes` — runs `collect-topology.sh` against gateway, asserts `node_count >= 3`
  - `test_discover_thisnode_works` — runs `discover-from-thisnode.sh`, asserts `http_ok: true`, `ssh_ok: true`
  - `test_ip_json_output` — asserts `ip -j addr show` returns parseable JSON with at least 1 non-lo interface

- [ ] **4.3 Create test: mesh protocol tests** at `tests/qemu/test-mesh-protocols.sh`:
  - `test_bmx7_neighbors_exist` — asserts each node has >=1 BMX7 neighbor
  - `test_bmx7_originators_cover_mesh` — asserts gateway sees >=3 originators
  - `test_mesh_routing_works` — pings from node-3 to node-1 via IPv6 AND IPv4 (both now work over bridge)
  - `test_babel_fallback_works` — stops BMX7 on one node, starts babeld, verifies `collect-nodes.sh` still returns neighbors

- [ ] **4.4 Create test: validate-node tests** at `tests/qemu/test-validate-node.sh`:
  - `test_validate_healthy_node` — runs `validate-node.sh` on a healthy VM, asserts exit code 0
  - `test_validate_detects_missing_ssid` — removes community SSID, asserts WARN or FAIL
  - `test_validate_detects_no_neighbors` — stops BMX7, asserts FAIL on neighbor check

- [ ] **4.5 Create test: configuration drift tests** at `tests/qemu/test-config-drift.sh`:
  - `test_drift_detection_finds_changed_channel` — changes WiFi channel on one node, runs drift comparison, asserts difference detected
  - `test_uci_write_succeeds` — writes a UCI value via SSH, reads it back, asserts match

- [ ] **4.6 Create test: topology manipulation tests** at `tests/qemu/test-topology-manipulation.sh`:
  - `test_vwifi_ctrl_distance_based_loss` — places VMs at distant coordinates via `vwifi-ctrl set CID X Y Z`, enables loss with `vwifi-ctrl loss yes`, sets small scale with `vwifi-ctrl scale 0.001`, verifies BMX7 link quality degrades due to distance-based packet loss (vwifi-ctrl only supports global on/off loss, not per-link or percentage)
  - `test_node_removal_detected` — stops one VM, verifies `collect-topology.sh` reports fewer nodes

- [ ] **4.7 Create assertion library** (GAP 15 resolution):
  - Range assertions: `assert_json_gte "$json" ".node_count" 3`
  - Presence assertions: `assert_json_not_null "$json" ".hostname"`
  - Settled assertions: `wait_until_json_gte "$json" ".node_count" 3 --timeout 60`
  - All assertions output TAP-compatible results for CI integration

### Step-by-Step Test Gates: Phase 4

**Gate 4.1: Test framework loads and TAP output is valid**
- **Action:** Run a single no-op test to verify framework
- **Test command:**
  ```bash
  source tests/qemu/common.sh
  echo "1..1" > /tmp/test-gate.tap
  pass "framework loads" && cat /tmp/test-gate.tap
  ```
- **Expected:** TAP output `ok 1 - framework loads`
- **Diagnosis on failure:** `common.sh` has syntax errors or missing functions

**Gate 4.2: Adapter contract tests all pass**
- **Action:** Run `tests/qemu/test-adapters.sh`
- **Expected:** All 4 tests pass:
  - `test_collect_nodes_returns_valid_json` — each VM returns `reachable: true`
  - `test_collect_topology_sees_all_nodes` — gateway sees `node_count >= 3`
  - `test_discover_thisnode_works` — HTTP and SSH both OK
  - `test_ip_json_output` — `ip -j addr show` returns valid JSON with >= 1 non-lo interface
- **Test command:** `bash tests/qemu/test-adapters.sh 2>&1 | tee /tmp/phase4-adapters.tap`
- **Expected output:**
  ```
  1..4
  ok 1 - test_collect_nodes_returns_valid_json
  ok 2 - test_collect_topology_sees_all_nodes
  ok 3 - test_discover_thisnode_works
  ok 4 - test_ip_json_output
  ```
- **Diagnosis on failure:**
  - Test 1 fails: check Phase 3 Gate 3.4
  - Test 2 fails: BMX7 hasn't converged; wait 30s and re-run
  - Test 3 fails: check Phase 3 Gate 3.6
  - Test 4 fails: check Phase 3 Gate 3.3

**Gate 4.3: Mesh protocol tests pass**
- **Action:** Run `tests/qemu/test-mesh-protocols.sh`
- **Expected:** All 4 tests pass:
  - `test_bmx7_neighbors_exist` — each node has >= 1 BMX7 neighbor
  - `test_bmx7_originators_cover_mesh` — gateway sees >= 3 originators
  - `test_mesh_routing_works` — node-3 can ping node-1 (IPv4 and/or IPv6)
  - `test_babel_fallback_works` — switching to babeld still produces neighbors
- **Test command:** `bash tests/qemu/test-mesh-protocols.sh 2>&1 | tee /tmp/phase4-protocols.tap`
- **Important:** These tests require BMX7 convergence (30-60s after VM boot). The test script should include `wait_for_bmx7()` with a 90s timeout.
- **Diagnosis on failure:**
  - Neighbors = 0: vwifi not relaying frames; check vwifi-server and vwifi-client logs
  - Ping fails: check inter-VM connectivity (Phase 2 Gate 2.5)
  - Babel fallback fails: `babeld` not installed; check Phase 1 package list

**Gate 4.4: Validate-node tests pass**
- **Action:** Run `tests/qemu/test-validate-node.sh`
- **Expected:** All 3 tests pass:
  - `test_validate_healthy_node` — exit code 0 on healthy VM
  - `test_validate_detects_missing_ssid` — WARN or FAIL after removing SSID
  - `test_validate_detects_no_neighbors` — FAIL after stopping BMX7
- **Test command:** `bash tests/qemu/test-validate-node.sh 2>&1 | tee /tmp/phase4-validate.tap`
- **Diagnosis on failure:**
  - Healthy node fails: check Phase 3 Gate 3.7
  - Drift not detected: validate-node.sh threshold too lenient; check desired-state files
  - BMX7 stop doesn't trigger FAIL: validate-node.sh doesn't check neighbors; add neighbor check

**Gate 4.5: Config drift tests pass**
- **Action:** Run `tests/qemu/test-config-drift.sh`
- **Expected:** Both tests pass:
  - `test_drift_detection_finds_changed_channel` — drift detected after channel change
  - `test_uci_write_succeeds` — UCI write and read-back match
- **Test command:** `bash tests/qemu/test-config-drift.sh 2>&1 | tee /tmp/phase4-drift.tap`
- **Diagnosis on failure:**
  - UCI write fails: SSH session issues; check Gate 3.2
  - Drift not detected: drift comparison logic doesn't check the changed field

**Gate 4.6: Topology manipulation tests pass**
- **Action:** Run `tests/qemu/test-topology-manipulation.sh`
- **Expected:** Both tests pass:
  - `test_vwifi_ctrl_distance_based_loss` — BMX7 link quality degrades after enabling distance-based loss via vwifi-ctrl coordinates and scale
  - `test_node_removal_detected` — topology reports fewer nodes after stopping one VM
- **Test command:** `bash tests/qemu/test-topology-manipulation.sh 2>&1 | tee /tmp/phase4-topology.tap`
- **Diagnosis on failure:**
  - vwifi-ctrl not found: compile from vwifi repo; it's part of the vwifi project
  - Quality doesn't degrade: BMX7 metrics update slowly; increase wait time
  - Node removal not detected: `collect-topology.sh` caches results; add cache invalidation

**Gate 4.7: Full test suite runs in time budget**
- **Action:** Run `tests/qemu/run-all.sh` with timing
- **Test command:** `time bash tests/qemu/run-all.sh 2>&1 | tee /tmp/phase4-all.tap`
- **Expected:** All tests pass; total time < 10 min (KVM) or < 30 min (TCG)
- **Diagnosis on failure:**
  - Timeout: reduce VM count or increase timeout thresholds
  - Flaky test: add retry logic in `common.sh` for BMX7 convergence tests

**Risks:**
1. **Flaky tests due to BMX7 convergence timing** — Mitigation: Use `wait_until` assertions with generous timeouts; retry logic
2. **Test isolation** — Mitigation: Use qcow2 snapshot/restore between test groups; provide `reset-mesh.sh` script

---

### Phase 5: CI/CD Integration

**Goal:** Integrate the QEMU test bed into GitHub Actions for automated integration testing on PRs and merges.

- [ ] **5.1 Create GitHub Actions workflow** at `.github/workflows/qemu-integration-test.yml`:
  ```yaml
  name: QEMU Integration Test
  on:
    pull_request:
      paths:
        - 'adapters/mesh/**'
        - 'skills/mesh-readonly/**'
        - 'skills/mesh-rollout/**'
        - 'scripts/qemu/**'
        - 'tests/qemu/**'
    schedule:
      - cron: '0 3 * * *'  # nightly at 03:00 UTC
  jobs:
    qemu-test:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - name: Install QEMU and dependencies
          run: |
            sudo apt-get update
            sudo apt-get install -y qemu-system-x86 qemu-utils cmake g++ libnl-3-dev libnl-genl-3-dev iproute2
        - name: QEMU Integration Test
          uses: actions/cache@v4
          with:
            path: images/
            key: libremesh-x86-64-${{ hashFiles('scripts/qemu/build-libremesh-image.sh', 'docker/qemu-builder/Dockerfile', 'images/build-inputs.hash') }}
        - name: Build firmware (if not cached)
          run: bash scripts/qemu/build-libremesh-image.sh
        - name: Start test bed
          run: sudo bash scripts/qemu/start-vwifi.sh && sudo bash scripts/qemu/start-mesh.sh
          # sudo needed for TAP/bridge creation; GitHub Actions runners support this
        - name: Configure VMs
          run: bash scripts/qemu/configure-vms.sh
        - name: Run integration tests
          run: bash tests/qemu/run-all.sh
        - name: Collect logs
          if: always()
          run: bash scripts/qemu/collect-logs.sh
        - name: Upload logs
          if: always()
          uses: actions/upload-artifact@v4
          with:
            name: qemu-test-logs
            path: run/logs/
        - name: Stop test bed
          if: always()
          run: sudo bash scripts/qemu/stop-mesh.sh
  ```

- [ ] **5.2 Create log collection script** at `scripts/qemu/collect-logs.sh`:
  - Collects QEMU serial output from each VM
  - Collects vwifi-server logs
  - Collects dmesg and logread from each VM via SSH
  - Collects Mesha adapter output
  - Collects bridge and TAP status (`ip link show mesha-br0`, `brctl show`)
  - Writes everything to `run/logs/` for artifact upload

- [ ] **5.3 Optimize CI performance:**
  - Use GitHub Actions cache for firmware images (keyed on build script hash)
  - Only run QEMU tests when mesh-related files change (path filters)
  - Use nightly schedule for full topology manipulation tests
  - PR checks run subset: adapter contract tests only
  - TCG fallback: detect `/dev/kvm` availability, adjust timeouts accordingly

- [ ] **5.4 Document Docker vs QEMU test strategy (GAP 10):**
  - Docker onboarding test: runs on every PR, <30 seconds, tests onboarding workflow with stubs
  - QEMU integration test: runs on mesh-related changes + nightly, ~5 minutes, tests real mesh behavior
  - Both coexist; Docker is the fast gate, QEMU is the thorough check
  - Update `docs/testing/isolated-compose-plan.md` to reference QEMU tests as Phase 3 completion

- [ ] **5.5 Create self-hosted runner documentation** at `testbed/docs/self-hosted-runner.md`:
  - For maintainers with KVM-capable hardware
  - Documents setup of self-hosted GitHub Actions runner with KVM access
  - Enables larger topologies (>4 VMs) for advanced testing
  - Notes TAP/bridge setup permissions needed

### Step-by-Step Test Gates: Phase 5

**Gate 5.1: GitHub Actions workflow syntax is valid**
- **Action:** Push workflow file to a branch and check Actions tab
- **Expected:** YAML parses without error; workflow appears in Actions list
- **Test command:** `python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/qemu-integration-test.yml")); print("OK")'`
- **Diagnosis on failure:** YAML syntax error; fix indentation or structure

**Gate 5.2: Firmware image caches correctly**
- **Action:** Run workflow twice; second run should use cache
- **Expected:** Second run's "Build firmware" step shows "Cache hit" or completes in < 30 seconds
- **Test command:** Check GitHub Actions log for cache hit/miss messages
- **Diagnosis on failure:** Cache key doesn't match; verify `hashFiles('scripts/qemu/build-libremesh-image.sh', 'docker/qemu-builder/Dockerfile')` produces consistent hash. Note: the cache key now includes the Dockerfile hash, not just the build script.

**Gate 5.3: TAP/bridge creation works in CI**
- **Action:** Check CI log for `start-mesh.sh` output
- **Expected:** `mesha-br0` created, TAP devices attached, no permission errors
- **Test command:** Check CI log for `ip link add name mesha-br0` success
- **Diagnosis on failure:**
  - `Operation not permitted`: GitHub Actions `sudo` not working; check step has `sudo`
  - `File exists`: previous run didn't clean up; verify `stop-mesh.sh` runs in `if: always()` step

**Gate 5.4: Full CI pipeline completes within time budget**
- **Action:** Run full workflow on GitHub Actions
- **Expected:** Total job time < 30 minutes (with cached image, KVM) / < 60 minutes (TCG)
- **Test command:** Check GitHub Actions job duration
- **Diagnosis on failure:**
  - Build step slow: cache not working; check Gate 5.2
  - VM boot slow: TCG mode; verify `/dev/kvm` detection in `start-mesh.sh`
  - Tests slow: reduce test count or increase timeouts for TCG
  - Total exceeds 60 min: consider reducing CI topology to 2 LibreMesh VMs + 1 tester

**Gate 5.5: Cleanup succeeds after CI job**
- **Action:** Check post-job state; verify no orphaned resources
- **Expected:** `stop-mesh.sh` step runs (even on failure); no lingering QEMU processes
- **Test command:** Check CI log for "Cleanup complete" message
- **Diagnosis on failure:** `stop-mesh.sh` step didn't run; verify `if: always()` is set

**Gate 5.6: Docker tests still work independently**
- **Action:** Run `docker-compose -f docker-compose.onboarding-test.yml up --abort-on-container-exit`
- **Expected:** Docker onboarding test passes as before (QEMU changes didn't break it)
- **Test command:** `docker-compose -f docker-compose.onboarding-test.yml up --abort-on-container-exit && echo 'OK'`
- **Diagnosis on failure:** QEMU scripts modified shared files; check for conflicts in `adapters/` or `inventories/`

**Risks:**
1. **GitHub Actions runners lack KVM** — Mitigation: TCG fallback with 3x timeouts; self-hosted runner documentation; reduce to 2-VM minimum topology in CI
2. **Build cache invalidation** — Mitigation: Key cache on build script hash + feed commit hashes
3. **CI cost from long-running QEMU jobs** — Mitigation: Path filters to only run on relevant changes; nightly schedule for full suite
4. **TAP/bridge creation requires sudo in CI** — Mitigation: GitHub Actions runners support sudo; document the requirement

---

### Phase 6: Advanced Testing and Documentation

**Goal:** Enable advanced testing scenarios and ensure the test bed is maintainable long-term.

- [ ] **6.1 Create firmware upgrade simulation test** at `tests/qemu/test-firmware-upgrade.sh`:
  - Builds a second firmware image with different version string
  - Simulates `sysupgrade` on one VM (canary pattern from `mesh-rollout`)
  - Validates the node comes back with new firmware version
  - Tests rollback by reverting to qcow2 snapshot

- [ ] **6.2 Create multi-topology test configurations:**
  - `config/topology-line.yaml` — 3 nodes in a line (tests multi-hop)
  - `config/topology-star.yaml` — 3 nodes through 1 hub (tests gateway)
  - `config/topology-partition.yaml` — starts full mesh, then partitions (tests resilience)

- [ ] **6.3 Create `testbed/docs/README.md`** documenting:
  - Quick start: one command to launch test bed
  - How to run individual tests
  - How to build firmware images
  - How to add new test scenarios
  - Known limitations (TCG performance)
  - How to integrate with Mesha's agent architecture
  - Networking architecture (TAP/bridge) and why

- [ ] **6.4 Create `testbed/docs/troubleshooting.md`:**
  - VM won't boot: common QEMU issues
  - vwifi-server won't start: dependency checks
  - BMX7 not forming mesh: interface and radio checks
  - SSH connection refused: verify 10.99.0.x IP assignment and key injection
  - `ip -j` not working: ip-full package verification
  - Bridge/TAP issues: `ip link show mesha-br0`, verify TAP attachment
  - Lock file stuck: how to manually clean up `run/testbed.lock`
  - Orphaned QEMU processes: `ps aux | grep qemu`, `kill` commands

- [ ] **6.5 Track upstream GSoC 2025 sub-issues:**
  - Monitor lime-packages issues #1181-#1185 for completion
  - When vwifi integration improves, update build pipeline
  - When shared-state-async tests are available, integrate

### Step-by-Step Test Gates: Phase 6

**Gate 6.1: Firmware upgrade simulation works**
- **Action:** Build second firmware image with different version; simulate sysupgrade on VM1
- **Expected:** VM1 reboots with new firmware version; `validate-node.sh` detects version change
- **Test command:**
  ```bash
  # Before upgrade
  ssh -F config/ssh-config lm-testbed-node-1 'cat /etc/openwrt_release | grep VERSION'
  # Run upgrade simulation
  bash tests/qemu/test-firmware-upgrade.sh
  # After upgrade
  ssh -F config/ssh-config lm-testbed-node-1 'cat /etc/openwrt_release | grep VERSION'
  ```
- **Expected:** VERSION string changes between before/after
- **Diagnosis on failure:**
  - VM doesn't come back: sysupgrade failed; check qcow2 overlay isn't corrupted
  - Version unchanged: upgrade didn't apply; check image was actually different
  - Rollback fails: snapshot restore didn't work; manually recreate overlay

**Gate 6.2: Line topology works**
- **Action:** Launch mesh with `config/topology-line.yaml` (3 nodes in line)
- **Expected:** Node-3 can reach node-1 via node-2 (multi-hop); `collect-topology.sh` shows 3 nodes
- **Test command:**
  ```bash
  bash scripts/qemu/start-mesh.sh --topology config/topology-line.yaml
  ssh -F config/ssh-config lm-testbed-node-3 'traceroute 10.99.0.11' 2>/dev/null
  ```
- **Expected:** Traceroute shows 2 hops (node-3 → node-2 → node-1)
- **Diagnosis on failure:**
  - Direct route: vwifi relays all frames (full mesh); need vwifi-ctrl to block direct links
  - No route: BMX7 didn't find path; check neighbor tables on each node

**Gate 6.3: Documentation enables independent setup**
- **Action:** Have someone unfamiliar with the project follow `testbed/docs/README.md`
- **Expected:** They can launch the test bed and run tests without help
- **Test command:** Follow the quick start guide verbatim
- **Diagnosis on failure:** Missing steps, wrong commands, or unclear instructions; update docs

**Risks:**
1. **Firmware upgrade simulation may not work with qcow2 overlays** — Mitigation: Test sysupgrade path carefully; may need to write new image directly
2. **Upstream GSoC work may change vwifi API** — Mitigation: Pin to specific commits; track upstream

---

## Directory Structure (New Files)

```
mesha/
├── scripts/qemu/
│   ├── build-libremesh-image.sh      # Phase 1: firmware build
│   ├── start-vwifi.sh                # Phase 2: vwifi server
│   ├── start-mesh.sh                 # Phase 2: launch VMs (TAP/bridge + process supervision)
│   ├── configure-vms.sh              # Phase 2: post-boot config + SSH key injection
│   ├── stop-mesh.sh                  # Phase 2: teardown (cleanup bridge/TAP/PIDs)
│   ├── mesh-status.sh                # Phase 2: status check
│   ├── validate-adapters.sh          # Phase 3: adapter validation
│   ├── collect-logs.sh               # Phase 5: log collection
│   └── reset-mesh.sh                 # Phase 4: reset to clean state
├── tests/qemu/
│   ├── common.sh                     # Phase 4: shared test functions
│   ├── run-all.sh                    # Phase 4: test orchestrator
│   ├── test-adapters.sh              # Phase 4: adapter contract tests
│   ├── test-mesh-protocols.sh        # Phase 4: BMX7/Babel tests
│   ├── test-validate-node.sh         # Phase 4: validate-node tests
│   ├── test-config-drift.sh          # Phase 4: drift detection tests
│   ├── test-topology-manipulation.sh # Phase 4: vwifi-ctrl tests
│   └── test-firmware-upgrade.sh      # Phase 6: upgrade simulation
├── testbed/
│   ├── config/
│   │   ├── topology.yaml             # Phase 2: default topology (10.99.0.0/16)
│   │   ├── topology-line.yaml        # Phase 6: line topology
│   │   ├── topology-star.yaml        # Phase 6: star topology
│   │   ├── inventories/              # Phase 3: test bed inventories
│   │   │   ├── mesh-nodes.yaml
│   │   │   ├── gateways.yaml
│   │   │   └── sites.yaml
│   │   ├── desired-state/            # Phase 3: test desired state
│   │   │   └── mesh/
│   │   └── ssh-config                # Phase 3: SSH config (direct IP, no port fwd)
│   ├── images/
│   │   └── README.md                 # Phase 1: image docs
│   ├── docs/
│   │   ├── README.md                 # Phase 6: test bed docs
│   │   ├── troubleshooting.md        # Phase 6: troubleshooting
│   │   └── self-hosted-runner.md     # Phase 5: CI runner docs
│   └── .gitignore                    # Phase 2: exclude run/, images, bin/, ssh-keys/
├── docker/qemu-builder/
│   └── Dockerfile                    # Phase 1: build environment
└── .github/workflows/
    └── qemu-integration-test.yml     # Phase 5: CI workflow
```

---

## Resource Requirements

### Local Development

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 4 GB (2 VMs) | 8 GB (4 VMs) |
| CPU | 2 cores (TCG) | 4+ cores (KVM) |
| Disk | 2 GB (images + overlays) | 5 GB (with build artifacts) |
| KVM | Optional (TCG works with 3x timeout) | Preferred |
| Permissions | CAP_NET_ADMIN for TAP/bridge (sudo) | Root or sudo access |

### CI (GitHub Actions)

| Resource | Value |
|----------|-------|
| RAM | 7 GB (runner limit) — 4 VMs at 1.3 GB + overhead |
| CPU | 2 cores (runner limit) |
| Disk | ~500 MB per run (images cached) |
| Time | ~10 min (KVM, cached image) / ~30 min (TCG, cached) / ~2-4 hours (first build) |
| Permissions | sudo available for TAP/bridge creation |

---

## Dependency Map

```
Phase 1 (Build Pipeline)
    ↓
Phase 2 (QEMU Orchestration) ← depends on images from Phase 1
    ↓
Phase 3 (Adapter Integration) ← depends on running VMs from Phase 2
    ↓
Phase 4 (Test Suite) ← depends on working adapters from Phase 3
    ↓
Phase 5 (CI/CD) ← depends on passing tests from Phase 4
    ↓
Phase 6 (Advanced) ← extends Phase 4 and 5
```

Phases 1-2 can be developed and verified independently. Phase 3 requires both 1 and 2. Phase 4 requires 3. Phase 5 requires 4. Phase 6 extends 4 and 5.

---

## Potential Risks and Mitigations

1. **vwifi-server doesn't compile or work on target platform**
   - Mitigation: Cache pre-compiled binaries for common platforms; fall back to mac80211_hwsim-only mode (intra-VM WiFi simulation without inter-VM relay)
   - Impact: Reduced test fidelity (no real inter-VM WiFi), but BMX7 over wired TAP/bridge interfaces still works

2. **LibreMesh BuildRoot build fails with vwifi feed**
   - Mitigation: Pin to exact commit hashes from GSoC 2025 proven configuration; maintain a known-good build manifest
   - Impact: May need to use older OpenWrt base version

3. **GitHub Actions KVM not available**
   - Mitigation: TCG fallback with 3x timeouts; self-hosted runner documentation; reduce to 2-VM minimum topology in CI
   - Impact: Slower CI; some timing-sensitive tests may be flaky

4. **BMX7 convergence too slow in virtualized environment**
   - Mitigation: Configurable wait times; retry with exponential backoff; reduce mesh size for CI
   - Impact: Tests may take longer; some edge cases may not be testable

5. **TAP/bridge setup requires elevated privileges**
   - Mitigation: Document requirement clearly; CI runners support sudo; provide manual cleanup commands
   - Impact: Cannot run without CAP_NET_ADMIN; not a problem in CI or on dev machines with sudo

6. **Test flakiness from virtualization timing**
   - Mitigation: Generous timeouts; `wait_until` assertion pattern; TAP output for CI retry logic; mark known-flaky tests
   - Impact: Some tests may need `continue-on-error` in CI

7. **Orphaned processes after script crash**
   - Mitigation: Trap handler on EXIT/INT/TERM/HUP; `stop-mesh.sh` performs force cleanup; lock file tracks PIDs
   - Impact: Minimal — cleanup is robust and idempotent

---

## Alternative Approaches

1. **Use libremesh-virtual-mesh scripts directly (VGDSpehar):**
   - Pros: Already works; has start-mesh.sh and setup-vm.sh
   - Cons: Requires tmux (GAP 11); uses user-mode networking which doesn't support inter-VM direct communication for Mesha's SSH-based adapters; 25 commits, proof-of-concept quality; would need significant adaptation for Mesha's adapter model
   - Decision: Reference for patterns but build our own orchestration with TAP/bridge networking

2. **Use Labgrid framework (from openwrt-tests-libremesh):**
   - Pros: pytest-based; YAML target definitions; power control abstraction
   - Cons: Heavy framework dependency; designed for hardware testing; Mesha uses shell scripts not pytest; would require rewriting the test layer
   - Decision: Reference for test patterns but don't adopt the framework

3. **Use Docker with real OpenWrt userspace (not QEMU):**
   - Pros: Faster startup; better CI integration; no KVM requirement; no TAP/bridge privilege issues
   - Cons: Cannot run real kernel modules (mac80211_hwsim); cannot test firmware upgrades; not real LibreMesh behavior
   - Decision: Keep Docker for fast onboarding tests (Phase 1 Docker already exists); use QEMU for integration tests

4. **Use pre-built LibreRouterOS 1.5 images:**
   - Pros: No build required; immediately available
   - Cons: No WiFi support (no mac80211_hwsim, no vwifi); cannot customize packages
   - Decision: Use for initial prototyping only; full solution requires custom build

---

## Success Metrics

- [ ] Phase 1: Custom LibreMesh image boots in QEMU with WiFi simulation support
- [ ] Phase 2: 4-VM mesh launches with TAP/bridge networking; all VMs SSH-reachable within 90 seconds; inter-VM ping works
- [ ] Phase 3: All Mesha adapter scripts return valid data from QEMU VMs
- [ ] Phase 4: Integration test suite passes with >=10 test cases
- [ ] Phase 5: QEMU tests run in GitHub Actions CI pipeline
- [ ] Phase 6: Firmware upgrade simulation and multi-topology testing works

---

## CHANGELOG

### v3.2 → v3.3 (2026-04-19) — Implementation Readiness Fixes

Six fixes based on cross-referencing with actual upstream source code (VGDSpehar/libremesh-virtual-mesh setup-vm.sh, Raizo62/vwifi config.h, LibreRouterOS pre-built images, VIRTUALIZING.md):

1. **Phase 1.1: Pinned exact commit hashes** — vwifi pinned to `c2ebeb9`, 802.11ax patch `89bc4284bb0b`. Added defconfig file (`libremesh-testbed.defconfig`) with all 17 CONFIG_PACKAGE entries. Added LibreMesh build process following libremesh.org instructions. Added fallback strategy.
2. **Phase 1.5 (NEW): Fast-path with pre-built images** — LibreRouterOS 1.5 pre-built images for parallel development while custom build runs (2-4 hours). Documents limitations (no WiFi simulation) and QEMU launch differences.
3. **Phase 2.6: Added lime-community template + lime-config sequence** — Critical fix: LibreMesh requires `lime-config` to generate UCI configuration from templates. Added `lime-community` UCI config (ap_ssid, protocols, domain), `lime-node` per-node overrides (main_ipv4_address), and the exact `vwifi-client start → wifi config → lime-config → wifi down/up` sequence from upstream `setup-vm.sh`.
4. **Phase 2.1: Fixed vwifi-server bind address** — Removed `-a 10.99.0.254` flag (does not exist). Server binds INADDR_ANY by default per `csocketserverfunctionitcp.cc`. Corrected port numbers from 8210-8213 to actual defaults: 8211-8214.
5. **Gate 2.5: Fixed ICMPv4 test** — Clarified that ICMPv4 limitation in VIRTUALIZING.md only applies to QEMU user-mode networking. TAP/bridge supports ICMPv4. Added IPv6 fallback test and firewall diagnosis.
6. **Gate 3.5: Added IPv6 parser fix** — Documented the exact regex change needed in `collect-topology.sh:203` to support IPv6 link-local addresses, plus the `bmx7 -c --jshow originators` JSON alternative.

Also added: dual-IP scheme clarification (management 10.99.0.x vs mesh LibreMesh-configured), vwifi-server port confirmation (8212 TCP/INET from config.h), corrected port numbers (8211-8214 not 8210-8213).
### v3.1 → v3.2 (2026-04-19)

**Test gate review fixes (15 issues found and corrected):**

1. **Gate 1.3: QEMU serial console test was wrong** — `echo 'root' | qemu...` doesn't work because QEMU serial console doesn't read stdin like a terminal. Fixed to use log file capture + grep pattern matching.

2. **Gate 1.4: SSH test assumed network was pre-configured** — OpenWrt default LAN is 192.168.1.1, not 10.99.0.11. Fixed to use QEMU user-mode `hostfwd=tcp::2222-:22` port forwarding, bypassing the need to configure guest IP.

3. **Gate 1.5: Shell quoting was broken** — `print('OK')` inside single-quoted SSH command caused nested quote clash. Fixed with `print(chr(79)+chr(75))`.

4. **Gate 1.5: Missing `nc` check** — Adapter scripts (`collect-nodes.sh:139`, `collect-topology.sh:118`) use `nc` for babeld fallback. Added `which nc` to the package verification checklist.

5. **Gate 1.6: Build caching was unrealistic** — Said "second build completes in < 30 seconds" but BuildRoot takes 2-4 hours. Fixed to describe hash-based skip logic instead.

6. **Gate 2.3: Missing serial log verification** — QEMU launch should capture serial output to files. Added serial log existence check to the gate.

7. **Gate 2.6: `iwconfig` may not exist** — OpenWrt uses `iw` not `iwconfig`. Changed to `iw dev` with `iwconfig` fallback.

8. **Gate 3.1: Missing `pyyaml` prerequisite** — The YAML validation test requires `python3-yaml`. Added prerequisite note.

9. **Gate 3.1b: Added host dependency gate** — Adapter scripts need `ssh`, `jq`, `python3`, `curl` on the host. Added new gate to verify these before running adapters.

10. **Gate 3.5: IPv6 originator parsing limitation** — `collect-topology.sh:203` only matches IPv4 (`\d+.\d+.\d+.\d+`). BMX7 may use IPv6. Added note about this limitation and diagnosis for `node_count: 1`.

11. **Gate 3.5: Missing `nc` and `python3` dependency notes** — `collect-topology.sh` uses both. Added notes.

12. **Gate 3.6: Missing output file verification** — `discover-from-thisnode.sh` writes to `exports/discovery/latest.json`. Added file existence check and JSON field validation.

13. **Gate 3.7: Missing lime-community prerequisite** — `validate-node.sh:170` checks `uci get lime-community.wifi.ap_ssid` which requires LibreMesh lime-packages. Added prerequisite and detailed per-check diagnosis.

14. **Phase 1.1: Missing packages** — Added `iw`, `lime-system`, `lime-proto-bmx7` to the package list. These are needed for WiFi interface checks and LibreMesh community config validation.

15. **Gate 5.2 / CI workflow: Cache key incomplete** — Only hashed the build script, not the Dockerfile. Fixed to include both.

### v3 → v3.1 (2026-04-19)

**Added step-by-step testing strategy:**

Replaced all vague "Verification Criteria" sections with concrete test gates for every phase:

- **Phase 1:** 6 gates (image file exists, Docker build matches, boots to prompt, SSH works, packages functional, caching works)
- **Phase 2:** 8 gates (vwifi-server starts, host networking configured, VMs boot, SSH connectivity, inter-VM ping, vwifi-client connects, lock protection, teardown cleanup)
- **Phase 3:** 7 gates (inventory valid, SSH config works, ip JSON works, collect-nodes works, collect-topology works, discover-thisnode works, validate-node works)
- **Phase 4:** 7 gates (framework loads, adapter tests pass, protocol tests pass, validate-node tests pass, drift tests pass, topology manipulation passes, time budget met)
- **Phase 5:** 6 gates (YAML valid, caching works, TAP/bridge in CI, time budget, cleanup, Docker still works)
- **Phase 6:** 3 gates (firmware upgrade, line topology, documentation)

Each gate includes: Action, Expected result, Test command, and Diagnosis on failure.

### v2 → v3 (2026-04-19)

**Technical corrections from deep codebase review:**

1. **vwifi TCP mode (not VHOST)** — Corrected from mixed VHOST/TCP to pure TCP mode. With TAP/bridge networking, VMs have their own IPs and TCP mode is the natural choice. VHOST mode requires `vhost_vsock` kernel module and per-VM CID numbers via `-device vhost-vsock-pci,guest-cid=N`.

2. **vwifi-client UCI configuration** — Corrected from direct CLI invocation (`vwifi-client 10.99.0.254:8212`) to proper OpenWrt UCI config (`uci set vwifi.config.server_ip=...` + `service vwifi-client start`). Verified against javierbrk/vwifi_cli_package README.

3. **Added `vwifi-add-interfaces` step** — vwifi requires creating wlan interfaces BEFORE starting vwifi-client. Added `vwifi-add-interfaces 2 <mac-prefix>` step in configure-vms.sh.

4. **mac80211_hwsim radios=0** — Corrected from unspecified to `radios=0`. vwifi-client creates its own interfaces via `vwifi-add-interfaces`; mac80211_hwsim must start with zero radios.

5. **Fixed build dependencies** — Added `pkg-config`, `make`, `libnl-3-dev`, `libnl-genl-3-dev` to both vwifi-server build and Docker builder.

6. **Fixed vwifi-server port numbers** — Corrected from 8210-8213 to actual defaults from vwifi source `config.h`: 8211 (VHOST), 8212 (TCP), 8213 (spy), 8214 (control).

7. **Added testbed path wrapper (3.1b)** — Mesha's adapter scripts have hardcoded paths (`run-mesh-readonly.sh:23-24`, `validate-node.sh:68`, `discover-from-thisnode.sh:19`). Added wrapper script to handle inventory/state path mapping.

8. **Host-side thisnode.info resolution** — Added requirement for host `/etc/hosts` entry, not just VM entries.

9. **Added python3 dependency note** — Adapter scripts use `python3` for JSON parsing (`collect-nodes.sh:167`). Verified it's in the image package list.

### v1 → v2 (2026-04-18)

### Breaking Changes

1. **Networking model (ISSUE 1 - FATAL):** Replaced QEMU user-mode networking (`-netdev user`) for mesh0 with TAP/bridge networking (`-netdev tap`). This is the core architectural fix — without it, VMs cannot communicate with each other, making the entire test bed non-functional.

2. **Management subnet (ISSUE 2):** Changed from 10.13.0.0/16 to 10.99.0.0/16 to avoid collision with LibreMesh's internal mesh subnet.

### New Additions

3. **Concurrent run protection (ISSUE 4):** Added mkdir-based lock file mechanism to prevent multiple test bed instances.

4. **Process supervision and cleanup (ISSUE 5):** Added comprehensive trap handler that cleans up QEMU processes, vwifi-server, TAP devices, and bridge on any exit signal.

5. **SSH key injection resolved (ISSUE 6):** Removed TBD. Uses OpenWrt's default passwordless root login for initial connection, then injects SSH key and locks down to key-only auth.

### Fixes

6. **Tester VM reachability (ISSUE 3):** Resolved by TAP/bridge networking — all VMs are on the same L2 segment and can reach each other directly.

7. **SSH config updated:** Removed port forwarding (no longer needed with TAP/bridge). SSH config uses direct 10.99.0.x IPs.

8. **vwifi-server listen address:** Server binds INADDR_ANY by default — no flag needed. VMs reach it at 10.99.0.254:8212.

9. **CI workflow updated:** Added `sudo` for start/stop scripts (needed for TAP/bridge), added `iproute2` dependency.

10. **Topology config updated:** Added `tap_index`, `mac_wan`, `bridge_name`, `bridge_ip`, `management_subnet`, `tap_prefix` fields.

---

## References

- LibreMesh VIRTUALIZING.md: https://github.com/libremesh/lime-packages/blob/master/VIRTUALIZING.md
- GSoC 2025 WiFi Support: https://blog.freifunk.net/2025/09/01/gsoc-2025-bringing-wi-fi-support-to-qemu-simulations-for-libremesh/
- lime-packages issue #1178: https://github.com/libremesh/lime-packages/issues/1178
- vwifi project: https://github.com/Raizo62/vwifi
- vwifi_cli_package feed: https://github.com/javierbrk/vwifi_cli_package
- libremesh-virtual-mesh: https://github.com/VGDSpehar/libremesh-virtual-mesh
- openwrt-tests-libremesh: https://github.com/VGDSpehar/openwrt-tests-libremesh
- LibreRouterOS 1.5 images: https://repo.librerouter.org/lros/releases/1.5/targets/x86/64/
- 802.11ax patch commit: 89bc4284bb0b in lime-packages
- Mesha existing Docker test: `docker-compose.onboarding-test.yml`
- Mesha testing plan: `docs/testing/isolated-compose-plan.md`
- QEMU TAP networking: https://wiki.qemu.org/Documentation/Networking#Tap
- Linux bridge documentation: https://wiki.linuxfoundation.org/networking/bridge

### v3.3 → v3.4 (2026-04-25) — Upstream-Verified Corrections

Twenty-three corrections verified against actual upstream source code (Raizo62/vwifi commit 75cc3b52: `vwifi-server.cc`, `vwifi-ctrl.cc`, `csocketserverfunctionitcp.cc`, `config.h`; javierbrk/vwifi_cli_package commit 51bbf3bc):

1. **C1: vwifi-server has no `-a` flag** — Removed `-a 10.99.0.254` from launch command. Server binds INADDR_ANY by default (`csocketserverfunctionitcp.cc`). No config.h patching needed.
2. **C2: Port numbers off by one** — Corrected from 8210-8213 to actual defaults from `config.h`: VHOST=8211, TCP=8212, Spy=8213, Ctrl=8214.
3. **C3: vwifi-ctrl only supports global yes/no loss** — Rewrote Phase 4.6 test to use distance-based loss (coordinates + scale) instead of per-link percentage.
4. **C4: IPv6 EUI-64 address wrong** — Corrected from `fe80::5054:ff:fe00:2` to `fe80::5054:00ff:fe00:2`.
5. **C5: Build sequence backwards** — Reordered: feeds update/install BEFORE `make defconfig`.
6. **C6: qcow2 overlay backing format wrong** — Changed `-F qcow2` to `-F raw` (base image is raw ext4).
7. **C7: `-cpu host` crashes TCG** — Made CPU selection conditional on `/dev/kvm` availability.
8. **C8: Bridge STP forwarding delay** — Added `stp_state 0 forward_delay 0` to bridge creation.
9. **C9: TAP device ownership** — Added `user $(whoami)` for non-root QEMU.
10. **C10: Missing `qemu-utils` dependency** — Added to Docker builder and CI apt-get lists.
11. **C11: Lock file in `/tmp` is ephemeral** — Moved to `run/testbed.lock`.
12. **C12: Duplicate `service vwifi-client start`** — Removed first invocation, kept only inside lime-config sequence.
13. **C13: Wrong file path references** — Corrected `discover-from-thisnode.sh` to `scripts/discover-from-thisnode.sh`, `validate-node.sh` to `skills/mesh-rollout/scripts/validate-node.sh`.
14. **C14: SSH config IdentityFile relative path** — Added note to generate with absolute paths at runtime.
15. **C15: libremesh.org/development.html is 404** — Replaced with GitHub repo link.
16. **C16: Host `/etc/hosts` alternative** — Added HOSTALIASES and `curl --resolve` alternatives.
17. **C17: Drop `openssh-server`, use dropbear** — Removed from defconfig; OpenWrt base includes dropbear.
18. **C18: Add ccache** — Added `CONFIG_CCACHE=y` to defconfig; added `ccache` to Docker builder deps.
19. **C19: CI time budget unrealistic** — Increased to 30 min (KVM) / 60 min (TCG).
20. **C20: Cache key missing upstream hashes** — Added `build-inputs.hash` to cache key.
21. **C21: Pre-built kernel cmdline insufficient** — Added `rootwait console=ttyS0`.
22. **C22: Gate 1.2/1.4 diagnosis references** — Updated to reference dropbear instead of openssh-server.
23. **C23: CHANGELOG port numbers** — Corrected v3→v3.1 changelog port numbers from 8210-8213 to 8211-8214.

---

# Appendix A: Verified Corrections Research (2026-04-25)

Source: `plans/2026-04-25-qemu-testbed-v3.3-corrections-v1.md`


## Verified Against Upstream Source Code (April 2026)

All corrections below are grounded in actual source code from:
- Raizo62/vwifi `master` branch (commit 75cc3b52)
- javierbrk/vwifi_cli_package `master` branch (commit 51bbf3bc)
- Mesha codebase adapters and scripts

---

## CORRECTIONS TO APPLY

### C1. vwifi-server: NO `-a` flag exists — use `INADDR_ANY` binding instead

**Plan line 349:** `bin/vwifi-server -u -a 10.99.0.254`
**VERIFIED FALSE.** The `vwifi-server.cc` `main()` parses only these flags: `-v`, `-h`, `-l`, `-u`, `-p` (VHOST port), `-t` (TCP port), `-s` (spy port), `-c` (ctrl port). No `-a` flag.

**However:** The `csocketserverfunctionitcp.cc` `_Listen()` binds with `address.sin_addr.s_addr = INADDR_ANY` — this means vwifi-server **already binds on 0.0.0.0 on all ports (TCP, Spy, Ctrl)**. The `DEFAULT_ADDRESS_IP "127.0.0.1"` in `config.h` is used by the CLIENT (`vwifi-client` and `vwifi-ctrl`), NOT the server.

**The plan's concern was wrong — vwifi-server already listens on all interfaces.** No patching of `config.h` is needed for the server.

**What DOES need changing:** `vwifi-ctrl` (used in Phase 4 tests) defaults to connecting to `127.0.0.1` (`DEFAULT_ADDRESS_IP`). Since vwifi-ctrl runs on the same host as vwifi-server, this is fine — no change needed.

**Corrected line 349:**
```
Launches in TCP mode: `bin/vwifi-server -u` (`-u`: use-port-in-hash for multi-VM identification; vwifi-server binds INADDR_ANY by default — all interfaces, no bind-address flag needed)
```

**Corrected line 353:**
```
vwifi-server binds INADDR_ANY (0.0.0.0) by default per csocketserverfunctionitcp.cc — no config.h patching needed. VMs connect via 10.99.0.254:8212.
```

### C2. vwifi-server port numbers: Plan is WRONG

**Plan line 351:** "Default ports: 8210 (VHOST, unused), 8211 (TCP primary), 8212 (spy), 8213 (control)"

**VERIFIED from config.h:**
```c
const TPort DEFAULT_WIFI_CLIENT_PORT_VHOST = 8211;
const TPort DEFAULT_WIFI_CLIENT_PORT_INET = DEFAULT_WIFI_CLIENT_PORT_VHOST+1;  // 8212
const TPort DEFAULT_WIFI_SPY_PORT = DEFAULT_WIFI_CLIENT_PORT_VHOST+2;          // 8213
const TPort DEFAULT_CTRL_PORT = DEFAULT_WIFI_CLIENT_PORT_VHOST+3;              // 8214
```

**Actual defaults:** VHOST=8211, TCP=8212, Spy=8213, Ctrl=8214

**Corrected line 351:**
```
Default ports: 8211 (VHOST, unused in TCP mode), 8212 (TCP primary), 8213 (spy), 8214 (control) — from src/config.h
```

**Corrected topology.yaml (line 595-599):**
```yaml
vwifi:
  server_port: 8211  # VHOST port (unused in TCP mode)
  tcp_port: 8212     # TCP primary (vwifi-server default)
  spy_port: 8213     # Spy port
  control_port: 8214 # Control port
```

### C3. vwifi-ctrl: Per-link packet loss NOT supported — only global + distance-based

**VERIFIED from vwifi-ctrl.cc:** The `loss` command takes `yes/no` only (binary toggle). There is no per-link or percentage-based loss control. Packet loss in vwifi is distance-based (coordinates set via `vwifi-ctrl set CID X Y Z` + `vwifi-ctrl scale VALUE`).

**Corrected Phase 4.6 test (line 1033):**
```
test_vwifi_ctrl_adds_packet_loss — uses vwifi-ctrl to set distant coordinates for one VM pair, enables loss with `vwifi-ctrl loss yes`, sets a small scale with `vwifi-ctrl scale 0.001`, verifies BMX7 link quality degrades due to distance-based packet loss
```

### C4. IPv6 EUI-64 link-local address: Plan had wrong address

**Plan line 695:** `fe80::5054:ff:fe00:2`
**Correct:** `fe80::5054:00ff:fe00:2` (or equivalently `fe80::5054:ff:fe00:0002`)

EUI-64 derivation for MAC `52:54:00:00:00:02`:
1. Split: `52:54:00` | `00:00:02`
2. Insert `ff:fe`: `52:54:00:ff:fe:00:00:02`
3. Flip U/L bit (bit 1 of first byte): `52` → `50` → `50:54:00:ff:fe:00:00:02`
4. Link-local: `fe80::5054:00ff:fe00:0002`

**Corrected line 695:**
```bash
ssh -i run/ssh-keys/id_ed25519 root@10.99.0.11 'ping6 -c 3 -I eth0 fe80::5054:00ff:fe00:2' 2>/dev/null || true
```

### C5. OpenWrt build sequence: feeds MUST come before `make defconfig`

**Plan lines 169-176:** Has `make defconfig` BEFORE `./scripts/feeds install -a`

**Corrected build sequence:**
```bash
# 1. Clone and enter build dir
git clone https://github.com/libremesh/lime-packages.git
cd lime-packages && make  # clones OpenWrt, applies lime-packages as feed

# 2. Add vwifi feed BEFORE feeds update
echo 'src-git vwifi https://github.com/javierbrk/vwifi_cli_package.git' >> feeds.conf

# 3. Update and install ALL feeds (including vwifi)
./scripts/feeds update -a
./scripts/feeds install -a

# 4. NOW apply defconfig — feeds are available for symbol resolution
cp scripts/qemu/libremesh-testbed.defconfig .config
make defconfig  # expands defconfig; vwifi symbols now resolvable

# 5. Verify critical packages resolved
grep CONFIG_PACKAGE_vwifi-client .config  # must not be '# ... is not set'

# 6. Build
make -j$(nproc)
```

### C6. qcow2 overlay backing format: base image is RAW, not qcow2

**Plan line 385-386:** `-F qcow2`
**Corrected:**
```bash
qemu-img create -f qcow2 -b images/libremesh-x86-64-base.img \
  -F raw run/node-{N}.qcow2
```

### C7. QEMU `-cpu host` breaks TCG fallback

**Plan line 391:** `-enable-kvm -M q35 -cpu host -smp 2`
**Corrected logic:**
```bash
if [ -w /dev/kvm ]; then
  ACCEL="-enable-kvm"
  CPU="-cpu host"
else
  ACCEL="-accel tcg"
  CPU="-cpu qemu64"  # -cpu host requires KVM
  QEMU_TIMEOUT_MULTIPLIER=3
fi
qemu-system-x86_64 ${ACCEL} -M q35 ${CPU} -smp 2 -m ${RAM_MB}M ...
```

### C8. vwifi-client CLI: positional IP argument, not `-a`

**VERIFIED from vwifi-client.cc:** TCP mode is activated by passing an IP address as a positional argument:
```c
else {
    if( ip_addr.empty() )
        ip_addr = std::string(argv[arg_idx]);
```

So the CLI is: `vwifi-client 10.99.0.254` (not `vwifi-client -a 10.99.0.254`)

The javierbrk/vwifi_cli_package README confirms: `uci set vwifi.config.server_ip=192.168.126.187` then `service vwifi-client start`.

**Plan's Phase 2.6 UCI config is correct** — the UCI approach is right for the OpenWrt package. No CLI fix needed, just confirming the plan's UCI method matches upstream.

### C9. vwifi-server already binds 0.0.0.0 — no config.h patch needed

**VERIFIED from csocketserverfunctionitcp.cc:**
```c
address.sin_addr.s_addr = INADDR_ANY;
```

The server binds ALL interfaces. The `DEFAULT_ADDRESS_IP "127.0.0.1"` in config.h is only used by vwifi-client and vwifi-ctrl as their default connection target.

**Impact on plan:** Remove all mentions of patching config.h for bind address. The plan's concern at line 349 about "MUST override for VMs to reach it" is unfounded — VMs can already reach the server at 10.99.0.254:8212 because it binds 0.0.0.0.

### C10. Bridge STP forwarding delay

**Add after line 363:**
```bash
# Disable STP and forwarding delay for immediate connectivity
ip link set mesha-br0 type bridge stp_state 0 forward_delay 0
```

### C11. TAP device ownership for non-root QEMU

**Corrected line 367:**
```bash
ip tuntap add dev mesha-tap${i} mode tap user $(whoami) 2>/dev/null || true
```

This allows QEMU to open the TAP device without root.

### C12. Add `qemu-utils` to dependencies

**Docker builder (line 185):** Add `qemu-utils` to apt-get install list.
**CI workflow (line 1163):** Add `qemu-utils` to apt-get install list.

### C13. Fix file path references

**Line 772-774 corrections:**
- `run-mesh-readonly.sh:23-24` → `skills/mesh-readonly/scripts/run-mesh-readonly.sh:23-24` ✓ (already correct)
- `discover-from-thisnode.sh:19` → `scripts/discover-from-thisnode.sh:19` (not `adapters/mesh/`)
- `validate-node.sh:68` → `skills/mesh-rollout/scripts/validate-node.sh:68` (WORKSPACE_ROOT derivation; firmware check at lines 109-121)

### C14. SSH config IdentityFile needs absolute path

**Line 788 correction:**
```
IdentityFile %(cwd)s/run/ssh-keys/id_ed25519
```
Or generate at runtime with absolute paths.

### C15. libremesh.org/development.html is 404

**Line 136:** Replace with inline build instructions (already present in the plan) or point to `https://github.com/libremesh/lime-packages` README.

### C16. Lock file location

**Line 409:** Change from `/tmp/mesha-qemu-testbed.lock` to `run/testbed.lock` for persistence across reboots.

### C17. Duplicate `service vwifi-client start`

**Lines 480 and 499:** Remove the first invocation at line 480. Keep only the one inside the lime-config sequence block (line 499).

### C18. CI time budget increase

**Line 1243:** Change `< 10 minutes` to `< 30 minutes (with cached image, KVM)` / `< 60 minutes (TCG)`.
**Line 1127:** Change `< 5 min (KVM) or < 15 min (TCG)` to `< 10 min (KVM) or < 30 min (TCG)`.

### C19. Host /etc/hosts alternative

**Line 819 addition:** Provide alternative that doesn't require sudo:
```bash
# Option A: Use HOSTALIASES (no sudo needed)
echo "thisnode.info 10.99.0.11" > run/host-aliases
export HOSTALIASES=run/host-aliases
# Note: HOSTALIASES doesn't work with all commands (e.g., ping ignores it)
# Option B: Use curl --resolve for HTTP tests
curl --resolve thisnode.info:80:10.99.0.11 http://thisnode.info/
```

### C20. Drop openssh-server, keep dropbear

**Line 161:** Remove `CONFIG_PACKAGE_openssh-server=y`. OpenWrt base images include dropbear. Add verification in Gate 1.5 that dropbear is running on port 22.

### C21. Add ccache for build acceleration

**Line 147:** Add `CONFIG_CCACHE=y` to defconfig. Add `ccache` to Docker builder dependencies. Include `~/.ccache` in GitHub Actions cache.

### C22. Cache key should include upstream commit hashes

**Line 1168:** Add a `images/build-inputs.hash` file containing pinned commit hashes:
```yaml
key: libremesh-x86-64-${{ hashFiles('scripts/qemu/build-libremesh-image.sh', 'docker/qemu-builder/Dockerfile', 'images/build-inputs.hash') }}
```

### C23. vwifi-add-interfaces MAC prefix format

**VERIFIED from vwifi README:** `vwifi-add-interfaces 2 0a:0b:0c:03:02` — the second argument is a partial MAC prefix (format: `XX:XX:XX:XX:XX`). The javierbrk UCI `mac_prefix` uses a shorter format (`74:f8:f6:66`).

**Plan line 472:** `vwifi-add-interfaces 2 52:54:00:02:{N}:00` — this is 6 bytes which is a full MAC, not a prefix. vwifi-add-interfaces uses this as a base and randomizes remaining bytes.

**Corrected:** Keep as-is but document that vwifi-add-interfaces uses this as a base MAC prefix (first 5 bytes) and appends/increments for each interface.

---

## SUMMARY OF VERIFICATION RESULTS

| Finding | Verified? | Action |
|---------|-----------|--------|
| `-a` flag on vwifi-server | **FALSE** — no such flag | Remove `-a`; server already binds 0.0.0.0 |
| config.h needs patching | **FALSE** — server uses INADDR_ANY | Remove patching instructions |
| Port numbers 8210-8213 | **WRONG** — actual: 8211-8214 | Correct all port references |
| vwifi-ctrl per-link loss | **FALSE** — only global yes/no | Rewrite Phase 4.6 test |
| IPv6 EUI-64 address | **WRONG** — missing `00ff` | Correct to `fe80::5054:00ff:fe00:2` |
| Build sequence order | **CONFIRMED WRONG** | Feeds before defconfig |
| qcow2 backing format | **CONFIRMED WRONG** | `-F raw` not `-F qcow2` |
| `-cpu host` with TCG | **CONFIRMED WRONG** | Use `-cpu qemu64` for TCG |
| vwifi-client CLI | **CONFIRMED** — positional IP arg | Plan's UCI approach is correct |
| Server binds 127.0.0.1 | **FALSE** — binds INADDR_ANY | No patching needed |

---

# Appendix B: Corrections Application Checklist (2026-04-25)

Source: `plans/2026-04-25-apply-qemu-testbed-corrections-v1.md`


## Objective

Apply 23 verified corrections to `plans/2026-04-19-qemu-testbed-v3.3.md`, producing a single canonical plan document with no errors. All corrections are grounded in actual upstream source code (Raizo62/vwifi, javierbrk/vwifi_cli_package, Mesha codebase).

## Implementation Plan

- [ ] **Fix 1. Line 136: Replace dead libremesh.org URL**
  Replace `https://libremesh.org/development.html` with `https://github.com/libremesh/lime-packages` (or inline the build steps, which are already present).

- [ ] **Fix 2. Lines 147-167: Drop `openssh-server`, add `ccache`, add verification gate**
  - Remove `CONFIG_PACKAGE_openssh-server=y` (line 161) — OpenWrt base includes dropbear
  - Add `CONFIG_CCACHE=y` to defconfig
  - Add note: "After `make defconfig`, verify each symbol with `grep CONFIG_PACKAGE_ .config`"

- [ ] **Fix 3. Lines 169-176: Reorder build sequence — feeds before defconfig**
  Change to:
  ```
  1. Clone lime-packages (which clones OpenWrt)
  2. Add vwifi feed to feeds.conf
  3. ./scripts/feeds update -a && ./scripts/feeds install -a
  4. cp defconfig .config && make defconfig
  5. Verify: grep CONFIG_PACKAGE_vwifi-client .config
  6. make -j$(nproc)
  ```

- [ ] **Fix 4. Line 185: Add `qemu-utils` and `ccache` to Docker builder deps**
  Add `qemu-utils` and `ccache` to apt-get install list.

- [ ] **Fix 5. Line 221-226: Add `rootwait console=ttyS0` to kernel cmdline**
  Change `-append "root=/dev/vda rootfstype=ext4"` to `-append "root=/dev/vda rootfstype=ext4 rootwait console=ttyS0"`

- [ ] **Fix 6. Line 253: Update Gate 1.2 grep — drop openssh-server, add dropbear**
  Change grep to check for `dropbear` instead of `openssh-server`.

- [ ] **Fix 7. Line 300: Update Gate 1.4 diagnosis — reference dropbear, not openssh-server**
  Change "openssh-server not installed" to "dropbear not running".

- [ ] **Fix 8. Lines 349-354: Fix vwifi-server launch — remove `-a` flag, correct ports, correct bind description**
  - Change launch command to: `bin/vwifi-server -u` (no `-a` flag — server binds INADDR_ANY by default per `csocketserverfunctionitcp.cc`)
  - Correct port numbers: VHOST=8211, TCP=8212, Spy=8213, Ctrl=8214 (from `config.h`)
  - Update description: "vwifi-server binds INADDR_ANY (0.0.0.0) by default — no bind-address flag or config.h patching needed"
  - Remove all mentions of patching config.h for bind address

- [ ] **Fix 9. Lines 359-371: Add STP disable + TAP user ownership**
  - Add after bridge creation: `ip link set mesha-br0 type bridge stp_state 0 forward_delay 0`
  - Change TAP creation to: `ip tuntap add dev mesha-tap${i} mode tap user $(whoami) 2>/dev/null || true`

- [ ] **Fix 10. Lines 385-386: Change qcow2 overlay backing format to raw**
  Change `-F qcow2` to `-F raw` (base image is raw ext4, not qcow2)

- [ ] **Fix 11. Lines 391-403: Fix CPU selection for TCG fallback**
  Replace static `-cpu host` with conditional:
  ```bash
  if [ -w /dev/kvm ]; then
    ACCEL="-enable-kvm"; CPU="-cpu host"
  else
    ACCEL="-accel tcg"; CPU="-cpu qemu64"; QEMU_TIMEOUT_MULTIPLIER=3
  fi
  ```

- [ ] **Fix 12. Lines 409-416: Move lock file from /tmp to run/**
  Change `LOCKFILE=/tmp/mesha-qemu-testbed.lock` to `LOCKFILE=run/testbed.lock`
  Update all references to this path (stop-mesh.sh cleanup, Gate 2.7, Gate 2.8, troubleshooting docs)

- [ ] **Fix 13. Line 456: Update cleanup lock path**
  Change `rm -rf /tmp/mesha-qemu-testbed.lock` to `rm -rf run/testbed.lock`

- [ ] **Fix 14. Line 480: Remove duplicate `service vwifi-client start`**
  Remove the first invocation at line 480. Keep only the one inside the lime-config sequence (line 499).

- [ ] **Fix 15. Lines 595-599: Correct vwifi port numbers in topology.yaml**
  Change:
  ```yaml
  server_port: 8210  →  server_port: 8211
  tcp_port: 8211     →  tcp_port: 8212
  spy_port: 8212     →  spy_port: 8213
  control_port: 8213 →  control_port: 8214
  ```

- [ ] **Fix 16. Line 623: Update Gate 2.1 port check**
  Change `grep 8211` to `grep 8212` (TCP primary port is 8212)

- [ ] **Fix 17. Lines 695-698: Fix IPv6 EUI-64 address**
  Change `fe80::5054:ff:fe00:2` to `fe80::5054:00ff:fe00:2`
  Update the explanation text to show correct EUI-64 derivation.

- [ ] **Fix 18. Lines 772-774: Correct file path references**
  - `discover-from-thisnode.sh:19` → `scripts/discover-from-thisnode.sh:19` (not `adapters/mesh/`)
  - `validate-node.sh:68` → `skills/mesh-rollout/scripts/validate-node.sh:68` (firmware check at 109-121)

- [ ] **Fix 19. Lines 788, 794, 800, 806: Fix SSH config IdentityFile paths**
  Add note: "Generate at runtime with absolute paths: `IdentityFile $(pwd)/run/ssh-keys/id_ed25519`"

- [ ] **Fix 20. Line 819: Add /etc/hosts alternative**
  Add after the /etc/hosts requirement:
  ```
  Alternative (no sudo): Use HOSTALIASES env var or curl --resolve thisnode.info:80:10.99.0.11
  ```

- [ ] **Fix 21. Line 1033: Rewrite Phase 4.6 vwifi-ctrl test**
  Change from "50% packet loss on a link" to:
  ```
  test_vwifi_ctrl_distance_based_loss — places VMs at distant coordinates via `vwifi-ctrl set`,
  enables loss with `vwifi-ctrl loss yes`, sets small scale with `vwifi-ctrl scale 0.001`,
  verifies BMX7 link quality degrades due to distance-based packet loss
  ```

- [ ] **Fix 22. Line 1127: Increase CI time budget**
  Change `< 5 min (KVM) or < 15 min (TCG)` to `< 10 min (KVM) or < 30 min (TCG)`

- [ ] **Fix 23. Line 1163: Add qemu-utils to CI deps**
  Add `qemu-utils` to apt-get install list in CI workflow

- [ ] **Fix 24. Line 1168: Add build-inputs.hash to cache key**
  Add `images/build-inputs.hash` to hashFiles and create the hash file concept

- [ ] **Fix 25. Line 1243: Increase total CI time budget**
  Change `< 10 minutes (with cached image)` to `< 30 minutes (with cached image, KVM) / < 60 minutes (TCG)`

- [ ] **Fix 26. Line 1423: Update CI resource table time**
  Change `~5 min (cached image) / ~15 min (first build)` to `~10 min (KVM, cached) / ~30 min (TCG) / ~2-4 hours (first build)`

- [ ] **Fix 27. Line 1301: Update troubleshooting lock file path**
  Change `/tmp/mesha-qemu-testbed.lock` to `run/testbed.lock`

- [ ] **Fix 28. Lines 1524-1528: Update CHANGELOG v3.2→v3.3 entry**
  Remove "Fixed vwifi-server bind address — Added `-a 10.99.0.254` flag" (was wrong).
  Add new v3.3→v3.4 changelog entry documenting all 23 corrections.

- [ ] **Fix 29. Update version header**
  Change version from `v3.3 (final)` to `v3.4 (corrected)` and date to 2026-04-25

- [ ] **Fix 30. Line 1592: Fix CHANGELOG v3→v3.1 port numbers**
  Change "8210 (VHOST), 8211 (TCP), 8212 (spy), 8213 (control)" to "8211 (VHOST), 8212 (TCP), 8213 (spy), 8214 (control)"

## Verification Criteria

- [ ] Every `-a` flag reference removed from vwifi-server commands
- [ ] All port numbers are 8211-8214 (not 8210-8213)
- [ ] Build sequence has feeds before defconfig
- [ ] qcow2 overlay uses `-F raw`
- [ ] CPU selection is conditional on KVM availability
- [ ] IPv6 address is `fe80::5054:00ff:fe00:2`
- [ ] Bridge STP is disabled
- [ ] TAP devices have `user $(whoami)`
- [ ] Lock file is at `run/testbed.lock`
- [ ] Duplicate vwifi-client start removed
- [ ] openssh-server removed from defconfig
- [ ] qemu-utils in both Docker and CI deps
- [ ] CI time budgets are realistic (30/60 min)
- [ ] Phase 4.6 test uses distance-based loss, not per-link percentage
- [ ] File paths match actual repo layout
- [ ] Version header says v3.4

## Potential Risks and Mitigations

1. **Cascading line number changes** — Each edit shifts line numbers for subsequent edits.
   Mitigation: Apply edits bottom-to-top (highest line numbers first) to preserve earlier line numbers.

2. **Internal consistency** — Some corrections appear in multiple locations (ports, lock file, paths).
   Mitigation: Use fs_search after all edits to verify no stale references remain.

3. **CHANGELOG accuracy** — The changelog references old port numbers and the `-a` flag.
   Mitigation: Update all changelog entries that reference corrected items.

## Alternative Approaches

1. **Create v3.4 as new file** — Leave v3.3 untouched, create `plans/2026-04-25-qemu-testbed-v3.4.md`. Preserves history but creates two files to maintain.
2. **Patch v3.3 in-place** — Single source of truth. Preferred approach.
