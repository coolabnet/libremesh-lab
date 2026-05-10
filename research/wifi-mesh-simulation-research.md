# WiFi Mesh Simulation Research

**Date:** 2026-05-09
**Status:** Research complete, awaiting specialist review
**Goal:** Find the best approach to fully test Mesha's mesh adapters against a simulated LibreMesh WiFi mesh network with real data frame forwarding

---

## The Problem

Mesha's QEMU testbed uses **vwifi** to simulate WiFi between 4 LibreMesh VMs. vwifi creates `mac80211_hwsim` radios inside each VM and relays frames via a TCP server on the host. **Management frames (beacons, probe requests) are relayed correctly, but data frames (including BMX7 OGMs) are not.** This means:

- IBSS/adhoc stations can see each other (beacon exchange works)
- But BMX7 cannot discover neighbors over WiFi (OGM data frames don't arrive)
- We use a dual-interface workaround: `bmx7 dev=wlan0 dev=br-lan` (wired bridge as fallback)
- WiFi-specific adapter data (signal_dbm, tx_rate, WiFi mesh links) is always null or stub

All 15 test suites pass with the dual-interface approach, but WiFi-specific adapter behavior cannot be fully tested.

---

## Projects Found

### 1. wmediumd -- THE canonical solution

| Field | Value |
|-------|-------|
| **Repository** | https://github.com/bcopeland/wmediumd (42 stars) |
| **Original** | https://github.com/cozybit/wmediumd (14 stars) |
| **Author** | Ben Greear (bcopeland), originally cozybit |
| **Language** | C |
| **License** | GPL-2.0 |
| **Dependencies** | libnl-3.0, Linux kernel with mac80211_hwsim |
| **Last active** | 2018 (bcopeland fork), original 2011 |

**What it does:**
wmediumd is a wireless medium simulation daemon for Linux. It intercepts ALL frames (management AND data) from `mac80211_hwsim` via a custom generic netlink family and applies configurable loss/delay models. It runs on the **host kernel** where all hwsim radios share the same L2 domain automatically.

**Key capabilities:**
- **Perfect medium mode** -- all traffic flows between configured interfaces (identified by MAC)
- **Per-link loss probability** -- fixed error probabilities for each directed link
- **Per-link SNR model** -- signal-to-noise ratios affect maximum data rates
- **Path loss model** -- derives SNR from node coordinates with log-distance propagation
- **802.11s mesh point support** -- the README example uses `iw dev wlan1 set type mp` + `iw dev wlan1 mesh join`
- **Network namespace support** -- uses `iw phy phyN set netns <pid>` to isolate nodes

**Example from README (802.11s mesh with network namespaces):**
```bash
sudo modprobe -r mac80211_hwsim
sudo modprobe mac80211_hwsim
sudo ./wmediumd/wmediumd -c ./tests/2node.cfg

# Window 2: create network namespace
sudo lxc-unshare -s NETWORK bash
ps | grep bash  # note pid

# Window 1: move phy2 to namespace, set up mesh
sudo iw phy phy2 set netns $pid
sudo ip link set wlan1 down
sudo iw dev wlan1 set type mp
sudo ip link set addr 42:00:00:00:00:00 dev wlan1
sudo ip link set wlan1 up
sudo ip addr add 10.10.10.1/24 dev wlan1
sudo iw dev wlan1 set channel 149
sudo iw dev wlan1 mesh join meshabc

# Window 2: set up mesh in namespace
sudo ip link set wlan2 down
sudo iw dev wlan2 set type mp
sudo ip link set addr 42:00:00:00:01:00 dev wlan2
sudo ip link set wlan2 up
sudo ip addr add 10.10.10.2/24 dev wlan2
sudo iw dev wlan2 set channel 149
sudo iw dev wlan2 mesh join meshabc
```

**Config file example (SNR model):**
```
ifaces :
{
    ids = [
        "02:00:00:00:00:00",
        "02:00:00:00:01:00",
        "02:00:00:00:02:00",
        "02:00:00:00:03:00"
    ];

    links = (
        (0, 1, 30),
        (0, 2, 10),
        (1, 2, 20)
    );
};
```

**Config file example (path loss model with positions):**
```
ifaces : {...};
model :
{
    type = "path_loss";
    positions = (
        (-50.0, 0.0),
        ( 0.0, 40.0),
        ( 0.0, -70.0),
        ( 50.0, 0.0)
    );
    tx_powers = (15.0, 15.0, 15.0, 15.0);
    model_name = "log_distance";
    path_loss_exp = 3.5;
    xg = 0.0;
};
```

**Why it solves our problem:**
- `mac80211_hwsim` radios on the same host kernel share the same L2 domain automatically -- both management AND data frames
- wmediumd adds loss/delay simulation on top
- Supports 802.11s mesh point mode (what LibreMesh actually uses)
- Supports IBSS/adhoc mode
- Supports SNR-based loss (would give us realistic `signal_dbm` values in adapter output)

**Limitations for our use case:**
- Runs on the **host kernel**, not inside QEMU VMs
- To use with QEMU VMs, you need to either:
  - (a) Use network namespaces instead of QEMU VMs (loses real OpenWrt kernel/userspace)
  - (b) Use PCI passthrough to give each VM its own hwsim radio (complex, needs VFIO support)
  - (c) Bridge host hwsim radios to VMs via TAP (VMs see WiFi as wired eth0)

**Gotchas documented in README:**
- MAC addresses must have bit 6 set in the most significant octet (`42:xx:xx:...` not `02:xx:xx:...`) on kernels before 4.1.0
- Rate table is hardcoded to 802.11a OFDM rates -- must use 5 GHz channels or supply a rateset with no CCK rates
- Traffic between local devices in Linux won't go over the wireless medium by default -- need separate network namespaces or routing rules

---

### 2. vwifi -- What we currently use

| Field | Value |
|-------|-------|
| **Repository** | https://github.com/Raizo62/vwifi |
| **OpenWrt package** | https://github.com/javierbrk/vwifi_cli_package.git |
| **Language** | C++ |
| **What** | Simulates WiFi between VMs via mac80211_hwsim + TCP relay |

**Architecture:**
- `vwifi-server` runs on the host, listening on TCP port 8212
- `vwifi-client` runs inside each VM, connecting to the server
- Each client creates `mac80211_hwsim` radios inside the VM via netlink (`HWSIM_CMD_NEW_RADIO`)
- Frames from one client are sent to the server, which relays to all other clients
- The server relays ALL frames (no filtering by frame type)

**What works:**
- PHY radio creation inside VMs
- IBSS/adhoc beacon exchange (stations see each other)
- `iw dev wlan0 station dump` shows all peers
- `iw dev wlan0 info` shows correct IBSS type
- Distance-based packet loss via `vwifi-ctrl`

**What doesn't work:**
- Data frames are NOT forwarded between VMs
- The server relays all frames, but the client's frame injection path doesn't properly deliver data frames to the local mac80211_hwsim stack
- The bug is likely in `ckernelwifi.cc` around lines 535-541 where `send_cloned_frame_msg` injects received frames

**Key source files (in `src/vwifi/src/`):**
- `ckernelwifi.cc` -- Client kernel WiFi interface, frame TX/RX
- `cwifiserver.cc` / `cwifiserveritcp.cc` -- TCP server, frame relay
- `cmonwirelessdevice.cc` -- Netlink RTM_NEWLINK monitor for detecting new interfaces
- `addinterfaces.cc` -- Creates hwsim radios via `HWSIM_CMD_NEW_RADIO`
- `cwirelessdevicelist.cc` -- Manages list of wireless interfaces per client

**The frame relay flow:**
1. Local process sends frame via wlan0
2. mac80211_hwsim generates `HWSIM_CMD_FRAME` netlink message
3. vwifi-client catches it in `process_messages()`
4. Client sends frame to vwifi-server via TCP
5. Server calls `SendAllOtherClients()` -- relays to all other clients (no frame type filtering)
6. Receiving client gets frame from server
7. Client iterates `_list_winterfaces.list_devices()` and calls `send_cloned_frame_msg` for each
8. **BUG:** The injected frame doesn't arrive at the mac80211_hwsim stack as a data frame

**Additional issues found during debugging:**
- `vwifi-add-interfaces` binary is glibc-linked, won't run on musl (OpenWrt)
- `nohup` doesn't exist on OpenWrt (ash shell)
- vwifi-client creates PHY radios but NOT wlan0 network interfaces (must use `iw phy <N> interface add wlan0 type ibss` manually)
- Phys accumulate across module reload cycles (never reused, always incrementing)

---

### 3. Bhaktirk269 GSoC Proposal

| Field | Value |
|-------|-------|
| **Repository** | https://github.com/Bhaktirk269/Adding-Wifi-Support-to-QEMU-Simulation-in-LibreMesh |
| **What** | GSoC 2025 project proposal for LibreMesh WiFi simulation |
| **Status** | Pseudocode only, not runnable code |
| **Stars** | 0 |

**Proposed approach:**
1. Load `mac80211_hwsim radios=4` on the HOST
2. Bridge virtual radios to QEMU VMs: `brctl addif br0 radio_interface`
3. Use BMX6 (not BMX7) for mesh routing
4. Test connectivity via `ping` and `bmx6 -c topology`

**Why it doesn't solve our problem:**
- `brctl addif br0 wlan0` bridges the host's wlan0 into a Linux bridge alongside the VM's TAP device
- The VM sees it as a **wired** interface (eth0 via virtio-net), NOT as wlan0
- There is no `iw dev wlan0 info` inside the VM showing IBSS or mesh point mode
- The WiFi simulation is invisible to the VM -- it just sees another wired connection
- Uses BMX6 instead of BMX7 (outdated)

**What we already have that this proposal doesn't:**
- Working WiFi interfaces inside VMs (wlan0 with IBSS mode, real `iw` output)
- vwifi-server frame relay (partial -- beacons work)
- 15 passing test suites
- Automated testbed lifecycle scripts
- Dual-interface BMX7 convergence

---

### 4. Linux Kernel mac80211_hwsim

| Field | Value |
|-------|-------|
| **Source** | `drivers/net/wireless/virtual/mac80211_hwsim.c` in Linux kernel |
| **Docs** | https://github.com/torvalds/linux/blob/master/drivers/net/wireless/virtual/mac80211_hwsim.c |

**Key features relevant to our problem:**
- Creates virtual WiFi radios that behave like real hardware
- All radios on the same kernel share the same L2 domain (frames forwarded automatically in-kernel)
- Supports wmediumd integration via `HWSIM_CMD_REGISTER` netlink command
- When wmediumd is NOT registered, uses default in-kernel frame forwarding (perfect medium, 0% loss)
- Supports network namespaces: `iw phy phyN set netns <pid>`
- Supports 802.11s mesh point, IBSS/adhoc, AP/STA modes
- **Has virtio transport support** -- `hwsim_tx_virtio()` and `hwsim_virtio_rx_work()` functions exist in the source, suggesting a built-in mechanism for cross-VM frame relay via virtio

**The virtio transport (potentially significant):**
The kernel source contains:
- `hwsim_virtio_enabled` macro
- `hwsim_tx_virtio()` function
- `hwsim_virtio_rx_work()` function
- `mac80211_hwsim_tx_frame_nl()` which sends frames via netlink

This suggests the kernel already has a mechanism to relay hwsim frames between VMs via virtio. If this works, it would be the cleanest solution -- no external TCP relay needed, just QEMU virtio devices.

---

### 5. Other Projects Searched (No Results)

- `freifunk-berlin/mesh-testbed` -- 404 (doesn't exist)
- `open80211s/open80211s` -- 404 (defunct)
- GitHub topic `wifi-mesh-simulation` -- No repositories tagged
- GitHub search `mac80211_hwsim mesh simulation` -- 0 results
- GitHub search `batman-adv mac80211_hwsim testbed` -- 0 results
- GitHub search `libremesh qemu simulation` -- Only Bhaktirk269 proposal

**Conclusion:** There is no established, working project that does cross-QEMU-VM WiFi mesh simulation with full data frame forwarding. Our LibreMesh Lab is the most advanced attempt at this.

---

## The Architectural Problem

```
SINGLE KERNEL (wmediumd approach -- WORKS):
+-----------------------------------------+
|  Host Linux Kernel                       |
|  +------+ +------+ +------+ +------+   |
|  |phy0  | |phy1  | |phy2  | |phy3  |   |
|  |wlan0 | |wlan1 | |wlan2 | |wlan3 |   |
|  +--+---+ +--+---+ +--+---+ +--+---+   |
|     +--------+--------+--------+        |
|       mac80211_hwsim in-kernel relay    |
|       (or wmediumd for loss simulation) |
+-----------------------------------------+
Result: ALL frames forwarded, including data

SEPARATE KERNELS (vwifi approach -- BROKEN):
+----------+  +----------+
| VM1      |  | VM2      |
| kernel A |  | kernel B |
| phy0     |  | phy0     |
| wlan0    |  | wlan0    |
| vwifi-   |  | vwifi-   |
| client   |  | client   |
+----+-----+  +----+-----+
     |   TCP relay   |
     +-------+-------+
       vwifi-server
Result: Only management frames relay properly
Result: Data frames lost in translation
```

The fundamental challenge: `mac80211_hwsim` was designed for single-kernel testing. The kernel's own WiFi stack tests use it this way. Cross-VM WiFi simulation requires either sharing the same kernel (network namespaces), bridging host radios to VMs (loses WiFi semantics), or external frame relay (what vwifi does, but data frames are broken).

---

## Current Mesha Testbed State

**Working (15/15 test suites passing):**

| Feature | Status | How |
|---------|--------|-----|
| SSH connectivity to nodes | Works | Wired bridge (br-lan) |
| collect-nodes.sh -- hostname, firmware, uptime | Works | Standard OpenWrt commands |
| collect-nodes.sh -- interfaces list (including wlan0) | Works | wlan0 appears with IBSS type |
| collect-nodes.sh -- BMX7 mesh neighbors | Works | BMX7 converges via br-lan |
| collect-topology.sh -- node discovery, links, metrics | Works | BMX7 over br-lan |
| Config drift detection (UCI reads/writes) | Works | Full UCI access |
| Firmware version detection | Works | /etc/openwrt_release |
| Node removal detection | Works | BMX7 expiry over br-lan |
| Babeld fallback | Works | Over br-lan |
| Rollback, maintenance windows, staging | Works | All SSH-based |

**Not working (vwifi limitation):**

| Feature | Status | Why |
|---------|--------|-----|
| BMX7 links over WiFi (wlan0) | Broken | vwifi IBSS doesn't forward data frames |
| WiFi signal strength (signal_dbm) | Always null | No real radio propagation |
| WiFi tx/rx rates on mesh links | Always null | Links are over br-lan, not wlan0 |
| vwifi distance-based link degradation | Skipped | BMX7 prefers br-lan |
| 802.11s mesh peering | Broken | Same vwifi data frame limitation |
| iwinfo radio details | Stub data | UCI wireless config is default, not real |

**Files modified to get here:**
- `scripts/qemu/start-vwifi.sh` -- Added stale process cleanup
- `scripts/qemu/configure-vms.sh` -- Dual-interface BMX7 (`dev=wlan0 dev=br-lan`)
- `tests/qemu/common.sh` -- Fixed `ensure_vwifi_client()` (no nohup, manual wlan0 creation)
- `tests/qemu/test-topology-manipulation.sh` -- Skip vwifi distance test with clear reason

---

## Follow-up Suggestions

### Option A: Network Namespace Approach (simplest, best WiFi simulation)

**Effort:** Medium
**Risk:** Low
**WiFi fidelity:** Full

Run `mac80211_hwsim radios=4` + wmediumd on the host. Create 4 network namespaces, each with one hwsim radio. Run OpenWrt userspace in each namespace (using `chroot` or `proot` with the OpenWrt rootfs from the existing qcow2 image).

**Pros:**
- Full WiFi simulation including data frames, SNR, path loss
- BMX7 sees real wlan0 with real WiFi behavior
- Signal strength, tx/rx rates, link quality all work
- wmediumd provides configurable loss/delay models
- No QEMU overhead (faster test execution)
- Can reuse existing OpenWrt rootfs

**Cons:**
- No real OpenWrt kernel (uses host kernel, not OpenWrt's patched kernel)
- OpenWrt-specific kernel modules (like some BMX7 kernel features) may not be available
- Network namespace management adds complexity
- Some UCI wireless config may not behave identically

**Investigation needed:**
- Can we extract the OpenWrt rootfs from the qcow2 image and chroot into it?
- Does BMX7 work correctly on a stock host kernel vs OpenWrt kernel?
- How to handle /proc, /sys, /dev in the chroot?

### Option B: Patch vwifi (incremental improvement)

**Effort:** Medium-High (C++ debugging)
**Risk:** Medium
**WiFi fidelity:** Depends on fix quality

Debug and fix vwifi's data frame injection path. The server already relays all frames -- the bug is in the client.

**Investigation needed:**
- Compare vwifi's `send_cloned_frame_msg` in `ckernelwifi.cc:535-541` with how wmediumd's modified `mac80211_hwsim` module does frame injection
- The original cozybit/wmediumd includes a modified `mac80211_hwsim` kernel module that supports userspace frame TX -- vwifi may need a similar approach
- Check if the frame needs different netlink attributes when injected as "received" vs "transmitted"
- Check if `mac80211_hwsim` in the VM's kernel has the `HWSIM_CMD_REGISTER` interface that wmediumd uses

**Pros:**
- Minimal architectural change -- keep existing QEMU testbed
- Real OpenWrt kernel and userspace in each VM
- If fixed, all WiFi adapter testing works as-is

**Cons:**
- May require modifying the OpenWrt kernel's mac80211_hwsim module
- vwifi is not actively maintained (last update unclear)
- Frame injection bugs can be subtle (kernel netlink API edge cases)

### Option C: mac80211_hwsim Virtio Transport (potentially the cleanest)

**Effort:** High (kernel-level work)
**Risk:** High (experimental kernel feature)
**WiFi fidelity:** Full

The Linux kernel source shows `hwsim_tx_virtio()` and `hwsim_virtio_rx_work()` functions in `mac80211_hwsim.c`, suggesting a built-in virtio transport for cross-VM frame relay.

**Investigation needed:**
- Read the kernel source to understand the virtio hwsim transport
- Check if QEMU can expose hwsim virtio devices to VMs
- Check kernel version requirements (may need very recent kernel)
- Check if this feature is actually complete and functional

**Pros:**
- No external relay needed -- kernel does it natively
- Full WiFi semantics inside each VM
- Real OpenWrt kernel in each VM
- Clean architecture

**Cons:**
- May be incomplete or experimental kernel feature
- Requires kernel version that OpenWrt may not have
- Complex to set up (virtio device configuration)
- No documentation found

### Option D: Hybrid wmediumd + QEMU (compromise)

**Effort:** Medium
**Risk:** Medium
**WiFi fidelity:** Partial (WiFi queries in namespace, mesh in VM)

Run `mac80211_hwsim radios=4` + wmediumd on the host. Each radio gets its own network namespace. Each namespace has a TAP device bridged to a QEMU VM. The namespace's wlan0 is bridged to the VM's eth0.

**Pros:**
- WiFi queries (`iw`, `iwinfo`) work in the namespace
- Full OpenWrt in the VM
- wmediumd provides loss simulation

**Cons:**
- VMs still see WiFi as wired eth0
- WiFi-specific adapter queries must run in the namespace, not the VM
- Complex setup (namespace + bridge + QEMU per node)
- Adapter tests need to know whether to SSH to VM or run in namespace

---

## Questions for Specialist

1. **Is the mac80211_hwsim virtio transport functional?** Check `drivers/net/wireless/virtual/mac80211_hwsim.c` for `hwsim_tx_virtio` / `hwsim_virtio_rx_work` -- is this a complete feature or stub?

2. **Can wmediumd work with network namespaces + OpenWrt chroot?** What's the minimal setup to get BMX7 running in a namespace with a chrooted OpenWrt rootfs?

3. **What's the root cause of vwifi's data frame bug?** Compare vwifi's `send_cloned_frame_msg` with wmediumd's modified mac80211_hwsim module's frame injection path.

4. **What approach do BMX7/batman-adv developers use for testing?** They must test mesh protocols somehow -- do they use wmediumd + namespaces?

5. **Is there a way to pass a host mac80211_hwsim PHY to a QEMU VM** while preserving WiFi semantics inside the VM? (PCI passthrough? USB passthrough of a virtual device?)

---

## Links

- wmediumd (bcopeland fork): https://github.com/bcopeland/wmediumd
- wmediumd (original cozybit): https://github.com/cozybit/wmediumd
- vwifi: https://github.com/Raizo62/vwifi
- vwifi OpenWrt package: https://github.com/javierbrk/vwifi_cli_package.git
- Bhaktirk269 GSoC proposal: https://github.com/Bhaktirk269/Adding-Wifi-Support-to-QEMU-Simulation-in-LibreMesh
- Linux mac80211_hwsim source: https://github.com/torvalds/linux/blob/master/drivers/net/wireless/virtual/mac80211_hwsim.c
- Linux wireless wiki: https://wireless.wiki.kernel.org/
- mac80211_hwsim kernel docs: https://www.kernel.org/doc/html/latest/driver-api/80211/mac80211_hwsim.html
- LibreMesh Lab vwifi source: `src/vwifi/`
- LibreMesh Lab vwifi README: `src/vwifi/README.md`
