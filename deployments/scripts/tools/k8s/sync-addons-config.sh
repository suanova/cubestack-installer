#!/bin/bash
# ============================================================
# sync-addons-config.sh — 从 cluster.conf 组件开关生成 kubespray addons.yml
# 职责: 让 cluster.conf 成为组件启用的唯一数据源:
#   REGISTRY_ENABLED / METALLB_ENABLED / LOCAL_PATH_ENABLED / METRICS_SERVER_ENABLED
#   HELM_ENABLED / INGRESS_NGINX_ENABLED / DASHBOARD_ENABLED / CERT_MANAGER_ENABLED
# 数据源: deployments/config/cluster.conf (变量均带默认值, 缺省不影响)
# 生成: inventory/<cluster>/group_vars/k8s_cluster/addons.yml 中的 *_enabled 行
# 幂等: 每次执行收敛到 cluster.conf 状态; 其余 addons.yml 内容(地址池等)不动
# 用法: ./sync-addons-config.sh
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

INV_DIR="${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster}"
ADDONS_YML="${INV_DIR}/group_vars/k8s_cluster/addons.yml"
[ -f "${ADDONS_YML}" ] || { warn "未找到 ${ADDONS_YML},跳过 addons 同步"; exit 0; }

# 布尔归一化: 支持 true/false/1/0/yes/no, 缺省按 kubespray 默认
bool() { case "${1:-}" in 1|true|yes|on) echo true;; 0|false|no|off) echo false;; esac; }

# 更新 addons.yml 中 <key> 的值(幂等: 取消注释并覆盖; 不存在则末尾追加)
# 用法: set_key <yaml_key> <yaml_value>
set_key() {
    local key="$1" val="$2"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}:" "${ADDONS_YML}"; then
        sed -i -E "s/^[[:space:]]*#?[[:space:]]*${key}:.*/${key}: ${val}/" "${ADDONS_YML}"
    else
        echo "${key}: ${val}" >> "${ADDONS_YML}"
    fi
}

say "同步 addons.yml 组件开关(数据源: ${CLUSTER_CONF})..."

# ---- 布尔型组件开关 ----
# 集群内 registry 默认不部署(REGISTRY_ENABLED 默认 0/false); 集群外仓库用 Harbor
set_key registry_enabled            "$(bool "${REGISTRY_ENABLED:-false}")"
set_key metallb_enabled             "$(bool "${METALLB_ENABLED:-true}")"
set_key metallb_speaker_enabled     "$(bool "${METALLB_ENABLED:-true}")"
set_key local_path_provisioner_enabled "$(bool "${LOCAL_PATH_ENABLED:-false}")"
set_key metrics_server_enabled      "$(bool "${METRICS_SERVER_ENABLED:-true}")"
set_key helm_enabled                "$(bool "${HELM_ENABLED:-true}")"
set_key ingress_nginx_enabled       "$(bool "${INGRESS_NGINX_ENABLED:-false}")"
set_key dashboard_enabled           "$(bool "${DASHBOARD_ENABLED:-false}")"
set_key cert_manager_enabled        "$(bool "${CERT_MANAGER_ENABLED:-false}")"
set_key gateway_api_enabled         "$(bool "${GATEWAY_API_ENABLED:-false}")"

# ---- 字符串型组件配置(有则覆盖) ----
if [ -n "${REGISTRY_SERVICE_TYPE:-}" ]; then
    set_key registry_service_type "${REGISTRY_SERVICE_TYPE}"
fi
if [ -n "${REGISTRY_STORAGE_CLASS:-}" ]; then
    set_key registry_storage_class "\"${REGISTRY_STORAGE_CLASS}\""
fi

ok "addons.yml 组件开关已同步: $(grep -cE '^[a-z_]+_enabled: (true|false)$' "${ADDONS_YML}") 项"
