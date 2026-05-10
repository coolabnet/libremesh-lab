#!/usr/bin/env bash
# Shared topology helpers for LibreMesh Lab QEMU scripts.

lab_topology_set_defaults() {
    BRIDGE_NAME="mesha-br0"
    BRIDGE_IP="10.99.0.254"
    BRIDGE_CIDR="10.99.0.254/16"
    TAP_PREFIX="mesha-tap"
    NODE_HOSTNAMES=("lm-testbed-node-1" "lm-testbed-node-2" "lm-testbed-node-3" "lm-testbed-tester")
    NODE_IPS=("10.99.0.11" "10.99.0.12" "10.99.0.13" "10.99.0.14")
    NODE_COUNT=4
}

lab_topology_value() {
    local topology_file="$1"
    local key="$2"

    [ -f "${topology_file}" ] || return 1
    awk -v key="${key}" '
        $0 ~ "^[[:space:]]*" key ":" {
            sub("^[[:space:]]*" key ":[[:space:]]*", "", $0)
            gsub("\"", "", $0)
            print $0
            exit
        }
    ' "${topology_file}"
}

lab_topology_load_nodes() {
    local topology_file="$1"
    local field="$2"

    [ -f "${topology_file}" ] || return 1
    awk -v field="${field}" '
        /^  nodes:/ { in_nodes=1; next }
        in_nodes && /^  [[:alnum:]_]+:/ { exit }
        in_nodes && $0 ~ "^[[:space:]]+" field ":" {
            sub("^[[:space:]]*" field ":[[:space:]]*", "", $0)
            gsub("\"", "", $0)
            print $0
        }
    ' "${topology_file}"
}

lab_topology_load() {
    local topology_file="${1:-}"
    local value
    local -a parsed_hostnames=()
    local -a parsed_ips=()

    lab_topology_set_defaults

    [ -n "${topology_file}" ] && [ -f "${topology_file}" ] || return 0

    value="$(lab_topology_value "${topology_file}" "bridge_name" || true)"
    [ -n "${value}" ] && BRIDGE_NAME="${value}"

    value="$(lab_topology_value "${topology_file}" "bridge_ip" || true)"
    if [ -n "${value}" ]; then
        BRIDGE_IP="${value%%/*}"
        if [[ "${value}" == */* ]]; then
            BRIDGE_CIDR="${value}"
        else
            BRIDGE_CIDR="${value}/16"
        fi
    fi

    value="$(lab_topology_value "${topology_file}" "tap_prefix" || true)"
    [ -n "${value}" ] && TAP_PREFIX="${value}"

    while IFS= read -r value; do
        [ -n "${value}" ] && parsed_hostnames+=("${value}")
    done < <(lab_topology_load_nodes "${topology_file}" "hostname" || true)

    while IFS= read -r value; do
        [ -n "${value}" ] && parsed_ips+=("${value%%/*}")
    done < <(lab_topology_load_nodes "${topology_file}" "ip" || true)

    if [ "${#parsed_hostnames[@]}" -gt 0 ] && [ "${#parsed_hostnames[@]}" -eq "${#parsed_ips[@]}" ]; then
        NODE_HOSTNAMES=("${parsed_hostnames[@]}")
        NODE_IPS=("${parsed_ips[@]}")
        NODE_COUNT="${#NODE_HOSTNAMES[@]}"
    fi
}
