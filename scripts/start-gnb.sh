#!/usr/bin/env bash
# =============================================================================
# start-gnb.sh — Start UERANSIM gNB (+ UE) in gnb-ns
#
# Prerequisite: namespace created, free5gc is running in core-ns
#
# Usage:
#   sudo ./scripts/start-gnb.sh start      # Start gNB
#   sudo ./scripts/start-gnb.sh start-ue   # Start UE
#   sudo ./scripts/start-gnb.sh stop
#   sudo ./scripts/start-gnb.sh status
# =============================================================================

set -euo pipefail

ACTION="${1:-status}"
NS="gnb-ns"
UERANSIM_DIR="${UERANSIM_DIR:-/home/$(logname 2>/dev/null || echo $SUDO_USER)/UERANSIM}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PID_FILE="/tmp/gnb-ns-pids"

# gNB configuration path in namespace
GNB_CONFIG="${PROJECT_DIR}/config/ueransim-gnb.yaml"
UE_CONFIG="${PROJECT_DIR}/config/ueransim-ue.yaml"

check_ns() {
    if ! ip netns list 2>/dev/null | grep -qw "$NS"; then
        echo "[ERROR] namespace '$NS' does not exist. Please run first:"
        echo "  sudo ./scripts/setup-namespaces.sh create"
        exit 1
    fi
}

ns_exec() {
    ip netns exec "$NS" "$@"
}

create_configs() {
    mkdir -p "${PROJECT_DIR}/config"

    # ---------------------------------------------------------------
    # gNB 設定：適配 namespace 網路
    # ---------------------------------------------------------------
    if [ ! -f "$GNB_CONFIG" ]; then
        echo ">>> Generating gNB configuration file..."
        cat > "$GNB_CONFIG" << 'GNBEOF'
# =============================================================================
# UERANSIM gNB — for gnb-ns namespace + Ziti protection
#
# Important:
#   linkIp/ngapIp/gtpIp: Use 127.0.0.1 (loopback in gnb-ns)
#   AMF address: Connect to local n2 gateway (127.0.0.1:38412)
#     gateway sends SCTP payload + metadata → UDP frame → Ziti Tunneler → Ziti Fabric
#     → Core Tunneler → gateway → AMF
#
#   N3 GTP-U:
#     gNB sends UDP to UPF address informed by AMF (10.10.2.2:2152)
#     → Routed by Tunneler into ziti0 in gnb-ns
#     → Ziti Fabric → Core Tunneler → UPF
# =============================================================================

mcc: '208'
mnc: '93'
nci: '0x000000010'
idLength: 32
tac: 1

linkIp: 127.0.0.1     # gNB internal connection (gnb-ns loopback)
ngapIp: 127.0.0.1     # N2 local side (gNB side)
gtpIp:  10.10.1.2     # N3 address (for UPF downlink back to gNB)

# AMF connection — pointing to local n2 gateway (SCTP:38412 → UDP frame → Ziti)
amfConfigs:
  - address: 127.0.0.1
    port: 38412

slices:
  - sst: 0x1
    sd: 0x010203

ignoreStreamIds: true
GNBEOF
        echo "  → $GNB_CONFIG"
    fi

    # ---------------------------------------------------------------
    # UE 設定
    # ---------------------------------------------------------------
    if [ ! -f "$UE_CONFIG" ]; then
        echo ">>> Generating UE configuration file..."
        cat > "$UE_CONFIG" << 'UEEOF'
# UERANSIM UE — for gnb-ns namespace
supi: 'imsi-208930000000001'
mcc: '208'
mnc: '93'
protectionScheme: 0
homeNetworkPublicKey: '5a8d38864820197c3394b92613b20b91633cbd897119273bf8e4a6f4eec0a650'
homeNetworkPublicKeyId: 1
routingIndicator: '0000'

key: '8baf473f2f8fd09487cccbd7097c6862'
op: '8e27b6af0e692e750f32667a3b14605d'
opType: 'OPC'
amf: '8000'
imei: '356938035643803'
imeiSv: '4370816125816151'

tunNetmask: '255.255.255.0'

gnbSearchList:
  - 127.0.0.1      # gNB 在同一個 namespace

uacAic:
  mps: false
  mcs: false

uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false

sessions:
  - type: 'IPv4'
    apn: 'internet'
    slice:
      sst: 0x01
      sd: 0x010203

configured-nssai:
  - sst: 0x01
    sd: 0x010203

default-nssai:
  - sst: 1
    sd: 0x010203

integrity:
  IA1: true
  IA2: true
  IA3: true

ciphering:
  EA1: true
  EA2: true
  EA3: true

integrityMaxRate:
  uplink: 'full'
  downlink: 'full'
UEEOF
        echo "  → $UE_CONFIG"
    fi
}

start_gnb() {
    check_ns
    create_configs
    echo "=== 在 $NS 內Start UERANSIM gNB ==="

    > "$PID_FILE"

    # 確保到 UPF 的路由存在（讓目的地可被導向 ziti0）
    # 10.10.2.2 是 core-ns 的 IP，gNB 會嘗試送 GTP-U 到這裡
    # run(TUN) 會依目的地路由將流量送入 ziti0
    ns_exec ip route add 10.10.2.0/24 via 10.10.1.1 2>/dev/null || true
    # 確保 gNB-side Tunneler 一直能連到 Controller 管理位址
    # 避免 UE 啟動後將 10.10.3.1 誤導到 uesimtun0
    ns_exec ip route replace 10.10.3.1/32 via 10.10.1.1 dev veth-gnb 2>/dev/null || true

    # 下行 N3 改由 Ziti n3-gtpu-dl-service 直接投遞到 10.10.1.2:2152
    # 清理舊版 veth-gnb -> 127.0.0.1 的 DNAT workaround（避免殘留規則干擾）
    ns_exec iptables -t nat -D PREROUTING -i veth-gnb -p udp -d 10.10.1.2 --dport 2152 -j DNAT --to-destination 127.0.0.1:2152 2>/dev/null || true

    # Start gNB
    ns_exec "${UERANSIM_DIR}/build/nr-gnb" \
        -c "$GNB_CONFIG" \
        > "${PROJECT_DIR}/logs/gnb.log" 2>&1 &
    GNB_PID=$!
    echo "gnb:$GNB_PID" >> "$PID_FILE"
    echo "  gNB PID: $GNB_PID"

    sleep 1

    # 檢查是否存活
    if kill -0 "$GNB_PID" 2>/dev/null; then
        echo "✓ gNB 已在 $NS 內啟動"
    else
        echo "✗ gNB 啟動失敗，查看日誌:"
        echo "  tail -20 ${PROJECT_DIR}/logs/gnb.log"
        return 1
    fi

    echo ""
    echo "  Start UE:  sudo $0 start-ue"
    echo "  查看日誌: tail -f ${PROJECT_DIR}/logs/gnb.log"
}

start_ue() {
    check_ns
    create_configs
    echo "=== 在 $NS 內Start UERANSIM UE ==="

    ns_exec "${UERANSIM_DIR}/build/nr-ue" \
        -c "$UE_CONFIG" \
        > "${PROJECT_DIR}/logs/ue.log" 2>&1 &
    UE_PID=$!
    echo "ue:$UE_PID" >> "$PID_FILE"
    echo "  UE PID: $UE_PID"

    sleep 2

    # UE 啟動後再次釘住 Controller 路由，避免被 rt_uesimtun0 蓋掉
    ns_exec ip route replace 10.10.3.1/32 via 10.10.1.1 dev veth-gnb 2>/dev/null || true

    # UERANSIM 在 PDU Session 建立後可能再次改寫主路由表，延後再補一次
    (
        sleep 25
        ns_exec ip route replace 10.10.3.1/32 via 10.10.1.1 dev veth-gnb 2>/dev/null || true
    ) &

    if kill -0 "$UE_PID" 2>/dev/null; then
        echo "✓ UE 已在 $NS 內啟動"
        echo ""
        echo "  在 gnb-ns 內查看 UE tunnel 介面:"
        echo "    sudo ip netns exec $NS ip addr show uesimtun0"
        echo ""
        echo "  測試上網:"
        echo "    sudo ip netns exec $NS ping -I uesimtun0 8.8.8.8"
    else
        echo "✗ UE 啟動失敗，查看日誌:"
        echo "  tail -20 ${PROJECT_DIR}/logs/ue.log"
    fi
}

stop_gnb() {
    echo "=== 停止 $NS 內的 UERANSIM ==="

    if [ -f "$PID_FILE" ]; then
        while IFS=: read -r name pid; do
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                echo "  停止 $name (PID: $pid)"
            fi
        done < "$PID_FILE"
        rm -f "$PID_FILE"
    fi

    if ip netns list 2>/dev/null | grep -qw "$NS"; then
        ns_exec pkill -f nr-gnb 2>/dev/null || true
        ns_exec pkill -f nr-ue 2>/dev/null || true
    fi

    echo "✓ UERANSIM stopped"
}

show_status() {
    check_ns
    echo "=== $NS 內的 UERANSIM Status ==="
    echo ""
    echo "--- 網路介面 ---"
    ns_exec ip -br addr | sed 's/^/  /'
    echo ""
    echo "--- 程式 ---"
    if [ -f "$PID_FILE" ]; then
        while IFS=: read -r name pid; do
            if kill -0 "$pid" 2>/dev/null; then
                echo "  ✓ $name (PID: $pid)"
            else
                echo "  ✗ $name (PID: $pid) — Not running"
            fi
        done < "$PID_FILE"
    else
        echo "  (無 PID 記錄)"
        ns_exec pgrep -a "nr-gnb\|nr-ue" | sed 's/^/  /' 2>/dev/null || echo "  (無)"
    fi
}

case "$ACTION" in
    start)    start_gnb ;;
    start-ue) start_ue ;;
    stop)     stop_gnb ;;
    status)   show_status ;;
    *)
        echo "Usage: $0 {start|start-ue|stop|status}"
        exit 1
        ;;
esac
