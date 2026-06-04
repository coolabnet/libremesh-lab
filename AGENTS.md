# Repository Guidelines

## Project Structure & Module Organization

LibreMesh Lab is a standalone Bash/QEMU testbed for LibreMesh/OpenWrt operations.
The main CLI entrypoint is `bin/libremesh-lab`, which delegates to scripts under
`scripts/qemu/`. QEMU integration tests live in `tests/qemu/`, with shared
helpers in `tests/qemu/common.sh` and fixtures in `tests/qemu/fixtures/`.
Topology, inventories, SSH config templates, and desired state are in
`config/`. User-facing docs live in `docs/`; research notes are in `research/`;
archived implementation plans are in `plans/archive/`. Generated runtime data
belongs in `run/`, built images in `images/`, and external checkouts in `src/`;
keep these artifacts out of commits.

## Build, Test, and Development Commands

- `bin/libremesh-lab build-image`: build or prepare a LibreMesh firmware image.
- `bin/libremesh-lab start`: start the QEMU/vwifi lab. This may require root
  privileges for bridges, TAP devices, dnsmasq, and QEMU networking.
- `bin/libremesh-lab configure`: configure booted lab VMs after startup.
- `bin/libremesh-lab status`: print current lab status as JSON.
- `bin/libremesh-lab test`: run the default VM-free `fast` suite.
- `bin/libremesh-lab test --suite lab`: run tests that require an already
  running and configured QEMU/vwifi lab.
- `MESHA_ROOT=/path/to/mesha bin/libremesh-lab test --suite adapter`: run Mesha
  adapter tests against a running lab.
- `RUN_LIFECYCLE_TESTS=1 bin/libremesh-lab test --suite lifecycle`: run
  destructive lifecycle coverage on an isolated host.
- `bin/libremesh-lab test --suite namespace`: run the safe namespace/wmediumd
  preflight; use `sudo env RUN_NAMESPACE_TESTS=1 bin/libremesh-lab test --suite
  namespace` on an isolated host for the root-gated hwsim/wmediumd smoke.
- `bin/libremesh-lab stop`: stop VMs and clean runtime networking state.
- `sudo bin/rollback-lab.sh`: comprehensive undo — stops the lab, removes
  TAP devices, the bridge, runtime state, and the testbed lock. Idempotent.
  Use `--full` to also drop the passwordless sudo rule and remove
  `bin/wmediumd` / `bin/lib/`. Use it as the safe teardown after a
  `start` + `configure` + `test` session, especially on shared hosts.
- `scripts/qemu/build-wmediumd.sh`: build a relocatable wmediumd binary
  (with vendored libconfig) into `bin/wmediumd`. Defaults to a pinned
  `WMEDIUMD_REF` SHA; override `WMEDIUMD_REPO` / `WMEDIUMD_REF` deliberately
  when testing forks or upgrades.

## Workflow (full cycle)

```
# 1. Build or get an image (pick one)
bin/libremesh-lab build-image          # source-built LibreMesh
bash scripts/qemu/convert-prebuilt.sh  # prebuilt LibreRouterOS

# 2. For source-built images only: install SSH keys + DHCP
scripts/qemu/configure-source-image.sh --image images/libremesh-combined.img

# 3. Start lab (root)
sudo bin/libremesh-lab start           # → vwifi + 4 QEMU VMs on mesha-br0

# 4. Configure VMs (wait ~90s after step 3 for boot)
bin/libremesh-lab configure            # hostname, IP, mesh proto, SSH keys

# 5. Run tests
bin/libremesh-lab test                 # fast suite (no VMs needed)
bin/libremesh-lab test --suite lab     # lab suite (needs VMs up)
MESHA_ROOT=path bin/libremesh-lab test --suite adapter  # adapter suite

# 6. Teardown
sudo bin/rollback-lab.sh               # stop lab, kill processes, remove TAPs/bridge
sudo bin/rollback-lab.sh --full        # also drop sudo rule + bin/wmediumd
```

`bin/libremesh-lab start` delegates to `scripts/qemu/start-mesh.sh` (starts vwifi before booting VMs).
Use lower-level scripts under `scripts/qemu/` only when debugging a single phase.
User-facing docs with full architecture and test descriptions: `docs/README.md`.

## Coding Style & Naming Conventions

Shell scripts use Bash with `set -euo pipefail`. Prefer clear function names,
quoted variable expansions, and uppercase environment variables like
`MESHA_ROOT`, `CONVERGE_WAIT`, and `QEMU_TIMEOUT_MULTIPLIER`. Keep script
filenames lowercase and hyphenated, for example `start-mesh.sh` or
`test-config-drift.sh`. YAML uses two-space indentation and descriptive names.

## Testing Guidelines

Tests are Bash integration tests with TAP-style output helpers from
`tests/qemu/common.sh`. Name new test files `test-*.sh`, add reusable helpers to
`common.sh`, and add new suite entries to `tests/qemu/run-all.sh`. Prefer dry-run
coverage for destructive flows. Lifecycle tests are gated behind
`RUN_LIFECYCLE_TESTS=1`; convergence-sensitive tests can use `CONVERGE_WAIT` and
`QEMU_TIMEOUT_MULTIPLIER`. Namespace/wmediumd work starts with the non-mutating
`scripts/qemu/preflight-namespace.sh` check; root-mutating namespace tests must
be gated behind `RUN_NAMESPACE_TESTS=1` and must clean up namespaces, wmediumd,
and disposable `mac80211_hwsim` radios.

## Commit & Pull Request Guidelines

The current history uses Conventional Commits, for example
`feat: initial LibreMesh Lab repository`. Continue with concise prefixes such as
`feat:`, `fix:`, `docs:`, and `test:`. Pull requests should explain the testbed
behavior changed, list commands run, call out any sudo/root requirements, and
include logs or status JSON when debugging QEMU, vwifi, or adapter
failures.

## Safety & Configuration Tips

Do not commit generated VM state, built images, logs, keys, or local runtime
files. Avoid changing the default bridge name `mesha-br0` unless compatibility
with Mesha adapter tests is considered. When touching `config/topology.yaml`,
verify SSH aliases, inventories, and test assumptions.
