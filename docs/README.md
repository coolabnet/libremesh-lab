# LibreMesh Lab

> See [AGENTS.md](../AGENTS.md) for the agent-facing workflow and repository conventions.

## Quick Start

Install the CLI into the default user-local location:

```bash
curl -fsSL https://raw.githubusercontent.com/coolabnet/libremesh-lab/main/scripts/install.sh | bash
```

The installer clones the repository to `~/.local/share/libremesh-lab` and
symlinks `libremesh-lab` into `~/.local/bin`. For a local checkout, run the same
commands through `bin/libremesh-lab`.

```bash
# 1. Build or download firmware image
bin/libremesh-lab build-image
# OR use pre-built image conversion:
bash scripts/qemu/convert-prebuilt.sh

# 2. (Source-built images only) Install SSH keys and DHCP into the image
scripts/qemu/configure-source-image.sh --image images/libremesh-combined.img

# 3. Start the test bed (requires root for bridge/TAP/dnsmasq/QEMU networking)
sudo bin/libremesh-lab start

# 4. Configure VMs (wait ~90s for boot)
bin/libremesh-lab configure

# 5. Run tests
bin/libremesh-lab test                   # safe VM-free suite
bin/libremesh-lab test --suite lab       # VM-backed checks
MESHA_ROOT=/path/to/mesha bin/libremesh-lab test --suite adapter

# 6. Teardown
sudo bin/rollback-lab.sh                 # stop lab, clean up networking
sudo bin/rollback-lab.sh --full          # also remove sudo rule + wmediumd binary
```

## Architecture

4 LibreMesh VMs connected via TAP/bridge networking:

- **lm-testbed-node-1** (10.99.0.11) — gateway
- **lm-testbed-node-2** (10.99.0.12) — relay
- **lm-testbed-node-3** (10.99.0.13) — leaf
- **lm-testbed-tester** (10.99.0.14) — tester (512MB RAM)

Each VM has:

- mesh0 (TAP via mesha-br0) — management SSH + wired mesh
- wan0 (QEMU user-mode) — internet access
- wlan0 (vwifi-client → vwifi-server) — WiFi mesh simulation

The host (10.99.0.254) runs vwifi-server for inter-VM WiFi frame relay.

## Scripts

| Script | Purpose |
|--------|---------|
| `rollback-lab.sh` | Comprehensive teardown: stop lab, kill scoped processes, remove TAPs/bridge, clean runtime state, verify idempotent cleanup. Run with `sudo`. |
| `build-libremesh-image.sh` | Build custom LibreMesh firmware with vwifi support |
| `build-wmediumd.sh` | Build a relocatable wmediumd binary with vendored libconfig into `bin/` |
| `convert-prebuilt.sh` | Download and convert LibreRouterOS pre-built image |
| `configure-source-image.sh` | Mount a source-built image, install SSH keys and DHCP config |
| `configure-source-vms.sh` | Configure source-built VMs via serial console (SSH keys, hostname, IP) |
| `configure-vms.sh` | Post-boot: hostname, IP, mesh protocol (babeld/bmx7), lime-config, SSH keys |
| `inject-keys-serial.sh` | Inject SSH public key into running VM via serial console |
| `prepare-source-image.sh` | Mount a source-built ext4 image, pre-bake SSH keys and known_hosts |
| `start-vwifi.sh` | Compile and launch vwifi-server |
| `start-mesh.sh` | Launch 4 QEMU VMs with TAP/bridge networking |
| `stop-mesh.sh` | Stop VMs via pid files (for simple stop without full cleanup; prefer `rollback-lab.sh`) |
| `mesh-status.sh` | Status check: VM state, SSH, vwifi, bridge, PID aliveness |
| `run-testbed-adapter.sh` | Run adapter scripts with testbed path mapping |
| `validate-adapters.sh` | Validate all adapter scripts against test bed |
| `preflight-namespace.sh` | Non-mutating check for namespace/wmediumd tool availability |
| `collect-logs.sh` | Collect logs for CI artifact upload |

## Suite Selection

The default test command is intentionally safe:

```bash
bin/libremesh-lab test
bin/libremesh-lab test --suite fast
```

Available suites:

| Suite | Requirements | Notes |
|-------|--------------|-------|
| `fast` | No VMs, no Mesha checkout, no root | CLI contract, `run-adapter` workspace isolation, and namespace preflight |
| `lab` | Already running and configured QEMU/vwifi lab | Mesh protocol and rollback checks |
| `adapter` | Running lab plus `MESHA_ROOT=/path/to/mesha` | Mesha adapters, rollout, drift, validation, readonly, and failure-path checks |
| `lifecycle` | Isolated host, root-capable start/stop, `RUN_LIFECYCLE_TESTS=1` | Destructive lifecycle cleanup coverage |
| `namespace` | Isolated host with namespace/wmediumd prerequisites | Runs preflight by default; with `RUN_NAMESPACE_TESTS=1`, runs a root-gated two-node hwsim/wmediumd mesh smoke |

`lab` and `adapter` do not create the VMs themselves. Build or prepare the
firmware, start the lab with root privileges, wait for boot, run
`bin/libremesh-lab configure`, and then run those suites. Use `CONVERGE_WAIT` and
`QEMU_TIMEOUT_MULTIPLIER` on slower hosts.

The namespace suite runs the safe preflight first. The preflight checks for
`ip`, `ip netns`, `iw`, `wmediumd`, `modprobe`, `ping`, `timeout`, and
`mac80211_hwsim` availability without creating namespaces, loading kernel
modules, or requiring root:

```bash
bash scripts/qemu/preflight-namespace.sh
bin/libremesh-lab test --suite namespace
sudo env RUN_NAMESPACE_TESTS=1 bin/libremesh-lab test --suite namespace
```

With `RUN_NAMESPACE_TESTS=1`, the suite loads two disposable hwsim radios, moves
one PHY into a network namespace, starts `wmediumd`, joins both interfaces to an
802.11s mesh, verifies ping over the simulated medium, and cleans up. Run it
only on an isolated host; if `mac80211_hwsim` is already loaded, set
`LIBREMESH_LAB_NAMESPACE_RESET_HWSIM=1` only when it is safe to unload/reload it.

## Test Files

| Test file | Tests |
|-----------|-------|
| `test-fast-cli.sh` | CLI contract: status JSON, stop path, missing suite error |
| `test-run-adapter.sh` | No-VM adapter workspace isolation, source writeback prevention |
| `test-qemu-script-units.sh` | Static unit tests: convert-prebuilt parser, fdisk partition-2 awk, ed25519 ssh-config migration |
| `test-mesh-status-pid.sh` | Runtime PID aliveness checks: /proc-based detection, stale PID, vwifi PID |
| `test-mesh-protocols.sh` | Protocol-agnostic convergence: detected protocol active, gateway alive, routing, restart |
| `test-validate-node.sh` | Healthy node, missing SSID detection, no neighbors detection (protocol-agnostic) |
| `test-config-drift.sh` | UCI write/read, drift detection |
| `test-topology-manipulation.sh` | vwifi-ctrl distance-based loss (bmx7 TQ), protocol-agnostic node removal detection |
| `test-firmware-upgrade.sh` | Firmware version change, validate-node mismatch |
| `test-multi-hop.sh` | End-to-end multi-hop connectivity (protocol-agnostic) |
| `test-rollback.sh` | Configuration backup and rollback |
| `test-rollout.sh` | Rolling configuration update dry runs |
| `test-failure-paths.sh` | Unreachable hosts and adapter error handling (protocol-agnostic recovery) |
| `test-topologies.sh` | Line, star, and partition topology convergence (protocol-agnostic) |
| `test-namespace-wmediumd.sh` | Root-gated two-node hwsim/wmediumd namespace smoke |
| `test-namespace-preflight.sh` | No-root namespace/wmediumd preflight regression |

## Adapter Isolation

`bin/libremesh-lab run-adapter <script> [args...]` runs Mesha or other adapter
scripts from a temporary workspace instead of the caller repository. The wrapper:

- Maps lab `config/inventories`, `config/desired-state`, `config/topology.yaml`, and SSH config into the temporary workspace.
- Copies adapter repository entries into the temporary workspace while excluding selected generated or heavy top-level entries such as `.git`, `.venv`, `node_modules`, `exports`, `images`, `logs`, and `run`, then removes VCS metadata from the copy.
- Exposes `REPO_ROOT`, `WORKSPACE_ROOT`, `SOURCE_WORKSPACE_ROOT`, `LIBREMESH_LAB_ROOT`, `LIBREMESH_LAB_CONFIG`, `LIBREMESH_LAB_INVENTORIES`, `LIBREMESH_LAB_DESIRED_STATE`, `SSH_CONFIG_PATH`, `SSH_KEY`, and `GIT_SSH_COMMAND`.
- Sets an isolated `HOME` and an SSH wrapper that automatically uses the lab SSH config.

This lets adapter scripts that expect repository-relative paths run against lab
fixtures without writing generated files back into the source checkout.

## Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 4 GB | 8 GB |
| CPU | 2 cores (TCG) | 4+ cores (KVM) |
| Disk | 2 GB | 5 GB |
| Permissions | sudo/CAP_NET_ADMIN for VM networking | root on isolated QA hosts |

Host root privileges are required for commands that create or remove bridge, TAP,
dnsmasq, vwifi, QEMU, loopback mount, or namespace state. In practice, run
`start`, `stop`, direct `start-vwifi.sh`, direct `start-mesh.sh`, direct
`stop-mesh.sh`, and pre-built image conversion with `sudo` when prompted by the
host. `status`, `logs`, `configure`, `test --suite fast`, and `run-adapter`
should run unprivileged after the lab exists.

Namespace work starts with the non-mutating preflight:

```bash
bash scripts/qemu/preflight-namespace.sh
```

Only run root-backed namespace creation or module loading on an isolated host
after bridge, namespace, and wireless simulation cleanup expectations are clear.

## Known Limitations

- TCG mode (no KVM) is 3x slower — increase timeouts
- Pre-built images lack WiFi simulation (mac80211_hwsim, vwifi)
- Mesh protocol convergence (babeld or bmx7) takes 30-60s in a virtualized environment
- babeld in a wired br-lan topology installs 0 kernel routes (L2 already handles reachability);
  neighbour count is verified via the daemon's UDP listener presence instead
- vwifi-ctrl only supports global packet loss (not per-link)

## Troubleshooting

See [troubleshooting.md](troubleshooting.md).
