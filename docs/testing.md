# Testing

LibreMesh Lab uses Bash integration tests. The default suite is intentionally safe: it does not need VMs, Mesha, or root.

## Test Suites

Run tests through the main CLI:

```bash
bin/libremesh-lab test
bin/libremesh-lab test --suite fast
```

Available suites:

| Suite | Requires VMs? | Requires Mesha? | Root requirement | Purpose |
|---|---|---|---|---|
| `fast` | No | No | No | CLI contract, adapter-wrapper isolation, static script checks, and namespace preflight. |
| `lab` | Yes, already running and configured | No | Root only for prior `start` and later teardown | Mesh protocol, topology, multi-hop, drift, upgrade, and rollback checks. |
| `adapter` | Yes, already running and configured | Yes, `MESHA_ROOT=/path/to/mesha` | Root only for prior `start` and later teardown | Mesha adapter, rollout, validation, readonly, and failure-path coverage. |
| `lifecycle` | Starts/stops the lab | Optional for topology checks | Yes; requires `RUN_LIFECYCLE_TESTS=1` | Destructive lifecycle and cleanup coverage. |
| `namespace` | Host namespace/wmediumd smoke | No | Yes only with `RUN_NAMESPACE_TESTS=1` | Two-radio `mac80211_hwsim` + `wmediumd` mesh ping in network namespaces. |

## Safe Checks

The default command runs the `fast` suite:

```bash
bin/libremesh-lab test
bin/libremesh-lab test --suite fast
```

Use this in local development and CI when VMs are not available.

## VM-Backed Checks

Run these after starting and configuring the lab:

```bash
sudo bin/libremesh-lab start
bin/libremesh-lab configure
bin/libremesh-lab test --suite lab
```

Adapter tests additionally require a Mesha checkout:

```bash
MESHA_ROOT=/path/to/mesha bin/libremesh-lab test --suite adapter
```

## Destructive Lifecycle Checks

Lifecycle tests start and stop the lab themselves. Run only on an isolated host:

```bash
RUN_LIFECYCLE_TESTS=1 bin/libremesh-lab test --suite lifecycle
```

## Namespace / wmediumd Checks

The namespace suite always starts with a non-mutating preflight:

```bash
bash scripts/qemu/preflight-namespace.sh
bin/libremesh-lab test --suite namespace
```

To run the root-backed smoke test on an isolated host:

```bash
sudo env RUN_NAMESPACE_TESTS=1 bin/libremesh-lab test --suite namespace
```

This loads two disposable `mac80211_hwsim` radios, moves one PHY into a network namespace, starts `wmediumd`, joins both interfaces to an 802.11s mesh, verifies ping over the simulated medium, and cleans up. If `mac80211_hwsim` is already loaded, the test refuses to proceed unless `LIBREMESH_LAB_NAMESPACE_RESET_HWSIM=1` is set.

## Useful Environment Variables

| Variable | Used by | Purpose |
|---|---|---|
| `MESHA_ROOT=/path/to/mesha` | `adapter` suite | Points adapter tests to a Mesha checkout. |
| `CONVERGE_WAIT=30` | convergence-sensitive tests | Controls wait time for mesh protocol convergence. |
| `QEMU_TIMEOUT_MULTIPLIER=2` | slow hosts / TCG | Scales SSH and boot timeouts. |
| `RUN_LIFECYCLE_TESTS=1` | `lifecycle` suite | Enables destructive start/stop coverage. |
| `RUN_NAMESPACE_TESTS=1` | `namespace` suite | Enables root-backed hwsim/wmediumd smoke test. |
| `LIBREMESH_LAB_NAMESPACE_RESET_HWSIM=1` | namespace smoke | Allows resetting pre-existing `mac80211_hwsim` state when safe. |

## Test Files

| Test file | What it covers |
|---|---|
| `test-fast-cli.sh` | CLI contract: status JSON, stop path, missing suite error. |
| `test-run-adapter-wrapper.sh` | No-VM adapter workspace isolation regression. |
| `test-qemu-script-units.sh` | Static script units: image conversion parser, partition parsing, SSH config migration. |
| `test-mesh-status-pid.sh` | Runtime PID aliveness checks for QEMU and vwifi. |
| `test-mesh-protocols.sh` | Protocol convergence, gateway reachability, routing, restart behavior. |
| `test-validate-node.sh` | Healthy node, missing SSID, and no-neighbor validation. |
| `test-config-drift.sh` | UCI write/read and drift detection. |
| `test-topology-manipulation.sh` | vwifi control, loss simulation, and node removal detection. |
| `test-firmware-upgrade.sh` | Firmware version changes and validation mismatch. |
| `test-multi-hop.sh` | End-to-end multi-hop connectivity. |
| `test-rollback.sh` | Configuration backup and rollback. |
| `test-rollout.sh` | Rolling configuration update dry runs. |
| `test-failure-paths.sh` | Unreachable hosts and adapter error handling. |
| `test-topologies.sh` | Line, star, and partition topology convergence. |
| `test-namespace-preflight.sh` | No-root namespace/wmediumd preflight regression. |
| `test-namespace-wmediumd.sh` | Root-gated two-node hwsim/wmediumd namespace smoke. |

## CI Notes

- Run `bin/libremesh-lab test --suite fast` on ordinary hosted runners.
- Use a KVM-capable self-hosted runner for VM-backed tests; see [self-hosted-runner.md](self-hosted-runner.md).
- Always collect logs with `bin/libremesh-lab logs` when debugging failures.
- Clean up with `sudo bin/rollback-lab.sh` after VM-backed runs.
