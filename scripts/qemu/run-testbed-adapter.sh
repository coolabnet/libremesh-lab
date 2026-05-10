#!/usr/bin/env bash
# Run an adapter script against LibreMesh Lab without modifying the caller repo.
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAB_CONFIG="${LIBREMESH_LAB_CONFIG:-${LAB_ROOT}/config}"
RUN_DIR="${LAB_ROOT}/run"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <adapter-script> [args...]" >&2
  exit 1
fi

ADAPTER_SCRIPT="$1"
shift
ADAPTER_ARGS=("$@")

if [ ! -f "${ADAPTER_SCRIPT}" ]; then
  echo "ERROR: Adapter script not found: ${ADAPTER_SCRIPT}" >&2
  exit 1
fi

ADAPTER_SCRIPT="$(cd "$(dirname "${ADAPTER_SCRIPT}")" && pwd)/$(basename "${ADAPTER_SCRIPT}")"
ADAPTER_ROOT="$(git -C "$(dirname "${ADAPTER_SCRIPT}")" rev-parse --show-toplevel 2>/dev/null || true)"

SSH_KEY="${SSH_KEY:-${RUN_DIR}/ssh-keys/id_rsa}"
SSH_CONFIG_TEMPLATE="${LAB_CONFIG}/ssh-config"
SSH_CONFIG_RESOLVED="${LAB_CONFIG}/ssh-config.resolved"

if [ -f "${SSH_CONFIG_RESOLVED}" ]; then
  SSH_CONFIG="${SSH_CONFIG_RESOLVED}"
else
  SSH_CONFIG="$(mktemp /tmp/libremesh-lab-ssh-config.XXXXXX)"
  sed "s|__REPO_ROOT__|${LAB_ROOT}|g" "${SSH_CONFIG_TEMPLATE}" > "${SSH_CONFIG}"
fi

TMP_WORKSPACE="$(mktemp -d /tmp/libremesh-lab-adapter.XXXXXX)"
SSH_WRAPPER_DIR="$(mktemp -d /tmp/libremesh-lab-ssh-wrapper.XXXXXX)"

cleanup() {
  rm -rf "${TMP_WORKSPACE}" "${SSH_WRAPPER_DIR}"
  case "${SSH_CONFIG:-}" in /tmp/libremesh-lab-ssh-config.*) rm -f "${SSH_CONFIG}" ;; esac
}
trap cleanup EXIT

ln -s "${LAB_CONFIG}/inventories" "${TMP_WORKSPACE}/inventories"
ln -s "${LAB_CONFIG}/desired-state" "${TMP_WORKSPACE}/desired-state"
mkdir -p "${TMP_WORKSPACE}/exports" "${TMP_WORKSPACE}/logs"

EXEC_SCRIPT="${ADAPTER_SCRIPT}"
if [ -n "${ADAPTER_ROOT}" ] && [ -d "${ADAPTER_ROOT}" ]; then
  for entry in adapters skills scripts pyproject.toml LICENSE; do
    if [ -e "${ADAPTER_ROOT}/${entry}" ]; then
      ln -s "${ADAPTER_ROOT}/${entry}" "${TMP_WORKSPACE}/${entry}"
    fi
  done

  case "${ADAPTER_SCRIPT}" in
    "${ADAPTER_ROOT}"/*)
      REL_PATH="${ADAPTER_SCRIPT#${ADAPTER_ROOT}/}"
      EXEC_SCRIPT="${TMP_WORKSPACE}/${REL_PATH}"
      ;;
  esac
fi

cat > "${SSH_WRAPPER_DIR}/ssh" <<'WRAPPER'
#!/usr/bin/env bash
if [ -n "${SSH_CONFIG_PATH:-}" ] && [ -f "${SSH_CONFIG_PATH}" ]; then
  exec /usr/bin/ssh -F "${SSH_CONFIG_PATH}" "$@"
fi
exec /usr/bin/ssh "$@"
WRAPPER
chmod +x "${SSH_WRAPPER_DIR}/ssh"

HOSTALIASES_FILE="${RUN_DIR}/host-aliases"
if [ -f "${HOSTALIASES_FILE}" ]; then
  export HOSTALIASES="${HOSTALIASES_FILE}"
fi

export LIBREMESH_LAB_ROOT="${LAB_ROOT}"
export LIBREMESH_LAB_CONFIG="${LAB_CONFIG}"
export LIBREMESH_LAB_INVENTORIES="${LAB_CONFIG}/inventories"
export LIBREMESH_LAB_DESIRED_STATE="${LAB_CONFIG}/desired-state"
export REPO_ROOT="${TMP_WORKSPACE}"
export WORKSPACE_ROOT="${TMP_WORKSPACE}"
export SOURCE_WORKSPACE_ROOT="${ADAPTER_ROOT:-}"
export SSH_CONFIG_PATH="${SSH_CONFIG}"
export SSH_KEY="${SSH_KEY}"
export GIT_SSH_COMMAND="ssh -F ${SSH_CONFIG}"
export PATH="${SSH_WRAPPER_DIR}:${PATH}"

"${EXEC_SCRIPT}" "${ADAPTER_ARGS[@]}"
