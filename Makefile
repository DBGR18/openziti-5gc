# =============================================================================
# OpenZiti 5GC Overlay — Local Build and Deployment Makefile
# Used to protect free5gc N2/N3/N4 interfaces
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

# Ziti Version
ZITI_VERSION       := 1.6.13
TUNNEL_VERSION     := 1.10.10

# Network Parameters
# For 3-ns deployment, CTRL/ROUTER are in router-ns, use 10.10.3.1 (Host management side)
CTRL_HOST     := 10.10.3.1
CTRL_MGMT_PORT := 1280
CTRL_CTRL_PORT := 6262
ROUTER_HOST   := 10.10.3.1
ROUTER_EDGE_PORT := 3022
ADMIN_USER    := admin
ADMIN_PASS    := $(shell cat .admin-password 2>/dev/null || echo "Change!Me123")

# Ziti CLI path
ZITI          := $(BIN_DIR)/ziti
ZET           := $(BIN_DIR)/ziti-edge-tunnel
N2GW          := $(BIN_DIR)/n2-sctp-gateway
GO            := $(or $(shell command -v go 2>/dev/null),/usr/local/go/bin/go)

.PHONY: all help dirs download build-from-source install-tunnel \
	build-n2-gateway \
        pki controller-init router-init \
        start-controller start-router stop-controller stop-router \
        login apply apply-services apply-identities apply-policies \
        enroll-gnb enroll-core start-tunnel-gnb start-tunnel-core \
	verify-router-tls fix-router-server-cert \
	repair-pki \
        status clean systemd-install \
        ns-create ns-delete ns-status \
        start-core stop-core start-gnb stop-gnb \
	deploy stop-all verify verify-active \
	controller router enroll core tunneler gnb ue \
	rebuild clean-rebuild

# =============================================================================
# Instructions
# =============================================================================
help:
	@echo ""
	@echo "=== OpenZiti 5GC Three Namespace Deployment  ==="
	@echo ""
	@echo "  Mandatory Commands:"
	@echo "    make dirs             Create directories"
	@echo "    sudo make ns-create   Create namespaces"
	@echo "    make pki              Generate PKI"
	@echo "    make controller       Initialize and start Controller"
	@echo "    make router           Register and start Router"
	@echo "    make apply            Apply services/identities/policies"
	@echo "    make enroll           Enroll all Identities"
	@echo "    sudo make core        Start free5gc"
	@echo "    sudo make tunneler    Start core/gnb Tunnelers"
	@echo "    sudo make gnb         Start gNB"
	@echo "    sudo make ue          Start UE"
	@echo ""
	@echo "  One-click Workflow:"
	@echo "    sudo make rebuild     Clean-all followed by complete rebuild"
	@echo "    sudo make resume      Resume existing environment"
	@echo ""
	@echo "  Verification and Cleanup:"
	@echo "    sudo make verify      Passive verification"
	@echo "    sudo make verify-active Active verification"
	@echo "    sudo make stop-all    Stop all services"
	@echo "    make clean            Clean runtime data"
	@echo "    make clean-all        Clean PKI/data/logs"
	@echo ""

dirs:
	mkdir -p $(BIN_DIR) $(PKI_DIR)/identities
	mkdir -p $(DATA_DIR) $(LOG_DIR)
	mkdir -p $(POLICY_DIR) $(SCRIPTS_DIR)
	@echo "✓ Directories created"

# =============================================================================
# Download pre-built binaries
# =============================================================================
download: dirs
	@echo ">>> Downloading ziti v$(ZITI_VERSION) ..."
	curl -sL "https://github.com/openziti/ziti/releases/download/v$(ZITI_VERSION)/ziti-linux-amd64-$(ZITI_VERSION).tar.gz" \
		| tar xz -C $(BIN_DIR)/
	chmod +x $(BIN_DIR)/ziti
	@echo ">>> Downloading ziti-edge-tunnel v$(TUNNEL_VERSION) ..."
	curl -sL "https://github.com/openziti/ziti-tunnel-sdk-c/releases/download/v$(TUNNEL_VERSION)/ziti-edge-tunnel-Linux_x86_64.zip" \
		-o /tmp/zet.zip
	unzip -o /tmp/zet.zip -d $(BIN_DIR)/ && rm -f /tmp/zet.zip
	chmod +x $(BIN_DIR)/ziti-edge-tunnel
	$(ZITI) version
	@echo "✓ Download complete"

# =============================================================================
# Build from source
# =============================================================================
build-from-source: dirs
	@echo ">>> clone openziti/ziti source code..."
	@if [ ! -d /tmp/ziti-src ]; then \
		git clone --depth 1 --branch "v$(ZITI_VERSION)" \
			https://github.com/openziti/ziti.git /tmp/ziti-src; \
	fi
	@if [ ! -x "$(GO)" ]; then \
		echo "✗ Go compiler not found. Install Go or export GO=/path/to/go"; \
		exit 127; \
	fi
	@echo ">>> Building ziti (requires $$($(GO) version | awk '{print $$3}'))..."
	cd /tmp/ziti-src && $(GO) build -o $(BIN_DIR)/ziti ./ziti/
	chmod +x $(BIN_DIR)/ziti
	$(ZITI) version
	@echo "✓ Build from source complete"

# =============================================================================
# Install ziti-edge-tunnel
# =============================================================================
install-tunnel: dirs
	@echo ">>> Install ziti-edge-tunnel..."
	@if [ ! -f $(ZET) ]; then \
		curl -sL "https://github.com/openziti/ziti-tunnel-sdk-c/releases/download/v$(TUNNEL_VERSION)/ziti-edge-tunnel-Linux_x86_64.zip" \
			-o /tmp/zet.zip; \
		unzip -o /tmp/zet.zip -d $(BIN_DIR)/ && rm -f /tmp/zet.zip; \
		chmod +x $(ZET); \
	fi
	$(ZET) version || true
	@echo "✓ ziti-edge-tunnel installation complete"

build-n2-gateway: dirs
	@echo ">>> Building N2 SCTP-aware gateway..."
	@if [ ! -x "$(GO)" ]; then \
		echo "✗ Go compiler not found. Install Go or export GO=/path/to/go"; \
		exit 127; \
	fi
	cd $(PROJECT_DIR)/n2-gateway && $(GO) build -o $(N2GW) ./cmd/n2-sctp-gateway
	chmod +x $(N2GW)
	@echo "✓ N2 gateway build complete"

pki:
	@echo ">>> Generating PKI with safe script..."
	-@sudo rm -rf $(PKI_DIR) 2>/dev/null || true
	@mkdir -p $(PKI_DIR)
	-@sudo chown -R $$(id -u):$$(id -g) $(PKI_DIR) 2>/dev/null || true
	bash $(SCRIPTS_DIR)/pki-generate-safe.sh
	-@sudo chown -R $$(id -u):$$(id -g) $(PKI_DIR) 2>/dev/null || true
	@echo "✓ PKI certificates generation complete (located in $(PKI_DIR))"
	@echo ">>> Verifying PKI integrity..."
	@test -s $(PKI_DIR)/ca/certs/ca.cert || (echo "✗ CA cert missing or empty" && exit 1)
	@test -s $(PKI_DIR)/ca/keys/ca.key || (echo "✗ CA key missing or empty" && exit 1)
	@test -s $(PKI_DIR)/ca/certs/router-server.cert || (echo "✗ router-server cert missing or empty" && exit 1)
	@test -s $(PKI_DIR)/ca/keys/router-server.key || (echo "✗ router-server key missing or empty" && exit 1)
	@openssl x509 -in $(PKI_DIR)/ca/certs/router-server.cert -noout >/dev/null 2>&1 || (echo "✗ router-server.cert is not a valid certificate" && exit 1)
	@openssl pkey -in $(PKI_DIR)/ca/keys/router-server.key -noout >/dev/null 2>&1 || (echo "✗ router-server.key is not a valid key" && exit 1)
	@echo "✓ PKI integrity verified"

verify-router-tls:
	@echo ">>> Verifying router server cert/key pair..."
	@openssl x509 -in $(PKI_DIR)/ca/certs/router-server.cert -pubkey -noout >| $(DATA_DIR)/router-server.cert.pub 2>/dev/null; \
	openssl pkey -in $(PKI_DIR)/ca/keys/router-server.key -pubout >| $(DATA_DIR)/router-server.key.pub 2>/dev/null; \
	if diff -q $(DATA_DIR)/router-server.cert.pub $(DATA_DIR)/router-server.key.pub >/dev/null 2>&1; then \
		echo "  ✓ router-server cert/key pair valid"; \
	else \
		echo "  ✗ router-server cert/key mismatch"; \
		exit 1; \
	fi

repair-pki:
	@echo ">>> Repairing PKI using safe generation script..."
	-@sudo rm -rf $(PKI_DIR) 2>/dev/null || true
	@mkdir -p $(PKI_DIR)
	-@sudo chown -R $$(id -u):$$(id -g) $(PKI_DIR) 2>/dev/null || true
	bash $(SCRIPTS_DIR)/pki-generate-safe.sh
	-@sudo chown -R $$(id -u):$$(id -g) $(PKI_DIR) 2>/dev/null || true
	@$(MAKE) verify-router-tls
	@echo "✓ PKI repair complete"

fix-router-server-cert:
	@echo ">>> Checking router server cert/key pair (auto-heal if needed)..."
	@openssl x509 -in $(PKI_DIR)/ca/certs/router-server.cert -pubkey -noout >| $(DATA_DIR)/router-server.cert.pub 2>/dev/null; \
	openssl pkey -in $(PKI_DIR)/ca/keys/router-server.key -pubout >| $(DATA_DIR)/router-server.key.pub 2>/dev/null; \
	if diff -q $(DATA_DIR)/router-server.cert.pub $(DATA_DIR)/router-server.key.pub >/dev/null 2>&1; then \
		echo "  ✓ router-server cert/key pair valid"; \
	else \
		echo "  ✗ router-server cert/key mismatch detected, trying in-place regeneration..."; \
		openssl x509 -in $(PKI_DIR)/ca/certs/ca.cert -pubkey -noout >| $(DATA_DIR)/ca.cert.pub 2>/dev/null; \
		openssl pkey -in $(PKI_DIR)/ca/keys/ca.key -pubout >| $(DATA_DIR)/ca.key.pub 2>/dev/null; \
		if ! diff -q $(DATA_DIR)/ca.cert.pub $(DATA_DIR)/ca.key.pub >/dev/null 2>&1; then \
			echo "  ✗ Root CA cert/key mismatch. Running full PKI repair..."; \
			$(MAKE) repair-pki; \
			openssl x509 -in $(PKI_DIR)/ca/certs/router-server.cert -pubkey -noout >| $(DATA_DIR)/router-server.cert.pub 2>/dev/null; \
			openssl pkey -in $(PKI_DIR)/ca/keys/router-server.key -pubout >| $(DATA_DIR)/router-server.key.pub 2>/dev/null; \
			if diff -q $(DATA_DIR)/router-server.cert.pub $(DATA_DIR)/router-server.key.pub >/dev/null 2>&1; then \
				echo "  ✓ Recovered by full PKI repair"; \
				exit 0; \
			else \
				echo "  ✗ FATAL: PKI repaired but router-server pair still mismatched"; \
				exit 1; \
			fi; \
		fi; \
		$(ZITI) pki create server \
			--pki-root $(PKI_DIR) \
			--ca-name ca \
			--server-file router-server-regenerate \
			--dns "localhost,ziti-router" \
			--ip "127.0.0.1,10.10.1.1,10.10.2.1,10.10.3.1"; \
		if [ ! -f $(PKI_DIR)/ca/certs/router-server-regenerate.cert ] || [ ! -f $(PKI_DIR)/ca/keys/router-server-regenerate.key ]; then \
			echo "  ✗ FATAL: Regenerated router-server files not found"; \
			exit 1; \
		fi; \
		openssl x509 -in $(PKI_DIR)/ca/certs/router-server-regenerate.cert -pubkey -noout >| $(DATA_DIR)/router-server-regen.cert.pub; \
		openssl pkey -in $(PKI_DIR)/ca/keys/router-server-regenerate.key -pubout >| $(DATA_DIR)/router-server-regen.key.pub; \
		if ! diff -q $(DATA_DIR)/router-server-regen.cert.pub $(DATA_DIR)/router-server-regen.key.pub >/dev/null 2>&1; then \
			echo "  ✗ FATAL: Regenerated router-server cert/key still mismatch"; \
			exit 1; \
		fi; \
		cp -f $(PKI_DIR)/ca/certs/router-server-regenerate.cert $(PKI_DIR)/ca/certs/router-server.cert; \
		cp -f $(PKI_DIR)/ca/keys/router-server-regenerate.key $(PKI_DIR)/ca/keys/router-server.key; \
		echo "  ✓ Regenerated and replaced router-server cert/key pair"; \
	fi

controller-init:
	@echo ">>> Initializing Controller database..."
	$(ZITI) controller edge init $(CTRL_CFG) \
		-u "$(ADMIN_USER)" -p "$(ADMIN_PASS)"
	@echo "$(ADMIN_PASS)" > .admin-password
	@chmod 600 .admin-password
	@echo "✓ Controller initialization complete (password stored in .admin-password)"

start-controller:
	@echo ">>> Starting Controller in router-ns..."
	sudo ip netns exec router-ns nohup $(ZITI) controller run $(CTRL_CFG) > $(LOG_DIR)/controller.log 2>&1 &
	@sudo ip netns exec router-ns pgrep -f "$(ZITI) controller run $(CTRL_CFG)" | tail -n1 > $(DATA_DIR)/controller.pid || true
	@echo ">>> Waiting for Controller to be ready..."
	@timeout 15 bash -c 'until sudo ip netns exec router-ns nc -z $(CTRL_HOST) $(CTRL_MGMT_PORT); do sleep 1; done' || (echo "Startup timeout" && exit 1)
	@echo "✓ Controller started (PID: $$(cat $(DATA_DIR)/controller.pid 2>/dev/null || echo unknown))"

stop-controller:
	@if [ -f $(DATA_DIR)/controller.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/controller.pid) 2>/dev/null || true; \
		rm -f $(DATA_DIR)/controller.pid; \
		echo "✓ Controller stopped"; \
	else \
		echo "Controller is not running"; \
	fi

controller: controller-init start-controller
	@echo "✓ Controller workflow complete"

router-init: login
	@echo ">>> Creating Edge Router..."
	$(ZITI) edge create edge-router main-router \
		-o $(DATA_DIR)/main-router.jwt \
		-a "public" --tunneler-enabled || true
	@echo ">>> Enrolling Router..."
	$(ZITI) router enroll $(ROUTER_CFG) \
		--jwt $(DATA_DIR)/main-router.jwt
	@echo "✓ Router registration complete"

start-router: fix-router-server-cert
	@echo ">>> Starting Router in router-ns..."
	sudo ip netns exec router-ns \
		nohup $(ZITI) router run $(ROUTER_CFG) \
		> $(LOG_DIR)/router.log 2>&1 &
	@sudo ip netns exec router-ns pgrep -f "$(ZITI) router run $(ROUTER_CFG)" | tail -n1 > $(DATA_DIR)/router.pid || true
	@sleep 3
	@echo "✓ Router started (PID: $$(cat $(DATA_DIR)/router.pid 2>/dev/null || echo unknown))"

stop-router:
	@if [ -f $(DATA_DIR)/router.pid ]; then \
		sudo kill $$(cat $(DATA_DIR)/router.pid) 2>/dev/null || true; \
		rm -f $(DATA_DIR)/router.pid; \
		echo "✓ Router stopped"; \
	else \
		echo "Router is not running"; \
	fi

router: router-init start-router
	@echo "✓ Router workflow complete"

login:
	@echo ">>> Logging into Ziti Controller..."
	$(ZITI) edge login https://$(CTRL_HOST):$(CTRL_MGMT_PORT) \
		-u "$(ADMIN_USER)" -p "$(ADMIN_PASS)" \
		--yes

apply: login apply-services apply-identities apply-policies
	@echo ""
	@echo "✓ All services, identities, and policies applied!"

apply-services:
	@echo ">>> Applying Services..."
	$(SCRIPTS_DIR)/apply.sh services $(POLICY_DIR)/services.yml

apply-identities:
	@echo ">>> Applying Identities..."
	$(SCRIPTS_DIR)/apply.sh identities $(POLICY_DIR)/identities.yml

apply-policies:
	@echo ">>> Applying Policies..."
	$(SCRIPTS_DIR)/apply.sh policies $(POLICY_DIR)/service-policies.yml
	$(SCRIPTS_DIR)/apply.sh router-policies $(POLICY_DIR)/edge-router-policies.yml

enroll-gnb:
	@for jwt in $(PKI_DIR)/identities/gnb-*.jwt; do \
		name=$$(basename $$jwt .jwt); \
		json="$(PKI_DIR)/identities/$$name.json"; \
		echo ">>> Re-enrolling $$name ..."; \
		rm -f $$json; \
		$(ZET) enroll --jwt $$jwt \
			--identity $$json; \
		chmod 600 $$json; \
	done
	@echo "✓ gNB Identity enrollment complete"

enroll-core:
	@for jwt in $(PKI_DIR)/identities/core-*.jwt; do \
		name=$$(basename $$jwt .jwt); \
		json="$(PKI_DIR)/identities/$$name.json"; \
		echo ">>> Re-enrolling $$name ..."; \
		rm -f $$json; \
		$(ZET) enroll --jwt $$jwt \
			--identity $$json; \
		chmod 600 $$json; \
	done
	@echo "✓ Core Identity enrollment complete"

enroll: enroll-gnb enroll-core
	@echo "✓ All Identities enrollment complete"

start-tunnel-core: build-n2-gateway
	@echo ">>> Verifying controller and router are running..."
	@sudo ip netns exec router-ns pgrep -f "ziti controller run" >/dev/null || (echo "✗ Controller not running" && exit 1)
	@sudo ip netns exec router-ns pgrep -f "ziti router run" >/dev/null || (echo "✗ Router not running" && exit 1)
	@echo "✓ Controller and Router verified"
	@echo ">>> Starting Tunneler in core-ns (run-host mode)..."
	@echo ">>> Preparing core-side host identities ..."
	@mkdir -p $(DATA_DIR)/core-host-identities
	@rm -f $(DATA_DIR)/core-host-identities/config.json
	@rm -f $(DATA_DIR)/core-host-identities/*.json
	@cp -f $(PKI_DIR)/identities/core-amf-host.json $(DATA_DIR)/core-host-identities/ 2>/dev/null || true
	@cp -f $(PKI_DIR)/identities/core-upf-host.json $(DATA_DIR)/core-host-identities/ 2>/dev/null || true
	@test -s $(DATA_DIR)/core-host-identities/core-amf-host.json || (echo "✗ missing core-amf-host identity JSON" && exit 1)
	@test -s $(DATA_DIR)/core-host-identities/core-upf-host.json || (echo "✗ missing core-upf-host identity JSON" && exit 1)
	@echo ">>> Cleaning up old tunnel/N2 gateway in core-ns ..."
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
	@echo ">>> Pinning core->router transport path via veth-core..."
	sudo ip netns exec core-ns ip route replace 10.10.3.1/32 via 10.10.2.1 dev veth-core
	@sudo ip netns exec core-ns sh -c 'ip route get 10.10.3.1 | grep -q "dev veth-core"' \
		|| (echo "✗ core-ns route pin failed for 10.10.3.1" && exit 1)
	@sleep 1
	sudo ip netns exec core-ns \
		nohup $(ZET) run-host \
		--identity-dir $(DATA_DIR)/core-host-identities/ \
		--verbose 2 \
		> $(LOG_DIR)/tunnel-core.log 2>&1 &
	@sudo ip netns exec core-ns pgrep -f "ziti-edge-tunnel run-host" | tail -n1 > $(DATA_DIR)/tunnel-core.pid || true
	@sleep 2
	@echo "✓ Core Tunneler started in core-ns"
	@echo ">>> Starting core-upf-dialer (run mode, for N3 downlink interception)..."
	sudo ip netns exec core-ns \
		nohup $(ZET) run \
		--identity $(PKI_DIR)/identities/core-upf-dialer.json \
		--dns-ip-range "100.64.0.0/10" \
		--verbose 2 \
		> $(LOG_DIR)/tunnel-core-dial.log 2>&1 &
	@sudo ip netns exec core-ns pgrep -f "ziti-edge-tunnel run --identity $(PKI_DIR)/identities/core-upf-dialer.json" | tail -n1 > $(DATA_DIR)/tunnel-core-dial.pid || true
	@sleep 2
	@echo ">>> Re-applying core->router pin route after tunnel interfaces creation..."
	sudo ip netns exec core-ns ip route replace 10.10.3.1/32 via 10.10.2.1 dev veth-core
	@sudo ip netns exec core-ns sh -c 'ip route get 10.10.3.1 | grep -q "dev veth-core"' \
		|| (echo "✗ core-ns route pin lost after tunnel start" && exit 1)
	@echo "✓ core-upf-dialer started (N3 downlink intercept)"
	@echo ">>> Starting N2 SCTP-aware gateway (in core-ns)..."
	sudo ip netns exec core-ns \
		nohup $(N2GW) --mode core --udp-listen 127.0.0.1:38413 --amf-sctp 127.0.0.18:38412 \
		> $(LOG_DIR)/n2gw-core.log 2>&1 &
	@sudo ip netns exec core-ns pgrep -f "n2-sctp-gateway --mode core" | tail -n1 > $(DATA_DIR)/n2gw-core.pid || true
	@echo "✓ N2 core gateway started (UDP:127.0.0.1:38413→SCTP:127.0.0.18:38412)"

start-tunnel-gnb: build-n2-gateway
	@echo ">>> Starting Tunneler in gnb-ns (run/TUN mode)..."
	@echo ">>> Pinning gnb->router transport path via veth-gnb..."
	sudo ip netns exec gnb-ns ip route replace 10.10.3.1/32 via 10.10.1.1 dev veth-gnb
	@sudo ip netns exec gnb-ns sh -c 'ip route get 10.10.3.1 | grep -q "dev veth-gnb"' \
		|| (echo "✗ gnb-ns route pin failed for 10.10.3.1" && exit 1)
	@echo ">>> Setting gnb-ns DNS to Ziti DNS (100.64.0.1)..."
	-sudo mkdir -p /etc/netns/gnb-ns
	-echo -e "nameserver 100.64.0.1\noptions timeout:1 attempts:1" | sudo tee /etc/netns/gnb-ns/resolv.conf >/dev/null
	@echo ">>> Cleaning up old tunnel/N2 gateway in gnb-ns ..."
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
	@echo ">>> Re-applying gnb->router pin route after tunnel interfaces creation..."
	sudo ip netns exec gnb-ns ip route replace 10.10.3.1/32 via 10.10.1.1 dev veth-gnb
	@sudo ip netns exec gnb-ns sh -c 'ip route get 10.10.3.1 | grep -q "dev veth-gnb"' \
		|| (echo "✗ gnb-ns route pin lost after tunnel start" && exit 1)
	@echo "✓ gNB Tunneler started in gnb-ns"
	@echo ">>> Waiting for Ziti DNS record amf.ziti in gnb-ns..."
	@timeout 30 bash -c 'until sudo ip netns exec gnb-ns getent hosts amf.ziti >/dev/null 2>&1; do sleep 1; done' \
		|| (echo "✗ amf.ziti DNS is not ready; check $(LOG_DIR)/tunnel-gnb.log" && exit 1)
	@echo ">>> Adding UPF route (required for route-based tunnel interception)..."
	sudo ip netns exec gnb-ns \
		ip route add 10.10.2.0/24 via 10.10.1.1 2>/dev/null || true
	@echo ">>> Starting N2 SCTP-aware gateway (in gnb-ns)..."
	sudo ip netns exec gnb-ns \
		nohup $(N2GW) --mode gnb --sctp-listen 127.0.0.1:38412 --udp-remote amf.ziti:38412 \
		> $(LOG_DIR)/n2gw-gnb.log 2>&1 &
	@sudo ip netns exec gnb-ns pgrep -f "n2-sctp-gateway --mode gnb" | tail -n1 > $(DATA_DIR)/n2gw-gnb.pid || true
	@echo "✓ N2 gNB gateway started (SCTP:127.0.0.1:38412→UDP:amf.ziti:38412)"

start-core:
	@echo ">>> Start free5gc in core-ns..."
	sudo bash $(SCRIPTS_DIR)/start-core.sh start

stop-core:
	sudo bash $(SCRIPTS_DIR)/start-core.sh stop

core: start-core
	@echo "✓ Core workflow complete"

start-gnb:
	@echo ">>> Start UERANSIM gNB in gnb-ns..."
	sudo bash $(SCRIPTS_DIR)/start-gnb.sh start

start-ue:
	@echo ">>> Start UERANSIM UE in gnb-ns..."
	sudo bash $(SCRIPTS_DIR)/start-gnb.sh start-ue

stop-gnb:
	sudo bash $(SCRIPTS_DIR)/start-gnb.sh stop

tunneler: start-tunnel-core start-tunnel-gnb
	@echo "✓ Tunneler workflow complete"

gnb: start-gnb
	@echo "✓ gNB workflow complete"

ue: start-ue
	@echo "✓ UE workflow complete"

status:
	@echo ""
	@echo "=== OpenZiti 5GC Status ==="
	@echo ""
	@echo "--- Controller ---"
	@CTRL_PID=$$(sudo ip netns exec router-ns pgrep -f "$(ZITI) controller run $(CTRL_CFG)" | tail -n1); \
	if [ -n "$$CTRL_PID" ]; then \
		echo $$CTRL_PID > $(DATA_DIR)/controller.pid; \
		echo "  Status: ✓ Running (PID: $$CTRL_PID)"; \
	else \
		echo "  Status: ✗ Not running"; \
	fi
	@echo ""
	@echo "--- Router ---"
	@ROUTER_PID=$$(sudo ip netns exec router-ns pgrep -f "$(ZITI) router run $(ROUTER_CFG)" | tail -n1); \
	if [ -n "$$ROUTER_PID" ]; then \
		echo $$ROUTER_PID > $(DATA_DIR)/router.pid; \
		echo "  Status: ✓ Running (PID: $$ROUTER_PID)"; \
	else \
		echo "  Status: ✗ Not running"; \
	fi
	@echo ""
	@echo "--- Tunneler ---"
	@echo "  Ziti edge tunnel (core-ns):"
	@{ \
		sudo pgrep -a -f "^$(ZET) run-host --identity-dir $(DATA_DIR)/core-host-identities/"; \
		sudo pgrep -a -f "^$(ZET) run --identity $(PKI_DIR)/identities/core-upf-dialer.json"; \
	} 2>/dev/null || echo "    ✗ Not running"
	@echo "  Ziti edge tunnel (gnb-ns):"
	@sudo pgrep -a -f "^$(ZET) run --identity $(PKI_DIR)/identities/gnb-01.json" 2>/dev/null || echo "    ✗ Not running"
	@echo "  N2 gateway (core-ns):"
	@sudo pgrep -a -f "^$(N2GW) --mode core --udp-listen" 2>/dev/null || echo "    ✗ Not running"
	@echo "  N2 gateway (gnb-ns):"
	@sudo pgrep -a -f "^$(N2GW) --mode gnb --sctp-listen" 2>/dev/null || echo "    ✗ Not running"
	@echo ""
	@echo "--- Registered Services ---"
	@$(ZITI) edge list services 2>/dev/null || echo "  (need to run make login first)"
	@echo ""
	@echo "--- Registered Identities ---"
	@$(ZITI) edge list identities 2>/dev/null || echo "  (need to run make login first)"


ns-create:
	@echo ">>> Creating three namespaces (gnb-ns, router-ns, core-ns)..."
	sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh create

ns-delete:
	@echo ">>> Deleting all namespaces..."
	sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh delete

ns-status:
	sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh status

verify:
	@echo ">>> Executing OpenZiti Passive verification..."
	sudo bash $(SCRIPTS_DIR)/verify-openziti.sh

verify-active:
	@echo ">>> Executing OpenZiti Active verification..."
	sudo bash $(SCRIPTS_DIR)/verify-openziti.sh --active

stop-all:
	@echo ">>> Stop all services..."
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
	@echo "✓ All services stopped"

resume: start-controller start-router start-core start-tunnel-core start-tunnel-gnb start-gnb start-ue
	@echo "✓ All services resumed"

clean: stop-all
	@echo ">>> Cleaning up data..."
	-sudo rm -rf $(PKI_DIR) $(DATA_DIR) $(LOG_DIR) 2>/dev/null || true
	rm -rf $(PKI_DIR) $(DATA_DIR) $(LOG_DIR)
	rm -f .admin-password
	-sudo bash $(SCRIPTS_DIR)/setup-namespaces.sh delete 2>/dev/null || true
	@echo "✓ Cleanup complete"

build: dirs ns-create pki controller router apply enroll core tunneler gnb ue
	@echo "✓ Full rebuild completed"

rebuild: clean build

install: download install-tunnel build
	@echo "✓ Binary is ready"