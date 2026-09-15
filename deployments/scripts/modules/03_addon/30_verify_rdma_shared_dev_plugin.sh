#!/bin/bash
# ============================================================
# MODULE: verify_rdma_shared_dev_plugin
# DESC: 端到端验证 k8s-rdma-shared-dev-plugin 真正工作(非仅 DaemonSet Running):
#       ① DaemonSet pod 全 Running → ② ConfigMap(资源池)存在
#       → ③ 从 ConfigMap 解析全部扩展资源 → ④ 逐个资源遍历节点检查 allocatable 注册
#       (pool 单资源 / per-hca 每块 HCA 一个资源, 自动适配; 无 HCA 节点自然没有, warn 说明)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: rdma_shared_dev_plugin
# 说明:
#   · **验证模块不设 TOGGLE**(否则 RDMA_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_rdma_shared_dev_plugin 在安装后单个执行。
#   · **门禁看实际部署, 不看配置开关**(仿 verify_lws): 只要 rdma-shared-dp-ds 实际在跑
#     就验证(无论 RDMA_ENABLED true/false, 例如 --steps rdma_shared_dev_plugin 单独部署过);
#     仅当"DaemonSet 不在 且 RDMA_ENABLED≠true"才跳过。
#   · 资源注册: 插件经 /var/lib/kubelet/device-plugins 把资源注册进 kubelet → 节点
#     allocatable 出现扩展资源。无 HCA 节点不注册(自然)。
#   · **资源名动态解析**: 不依赖 RDMA_RESOURCE_NAME 单一资源(pool 模式是单资源, per-hca
#     模式每块 HCA 一个资源名如 mlx5_0/mlx5_1...)。本模块从 ConfigMap 的 config.json 解析
#     configList 全部条目, 逐个资源逐个节点检查 allocatable。
# 数据源: cluster.conf (RDMA_ENABLED / RDMA_RESOURCE_PREFIX / RDMA_NAMESPACE / NODES /
#         SSH_KEY_NAME); 资源列表动态读取自 ConfigMap(rdma-devices/config.json)
# 用法: sudo ./deploy-cluster.sh --steps verify_rdma_shared_dev_plugin
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

NS="${RDMA_NAMESPACE:-kube-system}"
DS_NAME="rdma-shared-dp-ds"
RES_PREFIX="${RDMA_RESOURCE_PREFIX:-nvidia.com}"

# ---- 门禁: 以实际部署为准(DaemonSet 是否在跑) ----
DEPLOYED="$( (SSH "${K} -n ${NS} get ds ${DS_NAME} --no-headers 2>/dev/null" || true) | wc -l )"
if [ "${DEPLOYED:-0}" -eq 0 ] && [ "${RDMA_ENABLED:-false}" != "true" ]; then
    say "RDMA 插件未部署(DaemonSet 不存在且 RDMA_ENABLED≠true), 跳过验证(先 --steps rdma_shared_dev_plugin 部署)"
    exit 0
fi

say "Verify RDMA 共享设备插件: DaemonSet → ConfigMap → 节点扩展资源注册..."

say "  ① 检查 rdma-shared-dp-ds pod 全 Running..."
_NRUN="$( (SSH "${K} -n ${NS} get pods -l name=rdma-shared-dp --no-headers 2>/dev/null" || true) | awk '$3=="Running"{n++} END{print n+0}' )"
_NTOT="$( (SSH "${K} -n ${NS} get pods -l name=rdma-shared-dp --no-headers --ignore-not-found 2>/dev/null" || true) | wc -l )"
[ "${_NRUN:-0}" -ge 1 ] || { err "rdma-shared-dp-ds 无 Running pod(${_NRUN}/${_NTOT}); 检查镜像拉取/privileged 状态"; exit 1; }
ok "    rdma pod Running ${_NRUN}/${_NTOT} ✓"

say "  ② 检查 ConfigMap(资源池)存在..."
_CM="$(SSH "${K} -n ${NS} get cm rdma-devices --no-headers 2>/dev/null" || true)"
[ -n "${_CM}" ] && ok "    ConfigMap ${NS}/rdma-devices 存在 ✓" \
    || { err "ConfigMap ${NS}/rdma-devices 不存在(先 --steps rdma_shared_dev_plugin 部署)"; exit 1; }

say "  ③ 从 ConfigMap 解析全部扩展资源, 遍历节点检查 allocatable..."
# config.json 由 10_rdma 模块生成: pool=单条目, per-hca=每块 HCA 一个条目
# 取 data["config.json"]: 键含点号不能走 jsonpath 点路径, 用 go-template index
_CM_JSON="$(SSH "${K} -n ${NS} get cm rdma-devices -o go-template='{{index .data \"config.json\"}}' 2>/dev/null" || true)"
# 解析 configList 各条目 resourcePrefix + resourceName(纯 awk, 不依赖 jq/python3):
# config.json 每条 configList 条目按顺序含一个 resourcePrefix 和紧跟的 resourceName,
# awk 逐行提取二者并逐对配对输出 "前缀/资源名"。
_RES_LIST="$(echo "${_CM_JSON}" | awk '
/"resourcePrefix"/ {
    p=$0
    sub(/^.*"resourcePrefix"[[:space:]]*:[[:space:]]*"/, "", p)
    sub(/"[[:space:]]*,?[[:space:]]*$/, "", p)
}
/"resourceName"/ {
    n=$0
    sub(/^.*"resourceName"[[:space:]]*:[[:space:]]*"/, "", n)
    sub(/"[[:space:]]*,?[[:space:]]*$/, "", n)
    if (p!="" && n!="") { printf " %s/%s", p, n; p="" }
}' 2>/dev/null || true)"
# 兜底: 解析失败/为空则退回配置里的单一资源(pool 模式)
if [ -z "${_RES_LIST}" ]; then
    RES_NAME="${RDMA_RESOURCE_NAME:-mlx5_0}"
    _RES_LIST="${RES_PREFIX}/${RES_NAME}"
    warn "  ConfigMap config.json 解析失败或为空, 退回配置单一资源: ${RES_PREFIX}/${RES_NAME}(per-hca 多资源请检查 10_rdma 生成的 config.json)"
fi
say "    资源列表:${_RES_LIST}"
_NODES="$(SSH "${K} get nodes --no-headers 2>/dev/null" || true)"
_NODES_TOTAL="$(echo "${_NODES}" | grep -c . || true)"; _NODES_TOTAL="${_NODES_TOTAL:-0}"
[ "${_NODES_TOTAL:-0}" -ge 1 ] || { err "未获取到任何节点(kubectl get nodes 为空); 检查集群可达性"; exit 1; }
_FOUND=0; _RES_OK=""; _RES_MISS=""
for _res in ${_RES_LIST}; do
    _NODES_WITH=0
    while IFS= read -r _n; do
        [ -z "${_n}" ] && continue
        _node="$(echo "${_n}" | awk '{print $1}')"
        # 查该节点 allocatable 是否含该扩展资源
        _alloc="$(SSH "${K} get node ${_node} -o jsonpath='{.status.allocatable}' 2>/dev/null" || true)"
        if echo "${_alloc}" | grep -q "${_res}"; then
            _NODES_WITH=$((_NODES_WITH + 1))
        fi
    done <<< "${_NODES}"
    if [ "${_NODES_WITH}" -ge 1 ]; then
        _FOUND=1; _RES_OK="${_RES_OK} ${_res}(${_NODES_WITH}节点)"
        say "    ${_res}: ${_NODES_WITH}/${_NODES_TOTAL} 节点注册 ✓"
    else
        _RES_MISS="${_RES_MISS} ${_res}"
        say "    ${_res}: 无节点注册(该 HCA 未检测到或驱动未加载, 属正常)"
    fi
done
if [ "${_FOUND}" = "1" ]; then
    ok "    已注册:${_RES_OK}(RDMA 扩展资源可用) ✓"
    if [ -n "${_RES_MISS}" ]; then
        warn "    未注册:${_RES_MISS}(无 HCA 网卡节点/驱动未加载/该资源本节点不存在, 单节点验证可通过)"
    fi
else
    warn "    暂无节点注册任何 RDMA 资源(共 ${_NODES_TOTAL} 节点)。"
    warn "    可能原因: ① 节点无 RDMA 网卡/驱动(ibstat 验证); ② RDMA_VENDORS/RDMA_IF_NAMES 与设备不匹配;"
    warn "    ③ 插件尚未周期更新(periodicUpdateInterval)。查看: kubectl -n ${NS} logs -l name=rdma-shared-dp --tail=50"
fi

echo "---------------------------------------------"
if [ "${_FOUND}" = "1" ]; then
    ok "RDMA 共享设备插件验证通过: DaemonSet Ready → ConfigMap 存在 → 节点注册资源:${_RES_OK}"
else
    err "RDMA 插件验证未通过: 无节点注册扩展资源(检查节点驱动与 RDMA_* 配置); 见上方排查指引"
    exit 1
fi
unset _NRUN _NTOT _CM _CM_JSON _RES_LIST _RES_OK _RES_MISS _FOUND _NODES_WITH _NODES_TOTAL _NODES _n _node _alloc _block _p 2>/dev/null || true
