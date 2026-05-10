# LibreMesh Lab QA Runbook

This runbook is written for an AI agent testing LibreMesh Lab end to end. Start with the safe checks and only run VM-backed or destructive suites on a host that has the required privileges and can tolerate TAP/bridge changes.

## Ground Rules

- Do not commit generated files from `run/`, `logs/`, `exports/`, `images/`, `src/`, or local install smoke-test directories.
- Record command output, exit codes, host OS, kernel, available RAM/CPU, and whether KVM is available.
- If a privileged command fails, capture the exact error and stop that phase before trying cleanup.
- Before destructive lifecycle tests, verify no unrelated process is using the configured bridge, TAP prefix, or QEMU PID files.

## 1. Preflight

```bash
git status --short --ignored
git log --oneline --decorate -5
command -v bash git curl python3 ssh
command -v shellcheck || true
command -v qemu-system-x86_64 || true
command -v ip || true
command -v dnsmasq || true
```

Expected:

- Only intentional local files are modified or ignored.
- `bash`, `git`, `curl`, `python3`, and `ssh` are present for basic QA.
- QEMU, `ip`, and `dnsmasq` are present before VM-backed phases.

## 2. Static Checks

```bash
bash -n scripts/install.sh bin/libremesh-lab scripts/qemu/*.sh scripts/qemu/lib/*.sh tests/qemu/*.sh
shellcheck -x -P tests/qemu scripts/install.sh bin/libremesh-lab scripts/qemu/run-testbed-adapter.sh tests/qemu/run-all.sh tests/qemu/test-fast-cli.sh tests/qemu/test-run-adapter-wrapper.sh
git diff --check
```

Expected:

- Syntax checks pass.
- Targeted ShellCheck passes. Full-repository ShellCheck may still report existing informational warnings in older QEMU scripts; record them if reviewing broad cleanup.
- No whitespace errors.

## 3. Installer

Test default public install path in temporary directories:

```bash
rm -rf /tmp/libremesh-lab-install /tmp/libremesh-lab-bin
LIBREMESH_LAB_INSTALL_DIR=/tmp/libremesh-lab-install \
LIBREMESH_LAB_BIN_DIR=/tmp/libremesh-lab-bin \
bash scripts/install.sh
/tmp/libremesh-lab-bin/libremesh-lab --help
readlink /tmp/libremesh-lab-bin/libremesh-lab
git -C /tmp/libremesh-lab-install remote -v
```

Expected:

- The installer clones `https://github.com/coolabnet/libremesh-lab.git`.
- The symlink points at `/tmp/libremesh-lab-install/bin/libremesh-lab`.
- `--help` prints all supported commands.

Test pinned refs when a tag exists:

```bash
LIBREMESH_LAB_REF=<tag-or-commit> \
LIBREMESH_LAB_INSTALL_DIR=/tmp/libremesh-lab-install-pinned \
LIBREMESH_LAB_BIN_DIR=/tmp/libremesh-lab-bin-pinned \
bash scripts/install.sh
/tmp/libremesh-lab-bin-pinned/libremesh-lab --help
git -C /tmp/libremesh-lab-install-pinned rev-parse HEAD
```

Expected:

- The checkout resolves to the requested tag or commit.

## 4. CLI Contract

```bash
bin/libremesh-lab --help
bin/libremesh-lab status | python3 -m json.tool
bin/libremesh-lab logs
bin/libremesh-lab stop
bin/libremesh-lab test --help
bin/libremesh-lab test --suite fast
bin/libremesh-lab test --suite
bin/libremesh-lab test --suite nope
```

Expected:

- `status` exits zero and emits valid JSON even when the lab is not running.
- `logs` and `stop` are idempotent on a clean host.
- `test --suite fast` passes without VMs and without a Mesha checkout.
- Missing or invalid suite arguments exit nonzero and print a useful error.

## 5. Adapter Wrapper Isolation

Run the no-VM regression:

```bash
bin/libremesh-lab test --suite fast
```

Expected:

- `Run Adapter Wrapper` passes.
- The fixture writes only inside the temporary wrapper workspace, not back into the source fixture.

If a Mesha checkout is available, test a real adapter against a running lab after completing the lab startup phase:

```bash
MESHA_ROOT=/path/to/mesha bin/libremesh-lab run-adapter \
  /path/to/mesha/adapters/mesh/collect-nodes.sh lm-testbed-node-1
```

Expected:

- The adapter sees `REPO_ROOT`, `WORKSPACE_ROOT`, inventories, desired state, SSH config, and `LIBREMESH_LAB_*` environment variables from the lab wrapper.
- No files are written to the Mesha checkout except intentional adapter outputs if the adapter itself explicitly targets that checkout.

## 6. Image Build Or Preparation

Choose one image path:

```bash
bin/libremesh-lab build-image
```

or:

```bash
bash scripts/qemu/convert-prebuilt.sh
```

Expected:

- A usable image is present under `images/`.
- Build logs explain any missing package or build dependency.
- Generated images remain untracked.

## 7. QEMU/Vwifi Lab Startup

Run on a host with root privileges, TAP/bridge support, and enough RAM:

```bash
sudo bash scripts/qemu/start-vwifi.sh
sudo bash scripts/qemu/start-mesh.sh
sleep 90
bin/libremesh-lab configure
bin/libremesh-lab status | python3 -m json.tool
```

Expected:

- The configured bridge exists with the topology CIDR.
- All TAP devices exist.
- VM PID files exist under `run/`.
- `status` reports expected VM entries and SSH eventually becomes reachable.

## 8. Lab Suites

With the lab running and configured:

```bash
bin/libremesh-lab test --suite lab
```

Expected:

- Mesh protocol and rollback checks pass, or failures include enough logs to diagnose VM boot, SSH, BMX7, or routing problems.

With a Mesha checkout:

```bash
MESHA_ROOT=/path/to/mesha bin/libremesh-lab test --suite adapter
```

Expected:

- Adapter contract, topology manipulation, firmware upgrade, multi-hop, validation, config drift, rollout, maintenance, readonly, and failure-path checks either pass or fail with actionable lab logs.

## 9. Logs And Cleanup

```bash
bin/libremesh-lab logs
find run/logs -maxdepth 1 -type f -print
sudo bin/libremesh-lab stop
bin/libremesh-lab status | python3 -m json.tool
```

Expected:

- Host and VM logs are collected under `run/logs/`.
- Cleanup removes VM processes, vwifi server, dnsmasq PID, TAP devices, bridge, overlays, and lock directory.
- A second `bin/libremesh-lab stop` exits zero and reports nothing to clean.

## 10. Lifecycle Suite

Only run this on an isolated QA host:

```bash
RUN_LIFECYCLE_TESTS=1 bin/libremesh-lab test --suite lifecycle
```

Expected:

- The suite can start, inspect, and stop the testbed without leaving bridge, TAP, QEMU, vwifi, dnsmasq, overlay, or lock artifacts.
- Topology tests are skipped unless `MESHA_ROOT` is set.

## 11. Namespace Track

The namespace suite is a placeholder until namespace/wmediumd tests exist:

```bash
bin/libremesh-lab test --suite namespace
RUN_NAMESPACE_TESTS=1 bin/libremesh-lab test --suite namespace
```

Expected:

- Without `RUN_NAMESPACE_TESTS=1`, the suite reports a skip-like message and exits zero.
- With `RUN_NAMESPACE_TESTS=1`, it exits nonzero until real namespace tests are implemented.

## 12. Final Report

Summarize:

- Commit under test and whether the tree was clean before QA.
- Commands run and pass/fail results.
- Any skipped phase and the exact missing prerequisite.
- Any files left under `run/`, `logs/`, `exports/`, `images/`, or `/tmp/libremesh-lab-*`.
- Follow-up issues with severity and reproduction commands.
