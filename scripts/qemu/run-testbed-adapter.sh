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
SYSTEM_SSH="$(command -v ssh || true)"
if [ -z "${SYSTEM_SSH}" ]; then
  echo "ERROR: ssh is required to run adapter scripts." >&2
  exit 1
fi

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
TMP_HOME="${TMP_WORKSPACE}/home"
TMP_WORKSPACE_REAL="$(cd "${TMP_WORKSPACE}" && pwd -P)"

cleanup() {
  rm -rf "${TMP_WORKSPACE}" "${SSH_WRAPPER_DIR}"
  case "${SSH_CONFIG:-}" in /tmp/libremesh-lab-ssh-config.*) rm -f "${SSH_CONFIG}" ;; esac
}
trap cleanup EXIT

copy_adapter_entry() {
  local entry="$1"
  local name
  name="$(basename "${entry}")"

  case "${name}" in
    .git|.hg|.svn|.venv|venv|node_modules|__pycache__|.pytest_cache|.mypy_cache|.ruff_cache)
      return
      ;;
    build|dist|exports|home|images|logs|run|tmp)
      return
      ;;
    inventories|desired-state)
      return
      ;;
  esac

  if [ -e "${TMP_WORKSPACE}/${name}" ] || [ -L "${TMP_WORKSPACE}/${name}" ]; then
    return
  fi

  cp -aL "${entry}" "${TMP_WORKSPACE}/${name}"
}

remove_vcs_metadata() {
  find "${TMP_WORKSPACE}" \
    \( -name .git -o -name .hg -o -name .svn \) \
    -prune -exec rm -rf {} +
}

map_lab_path() {
  local source_path="$1"
  local target_path="$2"
  local target_parent
  local target_parent_real

  target_parent="$(dirname "${target_path}")"
  mkdir -p "${target_parent}"
  target_parent_real="$(cd "${target_parent}" && pwd -P)"
  case "${target_parent_real}" in
    "${TMP_WORKSPACE_REAL}"|"${TMP_WORKSPACE_REAL}"/*) ;;
    *)
      echo "ERROR: Refusing to map lab path outside temp workspace: ${target_path}" >&2
      exit 1
      ;;
  esac
  rm -rf "${target_path}"
  ln -s "${source_path}" "${target_path}"
}

mkdir -p "${TMP_WORKSPACE}/exports" "${TMP_WORKSPACE}/logs" "${TMP_HOME}"

EXEC_SCRIPT="${ADAPTER_SCRIPT}"
if [ -n "${ADAPTER_ROOT}" ] && [ -d "${ADAPTER_ROOT}" ]; then
  while IFS= read -r -d '' entry; do
    copy_adapter_entry "${entry}"
  done < <(find "${ADAPTER_ROOT}" -mindepth 1 -maxdepth 1 -print0)
  remove_vcs_metadata

  case "${ADAPTER_SCRIPT}" in
    "${ADAPTER_ROOT}"/*)
      REL_PATH="${ADAPTER_SCRIPT#"${ADAPTER_ROOT}"/}"
      EXEC_SCRIPT="${TMP_WORKSPACE}/${REL_PATH}"
      ;;
  esac
fi

mkdir -p "${TMP_WORKSPACE}/config"
map_lab_path "${LAB_CONFIG}/inventories" "${TMP_WORKSPACE}/inventories"
map_lab_path "${LAB_CONFIG}/desired-state" "${TMP_WORKSPACE}/desired-state"
map_lab_path "${LAB_CONFIG}/inventories" "${TMP_WORKSPACE}/config/inventories"
map_lab_path "${LAB_CONFIG}/desired-state" "${TMP_WORKSPACE}/config/desired-state"
if [ -f "${LAB_CONFIG}/topology.yaml" ]; then
  map_lab_path "${LAB_CONFIG}/topology.yaml" "${TMP_WORKSPACE}/config/topology.yaml"
fi
if [ -f "${LAB_CONFIG}/ssh-config" ]; then
  map_lab_path "${LAB_CONFIG}/ssh-config" "${TMP_WORKSPACE}/config/ssh-config"
fi
if [ -f "${SSH_CONFIG_RESOLVED}" ]; then
  map_lab_path "${SSH_CONFIG_RESOLVED}" "${TMP_WORKSPACE}/config/ssh-config.resolved"
fi

cat > "${SSH_WRAPPER_DIR}/ssh" <<WRAPPER
#!/usr/bin/env bash
if [ -n "\${SSH_CONFIG_PATH:-}" ] && [ -f "\${SSH_CONFIG_PATH}" ]; then
  exec "${SYSTEM_SSH}" -F "\${SSH_CONFIG_PATH}" "\$@"
fi
exec "${SYSTEM_SSH}" "\$@"
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
export HOME="${TMP_HOME}"
export SOURCE_WORKSPACE_ROOT="${ADAPTER_ROOT:-}"
export SSH_CONFIG_PATH="${SSH_CONFIG}"
export SSH_KEY="${SSH_KEY}"
export GIT_SSH_COMMAND="ssh -F ${SSH_CONFIG}"
export PATH="${SSH_WRAPPER_DIR}:${PATH}"

cd "${TMP_WORKSPACE}"
"${EXEC_SCRIPT}" "${ADAPTER_ARGS[@]}"
