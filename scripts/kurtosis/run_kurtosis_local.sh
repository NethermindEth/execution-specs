#!/bin/bash
set -euo pipefail

ENCLAVE_NAME="local-eth-dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
LAB_DIR="${REPO_ROOT}/.lab"
ETH_PACKAGE_DIR="${LAB_DIR}/ethereum-package"
ETH_PACKAGE_REPO="https://github.com/dmitriy-b/ethereum-package.git"
ETH_PACKAGE_BRANCH="feat/sync-upstream"
DEFAULT_ARGS_FILE="${SCRIPT_DIR}/network.yaml"

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  start [--args-file PATH]   Ensure ${ETH_PACKAGE_DIR} is up to date and run the Kurtosis enclave.
                             Defaults --args-file to ${DEFAULT_ARGS_FILE}.
  stop                       Remove the Kurtosis enclave.
  update                     Clone or fast-forward ${ETH_PACKAGE_DIR} to ${ETH_PACKAGE_BRANCH}.
EOF
    exit 1
}

if [ "$#" -lt 1 ]; then
    usage
fi

COMMAND=$1
shift

if ! command -v kurtosis &> /dev/null; then
    echo "Kurtosis CLI could not be found. Please install it first."
    echo "Follow instructions at https://docs.kurtosis.com/install"
    exit 1
fi

if ! command -v git &> /dev/null; then
    echo "git could not be found. Please install it first."
    exit 1
fi

ensure_eth_package() {
    mkdir -p "${LAB_DIR}"

    if [ -d "${ETH_PACKAGE_DIR}/.git" ]; then
        echo ">>> Updating existing ethereum-package clone at ${ETH_PACKAGE_DIR}"
        git -C "${ETH_PACKAGE_DIR}" fetch origin "${ETH_PACKAGE_BRANCH}"
        git -C "${ETH_PACKAGE_DIR}" checkout "${ETH_PACKAGE_BRANCH}"
        git -C "${ETH_PACKAGE_DIR}" pull --ff-only origin "${ETH_PACKAGE_BRANCH}"
    elif [ -e "${ETH_PACKAGE_DIR}" ]; then
        echo ">>> Error: ${ETH_PACKAGE_DIR} exists but is not a git clone."
        echo ">>> Remove it manually and re-run this command."
        exit 1
    else
        echo ">>> Cloning ${ETH_PACKAGE_REPO} (${ETH_PACKAGE_BRANCH}) into ${ETH_PACKAGE_DIR}"
        git clone --branch "${ETH_PACKAGE_BRANCH}" "${ETH_PACKAGE_REPO}" "${ETH_PACKAGE_DIR}"
    fi
}

start_enclave() {
    local args_file="${DEFAULT_ARGS_FILE}"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --args-file)
                [ "$#" -ge 2 ] || { echo "Error: --args-file requires a path"; exit 1; }
                args_file="$2"
                shift 2
                ;;
            --args-file=*)
                args_file="${1#*=}"
                shift
                ;;
            *)
                echo "Error: unknown argument '$1'"
                usage
                ;;
        esac
    done

    if [ ! -f "${args_file}" ]; then
        echo "Error: args file not found: ${args_file}"
        exit 1
    fi

    ensure_eth_package

    echo ">>> Starting Kurtosis enclave: ${ENCLAVE_NAME}"
    echo ">>> Using args file: ${args_file}"
    echo ">>> Attempting to remove existing enclave (if any)..."
    kurtosis enclave rm "${ENCLAVE_NAME}" -f 2>/dev/null || echo ">>> No existing enclave to remove."

    echo ">>> Running Kurtosis package..."
    kurtosis run "${ETH_PACKAGE_DIR}" \
        --args-file "${args_file}" \
        --enclave "${ENCLAVE_NAME}"
    echo ">>> Kurtosis package started in enclave: ${ENCLAVE_NAME}"
}

stop_enclave() {
    echo ">>> Stopping Kurtosis enclave: ${ENCLAVE_NAME}"
    kurtosis enclave rm "${ENCLAVE_NAME}" -f
    echo ">>> Kurtosis enclave ${ENCLAVE_NAME} stopped."
}

case "$COMMAND" in
    start)
        start_enclave "$@"
        ;;
    stop)
        stop_enclave
        ;;
    update)
        ensure_eth_package
        ;;
    *)
        usage
        ;;
esac

exit 0
