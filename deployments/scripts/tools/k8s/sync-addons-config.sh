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
    local key="$1" val="$2" esc
    # 值里可能有 `/`(mirror 镜像名)与 `&`(sed 替换串特殊字符) ⇒ 先转义再放进 `s///`
    esc="${val//\\/\\\\}"
    esc="${esc//&/\\&}"
    esc="${esc//\//\\/}"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}:" "${ADDONS_YML}"; then
        sed -i -E "s/^[[:space:]]*#?[[:space:]]*${key}:.*/${key}: ${esc}/" "${ADDONS_YML}"
    else
        echo "${key}: ${val}" >> "${ADDONS_YML}"
    fi
}

# 关闭一个由本脚本管理的键(注释掉, 让 kubespray 回到自己的默认值)。
# ⚠ 不能只"不写": 上一次运行写入的生效值会留在文件里, 切换开关后仍被 kubespray 读到。
unset_key() {
    local key="$1"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}:" "${ADDONS_YML}"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}:.*|# ${key}: 已由 sync-addons-config.sh 关闭(HARBOR_MIRROR_ENABLED=false)|" "${ADDONS_YML}"
    fi
}

say "同步 addons.yml 组件开关(数据源: ${CLUSTER_CONF})..."

# ---- 布尔型组件开关 ----
# 集群内 registry 默认不部署(REGISTRY_ENABLED 默认 0/false); 集群外仓库用 Harbor
set_key registry_enabled            "$(bool "${REGISTRY_ENABLED:-false}")"
# 服务暴露方式: nodeport 模式(测试环境)自动关闭 MetalLB —— 对外访问全部走 NodePort, 不依赖 L2 VIP。
# (生产 metallb 模式才按 METALLB_ENABLED 开关)
_metallb="${METALLB_ENABLED:-true}"
[ "${SERVICE_EXPOSE_MODE:-metallb}" = "nodeport" ] && _metallb=false
set_key metallb_enabled             "$(bool "${_metallb}")"
set_key metallb_speaker_enabled     "$(bool "${_metallb}")"
set_key local_volume_provisioner_enabled "$(bool "${LOCAL_VOLUME_PROVISIONER_ENABLED:-false}")"
set_key node_feature_discovery_enabled   "$(bool "${NFD_ENABLED:-false}")"
set_key local_path_provisioner_enabled "$(bool "${LOCAL_PATH_ENABLED:-false}")"
set_key metrics_server_enabled      "$(bool "${METRICS_SERVER_ENABLED:-true}")"
set_key helm_enabled                "$(bool "${HELM_ENABLED:-true}")"
set_key ingress_nginx_enabled       "$(bool "${INGRESS_NGINX_ENABLED:-false}")"
set_key dashboard_enabled           "$(bool "${DASHBOARD_ENABLED:-false}")"
set_key cert_manager_enabled        "$(bool "${CERT_MANAGER_ENABLED:-false}")"
set_key gateway_api_enabled         "$(bool "${GATEWAY_API_ENABLED:-false}")"

# ingress-nginx Service 类型: 跟随全局暴露方式(metallb→LoadBalancer, nodeport→NodePort + 30080/30081)
if [ "${SERVICE_EXPOSE_MODE:-metallb}" = "nodeport" ]; then
    set_key ingress_nginx_service_type "NodePort"
    set_key ingress_nginx_service_nodeport_http "30080"
    set_key ingress_nginx_service_nodeport_https "30081"
else
    set_key ingress_nginx_service_type "LoadBalancer"
fi

# ---- 字符串型组件配置(有则覆盖) ----
if [ -n "${REGISTRY_SERVICE_TYPE:-}" ]; then
    # kubespray registry 角色校验 registry_service_type ∈ {ClusterIP, LoadBalancer, NodePort},
    # 必须大写; 但 cluster.conf 用小写(loadbalancer/nodeport)—— 这里归一化, 否则 registry addon 部署失败
    _rtype="${REGISTRY_SERVICE_TYPE}"
    case "${_rtype,,}" in
        loadbalancer) _rtype="LoadBalancer" ;;
        nodeport)     _rtype="NodePort" ;;
        clusterip)    _rtype="ClusterIP" ;;
    esac
    set_key registry_service_type "${_rtype}"
fi
if [ -n "${REGISTRY_STORAGE_CLASS:-}" ]; then
    set_key registry_storage_class "\"${REGISTRY_STORAGE_CLASS}\""
fi
# registry PVC 容量: kubespray 缺省仅 10Gi, 放不下 dev_lab(≈21G)等大镜像 ⇒ 盘满后 push 全 500
# (2026-10-13 实机事故)。存量集群的扩容由 05_k8s_registry.sh 幂等执行 —— 这里只决定**新建** PVC
# 的声明大小(同一数据源 REGISTRY_DISK_SIZE, 两处默认值必须一致)。
set_key registry_disk_size "\"${REGISTRY_DISK_SIZE:-200Gi}\""

# ---- 镜像源: 先于内置 registry 就绪的 addon 必须引用预加载的 mirror 名 ----
# 版本树的离线 tar 以 mirror 名(skopeo RepoTags)打包; ctr import 后 containerd 里只有 mirror 名。
# local-path-provisioner / 它的 helper busybox / registry 自身都在内置 registry 之前启动,
# 写上游名(docker.io/...)在断网环境必然 ImagePullBackOff(local-path helper 还会 120s 超时,
# PVC 无法 Bound → registry 起不来)。helper 的 tag 必须与版本树一致, 不能沿用 kubespray 的 latest。
# *_pod_image_* 是 cubestack 补丁 17 引入的"仅 Pod 引用"变量: download role 仍按上游 repo 推导
# 缓存 tar 文件名(与版本树 tar 名一致), 因此不能直接改 *_image_repo —— 那会让 download 在
# 离线环境去找不存在的 mirror 名 tar 并尝试联网拉取。
_mirror="$(harbor_mirror_base)"
if [ -n "${_mirror}" ]; then
    set_key local_path_provisioner_pod_image_repo "\"${_mirror}/docker.io/rancher/local-path-provisioner\""
    if [ -n "${LOCAL_PATH_VERSION:-}" ]; then
        set_key local_path_provisioner_pod_image_tag "\"${LOCAL_PATH_VERSION}\""
    fi
    set_key local_path_provisioner_helper_image_repo "\"${_mirror}/docker.io/library/busybox\""
    if [ -n "${BUSYBOX_TAG:-}" ]; then
        set_key local_path_provisioner_helper_image_tag "\"${BUSYBOX_TAG}\""
    fi
    set_key registry_pod_image_repo "\"${_mirror}/docker.io/library/registry\""
    if [ -n "${REGISTRY_IMAGE_TAG:-}" ]; then
        set_key registry_pod_image_tag "\"${REGISTRY_IMAGE_TAG}\""
    fi
    # 节点侧 API 本地代理(nginx-proxy 静态 Pod)同样是 docker.io 镜像
    set_key nginx_pod_image_repo "\"${_mirror}/docker.io/library/nginx\""
    if [ -n "${API_LB_NGINX_IMAGE_TAG:-}" ]; then
        set_key nginx_pod_image_tag "\"${API_LB_NGINX_IMAGE_TAG}\""
    fi
    ok "addon 镜像源已同步 → ${_mirror}(local-path/helper/registry 直连预加载镜像)"
else
    unset_key local_path_provisioner_pod_image_repo
    unset_key local_path_provisioner_pod_image_tag
    unset_key local_path_provisioner_helper_image_repo
    unset_key local_path_provisioner_helper_image_tag
    unset_key registry_pod_image_repo
    unset_key registry_pod_image_tag
    unset_key nginx_pod_image_repo
    unset_key nginx_pod_image_tag
    say "HARBOR_MIRROR_ENABLED=false → addon 镜像源保持上游名(kubespray 默认)"
fi
unset _mirror

ok "addons.yml 组件开关已同步: $(grep -cE '^[a-z_]+_enabled: (true|false)$' "${ADDONS_YML}") 项"
