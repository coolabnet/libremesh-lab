# Fix LibreMesh QEMU Testbed Mesh Networking

## Objective

Enable LibreMesh mesh networking (babeld/batman-adv) to work between QEMU VMs in the testbed, while preserving existing DHCP IP assignment, SSH access, and test infrastructure. The fix must be fully automated with no manual serial console steps.

## Root Cause Analysis

### The Problem Chain

1. **LibreMesh's lime-config** (runs at first boot via `/etc/uci-defaults/91_lime-config`) generates a network config based on real hardware assumptions:
   - Creates 802.1ad VLAN-tagged interfaces (e.g., `eth0_29`) for mesh traffic
   - Sets up batman-adv virtual interface (`bat0`) bridged with `eth0` on `br-lan`
   - Configures babeld to route over the VLAN-tagged interfaces

2. **The QEMU environment doesn't match these assumptions:**
   - QEMU TAP interfaces provide plain Ethernet (no VLAN tagging)
   - The `mesha-br0` Linux bridge on the host doesn't pass VLAN-tagged frames between TAPs by default (no `vlan_filtering=1`)
   - Even with VLAN filtering, the VMs' VLAN sub-interfaces won't match because lime-config creates them based on specific radio/wireless assumptions

3. **The current rc.local workaround** (`configure-source-image.sh:291-306`) bypasses the problem by:
   - Running `ip link set eth0 up` + `udhcpc` after LibreMesh finishes booting
   - This gets DHCP working (IPs on 10.99.0.x) but **completely bypasses lime-config's network setup**
   - babeld never gets configured with proper interfaces
   - Result: mesh daemon is either not running or running on wrong interfaces

### Why Phase 3 Fails

In `configure-vms.sh:779-835`, Phase 3 waits for babeld convergence. The convergence check (`count_mesh_neighbors` in `common.sh:221-262`) for babeld checks if the daemon has a UDP listener on port 6696. But babeld is either:
- Not running at all (lime-config didn't start it properly because the interfaces it configured don't exist)
- Running on non-existent VLAN interfaces
- Running but unable to communicate with peers because the underlying L2 path is broken

## Strategy: Replace rc.local Bypass with Proper Network Reconfiguration

Instead of bypassing lime-config's network entirely with raw `ip` commands, we need to **reconfigure the network properly after lime-config runs** so that:
1. The management interface (br-lan/eth0) gets a DHCP IP for SSH access
2. babeld runs on br-lan (the wired bridge interface that all VMs share)
3. The mesh routing protocol can discover peers via the shared L2 broadcast domain

### Key Insight

The `mesha-br0` bridge on the host connects all 4 VM TAP devices. This means all VMs share the same L2 broadcast domain via their `eth0` interfaces. If we configure babeld to run on `br-lan` (which bridges to `eth0`) inside each VM, babeld hellos will be broadcast across the bridge and all nodes will discover each other. This is exactly how the "bare OpenWrt" path already works in `configure-vms.sh:389-482`.

The fix is to make the LibreMesh (lime-config) path produce the same result as the bare OpenWrt path: babeld running on br-lan with proper IP configuration.

## Implementation Plan

### Task 1: Replace rc.local in configure-source-image.sh

The rc.local at `scripts/qemu/configure-source-image.sh:291-306` currently does `ip link up + udhcpc` which gets DHCP but destroys mesh. Replace it with a proper post-boot network reconfiguration that:
1. Waits for lime-config to finish (it runs via uci-defaults on first boot)
2. Reconfigures network to use DHCP on br-lan with eth0 as member
3. Ensures babeld is configured to run on br-lan
4. Restarts networking properly

- [ ] **1.1** Modify `scripts/qemu/configure-source-image.sh` rc.local section (lines 267-308) to replace the raw `ip link up + udhcpc` approach with a UCI-based network reconfiguration script
  - The new rc.local should:
    - Wait for lime-config to complete (check for `/etc/config/.lime-configured` marker or wait for uci-defaults to finish)
    - Rewrite `/etc/config/network` to use DHCP on br-lan with eth0 as the only bridge port
    - Remove any VLAN interface references from network config
    - Configure babeld to use br-lan as its interface (`/etc/config/babeld`)
    - Restart netifd (`/etc/init.d/network restart`) instead of raw `ip` commands
    - Restart dropbear after network is up
  - Rationale: Using UCI/netifd instead of raw `ip` commands ensures the network state is consistent and netifd-managed, which lime-config and other services expect

- [ ] **1.2** Add babeld UCI configuration to the rc.local script
  - Create `/etc/config/babeld` with a proper interface section for br-lan if lime-config didn't create one
  - Ensure babeld init script is enabled (`/etc/init.d/babeld enable`)
  - Rationale: Even after lime-config runs, the babeld config may reference VLAN interfaces that don't exist in QEMU. We need to ensure babeld is configured for br-lan

- [ ] **1.3** Add a first-boot marker to prevent rc.local from re-running on subsequent boots
  - After configuration, write `/etc/.mesha-testbed-configured`
  - Add guard at top of rc.local: `if [ -f /etc/.mesha-testbed-configured ]; then exit 0; fi`
  - Rationale: Prevents reconfiguration on every boot after the first

### Task 2: Update configure-vms.sh Phase 1 for LibreMesh Path

The LibreMesh path in `configure-vms.sh:344-387` currently relies on lime-config to set up everything. After our rc.local fix, lime-config will have run but been overridden. We need Phase 1 to verify and correct the state.

- [ ] **2.1** Add a post-lime-config verification step in the `has_lime_config=yes` branch (after line 387)
  - After the lime-config sequence runs, verify that br-lan has the correct IP
  - If not, apply the same UCI network config as the bare OpenWrt path
  - Ensure babeld is running on br-lan (not on VLAN interfaces)
  - Rationale: The rc.local override runs before SSH is available, but configure-vms.sh runs after SSH. We need a safety net in case rc.local didn't fully work

- [ ] **2.2** Unify the mesh daemon start logic between LibreMesh and bare OpenWrt paths
  - Currently the LibreMesh path doesn't call `start_mesh_daemon_on_vm` (line 475-482 only runs for bare OpenWrt)
  - After lime-config override, the mesh daemon may need the same restart logic
  - Add `start_mesh_daemon_on_vm` call after the LibreMesh path as well
  - Rationale: Ensures consistent mesh daemon state regardless of image type

### Task 3: Ensure Host Bridge Passes All Required Frames

The `mesha-br0` bridge must pass babeld's multicast/broadcast hellos between TAP devices.

- [ ] **3.1** Verify bridge multicast/broadcast forwarding in `start-mesh.sh:148-166`
  - The bridge is created with `stp_state 0` and `forward_delay 0` (lines 153-154)
  - Verify that multicast_snooping is disabled (or not interfering)
  - Add `ip link set "${BRIDGE_NAME}" type bridge multicast_snooping 0` if needed
  - Rationale: babeld uses multicast for neighbor discovery. If multicast snooping is enabled, the bridge may not forward multicast to ports that haven't joined the group

- [ ] **3.2** Verify no iptables/nftables rules block inter-VM traffic on the bridge
  - Check if the host has `iptables -t nat -A POSTROUTING` or bridge netfilter rules
  - Add a note in the plan about checking `br_netfilter` module
  - Rationale: Some distributions load `br_netfilter` which can cause bridge traffic to be processed by iptables, potentially dropping inter-VM traffic

### Task 4: Fix Phase 3 Convergence Detection

The current babeld convergence check is overly simplistic. It only checks if babeld has a UDP listener, not if it actually sees neighbors.

- [ ] **4.1** Improve babeld neighbor detection in `tests/qemu/common.sh:count_mesh_neighbors` (lines 230-249)
  - Current check: babeld PID exists + UDP socket open = 1 neighbor
  - Better check: parse babeld's local socket (`/var/run/babeld.sock` or `/tmp/babeld.sock`) to get actual neighbor count
  - Alternative: check `ip route` for babeld-installed routes, or check `babeld -c dump` output
  - Fallback: check `/proc/net/udp` for established babeld neighbor state
  - Rationale: The current check can report "converged" when babeld is running but isolated. We need to verify actual peer communication

- [ ] **4.2** Update Phase 3 convergence logic in `configure-vms.sh:779-835`
  - For babeld, check for actual neighbor entries instead of just UDP listener
  - Add a fallback ping test: after convergence check, try `ping -c 1 10.99.0.12` from node-1
  - Increase timeout if needed (current 90s may not be enough for first convergence)
  - Rationale: The convergence check should verify actual mesh connectivity, not just daemon presence

### Task 5: Add Diagnostics for Debugging

- [ ] **5.1** Add a diagnostic dump to configure-vms.sh that runs when convergence fails
  - When Phase 3 times out, SSH to each node and collect:
    - `ip addr show` (verify IP assignment)
    - `ip link show` (verify interface states)
    - `cat /etc/config/network` (verify UCI network config)
    - `cat /etc/config/babeld` (verify babeld config)
    - `ps | grep babeld` (verify daemon running)
    - `logread | grep babeld | tail -20` (check for errors)
    - `logread | grep netifd | tail -20` (check for network errors)
  - Write diagnostics to `run/logs/convergence-diagnostics.log`
  - Rationale: When mesh fails to converge, the current error message is unhelpful. Detailed diagnostics will make debugging much faster

- [ ] **5.2** Add a `--debug` flag to configure-vms.sh that enables verbose logging
  - Show all SSH command outputs instead of suppressing them
  - Add timing information for each phase
  - Rationale: Makes it possible to debug issues without modifying the script

### Task 6: Update Image Configuration Scripts

- [ ] **6.1** Update `scripts/qemu/configure-source-image.sh` to also configure babeld UCI
  - In the mounted rootfs, pre-create `/etc/config/babeld` with a br-lan interface section
  - This ensures babeld has a valid config even before rc.local runs
  - Rationale: Defense in depth — if rc.local fails, babeld still has a usable config

- [ ] **6.2** Ensure the defconfig (`scripts/qemu/libremesh-testbed.defconfig`) includes all needed packages
  - Verify `CONFIG_PACKAGE_babeld=y` is present (it is, line 7)
  - Consider adding `CONFIG_PACKAGE_lime-proto-babeld=y` for babeld proto support
  - Rationale: The defconfig already has babeld, but lime-proto-babeld may be needed for proper lime-config integration

## Verification Criteria

1. **DHCP IP Assignment**: All 4 VMs get IPs 10.99.0.11-14 via dnsmasq DHCP
   - Verify: `ssh root@10.99.0.11 'ip addr show br-lan'` shows correct IP

2. **SSH Access**: All VMs reachable via SSH from host
   - Verify: `ssh -i run/ssh-keys/id_ed25519 root@10.99.0.{11,12,13,14} 'echo ok'`

3. **Mesh Convergence**: babeld discovers all peers within 90 seconds
   - Verify: Phase 3 of configure-vms.sh completes without timeout
   - Verify: `ssh root@10.99.0.11 'pgrep -x babeld'` returns a PID
   - Verify: babeld sees neighbors (check via babeld socket or routes)

4. **Inter-VM Connectivity**: All VMs can ping each other
   - Verify: `ssh root@10.99.0.13 'ping -c 1 10.99.0.11'` succeeds

5. **thisnode.info Resolution**: thisnode.info resolves to a node IP
   - Verify: `curl -s http://thisnode.info` or `/etc/hosts` entry exists

6. **Test Suite Passes**: All mesh-related tests pass
   - Verify: `bash tests/qemu/test-mesh-protocols.sh` passes all 4 tests
   - Verify: `bash tests/qemu/test-multi-hop.sh` passes both tests

7. **Automation**: No manual steps required
   - Verify: `sudo bash scripts/qemu/start-mesh.sh && bash scripts/qemu/configure-vms.sh` completes end-to-end without intervention

## Potential Risks and Mitigations

1. **Risk: rc.local runs before lime-config finishes**
   - Mitigation: Add a wait loop in rc.local that checks for lime-config completion (look for `/etc/config/.lime-configured` or wait for uci-defaults to finish by checking `ls /etc/uci-defaults/` for remaining scripts). Use a timeout of 60 seconds.

2. **Risk: netifd restart drops SSH connection before dropbear rebinds**
   - Mitigation: Use `nohup` or background the network restart. Start a secondary dropbear on a different port before restarting network. Or use serial console as fallback (already available).

3. **Risk: Bridge multicast snooping drops babeld hellos**
   - Mitigation: Explicitly disable multicast snooping on mesha-br0 in start-mesh.sh. This is a simple one-line addition.

4. **Risk: First-boot vs subsequent-boot behavior differs**
   - Mitigation: Use the marker file approach (`/etc/.mesha-testbed-configured`) to ensure rc.local only runs once. On subsequent boots, the UCI config is already correct.

5. **Risk: lime-config overwrites our network config on every boot**
   - Mitigation: lime-config runs via uci-defaults which are self-deleting (they remove themselves after execution). After first boot, lime-config won't run again. The rc.local marker prevents reconfiguration.

6. **Risk: babeld UCI config format differs between LibreMesh versions**
   - Mitigation: Use the same babeld config format as the bare OpenWrt path (command-line arguments via init script), which is already tested and working.

## Alternative Approaches

### Alternative A: Disable lime-config Entirely (Simpler but Less Faithful)

Instead of letting lime-config run and then overriding it, disable lime-config's uci-defaults entirely and pre-configure the network manually in the image.

- **Approach**: In `configure-source-image.sh`, rename `/etc/uci-defaults/91_lime-config` to `.disabled` and pre-write all UCI configs (network, babeld, wireless)
- **Pros**: Simpler, more predictable, no race conditions with lime-config
- **Cons**: Doesn't test the full LibreMesh boot sequence; some lime-config features (like thisnode.info DNS, shared-state) won't be configured
- **Trade-off**: This is essentially what the bare OpenWrt path does. It works but doesn't exercise the real LibreMesh stack

### Alternative B: VLAN-Aware Bridge on Host (Most Faithful to Real Hardware)

Configure the host's `mesha-br0` bridge to pass VLAN-tagged frames, matching what LibreMesh expects.

- **Approach**: Enable VLAN filtering on mesha-br0 (`ip link set mesha-br0 type bridge vlan_filtering 1`), add VLAN 29 to all TAP ports, configure VMs to use VLAN-tagged interfaces
- **Pros**: Most faithful to real LibreMesh hardware behavior; tests the actual VLAN mesh path
- **Cons**: Significantly more complex; requires understanding LibreMesh's exact VLAN scheme; may not work with all bridge/TAP configurations; lime-config creates VLANs based on detected radios which don't exist in QEMU
- **Trade-off**: High effort, high reward if it works, but may be fragile

### Alternative C: Network Namespace Approach (From Research)

Replace QEMU VMs with network namespaces running OpenWrt userspace via chroot, using mac80211_hwsim on the host for WiFi simulation.

- **Approach**: As described in `research/wifi-mesh-simulation-research.md` Option A
- **Pros**: Full WiFi simulation including data frames; no vwifi dependency; faster than QEMU
- **Cons**: Major architectural change; no real OpenWrt kernel; significant development effort; loses ability to test real firmware images
- **Trade-off**: This is the long-term solution but too invasive for this fix

### Recommended Approach: Task 1-6 (Primary Plan)

The primary plan lets lime-config run (preserving LibreMesh services like thisnode.info and shared-state), then overrides only the network layer to work with QEMU's plain Ethernet. This is the best balance of fidelity, simplicity, and maintainability.

## File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `scripts/qemu/configure-source-image.sh` | Modify | Replace rc.local with proper post-lime-config network reconfiguration |
| `scripts/qemu/configure-vms.sh` | Modify | Add post-lime-config verification and unified mesh daemon start |
| `scripts/qemu/start-mesh.sh` | Modify | Disable bridge multicast snooping |
| `tests/qemu/common.sh` | Modify | Improve babeld neighbor detection |
| `scripts/qemu/libremesh-testbed.defconfig` | Possibly modify | Add lime-proto-babeld if needed |

## Execution Order

1. Task 3 (host bridge fix) — simplest change, can be tested independently
2. Task 1 (rc.local replacement) — core fix, requires careful testing
3. Task 2 (configure-vms.sh updates) — depends on Task 1
4. Task 4 (convergence detection) — can be done in parallel with Tasks 1-2
5. Task 6 (image config hardening) — defense in depth, done last
6. Task 5 (diagnostics) — useful for debugging, done in parallel
