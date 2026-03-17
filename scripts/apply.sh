#!/usr/bin/env bash
# =============================================================================
# apply.sh — Read YAML config and apply to Controller via ziti edge CLI
#
# Usage:
#   ./apply.sh services      policies/services.yml
#   ./apply.sh identities    policies/identities.yml
#   ./apply.sh policies       policies/service-policies.yml
#   ./apply.sh router-policies policies/edge-router-policies.yml
#
# Dependencies: yq (https://github.com/mikefarah/yq), jq, ziti CLI
# =============================================================================

set -euo pipefail

# Find ziti binary (prioritize project directory)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ZITI="${PROJECT_DIR}/bin/ziti"
if [ ! -x "$ZITI" ]; then
    ZITI="$(which ziti 2>/dev/null || true)"
fi
if [ -z "$ZITI" ] || [ ! -x "$ZITI" ]; then
    echo "ERROR: ziti CLI not found, please run make download first" >&2
    exit 1
fi

# Ensure yq is available
if ! command -v yq &>/dev/null; then
    echo ">>> Installing yq..."
    sudo wget -qO /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
    sudo chmod +x /usr/local/bin/yq
fi

ACTION="$1"
YAML_FILE="$2"

# Check if resource already exists
resource_exists() {
    local type="$1" name="$2"
    local resource_name

    case "$type" in
        config) resource_name="configs" ;;
        service) resource_name="services" ;;
        identity) resource_name="identities" ;;
        service-policy) resource_name="service-policies" ;;
        edge-router-policy) resource_name="edge-router-policies" ;;
        service-edge-router-policy) resource_name="service-edge-router-policies" ;;
        *)
            echo "ERROR: unsupported resource type '$type'" >&2
            return 1
            ;;
    esac

    $ZITI edge list "$resource_name" "name = \"${name}\" limit 1" --output-json 2>/dev/null \
        | jq -e '(.data // []) | length > 0' >/dev/null 2>&1
}

# =============================================================================
# Applying Services
# =============================================================================
apply_services() {
    local count
    count=$(yq '.services | length' "$YAML_FILE")
    echo "  Found ${count} Service definitions"

    for i in $(seq 0 $((count - 1))); do
        local name roles
        name=$(yq ".services[$i].name" "$YAML_FILE")
        roles=$(yq ".services[$i].roleAttributes | join(\",\")" "$YAML_FILE")

        # Create intercept config
        local intercept_data
        intercept_data=$(yq -o=json ".services[$i].configs.intercept" "$YAML_FILE")
        local intercept_cfg_name="${name}-intercept-config"

        if ! resource_exists "config" "$intercept_cfg_name"; then
            $ZITI edge create config "$intercept_cfg_name" intercept.v1 "$intercept_data" && \
                echo "  [+] Config '${intercept_cfg_name}' created successfully" || \
                echo "  [!] Config '${intercept_cfg_name}' creation failed"
        else
            $ZITI edge update config "$intercept_cfg_name" --data "$intercept_data" >/dev/null 2>&1 && \
                echo "  [=] Config '${intercept_cfg_name}' updated" || \
                echo "  [!] Config '${intercept_cfg_name}' update failed"
        fi

        # Create host config
        local host_data
        host_data=$(yq -o=json ".services[$i].configs.host" "$YAML_FILE")
        local host_cfg_name="${name}-host-config"

        if ! resource_exists "config" "$host_cfg_name"; then
            $ZITI edge create config "$host_cfg_name" host.v1 "$host_data" && \
                echo "  [+] Config '${host_cfg_name}' created successfully" || \
                echo "  [!] Config '${host_cfg_name}' creation failed"
        else
            $ZITI edge update config "$host_cfg_name" --data "$host_data" >/dev/null 2>&1 && \
                echo "  [=] Config '${host_cfg_name}' updated" || \
                echo "  [!] Config '${host_cfg_name}' update failed"
        fi

        # 建立 service
        if ! resource_exists "service" "$name"; then
            $ZITI edge create service "$name" \
                --configs "${intercept_cfg_name},${host_cfg_name}" \
                -a "$roles" && \
                echo "  [+] Service '${name}' created successfully" || \
                echo "  [!] Service '${name}' creation failed"
        else
            $ZITI edge update service "$name" \
                --configs "${intercept_cfg_name},${host_cfg_name}" \
                -a "$roles" >/dev/null 2>&1 && \
                echo "  [=] Service '${name}' updated（configs/roles 已同步）" || \
                echo "  [!] Service '${name}' update failed"
        fi
    done
}

# =============================================================================
# Applying Identities
# =============================================================================
apply_identities() {
    local count
    count=$(yq '.identities | length' "$YAML_FILE")
    echo "  Found ${count} Identity definitions"

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
                echo "  [+] Identity '${name}' created successfully → JWT: ${jwt_dir}/${name}.jwt" || \
                echo "  [!] Identity '${name}' creation failed"
        else
            # 更新角色標籤
            $ZITI edge update identity "$name" -a "$roles" 2>/dev/null
            echo "  [=] Identity '${name}' 已存在（角色updated: ${roles}）"
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
        local name type id_roles svc_roles id_count svc_count id_roles_csv svc_roles_csv
        name=$(yq ".servicePolicies[$i].name" "$YAML_FILE")
        type=$(yq ".servicePolicies[$i].type" "$YAML_FILE")

        id_roles=()
        id_count=$(yq ".servicePolicies[$i].identityRoles | length" "$YAML_FILE")
        for j in $(seq 0 $((id_count - 1))); do
            id_roles+=("$(yq ".servicePolicies[$i].identityRoles[$j]" "$YAML_FILE")")
        done

        svc_roles=()
        svc_count=$(yq ".servicePolicies[$i].serviceRoles | length" "$YAML_FILE")
        for j in $(seq 0 $((svc_count - 1))); do
            svc_roles+=("$(yq ".servicePolicies[$i].serviceRoles[$j]" "$YAML_FILE")")
        done

        id_roles_csv=$(IFS=,; echo "${id_roles[*]}")
        svc_roles_csv=$(IFS=,; echo "${svc_roles[*]}")

        if ! resource_exists "service-policy" "$name"; then
            $ZITI edge create service-policy "$name" "$type" \
                --identity-roles "$id_roles_csv" \
                --service-roles "$svc_roles_csv" && \
                echo "  [+] ServicePolicy '${name}' (${type}) created successfully" || \
                echo "  [!] ServicePolicy '${name}' creation failed"
        else
            $ZITI edge update service-policy "$name" \
                --identity-roles "$id_roles_csv" \
                --service-roles "$svc_roles_csv" >/dev/null 2>&1 && \
                echo "  [=] ServicePolicy '${name}' updated" || \
                echo "  [!] ServicePolicy '${name}' update failed"
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
        local name id_roles er_roles id_count er_count id_roles_csv er_roles_csv
        name=$(yq ".edgeRouterPolicies[$i].name" "$YAML_FILE")

        id_roles=()
        id_count=$(yq ".edgeRouterPolicies[$i].identityRoles | length" "$YAML_FILE")
        for j in $(seq 0 $((id_count - 1))); do
            id_roles+=("$(yq ".edgeRouterPolicies[$i].identityRoles[$j]" "$YAML_FILE")")
        done

        er_roles=()
        er_count=$(yq ".edgeRouterPolicies[$i].edgeRouterRoles | length" "$YAML_FILE")
        for j in $(seq 0 $((er_count - 1))); do
            er_roles+=("$(yq ".edgeRouterPolicies[$i].edgeRouterRoles[$j]" "$YAML_FILE")")
        done

        id_roles_csv=$(IFS=,; echo "${id_roles[*]}")
        er_roles_csv=$(IFS=,; echo "${er_roles[*]}")

        if ! resource_exists "edge-router-policy" "$name"; then
            $ZITI edge create edge-router-policy "$name" \
                --identity-roles "$id_roles_csv" \
                --edge-router-roles "$er_roles_csv" && \
                echo "  [+] EdgeRouterPolicy '${name}' created successfully" || \
                echo "  [!] EdgeRouterPolicy '${name}' creation failed"
        else
            $ZITI edge update edge-router-policy "$name" \
                --identity-roles "$id_roles_csv" \
                --edge-router-roles "$er_roles_csv" >/dev/null 2>&1 && \
                echo "  [=] EdgeRouterPolicy '${name}' updated" || \
                echo "  [!] EdgeRouterPolicy '${name}' update failed"
        fi
    done

    # Service Edge Router Policies
    local serp_count
    serp_count=$(yq '.serviceEdgeRouterPolicies | length' "$YAML_FILE")
    echo "  找到 ${serp_count} 個 Service Edge Router Policy 定義"

    for i in $(seq 0 $((serp_count - 1))); do
        local name svc_roles er_roles svc_count er_count svc_roles_csv er_roles_csv
        name=$(yq ".serviceEdgeRouterPolicies[$i].name" "$YAML_FILE")

        svc_roles=()
        svc_count=$(yq ".serviceEdgeRouterPolicies[$i].serviceRoles | length" "$YAML_FILE")
        for j in $(seq 0 $((svc_count - 1))); do
            svc_roles+=("$(yq ".serviceEdgeRouterPolicies[$i].serviceRoles[$j]" "$YAML_FILE")")
        done

        er_roles=()
        er_count=$(yq ".serviceEdgeRouterPolicies[$i].edgeRouterRoles | length" "$YAML_FILE")
        for j in $(seq 0 $((er_count - 1))); do
            er_roles+=("$(yq ".serviceEdgeRouterPolicies[$i].edgeRouterRoles[$j]" "$YAML_FILE")")
        done

        svc_roles_csv=$(IFS=,; echo "${svc_roles[*]}")
        er_roles_csv=$(IFS=,; echo "${er_roles[*]}")

        if ! resource_exists "service-edge-router-policy" "$name"; then
            $ZITI edge create service-edge-router-policy "$name" \
                --service-roles "$svc_roles_csv" \
                --edge-router-roles "$er_roles_csv" && \
                echo "  [+] ServiceEdgeRouterPolicy '${name}' created successfully" || \
                echo "  [!] ServiceEdgeRouterPolicy '${name}' creation failed"
        else
            $ZITI edge update service-edge-router-policy "$name" \
                --service-roles "$svc_roles_csv" \
                --edge-router-roles "$er_roles_csv" >/dev/null 2>&1 && \
                echo "  [=] ServiceEdgeRouterPolicy '${name}' updated" || \
                echo "  [!] ServiceEdgeRouterPolicy '${name}' update failed"
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
