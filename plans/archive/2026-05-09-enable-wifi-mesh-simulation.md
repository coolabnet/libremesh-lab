# Enable WiFi Mesh Simulation in QEMU Testbed

**Date:** 2026-05-09
**Status:** Ready for Investigation & Implementation
**Context:** The QEMU testbed currently runs BMX7 over wired br-lan (all VMs share a host bridge). The goal is to enable full WiFi mesh simulation using `mac80211_hwsim` + `vwifi` so that BMX7 runs over virtual wlan interfaces and adapters can be tested against realistic wireless mesh behavior including distance-based link degradation.

---

## Objective

Make the QEMU testbed run BMX7 over virtual WiFi interfaces (wlan0/wlan1) instead of wired br-lan, using the `vwifi` project (https://github.com/Raizo62/vwifi) to simulate wireless propagation between VMs. When complete:

1. BMX7 runs on `wlan0` (or similar virtual wlan) on all mesh nodes
2. `vwifi-server` on the host relays WiFi frames between VMs
3. `vwifi-ctrl` can simulate distance/mobility, causing BMX7 link quality to degrade
4. The `test_vwifi_ctrl_distance_based_loss` test (currently skipped) passes
5. All adapter tests (`collect-topology.sh`, `collect-nodes.sh`) work against WiFi-based BMX7
6. All existing tests that pass on wired mesh continue to pass on WiFi mesh

---

## Current State

### What works (wired mesh over br-lan)

- 4 QEMU VMs boot with source-built LibreMesh images
- BMX7 runs on `br-lan` (wired), converges with 2 neighbors per node
- All test suites pass (12/12 tests, 1 skip for vwifi distance test)
- Adapters correctly parse BMX7 IPv6 output and resolve to IPv4 via EUI-64 + ARP

### What exists but is NOT working (WiFi simulation)

| Component | Location | Status |
|---|---|---|
| `mac80211_hwsim` kernel module | Loaded on all VMs | Loaded with `radios=0` (no wlan interfaces created) |
| `vwifi-client` binary | `/usr/sbin/vwifi-client` on VMs | Installed but not running, UCI config has wrong `server_ip` and `enabled='0'` |
| `vwifi-server` binary | `src/vwifi/build/vwifi-server` on host | Built but NOT running (no process found) |
| `vwifi-ctrl` binary | `bin/vwifi-ctrl` on host | Built, available |
| `vwifi-add-interfaces` binary | `src/vwifi/build/vwifi-add-interfaces` on host | Built but NOT present on VMs — `configure-vms.sh:160` tries to run it on VMs and silently fails |
| `start-vwifi.sh` | `scripts/qemu/start-vwifi.sh` | Compiles and launches vwifi-server on host, called by `start-mesh.sh` |
| `configure-vms.sh` vwifi setup | Lines 155-243 | Has code for vwifi but falls through to bare OpenWrt path (no lime-config), which starts bmx7 on br-lan instead |

### Key findings from investigation

1. **`vwifi-add-interfaces` is a HOST tool, not a VM tool.** The vwifi README shows it runs on the guest VM, but it's NOT included in the `vwifi` opkg package installed on the VMs. The opkg package only contains: `vwifi-client`, `vwifi-client` init script, `mac80211_hwsim` module load, and UCI config. The `vwifi-add-interfaces` binary only exists at `src/vwifi/build/vwifi-add-interfaces` on the HOST.

2. **vwifi architecture (from README):**
   - `vwifi-server` runs on the HOST, relays WiFi frames between VMs
   - `vwifi-client` runs on each VM, connects to `vwifi-server` via TCP or VHOST
   - `vwifi-add-interfaces` creates wlan interfaces via `mac80211_hwsim` — runs on each VM
   - `vwifi-ctrl` controls the server (distance, loss, scale) — runs on the HOST
   - For TCP mode: `vwifi-server` and `vwifi-client` must be on a DIFFERENT IP network than WiFi

3. **Current vwifi-server uses TCP mode** (`start-vwifi.sh` launches with `-u -t 8212`). The server binds to INADDR_ANY. VMs need to connect to `10.99.0.254` (bridge IP) on port 8212.

4. **The VMs' vwifi UCI config is wrong:**
   - `server_ip='172.16.0.1'` (should be `10.99.0.254`)
   - `enabled='0'` (should be `1`)
   - `mac_prefix='74:f8:f6:66'` (should match node MAC prefix like `52:54:00:00:01`)

5. **`configure-vms.sh` line 160** runs `vwifi-add-interfaces 2 ${mac_prefix}` on the VM via SSH, but the binary doesn't exist on the VM. This silently fails (`|| true`).

6. **The "Bare OpenWrt" path** (no lime-config) at `configure-vms.sh:210-244` configures wireless for adhoc mode but then starts bmx7 on br-lan with the comment: "vwifi IBSS doesn't forward beacons between VMs — wireless adhoc discovery fails." This suggests adhoc mode over vwifi was attempted but didn't work.

---

## Key Files

| File | Purpose |
|---|---|
| `scripts/qemu/start-mesh.sh` | Launches QEMU VMs, calls `start-vwifi.sh`, sets up host networking |
| `scripts/qemu/start-vwifi.sh` | Compiles and launches `vwifi-server` on host |
| `scripts/qemu/configure-vms.sh` | Post-boot VM configuration (networking, vwifi, bmx7) |
| `config/topology.yaml` | Node definitions, vwifi config, network config |
| `src/vwifi/` | vwifi source code (cloned from GitHub) |
| `src/vwifi/README.md` | vwifi documentation with setup instructions |
| `tests/qemu/test-topology-manipulation.sh` | Contains `test_vwifi_ctrl_distance_based_loss` (currently skipped) |
| `tests/qemu/common.sh` | Test helpers including `wait_for_bmx7`, `ssh_vm` |
| `adapters/mesh/collect-topology.sh` | Topology adapter (already handles IPv6 BMX7) |
| `adapters/mesh/collect-nodes.sh` | Node adapter (already handles IPv6 BMX7) |

---

## Investigation Tasks

### Task 1: Understand why vwifi-adhoc doesn't forward beacons

The `configure-vms.sh:234` comment says "vwifi IBSS doesn't forward beacons between VMs — wireless adhoc discovery fails." Investigate:

- Does vwifi actually support IBSS/adhoc mode? The README shows adhoc examples (Test 3).
- Is the issue that `vwifi-server` isn't running when `configure-vms.sh` runs?
- Is the issue that `vwifi-client` isn't connected to the server?
- Is the issue that wlan interfaces aren't created because `vwifi-add-interfaces` failed?
- Could we use 802.11s mesh mode instead of IBSS adhoc? BMX7 can run on top of 802.11s.

**How to test:** Start vwifi-server manually, then manually run vwifi-add-interfaces and vwifi-client on a VM, configure adhoc, and see if beacons flow.

### Task 2: Get vwifi-add-interfaces onto the VMs

Options:
- A) Copy the host-built binary to each VM via SCP during `configure-vms.sh`
- B) Build `vwifi-add-interfaces` as an OpenWrt package and include it in the image
- C) Use `vwifi-client --number N --mac XX:XX:XX:XX:XX` instead (README says vwifi-client can also create interfaces)
- D) Check if `mac80211_hwsim radios=N` (with N>0) creates interfaces automatically, bypassing the need for `vwifi-add-interfaces`

### Task 3: Verify vwifi-server connectivity from VMs

The vwifi-server uses TCP mode on port 8212. The VMs connect via the bridge IP (10.99.0.254). Verify:
- vwifi-server is running and listening on port 8212
- VMs can reach 10.99.0.254:8212 via TCP
- vwifi-client on VMs can connect and register

### Task 4: Determine the correct BMX7-over-wifi configuration

Once wlan interfaces exist and vwifi relays frames:
- Should bmx7 run on `wlan0` directly? On a bridge containing wlan0?
- Does bmx7 need `dev=wlan0` or can it auto-detect?
- Does the adhoc mode need to be set up first (`iw wlan0 set type ibss; iw wlan0 ibss join ...`)?
- Or should we use 802.11s mesh point mode?

### Task 5: Assess impact on existing tests

Some tests may need adjustment:
- `wait_for_bmx7` in `common.sh` starts bmx7 with `dev=br-lan` — needs to use `dev=wlan0` (or whatever the WiFi interface is)
- `test-mesh-protocols.sh` restarts bmx7 with `dev=br-lan` — same
- `test-topology-manipulation.sh` stops/restarts bmx7 — same
- `test-failure-paths.sh` reboots nodes — bmx7 and vwifi-client need to restart after reboot
- Adapter IPv6 resolution may work differently over WiFi (different ARP/neighbor behavior)

---

## Implementation Plan

### Phase 1: Manual proof-of-concept (investigation)

Get WiFi mesh working manually on running VMs before automating:

1. Start `vwifi-server` on the host:
   ```bash
   src/vwifi/build/vwifi-server -u -t 8212 &
   ```

2. On each VM, create wlan interfaces. Try option C first (vwifi-client can create them):
   ```bash
   ssh_vm node "vwifi-client --number 2 --mac 52:54:00:00:0N 10.99.0.254"
   ```
   Or copy `vwifi-add-interfaces` to the VM:
   ```bash
   scp vwifi-add-interfaces root@10.99.0.1N:/tmp/
   ssh_vm node "/tmp/vwifi-add-interfaces 2 52:54:00:00:0N"
   ```

3. Verify wlan interfaces appear: `ssh_vm node "iw dev" && ip link show wlan0`

4. Set up adhoc mode on each VM:
   ```bash
   ssh_vm node "ip link set wlan0 up; iw wlan0 set type ibss; iw wlan0 ibss join MeshaTestBed 2462"
   ```

5. Start bmx7 on wlan0:
   ```bash
   ssh_vm node "bmx7 dev=wlan0"
   ```

6. Check if BMX7 sees neighbors: `ssh_vm node "bmx7 -c links"`

7. If neighbors are visible, test distance simulation:
   ```bash
   vwifi-ctrl ls                    # list connected VMs
   vwifi-ctrl set 3 10000 10000 0   # move node-3 far away
   vwifi-ctrl loss yes              # enable distance-based loss
   vwifi-ctrl scale 0.001           # small scale = far distances
   # Wait and check bmx7 link quality
   ```

### Phase 2: Automate in configure-vms.sh

Once the manual procedure works, update `configure-vms.sh` to:

1. Ensure vwifi-server is running before configuring VMs
2. Copy `vwifi-add-interfaces` to VMs (or use vwifi-client's built-in interface creation)
3. Set correct vwifi UCI config (`server_ip=10.99.0.254`, `enabled=1`)
4. Start vwifi-client on each VM
5. Configure wlan interfaces for adhoc or 802.11s mesh
6. Start bmx7 on wlan0 instead of br-lan
7. Verify mesh convergence over WiFi

### Phase 3: Update test infrastructure

1. Update `common.sh` `wait_for_bmx7()` to detect the correct interface (wlan0 vs br-lan)
2. Update all bmx7 restart commands in test files
3. Un-skip `test_vwifi_ctrl_distance_based_loss`
4. Ensure adapters work with WiFi-based BMX7 (may need different ARP resolution)
5. Run full test suite and verify all tests pass

### Phase 4: Validate end-to-end

1. Stop and restart the full testbed (`stop-mesh.sh` + `start-mesh.sh` + `configure-vms.sh`)
2. Verify WiFi mesh forms automatically
3. Run all test suites
4. Verify `vwifi-ctrl` distance simulation degrades BMX7 link quality
5. Verify adapters return correct topology data

---

## Success Criteria

- [ ] BMX7 runs on virtual wlan interfaces (not br-lan) on all 3 mesh nodes
- [ ] `vwifi-ctrl ls` shows all 3 VMs connected to vwifi-server
- [ ] `vwifi-ctrl set` + `loss yes` causes measurable BMX7 link quality degradation
- [ ] `test_vwifi_ctrl_distance_based_loss` passes (currently skipped)
- [ ] `test_node_removal_detected` passes (stopping bmx7 on a node)
- [ ] All other existing tests continue to pass
- [ ] `collect-topology.sh` returns correct node count and links over WiFi BMX7
- [ ] `collect-nodes.sh` returns correct mesh_neighbors over WiFi BMX7
- [ ] Full testbed can be started from scratch (`stop-mesh.sh` → `start-mesh.sh` → `configure-vms.sh`) and WiFi mesh forms automatically

---

## Risks

1. **vwifi may not support IBSS/adhoc frame forwarding properly.** The existing comment in `configure-vms.sh` suggests this was already tried. If adhoc doesn't work, try 802.11s mesh point mode or plain managed mode with hostapd.

2. **vwifi-client may not be compatible with the vwifi-server version.** The VM package is `vwifi 7.0-r1` (OpenWrt build) while the host server is built from the same source tree. Verify version compatibility.

3. **mac80211_hwsim with radios=0 + vwifi-add-interfaces may not create working interfaces.** Test manually first.

4. **BMX7 over virtual WiFi may be significantly slower to converge** than over wired, causing test timeouts. May need to increase wait times.

5. **Frame relay through vwifi-server may introduce latency** that affects BMX7's link quality measurements even without distance simulation. Baseline measurements needed.

---

## Reference: vwifi Architecture

```
HOST (10.99.0.254)
├── vwifi-server (TCP :8212) — relays WiFi frames between VMs
├── vwifi-ctrl — controls server (distance, loss, scale)
├── mesha-br0 — bridge connecting all VM TAP devices
└── dnsmasq — DHCP server

VM-1 (10.99.0.11)
├── eth0 → br-lan (management, wired)
├── wlan0 — virtual WiFi via mac80211_hwsim
├── vwifi-client → connects to vwifi-server:8212
└── bmx7 dev=wlan0 — mesh routing over WiFi

VM-2 (10.99.0.12) — same as VM-1
VM-3 (10.99.0.13) — same as VM-1
```

WiFi frames flow: VM-1 wlan0 → vwifi-client → TCP → vwifi-server → TCP → vwifi-client → VM-2 wlan0
