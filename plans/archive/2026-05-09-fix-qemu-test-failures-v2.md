# Fix QEMU Test Failures — Source-Built Image Integration

**Date:** 2026-05-09
**Status:** Ready for Implementation
**Context:** Source-built VMs are running, SSH key auth works, bmx7 converges over br-lan, but test suites fail due to test infrastructure expecting wireless mesh and IPv4 BMX7 output.

---

## Objective

Fix all failing QEMU test suites by updating the test infrastructure and adapters to work with the actual capabilities of the source-built image: wired mesh over br-lan (not wireless adhoc) and BMX7 with IPv6 link-local addresses.

---

## Root Cause Analysis

### Issue 1: BMX7 originators output uses IPv6, parsers expect IPv4

**Locations:** `adapters/mesh/collect-topology.sh:203,222` AND `adapters/mesh/collect-nodes.sh:245`

BMX7 running on br-lan uses IPv6 link-local addresses (`fe80::...`). The Python parsers only match IPv4:
```python
# collect-topology.sh:203
if re.match(r'\d+\.\d+\.\d+\.\d+', ip):  # misses IPv6

# collect-nodes.sh:245
if len(tokens) >= 3 and "." in tokens[0]:  # misses IPv6
```

**Impact:** `collect-topology.sh` returns `node_count: 1` (only gateway), `links: []`. `collect-nodes.sh` returns `mesh_neighbors: []`. This breaks:
- `test-multi-hop.sh` — `test_topology_shows_mesh_links` expects `node_count >= 3`
- `test-topology-manipulation.sh` — `test_node_removal_detected` compares node counts
- `test-adapters.sh` — may fail if mesh_neighbors is expected
- `test-failure-paths.sh` — `test_collect_topology_partial_failure` may get wrong results

**Fix:** Update both adapters to match IPv6. Resolve IPv6 link-local to IPv4 via ARP/neighbor table data (already collected by the remote script).

### Issue 2: Tests restart bmx7 on wrong interface

**Location:** `tests/qemu/test-mesh-protocols.sh:105`

After the babel fallback test, line 105 restarts bmx7 without specifying an interface:
```bash
ssh_vm "$NODE2" "killall babeld 2>/dev/null; /etc/init.d/bmx7 start 2>/dev/null || bmx7 2>/dev/null || true"
```

**Impact:** Node-2's bmx7 restarts without `dev=br-lan`, may start on wrong interface or fail entirely. Subsequent tests see fewer peers.

**Fix:** All bmx7 start/restart commands must use `bmx7 dev=br-lan`.

### Issue 3: `common.sh` `wait_for_bmx7` doesn't start bmx7 if daemon isn't running

**Location:** `tests/qemu/common.sh:138`

`wait_for_bmx7` checks `bmx7 -c originators` output. If bmx7 binary exists but the daemon isn't running (common after VM reboot), the CLI returns error and `wc -l` returns 0. The function waits the full 90s timeout before failing.

This also affects `test-failure-paths.sh:46,71` which reboots node-3 then calls `wait_for_bmx7` — bmx7 won't be running after reboot.

**Fix:** In `wait_for_bmx7`, if first check returns 0 originators, try `bmx7 dev=br-lan` before entering wait loop.

### Issue 4: Topology Manipulation tests depend on vwifi distance simulation

**Location:** `tests/qemu/test-topology-manipulation.sh:42-53`

`test_vwifi_ctrl_distance_based_loss` uses `vwifi-ctrl` to move nodes apart and expects BMX7 link quality to degrade. But bmx7 runs on br-lan (wired), not wireless. vwifi-ctrl distance changes have no effect on br-lan links.

**Fix:** Skip with clear reason. Test is conceptually valid for wireless mesh but not applicable to wired mesh.

### Issue 5: `test-multi-hop.sh` checks originators for IPv4 address

**Location:** `tests/qemu/test-multi-hop.sh:33`

```bash
ROUTE_INFO=$(ssh_vm "$GATEWAY" "bmx7 -c originators 2>/dev/null" || true)
if echo "$ROUTE_INFO" | grep -q "$NODE3_IP"; then
```

`NODE3_IP="10.99.0.13"` but BMX7 originators shows IPv6 addresses. The grep fails.

**Fix:** Check reachability via ping instead of grepping originators output.

### Issue 6: Node-3 restart in `test-topology-manipulation.sh` missing `-kernel` flag

**Location:** `tests/qemu/test-topology-manipulation.sh:114-121`

The test restarts node-3 after killing it, but the QEMU command is missing `-kernel` and `-append` flags. `start-mesh.sh:278-279` adds these for images without a bootloader (like the source-built flat image). Without them, the restarted VM won't boot.

Additionally, after restart, bmx7 won't be running on node-3 (started by `configure-vms.sh`, not persisted).

**Fix:** Update the restart command to match `start-mesh.sh`'s `launch_vm` logic. Add a bmx7 startup step after the VM boots.

### Issue 7: `ssh-config` missing `IdentitiesOnly=yes`

**Location:** `config/ssh-config:33-38`

The SSH config specifies `IdentityFile` but not `IdentitiesOnly=yes`. The SSH agent has 2 keys that get tried first. Dropbear may reject them, and with enough failed attempts, the correct key never gets tried. This is the same bug that was fixed in `configure-vms.sh` (commit `e6b1e2c`).

**Impact:** All tests using `common.sh:ssh_vm()` (which uses `ssh -F "${SSH_CONFIG}"`) may fail intermittently due to SSH agent key interference.

**Fix:** Add `IdentitiesOnly=yes` to `config/ssh-config` under `Host *`.

### Issue 8: `prepare-source-image.sh` not idempotent against debugfs-modified images

**Location:** `scripts/qemu/prepare-source-image.sh`

The image was modified via `debugfs` (not `prepare-source-image.sh`). If someone runs `prepare-source-image.sh` on the already-modified image, it may fail or produce duplicate entries. The script should check if files already exist and match expected content.

**Fix:** Make `prepare-source-image.sh` idempotent — skip files that already match expected content.

---

## Implementation Plan

### Phase 1: Fix adapter IPv6 parsing (collect-topology.sh + collect-nodes.sh)

- [ ] **Task 1.1:** Update `adapters/mesh/collect-topology.sh` originators parser (line 203) to match both IPv4 and IPv6
  - Change regex from `r'\d+\.\d+\.\d+\.\d+'` to a pattern that matches both
  - When an IPv6 link-local address is found, look up the corresponding IPv4 from the ARP/neighbor table section (already collected in `__ARP_START__`/`__ARP_END__`)
  - Build an IPv6→IPv4 lookup dict from the ARP data: each ARP entry has both the IPv6 neighbor and the corresponding IPv4 for the same MAC
  - Output always uses IPv4 addresses (as expected by downstream consumers)

- [ ] **Task 1.2:** Update `adapters/mesh/collect-topology.sh` links parser (line 222) to match both IPv4 and IPv6
  - Same regex and IPv6→IPv4 resolution as Task 1.1

- [ ] **Task 1.3:** Update `adapters/mesh/collect-nodes.sh` BMX7 neighbor parser (line 245) to match both IPv4 and IPv6
  - Change `"." in tokens[0]` to also match `":"` for IPv6 addresses
  - Resolve IPv6 to IPv4 using the interface data already collected (interfaces list has both IPv4 and IPv6 per interface)

- [ ] **Task 1.4:** Verify both adapters return correct data
  - Run: `bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-topology.sh lm-testbed-node-1`
  - Expect: `node_count: 4`, `links: 3+`
  - Run: `bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-nodes.sh lm-testbed-node-1`
  - Expect: `mesh_neighbors` with 3 entries

### Phase 2: Fix SSH config and bmx7 interface in test files

- [ ] **Task 2.1:** Add `IdentitiesOnly=yes` to `config/ssh-config` under `Host *` section
  - Prevents SSH agent keys from interfering with the testbed key auth
  - Same fix as was applied to `configure-vms.sh` in commit `e6b1e2c`

- [ ] **Task 2.2:** Update `tests/qemu/common.sh` `wait_for_bmx7()` to start bmx7 if daemon isn't running
  - After the `has_bmx7` check (line 129-131), add: if first originators check returns 0, try `bmx7 dev=br-lan 2>/dev/null` before entering wait loop
  - This handles the case where bmx7 binary exists but daemon isn't started (after reboot, or if configure-vms.sh didn't start it)
  - Also affects `test-failure-paths.sh:71` which calls `wait_for_bmx7` after rebooting node-3

- [ ] **Task 2.3:** Update `tests/qemu/test-mesh-protocols.sh:105` to restart bmx7 with `dev=br-lan`
  - Change: `bmx7 2>/dev/null` → `bmx7 dev=br-lan 2>/dev/null`

### Phase 3: Fix multi-hop test reachability check

- [ ] **Task 3.1:** Update `tests/qemu/test-multi-hop.sh:31-38` to use ping instead of grep on originators
  - Replace the originators grep with a direct ping test
  - BMX7 routes IPv4 traffic even when it uses IPv6 for mesh discovery
  - If mesh is converged (wait_for_bmx7 passed), ping will work

### Phase 4: Fix topology manipulation tests

- [ ] **Task 4.1:** Update `tests/qemu/test-topology-manipulation.sh` `test_vwifi_ctrl_distance_based_loss` to skip with clear reason
  - Add check at start: if bmx7 is on br-lan (wired), skip with "wired mesh not affected by vwifi distance simulation"
  - The test is conceptually valid for wireless mesh but not applicable to wired mesh

- [ ] **Task 4.2:** Fix node-3 restart command in `tests/qemu/test-topology-manipulation.sh:114-121`
  - Add `-kernel` and `-append` flags matching `start-mesh.sh:278-279` logic
  - The source-built flat image has no bootloader — it requires explicit kernel boot
  - After restart, wait for SSH then start bmx7: `ssh_vm "lm-testbed-node-3" "bmx7 dev=br-lan" || true`
  - This ensures node-3 rejoins the mesh after restart

### Phase 5: Make prepare-source-image.sh idempotent

- [ ] **Task 5.1:** Update `scripts/qemu/prepare-source-image.sh` to be idempotent
  - Before writing each file, check if it already exists and matches expected content
  - Skip files that are already correct (e.g., SSH key already in authorized_keys)
  - This prevents issues when running the script on an already-debugfs-modified image

### Phase 6: Run full test suite and verify

- [ ] **Task 6.1:** Run `tests/qemu/run-all.sh` with increased timeout and verify all suites pass
  - Use `timeout 600 bash tests/qemu/run-all.sh` to avoid stage-upgrade timeout
  - Expected: 0 failures, only `test_vwifi_ctrl_distance_based_loss` legitimately skips

- [ ] **Task 6.2:** Run adapter tests individually
  - `bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-topology.sh lm-testbed-node-1`
  - `bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-nodes.sh lm-testbed-node-1`

- [ ] **Task 6.3:** Commit all fixes

---

## Verification Criteria

- [ ] `collect-topology.sh` returns `node_count >= 4` with `links >= 3`
- [ ] `collect-nodes.sh` returns `mesh_neighbors` with 3 entries
- [ ] `test-mesh-protocols.sh` — all 4 tests pass (or babel test skips gracefully)
- [ ] `test-topology-manipulation.sh` — `test_node_removal_detected` passes, `test_vwifi_ctrl_distance_based_loss` skips with reason
- [ ] `test-multi-hop.sh` — both tests pass
- [ ] `test-failure-paths.sh` — all 5 tests pass (node-3 reboots and reconverges)
- [ ] `tests/qemu/run-all.sh` — 0 failures

---

## Potential Risks and Mitigations

1. **IPv6-to-IPv4 mapping in collect-topology may be unreliable**
   - Mitigation: Build lookup from ARP/neighbor table data (already collected by the remote script). All VMs have both IPv4 and IPv6 on br-lan. The ARP table maps MAC addresses to both IPv4 and IPv6 — use MAC as the join key.

2. **BMX7 originators output format may vary between versions**
   - Mitigation: Parse both IPv4 and IPv6 formats. Test with the actual source-built image's bmx7 binary.

3. **Node removal test may be flaky (QEMU process kill timing)**
   - Mitigation: Keep the existing 15-second wait after kill. If flaky, increase to 30s.

4. **babeld may not be installed on source-built image**
   - Mitigation: The babel test already skips gracefully if babeld isn't available (`test-mesh-protocols.sh:110`).

5. **Node-3 restart may not get DHCP lease quickly**
   - Mitigation: Add a `wait_for_ssh` call after restart before checking topology. The existing `configure-vms.sh` pattern (exponential backoff SSH wait) can be reused.

6. **prepare-source-image.sh changes may conflict with debugfs-modified image**
   - Mitigation: Idempotency checks (Task 5.1) ensure no duplicate entries or overwrites.

---

## Alternative Approaches

1. **Force bmx7 to use IPv4**: Configure bmx7 with `bmx7 dev=br-lan ip=10.99.0.11/16` to use IPv4 instead of IPv6. This would make the existing parsers work without changes. Trade-off: may not match real LibreMesh behavior which uses IPv6.

2. **Add IPv4 to BMX7 via UCI**: Set `bmx7.general.ip_auto_table_offset=0` or similar to enable IPv4 address assignment. Trade-off: complex BMX7-specific config, may not work on all versions.

3. **Use ARP table instead of BMX7 for node discovery**: Parse `ip neigh show` instead of `bmx7 -c originators`. Trade-off: ARP only shows L2 neighbors, not multi-hop mesh topology.

---

## Files to Modify

| File | Change | Lines |
|------|--------|-------|
| `adapters/mesh/collect-topology.sh` | Add IPv6 regex + IPv6→IPv4 resolution via ARP | 203, 222 |
| `adapters/mesh/collect-nodes.sh` | Add IPv6 matching for BMX7 neighbor parser | 245 |
| `config/ssh-config` | Add `IdentitiesOnly=yes` to `Host *` | 33-38 |
| `tests/qemu/common.sh` | Start bmx7 in `wait_for_bmx7` if not running | 136-149 |
| `tests/qemu/test-mesh-protocols.sh` | Restart bmx7 with `dev=br-lan` | 105 |
| `tests/qemu/test-multi-hop.sh` | Use ping instead of originators grep | 31-38 |
| `tests/qemu/test-topology-manipulation.sh` | Skip vwifi distance test; fix node-3 restart with `-kernel` + bmx7 startup | 35-63, 114-121 |
| `scripts/qemu/prepare-source-image.sh` | Add idempotency checks | throughout |
