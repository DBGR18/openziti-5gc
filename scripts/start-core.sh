#!/usr/bin/env bash
# =============================================================================
# start-core.sh — Start all free5gc NFs in core-ns
#
# Prerequisite: namespace created (setup-namespaces.sh create)
#
# Usage:
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
RUNTIME_CFG_DIR="/tmp/core-ns-free5gc-config"

# Check if namespace exists
check_ns() {
    if ! ip netns list 2>/dev/null | grep -qw "$NS"; then
        echo "[ERROR] namespace '$NS' does not exist. Please run first:"
        echo "  sudo ./scripts/setup-namespaces.sh create"
        exit 1
    fi
}

# Execute command within namespace
ns_exec() {
    ip netns exec "$NS" "$@"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[ERROR] missing required command: $1"
        exit 1
    }
}

prepare_runtime_configs() {
    require_cmd yq

    local core_n3_ip n6_if
    core_n3_ip="$(ns_exec ip -4 -o addr show dev veth-core | awk '{print $4}' | cut -d/ -f1 | head -1)"
    n6_if="$(ns_exec ip route show default | awk '/default/ {for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"

    if [[ -z "$core_n3_ip" ]]; then
        echo "[ERROR] failed to detect core-ns N3 IP on veth-core"
        exit 1
    fi
    if [[ -z "$n6_if" ]]; then
        echo "[ERROR] failed to detect core-ns default egress interface"
        exit 1
    fi

    rm -rf "$RUNTIME_CFG_DIR"
    mkdir -p "$RUNTIME_CFG_DIR"
    cp "${FREE5GC_DIR}/config/"*.yaml "$RUNTIME_CFG_DIR/"

    export CORE_N3_IP="$core_n3_ip"
    export CORE_N6_IF="$n6_if"

    # Keep SBI/PFCP loopback topology inside core-ns, but advertise reachable N3 IP to gNB side.
    yq -i '.configuration.userplaneInformation.upNodes.UPF.interfaces[0].endpoints = [strenv(CORE_N3_IP)]' "$RUNTIME_CFG_DIR/smfcfg.yaml"

    # UPF binds GTP-U on core-ns underlay interface (veth-core).
    yq -i '.gtpu.ifList[0].addr = strenv(CORE_N3_IP)' "$RUNTIME_CFG_DIR/upfcfg.yaml"

    # Optional but useful: keep natifname aligned with current N6 egress interface.
    yq -i '.dnnList[].natifname = strenv(CORE_N6_IF)' "$RUNTIME_CFG_DIR/upfcfg.yaml"

    echo "  Runtime config dir: $RUNTIME_CFG_DIR"
    echo "  Detected core-ns N3 IP: $core_n3_ip"
    echo "  Detected core-ns N6 IF: $n6_if"
}

seed_default_subscriber() {
        # Create only if data does not exist, to avoid overwriting user settings
        ns_exec mongosh free5gc --quiet --eval '
const ueId = "imsi-208930000000001";
const plmn = "20893";
const key = "8baf473f2f8fd09487cccbd7097c6862";
const opc = "8e27b6af0e692e750f32667a3b14605d";

const db5g = db.getSiblingDB("free5gc");
const authColl = db5g.getCollection("subscriptionData.authenticationData.authenticationSubscription");
const seedSqn = "000000000020";

if (!authColl.findOne({ ueId })) {
    authColl.updateOne(
        { ueId },
        {
            $set: {
                ueId,
                authenticationMethod: "5G_AKA",
                encPermanentKey: key,
                protectionParameterId: "",
                sequenceNumber: {
                    sqn: seedSqn,
                    sqnScheme: "NON_TIME_BASED",
                    lastIndexes: { ausf: 0 }
                },
                authenticationManagementField: "8000",
                algorithmId: "milenage",
                encOpcKey: opc
            }
        },
        { upsert: true }
    );

    db5g.getCollection("subscriptionData.authenticationData.webAuthenticationSubscription").updateOne(
        { ueId },
        {
            $set: {
                ueId,
                authenticationMethod: "5G_AKA",
                authenticationManagementField: "8000",
                permanentKey: { permanentKeyValue: key },
                sequenceNumber: seedSqn,
                opc: { opcValue: opc }
            }
        },
        { upsert: true }
    );

    db5g.getCollection("subscriptionData.provisionedData.amData").updateOne(
        { ueId, servingPlmnId: plmn },
        {
            $set: {
                ueId,
                servingPlmnId: plmn,
                gpsis: ["msisdn-0900000000"],
                subscribedUeAmbr: { uplink: "1 Gbps", downlink: "2 Gbps" },
                nssai: {
                    defaultSingleNssais: [
                        { sst: 1, sd: "010203" },
                        { sst: 1, sd: "112233" }
                    ],
                    singleNssais: [
                        { sst: 1, sd: "010203" },
                        { sst: 1, sd: "112233" }
                    ]
                },
                subscribedDnnList: ["internet"]
            }
        },
        { upsert: true }
    );

    db5g.getCollection("subscriptionData.provisionedData.smfSelectionSubscriptionData").updateOne(
        { ueId, servingPlmnId: plmn },
        {
            $set: {
                ueId,
                servingPlmnId: plmn,
                subscribedSnssaiInfos: {
                    "01010203": { dnnInfos: [{ dnn: "internet" }] },
                    "01112233": { dnnInfos: [{ dnn: "internet" }] }
                }
            }
        },
        { upsert: true }
    );

    db5g.getCollection("subscriptionData.provisionedData.smData").updateOne(
        { ueId, servingPlmnId: plmn, "singleNssai.sst": 1, "singleNssai.sd": "010203" },
        {
            $set: {
                ueId,
                servingPlmnId: plmn,
                singleNssai: { sst: 1, sd: "010203" },
                dnnConfigurations: {
                    internet: {
                        pduSessionTypes: {
                            defaultSessionType: "IPV4",
                            allowedSessionTypes: ["IPV4"]
                        },
                        sscModes: {
                            defaultSscMode: "SSC_MODE_1",
                            allowedSscModes: ["SSC_MODE_2", "SSC_MODE_3"]
                        },
                        sessionAmbr: { uplink: "1000 Mbps", downlink: "1000 Mbps" },
                        "5gQosProfile": {
                            "5qi": 9,
                            arp: { priorityLevel: 8 },
                            priorityLevel: 8
                        }
                    }
                }
            }
        },
        { upsert: true }
    );

    db5g.getCollection("subscriptionData.provisionedData.smData").updateOne(
        { ueId, servingPlmnId: plmn, "singleNssai.sst": 1, "singleNssai.sd": "112233" },
        {
            $set: {
                ueId,
                servingPlmnId: plmn,
                singleNssai: { sst: 1, sd: "112233" },
                dnnConfigurations: {
                    internet: {
                        pduSessionTypes: {
                            defaultSessionType: "IPV4",
                            allowedSessionTypes: ["IPV4"]
                        },
                        sscModes: {
                            defaultSscMode: "SSC_MODE_1",
                            allowedSscModes: ["SSC_MODE_2", "SSC_MODE_3"]
                        },
                        sessionAmbr: { uplink: "1000 Mbps", downlink: "1000 Mbps" },
                        "5gQosProfile": {
                            "5qi": 8,
                            arp: { priorityLevel: 8 },
                            priorityLevel: 8
                        }
                    }
                }
            }
        },
        { upsert: true }
    );

    db5g.getCollection("policyData.ues.amData").updateOne(
        { ueId },
        {
            $set: {
                ueId,
                subscCats: ["free5gc"]
            }
        },
        { upsert: true }
    );

    db5g.getCollection("policyData.ues.smData").updateOne(
        { ueId },
        {
            $set: {
                ueId,
                smPolicySnssaiData: {
                    "01010203": {
                        snssai: { sst: 1, sd: "010203" },
                        smPolicyDnnData: { internet: { dnn: "internet" } }
                    },
                    "01112233": {
                        snssai: { sst: 1, sd: "112233" },
                        smPolicyDnnData: { internet: { dnn: "internet" } }
                    }
                }
            }
        },
        { upsert: true }
    );

    print("seeded default subscriber: " + ueId);
}
'
}

cleanup_residual_nf() {
    if ! ip netns list 2>/dev/null | grep -qw "$NS"; then
        return 0
    fi

    # 先嘗試正常結束
    ns_exec pkill -f "bin/upf" 2>/dev/null || true
    ns_exec pkill -f "bin/nrf" 2>/dev/null || true
    ns_exec pkill -f "bin/amf" 2>/dev/null || true
    ns_exec pkill -f "bin/smf" 2>/dev/null || true
    for nf in udr pcf udm nssf ausf chf nef; do
        ns_exec pkill -f "bin/${nf}" 2>/dev/null || true
    done

    # 給予一點時間讓程序釋放埠
    sleep 1

    # 仍殘留者強制結束，避免 start 時 NRF bind 衝突
    ns_exec pkill -9 -f "bin/upf" 2>/dev/null || true
    ns_exec pkill -9 -f "bin/nrf" 2>/dev/null || true
    ns_exec pkill -9 -f "bin/amf" 2>/dev/null || true
    ns_exec pkill -9 -f "bin/smf" 2>/dev/null || true
    for nf in udr pcf udm nssf ausf chf nef; do
        ns_exec pkill -9 -f "bin/${nf}" 2>/dev/null || true
    done
}

start_core() {
    check_ns
    echo "=== 在 $NS 內Starting free5gc ==="

    # Starting前清掉任何殘留程序，避免埠衝突
    cleanup_residual_nf

    # 確認 lo 介面的 127.0.0.0/8 可用（Linux 預設行為，但確認一下）
    ns_exec ip link set lo up

    echo ">>> Preparing runtime configs for namespace IPs..."
    prepare_runtime_configs

    mkdir -p "$LOG_DIR"
    > "$PID_FILE"

    # ---------------------------------------------------------------
    # 1. Starting MongoDB（在 core-ns 內）
    # ---------------------------------------------------------------
    echo ">>> Starting MongoDB..."
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

    # 補齊預設 UE 訂閱資料，避免 UDR 空資料導致 Registration Reject[CONGESTION]
    seed_default_subscriber > /dev/null 2>&1 || true

    # ---------------------------------------------------------------
    # 2. Starting UPF（需要 sudo，因為要建 GTP tunnel）
    # ---------------------------------------------------------------
    echo ">>> Starting UPF..."
    ns_exec "${FREE5GC_DIR}/bin/upf" \
        -c "${RUNTIME_CFG_DIR}/upfcfg.yaml" \
        -l "$LOG_DIR/free5gc.log" &
    UPF_PID=$!
    echo "upf:$UPF_PID" >> "$PID_FILE"
    echo "  UPF PID: $UPF_PID"
    sleep 1

    # ---------------------------------------------------------------
    # 2b. 清理舊版 N3 下行 workaround（改由 Ziti n3-gtpu-dl-service 處理）
    # ---------------------------------------------------------------
    ns_exec iptables -t nat -D OUTPUT -p udp -d 127.0.0.1 --sport 2152 --dport 2152 -j DNAT --to-destination 10.10.1.2:2152 2>/dev/null || true
    ns_exec iptables -t nat -D POSTROUTING -p udp -d 10.10.1.2 --sport 2152 --dport 2152 -j SNAT --to-source 10.10.2.2 2>/dev/null || true

    # ---------------------------------------------------------------
    # 3. Starting其他 NF（不需 sudo）
    # ---------------------------------------------------------------
    export GIN_MODE=release
    cd "${FREE5GC_DIR}" || exit 1
    NF_LIST="nrf amf smf udr pcf udm nssf ausf chf nef"
    for nf in $NF_LIST; do
        echo ">>> Starting ${nf}..."
        ns_exec "${FREE5GC_DIR}/bin/${nf}" \
            -c "${RUNTIME_CFG_DIR}/${nf}cfg.yaml" \
            -l "$LOG_DIR/free5gc.log" &
        NF_PID=$!
        echo "${nf}:${NF_PID}" >> "$PID_FILE"
        echo "  ${nf} PID: $NF_PID"
        sleep 0.2
    done

    echo ""
    echo "✓ free5gc 所有 NF 已在 $NS 內Starting"
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
        cleanup_residual_nf
        ns_exec mongod --shutdown --dbpath /tmp/core-ns-mongo 2>/dev/null || true
    fi

    echo "✓ free5gc 已停止"
}

show_status() {
    check_ns
    echo "=== $NS 內的 free5gc Status ==="
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
                echo "  ✗ $name (PID: $pid) — Not running"
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
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
