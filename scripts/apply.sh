#!/usr/bin/env bash
# =============================================================================
# apply.sh — 讀取 YAML 設定檔，透過 ziti edge CLI 套用到 Controller
#
# 用法:
#   ./apply.sh services      policies/services.yml
#   ./apply.sh identities    policies/identities.yml
#   ./apply.sh policies       policies/service-policies.yml
#   ./apply.sh router-policies policies/edge-router-policies.yml
#
# 依賴: yq (https://github.com/mikefarah/yq), jq, ziti CLI
# =============================================================================

set -euo pipefail

# 找 ziti binary（優先用專案目錄內的）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ZITI="${PROJECT_DIR}/bin/ziti"
if [ ! -x "$ZITI" ]; then
    ZITI="$(which ziti 2>/dev/null || true)"
fi
if [ -z "$ZITI" ] || [ ! -x "$ZITI" ]; then
    echo "ERROR: 找不到 ziti CLI，請先執行 make download" >&2
    exit 1
fi

# 確保 yq 可用
if ! command -v yq &>/dev/null; then
    echo ">>> 安裝 yq..."
    sudo wget -qO /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
    sudo chmod +x /usr/local/bin/yq
fi

ACTION="$1"
YAML_FILE="$2"

# 檢查資源是否已存在
resource_exists() {
    local type="$1" name="$2"
    local count
    count=$($ZITI edge list "${type}s" "name=\"${name}\"" --output-json 2>/dev/null \
        | jq -r '.data.totalCount // 0' 2>/dev/null || echo 0)
    [ "$count" -gt 0 ]
}

# =============================================================================
# 套用 Services
# =============================================================================
apply_services() {
    local count
    count=$(yq '.services | length' "$YAML_FILE")
    echo "  找到 ${count} 個 Service 定義"

    for i in $(seq 0 $((count - 1))); do
        local name roles
        name=$(yq ".services[$i].name" "$YAML_FILE")
        roles=$(yq ".services[$i].roleAttributes | join(\",\")" "$YAML_FILE")

        # 建立 intercept config
        local intercept_data
        intercept_data=$(yq -o=json ".services[$i].configs.intercept" "$YAML_FILE")
        local intercept_cfg_name="${name}-intercept-config"

        if ! resource_exists "config" "$intercept_cfg_name"; then
            $ZITI edge create config "$intercept_cfg_name" intercept.v1 "$intercept_data" && \
                echo "  [+] Config '${intercept_cfg_name}' 建立成功" || \
                echo "  [!] Config '${intercept_cfg_name}' 建立失敗"
        else
            echo "  [=] Config '${intercept_cfg_name}' 已存在"
        fi

        # 建立 host config
        local host_data
        host_data=$(yq -o=json ".services[$i].configs.host" "$YAML_FILE")
        local host_cfg_name="${name}-host-config"

        if ! resource_exists "config" "$host_cfg_name"; then
            $ZITI edge create config "$host_cfg_name" host.v1 "$host_data" && \
                echo "  [+] Config '${host_cfg_name}' 建立成功" || \
                echo "  [!] Config '${host_cfg_name}' 建立失敗"
        else
            echo "  [=] Config '${host_cfg_name}' 已存在"
        fi

        # 建立 service
        if ! resource_exists "service" "$name"; then
            $ZITI edge create service "$name" \
                --configs "${intercept_cfg_name},${host_cfg_name}" \
                -a "$roles" && \
                echo "  [+] Service '${name}' 建立成功" || \
                echo "  [!] Service '${name}' 建立失敗"
        else
            # 更新角色標籤
            $ZITI edge update service "$name" -a "$roles" 2>/dev/null
            echo "  [=] Service '${name}' 已存在（角色已更新: ${roles}）"
        fi
    done
}

# =============================================================================
# 套用 Identities
# =============================================================================
apply_identities() {
    local count
    count=$(yq '.identities | length' "$YAML_FILE")
    echo "  找到 ${count} 個 Identity 定義"

    local jwt_dir="${PROJECT_DIR}/pki/identities"
    mkdir -p "$jwt_dir"

    for i in $(seq 0 $((count - 1))); do
        local name type roles
        name=$(yq ".identities[$i].name" "$YAML_FILE")
        type=$(yq ".identities[$i].type // \"Device\"" "$YAML_FILE")
        roles=$(yq ".identities[$i].roleAttributes | join(\",\")" "$YAML_FILE")

        if ! resource_exists "identity" "$name"; then
            $ZITI edge create identity "$name" \
                -a "$roles" \
                -o "${jwt_dir}/${name}.jwt" && \
                echo "  [+] Identity '${name}' 建立成功 → JWT: ${jwt_dir}/${name}.jwt" || \
                echo "  [!] Identity '${name}' 建立失敗"
        else
            # 更新角色標籤
            $ZITI edge update identity "$name" -a "$roles" 2>/dev/null
            echo "  [=] Identity '${name}' 已存在（角色已更新: ${roles}）"
        fi
    done
}

# =============================================================================
# 套用 Service Policies
# =============================================================================
apply_service_policies() {
    local count
    count=$(yq '.servicePolicies | length' "$YAML_FILE")
    echo "  找到 ${count} 個 Service Policy 定義"

    for i in $(seq 0 $((count - 1))); do
        local name type
        name=$(yq ".servicePolicies[$i].name" "$YAML_FILE")
        type=$(yq ".servicePolicies[$i].type" "$YAML_FILE")

        if ! resource_exists "service-policy" "$name"; then
            # 收集 identity roles
            local id_roles=()
            local id_count
            id_count=$(yq ".servicePolicies[$i].identityRoles | length" "$YAML_FILE")
            for j in $(seq 0 $((id_count - 1))); do
                id_roles+=($(yq ".servicePolicies[$i].identityRoles[$j]" "$YAML_FILE"))
            done

            # 收集 service roles
            local svc_roles=()
            local svc_count
            svc_count=$(yq ".servicePolicies[$i].serviceRoles | length" "$YAML_FILE")
            for j in $(seq 0 $((svc_count - 1))); do
                svc_roles+=($(yq ".servicePolicies[$i].serviceRoles[$j]" "$YAML_FILE"))
            done

            local id_roles_csv svc_roles_csv
            id_roles_csv=$(IFS=,; echo "${id_roles[*]}")
            svc_roles_csv=$(IFS=,; echo "${svc_roles[*]}")

            $ZITI edge create service-policy "$name" "$type" \
                --identity-roles "$id_roles_csv" \
                --service-roles "$svc_roles_csv" && \
                echo "  [+] ServicePolicy '${name}' (${type}) 建立成功" || \
                echo "  [!] ServicePolicy '${name}' 建立失敗"
        else
            echo "  [=] ServicePolicy '${name}' 已存在"
        fi
    done
}

# =============================================================================
# 套用 Edge Router Policies & Service Edge Router Policies
# =============================================================================
apply_router_policies() {
    # Edge Router Policies
    local erp_count
    erp_count=$(yq '.edgeRouterPolicies | length' "$YAML_FILE")
    echo "  找到 ${erp_count} 個 Edge Router Policy 定義"

    for i in $(seq 0 $((erp_count - 1))); do
        local name
        name=$(yq ".edgeRouterPolicies[$i].name" "$YAML_FILE")

        if ! resource_exists "edge-router-policy" "$name"; then
            local id_roles=()
            local id_count
            id_count=$(yq ".edgeRouterPolicies[$i].identityRoles | length" "$YAML_FILE")
            for j in $(seq 0 $((id_count - 1))); do
                id_roles+=($(yq ".edgeRouterPolicies[$i].identityRoles[$j]" "$YAML_FILE"))
            done

            local er_roles=()
            local er_count
            er_count=$(yq ".edgeRouterPolicies[$i].edgeRouterRoles | length" "$YAML_FILE")
            for j in $(seq 0 $((er_count - 1))); do
                er_roles+=($(yq ".edgeRouterPolicies[$i].edgeRouterRoles[$j]" "$YAML_FILE"))
            done

            local id_roles_csv er_roles_csv
            id_roles_csv=$(IFS=,; echo "${id_roles[*]}")
            er_roles_csv=$(IFS=,; echo "${er_roles[*]}")

            $ZITI edge create edge-router-policy "$name" \
                --identity-roles "$id_roles_csv" \
                --edge-router-roles "$er_roles_csv" && \
                echo "  [+] EdgeRouterPolicy '${name}' 建立成功" || \
                echo "  [!] EdgeRouterPolicy '${name}' 建立失敗"
        else
            echo "  [=] EdgeRouterPolicy '${name}' 已存在"
        fi
    done

    # Service Edge Router Policies
    local serp_count
    serp_count=$(yq '.serviceEdgeRouterPolicies | length' "$YAML_FILE")
    echo "  找到 ${serp_count} 個 Service Edge Router Policy 定義"

    for i in $(seq 0 $((serp_count - 1))); do
        local name
        name=$(yq ".serviceEdgeRouterPolicies[$i].name" "$YAML_FILE")

        if ! resource_exists "service-edge-router-policy" "$name"; then
            local svc_roles=()
            local svc_count
            svc_count=$(yq ".serviceEdgeRouterPolicies[$i].serviceRoles | length" "$YAML_FILE")
            for j in $(seq 0 $((svc_count - 1))); do
                svc_roles+=($(yq ".serviceEdgeRouterPolicies[$i].serviceRoles[$j]" "$YAML_FILE"))
            done

            local er_roles=()
            local er_count
            er_count=$(yq ".serviceEdgeRouterPolicies[$i].edgeRouterRoles | length" "$YAML_FILE")
            for j in $(seq 0 $((er_count - 1))); do
                er_roles+=($(yq ".serviceEdgeRouterPolicies[$i].edgeRouterRoles[$j]" "$YAML_FILE"))
            done

            local svc_roles_csv er_roles_csv
            svc_roles_csv=$(IFS=,; echo "${svc_roles[*]}")
            er_roles_csv=$(IFS=,; echo "${er_roles[*]}")

            $ZITI edge create service-edge-router-policy "$name" \
                --service-roles "$svc_roles_csv" \
                --edge-router-roles "$er_roles_csv" && \
                echo "  [+] ServiceEdgeRouterPolicy '${name}' 建立成功" || \
                echo "  [!] ServiceEdgeRouterPolicy '${name}' 建立失敗"
        else
            echo "  [=] ServiceEdgeRouterPolicy '${name}' 已存在"
        fi
    done
}

# =============================================================================
# 主程式
# =============================================================================
echo ""
echo "=== Apply: ${ACTION} from ${YAML_FILE} ==="
echo ""

case "$ACTION" in
    services)
        apply_services
        ;;
    identities)
        apply_identities
        ;;
    policies)
        apply_service_policies
        ;;
    router-policies)
        apply_router_policies
        ;;
    *)
        echo "ERROR: 未知的 action '${ACTION}'"
        echo "支援的 action: services, identities, policies, router-policies"
        exit 1
        ;;
esac

echo ""
echo "✓ 完成"
