#!/bin/bash
# ============================================================
# MODULE: k8s_deploy
# DESC: 部署 kubespray 集群(离线)
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: K8S_ENABLED
# 说明: 调用 cubestack-offline.sh install; 透传 cluster.conf 中 PRELOAD_IMAGE_PATTERNS
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ⚠ 部署 kubespray 前醒目提示 METALLB_POOL 需正确配置(sleep 30 倒计时供人工确认/修改)
# MetalLB Layer2 要求池内 IP 与集群节点同一二层网络且空闲; 虚拟机集群应已由
# create-vms.sh 自动推导为 VM 网段, 裸金属集群需手动设置(如 10.66.1.130-139)。
# nodeport 暴露模式(SERVICE_EXPOSE_MODE=nodeport)不部署 MetalLB, 地址池与本次部署无关 → 跳过提示。
if [ "${SERVICE_EXPOSE_MODE:-nodeport}" = "metallb" ]; then
    echo ""
    echo -e "\033[41m\033[97m================================================================\033[0m"
    echo -e "\033[41m\033[97m ⚠⚠⚠  即将部署 kubespray, 请确认 METALLB_POOL 地址池已正确配置  ⚠⚠⚠\033[0m"
    echo -e "\033[41m\033[97m  当前: METALLB_POOL=${METALLB_POOL:-<未设置>}\033[0m"
    echo -e "\033[41m\033[97m  要求: 池内 IP 必须与集群节点同一二层网络且空闲(避免被 DHCP 占用):\033[0m"
    echo -e "\033[41m\033[97m    · 虚拟机集群: 已由 create-vms.sh 自动推导为 VM 网段(如 10.244.1.200-209)\033[0m"
    echo -e "\033[41m\033[97m    · 裸金属集群: 手动填节点物理网段空闲段(如 10.66.1.130-139)\033[0m"
    echo -e "\033[41m\033[97m  如需修改: 在 ${CLUSTER_CONF} 的 METALLB_POOL 行\033[0m"
    echo -e "\033[41m\033[97m================================================================\033[0m"
    # 倒计时(单行刷新)
    for _c in $(seq 30 -1 1); do
        printf "\r%s" "$(printf '\033[41m\033[97m  ⏳ 倒计时 %d 秒继续        \033[0m' "${_c}")"
        sleep 1
    done
    printf "\r%s\n" "$(printf '\033[0m  %s             ')"
    printf "\r%s\n" "$(printf '\033[0m  %s             ')"
fi

# 部署前强制重新生成 inventory(hosts.yml + group_vars 均由当前 cluster.conf 派生):
# 即使本次未执行 inventory 模块(--skip inventory / --steps k8s), 也保证 kubespray
# 始终按当前 cluster.conf 的节点部署, 不因断点续跑跳过而使用过期的 hosts.yml
say "重新生成 inventory(依据当前 ${CLUSTER_CONF})..."
bash "${SCRIPT_DIR}/tools/k8s/gen-inventory.sh"

# registry 暴露归一化 + 预检(kubespray 对 registry_service_* 严格校验: 定义了 loadbalancer_ip 但
# type≠LoadBalancer 直接 fail, 曾因 addons.yml 残留旧环境 VIP 导致整次部署中断)。
# gen-inventory 已内部调用 sync, 此处再显式兜底归一化一次, 并在 kubespray 前快速失败给出可操作提示。
bash "${SCRIPT_DIR}/tools/k8s/sync-kubespray-config.sh" >/dev/null 2>&1 || \
    warn "sync-kubespray-config.sh 归一化失败(以下方预检为准)"
_ADDONS_YML="${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster}/group_vars/k8s_cluster/addons.yml"
if [ -f "${_ADDONS_YML}" ]; then
    _EXPOSE="$(echo "${SERVICE_EXPOSE_MODE:-nodeport}" | tr '[:upper:]' '[:lower:]')"
    _BAD=""
    if [ "${_EXPOSE}" = "nodeport" ] && grep -qE '^[[:space:]]*registry_service_loadbalancer_ip:[[:space:]]*[^#[:space:]]' "${_ADDONS_YML}"; then
        _BAD="registry_service_loadbalancer_ip(nodeport 模式须注释)"
    fi
    if [ "${_EXPOSE}" != "nodeport" ] && grep -qE '^[[:space:]]*registry_service_nodeport:' "${_ADDONS_YML}"; then
        _BAD="${_BAD:+${_BAD} + }registry_service_nodeport(metallb 模式须注释)"
    fi
    if [ -n "${_BAD}" ]; then
        err "addons.yml registry 暴露配置与 SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE:-nodeport} 不一致: ${_BAD}"
        err "修复: 重跑 bash tools/k8s/sync-kubespray-config.sh(自动归一化), 或手工注释 ${_ADDONS_YML} 对应行后再部署"
        exit 1
    fi
    unset _BAD _EXPOSE
fi
unset _ADDONS_YML

OFFLINE_SCRIPT="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
[ -f "${OFFLINE_SCRIPT}" ] || { err "未找到 ${OFFLINE_SCRIPT}"; exit 1; }

say "执行 kubespray 离线部署 (via cubestack-offline.sh) ..."
# 透传 cluster.conf 的预加载镜像集合; 仅当显式定义了该变量(含空串=全量同步)才传递,
# 否则由 cubestack-offline.sh 回退内置默认最小集合
# 离线文件路径: OFFLINE_FILES_DIR(全局切换根目录) + CUBESTACK_LOCAL_REPO_DIR(完整路径, 最高优先)
OFFLINE_ENV=(
    "CUBESTACK_KUBESPRAY_DIR=${KUBESPRAY_DIR}"
    "CUBESTACK_INVENTORY_DIR=${KUBESPRAY_INV_DIR}"
    "OFFLINE_FILES_DIR=${OFFLINE_FILES_DIR}"
    "CUBESTACK_LOCAL_REPO_DIR=${LOCAL_REPO_DIR}"
)
[ -n "${PRELOAD_IMAGE_PATTERNS+x}" ] && \
    OFFLINE_ENV+=("CUBESTACK_PRELOAD_IMAGE_PATTERNS=${PRELOAD_IMAGE_PATTERNS}")
env "${OFFLINE_ENV[@]}" bash "${OFFLINE_SCRIPT}" install
ok "kubespray 集群部署完成"
