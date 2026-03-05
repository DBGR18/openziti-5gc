# OpenZiti 介紹 — 以零信任網路保護 5G 核心網路

## 目錄

1. [什麼是 OpenZiti？](#1-什麼是-openziti)
2. [為什麼 5G 核心網路需要 OpenZiti？](#2-為什麼-5g-核心網路需要-openziti)
3. [OpenZiti 核心概念](#3-openziti-核心概念)
4. [系統架構總覽](#4-系統架構總覽)
5. [三 Namespace 隔離拓撲](#5-三-namespace-隔離拓撲)
6. [組件詳解](#6-組件詳解)
7. [服務與策略設計](#7-服務與策略設計)
8. [資料流路徑分析](#8-資料流路徑分析)
9. [具體實做步驟](#9-具體實做步驟)
10. [systemd 服務化管理](#10-systemd-服務化管理)
11. [驗證與疑難排解](#11-驗證與疑難排解)
12. [多機部署延伸](#12-多機部署延伸)

---

## 1. 什麼是 OpenZiti？

[OpenZiti](https://openziti.io/) 是一個開源的**零信任網路覆蓋層（Zero Trust Network Overlay）**平台，由 NetFoundry 主導開發。它在既有的 IP 網路之上建立一層**全加密、基於身份驗證**的覆蓋網路（Overlay Network），使應用程式之間的通訊不需要暴露任何傳統的網路端口。

### 核心特性

| 特性 | 說明 |
|---|---|
| **零信任架構** | 每個連線都需要身份驗證與授權，預設拒絕所有未明確允許的流量 |
| **端對端加密** | 所有透過 Ziti Fabric 的流量皆使用 mTLS（mutual TLS）加密 |
| **無需開放端口** | 服務端不需要對外開放任何 listening port，消除攻擊面 |
| **身份導向** | 以密碼學身份（Identity）取代 IP 位址作為信任基礎 |
| **細粒度存取控制** | 透過 Service Policy 精確控制「誰能存取什麼服務」 |
| **可嵌入式 SDK** | 提供 Go、C、Python 等 SDK，可直接嵌入應用程式 |

### 與傳統 VPN 的差異

```
傳統 VPN：
  使用者 → VPN 閘道 → 取得網路存取 → 可到達所有內部資源
                        ↑ 一旦進入就全通

OpenZiti：
  使用者 → Ziti Tunneler → Ziti Fabric → 僅可到達被授權的特定服務
                              ↑ 每個服務都需要獨立授權
```

---

## 2. 為什麼 5G 核心網路需要 OpenZiti？

### 5G 核心網路的安全挑戰

在 3GPP 定義的 5G 架構中，gNB（基站）與核心網路之間存在多個關鍵介面：

| 介面 | 用途 | 協議 | 端口 |
|---|---|---|---|
| **N2 (NGAP)** | 控制面：gNB ↔ AMF | SCTP | 38412 |
| **N3 (GTP-U)** | 用戶面：gNB ↔ UPF | UDP | 2152 |
| **N4 (PFCP)** | 控制面：SMF ↔ UPF | UDP | 8805 |
| **SBI** | 核網 NF 間通訊 | HTTP/2 (TCP) | 各 NF 不同 |

這些介面在傳統部署中存在嚴重的安全疑慮：

1. **明文傳輸**：SCTP 和 GTP-U 流量預設未加密
2. **固定端口暴露**：AMF 必須在 38412 端口等待連線進入
3. **IP 基礎信任**：僅依賴 IP 位址判斷來源是否合法
4. **無細粒度控制**：難以針對個別 gNB 實施差異化存取策略

### OpenZiti 如何解決

```
                    ┌─────────────────────────┐
   【傳統架構】      │  gNB ──SCTP:38412──→ AMF │  明文、固定IP、無驗證
                    │  gNB ──UDP:2152───→ UPF │
                    └─────────────────────────┘

                    ┌──────────────────────────────────────────────────┐
   【Ziti 保護】     │  gNB → socat → Tunneler → Ziti Fabric (mTLS)    │
                    │       → Tunneler → socat → AMF                  │
                    │                                                  │
                    │  ● 全程加密         ● AMF 不暴露端口              │
                    │  ● 身份驗證         ● 細粒度存取控制              │
                    └──────────────────────────────────────────────────┘
```

透過 OpenZiti，我們可以：

- **隱藏核心網路**：AMF、UPF 等不再對外暴露任何端口
- **加密所有介面**：N2、N3、N4 流量全部經過 mTLS 加密隧道
- **身份驗證每台 gNB**：每台基站有獨立的密碼學身份，可隨時撤銷
- **實施零信任策略**：按地區、角色、服務類型精確控制存取權限

---

## 3. OpenZiti 核心概念

### 3.1 Controller（控制器）

Controller 是 Ziti 網路的**大腦**，負責：

- **PKI 管理**：簽發與管理所有身份的憑證
- **身份註冊**：管理 Identity 的建立、Enroll 與撤銷
- **策略引擎**：評估 Service Policy，決定誰可以 Dial（呼叫）或 Bind（提供）哪些 Service
- **管理 API**：提供 REST API（預設端口 1280）供 CLI 或 Console 使用
- **控制面監聽**：提供 Router 連入的控制面端口（預設 6262）

```yaml
# Controller 設定摘要
ctrl:
  listener: tls:0.0.0.0:6262        # Router 連入
edge:
  api:
    listener: 0.0.0.0:1280           # 管理 API
```

### 3.2 Router（路由器）

Router 是 Ziti Fabric 的**資料轉發節點**，負責：

- **資料面路由**：在 Tunneler 之間轉發加密資料
- **Edge 接入**：提供 Tunneler / SDK 連入的 Edge 端口（預設 3022）
- **Fabric 互連**：多個 Router 之間建立 Link，形成 Mesh 拓撲

```yaml
# Router 設定摘要
ctrl:
  endpoint: tls:127.0.0.1:6262      # 連向 Controller
listeners:
  - binding: edge
    address: tls:0.0.0.0:3022       # Tunneler 連入
```

### 3.3 Identity（身份）

Identity 是 Ziti 的**認證基礎單元**，每個端點（gNB 主機、核網主機）都需要一個 Identity：

- **類型**：Device、Service、Router 等
- **角色標籤（Role Attributes）**：用於策略匹配（如 `gnb-side`、`core-side`）
- **Enrollment**：透過 JWT Token 完成首次註冊，取得 x509 憑證

```yaml
# Identity 範例
- name: gnb-01
  type: Device
  roleAttributes:
    - gnb-side
    - region-north
  enrollment:
    ott: true    # One-Time-Token
```

### 3.4 Service（服務）

Service 定義了一個**可被存取的網路端點**，包含兩個關鍵設定：

- **Intercept Config**：在「使用端」攔截流量的規則（虛擬地址 + 端口）
- **Host Config**：在「提供端」將流量送達的實際目的地

```yaml
# Service 範例：N2 NGAP
- name: n2-ngap-service
  configs:
    intercept:
      protocols: [tcp]
      addresses: [amf.ziti]       # gNB 側的虛擬地址
      portRanges: [{low: 38412, high: 38412}]
    host:
      protocol: tcp
      address: 127.0.0.1          # 核網側的實際地址
      port: 38413
```

### 3.5 Service Policy（存取策略）

Service Policy 定義**存取控制規則**，分為兩種：

| 類型 | 說明 | 範例 |
|---|---|---|
| **Dial** | 誰可以「呼叫」（連線到）服務 | gNB 可以 Dial N2、N3 |
| **Bind** | 誰可以「提供」（監聽）服務 | Core AMF 可以 Bind N2 |

```yaml
# Dial 策略：gNB 可存取 N2 和 N3
- name: gnb-dial-n2-n3
  type: Dial
  identityRoles: ["#gnb-side"]
  serviceRoles: ["#control-plane", "#user-plane"]

# Bind 策略：AMF 主機提供 N2
- name: core-bind-n2
  type: Bind
  identityRoles: ["#control-plane-host"]
  serviceRoles: ["#control-plane"]
```

### 3.6 Tunneler（隧道代理）

Tunneler（`ziti-edge-tunnel`）是部署在端點主機上的**代理程式**，有兩種運行模式：

| 模式 | 用途 | 功能 |
|---|---|---|
| **`run`**（tproxy） | 在 gNB 側 | 攔截本機發出的流量（intercept），透過 iptables/tproxy 實現透明代理 |
| **`run-host`** | 在核網側 | 只提供服務（host/bind），將 Ziti 收到的流量投遞到本機服務 |

#### 為什麼 gNB 側使用 tproxy 而非 tun？

`ziti-edge-tunnel run` 在 Linux 上支援兩種攔截模式：**tproxy**（透明代理，預設）和 **tun**（虛擬網卡）。本專案選擇 tproxy 模式，原因有以下幾點：

| 比較項目 | tproxy 模式 | tun 模式 |
|---|---|---|
| **攔截方式** | iptables `mangle` 表的 `TPROXY` target | 建立虛擬網卡 `ziti0`，透過路由表把流量導入 |
| **封包處理** | 核心層級攔截，**不修改封包**的 src/dst IP | 封包需經過 tun 介面，核心→使用者空間→核心，多一次拷貝 |
| **UDP 支援** | 原生支援，可透明攔截 UDP 並保留原始目的地址 | 需額外處理 UDP conntrack，對無連線的 GTP-U 封包可能丟失目的地資訊 |
| **效能** | 較高（核心內直接轉向，零拷貝） | 較低（封包需上下穿越使用者空間） |
| **與 socat 配合** | socat 發出的 TCP 連線被 `OUTPUT` chain + fwmark 路由攔截，完全透明 | 需把 `amf.ziti` 解析到 tun 介面 IP，並確保路由正確 |
| **Namespace 隔離** | iptables 規則綁定在 namespace 內，天然不洩漏到其他 namespace | tun 介面和路由可能與 veth 路由衝突 |

**關鍵考量：N3 GTP-U 是 UDP 協議**

5G 用戶面的 N3 介面使用 UDP:2152 傳輸 GTP-U 封包。tproxy 在 iptables mangle 表中運作：

```
iptables -t mangle -A PREROUTING -p udp --dport 2152 -d <upf.ziti IP> -j TPROXY \
    --tproxy-mark 0x1/0x1 --on-port <tunneler-listen-port>
```

這使得 Tunneler 能攔截 socat（TCP, N2）和 gNB 直接發出的 UDP（N3）兩種流量，無需修改目的地址，也不需要 NAT。而 tun 模式處理 UDP 時，因 UDP 是無連線協議，封包經 tun 介面後可能需要額外的 conntrack 和 DNAT 機制來保留原始目的地資訊，增加了複雜度與除錯難度。

**總結**：在 Network Namespace 隔離環境中，tproxy 更輕量、更透明、對 UDP 的處理更可靠，是本專案的最佳選擇。

---

## 4. 系統架構總覽

### 整體資料流

```
┌────────────────────────────────────────────────────────────────────────┐
│                          Ziti Fabric (mTLS)                           │
│                                                                        │
│   gNB 側                    Router                    核網側            │
│   ┌──────────┐         ┌────────────┐         ┌──────────────┐        │
│   │ UERANSIM │         │            │         │   free5gc    │        │
│   │   gNB    │         │  Ziti Edge │         │  AMF / UPF   │        │
│   │          │         │   Router   │         │  SMF / NRF   │        │
│   ├──────────┤         │  :3022     │         ├──────────────┤        │
│   │ socat    │───TCP──►│            │───TCP──►│ socat        │        │
│   │SCTP→TCP  │         │  (mTLS     │         │ TCP→SCTP     │        │
│   ├──────────┤         │  加密轉發)  │         ├──────────────┤        │
│   │ Tunneler │         │            │         │ Tunneler     │        │
│   │ (run)    │◄────────┤            ├────────►│ (run-host)   │        │
│   │ tproxy   │  Edge   │            │  Edge   │ host-only    │        │
│   └──────────┘         └────────────┘         └──────────────┘        │
└────────────────────────────────────────────────────────────────────────┘
```

### N2 (NGAP) 封裝流程

5G N2 介面（NGAP）使用 **SCTP** 協議，但 **OpenZiti 的 Tunneler 僅支援 TCP 和 UDP 的攔截與轉發**，不支援 SCTP。因此我們需要使用 `socat` 在 Ziti 隧道的兩端各做一次 SCTP ↔ TCP 的協議轉換。

#### 什麼是 socat？

[socat](http://www.dest-unreach.org/socat/)（**SOcket CAT**）是一個多用途的網路中繼工具，可以在**任意兩種通訊通道**之間建立雙向資料傳輸。它是 `netcat`（nc）的強化版本，但支援的協定遠超 TCP/UDP，包括：

- TCP / UDP / SCTP / Unix Socket
- SSL/TLS 加密連線
- FILE / STDIN / STDOUT / PIPE
- PROXY / SOCKS
- 串列埠（Serial port）

**核心運作原理**：socat 建立兩個端點（address），然後在它們之間雙向搬運資料：

```
socat <address1> <address2>

          ┌──────────┐      雙向資料流      ┌──────────┐
          │ address1 │ ◄──────────────────► │ address2 │
          └──────────┘                      └──────────┘
```

常用參數說明：

| 參數 | 說明 |
|---|---|
| `SCTP-LISTEN:port` | 監聽指定 port 的 SCTP 連線 |
| `TCP-LISTEN:port` | 監聽指定 port 的 TCP 連線 |
| `TCP:host:port` | 主動連線到指定 host:port（TCP） |
| `SCTP:host:port` | 主動連線到指定 host:port（SCTP） |
| `bind=IP` | 綁定到特定 IP 介面 |
| `fork` | 每個新連線 fork 子程式處理（支援多連線並行） |
| `reuseaddr` | 允許重複使用地址（避免 TIME_WAIT 期間無法重啟） |

#### N2 封裝的完整路徑

```
gNB (SCTP)                                                    AMF (SCTP)
    │                                                              ▲
    ▼                                                              │
┌──────────┐    ┌──────────┐    ┌────────┐    ┌──────────┐    ┌──────────┐
│ socat-gnb│    │ Tunneler │    │  Ziti  │    │ Tunneler │    │socat-core│
│ SCTP→TCP │───►│ intercept│───►│ Fabric │───►│   host   │───►│ TCP→SCTP │
│          │TCP │ (tproxy) │mTLS│(加密)  │mTLS│(run-host)│TCP │          │
└──────────┘    └──────────┘    └────────┘    └──────────┘    └──────────┘
```

逐步展開：

```
gNB (SCTP:38412)
  → socat-gnb (SCTP → TCP)
    → Tunneler intercept (攔截 amf.ziti:38412 TCP)
      → Ziti Fabric (mTLS 加密傳輸)
        → Tunneler host (投遞到 127.0.0.1:38413)
          → socat-core (TCP:38413 → SCTP:127.0.0.18:38412)
            → AMF (SCTP:38412)
```

#### N2 socat 配置

**gNB 側（gnb-ns 內）**— SCTP 轉 TCP：
```bash
# gNB 發出 SCTP:38412 → socat 接收後轉為 TCP → 連到 amf.ziti:38412
# amf.ziti 由 Tunneler DNS 解析為虛擬 IP，Tunneler tproxy 攔截此 TCP 連線
socat SCTP-LISTEN:38412,bind=127.0.0.1,fork,reuseaddr \
      TCP:amf.ziti:38412
```

**Core 側（core-ns 內）**— TCP 轉 SCTP：
```bash
# Tunneler host 把 Ziti 收到的流量投遞到 127.0.0.1:38413 (TCP)
# socat 接收後轉為 SCTP → 連到 AMF 的 127.0.0.18:38412
socat TCP-LISTEN:38413,bind=127.0.0.1,fork,reuseaddr \
      SCTP:127.0.0.18:38412
```

**為什麼端口不同（38413 vs 38412）？**

Core 側 socat 監聽 TCP **38413**（而非 38412），是為了**避免端口衝突**：AMF 本身已經在 `127.0.0.18:38412` 監聽 SCTP，若 socat 也在同 namespace 監聽 38412（即使是 TCP），在某些情況下可能造成混淆。使用不同的 TCP 端口可明確分離 Ziti → socat → AMF 的資料路徑。

> 如果未來 OpenZiti 原生支援 SCTP 攔截，則可移除 socat 層，直接讓 Tunneler 攔截 SCTP 流量。

### N3 (GTP-U) 流程

GTP-U 使用 UDP 協議，Ziti 可直接處理：

```
gNB (UDP:2152)
  → Tunneler tproxy 攔截 (目標: upf.ziti:2152)
    → Ziti Fabric (mTLS 加密傳輸)
      → Tunneler host (投遞到 127.0.0.8:2152)
        → UPF (UDP:2152)
```

---

## 5. 三 Namespace 隔離拓撲

為了在**單機上模擬真實的多機部署**，本專案使用 Linux Network Namespace 建立三個隔離的網路環境：

```
  ┌──────────┐         ┌──────────────┐         ┌──────────┐
  │  gnb-ns  │  veth   │  router-ns   │  veth   │  core-ns │
  │10.10.1.2 ├────────►│10.10.1.1     │         │          │
  │          │         │     10.10.2.1├───────► │10.10.2.2 │
  └──────────┘         │   10.10.3.1  │         └──────────┘
                       └──── ┬────────┘
                             │ veth
                    Host (10.10.3.2)
                    (管理 CLI / MongoDB)
```

### Namespace 配置

| Namespace | 用途 | IP 範圍 | 運行的組件 |
|---|---|---|---|
| **gnb-ns** | 模擬 gNB 端 | 10.10.1.2/24 | UERANSIM gNB、gNB-Tunneler（run 模式）、socat-gnb |
| **router-ns** | 模擬獨立 Router | 10.10.1.1, 10.10.2.1, 10.10.3.1 | Ziti Controller、Ziti Router |
| **core-ns** | 模擬核心網路 | 10.10.2.2/24 | free5gc 所有 NF、Core-Tunneler（run-host）、socat-core |
| **Host** | 管理用 | 10.10.3.2/24 | CLI 管理工具 |

### 隔離機制

```
gnb-ns ←─✗─→ core-ns    完全隔離！封包被 iptables DROP

gnb-ns  ←→  router-ns   10.10.1.0/24 可達
core-ns ←→  router-ns   10.10.2.0/24 可達
Host    ←→  router-ns   10.10.3.0/24 管理通道
```

**關鍵設定**：Router-ns 開啟 IP forwarding 但用 iptables 明確禁止 gnb ↔ core 直接轉發：

```bash
# router-ns 內的 iptables 規則
iptables -A FORWARD -s 10.10.1.0/24 -d 10.10.2.0/24 -j DROP
iptables -A FORWARD -s 10.10.2.0/24 -d 10.10.1.0/24 -j DROP
iptables -A FORWARD -s 10.10.3.0/24 -j ACCEPT           # 管理流量放行
iptables -A FORWARD -d 10.10.3.0/24 -j ACCEPT
```

這意味著 **gNB 的所有流量都必須經過 Ziti Fabric 才能到達核心網路**，精確模擬了零信任環境。

### 為什麼需要 Network Namespace？

| 問題 | 原因 |
|---|---|
| 兩個 Tunneler 衝突 | gNB 側 `run` 模式的 tproxy/iptables 規則會影響 Core 側流量 |
| 路由表污染 | tproxy 的 `ip rule/route` 是全域的，會影響所有程式 |
| 缺乏隔離 | 單一主機內的程式可直接通過 loopback 通訊，繞過 Ziti |

**Namespace 解法**：每個 namespace 有獨立的 iptables、路由表、lo 介面和 tun/tproxy 介面，互不干擾。

---

## 6. 組件詳解

### 6.1 PKI 憑證體系

OpenZiti 使用完整的 **PKI（Public Key Infrastructure）**來建立信任鏈：

```
5GC-Ziti-Root-CA                        ← 根 CA
├── Controller Signing CA               ← Controller 中繼 CA（簽發 Identity）
├── ctrl-server.cert                    ← Controller HTTPS/TLS 憑證
├── ctrl-client.cert                    ← Controller 驗證用客戶端憑證
├── router-server.cert                  ← Router TLS 憑證
└── router-client.cert                  ← Router 驗證用客戶端憑證
```

**SAN（Subject Alternative Name）** 配置至關重要，必須包含所有可能被連線的 IP/DNS 名稱：

```bash
# Controller 和 Router 的 SAN 必須涵蓋三個 namespace 的 IP
--dns "localhost,ziti-controller"
--ip "127.0.0.1,10.10.1.1,10.10.2.1,10.10.3.1"
```

### 6.2 Controller 設定

```yaml
# controller/ctrl-config.yaml (關鍵項目)
v: 3
db: data/ctrl.db

identity:
  cert:        pki/ca/certs/ctrl-client.cert
  key:         pki/ca/keys/ctrl-client.key
  ca:          pki/ca/cas/ca.cert
  server_cert: pki/ca/certs/ctrl-server.chain.pem
  server_key:  pki/ca/keys/ctrl-server.key

ctrl:
  listener: tls:0.0.0.0:6262               # Router 連入
  options:
    advertiseAddress: tls:10.10.3.1:6262    # 廣播地址

edge:
  enrollment:
    signingCert:
      cert: pki/ca/certs/ctrl-intermediate.cert
      key:  pki/ca/keys/ctrl-intermediate.key
  api:
    listener: 0.0.0.0:1280                  # 管理 API
    advertise: 10.10.3.1:1280
```

### 6.3 Router 設定

```yaml
# router/router-config.yaml (關鍵項目)
v: 3

ctrl:
  endpoint: tls:127.0.0.1:6262    # 同 namespace，用 localhost

listeners:
  - binding: edge
    address: tls:0.0.0.0:3022     # Tunneler 連入
    options:
      advertise: 10.10.1.1:3022   # gNB 透過此 IP 連入
      maxConnections: 32768

edge:
  csr:
    sans:
      ip:
        - "127.0.0.1"
        - "10.10.1.1"     # gnb → router
        - "10.10.2.1"     # core → router
        - "10.10.3.1"     # host → router
```

---

## 7. 服務與策略設計

### 7.1 服務定義（Services）

本專案定義了三個核心服務，對應 5G 的 N2/N3/N4 介面：

| 服務名稱 | 對應介面 | 協議 | Intercept 地址 | Host 地址 |
|---|---|---|---|---|
| `n2-ngap-service` | N2 (NGAP) | TCP* | `amf.ziti:38412` | `127.0.0.1:38413` |
| `n3-gtpu-service` | N3 (GTP-U) | UDP | `upf.ziti:2152` | `127.0.0.8:2152` |
| `n4-pfcp-service` | N4 (PFCP) | UDP | `upf-n4.ziti:8805` | `127.0.0.8:8805` |

> *N2 原生使用 SCTP，但透過 socat 轉為 TCP 後再經過 Ziti。

### 7.2 身份定義（Identities）

```yaml
identities:
  # gNB 側 — 每台 gNB 一個
  - name: gnb-01
    type: Device
    roleAttributes: [gnb-side, region-north]

  # 核網側 — 依功能分
  - name: core-amf-host
    type: Device
    roleAttributes: [core-side, control-plane-host]

  - name: core-upf-host
    type: Device
    roleAttributes: [core-side, user-plane-host]
```

### 7.3 存取策略（Service Policies）

```
                    Dial (呼叫)                  Bind (提供)
               ┌──────────────────┐        ┌──────────────────┐
  gnb-01       │  #gnb-side       │        │                  │
  (gnb-side)   │  可 Dial:        │        │                  │
               │  #control-plane  │        │                  │
               │  #user-plane     │        │                  │
               └──────────────────┘        └──────────────────┘

  core-amf-host│                  │        │  #control-plane- │
  (core-side)  │                  │        │  host 可 Bind:   │
               │                  │        │  #control-plane  │
               └──────────────────┘        └──────────────────┘

  core-upf-host│                  │        │  #user-plane-    │
  (core-side)  │                  │        │  host 可 Bind:   │
               │                  │        │  #user-plane     │
               │                  │        │  #pfcp-plane     │
               └──────────────────┘        └──────────────────┘
```

### 7.4 Edge Router Policies

```yaml
# 所有端點可使用所有 Router 接入
edgeRouterPolicies:
  - name: gnb-use-all-routers
    identityRoles: ["#gnb-side"]
    edgeRouterRoles: ["#all"]

  - name: core-use-all-routers
    identityRoles: ["#core-side"]
    edgeRouterRoles: ["#all"]

# 所有服務可透過所有 Router
serviceEdgeRouterPolicies:
  - name: core-services-all-routers
    serviceRoles: ["#core-services"]
    edgeRouterRoles: ["#all"]
```

---

## 8. 資料流路徑分析

### 8.1 N2 NGAP 控制面（gNB → AMF）

```
Step  位置        元件                動作
───── ─────────── ─────────────────── ──────────────────────────────────
  1   gnb-ns      UERANSIM gNB        發出 SCTP 連線到 127.0.0.1:38412
  2   gnb-ns      socat-gnb           SCTP:38412 → TCP 連到 amf.ziti:38412
  3   gnb-ns      ziti-edge-tunnel    tproxy 攔截 amf.ziti:38412 TCP 流量
                  (run 模式)           → 查詢 n2-ngap-service → Dial
  4   (fabric)    Ziti Router         mTLS 加密 → 轉發到 Bind 端
  5   core-ns     ziti-edge-tunnel    收到 n2-ngap-service 資料
                  (run-host 模式)      → 投遞到 host: 127.0.0.1:38413
  6   core-ns     socat-core          TCP:38413 → SCTP 連到 127.0.0.18:38412
  7   core-ns     free5gc AMF         收到 SCTP NGAP 訊息
```

### 8.2 N3 GTP-U 用戶面（gNB → UPF）

```
Step  位置        元件                動作
───── ─────────── ─────────────────── ──────────────────────────────────
  1   gnb-ns      UERANSIM gNB        發出 UDP 封包到 upf.ziti:2152
  2   gnb-ns      ziti-edge-tunnel    tproxy 攔截 (upf.ziti:2152 UDP)
                  (run 模式)           → Dial n3-gtpu-service
  3   (fabric)    Ziti Router         mTLS 加密轉發
  4   core-ns     ziti-edge-tunnel    投遞到 host: 127.0.0.8:2152
                  (run-host 模式)
  5   core-ns     free5gc UPF         收到 GTP-U 封包
```

### 8.3 封包加密前後對比

```
【gnb-ns 內的 veth-gnb 介面抓包】
  看到: TLS 加密流量 → 10.10.1.1:3022 (Router Edge)
  看不到: 任何 SCTP 38412 或 GTP-U 2152 的明文封包

【core-ns 內的 loopback 介面】
  看到: 正常的 SCTP/UDP 明文流量（因為已在 Ziti 信任域內）
```

---

## 9. 具體實做步驟

### 前置需求

```bash
# 作業系統
Ubuntu 22.04 / 24.04（Linux 核心 4.x+）

# 必要套件
sudo apt-get update
sudo apt-get install -y socat unzip curl jq

# yq（YAML 處理工具）
sudo curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    -o /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq

# free5gc 已安裝且可運作
# UERANSIM 已安裝
```

### Phase 1: 建立目錄與下載 Binary

```bash
cd ~/openziti-5gc
make dirs         # 建立 bin/, pki/, data/, logs/ 等目錄
make download     # 下載 ziti v1.6.13 和 ziti-edge-tunnel v1.10.10
```

### Phase 2: 建立三個 Network Namespace

```bash
sudo make ns-create

# 驗證
sudo make ns-status
# 應看到:
#   gnb-ns:    10.10.1.2/24  ─── router-ns: 10.10.1.1/24
#   core-ns:   10.10.2.2/24  ─── router-ns: 10.10.2.1/24
#   Host:      10.10.3.2/24  ─── router-ns: 10.10.3.1/24
#   gnb-ns → core-ns: 不可達 ✓
```

### Phase 3: 生成 PKI 憑證

```bash
make pki

# 驗證
ls pki/ca/certs/    # ca.cert, ctrl-server.cert, router-server.cert ...
ls pki/ca/keys/     # 對應的私鑰
```

產生的憑證包含：
- Root CA
- Controller Intermediate CA（用於簽發 Identity）
- Controller Server/Client 憑證
- Router Server/Client 憑證

### Phase 4: 初始化並啟動 Controller

```bash
# 初始化資料庫（在 router-ns 內）
make controller-init

# 啟動 Controller
make start-controller

# 驗證
curl -sk https://10.10.3.1:1280/edge/client/v1/version | jq .
```

### Phase 5: 註冊並啟動 Router

```bash
# 登入 Controller
ziti edge login https://10.10.3.1:1280 -u admin -p <password> --yes

# 建立 Edge Router
ziti edge create edge-router main-router \
    -o data/main-router.jwt -a "public" --tunneler-enabled

# Enroll（在 router-ns 內）
ip netns exec router-ns \
    ziti router enroll router/router-config.yaml --jwt data/main-router.jwt

# 啟動（在 router-ns 內）
ip netns exec router-ns \
    nohup ziti router run router/router-config.yaml &

# 驗證
ziti edge list edge-routers
# main-router, isOnline: true
```

### Phase 6: 套用服務、身份與策略

```bash
make apply

# 此命令會依序執行：
# 1. apply-services:   建立 n2-ngap-service, n3-gtpu-service, n4-pfcp-service
# 2. apply-identities: 建立 gnb-01, core-amf-host, core-upf-host
# 3. apply-policies:   建立 Dial/Bind Service Policies 和 Edge Router Policies

# 驗證
ziti edge list services        # 3 個 service
ziti edge list identities      # 3 個 identity（+系統預設）
ziti edge list service-policies # Dial 和 Bind 策略
```

### Phase 7: Enroll Identities

```bash
make enroll-core    # Enroll core-amf-host, core-upf-host
make enroll-gnb     # Enroll gnb-01

# 驗證
ls pki/identities/*.json
# gnb-01.json, core-amf-host.json, core-upf-host.json
```

### Phase 8: 啟動 free5gc（core-ns 內）

```bash
sudo ./scripts/start-core.sh start

# 此腳本在 core-ns 內啟動：
# 1. MongoDB
# 2. UPF
# 3. NRF, AMF, SMF, UDR, PCF, UDM, NSSF, AUSF, CHF, NEF
```

### Phase 9: 啟動 Core 側 Tunneler + socat（core-ns 內）

```bash
# Tunneler: run-host 模式（只 Bind，不 intercept）
ip netns exec core-ns \
    ziti-edge-tunnel run-host \
        --identity-dir pki/identities/ \
        --verbose 2 &

# socat: TCP → SCTP 轉換（N2）
ip netns exec core-ns \
    socat TCP-LISTEN:38413,bind=127.0.0.1,fork,reuseaddr \
          SCTP:127.0.0.18:38412 &
```

### Phase 10: 啟動 gNB 側 Tunneler + socat（gnb-ns 內）

```bash
# Tunneler: run 模式（tproxy intercept）
ip netns exec gnb-ns \
    ziti-edge-tunnel run \
        --identity-dir pki/identities/ \
        --dns-ip-range "100.64.0.0/10" \
        --verbose 2 &

# socat: SCTP → TCP 轉換（N2）
ip netns exec gnb-ns \
    socat SCTP-LISTEN:38412,bind=127.0.0.1,fork,reuseaddr \
          TCP:amf.ziti:38412 &
```

### Phase 11: 啟動 UERANSIM（gnb-ns 內）

```bash
sudo ./scripts/start-gnb.sh start       # 啟動 gNB
sudo ./scripts/start-gnb.sh start-ue    # 啟動 UE
```

gNB 設定關鍵修改：

```yaml
# AMF 連線指向本地 socat
amfConfigs:
  - address: 127.0.0.1    # gnb-ns 內的 socat-gnb（非直連 AMF）
    port: 38412
```

### Phase 12: 驗證

```bash
# 檢查 Ziti 服務 terminator
make login
ziti edge list services --output-json | jq '.[].terminators'

# 查看 Tunneler 日誌
tail -f logs/tunnel-gnb.log     # 應看到 intercept 記錄
tail -f logs/tunnel-core.log    # 應看到 host/dial 記錄

# 抓包驗證加密
sudo ip netns exec gnb-ns tcpdump -i veth-gnb -n port 3022
# 看到 TLS 加密流量，而非明文 SCTP/GTP-U
```

### 一鍵部署

以上所有步驟可用一鍵部署腳本完成：

```bash
cd ~/openziti-5gc
sudo ./scripts/deploy-3ns.sh
```

---

## 10. systemd 服務化管理

專案提供了完整的 systemd service 檔案，支援開機自啟：

```bash
make systemd-install
```

### 服務列表

| 服務檔案 | 功能 | 部署位置 |
|---|---|---|
| `ziti-controller.service` | Ziti Controller | router-ns |
| `ziti-router.service` | Ziti Edge Router | router-ns |
| `ziti-tunnel-core.service` | Core 側 Tunneler (run-host) | core-ns |
| `ziti-tunnel-gnb.service` | gNB 側 Tunneler (run/tproxy) | gnb-ns |
| `socat-n2-core.service` | Core 側 SCTP↔TCP 轉換 | core-ns |
| `socat-n2-gnb.service` | gNB 側 SCTP↔TCP 轉換 | gnb-ns |

### 啟用服務

```bash
# 共用組件
sudo systemctl enable --now ziti-controller
sudo systemctl enable --now ziti-router

# gNB 側
sudo systemctl enable --now ziti-tunnel-gnb
sudo systemctl enable --now socat-n2-gnb

# 核網側
sudo systemctl enable --now ziti-tunnel-core
sudo systemctl enable --now socat-n2-core
```

---

## 11. 驗證與疑難排解

### 11.1 狀態檢查

```bash
make status

# 輸出範例：
# === OpenZiti 5GC 狀態 ===
# --- Controller ---  ✓ 運行中 (PID: 12345)
# --- Router ---      ✓ 運行中 (PID: 12346)
# --- Tunneler ---    兩個 ziti-edge-tunnel 程式
# --- 已註冊的服務 ---  n2-ngap-service, n3-gtpu-service, n4-pfcp-service
# --- 已註冊的 Identity --- gnb-01, core-amf-host, core-upf-host
```

```bash
# 一鍵檢查各 namespace 的網路狀態
for ns in gnb-ns router-ns core-ns; do
  echo "=== $ns ==="
  sudo ip netns exec $ns ip addr show | grep -E 'inet |mtu'
  sudo ip netns exec $ns ss -tulnp 2>/dev/null | head -10
  echo
done
```

### 11.2 封包抓取驗證

在三個 Namespace 中分別抓封包，可以驗證 Ziti overlay 是否正確加密並隔離了 N2/N3 流量。

基本語法：

```bash
sudo ip netns exec <ns名稱> tcpdump -i <介面> -n <過濾條件>
```

#### 11.2.1 N2 (SCTP/NGAP) — gNB ↔ AMF

**gnb-ns 端**（觀察 socat 轉換前後的封包）：

```bash
# gNB 發出的原始 SCTP 封包（到 socat）
sudo ip netns exec gnb-ns tcpdump -i lo -n sctp and port 38412

# socat 轉出的 TCP 封包（即將被 tproxy 攔截）
sudo ip netns exec gnb-ns tcpdump -i lo -n tcp and port 38412
```

**router-ns 端**（應只看到 Ziti TLS 加密流量）：

```bash
# gnb-ns → router-ns 方向
sudo ip netns exec router-ns tcpdump -i veth-r-gnb -n port 3022

# router-ns → core-ns 方向
sudo ip netns exec router-ns tcpdump -i veth-r-core -n port 3022
```

**core-ns 端**（還原後的明文）：

```bash
# Ziti 出來的 TCP 封包（socat 接收端）
sudo ip netns exec core-ns tcpdump -i lo -n tcp and port 38413

# socat 轉回的 SCTP 封包（送到 AMF）
sudo ip netns exec core-ns tcpdump -i lo -n sctp and port 38412
```

#### 11.2.2 N3 (GTP-U/UDP) — gNB ↔ UPF

**gnb-ns 端**：

```bash
# gNB 發出的 GTP-U（目的 10.10.2.2:2152，被 tproxy 攔截）
sudo ip netns exec gnb-ns tcpdump -i any -n udp and port 2152

# veth 上不應有明文 GTP-U（tproxy 在 OUTPUT chain 就攔截了）
sudo ip netns exec gnb-ns tcpdump -i veth-gnb -n udp and port 2152
# ↑ 預期：抓不到封包
```

**router-ns 端**：

```bash
# 只會看到 TLS 加密的 Ziti Fabric 封包
sudo ip netns exec router-ns tcpdump -i veth-r-gnb -n -c 20
sudo ip netns exec router-ns tcpdump -i veth-r-core -n -c 20
```

**core-ns 端**：

```bash
# Ziti run-host 還原後送到 UPF 的 GTP-U 明文
sudo ip netns exec core-ns tcpdump -i any -n udp and port 2152
```

#### 11.2.3 驗證隔離性 — gnb-ns 不可直達 core-ns

```bash
# 直接 ping（應該失敗）
sudo ip netns exec gnb-ns ping -c 3 10.10.2.2

# 同時查 router-ns 的 iptables DROP 計數（pkts 應遞增）
sudo ip netns exec router-ns iptables -L FORWARD -n -v | grep DROP
```

#### 11.2.4 對比實驗 — 證明 Ziti 加密有效

開兩個終端機並排觀察：

**終端 A**（gnb-ns veth — 只看得到加密流量）：

```bash
sudo ip netns exec gnb-ns tcpdump -i veth-gnb -n -X -c 10
```

**終端 B**（core-ns loopback — 看得到明文 SCTP/GTP）：

```bash
sudo ip netns exec core-ns tcpdump -i lo -n -X -c 10 'sctp or udp port 2152'
```

對比結果：
- **終端 A payload** → TLS 加密亂碼（Ziti Fabric），無法辨識協議內容
- **終端 B payload** → 可辨識的 NGAP/GTP-U 明文結構（SCTP chunk header、GTP header 等）

#### 11.2.5 儲存 pcap 檔（用 Wireshark 離線分析）

```bash
# 分別在三個 namespace 抓封包存檔
sudo ip netns exec gnb-ns tcpdump -i veth-gnb -n -w /tmp/gnb-veth.pcap -c 500 &
sudo ip netns exec router-ns tcpdump -i veth-r-gnb -n -w /tmp/router-gnb.pcap -c 500 &
sudo ip netns exec core-ns tcpdump -i lo -n -w /tmp/core-lo.pcap -c 500 &

# ... 執行測試流量後，取回 pcap 檔 ...

# 用 Wireshark 開啟
wireshark /tmp/gnb-veth.pcap &
wireshark /tmp/core-lo.pcap &
```

#### 11.2.6 預期結果總結

| 抓封包位置 | 應該看到 | 不應該看到 |
|---|---|---|
| gnb-ns `lo` | SCTP:38412、TCP:38412 (socat) | — |
| gnb-ns `veth-gnb` | TLS:3022 (Ziti 加密) | 明文 SCTP / GTP-U |
| router-ns `veth-r-gnb` | TLS:3022 | 明文 SCTP / GTP-U |
| router-ns `veth-r-core` | TLS:3022 | 明文 SCTP / GTP-U |
| core-ns `veth-core` | TLS:3022 (Ziti 加密) | — |
| core-ns `lo` | SCTP:38412、TCP:38413、UDP:2152 (明文) | — |

> **重點**：所有 veth 介面上只該看到 Ziti TLS 加密封包（port 3022），明文協定只出現在各自 namespace 的 loopback 上。這就是 Zero Trust overlay 的核心效果——即使攻擊者在傳輸路徑上抓封包，也只能看到無法解讀的 mTLS 密文。

### 11.3 常見問題

| 問題 | 診斷方法 | 解法 |
|---|---|---|
| Tunneler 無法連上 Router | `sudo ip netns exec gnb-ns curl -sk https://10.10.1.1:3022` | 檢查 veth 路由或 PKI SAN |
| socat 報 "Address already in use" | `sudo ip netns exec gnb-ns ss -tlnp \| grep 38412` | kill 佔用程式後重啟 |
| tproxy 規則未生效 | `sudo ip netns exec gnb-ns iptables -t mangle -L -n -v` | 檢查 Tunneler 是否以 root 執行 |
| gNB 無法註冊到 AMF | `tail -f logs/socat-n2-gnb.log` | 確認 socat 和 Tunneler 都已啟動 |
| N3 GTP-U 不通 | 檢查 UPF 的 gtpu 監聯地址 | 確保 upfcfg.yaml gtpu addr = 10.10.2.2 |
| gNB 抓包看到明文 GTP-U 出現在 veth 上 | tproxy 未攔截，檢查路由與 fwmark | 確認 `ip rule` 和 `ip route` 正確 |
| Namespace ping 不通 | `sudo ip netns exec gnb-ns ip route` | 確認 veth pair up 且有正確路由 |

### 11.4 清理重來

```bash
make stop-all           # 停止所有 Ziti 服務
sudo make ns-delete     # 刪除所有 namespace
make clean              # 清理資料（保留 binary 和設定）
make clean-all          # 完全清理（含 binary 和 PKI）
```

---

## 12. 多機部署延伸

三 Namespace 架構可直接對應到真實的多機部署，所有邏輯不變：

| 組件 | 單機 Namespace | 3 台 VM/主機 |
|---|---|---|
| Controller | router-ns (10.10.3.1) | VM-1 (192.168.x.10) |
| Router | router-ns (10.10.1.1) | VM-1 (192.168.x.10) |
| Core Tunneler + free5gc | core-ns (10.10.2.2) | VM-2 (192.168.x.20) |
| gNB Tunneler + UERANSIM | gnb-ns (10.10.1.2) | VM-3 (192.168.x.30) |

### 多機部署需修改的項目

1. **`Makefile`** 的 `CTRL_HOST` 和 `ROUTER_HOST` 改為實際 IP
2. **`ctrl-config.yaml`** 的 `advertiseAddress` 和 `advertise`
3. **`router-config.yaml`** 的 `ctrl.endpoint` 和 `advertise`
4. **PKI SAN** 加入實際 IP
5. **不再需要 Network Namespace**，因為每台主機天然隔離

### 架構擴展

- **多 gNB**：複製 `gnb-01` Identity 為 `gnb-02`、`gnb-03`...，使用相同角色標籤自動套用策略
- **多 Router**：在不同地點部署 Router，形成 Mesh 網路，提升可用性
- **區域策略**：為不同地區的 gNB 設定不同的 `region-*` 角色，限制只能連到特定區域的核網
- **SBI 保護**：取消註解 `services.yml` 中的 SBI 服務定義，保護 NRF、AMF 等之間的 HTTP/2 通訊

---

## 附錄：專案目錄結構

```
openziti-5gc/
├── Makefile                    # 主要操作入口（make help 查看所有指令）
├── .admin-password             # Controller 管理密碼
├── controller/
│   └── ctrl-config.yaml        # Controller 設定檔
├── router/
│   └── router-config.yaml      # Router 設定檔
├── policies/
│   ├── services.yml            # 服務定義（N2/N3/N4）
│   ├── identities.yml          # 身份定義（gNB/Core）
│   ├── service-policies.yml    # Dial/Bind 存取策略
│   └── edge-router-policies.yml # Router 接入策略
├── scripts/
│   ├── setup-namespaces.sh     # 建立/刪除 3 個 namespace
│   ├── deploy-3ns.sh           # 一鍵部署腳本
│   ├── apply.sh                # 讀取 YAML 套用到 Controller
│   ├── start-core.sh           # 在 core-ns 內啟動 free5gc
│   └── start-gnb.sh            # 在 gnb-ns 內啟動 UERANSIM
├── systemd/
│   ├── ziti-controller.service
│   ├── ziti-router.service
│   ├── ziti-tunnel.service        # 通用 Tunneler 服務（參考用）
│   ├── ziti-tunnel-core.service
│   ├── ziti-tunnel-gnb.service
│   ├── socat-n2-core.service
│   └── socat-n2-gnb.service
├── tunneler/
│   ├── core-side/              # Core 側 Tunneler 設定參考
│   └── gnb-side/               # gNB 側 Tunneler 設定參考
├── config/                     # UERANSIM 設定檔（start-gnb.sh 自動產生）
├── pki/                        # PKI 憑證（make pki 生成）
├── bin/                        # ziti, ziti-edge-tunnel binary
├── data/                       # Controller DB, PID 檔案
├── logs/                       # 各組件日誌
└── docs/
    └── DEPLOY-SINGLE-MACHINE.md # 單機部署文件
```

---

## 參考資料

- [OpenZiti 官方文件](https://openziti.io/docs/learn/introduction/)
- [OpenZiti GitHub](https://github.com/openziti/ziti)
- [ziti-edge-tunnel GitHub](https://github.com/openziti/ziti-tunnel-sdk-c)
- [free5GC 官方網站](https://free5gc.org/)
- [UERANSIM GitHub](https://github.com/aligungr/UERANSIM)
- [3GPP TS 23.501 — 5G 系統架構](https://www.3gpp.org/DynaReport/23501.htm)
