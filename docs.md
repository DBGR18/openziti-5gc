# openziti-5gc — Technical Documentation

This document provides a comprehensive technical reference for the openziti-5gc project: a zero-trust overlay that protects the N2, N3, and N4 interfaces of a free5gc 5G core network using OpenZiti mTLS tunnels.

---

## Table of Contents

1. [What is OpenZiti?](#1-what-is-openziti)
2. [Why a 5G Core Needs Zero Trust](#2-why-a-5g-core-needs-zero-trust)
3. [OpenZiti Core Concepts](#3-openziti-core-concepts)
4. [Three-Namespace Topology](#4-three-namespace-topology)
5. [PKI Design](#5-pki-design)
6. [Controller Configuration](#6-controller-configuration)
7. [Router Configuration](#7-router-configuration)
8. [Services, Identities, and Policies](#8-services-identities-and-policies)
9. [N2 SCTP Gateway](#9-n2-sctp-gateway)
10. [Data-Flow Analysis](#10-data-flow-analysis)
11. [Step-by-Step Deployment](#11-step-by-step-deployment)
12. [Verification and Packet Capture](#12-verification-and-packet-capture)
13. [Troubleshooting](#13-troubleshooting)
14. [Multi-Host Deployment](#14-multi-host-deployment)

---

## 1. What is OpenZiti?

[OpenZiti](https://openziti.io/) is an open-source **zero-trust network overlay** platform developed by NetFoundry. It builds an encrypted, identity-verified overlay on top of any existing IP network, so applications communicate without exposing traditional listening ports.

### Key Characteristics

| Property | Description |
|----------|-------------|
| **Zero-trust** | Every connection requires authentication and authorization; all traffic is denied by default |
| **End-to-end mTLS** | All fabric traffic is encrypted with mutual TLS (mTLS) |
| **No open ports** | Services never listen on public network interfaces, eliminating remote attack surface |
| **Identity-based** | Cryptographic identities replace IP addresses as the trust anchor |
| **Fine-grained access** | Service Policies define exactly which identities can reach which services |
| **Embeddable SDK** | Go, C, Python SDKs let applications join Ziti natively |

### Comparison with Traditional VPN

```
Traditional VPN:
  User → VPN gateway → receives full network access → can reach all internal resources

OpenZiti:
  User → Ziti Tunneler → Ziti Fabric → can only reach explicitly authorized services
```

---

## 2. Why a 5G Core Needs Zero Trust

### Security Gaps in Standard 5G Interfaces

| Interface | Purpose | Protocol | Port |
|-----------|---------|----------|------|
| **N2 (NGAP)** | Control plane: gNB ↔ AMF | SCTP | 38412 |
| **N3 (GTP-U)** | User plane: gNB ↔ UPF | UDP | 2152 |
| **N4 (PFCP)** | Control plane: SMF ↔ UPF | UDP | 8805 |
| **SBI** | Inter-NF communication | HTTP/2 (TCP) | Various |

In a conventional deployment these interfaces suffer from:

1. **Plaintext transport** — SCTP and GTP-U carry no native encryption
2. **Fixed exposed ports** — AMF must listen on 38412; any host that can reach it can attempt a connection
3. **IP-based trust** — source IP is the only identity check
4. **No per-gNB control** — a compromised base station can contact the core without restriction

### How OpenZiti Addresses These Gaps

```
Before (traditional):
  gNB ──── SCTP:38412 (plaintext) ────► AMF  (port open, IP-trusted)
  gNB ──── UDP:2152   (plaintext) ────► UPF

After (Ziti overlay):
  gNB ─► n2-gateway ─► Tunneler ─► Ziti Fabric (mTLS) ─► Tunneler ─► n2-gateway ─► AMF
  gNB ─► Tunneler  (run/TUN) ───► Ziti Fabric (mTLS) ──────────────► Tunneler  ─► UPF
         │
         ● AMF/UPF expose no ports on the network
         ● Every gNB has a unique cryptographic identity (revocable)
         ● Service Policies enforce per-identity, per-service access
```

---

## 3. OpenZiti Core Concepts

### 3.1 Controller

The **Controller** is the Ziti control plane. It handles:

- **PKI management** — issues and manages x509 certificates for all identities
- **Identity enrollment** — processes JWT-based enrollment, issues credentials
- **Policy engine** — evaluates Service Policies (Dial / Bind) for every connection request
- **Management API** — REST API on port 1280 for the CLI (`ziti edge ...`) and the web console
- **Control plane listener** — port 6262 for Edge Routers to connect to

### 3.2 Edge Router

The **Edge Router** is the data-plane forwarding node. It:

- Terminates mTLS connections from Tunnelers (Edge listener port 3022)
- Forwards encrypted payloads through the Ziti Fabric
- In a multi-router deployment, Routers interconnect via Fabric Links to form a mesh

### 3.3 Identity

An **Identity** is the authentication unit for every endpoint:

- Enrolled via a one-time JWT token; enrollment produces an x509 credential JSON file
- Carries **Role Attributes** (e.g., `gnb-side`, `core-side`) that Service Policies match against
- Can be revoked instantly without changing network configuration

### 3.4 Service

A **Service** is a named, addressable network endpoint with two configurations:

- **Intercept Config** — the virtual address and port that the Dial side uses (`amf.ziti:38412`)
- **Host Config** — the real address the Bind side delivers traffic to (`127.0.0.1:38413`)

### 3.5 Service Policy

Service Policies implement zero-trust access control:

| Type | Meaning |
|------|---------|
| **Dial** | Which identities can initiate a connection to a service |
| **Bind** | Which identities can host (accept connections for) a service |

Role attributes on identities and services are matched using `#role-name` selectors.

### 3.6 Tunneler (`ziti-edge-tunnel`)

The **Tunneler** is a local proxy agent deployed on each endpoint host:

| Mode | Used on | Behavior |
|------|---------|----------|
| `run` (TUN) | gNB side | Creates `ziti0` and steers matched destinations (e.g., `amf.ziti`, `10.10.2.2`) through the overlay; also provides DNS for `.ziti` names |
| `run-host` | Core side | Only hosts (binds) services; delivers Ziti traffic to local service addresses |

#### Current Intercept Mode (Observed)

Current runtime verification in this project shows `ziti-edge-tunnel run` operating in **TUN mode**:

- `ziti0` exists in `gnb-ns` and `core-ns`
- `iptables -t mangle` has no TPROXY redirect rules for Ziti interception
- Destination routes such as `10.10.2.2 dev ziti0` steer traffic into the overlay

For this codebase, the effective path is route-based interception via `ziti0`, not iptables TPROXY redirection.

---

## 4. Three-Namespace Topology

To simulate a multi-machine deployment on a single host, the project uses Linux **Network Namespaces** with veth pairs to create three fully isolated networks.

```
  ┌──────────────────┐        ┌──────────────────────────────────┐       ┌──────────────────────┐
  │     gnb-ns       │        │           router-ns              │       │       core-ns         │
  │  10.10.1.2/24    │◄──────►│  10.10.1.1 / 10.10.2.1          │◄─────►│  10.10.2.2/24         │
  │                  │veth    │  10.10.3.1 (host-facing)         │veth   │  10.10.4.1/24 (N6 out)│
  └──────────────────┘        └──────────────────────────────────┘       └──────────────────────┘
                                         ▲ veth                                     ▲ veth
                                  Host (10.10.3.2)                          Host (10.10.4.2)
                                  (management CLI)                          (N6 NAT / internet)
```

### Namespace Roles

| Namespace | IP Addresses | Components |
|-----------|-------------|------------|
| **gnb-ns** | 10.10.1.2/24 | UERANSIM gNB, `ziti-edge-tunnel run` (TUN mode), `n2-sctp-gateway` (gnb mode) |
| **router-ns** | 10.10.1.1, 10.10.2.1, 10.10.3.1 | Ziti Controller, Ziti Edge Router |
| **core-ns** | 10.10.2.2/24, 10.10.4.1/24 | free5gc NFs, `ziti-edge-tunnel run-host`, `ziti-edge-tunnel run` (core-upf-dialer), `n2-sctp-gateway` (core mode) |
| **Host** | 10.10.3.2/24, 10.10.4.2/24 | CLI management, N6 NAT |

### Isolation Rules

`router-ns` has IP forwarding enabled but iptables rules explicitly drop gnb ↔ core direct forwarding:

```bash
# Inside router-ns
iptables -A FORWARD -s 10.10.1.0/24 -d 10.10.2.0/24 -j DROP
iptables -A FORWARD -s 10.10.2.0/24 -d 10.10.1.0/24 -j DROP
iptables -A FORWARD -s 10.10.3.0/24 -j ACCEPT   # management
iptables -A FORWARD -d 10.10.3.0/24 -j ACCEPT
```

This guarantees **all gNB traffic must traverse the Ziti Fabric** to reach the core. N6 (UE internet) traffic travels via the dedicated `core-ns ↔ Host` 10.10.4.0/24 link.

### Why Namespaces Are Necessary

| Problem without namespaces | Cause |
|---------------------------|-------|
| Two Tunnelers conflict | Multiple `run` instances can interfere if route/table state is shared outside isolated namespaces |
| Route table pollution | `ip rule` / `ip route` changes from tunnel processes can pollute a shared host routing context |
| No isolation | Programs on the same host share loopback and can bypass Ziti entirely |

Each namespace has its own iptables, routing table, `lo`, and tunnel interfaces — completely independent.

---

## 5. PKI Design

OpenZiti requires a complete PKI to establish trust chains between all components.

### Certificate Hierarchy

```
5GC-Ziti-Root-CA                 ← Self-signed root CA
├── ctrl-intermediate             ← Controller intermediate CA (signs identities)
├── ctrl-server.chain.pem         ← Controller TLS server certificate (SAN: all IPs)
├── ctrl-client.cert              ← Controller client certificate
├── router-server.chain.pem       ← Router TLS server certificate (SAN: all IPs)
└── router-client.cert            ← Router client certificate
```

### SAN Requirements

Because the Controller and Router are accessed from multiple namespaces, their certificates must include SANs for all relevant IPs:

```bash
# Used in `make pki`
--dns "localhost,ziti-controller"
--ip  "127.0.0.1,10.10.1.1,10.10.2.1,10.10.3.1"
```

| IP | Accessed from |
|----|---------------|
| 127.0.0.1 | Local (router-ns) |
| 10.10.1.1 | gnb-ns |
| 10.10.2.1 | core-ns |
| 10.10.3.1 | Host (management) |

### Generating PKI

```bash
make pki
# Produces: pki/ca/certs/, pki/ca/keys/, pki/ca/cas/
```

Identity credentials (JSON files used by `ziti-edge-tunnel`) are generated separately during the enroll phase and stored under `pki/identities/`.

---

## 6. Controller Configuration

Key sections from `controller/ctrl-config.yaml`:

```yaml
v: 3
db: data/ctrl.db

identity:
  cert:        pki/ca/certs/ctrl-client.cert
  key:         pki/ca/keys/ctrl-client.key
  ca:          pki/ca/cas/ca.cert
  server_cert: pki/ca/certs/ctrl-server.chain.pem
  server_key:  pki/ca/keys/ctrl-server.key

ctrl:
  listener: tls:0.0.0.0:6262
  options:
    advertiseAddress: tls:10.10.3.1:6262   # routable from host / other namespaces

edge:
  enrollment:
    signingCert:
      cert: pki/ca/certs/ctrl-intermediate.cert
      key:  pki/ca/keys/ctrl-intermediate.key
  api:
    listener: 0.0.0.0:1280
    advertise: 10.10.3.1:1280
```

The Controller runs inside **router-ns**. The Makefile launches it with `sudo ip netns exec router-ns`.

---

## 7. Router Configuration

Key sections from `router/router-config.yaml`:

```yaml
v: 3

ctrl:
  endpoint: tls:127.0.0.1:6262     # same namespace as controller → use localhost

listeners:
  - binding: edge
    address: tls:0.0.0.0:3022
    options:
      advertise: 10.10.1.1:3022    # gnb-ns connects via this IP
      maxConnections: 32768

edge:
  csr:
    sans:
      ip:
        - "127.0.0.1"
        - "10.10.1.1"    # gnb-ns → router-ns
        - "10.10.2.1"    # core-ns → router-ns
        - "10.10.3.1"    # host → router-ns
```

The Router also runs inside **router-ns**, communicating with the Controller over localhost, while Tunnelers from gnb-ns and core-ns connect to it via their respective veth addresses.

---

## 8. Services, Identities, and Policies

### 8.1 Service Definitions

Defined in `policies/services.yml`:

| Service | Interface | Intercept | Ziti Transport | Host Delivery |
|---------|-----------|-----------|----------------|---------------|
| `n2-ngap-service` | N2 NGAP | `amf.ziti:38412` UDP | UDP (SCTP metadata preserved by n2-gateway) | `127.0.0.1:38413` UDP |
| `n3-gtpu-service` | N3 GTP-U uplink | `10.10.2.2:2152` UDP | UDP | `10.10.2.2:2152` UDP |
| `n3-gtpu-dl-service` | N3 GTP-U downlink | `10.10.1.2:2152` UDP | UDP | `10.10.1.2:2152` UDP |
| `n4-pfcp-service` | N4 PFCP | `upf-n4.ziti:8805` UDP | UDP | `127.0.0.8:8805` UDP |

The `roleAttributes` on each service (e.g., `control-plane`, `user-plane`) allow policies to reference groups of services without listing them by name.

### 8.2 Identity Definitions

Defined in `policies/identities.yml`:

| Identity | Role Attributes | Purpose |
|----------|----------------|---------|
| `gnb-01` | `gnb-side`, `region-north` | UERANSIM gNB in gnb-ns |
| `core-amf-host` | `core-side`, `control-plane-host` | Hosts N2 service (AMF) |
| `core-upf-host` | `core-side`, `user-plane-host` | Hosts N3/N4 services (UPF) |
| `core-upf-dialer` | `core-side`, `user-plane-dialer` | Dials N3 downlink service (UPF → gNB) |

Role attributes are the mechanism Service Policies use to select groups of identities without enumerating names.

### 8.3 Service Policies

Defined in `policies/service-policies.yml`:

| Policy | Type | Identity Role | Service Role | Effect |
|--------|------|---------------|-------------|--------|
| `gnb-dial-n2-n3` | Dial | `#gnb-side` | `#control-plane`, `#user-plane` | All gNBs can initiate N2 and N3 UL |
| `core-bind-n2` | Bind | `#control-plane-host` | `#control-plane` | AMF host provides N2 endpoint |
| `core-bind-n3-n4` | Bind | `#user-plane-host` | `#user-plane`, `#pfcp-plane` | UPF host provides N3 UL and N4 |
| `gnb-bind-n3-downlink` | Bind | `#gnb-side` | `#user-plane-downlink` | gNB provides N3 DL receive endpoint |
| `core-dial-n3-downlink` | Dial | `#user-plane-dialer` | `#user-plane-downlink` | core-upf-dialer sends N3 DL into Ziti |

### 8.4 Edge Router Policies

Defined in `policies/edge-router-policies.yml`:

```yaml
edgeRouterPolicies:
  - name: gnb-use-all-routers
    identityRoles: ["#gnb-side"]
    edgeRouterRoles: ["#all"]

  - name: core-use-all-routers
    identityRoles: ["#core-side"]
    edgeRouterRoles: ["#all"]

serviceEdgeRouterPolicies:
  - name: core-services-all-routers
    serviceRoles: ["#core-services"]
    edgeRouterRoles: ["#all"]
```

In a multi-router deployment, these can be tightened to route specific gNBs through specific regional Routers.

---

## 9. N2 SCTP Gateway

### Why a Custom Gateway?

`ziti-edge-tunnel` supports TCP and UDP interception natively, but **not SCTP**. The N2 interface (NGAP) uses SCTP as its transport. A simple SCTP↔TCP conversion (e.g., with socat) would strip SCTP-specific metadata:

- **PPID (Payload Protocol Identifier)** — identifies the NGAP payload type
- **Stream ID** — SCTP's multi-stream demultiplexing mechanism

Losing this metadata causes NGAP to malfunction. The project therefore includes a custom **`n2-sctp-gateway`** (Go, located in `n2-gateway/`) that encapsulates full SCTP frames — including metadata — into UDP datagrams, transports them through the Ziti UDP tunnel, and reconstructs an SCTP connection on the far side.

### Gateway Modes

```
gnb-ns side:
  gNB (SCTP:38412) ──► n2-sctp-gateway --mode gnb
                          └─► encapsulate SCTP frame + metadata into UDP
                              └─► send to amf.ziti:38412 (routed into `ziti0` by Tunneler)
                                  └─► travels through Ziti Fabric as UDP

core-ns side:
  Ziti Fabric UDP ──► Tunneler run-host ──► delivers to 127.0.0.1:38413
                                             └─► n2-sctp-gateway --mode core
                                                   └─► decode UDP frame
                                                       └─► reconstruct SCTP → AMF(127.0.0.18:38412)
```

### Makefile Invocations

```bash
# Build
make build-n2-gateway
# Output: bin/n2-sctp-gateway

# gNB side (inside gnb-ns)
bin/n2-sctp-gateway --mode gnb \
    --sctp-listen 127.0.0.1:38412 \
    --udp-remote amf.ziti:38412

# Core side (inside core-ns)
bin/n2-sctp-gateway --mode core \
    --udp-listen 127.0.0.1:38413 \
    --amf-sctp 127.0.0.18:38412
```

### Port Numbering Rationale

The core-side gateway listens on UDP **38413** (not 38412) to avoid ambiguity: AMF itself already listens on SCTP 38412 at `127.0.0.18:38412`. Using a distinct port makes the signal path unambiguous: Ziti → gateway UDP:38413 → gateway reconstructs SCTP → AMF SCTP:38412.

---

## 10. Data-Flow Analysis

### 10.1 N2 NGAP Control Plane (gNB → AMF)

```
Step  Namespace  Component              Action
────  ─────────  ─────────────────────  ─────────────────────────────────────────────
  1   gnb-ns     UERANSIM gNB           Sends SCTP to 127.0.0.1:38412
  2   gnb-ns     n2-sctp-gateway (gnb)  Receives SCTP; encapsulates frame+metadata into UDP
                                        Sends UDP to amf.ziti:38412
  3   gnb-ns     ziti-edge-tunnel       Route/DNS match steers UDP to amf.ziti:38412 into ziti0
                 (run mode)             Dials n2-ngap-service through Ziti Fabric
  4   fabric     Ziti Edge Router       mTLS-encrypts and forwards to Bind side
  5   core-ns    ziti-edge-tunnel       Receives n2-ngap-service data
                 (run-host mode)        Delivers to host: 127.0.0.1:38413 (UDP)
  6   core-ns    n2-sctp-gateway (core) Receives UDP frame; reconstructs SCTP
                                        Sends SCTP to 127.0.0.18:38412
  7   core-ns    free5gc AMF            Receives NGAP SCTP message
```

### 10.2 N3 GTP-U User Plane — Uplink (gNB → UPF)

```
Step  Namespace  Component              Action
────  ─────────  ─────────────────────  ─────────────────────────────────────────────
  1   gnb-ns     UERANSIM gNB           Sends GTP-U UDP to 10.10.2.2:2152 (UPF addr)
  2   gnb-ns     ziti-edge-tunnel       Route `10.10.2.2 dev ziti0` sends UDP:2152 into overlay
                 (run mode)             Dials n3-gtpu-service through Ziti Fabric
  3   fabric     Ziti Edge Router       mTLS-encrypts and forwards
  4   core-ns    ziti-edge-tunnel       Delivers to host: 10.10.2.2:2152 (UDP)
                 (run-host mode)
  5   core-ns    free5gc UPF            Receives GTP-U packet
```

### 10.3 N3 GTP-U User Plane — Downlink (UPF → gNB)

```
Step  Namespace  Component              Action
────  ─────────  ─────────────────────  ─────────────────────────────────────────────
  1   core-ns    free5gc UPF            Sends GTP-U UDP to 10.10.1.2:2152 (gNB addr)
  2   core-ns    ziti-edge-tunnel       `run` identity dials n3-gtpu-dl-service for UDP:2152 downlink
                 (run mode, upf-dialer) Dials n3-gtpu-dl-service through Ziti Fabric
  3   fabric     Ziti Edge Router       mTLS-encrypts and forwards
  4   gnb-ns     ziti-edge-tunnel       Delivers to host: 10.10.1.2:2152 (UDP)
                 (run mode, gnb bind)
  5   gnb-ns     UERANSIM gNB           Receives GTP-U downlink packet
```

### 10.4 Packet Visibility by Capture Point

| Capture point | Should see | Should NOT see |
|---------------|-----------|----------------|
| `gnb-ns lo` | SCTP:38412 (gNB→gateway), UDP:38412 (gateway→Tunneler) | — |
| `gnb-ns veth-gnb` | TLS:3022 (Ziti Fabric, encrypted) | Plaintext SCTP / GTP-U |
| `router-ns veth-r-gnb` | TLS:3022 | Plaintext SCTP / GTP-U |
| `router-ns veth-r-core` | TLS:3022 | Plaintext SCTP / GTP-U |
| `core-ns veth-core` | TLS:3022 | — |
| `core-ns lo` | UDP:38413 (Ziti→gateway), SCTP:38412 (gateway→AMF), UDP:2152 (GTP-U) | — |

---

## 11. Step-by-Step Deployment

### Prerequisites

```bash
# OS: Ubuntu 22.04 / 24.04, Linux kernel 4.x+

# Required packages
sudo apt-get update
sudo apt-get install -y unzip curl jq

# yq (YAML processor, v4)
sudo curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    -o /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq

# free5gc and UERANSIM must already be built and configured
```

### Phase 1 — Create Directories and Download Binaries

```bash
cd ~/openziti-5gc
make dirs       # creates bin/, pki/, data/, logs/, policies/, scripts/
make download   # downloads ziti v1.6.13 and ziti-edge-tunnel v1.10.10
```

Build the N2 SCTP gateway from source:

```bash
make build-n2-gateway
# requires Go; output: bin/n2-sctp-gateway
```

### Phase 2 — Create Network Namespaces

```bash
sudo make ns-create

# Verify
sudo make ns-status
# Expected:
#   gnb-ns   10.10.1.2/24  ←→  router-ns 10.10.1.1/24
#   core-ns  10.10.2.2/24  ←→  router-ns 10.10.2.1/24
#   Host     10.10.3.2/24  ←→  router-ns 10.10.3.1/24
#   gnb-ns → core-ns: unreachable ✓
```

### Phase 3 — Generate PKI

```bash
make pki

# Verify
ls pki/ca/certs/   # ca.cert, ctrl-server.chain.pem, router-server.chain.pem, ...
ls pki/ca/keys/    # corresponding private keys
```

### Phase 4 — Initialize and Start the Controller

```bash
make controller-init    # initializes ctrl.db; saves admin password to .admin-password
make start-controller   # starts Controller in router-ns; waits for port 1280

# Verify
curl -sk https://10.10.3.1:1280/edge/client/v1/version | jq .data.version
```

### Phase 5 — Register and Start the Edge Router

```bash
make router-init    # logs in, creates edge-router JWT, enrolls router config
make start-router   # starts Router in router-ns

# Verify
make login
bin/ziti edge list edge-routers
# main-router   isOnline: true
```

### Phase 6 — Apply Services, Identities, and Policies

```bash
make apply

# This runs in order:
#   apply-services    → policies/services.yml
#   apply-identities  → policies/identities.yml
#   apply-policies    → policies/service-policies.yml + edge-router-policies.yml

# Verify
bin/ziti edge list services
bin/ziti edge list identities
bin/ziti edge list service-policies
```

### Phase 7 — Enroll Identities

```bash
make enroll-core   # enrolls core-amf-host, core-upf-host, core-upf-dialer → JSON files
make enroll-gnb    # enrolls gnb-01 → JSON file

# Verify
ls pki/identities/*.json
# gnb-01.json  core-amf-host.json  core-upf-host.json  core-upf-dialer.json
```

### Phase 8 — Start free5gc (core-ns)

```bash
sudo make core
# Runs scripts/start-core.sh, which inside core-ns starts:
#   MongoDB → UPF → NRF → AMF → SMF → UDR → PCF → UDM → NSSF → AUSF → CHF → NEF
```

### Phase 9 — Start Tunnelers and N2 Gateway

```bash
sudo make tunneler
# Starts in core-ns:
#   ziti-edge-tunnel run-host  (identity-dir: data/core-host-identities/)
#   ziti-edge-tunnel run       (identity: core-upf-dialer, for N3 downlink intercept)
#   n2-sctp-gateway --mode core
#
# Starts in gnb-ns:
#   ziti-edge-tunnel run       (identity: gnb-01, TUN mode)
#   n2-sctp-gateway --mode gnb
```

### Phase 10 — Start UERANSIM

```bash
sudo make gnb    # starts UERANSIM gNB in gnb-ns
sudo make ue     # starts UERANSIM UE in gnb-ns
```

The gNB configuration (`config/`) must point AMF address to the local n2-sctp-gateway:
```yaml
amfConfigs:
  - address: 127.0.0.1   # local gateway inside gnb-ns
    port: 38412
```

### One-Shot Deployment

```bash
sudo make rebuild   # clean-all → full rebuild from scratch
sudo make resume    # restart all services on an already-provisioned environment
```

---

## 12. Verification and Packet Capture

### Quick Status Check

```bash
make status
# Shows PID status for Controller, Router, Tunnelers, N2 gateways
# Lists registered services and identities
```

### Checking Namespace Network State

```bash
for ns in gnb-ns router-ns core-ns; do
  echo "=== $ns ==="
  sudo ip netns exec $ns ip addr show | grep -E 'inet |state'
  sudo ip netns exec $ns ss -tulnp 2>/dev/null | head -10
done
```

### N2 NGAP Packet Capture

```bash
# gnb-ns loopback — raw SCTP from gNB, UDP from gateway
sudo ip netns exec gnb-ns tcpdump -i lo -n 'sctp or udp port 38412'

# gnb-ns veth — should only see TLS:3022 (Ziti Fabric), no plaintext NGAP
sudo ip netns exec gnb-ns tcpdump -i veth-gnb -n port 3022

# router-ns — encrypted relay (both directions)
sudo ip netns exec router-ns tcpdump -i veth-r-gnb -n port 3022
sudo ip netns exec router-ns tcpdump -i veth-r-core -n port 3022

# core-ns loopback — gateway UDP:38413 inbound, SCTP:38412 outbound to AMF
sudo ip netns exec core-ns tcpdump -i lo -n 'udp port 38413 or sctp port 38412'
```

### N3 GTP-U Packet Capture

```bash
# gnb-ns — gNB sends GTP-U; route-based interception sends matching destination into ziti0
sudo ip netns exec gnb-ns tcpdump -i any -n 'udp port 2152'

# gnb-ns veth — should NOT see plaintext GTP-U (overlay path is carried as TLS:3022)
sudo ip netns exec gnb-ns tcpdump -i veth-gnb -n 'udp port 2152'
# Expected: no packets captured

# core-ns — GTP-U restored to plaintext after Ziti delivery
sudo ip netns exec core-ns tcpdump -i any -n 'udp port 2152'
```

### Isolation Verification

```bash
# Direct ping from gnb-ns to core-ns should fail
sudo ip netns exec gnb-ns ping -I veth-gnb -c 3 10.10.2.2

# router-ns DROP counter should increment
sudo ip netns exec router-ns iptables -L FORWARD -n -v | grep DROP
```

### Passive Verification Script

```bash
sudo make verify
# Runs scripts/verify-openziti.sh in passive mode
# Checks: TLS on veth-gnb, no plaintext SCTP/GTP-U on veth interfaces, DROP counter
```

### Side-by-Side Comparison

Open two terminals simultaneously:

```bash
# Terminal A — gnb-ns veth (only encrypted Ziti traffic)
sudo ip netns exec gnb-ns tcpdump -i veth-gnb -n -X -c 10

# Terminal B — core-ns loopback (plaintext after Ziti delivery)
sudo ip netns exec core-ns tcpdump -i lo -n -X -c 10 'sctp or udp port 2152'
```

- **Terminal A payload**: TLS ciphertext — unreadable, no protocol structure visible
- **Terminal B payload**: Recognizable NGAP / GTP-U headers in plaintext (inside the trusted Ziti domain)

### Save pcap for Wireshark

```bash
sudo ip netns exec gnb-ns   tcpdump -i veth-gnb -n -w /tmp/gnb-veth.pcap   -c 500 &
sudo ip netns exec router-ns tcpdump -i veth-r-gnb -n -w /tmp/router.pcap   -c 500 &
sudo ip netns exec core-ns   tcpdump -i lo -n -w /tmp/core-lo.pcap          -c 500 &

# After generating test traffic:
wireshark /tmp/gnb-veth.pcap &
wireshark /tmp/core-lo.pcap &
```

---

## 13. Troubleshooting

| Symptom | Diagnostic Command | Resolution |
|---------|-------------------|------------|
| Tunneler cannot connect to Router | `sudo ip netns exec gnb-ns curl -sk https://10.10.3.1:3022` | Check gnb-ns route pinning to 10.10.3.1 and verify Router cert SANs include 10.10.3.1 |
| `Address already in use` on port 38412 | `sudo ip netns exec gnb-ns ss -tlnp \| grep 38412` | Kill the occupying process; restart n2-gateway |
| Traffic not entering Ziti tunnel | `sudo ip netns exec gnb-ns ip route show` | Verify destination routes map to `ziti0` (e.g., `10.10.2.2 dev ziti0`) and `ziti-edge-tunnel run` is healthy |
| gNB fails to register with AMF | `tail -f logs/n2gw-gnb.log` | Confirm both n2-sctp-gateway and ziti-edge-tunnel are running in gnb-ns |
| N3 GTP-U not passing through | Check UPF gtpu bind address | Ensure `upfcfg.yaml` has `gtpu.addr: 10.10.2.2` |
| Plaintext GTP-U visible on veth-gnb | Route steering not effective | Check `ip route` in gnb-ns/core-ns and confirm `ziti0` exists; restart tunneler before gNB |
| Namespace veth unreachable | `sudo ip netns exec gnb-ns ip route` | Verify veth pair is up and the correct route exists |
| Controller JWT enrollment fails | `tail -f logs/controller.log` | Check that server cert SAN covers the IP the enrolling client uses |
| `ziti edge list` shows empty | `make login` not run | Run `make login` first (session token may have expired) |

### Clean Up and Start Over

```bash
make stop-all          # stop all managed processes
sudo make ns-delete    # remove all namespaces
make clean             # delete data/, logs/, enrolled identity JSONs (keeps binaries and config)
make clean-all         # delete PKI, data, logs, binaries
```

---

## 14. Multi-Host Deployment

The three-namespace topology maps directly to a real multi-machine deployment. Replace namespaces with separate VMs or physical hosts:

| Role | Single-machine NS | Multi-machine |
|------|------------------|---------------|
| Controller + Router | router-ns (10.10.3.1) | VM-1 (e.g., 192.168.1.10) |
| free5gc core + Core Tunneler | core-ns (10.10.2.2) | VM-2 (e.g., 192.168.1.20) |
| UERANSIM gNB + gNB Tunneler | gnb-ns (10.10.1.2) | VM-3 (e.g., 192.168.1.30) |

### Required Configuration Changes

1. **`Makefile`** — update `CTRL_HOST` and `ROUTER_HOST` to the Controller VM's public IP
2. **`ctrl-config.yaml`** — update `advertiseAddress` and `advertise` under `edge.api`
3. **`router-config.yaml`** — update `ctrl.endpoint` and the `advertise` address under `listeners`
4. **PKI** — run `make pki` with `--ip` SANs that include the real VM IPs
5. **Network Namespaces** — not needed; each host is naturally isolated

### Scaling Out

- **More gNBs**: add entries to `policies/identities.yml` (e.g., `gnb-02`, `gnb-03`), re-run `make apply-identities && make enroll-gnb`. Existing policies using `#gnb-side` apply automatically.
- **More Routers**: deploy additional Edge Routers for redundancy or geographic proximity; Ziti handles mesh routing.
- **Regional access control**: add `region-*` role attributes to gNB identities and create region-scoped Dial policies.
- **SBI protection**: uncomment SBI service entries in `policies/services.yml` to extend zero-trust to NF-to-NF HTTP/2 communication.
