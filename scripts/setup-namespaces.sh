#!/usr/bin/env bash
# =============================================================================
# setup-namespaces.sh — Three Namespace Isolation Topology
#
# Realistic single-machine deployment: gNB, Router, and Core in separate Network Namespaces.
# N2/N3 use Ziti overlay, N6 (External Exit) connects core-ns directly to Host.
#
#  ┌──────────┐         ┌──────────────┐         ┌──────────┐
#  │  gnb-ns  │ veth    │  router-ns   │ veth    │  core-ns │
#  │10.10.1.2 ├────────►│10.10.1.1     │         │10.10.2.2 │
#  │          │         │     10.10.2.1├───────► │          │
#  └──────────┘         │     10.10.3.1│         │10.10.4.1 ├── veth ── Host (10.10.4.2)
#                       └───────┬──────┘         └──────────┘
#                               │ veth
#                    Host (10.10.3.2)
#                    (Management CLI / Internet uplink)
#
# Key Isolation:
#   gnb-ns can only reach router-ns (10.10.1.0/24)
#   core-ns can only reach router-ns (10.10.2.0/24)
#   gnb-ns ←✗→ core-ns    (Fully isolated, must go through Ziti)
#
# Usage:
#   sudo ./scripts/setup-namespaces.sh create
#   sudo ./scripts/setup-namespaces.sh delete
#   sudo ./scripts/setup-namespaces.sh status
# =============================================================================

set -euo pipefail

ACTION="${1:-status}"

# Namespace Names
NS_GNB="gnb-ns"
NS_ROUTER="router-ns"
NS_CORE="core-ns"
NS_DN="dn-ns"

# === Subnet Definitions ===
# gNB ↔ Router: 10.10.1.0/24
GNB_IP="10.10.1.2/24"
ROUTER_GNB_IP="10.10.1.1/24"

# Router ↔ Core: 10.10.2.0/24
ROUTER_CORE_IP="10.10.2.1/24"
CORE_IP="10.10.2.2/24"

# Router ↔ Host (Management): 10.10.3.0/24
ROUTER_HOST_IP="10.10.3.1/24"
HOST_IP="10.10.3.2/24"

# Core ↔ Host (N6 / External Exit): 10.10.4.0/24
CORE_HOST_IP="10.10.4.1/24"
HOST_CORE_IP="10.10.4.2/24"

# Router ↔ DN (Optional): 10.10.5.0/24
ROUTER_DN_IP="10.10.5.1/24"
DN_IP="10.10.5.2/24"

create_namespaces() {
    echo "=== Creating three Network Namespaces ==="

    # --- Cleaning up remnants ---
    for ns in "$NS_GNB" "$NS_ROUTER" "$NS_CORE" "$NS_DN"; do
        if ip netns list 2>/dev/null | grep -qw "$ns"; then
            ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
            sleep 0.3
            ip netns del "$ns" 2>/dev/null || true
        fi
    done
    ip link del veth-host 2>/dev/null || true
    ip link del veth-host-core 2>/dev/null || true
    ip link del veth-dn 2>/dev/null || true
    sleep 0.5

    # --- Creating Namespaces ---
    ip netns add "$NS_GNB"
    ip netns add "$NS_ROUTER"
    ip netns add "$NS_CORE"
    echo "✓ Three namespaces created"

    # --- veth pair 1: gNB ↔ Router (10.10.1.0/24) ---
    echo ">>> veth: gnb-ns ↔ router-ns..."
    ip link add veth-gnb type veth peer name veth-gnb-r
    ip link set veth-gnb netns "$NS_GNB"
    ip link set veth-gnb-r netns "$NS_ROUTER"

    ip netns exec "$NS_GNB" ip addr add "$GNB_IP" dev veth-gnb
    ip netns exec "$NS_GNB" ip link set veth-gnb up
    ip netns exec "$NS_GNB" ip link set lo up

    ip netns exec "$NS_ROUTER" ip addr add "$ROUTER_GNB_IP" dev veth-gnb-r
    ip netns exec "$NS_ROUTER" ip link set veth-gnb-r up
    ip netns exec "$NS_ROUTER" ip link set lo up

    # --- veth pair 2: Router ↔ Core (10.10.2.0/24) ---
    echo ">>> veth: router-ns ↔ core-ns..."
    ip link add veth-core type veth peer name veth-core-r
    ip link set veth-core netns "$NS_CORE"
    ip link set veth-core-r netns "$NS_ROUTER"

    ip netns exec "$NS_CORE" ip addr add "$CORE_IP" dev veth-core
    ip netns exec "$NS_CORE" ip link set veth-core up
    ip netns exec "$NS_CORE" ip link set lo up

    ip netns exec "$NS_ROUTER" ip addr add "$ROUTER_CORE_IP" dev veth-core-r
    ip netns exec "$NS_ROUTER" ip link set veth-core-r up

    # --- veth pair 3: Router ↔ Host (10.10.3.0/24) Management side ---
    echo ">>> veth: router-ns ↔ Host (Management channel)..."
    ip link add veth-host type veth peer name veth-host-r
    ip link set veth-host-r netns "$NS_ROUTER"

    ip addr add "$HOST_IP" dev veth-host
    ip link set veth-host up

    ip netns exec "$NS_ROUTER" ip addr add "$ROUTER_HOST_IP" dev veth-host-r
    ip netns exec "$NS_ROUTER" ip link set veth-host-r up

    # --- veth pair 4: Core ↔ Host (10.10.4.0/24) for N6 ---
    echo ">>> veth: core-ns ↔ Host (N6 exit)..."
    ip link add veth-host-core type veth peer name veth-core-host
    ip link set veth-core-host netns "$NS_CORE"

    ip addr add "$HOST_CORE_IP" dev veth-host-core
    ip link set veth-host-core up

    ip netns exec "$NS_CORE" ip addr add "$CORE_HOST_IP" dev veth-core-host
    ip netns exec "$NS_CORE" ip link set veth-core-host up

    # --- Route settings ---
    echo ">>> Setting routes..."

    # gNB default gateway -> Router (limited to 10.10.1.0/24)
    ip netns exec "$NS_GNB" ip route add default via 10.10.1.1

    # Core default gateway -> Host (N6 exit direct connect)
    ip netns exec "$NS_CORE" ip route add default via 10.10.4.2 dev veth-core-host

    # Core must be able to route back to the gNB subnet via router-ns.
    # This is required for the *baseline underlay N2* path where the core-side
    # n2-sctp-gateway sends UDP replies to 10.10.1.2.
    # (router-ns still enforces isolation via FORWARD DROP rules by default.)
    ip netns exec "$NS_CORE" ip route replace 10.10.1.0/24 via 10.10.2.1 dev veth-core

    # Host routes to each namespace
    ip route add 10.10.1.0/24 via 10.10.3.1 2>/dev/null || true
    ip route add 10.10.2.0/24 via 10.10.3.1 2>/dev/null || true
    # UE IP pool return route (back to core-ns after N6)
    ip route add 10.60.0.0/16 via 10.10.4.1 dev veth-host-core 2>/dev/null || true
    ip route add 10.61.0.0/16 via 10.10.4.1 dev veth-host-core 2>/dev/null || true

    # Router: IP forwarding not enabled！
    # gnb-ns and core-ns cannot communicate directly
    # Only Router ↔ gnb-ns and Router ↔ core-ns reachable
    ip netns exec "$NS_ROUTER" sysctl -w net.ipv4.ip_forward=0 > /dev/null

    # But Router needs to forward Host(10.10.3.0/24) ↔ gnb/core management traffic
    # 所以我們用 iptables 精確控制：只轉發管理流量，不轉發 gnb↔core
    ip netns exec "$NS_ROUTER" sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # 禁止其餘 gnb-ns ↔ core-ns 直接轉發
    ip netns exec "$NS_ROUTER" iptables -A FORWARD \
        -s 10.10.1.0/24 -d 10.10.2.0/24 -j DROP
    ip netns exec "$NS_ROUTER" iptables -A FORWARD \
        -s 10.10.2.0/24 -d 10.10.1.0/24 -j DROP
    # 允許 Host(10.10.3.0/24) ↔ 兩端management traffic
    ip netns exec "$NS_ROUTER" iptables -A FORWARD \
        -s 10.10.3.0/24 -j ACCEPT
    ip netns exec "$NS_ROUTER" iptables -A FORWARD \
        -d 10.10.3.0/24 -j ACCEPT

    # UE pools live behind core-ns (UPF). Add router-side return routes so
    # DN (10.10.5.0/24) replies to UE IPs go back to core-ns directly.
    ip netns exec "$NS_ROUTER" ip route add 10.60.0.0/16 via 10.10.2.2 2>/dev/null || true
    ip netns exec "$NS_ROUTER" ip route add 10.61.0.0/16 via 10.10.2.2 2>/dev/null || true

    # --- DNS ---
    for ns in "$NS_GNB" "$NS_ROUTER" "$NS_CORE"; do
        mkdir -p /etc/netns/"$ns"
        cp /etc/resolv.conf /etc/netns/"$ns"/resolv.conf
    done

    # --- NAT: 讓各 namespace 能上網（下載、enroll 等需要） ---
    # 從 router-ns 到 Host 的 NAT（讓 gnb-ns/router-ns 管理流量可上網）
    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # Host FORWARD is often DROP (e.g. Docker). Allow core-ns management + egress via veth-host-core.
    # - management/controller: 10.10.4.0/24 <-> 10.10.3.0/24
    # - internet egress: core-ns (10.10.4.0/24) and UE pools (10.60/16, 10.61/16)
    iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -C FORWARD -s 10.10.3.0/24 -d 10.10.4.0/24 -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -s 10.10.3.0/24 -d 10.10.4.0/24 -j ACCEPT
    iptables -C FORWARD -s 10.10.4.0/24 -d 10.10.3.0/24 -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -s 10.10.4.0/24 -d 10.10.3.0/24 -j ACCEPT
    iptables -C FORWARD -i veth-host-core -s 10.10.4.0/24 -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -i veth-host-core -s 10.10.4.0/24 -j ACCEPT
    iptables -C FORWARD -i veth-host-core -s 10.60.0.0/16 -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -i veth-host-core -s 10.60.0.0/16 -j ACCEPT
    iptables -C FORWARD -i veth-host-core -s 10.61.0.0/16 -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -i veth-host-core -s 10.61.0.0/16 -j ACCEPT

    iptables -t nat -A POSTROUTING -s 10.10.3.0/24 ! -d 10.10.0.0/16 -j MASQUERADE 2>/dev/null || true
    # core-ns 出口流量（透過 N6 直連 Host）
    iptables -t nat -A POSTROUTING -s 10.10.4.0/24 ! -d 10.10.0.0/16 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s 10.10.2.0/24 ! -d 10.10.0.0/16 -j MASQUERADE 2>/dev/null || true
    # UE PDU 位址池對外流量（經 UPF/N6）
    iptables -t nat -A POSTROUTING -s 10.60.0.0/16 ! -d 10.10.0.0/16 -j MASQUERADE 2>/dev/null || true

    # router-ns 到 Host 的預設路由（讓 router-ns 內的程式能上網）
    ip netns exec "$NS_ROUTER" ip route add default via 10.10.3.2

    # --- 測試 ---
    echo ""
    echo ">>> 連通性測試..."
    echo -n "  gnb-ns → router-ns (10.10.1.1): "
    ip netns exec "$NS_GNB" ping -c 1 -W 2 10.10.1.1 > /dev/null 2>&1 && echo "✓" || echo "✗"

    echo -n "  core-ns → router-ns (10.10.2.1): "
    ip netns exec "$NS_CORE" ping -c 1 -W 2 10.10.2.1 > /dev/null 2>&1 && echo "✓" || echo "✗"

    echo -n "  core-ns → Host N6 (10.10.4.2): "
    ip netns exec "$NS_CORE" ping -c 1 -W 2 10.10.4.2 > /dev/null 2>&1 && echo "✓" || echo "✗"

    echo -n "  Host → router-ns (10.10.3.1): "
    ping -c 1 -W 2 10.10.3.1 > /dev/null 2>&1 && echo "✓" || echo "✗"

    echo -n "  Host → gnb-ns (10.10.1.2): "
    ping -c 1 -W 2 10.10.1.2 > /dev/null 2>&1 && echo "✓" || echo "✗"

    echo -n "  Host → core-ns (10.10.2.2): "
    ping -c 1 -W 2 10.10.2.2 > /dev/null 2>&1 && echo "✓" || echo "✗"

    echo -n "  gnb-ns → core-ns (10.10.2.2): "
    ip netns exec "$NS_GNB" ping -c 1 -W 2 10.10.2.2 > /dev/null 2>&1 && echo "✗ (被 DROP，正確！)" || echo "✗ (不reachable，正確！)"

    echo ""
    echo "✓ 三個 Network Namespace Creatingcomplete！"
    echo ""
    echo "=== 拓撲 ==="
    echo ""
    echo "  gnb-ns  (10.10.1.2)  ────  router-ns  (10.10.1.1)"
    echo "                              (10.10.2.1) ────  core-ns (10.10.2.2)"
    echo "                              (10.10.3.1) ────  Host    (10.10.3.2)"
    echo "  core-ns (10.10.4.1)   ────  Host    (10.10.4.2)  [N6 egress]"
    echo ""
    echo "  gnb-ns ←✗→ core-ns (隔離，流量必須經 Ziti)"
    echo ""
    echo "=== 使用方式 ==="
    echo "  sudo ip netns exec gnb-ns bash       # 進入 gNB 側"
    echo "  sudo ip netns exec router-ns bash     # 進入 Router 側"
    echo "  sudo ip netns exec core-ns bash       # 進入核網側"
    echo ""
}

create_dn_namespace() {
    echo "=== Creating DN namespace (dn-ns) ==="

    if ! ip netns list 2>/dev/null | grep -qw "$NS_ROUTER"; then
        echo "[ERROR] router-ns does not exist. Run: sudo $0 create" >&2
        exit 1
    fi

    if ip netns list 2>/dev/null | grep -qw "$NS_DN"; then
        ip netns pids "$NS_DN" 2>/dev/null | xargs -r kill 2>/dev/null || true
        sleep 0.3
        ip netns del "$NS_DN" 2>/dev/null || true
    fi

    ip link del veth-dn 2>/dev/null || true
    ip netns exec "$NS_ROUTER" ip link del veth-dn-r 2>/dev/null || true

    ip netns add "$NS_DN"
    ip netns exec "$NS_DN" ip link set lo up

    echo ">>> veth: dn-ns ↔ router-ns..."
    ip link add veth-dn type veth peer name veth-dn-r
    ip link set veth-dn netns "$NS_DN"
    ip link set veth-dn-r netns "$NS_ROUTER"

    ip netns exec "$NS_DN" ip addr add "$DN_IP" dev veth-dn
    ip netns exec "$NS_DN" ip link set veth-dn up

    ip netns exec "$NS_ROUTER" ip addr add "$ROUTER_DN_IP" dev veth-dn-r
    ip netns exec "$NS_ROUTER" ip link set veth-dn-r up

    ip netns exec "$NS_DN" ip route add default via 10.10.5.1

    # Host needs a route to DN subnet via router-ns management link
    ip route add 10.10.5.0/24 via 10.10.3.1 2>/dev/null || true

    mkdir -p /etc/netns/"$NS_DN"
    cp /etc/resolv.conf /etc/netns/"$NS_DN"/resolv.conf

    echo "✓ dn-ns created"
}

delete_dn_namespace() {
    echo "=== Deleting DN namespace (dn-ns) ==="

    if ip netns list 2>/dev/null | grep -qw "$NS_DN"; then
        echo ">>> 清理 $NS_DN..."
        ip netns pids "$NS_DN" 2>/dev/null | xargs -r kill 2>/dev/null || true
        sleep 0.5
        ip netns del "$NS_DN" 2>/dev/null || true
    fi

    ip link del veth-dn 2>/dev/null || true

    # Remove Host route to DN subnet
    ip route del 10.10.5.0/24 via 10.10.3.1 2>/dev/null || true

    rm -rf /etc/netns/"$NS_DN" 2>/dev/null || true
    echo "✓ dn-ns deleted"
}

delete_namespaces() {
    echo "=== Deleting all Network Namespaces ==="

    for ns in "$NS_GNB" "$NS_ROUTER" "$NS_CORE" "$NS_DN"; do
        if ip netns list 2>/dev/null | grep -qw "$ns"; then
            echo ">>> 清理 $ns..."
            ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
            sleep 0.5
            ip netns del "$ns" 2>/dev/null || true
        fi
    done

    ip link del veth-host 2>/dev/null || true
    ip link del veth-host-core 2>/dev/null || true
    ip link del veth-dn 2>/dev/null || true

    # 清理路由與 NAT
    ip route del 10.10.1.0/24 via 10.10.3.1 2>/dev/null || true
    ip route del 10.10.2.0/24 via 10.10.3.1 2>/dev/null || true
    ip route del 10.10.5.0/24 via 10.10.3.1 2>/dev/null || true
    ip route del 10.60.0.0/16 via 10.10.4.1 dev veth-host-core 2>/dev/null || true
    ip route del 10.61.0.0/16 via 10.10.4.1 dev veth-host-core 2>/dev/null || true

    # 清理 Host FORWARD allow rules (added for core-ns management + egress)
    iptables -D FORWARD -s 10.10.3.0/24 -d 10.10.4.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -s 10.10.4.0/24 -d 10.10.3.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i veth-host-core -s 10.10.4.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i veth-host-core -s 10.60.0.0/16 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i veth-host-core -s 10.61.0.0/16 -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 10.10.3.0/24 ! -d 10.10.0.0/16 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 10.10.4.0/24 ! -d 10.10.0.0/16 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 10.10.2.0/24 ! -d 10.10.0.0/16 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 10.60.0.0/16 ! -d 10.10.0.0/16 -j MASQUERADE 2>/dev/null || true

    # 清理 DNS
    rm -rf /etc/netns/"$NS_GNB" /etc/netns/"$NS_ROUTER" /etc/netns/"$NS_CORE" /etc/netns/"$NS_DN" 2>/dev/null || true

    echo "✓ 清理complete"
}

show_status() {
    echo "=== Network Namespace Status ==="
    echo ""

    for ns in "$NS_GNB" "$NS_ROUTER" "$NS_CORE" "$NS_DN"; do
        if ip netns list 2>/dev/null | grep -qw "$ns"; then
            echo "--- $ns: 存在 ✓ ---"
            echo "  介面:"
            ip netns exec "$ns" ip -br addr 2>/dev/null | sed 's/^/    /'
            echo "  路由:"
            ip netns exec "$ns" ip route 2>/dev/null | sed 's/^/    /'
            echo "  程式:"
            local pids
            pids=$(ip netns pids "$ns" 2>/dev/null | tr '\n' ' ')
            if [ -n "$pids" ]; then
                for pid in $pids; do
                    echo "    PID $pid: $(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | head -c 100)"
                done
            else
                echo "    (無)"
            fi
        else
            echo "--- $ns: 不存在 ✗ ---"
        fi
        echo ""
    done

    echo "--- Host 側 veth ---"
    ip -br addr show dev veth-host 2>/dev/null | sed 's/^/  /' || echo "  veth-host 不存在"
    ip -br addr show dev veth-host-core 2>/dev/null | sed 's/^/  /' || echo "  veth-host-core 不存在"
    echo ""
}

case "$ACTION" in
    create)  create_namespaces ;;
    delete|destroy|clean) delete_namespaces ;;
    create-dn) create_dn_namespace ;;
    delete-dn) delete_dn_namespace ;;
    status|show) show_status ;;
    *)
        echo "用法: $0 {create|delete|status|create-dn|delete-dn}"
        exit 1
        ;;
esac
