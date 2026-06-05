# Mesha Integration

LibreMesh Lab can act as a test backend for [Mesha](https://github.com/coolabnet/mesha) and other adapter scripts. It provides a running LibreMesh-like environment, SSH aliases, inventories, desired state, and temporary workspaces so adapter code can be tested without touching real routers.

## What This Is For

Use this integration when you want to:

- run Mesha mesh adapter scripts against virtual LibreMesh nodes;
- test JSON-over-SSH collection scripts;
- validate rollout, drift, readonly, and failure-path behavior;
- keep generated files out of the source checkout that owns the adapter script.

## Basic Usage

From a Mesha checkout:

```bash
../libremesh-lab/bin/libremesh-lab run-adapter \
  "$PWD/adapters/mesh/collect-nodes.sh" lm-testbed-node-1
```

From inside this repository, the command shape is:

```bash
bin/libremesh-lab run-adapter /path/to/adapter-script [args...]
```

For the full adapter test suite:

```bash
sudo bin/libremesh-lab start
bin/libremesh-lab configure
MESHA_ROOT=/path/to/mesha bin/libremesh-lab test --suite adapter
sudo bin/rollback-lab.sh
```

## What the Lab Provides

The adapter runner exposes lab paths and SSH configuration through environment variables:

| Variable | Meaning |
|---|---|
| `LIBREMESH_LAB_ROOT` | Root path of the LibreMesh Lab checkout. |
| `LIBREMESH_LAB_CONFIG` | Path to lab configuration files. |
| `LIBREMESH_LAB_INVENTORIES` | Path to lab inventory YAML files. |
| `LIBREMESH_LAB_DESIRED_STATE` | Path to desired-state fixtures. |
| `REPO_ROOT` | Adapter workspace root visible to the script. |
| `WORKSPACE_ROOT` | Temporary workspace used for the adapter run. |
| `SOURCE_WORKSPACE_ROOT` | Original source checkout root when available. |
| `SSH_CONFIG_PATH` | SSH config file with lab node aliases. |
| `SSH_KEY` | SSH key used to connect to lab VMs. |
| `GIT_SSH_COMMAND` | SSH wrapper configured for the lab. |

The wrapper also sets an isolated `HOME` so adapter scripts do not accidentally read or write user-local state.

## Workspace Isolation

`run-adapter` creates a temporary workspace for each run.

It maps or copies:

- lab inventories;
- desired state;
- topology data;
- SSH configuration;
- adapter repository files needed by the script.

It excludes common generated or heavy directories such as:

- `.git`, `.hg`, `.svn`;
- `.venv`, `venv`, `node_modules`;
- `exports`, `images`, `logs`, `run`;
- common language cache directories.

This allows scripts that expect repository-relative paths to run normally while preventing writeback into the caller repository.

## Related Tests

The `adapter` suite covers adapter-oriented behavior including:

- collecting nodes and topology;
- discovery from `thisnode` aliases;
- rollout dry runs;
- configuration drift detection;
- readonly behavior;
- unreachable host and failure-path handling.

See [testing.md](testing.md) for the test matrix and [qemu-adapter-test-guide.md](qemu-adapter-test-guide.md) for the longer adapter walkthrough.

## Tips

- Start with `bin/libremesh-lab test --suite fast` to verify wrapper behavior without VMs.
- Use `MESHA_ROOT=/path/to/mesha` only for adapter tests that need a Mesha checkout.
- Run `bin/libremesh-lab logs` after failures and include logs in bug reports.
- Always clean up VM-backed runs with `sudo bin/rollback-lab.sh`.
