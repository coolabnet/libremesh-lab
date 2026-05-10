# QEMU LibreMesh Test Bed — Corrected Implementation Plan

**Date:** 2026-04-19
**Version:** v3 (final)
**Status:** Ready for Implementation
**Author:** Muse + Forge (Technical Review)
**Supersedes:** v2 (2026-04-18) — see CHANGELOG at end

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
5. **vwifi relay**: vwifi-server on the host (10.99.0.254) is reachable from all VMs for WiFi frame relay.

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
| GAP 2: vwifi-server | Compile from Raizo62/vwifi on host; TCP mode (not VHOST) with `-u` flag for multi-VM identification | Phase 2 |
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
  - Clones OpenWrt BuildRoot (specific tag, e.g., v23.05.x)
  - Adds LibreMesh feeds per lime-packages documentation
  - Adds vwifi feed: `echo 'src-git vwifi https://github.com/javierbrk/vwifi_cli_package.git' >> feeds.conf`
  - Cherry-picks commit `89bc4284bb0b` from lime-packages (802.11ax 6GHz fix) into the local feed
  - Selects target `x86/64` (subtarget `generic`)
  - Includes packages: `kmod-mac80211-hwsim`, `vwifi-client`, `bmx7`, `babeld`, `ip-full`, `iwinfo`, `uci`, `ubus`, `uhttpd`, `openssh-server`, `python3-light`, `netcat`
  - Runs `make -j$(nproc)`
  - Outputs `openwrt-x86-64-generic-ext4-combined.img.gz` to `images/`
  - Records build manifest (package list, commit hashes) in `images/build-manifest.yaml`

- [ ] **1.2 Create Docker-based build environment** at `docker/qemu-builder/Dockerfile`:
  - Based on `ubuntu:22.04` with build dependencies: `build-essential`, `cmake`, `g++`, `pkg-config`, `libncurses-dev`, `zlib1g-dev`, `gawk`, `git`, `gettext`, `libssl-dev`, `rsync`, `swig`, `unzip`, `wget`, `python3`, `libnl-3-dev`, `libnl-genl-3-dev`
  - Entry point: runs the build script from 1.1
  - Enables reproducible builds on any host with Docker

- [ ] **1.3 Create image versioning and caching strategy:**
  - Filename pattern: `libremesh-x86-64-{short-commit-hash}-{date}.img.gz`
  - `images/.cache-version` tracks the latest built version
  - Build script checks if cached image matches current source hashes before rebuilding
  - GitHub Actions artifact upload/download steps for CI caching (7-day retention)

- [ ] **1.4 Create `images/README.md`** documenting:
  - How to build from scratch
  - How to use pre-built images from LibreRouterOS releases (noting WiFi limitation)
  - Where cached images are stored
  - What packages are included and why

**Verification Criteria:**
- Built image boots in QEMU to a login prompt
- `mac80211_hwsim` module loads with `radios=0` (zero radios — vwifi-client creates its own via `vwifi-add-interfaces`)
- SSH server accepts connections (passwordless root login — OpenWrt default)
- `ip -j addr show` works (ip-full installed)
- `vwifi-add-interfaces` and `vwifi-client` commands are available
- `python3` is available (needed by Mesha adapter scripts for JSON parsing)

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
  - Launches in TCP mode: `bin/vwifi-server -u` (use-port-in-hash for multi-VM identification when VMs share the same L2 network)
  - PID tracked in `run/vwifi-server.pid`
  - Default ports: 8210 (VHOST, unused), 8211 (TCP primary), 8212 (spy), 8213 (control) — configurable via `src/config.h` before build
  - Optional: `-l 0.01` for 1% packet loss simulation (configurable via env var)
  - vwifi-server listens on 0.0.0.0:8211, reachable from all VMs via bridge at 10.99.0.254:8211
  - **Important**: We use TCP mode (not VHOST) because VMs have their own IPs on the TAP/bridge network. VHOST mode requires `vhost_vsock` kernel module and per-VM CID numbers, which adds unnecessary complexity.

- [ ] **2.2 Create host networking setup function** in `scripts/qemu/start-mesh.sh`:
  - Creates the Linux bridge and TAP devices before launching VMs:
    ```bash
    setup_host_networking() {
      # Create bridge for test bed management subnet
      ip link add name mesha-br0 type bridge 2>/dev/null || true
      ip addr add 10.99.0.254/16 dev mesha-br0 2>/dev/null || true
      ip link set mesha-br0 up

      # Create TAP devices for each VM (4 VMs)
      for i in 0 1 2 3; do
        ip tuntap add dev mesha-tap${i} mode tap 2>/dev/null || true
        ip link set mesha-tap${i} master mesha-br0 2>/dev/null || true
        ip link set mesha-tap${i} up
      done
    }
    ```
  - Requires the user running the script to have `CAP_NET_ADMIN` (typically via `sudo` for these operations, or run as root in CI)
  - Idempotent: uses `2>/dev/null || true` to avoid errors if devices already exist
  - The host IP 10.99.0.254 serves as:
    - SSH gateway to reach any VM
    - vwifi-server relay endpoint (10.99.0.254:8212)
    - Default gateway for VMs if needed

- [ ] **2.3 Create VM launch script** at `scripts/qemu/start-mesh.sh`:
  - Reads topology from `config/topology.yaml` (3 LibreMesh nodes + 1 tester)
  - Calls `setup_host_networking()` before launching VMs
  - For each VM, creates a qcow2 overlay backed by the base image:
    ```bash
    qemu-img create -f qcow2 -b images/libremesh-x86-64-base.img \
      -F qcow2 run/node-{N}.qcow2
    ```
  - Launches each VM with TAP networking for mesh0 and user-mode for wan0:
    ```bash
    qemu-system-x86_64 \
      -enable-kvm -M q35 -cpu host -smp 2 -m ${RAM_MB}M \
      -nographic \
      -drive file=run/node-${N}.qcow2,format=qcow2 \
      -device virtio-net-pci,netdev=mesh0,mac=${MAC_MESH} \
      -netdev tap,id=mesh0,ifname=mesha-tap${TAP_INDEX},script=no,downscript=no \
      -device virtio-net-pci,netdev=wan0,mac=${MAC_WAN} \
      -netdev user,id=wan0
    ```
  - Key differences from v1:
    - mesh0 uses `-netdev tap` instead of `-netdev user` — VMs share L2 via bridge
    - No `hostfwd` port forwarding needed — host reaches VMs directly at 10.99.0.x
    - No `net=` parameter on mesh0 — IP addressing is configured inside each VM
  - KVM detection: if `/dev/kvm` unavailable, uses `-accel tcg` and sets `QEMU_TIMEOUT_MULTIPLIER=3`
  - Each VM runs in background with PID tracked in `run/node-{N}.pid`

- [ ] **2.4 Create concurrent run protection** at the top of `start-mesh.sh`:
  - Uses `mkdir`-based lock file (atomic on all Linux filesystems):
    ```bash
    LOCKFILE=/tmp/mesha-qemu-testbed.lock
    if ! mkdir "$LOCKFILE" 2>/dev/null; then
      echo "ERROR: Test bed already running (PID $(cat $LOCKFILE/pid 2>/dev/null || 'unknown'))"
      echo "Run 'bash scripts/qemu/stop-mesh.sh' first, or remove $LOCKFILE manually."
      exit 1
    fi
    echo $$ > "$LOCKFILE/pid"
    trap 'rm -rf "$LOCKFILE"' EXIT
    ```
  - The lock is automatically released when the script exits (any reason)
  - `stop-mesh.sh` also removes the lock as part of cleanup
  - Prevents port conflicts, duplicate TAP devices, and resource exhaustion

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
      rm -rf /tmp/mesha-qemu-testbed.lock

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
    - Creates virtual WiFi interfaces: `vwifi-add-interfaces 2 52:54:00:02:{N}:00` (2 interfaces per VM, unique MAC prefix)
    - Configures vwifi-client via UCI (not direct CLI):
      ```
      uci set vwifi.config.server_ip='10.99.0.254'
      uci set vwifi.config.mac_prefix='52:54:00:02:{N}'
      uci set vwifi.config.enabled='1'
      uci commit vwifi
      ```
    - Starts vwifi-client service: `service vwifi-client start`
    - Configures BMX7 on the WiFi interface (wlan0)
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
         echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config && \
         /etc/init.d/sshd restart"
    done
    ```
  - This two-phase approach (password first, then key) works because:
    1. OpenWrt ships with `PermitRootLogin yes` and empty password by default
    2. First SSH uses password auth (empty password)
    3. After key injection, lock down to key-only auth
  - Configures tester VM (node 4) as Mesha ops host:
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
      server_port: 8210  # VHOST port (unused in TCP mode)
      tcp_port: 8211  # TCP primary (vwifi-server default)
      spy_port: 8212  # Spy port
      control_port: 8213  # Control port
      listen_address: "10.99.0.254"  # Host bridge IP, reachable from all VMs
      packet_loss: 0.0  # 0.0 to 1.0
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

**Verification Criteria:**
- `start-mesh.sh` launches 4 VMs within 90 seconds (KVM) or 270 seconds (TCG)
- All 4 VMs respond to SSH from host at 10.99.0.x within the timeout
- VMs can ping each other (e.g., VM1 can ping 10.99.0.12)
- vwifi-client connects to vwifi-server from each VM
- Host can SSH to any VM at 10.99.0.x
- Second run of `start-mesh.sh` fails with lock error
- `stop-mesh.sh` cleanly terminates all processes and removes bridge/TAP devices
- No tmux dependency required
- No orphaned processes after stop or crash

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
    - `validate-node.sh:68` reads `${WORKSPACE_ROOT}/desired-state/mesh/firmware-policy.yaml`
    - `discover-from-thisnode.sh:19` hardcodes `TARGET_HOST="thisnode.info"`
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
      IdentityFile run/ssh-keys/id_ed25519
      StrictHostKeyChecking no

    Host lm-testbed-node-2
      HostName 10.99.0.12
      User root
      IdentityFile run/ssh-keys/id_ed25519
      StrictHostKeyChecking no

    Host lm-testbed-node-3
      HostName 10.99.0.13
      User root
      IdentityFile run/ssh-keys/id_ed25519
      StrictHostKeyChecking no

    Host lm-testbed-tester
      HostName 10.99.0.14
      User root
      IdentityFile run/ssh-keys/id_ed25519
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

**Verification Criteria:**
- `collect-nodes.sh lm-testbed-node-1` returns valid JSON with `reachable: true`
- `collect-topology.sh lm-testbed-node-1` returns JSON with `node_count >= 3`
- `discover-from-thisnode.sh` completes successfully against VM1
- `validate-node.sh lm-testbed-node-1` reports PASS for SSH, firmware, uptime checks
- `ip -j addr show` returns parseable JSON (not empty or error)
- Tester VM can SSH to all other VMs and run adapters

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
  - `test_vwifi_ctrl_adds_packet_loss` — uses vwifi-ctrl to add 50% packet loss on a link, verifies BMX7 link quality degrades
  - `test_node_removal_detected` — stops one VM, verifies `collect-topology.sh` reports fewer nodes

- [ ] **4.7 Create assertion library** (GAP 15 resolution):
  - Range assertions: `assert_json_gte "$json" ".node_count" 3`
  - Presence assertions: `assert_json_not_null "$json" ".hostname"`
  - Settled assertions: `wait_until_json_gte "$json" ".node_count" 3 --timeout 60`
  - All assertions output TAP-compatible results for CI integration

**Verification Criteria:**
- All tests in `tests/qemu/` pass against a running 4-VM mesh
- Tests produce TAP-compatible output
- Tests complete within 5 minutes (KVM) or 15 minutes (TCG)
- Tests are idempotent: can be re-run without rebuilding VMs

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
            sudo apt-get install -y qemu-system-x86 cmake g++ libnl-3-dev libnl-genl-3-dev iproute2
        - name: Cache firmware image
          uses: actions/cache@v4
          with:
            path: images/
            key: libremesh-x86-64-${{ hashFiles('scripts/qemu/build-libremesh-image.sh') }}
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

**Verification Criteria:**
- QEMU integration tests run successfully in GitHub Actions
- Firmware image is cached and reused across runs
- Docker onboarding tests continue to work independently
- CI pipeline completes within 10 minutes on GitHub-hosted runner
- Nightly run produces full test report
- TAP/bridge cleanup succeeds even after CI job termination

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
  - Lock file stuck: how to manually clean up `/tmp/mesha-qemu-testbed.lock`
  - Orphaned QEMU processes: `ps aux | grep qemu`, `kill` commands

- [ ] **6.5 Track upstream GSoC 2025 sub-issues:**
  - Monitor lime-packages issues #1181-#1185 for completion
  - When vwifi integration improves, update build pipeline
  - When shared-state-async tests are available, integrate

**Verification Criteria:**
- Firmware upgrade simulation completes successfully
- At least 2 topology configurations work
- Documentation enables a new contributor to set up the test bed independently
- Troubleshooting guide covers the 8 most common failure modes

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
| Time | ~5 min (cached image) / ~15 min (first build) |
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

### v2 → v3 (2026-04-19)

**Technical corrections from deep codebase review:**

1. **vwifi TCP mode (not VHOST)** — Corrected from mixed VHOST/TCP to pure TCP mode. With TAP/bridge networking, VMs have their own IPs and TCP mode is the natural choice. VHOST mode requires `vhost_vsock` kernel module and per-VM CID numbers via `-device vhost-vsock-pci,guest-cid=N`.

2. **vwifi-client UCI configuration** — Corrected from direct CLI invocation (`vwifi-client 10.99.0.254:8212`) to proper OpenWrt UCI config (`uci set vwifi.config.server_ip=...` + `service vwifi-client start`). Verified against javierbrk/vwifi_cli_package README.

3. **Added `vwifi-add-interfaces` step** — vwifi requires creating wlan interfaces BEFORE starting vwifi-client. Added `vwifi-add-interfaces 2 <mac-prefix>` step in configure-vms.sh.

4. **mac80211_hwsim radios=0** — Corrected from unspecified to `radios=0`. vwifi-client creates its own interfaces via `vwifi-add-interfaces`; mac80211_hwsim must start with zero radios.

5. **Fixed build dependencies** — Added `pkg-config`, `make`, `libnl-3-dev`, `libnl-genl-3-dev` to both vwifi-server build and Docker builder.

6. **Fixed vwifi-server port numbers** — Corrected from 8211-8214 to actual defaults from vwifi source: 8210 (VHOST), 8211 (TCP), 8212 (spy), 8213 (control).

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

8. **vwifi-server listen address:** Explicitly bound to bridge IP 10.99.0.254 so all VMs can reach it.

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
