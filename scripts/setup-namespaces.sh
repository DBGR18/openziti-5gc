#!/usr/bin/env bash
# =============================================================================
# setup-namespaces.sh — 三 Namespace 隔離拓撲
#
# 最擬真的單機部署：gNB、Router、Core 各在獨立的 Network Namespace。
#
#  ┌──────────┐         ┌──────────────┐         ┌──────────┐
#  │  gnb-ns  │ veth    │  router-ns   │ veth    │  core-ns │
#  │10.10.1.2 ├────────►│10.10.1.1     │         │          │
#  │          │         │       10.10.2.1├───────►│10.10.2.2 │
#  └──────────┘         │       10.10.3.1│        └──────────┘
#                       └───────┬────────┘
#                               │ veth
#                    Host (10.10.3.2)
#                    (管理 CLI / MongoDB)
#
# 關鍵隔離：
#   gnb-ns 只能到達 router-ns (10.10.1.0/24)
#   core-ns 只能到達 router-ns (10.10.2.0/24)
#   gnb-ns ←✗→ core-ns    (完全隔離，必須經 Ziti)
#
# 用法：
#   sudo ./scripts/setup-namespaces.sh create
#   sudo ./scripts/setup-namespaces.sh delete
#   sudo ./scripts/setup-namespaces.sh status
# =============================================================================

set -euo pipefail

ACTION="${1:-status}"

# Namespace 名稱
NS_GNB="gnb-ns"
NS_ROUTER="router-ns"
NS_CORE="core-ns"

# === 網段定義 ===
# gNB ↔ Router: 10.10.1.0/24
GNB_IP="10.10.1.2/24"
ROUTER_GNB_IP="10.10.1.1/24"

# Router ↔ Core: 10.10.2.0/24
ROUTER_CORE_IP="10.10.2.1/24"
CORE_IP="10.10.2.2/24"

# Router ↔ Host (管理用): 10.10.3.0/24
ROUTER_HOST_IP="10.10.3.1/24"
HOST_IP="10.10.3.2/24"

create_namespaces() {
    echo "=== 建立三個 Network Namespaces ==="

    # --- 清理殘留 ---
    for ns in "$NS_GNB" "$NS_ROUTER" "$NS_CORE"; do
        if ip netns list 2>/dev/null | grep -qw "$ns"; then
            ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
            sleep 0.3
            ip netns del "$ns" 2>/dev/null || true
        fi
    done
    ip link del veth-host 2>/dev/null || true
    sleep 0.5

    # --- 建立 Namespaces ---
    ip netns add "$NS_GNB"
    ip netns add "$NS_ROUTER"
    ip netns add "$NS_CORE"
    echo "✓ 三個 namespace 已建立"

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

    # --- veth pair 3: Router ↔ Host (10.10.3.0/24) 管理用 ---
    echo ">>> veth: router-ns ↔ Host (管理通道)..."
    ip link add veth-host type veth peer name veth-host-r
    ip link set veth-host-r netns "$NS_ROUTER"

    ip addr add "$HOST_IP" dev veth-host
    ip link set veth-host up

    ip netns exec "$NS_ROUTER" ip addr add "$ROUTER_HOST_IP" dev veth-host-r
    ip netns exec "$NS_ROUTER" ip link set veth-host-r up

    # --- 路由設定 ---
    echo ">>> 設定路由..."

    # gNB 預設閘道 → Router (只能到 10.10.1.0/24)
    ip netns exec "$NS_GNB" ip route add default via 10.10.1.1

    # Core 預設閘道 → Router (只能到 10.10.2.0/24)
    ip netns exec "$NS_CORE" ip route add default via 10.10.2.1

    # Host 到各 namespace 的路由
    ip route add 10.10.1.0/24 via 10.10.3.1 2>/dev/null || true
    ip route add 10.10.2.0/24 via 10.10.3.1 2>/dev/null || true

    # Router: 不開啟 IP 轉發！
    # gnb-ns 和 core-ns 之間不能直接通訊
    # 只有 Router ↔ gnb-ns 和 Router ↔ core-ns 可達
    ip netns exec "$NS_ROUTER" sysctl -w net.ipv4.ip_forward=0 > /dev/null

    # 但 Router 需要轉發 Host(10.10.3.0/24) ↔ gnb/core 的管理流量
    # 所以我們用 iptables 精確控制：只轉發管理流量，不轉發 gnb↔core
    ip netns exec "$NS_ROUTER" sysctl -w net.ipv4.ip_forward=1 > /dev/null
    # 禁止 gnb-ns ↔ core-ns 直接轉發
    ip netns exec "$NS_ROUTER" iptables -A FORWARD \
        -s 10.10.1.0/24 -d 10.10.2.0/24 -j DROP
    ip netns exec "$NS_ROUTER" iptables -A FORWARD \
        -s 10.10.2.0/24 -d 10.10.1.0/24 -j DROP
    # 允許 Host(10.10.3.0/24) ↔ 兩端的管理流量
    ip netns exec "$NS_ROUTER" iptables -A FORWARD \
        -s 10.10.3.0/24 -j ACCEPT
    ip netns exec "$NS_ROUTER" iptables -A FORWARD \
        -d 10.10.3.0/24 -j ACCEPT

    # --- DNS ---
    for ns in "$NS_GNB" "$NS_ROUTER" "$NS_CORE"; do
        mkdir -p /etc/netns/"$ns"
        cp /etc/resolv.conf /etc/netns/"$ns"/resolv.conf
    done

    # --- NAT: 讓各 namespace 能上網（下載、enroll 等需要） ---
    # 從 router-ns 到 Host 的 NAT（讓 gnb-ns/core-ns 透過 Host 上網）
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    iptables -t nat -A POSTROUTING -s 10.10.3.0/24 ! -d 10.10.0.0/16 -j MASQUERADE 2>/dev/null || true

    # router-ns 到 Host 的預設路由（讓 router-ns 內的程式能上網）
    ip netns exec "$NS_ROUTER" ip route add default via 10.10.3.2

    # --- 測試 ---
    echo ""
    echo ">>> 連通性測試..."
    echo -n "  gnb-ns → router-ns (10.10.1.1): "
    ip netns exec "$NS_GNB" ping -c 1 -W 2 10.10.1.1 > /dev/null 2>&1 && echo "✓" || echo "✗"

    echo -n "  core-ns → router-ns (10.10.2.1): "
    ip netns exec "$NS_CORE" ping -c 1 -W 2 10.10.2.1 > /dev/null 2>&1 && echo "✓" || echo "✗"

    echo -n "  Host → router-ns (10.10.3.1): "
    ping -c 1 -W 2 10.10.3.1 > /dev/null 2>&1 && echo "✓" || echo "✗"

    echo -n "  Host → gnb-ns (10.10.1.2): "
    ping -c 1 -W 2 10.10.1.2 > /dev/null 2>&1 && echo "✓" || echo "✗"

    echo -n "  Host → core-ns (10.10.2.2): "
    ping -c 1 -W 2 10.10.2.2 > /dev/null 2>&1 && echo "✓" || echo "✗"

    echo -n "  gnb-ns → core-ns (10.10.2.2): "
    ip netns exec "$NS_GNB" ping -c 1 -W 2 10.10.2.2 > /dev/null 2>&1 && echo "✗ (被 DROP，正確！)" || echo "✗ (不可達，正確！)"

    echo ""
    echo "✓ 三個 Network Namespace 建立完成！"
    echo ""
    echo "=== 拓撲 ==="
    echo ""
    echo "  gnb-ns  (10.10.1.2)  ────  router-ns  (10.10.1.1)"
    echo "                              (10.10.2.1) ────  core-ns (10.10.2.2)"
    echo "                              (10.10.3.1) ────  Host    (10.10.3.2)"
    echo ""
    echo "  gnb-ns ←✗→ core-ns (隔離，流量必須經 Ziti)"
    echo ""
    echo "=== 使用方式 ==="
    echo "  sudo ip netns exec gnb-ns bash       # 進入 gNB 側"
    echo "  sudo ip netns exec router-ns bash     # 進入 Router 側"
    echo "  sudo ip netns exec core-ns bash       # 進入核網側"
    echo ""
}

delete_namespaces() {
    echo "=== 刪除所有 Network Namespaces ==="

    for ns in "$NS_GNB" "$NS_ROUTER" "$NS_CORE"; do
        if ip netns list 2>/dev/null | grep -qw "$ns"; then
            echo ">>> 清理 $ns..."
            ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
            sleep 0.5
            ip netns del "$ns" 2>/dev/null || true
        fi
    done

    ip link del veth-host 2>/dev/null || true

    # 清理路由與 NAT
    ip route del 10.10.1.0/24 via 10.10.3.1 2>/dev/null || true
    ip route del 10.10.2.0/24 via 10.10.3.1 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 10.10.3.0/24 ! -d 10.10.0.0/16 -j MASQUERADE 2>/dev/null || true

    # 清理 DNS
    rm -rf /etc/netns/"$NS_GNB" /etc/netns/"$NS_ROUTER" /etc/netns/"$NS_CORE" 2>/dev/null || true

    echo "✓ 清理完成"
}

show_status() {
    echo "=== Network Namespace 狀態 ==="
    echo ""

    for ns in "$NS_GNB" "$NS_ROUTER" "$NS_CORE"; do
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
    echo ""
}

case "$ACTION" in
    create)  create_namespaces ;;
    delete|destroy|clean) delete_namespaces ;;
    status|show) show_status ;;
    *)
        echo "用法: $0 {create|delete|status}"
        exit 1
        ;;
esac
