<p align="center">
  <strong>LibreMesh Lab</strong>
</p>

<p align="center">
  A standalone QEMU testbed for LibreMesh &amp; OpenWrt — simulate mesh networks, test firmware, validate configurations, all on your local machine.
</p>

<p align="center">
  <a href="https://github.com/coolabnet/libremesh-lab/issues">Report Bug</a>
  &middot;
  <a href="https://github.com/coolabnet/libremesh-lab/issues">Request Feature</a>
</p>

---

## Why LibreMesh Lab?

Testing community mesh networks on real hardware is slow, expensive, and hard to reproduce. LibreMesh Lab gives you a **complete virtual mesh network on your laptop** in minutes:

- **4 QEMU virtual machines** running real LibreMesh firmware (gateway, relay, leaf, tester)
- **WiFi mesh simulation** via vwifi — no wireless hardware needed
- **Multi-hop topology testing** — line, star, and partition topologies out of the box
- **BMX7 protocol convergence** — test routing, neighbor discovery, and mesh protocols
- **Config drift detection** — validate UCI changes and catch regressions
- **Firmware upgrade simulation** — test upgrade and rollback flows safely
- **Mesha adapter integration** — run your adapter scripts against a real(ish) mesh

## Quick Start

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/coolabnet/libremesh-lab/main/scripts/install.sh | bash
```

This clones the repo to `~/.local/share/libremesh-lab` and symlinks the CLI to `~/.local/bin/libremesh-lab`. Add `~/.local/bin` to your `PATH` if needed.

### Build, start, test

```bash
# 1. Build or download a LibreMesh firmware image
libremesh-lab build-image

# 2. Start the virtual mesh network (requires root for bridge/TAP/dnsmasq/QEMU networking)
sudo libremesh-lab start

# 3. Wait ~90s for boot, then configure VMs
libremesh-lab configure

# 4. Run safe VM-free checks
libremesh-lab test --suite fast

# 5. Check status
libremesh-lab status

# 6. Tear down VM networking when done
sudo libremesh-lab stop
```

For full VM-backed verification, keep the lab running after `configure`, then run
the `lab` suite and, when a Mesha checkout is available, the `adapter` suite:

```bash
libremesh-lab test --suite lab
MESHA_ROOT=/path/to/mesha libremesh-lab test --suite adapter
```

Destructive start/stop lifecycle coverage is opt-in:

```bash
RUN_LIFECYCLE_TESTS=1 libremesh-lab test --suite lifecycle
```

## Architecture

```
                        ┌──────────────────────┐
                        │    Host (10.99.0.254) │
                        │    vwifi-server       │
                        │    mesha-br0 bridge   │
                        └──────┬───────────────┘
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                     │
    ┌─────┴─────┐       ┌─────┴─────┐        ┌─────┴─────┐
    │  node-1   │───────│  node-2   │────────│  node-3   │
    │ gateway   │  hop  │  relay    │  hop   │   leaf    │
    │ .11       │       │  .12      │        │   .13     │
    └───────────┘       └───────────┘        └───────────┘
                              │
                        ┌─────┴─────┐
                        │  tester   │
                        │  .14      │
                        │  (512MB)  │
                        └───────────┘
```

Each VM has three network interfaces:

| Interface | Type | Purpose |
|-----------|------|---------|
| `mesh0` | TAP via `mesha-br0` | Management SSH + wired mesh |
| `wan0` | QEMU user-mode | Internet access |
| `wlan0` | vwifi-client | WiFi mesh simulation |

## CLI Reference

```
libremesh-lab <command> [args...]

Commands:
  build-image              Build or prepare a LibreMesh firmware image
  start                    Start the QEMU/vwifi lab
  configure                Configure booted lab VMs
  stop                     Stop VMs and clean networking state
  status                   Print lab status as JSON
  logs                     Collect lab logs
  test [--suite fast]      Run lab tests; default suite is fast
  run-adapter <script>     Run an external adapter against lab config
```

## Topologies

LibreMesh Lab ships with three pre-configured topologies in `config/`:

| Topology | File | Layout |
|----------|------|--------|
| **Line** | `topology.yaml` | node-1 -> node-2 -> node-3 (multi-hop) |
| **Star** | `topology-star.yaml` | node-1 hub with spokes |
| **Partition** | `topology-partition.yaml` | Split network for partition testing |

Switch topologies by pointing `start` to the desired config.

## Test Suites

`libremesh-lab test` defaults to the VM-free `fast` suite. Select broader
coverage explicitly:

| Suite | Requires VMs? | Requires Mesha? | Root requirement | Purpose |
|-------|---------------|-----------------|------------------|---------|
| `fast` | No | No | No | CLI contract, adapter-wrapper isolation, and namespace preflight checks |
| `lab` | Yes, already running and configured | No | Root only for prior `start`/later `stop` | Mesh protocol and rollback checks |
| `adapter` | Yes, already running and configured | Yes, `MESHA_ROOT=/path/to/mesha` | Root only for prior `start`/later `stop` | Mesha adapter, rollout, drift, validation, and failure-path coverage |
| `lifecycle` | It starts/stops the lab | Optional for topology checks | Yes; set `RUN_LIFECYCLE_TESTS=1` | Destructive lifecycle and cleanup coverage |
| `namespace` | Future track | No | Future namespace privileges | Placeholder for host namespace/wmediumd tests |

Run the default safe suite:

```bash
libremesh-lab test
libremesh-lab test --suite fast
```

Run VM-backed suites after `sudo libremesh-lab start` and `libremesh-lab configure`:

```bash
libremesh-lab test --suite lab
MESHA_ROOT=/path/to/mesha libremesh-lab test --suite adapter
```

The namespace suite is not implemented yet, but it runs the safe host preflight
first:

```bash
bash scripts/qemu/preflight-namespace.sh
libremesh-lab test --suite namespace
```

The preflight checks for tools and kernel support such as `ip`, `iw`, `wmediumd`,
`modprobe`, `unshare` or `ip netns`, and `mac80211_hwsim` availability without
creating namespaces, loading modules, or requiring root. Without
`RUN_NAMESPACE_TESTS=1`, `--suite namespace` reports the preflight result, prints
a skip-style message, and exits zero; with the variable set it exits nonzero
until real namespace tests land.

### Test files

| Test | What it covers |
|------|----------------|
| `test-adapters.sh` | collect-nodes JSON, collect-topology, thisnode discovery |
| `test-mesh-protocols.sh` | BMX7 neighbors, originators, mesh routing, Babel fallback |
| `test-validate-node.sh` | Healthy node checks, missing SSID, no neighbors |
| `test-config-drift.sh` | UCI write/read, drift detection |
| `test-topology-manipulation.sh` | vwifi-ctrl distance-based loss, node removal |
| `test-firmware-upgrade.sh` | Firmware version changes, validate-node mismatch |
| `test-multi-hop.sh` | End-to-end multi-hop connectivity |
| `test-rollback.sh` | Configuration rollback flows |
| `test-rollout.sh` | Rolling configuration updates |
| `test-failure-paths.sh` | Error handling and failure scenarios |
| `test-run-adapter-wrapper.sh` | No-VM adapter workspace isolation regression |
| `test-namespace-preflight.sh` | No-root namespace/wmediumd preflight regression |

Run the safe suite:

```bash
libremesh-lab test --suite fast
# Or directly:
bash tests/qemu/run-all.sh --suite fast
```

Lifecycle tests are gated behind `RUN_LIFECYCLE_TESTS=1`. Convergence-sensitive
tests accept `CONVERGE_WAIT` and `QEMU_TIMEOUT_MULTIPLIER` env vars.

## Mesha Integration

LibreMesh Lab is designed to work as a test backend for [Mesha](https://github.com/coolabnet/mesha) adapter scripts:

```bash
# From a Mesha checkout:
../libremesh-lab/bin/libremesh-lab run-adapter \
  "$PWD/adapters/mesh/collect-nodes.sh" lm-testbed-node-1
```

The lab provides inventories, desired state, SSH configuration, keys, and hostname aliases — no changes needed in the caller repository.

`run-adapter` executes the adapter from a temporary workspace. It exposes lab
paths through `LIBREMESH_LAB_ROOT`, `LIBREMESH_LAB_CONFIG`,
`LIBREMESH_LAB_INVENTORIES`, `LIBREMESH_LAB_DESIRED_STATE`, `REPO_ROOT`,
`WORKSPACE_ROOT`, `SSH_CONFIG_PATH`, `SSH_KEY`, and `GIT_SSH_COMMAND`, with an
isolated `HOME`. Lab inventories, desired state, topology, and SSH config are
mapped into the workspace, while adapter repository entries are copied in with
selected generated top-level directories excluded and VCS metadata removed. This
lets scripts that assume repository-relative paths run without writing back into
the caller repo.

## Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| **RAM** | 4 GB | 8 GB |
| **CPU** | 2 cores (TCG) | 4+ cores (KVM) |
| **Disk** | 2 GB | 5 GB |
| **OS** | Linux | Linux with KVM |
| **Permissions** | sudo / CAP_NET_ADMIN for VM networking | root on isolated QA hosts |

### Software dependencies

- **QEMU** (`qemu-system-x86_64`) — VM emulation
- **bash** 4+ — script runtime
- **git**, **curl** — installation and image download
- **bridge-utils**, **iproute2** — networking (`ip`, `brctl`)
- **dnsmasq** — DHCP for VM management network

Root is required for commands that create or remove host networking state:
`start`, `stop`, direct `scripts/qemu/start-vwifi.sh`,
`scripts/qemu/start-mesh.sh`, `scripts/qemu/stop-mesh.sh`, and some image
preparation flows that mount loopback filesystems. `status`, `logs`,
`configure`, `test --suite fast`, and `run-adapter` normally run unprivileged
after the lab exists.

## Project Structure

```
libremesh-lab/
├── bin/libremesh-lab            # CLI entrypoint
├── scripts/
│   ├── install.sh               # One-line installer
│   └── qemu/                    # QEMU lifecycle scripts
│       ├── build-libremesh-image.sh
│       ├── start-mesh.sh
│       ├── start-vwifi.sh
│       ├── configure-vms.sh
│       ├── stop-mesh.sh
│       ├── mesh-status.sh
│       ├── collect-logs.sh
│       └── ...
├── config/
│   ├── topology.yaml            # Line topology (default)
│   ├── topology-star.yaml
│   ├── topology-partition.yaml
│   ├── ssh-config               # SSH template for VMs
│   ├── inventories/             # Node inventories
│   └── desired-state/           # Desired configuration state
├── tests/qemu/                  # Integration test suite
│   ├── common.sh                # TAP-style test helpers
│   ├── fixtures/                # Test fixtures
│   ├── run-all.sh               # Test runner
│   └── test-*.sh                # Individual test files
├── docs/                        # User-facing documentation
├── research/                    # Research notes
├── docker/qemu-builder/         # Docker-based image builder
└── plans/archive/               # Archived implementation plans
```

Runtime artifacts (`run/`, `images/`, `src/`) are gitignored.

## Known Limitations

- **TCG mode** (no KVM) is ~3x slower — increase timeouts with `QEMU_TIMEOUT_MULTIPLIER`
- **Pre-built images** lack WiFi simulation (`mac80211_hwsim`, `vwifi`)
- **BMX7 convergence** takes 30-60s in virtualized environments
- **vwifi-ctrl** only supports global packet loss (not per-link)

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for common issues and solutions.

## Contributing

Contributions are welcome! This project uses [Conventional Commits](https://www.conventionalcommits.org/):

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m 'feat: add amazing feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

### Development conventions

- Shell scripts use `set -euo pipefail` with Bash
- Test files follow `test-*.sh` naming, using TAP-style helpers from `tests/qemu/common.sh`
- YAML uses two-space indentation
- Script filenames are lowercase and hyphenated (`start-mesh.sh`)

## License

LibreMesh Lab is free software. See [LICENSE](LICENSE) for details.

## Links

- **LibreMesh**: [https://libremesh.org](https://libremesh.org)
- **OpenWrt**: [https://openwrt.org](https://openwrt.org)
- **Mesha**: [https://github.com/coolabnet/mesha](https://github.com/coolabnet/mesha)
- **Cooolab**: [https://coolab.org](https://coolab.org)
