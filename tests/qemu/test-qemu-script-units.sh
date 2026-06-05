#!/usr/bin/env bash
# Static unit tests for the new and modified scripts in the staged changes:
#   - convert-prebuilt.sh --help exposes the antennine URL, --profile, --release
#   - convert-prebuilt.sh option parser handles new flags (not just help text)
#   - config/ssh-config has migrated to id_ed25519 (no id_rsa)
#   - configure-source-image.sh fdisk regex matches both /dev/loop0p2
#     and images/file.img2 style partition lines, and rejects /dev/loop0p12
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# QEMU Script Unit Tests"
tap_plan 9

# ─── convert-prebuilt.sh --help ───────────────────────────────────────────────
CONVERT_HELP="${LAB_ROOT}/scripts/qemu/convert-prebuilt.sh"
HELP_OUTPUT=""
HELP_EXIT=0
HELP_OUTPUT="$("${CONVERT_HELP}" --help 2>&1)" || HELP_EXIT=$?
if [ "${HELP_EXIT}" -eq 0 ] \
    && echo "${HELP_OUTPUT}" | grep -q -- "--profile" \
    && echo "${HELP_OUTPUT}" | grep -q -- "--release" \
    && echo "${HELP_OUTPUT}" | grep -q "antennine" \
    && echo "${HELP_OUTPUT}" | grep -q "2024.1-ow23.05.5" \
    && ! echo "${HELP_OUTPUT}" | grep -q "repo.librerouter.org" \
    && ! echo "${HELP_OUTPUT}" | grep -q "librerouteros-prebuilt.img"; then
    pass "test_convert_prebuilt_help_exposes_new_flags"
else
    fail "test_convert_prebuilt_help_exposes_new_flags" "exit=${HELP_EXIT}; output=${HELP_OUTPUT}"
fi

# ─── convert-prebuilt.sh option parser ────────────────────────────────────────
# Validate the parser actually consumes values, not just that the help text
# contains the flags. The previous `for arg; shift; case` parser silently
# accepted the values but never bound them to PROFILE/RELEASE (and then
# the download path ran with the defaults, so a tester who passed
# `--profile mini` got the default profile's image anyway). The fix is a
# while-shift2 loop; this test exercises it by stubbing `wget` in PATH
# with a recorder script that prints the URL it received, then errors
# out before downloading. The URL contains PROFILE/RELEASE, so the
# recorder's output proves the parser consumed them.
PARSER_PROBE_DIR=$(mktemp -d)
WGET_STUB="${PARSER_PROBE_DIR}/wget"
cat > "${WGET_STUB}" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub wget used by test_convert_prebuilt_parser_consumes_*: print the
# URL we were asked to fetch (last positional arg) and the output path
# (the -O target) so the test can verify the parser's values made it into
# the constructed URL. Then exit non-zero to halt convert-prebuilt.sh
# before it touches any real image.
for arg in "$@"; do
    case "${arg}" in
        http://*|https://*) echo "WGET_URL=${arg}" ;;
        -O) shift_next=1 ;;
        *)
            if [[ "${shift_next:-0}" == "1" ]]; then
                echo "WGET_OUTPUT=${arg}"
                shift_next=0
            fi
            ;;
    esac
done
exit 1
STUB_EOF
chmod +x "${WGET_STUB}"
PARSER_PROBE_OUT=$(PATH="${PARSER_PROBE_DIR}:${PATH}" \
    REPO_ROOT="${PARSER_PROBE_DIR}" \
    bash "${LAB_ROOT}/scripts/qemu/convert-prebuilt.sh" \
    --profile mini \
    --release 2024.99-test \
    --output /tmp/probe-image.img 2>&1 || true)
rm -rf "${PARSER_PROBE_DIR}"
if echo "${PARSER_PROBE_OUT}" | grep -q "2024.99-test" \
   && echo "${PARSER_PROBE_OUT}" | grep -q "mini"; then
    pass "test_convert_prebuilt_parser_consumes_profile_and_release"
else
    fail "test_convert_prebuilt_parser_consumes_profile_and_release" "injected values not in constructed URL; output: ${PARSER_PROBE_OUT}"
fi

# Unknown-option handling: convert-prebuilt.sh must reject --no-such-flag
# (the previous `for arg; shift; case` parser silently accepted unknowns
# and the option was harmlessly ignored).
UNKNOWN_OUT=$(bash "${LAB_ROOT}/scripts/qemu/convert-prebuilt.sh" --no-such-flag 2>&1 || true)
if echo "${UNKNOWN_OUT}" | grep -qi "unknown option\|ERROR"; then
    pass "test_convert_prebuilt_parser_rejects_unknown_option"
else
    fail "test_convert_prebuilt_parser_rejects_unknown_option" "output=${UNKNOWN_OUT}"
fi

# ─── rollback-lab.sh sudo re-exec preserves parsed args ───────────────────────
# rollback-lab.sh parses --full before its root check. Preserve the original
# argv for sudo re-exec so a non-root `bin/rollback-lab.sh --full` does not
# silently become a root `bin/rollback-lab.sh` without --full.
ROLLBACK_PROBE_DIR=$(mktemp -d)
ROLLBACK_ID_STUB="${ROLLBACK_PROBE_DIR}/id"
ROLLBACK_SUDO_STUB="${ROLLBACK_PROBE_DIR}/sudo"
cat > "${ROLLBACK_ID_STUB}" <<'STUB_EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
    echo 1000
    exit 0
fi
exec /usr/bin/id "$@"
STUB_EOF
cat > "${ROLLBACK_SUDO_STUB}" <<'STUB_EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    printf 'SUDO_ARG=%s\n' "${arg}"
done
exit 77
STUB_EOF
chmod +x "${ROLLBACK_ID_STUB}" "${ROLLBACK_SUDO_STUB}"
ROLLBACK_REEXEC_OUT=$(PATH="${ROLLBACK_PROBE_DIR}:${PATH}" \
    bash "${LAB_ROOT}/bin/rollback-lab.sh" --full 2>&1 || true)
rm -rf "${ROLLBACK_PROBE_DIR}"
if echo "${ROLLBACK_REEXEC_OUT}" | grep -qx 'SUDO_ARG=--full'; then
    pass "test_rollback_full_arg_survives_sudo_reexec"
else
    fail "test_rollback_full_arg_survives_sudo_reexec" "output=${ROLLBACK_REEXEC_OUT}"
fi

if grep -q 'LAB_SCOPE_TOKENS=.*"vwifi"' "${LAB_ROOT}/bin/rollback-lab.sh"; then
    fail "test_rollback_scope_tokens_do_not_match_process_name" "LAB_SCOPE_TOKENS must not include broad process-name token 'vwifi'"
else
    pass "test_rollback_scope_tokens_do_not_match_process_name"
fi

# ─── config/ssh-config uses id_ed25519 ────────────────────────────────────────
SSH_CONFIG_SRC="${LAB_ROOT}/config/ssh-config"
if [ ! -f "${SSH_CONFIG_SRC}" ]; then
    fail "test_ssh_config_uses_ed25519" "missing ${SSH_CONFIG_SRC}"
elif grep -q "id_ed25519" "${SSH_CONFIG_SRC}" \
    && ! grep -q "id_rsa" "${SSH_CONFIG_SRC}"; then
    pass "test_ssh_config_uses_ed25519"
else
    fail "test_ssh_config_uses_ed25519" "ssh-config did not fully migrate to id_ed25519"
fi

# ─── configure-source-image.sh fdisk parser ──────────────────────────────────
# Exercises the production awk (scripts/qemu/parse-fdisk-partition.awk) so
# the test fails when the shipped parser drifts. Tolerates both fdisk
# output formats (see header in parse-fdisk-partition.awk).
#
# Fixture 1 (modern, no CHS columns): util-linux >=2.38 on this system.
# Fixture 2 (old, CHS columns): pre-2.38 format where StartCHS/EndCHS
# contain commas (e.g. "0,32,33") and the awk skips them via the numeric
# field check. Both must yield the same StartLBA (500048).
#
# Each partition gets a unique start sector so a wrong match is
# always detectable.
AWK_SCRIPT="${LAB_ROOT}/scripts/qemu/parse-fdisk-partition.awk"
if [ ! -f "${AWK_SCRIPT}" ]; then
    fail "test_fdisk_partition2_parser_matches_both_forms" "missing ${AWK_SCRIPT}"
    fail "test_fdisk_partition2_parser_loop_and_file_independent" "missing ${AWK_SCRIPT}"
    fail "test_fdisk_partition2_parser_rejects_loop0p12" "missing ${AWK_SCRIPT}"
    tap_summary
    exit 0
fi

# Modern format (no CHS) with both loop and file rows, PLUS an old-format
# row (comma-bearing CHS columns) so the "both forms" test actually exercises
# the comma-skipping logic that is the awk's reason for existence.
FDISK_OUT='Disk images/libremesh-x86-64-source-built.img: 250 MB, 262144000 bytes, 512000 sectors
Units: sectors of 1 * 512 = 512 bytes

Device     Boot StartCHS EndCHS StartLBA EndLBA Sectors Size Id Type
images/libremesh-x86-64-source-built.img1  *  0,1,0    121,45,32   2048  500000  497953  243.0M 83 Linux
/dev/loop0p2                                     0,32,33  121,45,32  500048  600000  99953   48.8M 83 Linux
images/libremesh-x86-64-source-built.img2        0,65,66  121,45,32  700000  800000  100001  48.8M 83 Linux'

EXTRACTED=$(echo "${FDISK_OUT}" | awk -f "${AWK_SCRIPT}" | tail -1)
# With /dev/loop0p2 + images/file.img2 both present, the last match wins.
# Last match: images/file.img2, start sector 700000.
if [ "${EXTRACTED}" = "700000" ]; then
    pass "test_fdisk_partition2_parser_matches_both_forms"
else
    fail "test_fdisk_partition2_parser_matches_both_forms" "expected '700000', got '${EXTRACTED}'"
fi

# Spot-check each form independently to make the failure mode obvious.
LOOP_ONLY=$(printf '/dev/loop0p1 * 2048 500000 497953 243M 83 Linux\n/dev/loop0p2   500048 600000 99953 49M 83 Linux\n' \
    | awk -f "${AWK_SCRIPT}" | tail -1)
FILE_ONLY=$(printf 'images/file.img1 * 2048 500000 497953 243M 83 Linux\n/images/file.img2   700000 800000 100001 49M 83 Linux\n' \
    | awk -f "${AWK_SCRIPT}" | tail -1)
if [ "${LOOP_ONLY}" = "500048" ] && [ "${FILE_ONLY}" = "700000" ]; then
    pass "test_fdisk_partition2_parser_loop_and_file_independent"
else
    fail "test_fdisk_partition2_parser_loop_and_file_independent" "loop=${LOOP_ONLY} file=${FILE_ONLY}"
fi

# Regression check: a 12-partition image (loop0p12) must NOT be picked
# as "partition 2". With the anchor in place, only /dev/loop0p2 matches.
# p2 has start sector 500048; p12 has start sector 600048. If the broken
# `/2$/` regex were used, p12 would also match and `tail -1` would pick
# 600048. The correct regex (`(^|[^[:digit:]])2$`) skips p12 because the
# character before the trailing `2` is `1` (a digit), so the
# `(^|[^[:digit:]])` alternation fails.
P12_OUT=$(printf '/dev/loop0p2  500048 600000 99953 49M 83 Linux\n/dev/loop0p12 600048 700000 99953 49M 83 Linux\n' \
    | awk -f "${AWK_SCRIPT}" | tail -1)
if [ "${P12_OUT}" = "500048" ]; then
    pass "test_fdisk_partition2_parser_rejects_loop0p12"
else
    fail "test_fdisk_partition2_parser_rejects_loop0p12" "expected '500048' (partition 2), got '${P12_OUT}' (regex picked the wrong partition)"
fi

tap_summary
