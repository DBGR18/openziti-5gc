# 三 Namespace 部署 SOP — OpenZiti 5GC 保護層

## 架構總覽

```
一台實體機器
┌──────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│  gnb-ns (10.10.1.2)                                                         │
│  ┌─────────────────────────────┐                                            │
│  │  UERANSIM gNB + UE         │                                            │
│  │  socat (SCTP→TCP→amf.ziti) │    veth (10.10.1.0/24)                     │
│  │  ziti-edge-tunnel (tproxy) ├────────────────┐                           │
│  └─────────────────────────────┘                │                           │
│       ↑ 獨立 iptables + 路由表                    │                           │
│       ↑ gnb-ns → core-ns: ✗ DROP               │                           │
│                                                  ↓                           │
│                                   router-ns (10.10.1.1 / 10.10.2.1)        │
│                                   ┌────────────────────────┐                │
│                                   │  Ziti Controller :1280 │                │
│                                   │  Ziti Router     :3022 │                │
│                                   │  (只做 Fabric 路由)     │                │
│                                   └──────────┬─────────────┘                │
│                                              │ veth (10.10.2.0/24)          │
│                                              ↓                              │
│  core-ns (10.10.2.2)                                                        │
│  ┌─────────────────────────────────────────────────────────────┐            │
│  │  MongoDB (127.0.0.1:27017)                                  │            │
│  │  NRF (127.0.0.10:8000)   AMF (127.0.0.18:8000/38412)       │            │
│  │  SMF (127.0.0.2:8000)    UPF (10.10.2.2:2152 / 127.0.0.8) │            │
│  │  AUSF, UDM, UDR, NSSF, PCF, CHF, NEF ...                  │            │
│  │  socat (TCP→SCTP→AMF)                                      │            │
│  │  ziti-edge-tunnel (run-host)                                │            │
│  └─────────────────────────────────────────────────────────────┘            │
│                                                                              │
│  Host (10.10.3.2) ── veth ── router-ns (10.10.3.1)                         │
│  └─ 管理 CLI (ziti edge, make apply, etc.)                                  │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 為什麼三個 Namespace？

| 組件 | 真實部署位置 | Namespace |
|---|---|---|
| gNB | 基地台機房 | gnb-ns |
| Ziti Router | 傳輸網路 | router-ns |
| 核心網 (AMF, UPF...) | 資料中心 | core-ns |

**關鍵隔離**: gnb-ns ←✗→ core-ns（iptables FORWARD DROP），N2/N3 流量**必須**經過 Ziti overlay。

### 為什麼不需要 3 台 VM？

Network Namespace 提供：
- ✅ 獨立的網路介面、iptables、路由表
- ✅ Linux kernel 原生功能，零額外資源開銷
- ✅ 確保 tproxy 規則不會互相影響
- ❌ 不隔離 filesystem（所有 ns 共享 binary/config）但這不影響網路測試

---

## 前置需求

```bash
# 確認核心模組
lsmod | grep gtp5g    # 需要 gtp5g 已載入

# 安裝必要套件
sudo apt-get update
sudo apt-get install -y socat unzip curl jq

# 安裝 yq
sudo curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    -o /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq

# 確認 free5gc 和 UERANSIM
ls ~/free5gc/bin/amf ~/free5gc/bin/upf
ls ~/UERANSIM/build/nr-gnb ~/UERANSIM/build/nr-ue
```

---

## 快速部署（一鍵）

```bash
cd ~/openziti-5gc
sudo make deploy
```

---

## 分步驟部署

### Phase 1: 基礎準備

```bash
cd ~/openziti-5gc

# 建立目錄
make dirs

# 下載 Ziti binary
make download
```

### Phase 2: 建立三個 Namespace

```bash
sudo make ns-create

# 驗證
sudo make ns-status

# 測試隔離
sudo ip netns exec gnb-ns ping -c1 10.10.1.1    # ✓ (到 router-ns)
sudo ip netns exec gnb-ns ping -c1 10.10.2.2    # ✗ (到 core-ns，被 DROP)
```

### Phase 3: PKI 憑證

```bash
make pki
```

### Phase 4: Controller (router-ns)

```bash
make controller-init
sudo make start-controller

# 驗證（從 Host 透過管理通道）
curl -sk https://10.10.3.1:1280/edge/client/v1/version | jq .
```

### Phase 5: Router (router-ns)

```bash
make router-init
sudo make start-router

make login
bin/ziti edge list edge-routers
```

### Phase 6: 套用策略

```bash
make apply
make enroll-core
make enroll-gnb
```

### Phase 7: 啟動 free5gc (core-ns)

**重要**: 需要先修改 UPF 的 GTP-U 地址。

```bash
# 修改 upfcfg.yaml：gtpu addr 改為 10.10.2.2
# （讓 SMF 告訴 gNB 的 UPF 地址可被 Tunneler 攔截）
```

```yaml
# ~/free5gc/config/upfcfg.yaml 修改:
configuration:
  pfcp:
    nodeID: 127.0.0.8        # 不變（core-ns 內 loopback）
    addr: 127.0.0.8          # 不變
  gtpu:
    forwarder: gtp5g
    ifList:
      - addr: 10.10.2.2      # ← 從 127.0.0.8 改為 core-ns 的 veth IP
        type: N3
```

```bash
# 啟動 free5gc
sudo make start-core

# 驗證
sudo ip netns exec core-ns ss -tlnp | grep 8000
sudo ip netns exec core-ns ss -tlnp | grep 38412
```

### Phase 8: Core-side Tunneler (core-ns)

```bash
sudo make start-tunnel-core

# 驗證
sudo ip netns exec core-ns pgrep -a ziti-edge-tunnel
sudo ip netns exec core-ns pgrep -a socat
```

### Phase 9: gNB-side Tunneler (gnb-ns)

```bash
sudo make start-tunnel-gnb

# 驗證
sudo ip netns exec gnb-ns pgrep -a ziti-edge-tunnel
sudo ip netns exec gnb-ns pgrep -a socat
```

### Phase 10: UERANSIM gNB + UE (gnb-ns)

```bash
# 啟動 gNB
sudo make start-gnb

# 啟動 UE
sudo make start-ue

# 驗證
tail -f logs/gnb.log    # 看到 "NG Setup procedure is successful"
tail -f logs/ue.log     # 看到 "PDU Session establishment is successful"
```

### Phase 11: 驗證端對端

```bash
# 1. 檢查 UE tunnel 介面
sudo ip netns exec gnb-ns ip addr show uesimtun0

# 2. 測試 UE 上網
sudo ip netns exec gnb-ns ping -I uesimtun0 8.8.8.8

# 3. 驗證流量經過 Ziti（看加密的 TLS 流量）
sudo ip netns exec gnb-ns tcpdump -i veth-gnb -n port 3022

# 4. 確認 gnb-ns 不能直接到 core-ns
sudo ip netns exec gnb-ns ping -c1 10.10.2.2   # 應該失敗

# 5. 查看 Ziti 流量日誌
tail -f logs/tunnel-gnb.log    # intercept 記錄
tail -f logs/tunnel-core.log   # host/bind 記錄
```

---

## 封包流程圖

### N2 (NGAP/SCTP) 流程

```
gnb-ns                          router-ns              core-ns
 gNB                                                    AMF
  │ SCTP:38412                                          │
  ├──► socat-gnb                                        │
  │    SCTP → TCP                                       │
  │         │                                           │
  │    TCP → amf.ziti:38412                             │
  │         │                                           │
  │    Tunneler (tproxy intercept)                      │
  │         │                                           │
  │    ══ Ziti Fabric ══                                │
  │         │                    Ziti Router             │
  │         ├───────────────────→ (Fabric 路由)          │
  │         │                    ─────────────┐         │
  │         │                                 ↓         │
  │         │                    Tunneler (run-host)    │
  │         │                         │                 │
  │         │                    TCP:38413 → socat-core │
  │         │                         │                 │
  │         │                    SCTP:38412 → AMF      │
  │                                                ◄────┤
```

### N3 (GTP-U/UDP) 流程

```
gnb-ns                          router-ns              core-ns
 gNB                                                    UPF
  │                                                     │ (10.10.2.2:2152)
  │ UDP → 10.10.2.2:2152                               │
  │    ↓                                                │
  │ tproxy 攔截 (OUTPUT chain mark → reroute → TPROXY) │
  │    ↓                                                │
  │ Tunneler ──── Ziti Fabric ───── Router ───────┐    │
  │                                                ↓    │
  │                                   Tunneler     │    │
  │                                   (run-host)   │    │
  │                                        ↓       │    │
  │                                   UDP → 10.10.2.2:2152
  │                                                ◄────┤
```

---

## UPF 的特殊處理說明

### 為什麼 UPF GTP-U 地址需要改成 10.10.2.2？

1. SMF 在 PDU Session Setup 時告訴 gNB：「UPF 在 `addr:2152`」
2. gNB 收到後直接用 `sendto(fd, data, {addr:2152})` 送 GTP-U
3. 如果 addr = `127.0.0.8`：在 gnb-ns 裡 127.0.0.8 是本地 loopback → 送不出去
4. 如果 addr = `10.10.2.2`：不是 loopback → kernel 走路由 → tproxy 可以攔截

### free5gc 設定修改清單

| 檔案 | 欄位 | 改前 | 改後 |
|---|---|---|---|
| `upfcfg.yaml` | `gtpu.ifList[0].addr` | `127.0.0.8` | `10.10.2.2` |
| `smfcfg.yaml` | `userplaneInformation.upNodes.UPF.interfaces[].endpoints[]` | `127.0.0.8` | `10.10.2.2` |

其他 NF (NRF, AMF, AUSF, UDM, UDR, NSSF, PCF, CHF, NEF) 的 SBI bind 地址保持 `127.0.0.x` 不變，因為它們都在 core-ns 內，loopback 通訊不會跨越 namespace。

---

## 日常操作

```bash
# 狀態
make status
sudo make ns-status

# 停止所有
sudo make stop-all

# 清理（保留 binary）
make clean

# 完全清理
make clean-all

# 進入 namespace 調試
sudo ip netns exec gnb-ns bash
sudo ip netns exec router-ns bash
sudo ip netns exec core-ns bash
```

---

## 常見問題

### Q: gNB 連不上 AMF (NG Setup failed)

```bash
# 在 gnb-ns 檢查 socat 是否運行
sudo ip netns exec gnb-ns pgrep -a socat

# 在 core-ns 檢查 AMF 是否監聽 SCTP
sudo ip netns exec core-ns ss -lnp | grep 38412

# 檢查 Tunneler 日誌
tail -20 logs/tunnel-gnb.log
tail -20 logs/tunnel-core.log
```

### Q: PDU Session 建不起來 (N3 問題)

```bash
# 確認 upfcfg.yaml 的 gtpu.addr 是否已改為 10.10.2.2
grep -A2 gtpu ~/free5gc/config/upfcfg.yaml

# 確認 gnb-ns 有到 10.10.2.2 的路由
sudo ip netns exec gnb-ns ip route | grep 10.10.2

# 確認 tproxy 規則存在
sudo ip netns exec gnb-ns iptables -t mangle -L -n | grep 2152
```

### Q: gtp5g 模組問題

```bash
# gtp5g 是 kernel module，全域共享，不受 namespace 影響
lsmod | grep gtp5g

# 如果沒有載入
cd ~/gtp5g && sudo make install && sudo modprobe gtp5g
```

---

## 封包抓取驗證

在三個 Namespace 中分別抓封包，可以驗證 Ziti overlay 是否正確加密並隔離了 N2/N3 流量。

### 基本語法

```bash
sudo ip netns exec <ns名稱> tcpdump -i <介面> -n <過濾條件>
```

### N2 (SCTP/NGAP) — gNB ↔ AMF

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

### N3 (GTP-U/UDP) — gNB ↔ UPF

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

### 驗證隔離性 — gnb-ns 不可直達 core-ns

```bash
# 直接 ping（應該失敗）
sudo ip netns exec gnb-ns ping -c 3 10.10.2.2

# 同時查 router-ns 的 iptables DROP 計數（pkts 應遞增）
sudo ip netns exec router-ns iptables -L FORWARD -n -v | grep DROP
```

### 對比實驗 — 證明 Ziti 加密有效

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
- 終端 A payload → TLS 加密亂碼（Ziti Fabric）
- 終端 B payload → 可辨識的 NGAP/GTP-U 明文結構

### 儲存 pcap 檔（用 Wireshark 離線分析）

```bash
sudo ip netns exec gnb-ns tcpdump -i veth-gnb -n -w /tmp/gnb-veth.pcap -c 500
sudo ip netns exec router-ns tcpdump -i veth-r-gnb -n -w /tmp/router-gnb.pcap -c 500
sudo ip netns exec core-ns tcpdump -i lo -n -w /tmp/core-lo.pcap -c 500

# 事後開啟
wireshark /tmp/gnb-veth.pcap &
```

### 一鍵狀態檢查

```bash
for ns in gnb-ns router-ns core-ns; do
  echo "=== $ns ==="
  sudo ip netns exec $ns ip addr show | grep -E 'inet |mtu'
  sudo ip netns exec $ns ss -tulnp 2>/dev/null | head -10
  echo
done
```

### 預期結果總結

| 抓封包位置 | 應該看到 | 不應該看到 |
|---|---|---|
| gnb-ns `lo` | SCTP:38412、TCP:38412 (socat) | — |
| gnb-ns `veth-gnb` | TLS:3022 (Ziti 加密) | 明文 SCTP / GTP-U |
| router-ns `veth-r-gnb` | TLS:3022 | 明文 SCTP / GTP-U |
| router-ns `veth-r-core` | TLS:3022 | 明文 SCTP / GTP-U |
| core-ns `veth-core` | TLS:3022 (Ziti 加密) | — |
| core-ns `lo` | SCTP:38412、TCP:38413、UDP:2152 (明文) | — |

**重點**：veth 介面上只該看到 Ziti TLS 加密封包（port 3022），明文協定只出現在各自 namespace 的 loopback 上。
