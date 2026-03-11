# =============================================================================
# OpenZiti 5GC Overlay — 本地編譯部署 Makefile
# 用於保護 free5gc 的 N2/N3/N4 介面
# =============================================================================

SHELL        := /bin/bash
.DEFAULT_GOAL := help
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
N2GW          := $(BIN_DIR)/n2-sctp-gateway

.PHONY: all help dirs download build-from-source install-tunnel \
	build-n2-gateway \
        pki controller-init router-init \
        start-controller start-router stop-controller stop-router \
        login apply apply-services apply-identities apply-policies \
        enroll-gnb enroll-core start-tunnel-gnb start-tunnel-core \
        status clean systemd-install \
        ns-create ns-delete ns-status \
        start-core stop-core start-gnb stop-gnb \
	deploy stop-all verify verify-active \
	controller router enroll core tunneler gnb ue \
	rebuild clean-rebuild

# =============================================================================
# 說明
# =============================================================================
help:
	@echo ""
	@echo "=== OpenZiti 5GC Three Namespace Deployment  ==="
	@echo ""
	@echo "  必要指令："
	@echo "    make dirs             建立目錄"
	@echo "    sudo make ns-create   建立 namespace"
	@echo "    make pki              生成 PKI"
	@echo "    make controller       初始化並啟動 Controller"
	@echo "    make router           註冊並啟動 Router"
	@echo "    make apply            套用服務/身份/策略"
	@echo "    make enroll           Enroll 全部 Identity"
	@echo "    sudo make core        啟動 free5gc"
	@echo "    sudo make tunneler    啟動 core/gnb Tunneler"
	@echo "    sudo make gnb         啟動 gNB"
	@echo "    sudo make ue          啟動 UE"
	@echo ""
	@echo "  一鍵流程："
	@echo "    sudo make rebuild     clean-all 後依序完整重建"
	@echo "    sudo make resume      啟動既有環境"
	@echo ""
	@echo "  驗證與清理："
	@echo "    sudo make verify      被動驗證"
	@echo "    sudo make verify-active 主動驗證"
	@echo "    sudo make stop-all    停止所有服務"
	@echo "    make clean            清理 runtime 資料"
	@echo "    make clean-all        清理 PKI/data/logs"
	@echo ""

dirs:
	mkdir -p $(BIN_DIR) $(PKI_DIR)/identities
	mkdir -p $(DATA_DIR) $(LOG_DIR)
	mkdir -p $(POLICY_DIR) $(SCRIPTS_DIR)
	@echo "✓ 目錄建立完成"

# =============================================================================
# 下載預編譯 binary
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
# 從原始碼編譯
# =============================================================================
build-from-source: dirs
	@echo ">>> clone openziti/ziti source code..."
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
# 安裝 ziti-edge-tunnel
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

build-n2-gateway: dirs
	@echo ">>> 編譯 N2 SCTP-aware gateway..."
	cd $(PROJECT_DIR)/n2-gateway && go build -o $(N2GW) ./cmd/n2-sctp-gateway
	chmod +x $(N2GW)
	@echo "✓ N2 gateway 已編譯完成"

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

controller-init:
	@echo ">>> 初始化 Controller 資料庫..."
	$(ZITI) controller edge init $(CTRL_CFG) \
		-u "$(ADMIN_USER)" -p "$(ADMIN_PASS)"
	@echo "$(ADMIN_PASS)" > .admin-password
	@chmod 600 .admin-password
	@echo "✓ Controller 初始化完成（密碼存於 .admin-password）"

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

controller: controller-init start-controller
	@echo "✓ Controller 流程完成"

router-init: login
	@echo ">>> 建立 Edge Router..."
	$(ZITI) edge create edge-router main-router \
		-o $(DATA_DIR)/main-router.jwt \
		-a "public" --tunneler-enabled || true
	@echo ">>> Enroll Router..."
	$(ZITI) router enroll $(ROUTER_CFG) \
		--jwt $(DATA_DIR)/main-router.jwt
	@echo "✓ Router 註冊完成"

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

router: router-init start-router
	@echo "✓ Router 流程完成"

login:
	@echo ">>> 登入 Ziti Controller..."
	$(ZITI) edge login https://$(CTRL_HOST):$(CTRL_MGMT_PORT) \
		-u "$(ADMIN_USER)" -p "$(ADMIN_PASS)" \
		--yes

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

enroll-gnb:
	@for jwt in $(PKI_DIR)/identities/gnb-*.jwt; do \
		name=$$(basename $$jwt .jwt); \
		json="$(PKI_DIR)/identities/$$name.json"; \
		if [ ! -f $$json ] || [ $$jwt -nt $$json ]; then \
			echo ">>> Enrolling $$name ..."; \
			rm -f $$json; \
			$(ZET) enroll --jwt $$jwt \
				--identity $$json; \
		else \
			echo "[skip] $$name 已 enroll"; \
		fi \
	done
	@echo "✓ gNB Identity enroll 完成"

enroll-core:
	@for jwt in $(PKI_DIR)/identities/core-*.jwt; do \
		name=$$(basename $$jwt .jwt); \
		json="$(PKI_DIR)/identities/$$name.json"; \
		if [ ! -f $$json ] || [ $$jwt -nt $$json ]; then \
			echo ">>> Enrolling $$name ..."; \
			rm -f $$json; \
			$(ZET) enroll --jwt $$jwt \
				--identity $$json; \
		else \
			echo "[skip] $$name 已 enroll"; \
		fi \
	done
	@echo "✓ Core Identity enroll 完成"

enroll: enroll-gnb enroll-core
	@echo "✓ 全部 Identity enroll 完成"

start-tunnel-core: build-n2-gateway
	@echo ">>> 在 core-ns 內啟動 Tunneler (run-host 模式)..."
	@echo ">>> 準備 core-side host identities ..."
	@mkdir -p $(DATA_DIR)/core-host-identities
	@cp -f $(PKI_DIR)/identities/core-amf-host.json $(DATA_DIR)/core-host-identities/ 2>/dev/null || true
	@cp -f $(PKI_DIR)/identities/core-upf-host.json $(DATA_DIR)/core-host-identities/ 2>/dev/null || true
	@echo ">>> 清理 core-ns 舊的 tunnel/N2 gateway ..."
	-@if [ -f $(DATA_DIR)/tunnel-core.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/tunnel-core.pid) 2>/dev/null || true; \
		rm -f $(DATA_DIR)/tunnel-core.pid; \
	fi
	-@if [ -f $(DATA_DIR)/n2gw-core.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/n2gw-core.pid) 2>/dev/null || true; \
		rm -f $(DATA_DIR)/n2gw-core.pid; \
	fi
	-@if [ -f $(DATA_DIR)/tunnel-core-dial.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/tunnel-core-dial.pid) 2>/dev/null || true; \
		rm -f $(DATA_DIR)/tunnel-core-dial.pid; \
	fi
	-sudo ip netns exec core-ns pkill -f "n2-sctp-gateway --mode core" 2>/dev/null || true
	-sudo ip netns exec core-ns ip link del ziti0 2>/dev/null || true
	-sudo ip netns exec core-ns ip link del ziti1 2>/dev/null || true
	@sleep 1
	sudo ip netns exec core-ns \
		nohup $(ZET) run-host \
		--identity-dir $(DATA_DIR)/core-host-identities/ \
		--verbose 2 \
		> $(LOG_DIR)/tunnel-core.log 2>&1 &
	@sudo ip netns exec core-ns pgrep -f "ziti-edge-tunnel run-host" | tail -n1 > $(DATA_DIR)/tunnel-core.pid || true
	@sleep 2
	@echo "✓ Core Tunneler 已在 core-ns 內啟動"
	@echo ">>> 啟動 core-upf-dialer (run 模式，用於 N3 下行攔截)..."
	sudo ip netns exec core-ns \
		nohup $(ZET) run \
		--identity $(PKI_DIR)/identities/core-upf-dialer.json \
		--dns-ip-range "100.64.0.0/10" \
		--verbose 2 \
		> $(LOG_DIR)/tunnel-core-dial.log 2>&1 &
	@sudo ip netns exec core-ns pgrep -f "ziti-edge-tunnel run --identity $(PKI_DIR)/identities/core-upf-dialer.json" | tail -n1 > $(DATA_DIR)/tunnel-core-dial.pid || true
	@sleep 2
	@echo "✓ core-upf-dialer 已啟動（N3 downlink intercept）"
	@echo ">>> 啟動 N2 SCTP-aware gateway (core-ns 內)..."
	sudo ip netns exec core-ns \
		nohup $(N2GW) --mode core --udp-listen 127.0.0.1:38413 --amf-sctp 127.0.0.18:38412 \
		> $(LOG_DIR)/n2gw-core.log 2>&1 &
	@sudo ip netns exec core-ns pgrep -f "n2-sctp-gateway --mode core" | tail -n1 > $(DATA_DIR)/n2gw-core.pid || true
	@echo "✓ N2 core gateway 已啟動 (UDP:127.0.0.1:38413→SCTP:127.0.0.18:38412)"

start-tunnel-gnb: build-n2-gateway
	@echo ">>> 在 gnb-ns 內啟動 Tunneler (run/tproxy 模式)..."
	@echo ">>> 設定 gnb-ns DNS 指向 Ziti DNS (100.64.0.1)..."
	-sudo mkdir -p /etc/netns/gnb-ns
	-echo -e "nameserver 100.64.0.1\noptions timeout:1 attempts:1" | sudo tee /etc/netns/gnb-ns/resolv.conf >/dev/null
	@echo ">>> 清理 gnb-ns 舊的 tunnel/N2 gateway ..."
	-@if [ -f $(DATA_DIR)/tunnel-gnb.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/tunnel-gnb.pid) 2>/dev/null || true; \
		rm -f $(DATA_DIR)/tunnel-gnb.pid; \
	fi
	-@if [ -f $(DATA_DIR)/n2gw-gnb.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/n2gw-gnb.pid) 2>/dev/null || true; \
		rm -f $(DATA_DIR)/n2gw-gnb.pid; \
	fi
	-sudo ip netns exec gnb-ns pkill -f "n2-sctp-gateway --mode gnb" 2>/dev/null || true
	-sudo ip netns exec gnb-ns ip link del ziti0 2>/dev/null || true
	-sudo ip netns exec gnb-ns ip link del ziti1 2>/dev/null || true
	@sleep 1
	sudo ip netns exec gnb-ns \
		nohup $(ZET) run \
		--identity $(PKI_DIR)/identities/gnb-01.json \
		--dns-ip-range "100.64.0.0/10" \
		--verbose 2 \
		> $(LOG_DIR)/tunnel-gnb.log 2>&1 &
	@sudo ip netns exec gnb-ns pgrep -f "ziti-edge-tunnel run --identity" | tail -n1 > $(DATA_DIR)/tunnel-gnb.pid || true
	@sleep 3
	@echo "✓ gNB Tunneler 已在 gnb-ns 內啟動"
	@echo ">>> 添加 UPF 路由（tproxy 攔截需要）..."
	sudo ip netns exec gnb-ns \
		ip route add 10.10.2.0/24 via 10.10.1.1 2>/dev/null || true
	@echo ">>> 啟動 N2 SCTP-aware gateway (gnb-ns 內)..."
	sudo ip netns exec gnb-ns \
		nohup $(N2GW) --mode gnb --sctp-listen 127.0.0.1:38412 --udp-remote amf.ziti:38412 \
		> $(LOG_DIR)/n2gw-gnb.log 2>&1 &
	@sudo ip netns exec gnb-ns pgrep -f "n2-sctp-gateway --mode gnb" | tail -n1 > $(DATA_DIR)/n2gw-gnb.pid || true
	@echo "✓ N2 gNB gateway 已啟動 (SCTP:127.0.0.1:38412→UDP:amf.ziti:38412)"

start-core:
	@echo ">>> 在 core-ns 內啟動 free5gc..."
	sudo bash $(SCRIPTS_DIR)/start-core.sh start

stop-core:
	sudo bash $(SCRIPTS_DIR)/start-core.sh stop

core: start-core
	@echo "✓ Core 流程完成"

start-gnb:
	@echo ">>> 在 gnb-ns 內啟動 UERANSIM gNB..."
	sudo bash $(SCRIPTS_DIR)/start-gnb.sh start

start-ue:
	@echo ">>> 在 gnb-ns 內啟動 UERANSIM UE..."
	sudo bash $(SCRIPTS_DIR)/start-gnb.sh start-ue

stop-gnb:
	sudo bash $(SCRIPTS_DIR)/start-gnb.sh stop

tunneler: start-tunnel-core start-tunnel-gnb
	@echo "✓ Tunneler 流程完成"

gnb: start-gnb
	@echo "✓ gNB 流程完成"

ue: start-ue
	@echo "✓ UE 流程完成"

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
	@pgrep -a n2-sctp-gateway 2>/dev/null || echo "  N2 gateway: ✗ 未運行"
	@echo ""
	@echo "--- 已註冊的服務 ---"
	@$(ZITI) edge list services 2>/dev/null || echo "  (需先 make login)"
	@echo ""
	@echo "--- 已註冊的 Identity ---"
	@$(ZITI) edge list identities 2>/dev/null || echo "  (需先 make login)"


ns-create:
	@echo ">>> 建立三個 namespace (gnb-ns, router-ns, core-ns)..."
	sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh create

ns-delete:
	@echo ">>> 刪除所有 namespace..."
	sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh delete

ns-status:
	sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh status

verify:
	@echo ">>> 執行 OpenZiti 被動驗證..."
	sudo bash $(SCRIPTS_DIR)/verify-openziti.sh

verify-active:
	@echo ">>> 執行 OpenZiti 主動驗證..."
	sudo bash $(SCRIPTS_DIR)/verify-openziti.sh --active

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
	-@if [ -f $(DATA_DIR)/tunnel-core-dial.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/tunnel-core-dial.pid) 2>/dev/null; \
		rm -f $(DATA_DIR)/tunnel-core-dial.pid; \
	fi
	-@if [ -f $(DATA_DIR)/n2gw-gnb.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/n2gw-gnb.pid) 2>/dev/null; \
		rm -f $(DATA_DIR)/n2gw-gnb.pid; \
	fi
	-@if [ -f $(DATA_DIR)/n2gw-core.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/n2gw-core.pid) 2>/dev/null; \
		rm -f $(DATA_DIR)/n2gw-core.pid; \
	fi
	-$(MAKE) stop-router
	-$(MAKE) stop-controller
	-sudo pkill -f ziti-edge-tunnel 2>/dev/null || true
	-sudo pkill -f n2-sctp-gateway 2>/dev/null || true
	@echo "✓ 所有服務已停止"

resume: start-controller start-router start-core start-tunnel-core start-tunnel-gnb start-gnb start-ue
	@echo "✓ 所有服務已恢復運行"

clean: stop-all
	@echo ">>> 清理資料..."
	rm -rf $(PKI_DIR) $(DATA_DIR) $(LOG_DIR)
	rm -f .admin-password
	-sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh delete 2>/dev/null || true
	@echo "✓ 清理完成"

build: dirs ns-create pki controller router apply enroll core tunneler gnb ue
	@echo "✓ 已依序完成完整重建"

rebuild: clean build

install: download install-tunnel build
	@echo "✓ Binary 已準備就緒"