#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${LIBREMESH_LAB_REPO_URL:-https://github.com/coolabnet/libremesh-lab.git}"
INSTALL_DIR="${LIBREMESH_LAB_INSTALL_DIR:-${HOME}/.local/share/libremesh-lab}"
BIN_DIR="${LIBREMESH_LAB_BIN_DIR:-${HOME}/.local/bin}"
REF="${LIBREMESH_LAB_REF:-main}"

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: '${command_name}' is required to install LibreMesh Lab." >&2
    exit 1
  fi
}

checkout_ref() {
  local ref="$1"

  git -C "${INSTALL_DIR}" fetch --tags origin '+refs/heads/*:refs/remotes/origin/*'

  if git -C "${INSTALL_DIR}" rev-parse --verify --quiet "origin/${ref}^{commit}" >/dev/null; then
    git -C "${INSTALL_DIR}" checkout -B "${ref}" "origin/${ref}"
  else
    git -C "${INSTALL_DIR}" checkout --detach "${ref}"
  fi
}

require_command bash
require_command curl
require_command git

mkdir -p "${BIN_DIR}"

if [ -e "${INSTALL_DIR}" ] && [ ! -d "${INSTALL_DIR}/.git" ]; then
  echo "ERROR: install path exists but is not a git checkout: ${INSTALL_DIR}" >&2
  exit 1
fi

if [ ! -d "${INSTALL_DIR}/.git" ]; then
  mkdir -p "$(dirname "${INSTALL_DIR}")"
  git clone "${REPO_URL}" "${INSTALL_DIR}"
else
  git -C "${INSTALL_DIR}" remote set-url origin "${REPO_URL}"
fi

checkout_ref "${REF}"

if [ ! -x "${INSTALL_DIR}/bin/libremesh-lab" ]; then
  echo "ERROR: installed checkout does not contain executable bin/libremesh-lab." >&2
  exit 1
fi

ln -sfn "${INSTALL_DIR}/bin/libremesh-lab" "${BIN_DIR}/libremesh-lab"

echo "LibreMesh Lab installed:"
echo "  checkout: ${INSTALL_DIR}"
echo "  command:  ${BIN_DIR}/libremesh-lab"

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *)
    echo ""
    echo "Add ${BIN_DIR} to PATH to run 'libremesh-lab' from any directory."
    ;;
esac
