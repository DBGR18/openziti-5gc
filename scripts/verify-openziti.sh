#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$PROJECT_DIR/logs"
ACTIVE=0
PING_TARGET="8.8.8.8"
PING_COUNT=3
CAPTURE_SECONDS=8
FAILURES=0
WARNINGS=0

usage() {
    cat <<'EOF'
Usage: sudo bash scripts/verify-openziti.sh [options]

Options:
  --active              Run active ping and tcpdump validation.
  --ping-target ADDR    Ping target for active validation. Default: 8.8.8.8
  --ping-count N        Number of ICMP probes. Default: 3
  --capture-seconds N   Tcpdump window for active validation. Default: 8
  -h, --help            Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --active)
            ACTIVE=1
            shift
            ;;
        --ping-target)
            PING_TARGET="$2"
            shift 2
            ;;
        --ping-count)
            PING_COUNT="$2"
            shift 2
            ;;
        --capture-seconds)
            CAPTURE_SECONDS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

info() {
    echo "[INFO] $*"
}

pass() {
    echo "[PASS] $*"
}

warn() {
    echo "[WARN] $*"
    WARNINGS=$((WARNINGS + 1))
}

fail() {
    echo "[FAIL] $*"
    FAILURES=$((FAILURES + 1))
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo "[ERROR] This script must run as root." >&2
        exit 1
    fi
}

require_cmd() {
    local command="$1"
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "[ERROR] Required command not found: $command" >&2
        exit 1
    fi
}

wait_for_ue_readiness() {
    local attempts=45

    if ! ip netns exec gnb-ns pgrep -af "nr-ue" >/dev/null 2>&1; then
        return
    fi

    info "Waiting for UE data-plane readiness"
    while (( attempts > 0 )); do
        if ip netns exec gnb-ns ip link show uesimtun0 >/dev/null 2>&1 \
            && [[ -f "$LOG_DIR/ue.log" ]] \
            && grep -Fq "PDU Session establishment is successful" "$LOG_DIR/ue.log"; then
            pass "UE data-plane is ready for verification"
            return
        fi

        sleep 1
        attempts=$((attempts - 1))
    done

    warn "UE data-plane did not become ready before verification timeout"
}

ns_exists() {
    ip netns list | awk '{print $1}' | grep -qx "$1"
}

check_ns() {
    local ns="$1"
    if ns_exists "$ns"; then
        pass "namespace $ns exists"
    else
        fail "namespace $ns is missing"
    fi
}

check_iface() {
    local ns="$1"
    local iface="$2"
    local expect_ip="${3:-}"

    if ip netns exec "$ns" ip link show "$iface" >/dev/null 2>&1; then
        pass "$ns has interface $iface"
    else
        fail "$ns is missing interface $iface"
        return
    fi

    if [[ -n "$expect_ip" ]]; then
        if ip netns exec "$ns" ip -o -4 addr show dev "$iface" | grep -Fq "$expect_ip"; then
            pass "$ns/$iface carries $expect_ip"
        else
            fail "$ns/$iface does not carry $expect_ip"
        fi
    fi
}

check_route() {
    local ns="$1"
    local needle="$2"
    local description="$3"

    if ip netns exec "$ns" ip route show | grep -Fq "$needle"; then
        pass "$description"
    else
        fail "$description"
    fi
}

check_host_route() {
    local needle="$1"
    local description="$2"

    if ip route show | grep -Fq "$needle"; then
        pass "$description"
    else
        fail "$description"
    fi
}

check_process() {
    local ns="$1"
    local pattern="$2"
    local description="$3"

    if ip netns exec "$ns" pgrep -af "$pattern" >/dev/null 2>&1; then
        pass "$description"
    else
        fail "$description"
    fi
}

check_log_contains() {
    local file="$1"
    local needle="$2"
    local description="$3"

    if [[ -f "$file" ]] && grep -Fq "$needle" "$file"; then
        pass "$description"
    else
        fail "$description"
    fi
}

check_service_definition() {
    local needle="$1"
    local description="$2"

    if grep -Fq -- "$needle" "$PROJECT_DIR/policies/services.yml"; then
        pass "$description"
    else
        fail "$description"
    fi
}

capture_packets() {
    local ns="$1"
    local iface="$2"
    local filter="$3"
    local outfile="$4"

    timeout "$CAPTURE_SECONDS" ip netns exec "$ns" tcpdump -i "$iface" -n $filter >"$outfile" 2>&1 &
    CAPTURE_PID=$!
}

extract_capture_count() {
    local file="$1"
    local count

    count=$(grep -Eo '^[0-9]+ packets captured' "$file" | awk '{print $1}' | tail -n1 || true)
    if [[ -z "$count" ]]; then
        echo 0
    else
        echo "$count"
    fi
}

run_passive_checks() {
    info "Checking namespace topology and addressing"
    check_ns gnb-ns
    check_ns router-ns
    check_ns core-ns

    check_iface gnb-ns lo 127.0.0.1/8
    check_iface gnb-ns ziti0 100.64.0.0/32
    check_iface gnb-ns uesimtun0 10.60.
    check_iface gnb-ns veth-gnb 10.10.1.2/24

    check_iface router-ns lo 127.0.0.1/8
    check_iface router-ns veth-gnb-r 10.10.1.1/24
    check_iface router-ns veth-core-r 10.10.2.1/24
    check_iface router-ns veth-host-r 10.10.3.1/24

    check_iface core-ns lo 127.0.0.1/8
    check_iface core-ns upfgtp
    check_iface core-ns veth-core 10.10.2.2/24
    check_iface core-ns veth-core-host 10.10.4.1/24

    info "Checking routing and isolation assumptions"
    check_route gnb-ns "default via 10.10.1.1" "gnb-ns default route points to router-ns"
    check_route gnb-ns "10.10.2.0/24 via 10.10.1.1" "gnb-ns can hand N3 traffic to router-ns for interception"
    check_route gnb-ns "10.10.3.1 via 10.10.1.1 dev veth-gnb" "gnb-ns pins controller/router management IP to veth-gnb"
    check_route router-ns "default via 10.10.3.2" "router-ns default route points to host"
    check_route core-ns "default via 10.10.4.2 dev veth-core-host" "core-ns default route points to host over the dedicated N6 link"
    check_host_route "10.10.1.0/24 via 10.10.3.1" "host route to gnb-ns exists"
    check_host_route "10.10.2.0/24 via 10.10.3.1" "host route to core-ns exists"
    check_host_route "10.60.0.0/16 via 10.10.4.1 dev veth-host-core" "host route to UE address pool points directly to core-ns"

    if ip netns exec router-ns iptables -C FORWARD -s 10.10.1.0/24 -d 10.10.2.0/24 -j DROP >/dev/null 2>&1; then
        pass "router-ns drops other direct gnb-ns to core-ns traffic"
    else
        fail "router-ns is missing direct gnb-ns to core-ns DROP rule"
    fi

    if iptables -t nat -C POSTROUTING -s 10.10.4.0/24 ! -d 10.10.0.0/16 -j MASQUERADE >/dev/null 2>&1; then
        pass "host NAT for core N6 subnet is present"
    else
        fail "host NAT for core N6 subnet is missing"
    fi

    if iptables -t nat -C POSTROUTING -s 10.60.0.0/16 ! -d 10.10.0.0/16 -j MASQUERADE >/dev/null 2>&1; then
        pass "host NAT for UE pool is present"
    else
        fail "host NAT for UE pool is missing"
    fi

    info "Checking OpenZiti processes and service bindings"
    check_process router-ns "ziti controller run" "controller is running in router-ns"
    check_process router-ns "ziti router run" "edge router is running in router-ns"
    check_process gnb-ns "ziti-edge-tunnel run --identity" "gNB tunneler is running in intercept mode"
    check_process core-ns "ziti-edge-tunnel run-host" "core tunneler is running in host mode"
    check_process core-ns "core-upf-dialer.json" "core downlink dialer is running in intercept mode"
    check_process gnb-ns "n2-sctp-gateway --mode gnb" "gNB-side N2 gateway is listening for local NGAP SCTP"
    check_process core-ns "n2-sctp-gateway --mode core" "core-side N2 gateway is bridging UDP frames to AMF SCTP"
    check_process gnb-ns "nr-gnb" "UERANSIM gNB is running"
    check_process gnb-ns "nr-ue" "UERANSIM UE is running"
    check_process core-ns "/bin/amf" "free5gc AMF is running"
    check_process core-ns "/bin/upf" "free5gc UPF is running"

    info "Checking service definitions and protocol translation expectations"
    check_service_definition "- name: n2-ngap-service" "N2 OpenZiti service definition exists"
    check_service_definition "- name: n3-gtpu-service" "N3 OpenZiti service definition exists"
    check_service_definition "addresses:" "services.yml contains intercept blocks"
    check_service_definition "- amf.ziti" "N2 intercept address amf.ziti is configured"
    check_service_definition "- \"10.10.2.2\"" "N3 intercept address points at core-ns UPF address"
    check_service_definition "protocol: udp" "N2 host side is delivered over UDP to the core-side gateway"
    check_service_definition "address: 127.0.0.1" "N2 host side is delivered to the local core-side gateway"
    check_service_definition "address: 10.10.2.2" "N3 host side is delivered to core-ns UPF address"

    info "Checking logs for successful control-plane and session setup"
    check_log_contains "$LOG_DIR/gnb.log" "NG Setup procedure is successful" "gNB completed NG Setup over N2"
    check_log_contains "$LOG_DIR/ue.log" "PDU Session establishment is successful" "UE completed PDU session setup"
}

run_isolation_check() {
    local drop_before drop_after route_get_output

    info "Checking direct gnb-ns to core-ns isolation"

    route_get_output=$(ip netns exec gnb-ns ip route get 10.10.2.2 2>/dev/null || true)
    if grep -Fq "dev ziti0" <<<"$route_get_output"; then
        pass "traffic to 10.10.2.2 is captured by ziti0 instead of clear routing"
    else
        fail "traffic to 10.10.2.2 is not being steered into ziti0"
    fi

    drop_before=$(ip netns exec router-ns iptables -L FORWARD -n -v | awk '/10\.10\.1\.0\/24[[:space:]]+10\.10\.2\.0\/24/ && /DROP/ {print $1; exit}')
    drop_before=${drop_before:-0}

    ip netns exec gnb-ns ping -c 1 -W 2 10.10.2.254 >/dev/null 2>&1 || true

    drop_after=$(ip netns exec router-ns iptables -L FORWARD -n -v | awk '/10\.10\.1\.0\/24[[:space:]]+10\.10\.2\.0\/24/ && /DROP/ {print $1; exit}')
    drop_after=${drop_after:-0}

    if (( drop_after > drop_before )); then
        pass "non-overlay traffic to core subnet hits router-ns DROP rule"
    else
        warn "router-ns DROP counter did not move during the non-overlay probe"
    fi
}

run_active_checks() {
    local ping_log capture_tls capture_n3_any capture_n3_veth capture_n3_core
    local tls_pid any_pid veth_pid core_pid
    local tls_count any_count veth_count core_count

    info "Running active overlay validation with ping to $PING_TARGET"
    ping_log=$(mktemp)
    capture_tls=$(mktemp)
    capture_n3_any=$(mktemp)
    capture_n3_veth=$(mktemp)
    capture_n3_core=$(mktemp)

    capture_packets gnb-ns veth-gnb "port 3022" "$capture_tls"
    tls_pid=$CAPTURE_PID
    capture_packets gnb-ns any "udp and port 2152" "$capture_n3_any"
    any_pid=$CAPTURE_PID
    capture_packets gnb-ns veth-gnb "udp and port 2152" "$capture_n3_veth"
    veth_pid=$CAPTURE_PID
    capture_packets core-ns any "udp and port 2152" "$capture_n3_core"
    core_pid=$CAPTURE_PID

    sleep 1

    if ip netns exec gnb-ns ping -I uesimtun0 -c "$PING_COUNT" "$PING_TARGET" >"$ping_log" 2>&1; then
        pass "UE data-plane ping via uesimtun0 reached $PING_TARGET"
    else
        fail "UE data-plane ping via uesimtun0 failed; see $ping_log"
    fi

    wait "$tls_pid" || true
    wait "$any_pid" || true
    wait "$veth_pid" || true
    wait "$core_pid" || true

    tls_count=$(extract_capture_count "$capture_tls")
    any_count=$(extract_capture_count "$capture_n3_any")
    veth_count=$(extract_capture_count "$capture_n3_veth")
    core_count=$(extract_capture_count "$capture_n3_core")

    if (( tls_count > 0 )); then
        pass "gnb-ns/veth-gnb saw encrypted Ziti traffic on port 3022 ($tls_count packets)"
    else
        fail "gnb-ns/veth-gnb did not see encrypted Ziti traffic on port 3022 during ping"
    fi

    if (( any_count > 0 )); then
        pass "gnb-ns/any saw N3 UDP/2152 before interception ($any_count packets)"
    else
        warn "gnb-ns/any did not capture UDP/2152 during ping"
    fi

    if (( veth_count == 0 )); then
        pass "gnb-ns/veth-gnb leaked no clear UDP/2152 packets"
    else
        fail "gnb-ns/veth-gnb saw clear UDP/2152 traffic ($veth_count packets); current downlink N3 path bypasses the documented Ziti-only transport"
    fi

    if (( core_count > 0 )); then
        pass "core-ns/any saw UDP/2152 after Ziti decapsulation ($core_count packets)"
    else
        warn "core-ns/any did not capture UDP/2152 during ping"
    fi

    rm -f "$ping_log" "$capture_tls" "$capture_n3_any" "$capture_n3_veth" "$capture_n3_core"
}

print_summary() {
    echo
    echo "=== Verification Summary ==="
    echo "Failures : $FAILURES"
    echo "Warnings : $WARNINGS"
    echo "Mode     : $([[ $ACTIVE -eq 1 ]] && echo active || echo passive)"

    if (( FAILURES > 0 )); then
        exit 1
    fi
}

main() {
    require_root
    require_cmd ip
    require_cmd iptables
    require_cmd pgrep
    require_cmd grep
    require_cmd timeout

    if (( ACTIVE == 1 )); then
        require_cmd tcpdump
        require_cmd ping
    fi

    wait_for_ue_readiness

    run_passive_checks
    run_isolation_check

    if (( ACTIVE == 1 )); then
        run_active_checks
    fi

    print_summary
}

main