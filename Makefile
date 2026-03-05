# =============================================================================
# OpenZiti 5GC Overlay — 本地編譯部署 Makefile
# 用於保護 free5gc 的 N2/N3/N4 介面
# =============================================================================

SHELL        := /bin/bash
PROJECT_DIR  := $(shell pwd)
BIN_DIR      := $(PROJECT_DIR)/bin
PKI_DIR      := $(PROJECT_DIR)/pki
DATA_DIR     := $(PROJECT_DIR)/data
LOG_DIR      := $(PROJECT_DIR)/logs
CTRL_CFG     := $(PROJECT_DIR)/controller/ctrl-config.yaml
ROUTER_CFG   := $(PROJECT_DIR)/router/router-config.yaml
POLICY_DIR   := $(PROJECT_DIR)/policies
SCRIPTS_DIR  := $(PROJECT_DIR)/scripts

# Ziti 版本
ZITI_VERSION       := 1.6.13
TUNNEL_VERSION     := 1.10.10

# 網路參數
# 三 ns 部署時，CTRL/ROUTER 在 router-ns，用 10.10.3.1（Host 管理側）
CTRL_HOST     := 10.10.3.1
CTRL_MGMT_PORT := 1280
CTRL_CTRL_PORT := 6262
ROUTER_HOST   := 10.10.3.1
ROUTER_EDGE_PORT := 3022
ADMIN_USER    := admin
ADMIN_PASS    := $(shell cat .admin-password 2>/dev/null || echo "Change!Me123")

# Ziti CLI 路徑
ZITI          := $(BIN_DIR)/ziti
ZET           := $(BIN_DIR)/ziti-edge-tunnel

.PHONY: all help dirs download build-from-source install-tunnel \
        pki controller-init router-init \
        start-controller start-router stop-controller stop-router \
        login apply apply-services apply-identities apply-policies \
        enroll-gnb enroll-core start-tunnel-gnb start-tunnel-core \
        status clean systemd-install \
        ns-create ns-delete ns-status \
        start-core stop-core start-gnb stop-gnb \
        deploy stop-all

# =============================================================================
# 說明
# =============================================================================
help:
	@echo ""
	@echo "=== OpenZiti 5GC 三 Namespace 部署 ==="
	@echo ""
	@echo "  一鍵部署："
	@echo "    make deploy           一鍵部署所有組件（需 sudo）"
	@echo ""
	@echo "  初次完整部署（依序執行）："
	@echo "    make dirs             建立目錄"
	@echo "    make download         下載預編譯 binary"
	@echo "    sudo make ns-create   建立三個 namespace"
	@echo "    make pki              生成 PKI 憑證"
	@echo "    make controller-init  初始化 Controller"
	@echo "    make start-controller 啟動 Controller（router-ns）"
	@echo "    make router-init      註冊 Router"
	@echo "    make start-router     啟動 Router（router-ns）"
	@echo "    make login            登入管理 API"
	@echo "    make apply            套用服務與策略"
	@echo "    make enroll-gnb       Enroll gNB Identity"
	@echo "    make enroll-core      Enroll Core Identity"
	@echo "    sudo make start-core  啟動 free5gc（core-ns）"
	@echo "    sudo make start-tunnel-core 啟動 Core Tunneler（core-ns）"
	@echo "    sudo make start-tunnel-gnb  啟動 gNB Tunneler（gnb-ns）"
	@echo "    sudo make start-gnb   啟動 UERANSIM gNB（gnb-ns）"
	@echo ""
	@echo "  日常操作："
	@echo "    make status           檢查各組件狀態"
	@echo "    sudo make ns-status   檢查 namespace 狀態"
	@echo "    sudo make stop-all    停止所有服務"
	@echo "    make clean            清理資料（保留 binary）"
	@echo ""

# =============================================================================
# 1. 建立目錄
# =============================================================================
dirs:
	mkdir -p $(BIN_DIR) $(PKI_DIR)/identities
	mkdir -p $(DATA_DIR) $(LOG_DIR)
	mkdir -p $(POLICY_DIR) $(SCRIPTS_DIR)
	@echo "✓ 目錄建立完成"

# =============================================================================
# 2a. 下載預編譯 binary（推薦，最快）
# =============================================================================
download: dirs
	@echo ">>> 下載 ziti v$(ZITI_VERSION) ..."
	curl -sL "https://github.com/openziti/ziti/releases/download/v$(ZITI_VERSION)/ziti-linux-amd64-$(ZITI_VERSION).tar.gz" \
		| tar xz -C $(BIN_DIR)/
	chmod +x $(BIN_DIR)/ziti
	@echo ">>> 下載 ziti-edge-tunnel v$(TUNNEL_VERSION) ..."
	curl -sL "https://github.com/openziti/ziti-tunnel-sdk-c/releases/download/v$(TUNNEL_VERSION)/ziti-edge-tunnel-Linux_x86_64.zip" \
		-o /tmp/zet.zip
	unzip -o /tmp/zet.zip -d $(BIN_DIR)/ && rm -f /tmp/zet.zip
	chmod +x $(BIN_DIR)/ziti-edge-tunnel
	$(ZITI) version
	@echo "✓ 下載完成"

# =============================================================================
# 2b. 從原始碼編譯（替代方案）
# =============================================================================
build-from-source: dirs
	@echo ">>> 克隆 openziti/ziti 原始碼..."
	@if [ ! -d /tmp/ziti-src ]; then \
		git clone --depth 1 --branch "v$(ZITI_VERSION)" \
			https://github.com/openziti/ziti.git /tmp/ziti-src; \
	fi
	@echo ">>> 編譯 ziti（需要 Go $(shell go version | awk '{print $$3}')）..."
	cd /tmp/ziti-src && go build -o $(BIN_DIR)/ziti ./ziti/
	chmod +x $(BIN_DIR)/ziti
	$(ZITI) version
	@echo "✓ 從原始碼編譯完成"

# =============================================================================
# 2c. 安裝 ziti-edge-tunnel（從套件庫或下載）
# =============================================================================
install-tunnel: dirs
	@echo ">>> 安裝 ziti-edge-tunnel..."
	@if [ ! -f $(ZET) ]; then \
		curl -sL "https://github.com/openziti/ziti-tunnel-sdk-c/releases/download/v$(TUNNEL_VERSION)/ziti-edge-tunnel-Linux_x86_64.zip" \
			-o /tmp/zet.zip; \
		unzip -o /tmp/zet.zip -d $(BIN_DIR)/ && rm -f /tmp/zet.zip; \
		chmod +x $(ZET); \
	fi
	$(ZET) version || true
	@echo "✓ ziti-edge-tunnel 安裝完成"

# =============================================================================
# 3. 生成 PKI 憑證
# =============================================================================
pki:
	@echo ">>> 生成 Root CA..."
	@echo ">>> 預先建立所有憑證的目錄結構..."
	mkdir -p $(PKI_DIR)/{ctrl-intermediate,ctrl-server,ctrl-client,router-server,router-client}/{keys,certs}
	@echo ">>> 生成 Root CA..."
	$(ZITI) pki create ca \
		--pki-root $(PKI_DIR) \
		--ca-file ca \
		--ca-name "5GC-Ziti-Root-CA"
	@echo ">>> 生成 Controller 中繼 CA..."
	$(ZITI) pki create intermediate \
		--pki-root $(PKI_DIR) \
		--ca-name ca \
		--intermediate-file ctrl-intermediate \
		--intermediate-name "Controller Signing CA"
	@echo ">>> 生成 Controller Server 憑證..."
	$(ZITI) pki create server \
		--pki-root $(PKI_DIR) \
		--ca-name ca \
		--server-file ctrl-server \
		--dns "localhost,ziti-controller" \
		--ip "127.0.0.1,10.10.1.1,10.10.2.1,10.10.3.1"
	@echo ">>> 生成 Controller Client 憑證..."
	$(ZITI) pki create client \
		--pki-root $(PKI_DIR) \
		--ca-name ca \
		--client-file ctrl-client \
		--client-name "Controller Client"
	@echo ">>> 生成 Router Server 憑證..."
	$(ZITI) pki create server \
		--pki-root $(PKI_DIR) \
		--ca-name ca \
		--server-file router-server \
		--dns "localhost,ziti-router" \
		--ip "127.0.0.1,10.10.1.1,10.10.2.1,10.10.3.1"
	@echo ">>> 生成 Router Client 憑證..."
	$(ZITI) pki create client \
		--pki-root $(PKI_DIR) \
		--ca-name ca \
		--client-file router-client \
		--client-name "Router Client"
	@echo "✓ PKI 憑證生成完成（位於 $(PKI_DIR)）"

# =============================================================================
# 4. 初始化 Controller
# =============================================================================
controller-init:
	@echo ">>> 初始化 Controller 資料庫..."
	$(ZITI) controller edge init $(CTRL_CFG) \
		-u "$(ADMIN_USER)" -p "$(ADMIN_PASS)"
	@echo "$(ADMIN_PASS)" > .admin-password
	@chmod 600 .admin-password
	@echo "✓ Controller 初始化完成（密碼存於 .admin-password）"

# =============================================================================
# 5. 啟動/停止 Controller
# =============================================================================
start-controller:
	@echo ">>> 在 router-ns 內啟動 Controller..."
	sudo ip netns exec router-ns nohup $(ZITI) controller run $(CTRL_CFG) > $(LOG_DIR)/controller.log 2>&1 &
	@echo $$! > $(DATA_DIR)/controller.pid
	@echo ">>> 等待 Controller 就緒..."
	@timeout 15 bash -c 'until sudo ip netns exec router-ns nc -z $(CTRL_HOST) $(CTRL_MGMT_PORT); do sleep 1; done' || (echo "啟動超時" && exit 1)
	@echo "✓ Controller 已啟動"

stop-controller:
	@if [ -f $(DATA_DIR)/controller.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/controller.pid) 2>/dev/null || true; \
		rm -f $(DATA_DIR)/controller.pid; \
		echo "✓ Controller 已停止"; \
	else \
		echo "Controller 未在執行"; \
	fi

# =============================================================================
# 6. 初始化 Router（向 Controller 註冊）
# =============================================================================
router-init: login
	@echo ">>> 建立 Edge Router..."
	$(ZITI) edge create edge-router main-router \
		-o $(DATA_DIR)/main-router.jwt \
		-a "public" --tunneler-enabled || true
	@echo ">>> Enroll Router..."
	$(ZITI) router enroll $(ROUTER_CFG) \
		--jwt $(DATA_DIR)/main-router.jwt
	@echo "✓ Router 註冊完成"

# =============================================================================
# 7. 啟動/停止 Router
# =============================================================================
start-router:
	@echo ">>> 在 router-ns 內啟動 Router..."
	sudo ip netns exec router-ns \
		nohup $(ZITI) router run $(ROUTER_CFG) \
		> $(LOG_DIR)/router.log 2>&1 &
	@echo $$! > $(DATA_DIR)/router.pid
	@sleep 3
	@echo "✓ Router 已啟動 (PID: $$(cat $(DATA_DIR)/router.pid))"

stop-router:
	@if [ -f $(DATA_DIR)/router.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/router.pid) 2>/dev/null || true; \
		rm -f $(DATA_DIR)/router.pid; \
		echo "✓ Router 已停止"; \
	else \
		echo "Router 未在執行"; \
	fi

# =============================================================================
# 8. 登入管理 API
# =============================================================================
login:
	@echo ">>> 登入 Ziti Controller..."
	$(ZITI) edge login https://$(CTRL_HOST):$(CTRL_MGMT_PORT) \
		-u "$(ADMIN_USER)" -p "$(ADMIN_PASS)" \
		--yes

# =============================================================================
# 9. 套用所有設定檔
# =============================================================================
apply: login apply-services apply-identities apply-policies
	@echo ""
	@echo "✓ 所有服務、身份、策略已套用！"

apply-services:
	@echo ">>> 套用 Services..."
	$(SCRIPTS_DIR)/apply.sh services $(POLICY_DIR)/services.yml

apply-identities:
	@echo ">>> 套用 Identities..."
	$(SCRIPTS_DIR)/apply.sh identities $(POLICY_DIR)/identities.yml

apply-policies:
	@echo ">>> 套用 Policies..."
	$(SCRIPTS_DIR)/apply.sh policies $(POLICY_DIR)/service-policies.yml
	$(SCRIPTS_DIR)/apply.sh router-policies $(POLICY_DIR)/edge-router-policies.yml

# =============================================================================
# 10. Enroll Identity 並啟動 Tunnel
# =============================================================================
enroll-gnb:
	@for jwt in $(PKI_DIR)/identities/gnb-*.jwt; do \
		name=$$(basename $$jwt .jwt); \
		if [ ! -f $(PKI_DIR)/identities/$$name.json ]; then \
			echo ">>> Enrolling $$name ..."; \
			$(ZET) enroll --jwt $$jwt \
				--identity $(PKI_DIR)/identities/$$name.json; \
		else \
			echo "[skip] $$name 已 enroll"; \
		fi \
	done
	@echo "✓ gNB Identity enroll 完成"

enroll-core:
	@for jwt in $(PKI_DIR)/identities/core-*.jwt; do \
		name=$$(basename $$jwt .jwt); \
		if [ ! -f $(PKI_DIR)/identities/$$name.json ]; then \
			echo ">>> Enrolling $$name ..."; \
			$(ZET) enroll --jwt $$jwt \
				--identity $(PKI_DIR)/identities/$$name.json; \
		else \
			echo "[skip] $$name 已 enroll"; \
		fi \
	done
	@echo "✓ Core Identity enroll 完成"

start-tunnel-core:
	@echo ">>> 在 core-ns 內啟動 Tunneler (run-host 模式)..."
	sudo ip netns exec core-ns \
		nohup $(ZET) run-host \
		--identity-dir $(PKI_DIR)/identities/ \
		--verbose 2 \
		> $(LOG_DIR)/tunnel-core.log 2>&1 &
	@echo $$! > $(DATA_DIR)/tunnel-core.pid
	@sleep 2
	@echo "✓ Core Tunneler 已在 core-ns 內啟動"
	@echo ">>> 啟動 N2 socat (core-ns 內)..."
	sudo ip netns exec core-ns \
		nohup socat TCP-LISTEN:38413,bind=127.0.0.1,fork,reuseaddr \
		SCTP:127.0.0.18:38412 \
		> $(LOG_DIR)/socat-n2-core.log 2>&1 &
	@echo $$! > $(DATA_DIR)/socat-core.pid
	@echo "✓ socat-core 已啟動 (TCP:38413→SCTP:AMF:38412)"

start-tunnel-gnb:
	@echo ">>> 在 gnb-ns 內啟動 Tunneler (run/tproxy 模式)..."
	sudo ip netns exec gnb-ns \
		nohup $(ZET) run \
		--identity-dir $(PKI_DIR)/identities/ \
		--dns-ip-range "100.64.0.0/10" \
		--verbose 2 \
		> $(LOG_DIR)/tunnel-gnb.log 2>&1 &
	@echo $$! > $(DATA_DIR)/tunnel-gnb.pid
	@sleep 3
	@echo "✓ gNB Tunneler 已在 gnb-ns 內啟動"
	@echo ">>> 添加 UPF 路由（tproxy 攔截需要）..."
	sudo ip netns exec gnb-ns \
		ip route add 10.10.2.0/24 via 10.10.1.1 2>/dev/null || true
	@echo ">>> 啟動 N2 socat (gnb-ns 內)..."
	sudo ip netns exec gnb-ns \
		nohup socat SCTP-LISTEN:38412,bind=127.0.0.1,fork,reuseaddr \
		TCP:amf.ziti:38412 \
		> $(LOG_DIR)/socat-n2-gnb.log 2>&1 &
	@echo $$! > $(DATA_DIR)/socat-gnb.pid
	@echo "✓ socat-gnb 已啟動 (SCTP:38412→TCP:amf.ziti:38412)"

# =============================================================================
# 10b. 啟動/停止 free5gc (core-ns) 和 UERANSIM (gnb-ns)
# =============================================================================
start-core:
	@echo ">>> 在 core-ns 內啟動 free5gc..."
	sudo bash $(SCRIPTS_DIR)/start-core.sh start

stop-core:
	sudo bash $(SCRIPTS_DIR)/start-core.sh stop

start-gnb:
	@echo ">>> 在 gnb-ns 內啟動 UERANSIM gNB..."
	sudo bash $(SCRIPTS_DIR)/start-gnb.sh start

start-ue:
	@echo ">>> 在 gnb-ns 內啟動 UERANSIM UE..."
	sudo bash $(SCRIPTS_DIR)/start-gnb.sh start-ue

stop-gnb:
	sudo bash $(SCRIPTS_DIR)/start-gnb.sh stop

# =============================================================================
# 11. 狀態檢查
# =============================================================================
status:
	@echo ""
	@echo "=== OpenZiti 5GC 狀態 ==="
	@echo ""
	@echo "--- Controller ---"
	@if [ -f $(DATA_DIR)/controller.pid ] && kill -0 $$(cat $(DATA_DIR)/controller.pid) 2>/dev/null; then \
		echo "  狀態: ✓ 運行中 (PID: $$(cat $(DATA_DIR)/controller.pid))"; \
	else \
		echo "  狀態: ✗ 未運行"; \
	fi
	@echo ""
	@echo "--- Router ---"
	@if [ -f $(DATA_DIR)/router.pid ] && kill -0 $$(cat $(DATA_DIR)/router.pid) 2>/dev/null; then \
		echo "  狀態: ✓ 運行中 (PID: $$(cat $(DATA_DIR)/router.pid))"; \
	else \
		echo "  狀態: ✗ 未運行"; \
	fi
	@echo ""
	@echo "--- Tunneler ---"
	@pgrep -a ziti-edge-tunnel 2>/dev/null || echo "  狀態: ✗ 未運行"
	@echo ""
	@echo "--- 已註冊的服務 ---"
	@$(ZITI) edge list services 2>/dev/null || echo "  (需先 make login)"
	@echo ""
	@echo "--- 已註冊的 Identity ---"
	@$(ZITI) edge list identities 2>/dev/null || echo "  (需先 make login)"

# =============================================================================
# 12. 安裝 systemd 服務（開機自啟）
# =============================================================================
systemd-install:
	@echo ">>> 安裝 systemd 服務..."
	@echo ">>> 安裝 socat（SCTP-TCP 轉換用）..."
	sudo apt-get install -y socat || true
	sudo cp $(PROJECT_DIR)/systemd/ziti-controller.service /etc/systemd/system/
	sudo cp $(PROJECT_DIR)/systemd/ziti-router.service /etc/systemd/system/
	sudo cp $(PROJECT_DIR)/systemd/ziti-tunnel-gnb.service /etc/systemd/system/
	sudo cp $(PROJECT_DIR)/systemd/ziti-tunnel-core.service /etc/systemd/system/
	sudo cp $(PROJECT_DIR)/systemd/socat-n2-gnb.service /etc/systemd/system/
	sudo cp $(PROJECT_DIR)/systemd/socat-n2-core.service /etc/systemd/system/
	sudo systemctl daemon-reload
	@echo ""
	@echo "✓ systemd 服務已安裝"
	@echo ""
	@echo "  === 共用組件 ==="
	@echo "  sudo systemctl enable --now ziti-controller"
	@echo "  sudo systemctl enable --now ziti-router"
	@echo ""
	@echo "  === gNB 側主機啟用 ==="
	@echo "  sudo systemctl enable --now ziti-tunnel-gnb"
	@echo "  sudo systemctl enable --now socat-n2-gnb"
	@echo ""
	@echo "  === 核網側主機啟用 ==="
	@echo "  sudo systemctl enable --now ziti-tunnel-core"
	@echo "  sudo systemctl enable --now socat-n2-core"
	@echo ""

# =============================================================================
# 13. Network Namespace 管理（三 ns 拓撲）
# =============================================================================
ns-create:
	@echo ">>> 建立三個 namespace (gnb-ns, router-ns, core-ns)..."
	sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh create

ns-delete:
	@echo ">>> 刪除所有 namespace..."
	sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh delete

ns-status:
	sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh status

# =============================================================================
# 14. 一鍵部署（三 Namespace 版）
# =============================================================================
deploy:
	@echo ">>> 執行三 Namespace 一鍵部署..."
	sudo bash $(SCRIPTS_DIR)/deploy-3ns.sh

# =============================================================================
# 15. 停止所有服務
# =============================================================================
stop-all:
	@echo ">>> 停止所有服務..."
	-sudo bash $(SCRIPTS_DIR)/start-gnb.sh stop 2>/dev/null || true
	-sudo bash $(SCRIPTS_DIR)/start-core.sh stop 2>/dev/null || true
	-@if [ -f $(DATA_DIR)/tunnel-gnb.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/tunnel-gnb.pid) 2>/dev/null; \
		rm -f $(DATA_DIR)/tunnel-gnb.pid; \
	fi
	-@if [ -f $(DATA_DIR)/tunnel-core.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/tunnel-core.pid) 2>/dev/null; \
		rm -f $(DATA_DIR)/tunnel-core.pid; \
	fi
	-@if [ -f $(DATA_DIR)/socat-gnb.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/socat-gnb.pid) 2>/dev/null; \
		rm -f $(DATA_DIR)/socat-gnb.pid; \
	fi
	-@if [ -f $(DATA_DIR)/socat-core.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/socat-core.pid) 2>/dev/null; \
		rm -f $(DATA_DIR)/socat-core.pid; \
	fi
	-$(MAKE) stop-router
	-$(MAKE) stop-controller
	-sudo pkill -f ziti-edge-tunnel 2>/dev/null || true
	-sudo pkill -f "socat.*38412" 2>/dev/null || true
	-sudo pkill -f "socat.*38413" 2>/dev/null || true
	@echo "✓ 所有服務已停止"

# =============================================================================
# 清理
# =============================================================================
clean: stop-all
	@echo ">>> 清理資料..."
	rm -rf $(DATA_DIR) $(LOG_DIR) $(PKI_DIR)/identities/*.json
	-sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh delete 2>/dev/null || true
	@echo "✓ 清理完成（設定檔與 binary 保留）"

clean-all: clean
	rm -rf $(BIN_DIR) $(PKI_DIR) $(DATA_DIR) $(LOG_DIR)
	rm -f .admin-password
	@echo "✓ 全部清理完成"
