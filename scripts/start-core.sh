#!/usr/bin/env bash
# =============================================================================
# start-core.sh — 在 core-ns 內啟動 free5gc 全部 NF
#
# 前提: namespace 已建立 (setup-namespaces.sh create)
#
# 用法:
#   sudo ./scripts/start-core.sh start
#   sudo ./scripts/start-core.sh stop
#   sudo ./scripts/start-core.sh status
# =============================================================================

set -euo pipefail

ACTION="${1:-status}"
NS="core-ns"
FREE5GC_DIR="${FREE5GC_DIR:-/home/$(logname 2>/dev/null || echo $SUDO_USER)/free5gc}"
LOG_DIR="${FREE5GC_DIR}/log/ns-$(date +%Y%m%d_%H%M%S)"
PID_FILE="/tmp/core-ns-pids"

# 檢查 namespace 是否存在
check_ns() {
    if ! ip netns list 2>/dev/null | grep -qw "$NS"; then
        echo "[ERROR] namespace '$NS' 不存在。請先執行:"
        echo "  sudo ./scripts/setup-namespaces.sh create"
        exit 1
    fi
}

# 在 namespace 內執行命令
ns_exec() {
    ip netns exec "$NS" "$@"
}

start_core() {
    check_ns
    echo "=== 在 $NS 內啟動 free5gc ==="

    # 確認 lo 介面的 127.0.0.0/8 可用（Linux 預設行為，但確認一下）
    ns_exec ip link set lo up

    mkdir -p "$LOG_DIR"
    > "$PID_FILE"

    # ---------------------------------------------------------------
    # 1. 啟動 MongoDB（在 core-ns 內）
    # ---------------------------------------------------------------
    echo ">>> 啟動 MongoDB..."
    # MongoDB 的 data 目錄
    MONGO_DATA="/tmp/core-ns-mongo"
    mkdir -p "$MONGO_DATA"

    ns_exec mongod \
        --dbpath "$MONGO_DATA" \
        --bind_ip 127.0.0.1 \
        --port 27017 \
        --logpath "$LOG_DIR/mongod.log" \
        --fork \
        --quiet
    # mongod --fork 模式自己管理 PID
    MONGO_PID=$(ns_exec pgrep -f "mongod.*core-ns-mongo" | head -1)
    echo "mongod:$MONGO_PID" >> "$PID_FILE"
    echo "  MongoDB PID: $MONGO_PID"

    sleep 1

    # 清理舊的 NF 註冊資料（和 run.sh 一樣）
    ns_exec mongosh free5gc --quiet --eval '
        db.NfProfile.drop();
        db.getCollection("applicationData.influenceData.subsToNotify").drop();
        db.getCollection("applicationData.subsToNotify").drop();
        db.getCollection("policyData.subsToNotify").drop();
        db.getCollection("exposureData.subsToNotify").drop();
    ' > /dev/null 2>&1 || true

    # ---------------------------------------------------------------
    # 2. 啟動 UPF（需要 sudo，因為要建 GTP tunnel）
    # ---------------------------------------------------------------
    echo ">>> 啟動 UPF..."
    ns_exec "${FREE5GC_DIR}/bin/upf" \
        -c "${FREE5GC_DIR}/config/upfcfg.yaml" \
        -l "$LOG_DIR/free5gc.log" &
    UPF_PID=$!
    echo "upf:$UPF_PID" >> "$PID_FILE"
    echo "  UPF PID: $UPF_PID"
    sleep 1

    # ---------------------------------------------------------------
    # 3. 啟動其他 NF（不需 sudo）
    # ---------------------------------------------------------------
    export GIN_MODE=release

    NF_LIST="nrf amf smf udr pcf udm nssf ausf chf nef"
    for nf in $NF_LIST; do
        echo ">>> 啟動 ${nf}..."
        ns_exec "${FREE5GC_DIR}/bin/${nf}" \
            -c "${FREE5GC_DIR}/config/${nf}cfg.yaml" \
            -l "$LOG_DIR/free5gc.log" &
        NF_PID=$!
        echo "${nf}:${NF_PID}" >> "$PID_FILE"
        echo "  ${nf} PID: $NF_PID"
        sleep 0.2
    done

    echo ""
    echo "✓ free5gc 所有 NF 已在 $NS 內啟動"
    echo "  日誌: $LOG_DIR/"
    echo "  PID 列表: $PID_FILE"
    echo ""
    echo "  驗證: sudo ip netns exec $NS ss -tlnp | grep 8000"
    echo "        sudo ip netns exec $NS ss -tlnp | grep 38412"
}

stop_core() {
    echo "=== 停止 $NS 內的 free5gc ==="

    if [ -f "$PID_FILE" ]; then
        while IFS=: read -r name pid; do
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                echo "  停止 $name (PID: $pid)"
            fi
        done < "$PID_FILE"
        rm -f "$PID_FILE"
    fi

    # 確保全部停掉
    if ip netns list 2>/dev/null | grep -qw "$NS"; then
        ns_exec pkill -f "bin/upf" 2>/dev/null || true
        ns_exec pkill -f "bin/nrf" 2>/dev/null || true
        ns_exec pkill -f "bin/amf" 2>/dev/null || true
        ns_exec pkill -f "bin/smf" 2>/dev/null || true
        for nf in udr pcf udm nssf ausf chf nef; do
            ns_exec pkill -f "bin/${nf}" 2>/dev/null || true
        done
        ns_exec mongod --shutdown --dbpath /tmp/core-ns-mongo 2>/dev/null || true
    fi

    echo "✓ free5gc 已停止"
}

show_status() {
    check_ns
    echo "=== $NS 內的 free5gc 狀態 ==="
    echo ""
    echo "--- 網路介面 ---"
    ns_exec ip -br addr | sed 's/^/  /'
    echo ""
    echo "--- 監聽 Port ---"
    ns_exec ss -tlnp 2>/dev/null | sed 's/^/  /'
    ns_exec ss -ulnp 2>/dev/null | grep -E "8805|2152|38412" | sed 's/^/  /' || true
    echo ""
    echo "--- 程式 ---"
    if [ -f "$PID_FILE" ]; then
        while IFS=: read -r name pid; do
            if kill -0 "$pid" 2>/dev/null; then
                echo "  ✓ $name (PID: $pid)"
            else
                echo "  ✗ $name (PID: $pid) — 未運行"
            fi
        done < "$PID_FILE"
    else
        echo "  (無 PID 記錄，用 ps 搜尋)"
        ns_exec pgrep -a -f "free5gc/bin" | sed 's/^/  /' || echo "  (無)"
    fi
}

case "$ACTION" in
    start)  start_core ;;
    stop)   stop_core ;;
    status) show_status ;;
    *)
        echo "用法: $0 {start|stop|status}"
        exit 1
        ;;
esac
