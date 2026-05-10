# Fix QEMU Test Failures — Source-Built Image Integration

**Date:** 2026-05-09
**Status:** Planning
**Context:** Source-built VMs are running, SSH key auth works, bmx7 converges over br-lan, but 3 test suites fail due to test infrastructure expecting wireless mesh and IPv4 BMX7 output.

---

## Objective

Fix the 3 failing QEMU test suites (Mesh Protocols, Topology Manipulation, Multi-Hop Mesh) by updating the test infrastructure to work with the actual capabilities of the source-built image: wired mesh over br-lan (not wireless adhoc) and BMX7 with IPv6 link-local addresses.

---

## Root Cause Analysis

### Issue 1: BMX7 originators output uses IPv6, tests expect IPv4

**Location:** `adapters/mesh/collect-topology.sh:203` and `collect-topology.sh:222`

BMX7 running on br-lan uses IPv6 link-local addresses (`fe80::...`). The Python parser in `collect-topology.sh` only matches IPv4:
```python
if re.match(r'\d+\.\d+\.\d+\.\d+', ip):  # line 203 — misses IPv6
```
Same for link parsing at line 222.

**Impact:** `collect-topology.sh` returns `node_count: 1` (only the gateway itself), `links: []`. This breaks:
- `test-multi-hop.sh` — `test_topology_shows_mesh_links` expects `node_count >= 3` and `len(links) >= 3`
- `test-topology-manipulation.sh` — `test_node_removal_detected` compares node counts from collect-topology

**Fix:** Update the regex in `collect-topology.sh` to also match IPv6 addresses. Map IPv6 link-local to the corresponding IPv4 from the ARP/neighbor table.

### Issue 2: Tests restart bmx7 on wrong interface

**Location:** `tests/qemu/test-mesh-protocols.sh:105`

After the babel fallback test, line 105 restarts bmx7 with:
```bash
ssh_vm "$NODE2" "killall babeld 2>/dev/null; /etc/init.d/bmx7 start 2>/dev/null || bmx7 2>/dev/null || true"
```
The `bmx7` command without `dev=` starts on the default interface (which may be wireless or nothing). It should use `bmx7 dev=br-lan`.

**Impact:** After the babel test, node-2's bmx7 restarts without specifying an interface and loses mesh connectivity. Subsequent tests see fewer peers.

**Fix:** Update bmx7 restart commands across test files to use `bmx7 dev=br-lan`.

### Issue 3: `common.sh` `wait_for_bmx7` counts originators but bmx7 may not be running

**Location:** `tests/qemu/common.sh:138`

`wait_for_bmx7` checks `bmx7 -c originators` output. If bmx7 isn't running (no daemon to talk to), the CLI returns error and `wc -l` returns 0. The function correctly returns 2 if bmx7 binary isn't installed, but doesn't handle the case where bmx7 IS installed but the daemon isn't running.

**Impact:** Tests wait the full 90s timeout before failing, instead of starting bmx7 and waiting for convergence.

**Fix:** In `wait_for_bmx7`, if the first check returns 0 originators, try starting bmx7 with `bmx7 dev=br-lan` before entering the wait loop.

### Issue 4: Topology Manipulation tests depend on vwifi distance simulation

**Location:** `tests/qemu/test-topology-manipulation.sh:42-53`

The `test_vwifi_ctrl_distance_based_loss` test uses `vwifi-ctrl` to move nodes apart and expects BMX7 link quality to degrade. But bmx7 runs on br-lan (wired), not wireless. The vwifi-ctrl distance changes have no effect on br-lan links.

The `test_node_removal_detected` test kills a QEMU process and expects collect-topology to see fewer nodes. This test is valid but depends on collect-topology working (Issue 1).

**Impact:** `test_vwifi_ctrl_distance_based_loss` will always skip (quality won't degrade on wired). `test_node_removal_detected` should pass once collect-topology is fixed.

**Fix:** Mark `test_vwifi_ctrl_distance_based_loss` as skip with explanation. Fix `test_node_removal_detected` by ensuring collect-topology works (Issue 1 fix).

### Issue 5: `test-multi-hop.sh` checks originators for IPv4 address

**Location:** `tests/qemu/test-multi-hop.sh:33`

```bash
ROUTE_INFO=$(ssh_vm "$GATEWAY" "bmx7 -c originators 2>/dev/null" || true)
if echo "$ROUTE_INFO" | grep -q "$NODE3_IP"; then
```
`NODE3_IP="10.99.0.13"` but BMX7 originators shows IPv6 addresses. The grep fails.

**Impact:** `test_node3_reachable_via_mesh` always fails because the originators output doesn't contain the IPv4 address.

**Fix:** Check reachability via ping instead of grepping originators output. BMX7 routes both IPv4 and IPv6 — if the mesh is converged, ping will work.

---

## Implementation Plan

### Phase 1: Fix collect-topology.sh for IPv6 BMX7 output

- [ ] **Task 1.1:** Update `adapters/mesh/collect-topology.sh` originators parser (line 203) to match both IPv4 and IPv6 addresses
  - Change regex from `r'\d+\.\d+\.\d+\.\d+'` to `r'[\d.:a-fA-F]+'` or use a more specific pattern
  - When an IPv6 link-local address is found, look up the corresponding IPv4 from the ARP/neighbor table section
  - This ensures node IPs in the output are always IPv4 (as expected by tests and adapters)

- [ ] **Task 1.2:** Update `adapters/mesh/collect-topology.sh` links parser (line 222) to match both IPv4 and IPv6
  - Same regex fix as Task 1.1
  - Also resolve IPv6 neighbor IPs to IPv4 via ARP table

- [ ] **Task 1.3:** Verify `collect-topology.sh` returns correct node_count and links
  - Run: `bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-topology.sh lm-testbed-node-1`
  - Expect: `node_count: 4`, `links: 3+`

### Phase 2: Fix bmx7 interface in test files

- [ ] **Task 2.1:** Update `tests/qemu/test-mesh-protocols.sh:105` to restart bmx7 with `dev=br-lan`
  - Change: `bmx7 2>/dev/null` → `bmx7 dev=br-lan 2>/dev/null`

- [ ] **Task 2.2:** Update `tests/qemu/common.sh` `wait_for_bmx7()` to start bmx7 if daemon isn't running
  - After the `has_bmx7` check (line 129-131), add: if first originators check returns 0, try `bmx7 dev=br-lan` before entering wait loop
  - This handles the case where bmx7 binary exists but daemon isn't started

- [ ] **Task 2.3:** Update `tests/qemu/test-mesh-protocols.sh:86` babel test bmx7 stop to use `killall` (already correct)
  - Verify: no changes needed, `killall bmx7` is correct

### Phase 3: Fix multi-hop test reachability check

- [ ] **Task 3.1:** Update `tests/qemu/test-multi-hop.sh:31-38` to use ping instead of grep on originators
  - Replace the originators grep with a direct ping test
  - BMX7 routes IPv4 traffic even when it uses IPv6 for mesh discovery
  - If mesh is converged (wait_for_bmx7 passed), ping should work

### Phase 4: Handle topology manipulation test limitations

- [ ] **Task 4.1:** Update `tests/qemu/test-topology-manipulation.sh` `test_vwifi_ctrl_distance_based_loss` to skip with clear reason
  - Add check: if bmx7 is running on br-lan (wired), skip with "wired mesh not affected by vwifi distance"
  - The test is conceptually valid for wireless mesh but not applicable to wired mesh

- [ ] **Task 4.2:** Verify `test_node_removal_detected` works after collect-topology fix
  - This test kills node-3's QEMU process and checks that collect-topology sees fewer nodes
  - Should work once collect-topology returns correct node_count (Issue 1 fix)

### Phase 5: Run full test suite and verify

- [ ] **Task 5.1:** Run `tests/qemu/run-all.sh` and verify all suites pass
  - Expected: 0 failures, 0 skips (except vwifi distance test which legitimately skips)

- [ ] **Task 5.2:** Run adapter tests individually
  - `bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-topology.sh lm-testbed-node-1`
  - `bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-nodes.sh lm-testbed-node-1`

- [ ] **Task 5.3:** Commit all fixes

---

## Verification Criteria

- [ ] `collect-topology.sh` returns `node_count >= 4` with `links >= 3`
- [ ] `test-mesh-protocols.sh` — all 4 tests pass (or babel test skips gracefully)
- [ ] `test-topology-manipulation.sh` — `test_node_removal_detected` passes, `test_vwifi_ctrl_distance_based_loss` skips with reason
- [ ] `test-multi-hop.sh` — both tests pass
- [ ] `tests/qemu/run-all.sh` — 0 failures

---

## Potential Risks and Mitigations

1. **IPv6-to-IPv4 mapping in collect-topology may be unreliable**
   - Mitigation: Use the ARP/neighbor table (`ip neigh show`) to resolve link-local IPv6 to IPv4. All VMs have both IPv4 and IPv6 on br-lan.

2. **BMX7 originators output format may vary between versions**
   - Mitigation: Parse both IPv4 and IPv6 formats. Test with the actual source-built image's bmx7 binary.

3. **Node removal test may be flaky (QEMU process kill timing)**
   - Mitigation: Keep the existing 15-second wait after kill. If flaky, increase to 30s.

4. **babeld may not be installed on source-built image**
   - Mitigation: The babel test already skips gracefully if babeld isn't available (line 110).

---

## Alternative Approaches

1. **Force bmx7 to use IPv4**: Configure bmx7 with `bmx7 dev=br-lan ip=10.99.0.11/16` to use IPv4 instead of IPv6. This would make the existing parsers work without changes. Trade-off: may not match real LibreMesh behavior which uses IPv6.

2. **Add IPv4 to BMX7 via UCI**: Set `bmx7.general.ip_auto_table_offset=0` or similar to enable IPv4 address assignment. Trade-off: complex BMX7-specific config, may not work on all versions.

3. **Use ARP table instead of BMX7 for node discovery**: Parse `ip neigh show` instead of `bmx7 -c originators`. Trade-off: ARP only shows L2 neighbors, not multi-hop mesh topology.

---

## Files to Modify

| File | Change | Lines |
|------|--------|-------|
| `adapters/mesh/collect-topology.sh` | Add IPv6 regex + IPv6→IPv4 resolution | 203, 222 |
| `tests/qemu/common.sh` | Start bmx7 in `wait_for_bmx7` if not running | 136-149 |
| `tests/qemu/test-mesh-protocols.sh` | Restart bmx7 with `dev=br-lan` | 105 |
| `tests/qemu/test-multi-hop.sh` | Use ping instead of originators grep | 31-38 |
| `tests/qemu/test-topology-manipulation.sh` | Skip vwifi distance test on wired mesh | 35-63 |
