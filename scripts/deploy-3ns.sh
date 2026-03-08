#!/usr/bin/env bash
# =============================================================================
# deploy-3ns.sh — 一鍵部署：三 Namespace + Ziti + free5gc + UERANSIM
#
# 全自動部署流程：
#   Phase 0: 前置套件
#   Phase 1: Namespace 網路
#   Phase 2: Ziti binary
#   Phase 3: PKI 憑證
#   Phase 4: Controller（router-ns）
#   Phase 5: Router（router-ns）
#   Phase 6: 策略 & Identity
#   Phase 7: free5gc（core-ns）
#   Phase 8: Core-side Tunneler + socat（core-ns）
#   Phase 9: gNB-side Tunneler + socat（gnb-ns）
#   Phase 10: UERANSIM gNB（gnb-ns）
#   Phase 11: 驗證
#
# 用法：
#   cd ~/openziti-5gc
#   sudo ./scripts/deploy-3ns.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
step() { echo -e "\n${CYAN}══════════ $* ══════════${NC}\n"; }

if [ "$EUID" -ne 0 ]; then
    err "請使用 sudo 執行"; exit 1
fi

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~$REAL_USER")
ZITI="$PROJECT_DIR/bin/ziti"
ZET="$PROJECT_DIR/bin/ziti-edge-tunnel"

run_as_user() {
    su - "$REAL_USER" -c "cd '$PROJECT_DIR' && $*"
}

# =============================================================================
step "Phase 0: 前置套件"
# =============================================================================
apt-get update -qq
apt-get install -y -qq socat unzip curl jq > /dev/null 2>&1
if ! command -v yq &>/dev/null; then
    curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" \
        -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
fi
log "前置套件就緒"

# =============================================================================
step "Phase 1: 建立三個 Network Namespace"
# =============================================================================
bash "$SCRIPT_DIR/setup-namespaces.sh" create
log "Namespace 拓撲就緒"

# =============================================================================
step "Phase 2: 下載 Ziti binary"
# =============================================================================
run_as_user "make download"
log "Binary 下載完成"

# =============================================================================
step "Phase 3: PKI 憑證"
# =============================================================================
run_as_user "make pki"
log "PKI 就緒"

# =============================================================================
step "Phase 4: Controller (router-ns)"
# =============================================================================
run_as_user "make controller-init"

# 在 router-ns 內啟動 Controller
echo ">>> 在 router-ns 內啟動 Controller..."
ip netns exec router-ns \
    nohup "$ZITI" controller run "$PROJECT_DIR/controller/ctrl-config.yaml" \
    > "$PROJECT_DIR/logs/controller.log" 2>&1 &
echo $! > "$PROJECT_DIR/data/controller.pid"
sleep 4

# 從 Host 透過 10.10.3.1 驗證
if curl -sk "https://10.10.3.1:1280/edge/client/v1/version" > /dev/null 2>&1; then
    log "Controller 啟動成功（router-ns, 10.10.3.1:1280）"
else
    err "Controller 無法連線"
    tail -5 "$PROJECT_DIR/logs/controller.log"
    exit 1
fi

# =============================================================================
step "Phase 5: Router (router-ns)"
# =============================================================================
# Login（從 Host 透過管理通道）
"$ZITI" edge login "https://10.10.3.1:1280" \
    -u admin -p "$(cat .admin-password)" --yes

# 建立並 enroll router
"$ZITI" edge create edge-router main-router \
    -o "$PROJECT_DIR/data/main-router.jwt" \
    -a "public" --tunneler-enabled 2>/dev/null || true

ip netns exec router-ns \
    "$ZITI" router enroll "$PROJECT_DIR/router/router-config.yaml" \
    --jwt "$PROJECT_DIR/data/main-router.jwt"

# 在 router-ns 內啟動 Router
ip netns exec router-ns \
    nohup "$ZITI" router run "$PROJECT_DIR/router/router-config.yaml" \
    > "$PROJECT_DIR/logs/router.log" 2>&1 &
echo $! > "$PROJECT_DIR/data/router.pid"
sleep 3

log "Router 啟動成功（router-ns）"

# =============================================================================
step "Phase 6: 套用策略 & Enroll Identities"
# =============================================================================
run_as_user "make apply"
run_as_user "make enroll-core"
run_as_user "make enroll-gnb"
log "所有策略與 Identity 已就緒"

# =============================================================================
step "Phase 7: 啟動 free5gc (core-ns)"
# =============================================================================
bash "$SCRIPT_DIR/start-core.sh" start
log "free5gc 已在 core-ns 內啟動"

# =============================================================================
step "Phase 8: Core-side Tunneler + socat (core-ns)"
# =============================================================================
# Core-side 僅載入 core identities
mkdir -p "$PROJECT_DIR/data/core-identities"
cp -f "$PROJECT_DIR"/pki/identities/core-*.json "$PROJECT_DIR/data/core-identities/" 2>/dev/null || true

# Core 側 Tunneler: run-host 模式（不需 tproxy）
ip netns exec core-ns \
    nohup "$ZET" run-host \
        --identity-dir "$PROJECT_DIR/data/core-identities/" \
        --verbose 2 \
        > "$PROJECT_DIR/logs/tunnel-core.log" 2>&1 &
echo $! > "$PROJECT_DIR/data/tunnel-core.pid"
sleep 2

# socat-core: Ziti TCP → SCTP → AMF
ip netns exec core-ns \
    nohup socat TCP-LISTEN:38413,bind=127.0.0.1,fork,reuseaddr \
        SCTP:127.0.0.18:38412 \
        > "$PROJECT_DIR/logs/socat-n2-core.log" 2>&1 &
echo $! > "$PROJECT_DIR/data/socat-core.pid"

log "Core-side Tunneler + socat 啟動"

# =============================================================================
step "Phase 9: gNB-side Tunneler + socat (gnb-ns)"
# =============================================================================
# gnb-ns 內 DNS 指向 Ziti DNS
mkdir -p /etc/netns/gnb-ns
echo -e "nameserver 100.64.0.1\noptions timeout:1 attempts:1" > /etc/netns/gnb-ns/resolv.conf

# gNB 側 Tunneler: run 模式（tproxy）
ip netns exec gnb-ns \
    nohup "$ZET" run \
        --identity "$PROJECT_DIR/pki/identities/gnb-01.json" \
        --dns-ip-range "100.64.0.0/10" \
        --verbose 2 \
        > "$PROJECT_DIR/logs/tunnel-gnb.log" 2>&1 &
echo $! > "$PROJECT_DIR/data/tunnel-gnb.pid"
sleep 3

# 添加到 UPF 的路由（tproxy 攔截需要路由先存在）
ip netns exec gnb-ns ip route add 10.10.2.0/24 via 10.10.1.1 2>/dev/null || true

# socat-gnb: gNB SCTP → TCP → Ziti (via amf.ziti resolved by Tunneler DNS)
ip netns exec gnb-ns \
    nohup socat SCTP-LISTEN:38412,bind=127.0.0.1,fork,reuseaddr \
        TCP:amf.ziti:38412 \
        > "$PROJECT_DIR/logs/socat-n2-gnb.log" 2>&1 &
echo $! > "$PROJECT_DIR/data/socat-gnb.pid"

log "gNB-side Tunneler + socat 啟動"

# =============================================================================
step "Phase 10: UERANSIM gNB (gnb-ns)"
# =============================================================================
bash "$SCRIPT_DIR/start-gnb.sh" start
log "UERANSIM gNB 已在 gnb-ns 內啟動"

# =============================================================================
step "Phase 11: 驗證"
# =============================================================================

echo ""
echo "--- 組件狀態 ---"
echo ""

check_pid() {
    local name="$1" file="$2"
    if [ -f "$file" ] && kill -0 "$(cat "$file")" 2>/dev/null; then
        log "$name: 運行中 (PID: $(cat "$file"))"
    else
        err "$name: 未運行"
    fi
}

check_pid "Controller (router-ns)" "$PROJECT_DIR/data/controller.pid"
check_pid "Router (router-ns)"     "$PROJECT_DIR/data/router.pid"
check_pid "Core Tunneler (core-ns)" "$PROJECT_DIR/data/tunnel-core.pid"
check_pid "gNB Tunneler (gnb-ns)"  "$PROJECT_DIR/data/tunnel-gnb.pid"

echo ""
echo "--- Namespace 概況 ---"
for ns in gnb-ns router-ns core-ns; do
    count=$(ip netns pids "$ns" 2>/dev/null | wc -l)
    echo "  $ns: $count 個程式"
done

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  部署完成！${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  啟動 UE:"
echo "    sudo ./scripts/start-gnb.sh start-ue"
echo ""
echo "  日誌:"
echo "    tail -f logs/tunnel-gnb.log     # gNB Ziti"
echo "    tail -f logs/tunnel-core.log    # Core Ziti"
echo "    tail -f logs/gnb.log            # UERANSIM gNB"
echo ""
echo "  進入各 namespace:"
echo "    sudo ip netns exec gnb-ns bash"
echo "    sudo ip netns exec router-ns bash"
echo "    sudo ip netns exec core-ns bash"
echo ""
echo "  停止所有:"
echo "    sudo make stop-all"
echo ""
