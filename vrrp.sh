#!/usr/bin/env bash
set -euo pipefail

CONF_JSON="/etc/vrrp/conf.d/conf.json"
KEEPALIVED_CONF="/etc/keepalived/keepalived.conf"

# You can override this via environment variable if 8.8.8.8 is blocked
WAN_TEST_IP="${WAN_TEST_IP:-8.8.8.8}"

# Return codes:
# 0 = success
# 1 = generic error / invalid usage
# 2 = config / JSON error
# 3 = local node not found in config
# 4 = dependency missing (e.g. jq)
# 5 = keepalived error
# 6 = connectivity check failed (remote or WAN)

log() {
    echo "[vrrp.sh] $*" >&2
}

usage() {
    cat <<EOF
Usage: $0 {create|delete|status}

  create  - Parse JSON and set up VxLAN + VRRP (keepalived) on this node
  delete  - Tear down VxLAN + VRRP created by this config
  status  - Show VxLAN + VRRP status

Config JSON: $CONF_JSON
EOF
}

check_deps() {
    if ! command -v jq >/dev/null 2>&1; then
        log "Error: 'jq' is required but not installed."
        exit 4
    fi
    if ! command -v ip >/dev/null 2>&1; then
        log "Error: 'ip' command not found."
        exit 4
    fi
}

ensure_config_exists() {
    if [[ ! -f "$CONF_JSON" ]]; then
        log "Error: config JSON not found at $CONF_JSON"
        exit 2
    fi
}

get_local_wan_ip() {
    # Best-effort: pick any non-loopback, non-link-local IPv4 to match with Nodes[].WAN_IP
    ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1
}

find_iface_by_ip() {
    local ipaddr="$1"
    ip -4 -o addr show | awk -v ip="$ipaddr" '$4 ~ ip"/" {print $2; exit}'
}

extract_common_values() {
    GROUP_ID=$(jq -r '.vrrp.GroupID' "$CONF_JSON")
    VIP=$(jq -r '.vrrp.VIP' "$CONF_JSON")
    AUTH_PASS=$(jq -r '.vrrp.Auth_Pass' "$CONF_JSON")
    VRID=$(jq -r '.vrrp.VRID' "$CONF_JSON")
    PREEMPT=$(jq -r '.vrrp.PREEMPT' "$CONF_JSON")
    ADVERT_INT=$(jq -r '.vrrp.ADVERT_INT' "$CONF_JSON")

    # Basic validation
    if [[ -z "$GROUP_ID" || -z "$VIP" || -z "$VRID" ]]; then
        log "Error: missing GROUP_ID, VIP, or VRID in JSON"
        exit 2
    fi
}

find_local_node_index() {
    local local_ip="$1"
    NODE_INDEX=$(jq -r --arg ip "$local_ip" '.vrrp.Nodes | to_entries[] | select(.value.WAN_IP == $ip) | .key' "$CONF_JSON" || true)

    if [[ -z "$NODE_INDEX" ]]; then
        log "Error: local WAN IP $local_ip not found in vrrp.Nodes[].WAN_IP"
        exit 3
    fi
}

extract_node_values() {
    # Uses global NODE_INDEX
    NODE_SITE_ID=$(jq -r ".vrrp.Nodes[$NODE_INDEX].siteID" "$CONF_JSON")
    NODE_WAN_IP=$(jq -r ".vrrp.Nodes[$NODE_INDEX].WAN_IP" "$CONF_JSON")
    NODE_REMOTE_IP=$(jq -r ".vrrp.Nodes[$NODE_INDEX].Remote_IP" "$CONF_JSON")
    NODE_TUNNEL_IP=$(jq -r ".vrrp.Nodes[$NODE_INDEX].Tunnel_IP" "$CONF_JSON")
    NODE_VNI=$(jq -r ".vrrp.Nodes[$NODE_INDEX].VNI" "$CONF_JSON")
    NODE_PORT=$(jq -r ".vrrp.Nodes[$NODE_INDEX].PORT" "$CONF_JSON")
    NODE_IFACE=$(jq -r ".vrrp.Nodes[$NODE_INDEX].Interface" "$CONF_JSON")
    NODE_PRIORITY=$(jq -r ".vrrp.Nodes[$NODE_INDEX].Priority" "$CONF_JSON")

    # NOTE: we assume /24 for VIP/Tunnel subnet; adjust if needed
    VIP_CIDR="$VIP/24"
    TUNNEL_CIDR="$NODE_TUNNEL_IP/24"

    VX_IFACE="vxlan${NODE_VNI}"
}

create_vxlan_and_bridge() {
    log "Configuring VxLAN interface $VX_IFACE for local node (WAN_IP=$NODE_WAN_IP, remote=$NODE_REMOTE_IP)"

    local wan_dev
    wan_dev=$(find_iface_by_ip "$NODE_WAN_IP")
    if [[ -z "$wan_dev" ]]; then
        log "Error: unable to find interface for local WAN IP $NODE_WAN_IP"
        exit 2
    fi

    # Create vxlan if it doesn't exist
    if ! ip link show "$VX_IFACE" >/dev/null 2>&1; then
        ip link add "$VX_IFACE" type vxlan id "$NODE_VNI" \
            dev "$wan_dev" \
            local "$NODE_WAN_IP" remote "$NODE_REMOTE_IP" \
            dstport "$NODE_PORT" \
            udp6zerocsumrx off udp6zerocsumtx off
    else
        log "VxLAN interface $VX_IFACE already exists, skipping creation"
    fi

    # Bring it up only if not already UP
    if ip link show "$VX_IFACE" | grep -q "state UP"; then
        log "VxLAN interface $VX_IFACE already UP"
    else
        ip link set "$VX_IFACE" up
        log "Set VxLAN interface $VX_IFACE UP"
    fi

    # Attach to bridge (NODE_IFACE is expected to be a bridge name like br_lan)
    if ! ip link show "$NODE_IFACE" >/dev/null 2>&1; then
        log "Error: bridge/interface $NODE_IFACE does not exist"
        exit 2
    fi

    # Attach vxlan to bridge if not already
    if ! bridge link show dev "$VX_IFACE" >/dev/null 2>&1; then
        ip link set "$VX_IFACE" master "$NODE_IFACE"
        log "Attached $VX_IFACE to bridge $NODE_IFACE"
    else
        log "VxLAN interface $VX_IFACE already attached to $NODE_IFACE"
    fi

    # Add Tunnel_IP as secondary on bridge
    if ! ip -4 addr show dev "$NODE_IFACE" | grep -q "$NODE_TUNNEL_IP/"; then
        ip addr add "$TUNNEL_CIDR" dev "$NODE_IFACE"
        log "Added tunnel IP $TUNNEL_CIDR to $NODE_IFACE"
    else
        log "Tunnel IP $TUNNEL_CIDR already present on $NODE_IFACE"
    fi
}

generate_keepalived_conf() {
    log "Generating keepalived config at $KEEPALIVED_CONF"

    cat >"$KEEPALIVED_CONF" <<EOF
vrrp_instance VI_${GROUP_ID} {
    state BACKUP
    interface ${NODE_IFACE}
    virtual_router_id ${VRID}
    priority ${NODE_PRIORITY}
    advert_int ${ADVERT_INT}
    authentication {
        auth_type PASS
        auth_pass ${AUTH_PASS}
    }
    virtual_ipaddress {
        ${VIP_CIDR} dev ${NODE_IFACE}
    }
$( [[ "$PREEMPT" == "true" ]] && echo "    preempt" )
}
EOF
}

restart_keepalived() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log "Warning: systemctl not found; skipping keepalived restart"
        return 0
    fi

    if ! systemctl restart keepalived; then
        log "Error: failed to restart keepalived"
        exit 5
    fi

    log "keepalived restarted successfully"
}

verify_connectivity() {
    local errors=0

    log "Running connectivity checks..."

    # 1) Check reachability to remote WAN_IP (node-to-node)
    if ping -c 3 -W 2 "$NODE_REMOTE_IP" >/dev/null 2>&1; then
        log "OK: remote WAN_IP $NODE_REMOTE_IP reachable"
    else
        log "ERROR: cannot ping remote WAN_IP $NODE_REMOTE_IP"
        errors=1
    fi

    # 2) Check reachability to WAN test IP (Internet)
    if ping -c 3 -W 2 "$WAN_TEST_IP" >/dev/null 2>&1; then
        log "OK: WAN test IP $WAN_TEST_IP reachable"
    else
        log "ERROR: cannot ping WAN test IP $WAN_TEST_IP"
        errors=1
    fi

    if (( errors != 0 )); then
        log "Connectivity checks FAILED"
        exit 6
    fi

    log "Connectivity checks PASSED"
}

delete_vxlan_and_ip() {
    local local_ip
    local_ip=$(get_local_wan_ip)
    if [[ -z "$local_ip" ]]; then
        log "Warning: cannot determine local WAN IP; skipping VxLAN delete"
        return 0
    fi

    extract_common_values
    find_local_node_index "$local_ip"
    extract_node_values

    log "Deleting VxLAN $VX_IFACE and Tunnel IP $TUNNEL_CIDR from ${NODE_IFACE}"

    # Remove IP if present
    if ip -4 addr show dev "$NODE_IFACE" | grep -q "$NODE_TUNNEL_IP/"; then
        ip addr del "$TUNNEL_CIDR" dev "$NODE_IFACE" || true
        log "Removed tunnel IP $TUNNEL_CIDR from $NODE_IFACE"
    fi

    # Delete vxlan interface if present
    if ip link show "$VX_IFACE" >/dev/null 2>&1; then
        ip link set "$VX_IFACE" down || true
        ip link del "$VX_IFACE" || true
        log "Deleted VxLAN interface $VX_IFACE"
    fi
}

cmd_create() {
    check_deps
    ensure_config_exists

    local local_ip
    local_ip=$(get_local_wan_ip)
    if [[ -z "$local_ip" ]]; then
        log "Error: cannot determine local WAN IP"
        exit 2
    fi
    log "Local detected IP: $local_ip"

    extract_common_values
    find_local_node_index "$local_ip"
    extract_node_values

    create_vxlan_and_bridge
    generate_keepalived_conf
    restart_keepalived
    verify_connectivity

    log "Create operation completed successfully"
    exit 0
}

cmd_delete() {
    check_deps

    if [[ ! -f "$CONF_JSON" ]]; then
        log "Config JSON not found; nothing to delete"
        exit 0
    fi

    delete_vxlan_and_ip

    # Simple approach: backup keepalived.conf
    if [[ -f "$KEEPALIVED_CONF" ]]; then
        cp "$KEEPALIVED_CONF" "${KEEPALIVED_CONF}.bak.$(date +%s)" || true
        >"$KEEPALIVED_CONF" || true
        log "Cleared keepalived.conf (backed up previous version)"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart keepalived || log "Warning: failed to restart keepalived after delete"
    fi

    log "Delete operation completed"
    exit 0
}

cmd_status() {
    check_deps

    echo "=== VRRP/VxLAN Status ==="
    if [[ -f "$CONF_JSON" ]]; then
        echo "Config JSON: $CONF_JSON"
        jq '.vrrp' "$CONF_JSON" || true
    else
        echo "Config JSON: not found ($CONF_JSON)"
    fi
    echo

    echo "VxLAN interfaces:"
    ip -d link show type vxlan || true
    echo

    echo "Bridge addresses:"
    ip -4 addr show | grep -E 'br-|br_' || true
    echo

    if command -v systemctl >/dev/null 2>&1; then
        echo "keepalived service:"
        systemctl status keepalived --no-pager || true
    fi

    exit 0
}

main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    case "$1" in
        create)
            cmd_create
            ;;
        delete)
            cmd_delete
            ;;
        status)
            cmd_status
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
