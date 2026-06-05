# Contributing

Contributions are welcome. LibreMesh Lab is a Bash/QEMU testbed, so most changes involve shell scripts, YAML configuration, QEMU lifecycle behavior, or integration tests.

## Repository Layout

| Path | Purpose |
|---|---|
| `bin/libremesh-lab` | Main CLI entrypoint. |
| `bin/rollback-lab.sh` | Comprehensive cleanup helper. |
| `scripts/qemu/` | QEMU, vwifi, image, configuration, and lifecycle scripts. |
| `tests/qemu/` | Bash integration tests and test runner. |
| `tests/qemu/common.sh` | Shared TAP-style test helpers. |
| `tests/qemu/fixtures/` | Test fixtures. |
| `config/` | Topologies, inventories, SSH config, and desired state. |
| `docs/` | User-facing documentation. |
| `research/` | Research notes. |
| `plans/archive/` | Archived implementation plans. |

Generated runtime data belongs in `run/`, built images in `images/`, and external checkouts in `src/`. Keep those artifacts out of commits.

## Development Conventions

- Shell scripts use Bash with `set -euo pipefail`.
- Prefer clear function names and quoted variable expansions.
- Use uppercase environment variables such as `MESHA_ROOT`, `CONVERGE_WAIT`, and `QEMU_TIMEOUT_MULTIPLIER`.
- Keep script filenames lowercase and hyphenated, for example `start-mesh.sh`.
- YAML uses two-space indentation and descriptive names.
- Test files are named `test-*.sh`.
- Add reusable test helpers to `tests/qemu/common.sh`.
- Add new suites or test entries to `tests/qemu/run-all.sh`.

## Testing Changes

Start with the safe suite:

```bash
bin/libremesh-lab test --suite fast
```

For VM-backed behavior:

```bash
sudo bin/libremesh-lab start
bin/libremesh-lab configure
bin/libremesh-lab test --suite lab
sudo bin/rollback-lab.sh
```

Adapter tests require Mesha:

```bash
MESHA_ROOT=/path/to/mesha bin/libremesh-lab test --suite adapter
```

Destructive lifecycle tests are opt-in:

```bash
RUN_LIFECYCLE_TESTS=1 bin/libremesh-lab test --suite lifecycle
```

Namespace/wmediumd work should start with the safe preflight:

```bash
bash scripts/qemu/preflight-namespace.sh
bin/libremesh-lab test --suite namespace
```

Only run root-backed namespace tests on an isolated host:

```bash
sudo env RUN_NAMESPACE_TESTS=1 bin/libremesh-lab test --suite namespace
```

## Commit Style

Use [Conventional Commits](https://www.conventionalcommits.org/) with concise subjects:

```text
feat: add topology validation
fix: clean stale vwifi pid files
docs: clarify adapter workflow
test: cover namespace preflight failure
```

## Pull Request Checklist

A good pull request should include:

- what testbed behavior changed;
- commands run and whether they passed;
- any sudo/root requirements;
- logs or status JSON when debugging QEMU, vwifi, networking, or adapter failures;
- notes about generated artifacts that should stay uncommitted.

## Safety Rules

- Do not commit generated VM state, built images, logs, keys, or local runtime files.
- Avoid changing the default bridge name `mesha-br0` unless Mesha adapter compatibility has been considered.
- When touching `config/topology.yaml`, verify SSH aliases, inventories, and test assumptions.
- Prefer `sudo bin/rollback-lab.sh` after VM-backed test sessions, especially on shared hosts.
- Root-mutating namespace tests must clean up namespaces, wmediumd, and disposable `mac80211_hwsim` radios.

## Agent and QA References

- Agent-facing workflow and conventions: [../AGENTS.md](../AGENTS.md)
- End-to-end QA runbook: [../QA.md](../QA.md)
