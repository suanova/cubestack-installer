#!/bin/bash
# ============================================================
# MODULE: rdma_shared_dev_plugin
# DESC: 部署 Mellanox/NVIDIA k8s-rdma-shared-dev-plugin(Device Plugin, RDMA 扩展资源):
#       将宿主机 RDMA 网卡(InfiniBand/RoCE)的字符设备以 K8s 扩展资源暴露给 Pod, 支持多 Pod 共享同一物理 HCA。
#       步骤: 校验离线镜像 tar → 推送进集群内置 registry → 建 ConfigMap(资源池)+ DaemonSet(插件)
#       → 等待 DaemonSet Ready → 校验节点扩展资源注册。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: RDMA_ENABLED
# REQUIRES: k8s_deploy k8s_registry
# 说明:
#   · 断点续跑: REPEAT:0 → 安装成功写状态, 重跑跳过; --fresh 清状态后重装。
#   · RDMA 插件是纯 Device Plugin: 在 /var/lib/kubelet/device-plugins 注册扩展资源
#     (resourcePrefix/resourceName, 如 nvidia.com/mlx5_0), 让 Pod 经 resources.limits 申请;
#     rdmaHcaMax=每资源最大共享 Pod 数(如 100 表示允许 100 个 Pod 共享这块网卡)。
#   · 资源模式(RDMA_HCA_MODE): per-hca=每块 HCA 独立扩展资源(资源名=节点实际 RDMA 设备名, 如
#     nvidia.com/mlx5_0/1/2...), Pod 按资源名选择用哪块卡 —— cluster.conf.example 默认值(推荐);
#     pool=全部 HCA 聚合为单个资源(RDMA_RESOURCE_NAME, 兼容旧部署; 也是代码内建回退值);
#     链路类型自动识别(网卡 type 32=IB(ibsX) / 1=RoCE(ens*/manage0))。
#   · ACTIVE 过滤(RDMA_ACTIVE_ONLY, 默认 true): 自动检测时只收录链路状态 ACTIVE 的 HCA
#     (/sys/class/infiniband/<dev>/ports/*/state 含 ACTIVE), DOWN/DISABLED 卡不建资源不暴露;
#     =false 时全部暴露。仅作用于自动检测; 显式 RDMA_IF_NAMES 时尊重用户配置不过滤。
#   · 占位模式(RDMA_PLACEHOLDER_HCAS; cluster.conf.example 默认 mlx5_0,mlx5_1,mlx5_2):
#     **纯 VM 无 RDMA 卡时跑通部署流水线用**。自动检测到 0 块 HCA 时, 用这些占位设备名生成
#     config.json —— 插件 DaemonSet 正常起来, 但占位名不可能是节点真实 netdev 名 → selectors
#     永不匹配 → **不注册任何扩展资源**。仅作用自动检测; 检测到真实 HCA 时本项被忽略(物理机零影响)。
#     ConfigMap 会带标注 cubestack.io/rdma-placeholder=true, verify 模块据此放行并明确标注"未验收真实 RDMA"。
#     ⚠ 本行代码回退为空 = 严格模式(per-hca 检测不到 HCA 即报错退出, 防静默掩盖真实故障);
#     走严格模式: 把 cluster.conf 该行改成 RDMA_PLACEHOLDER_HCAS=""(去掉 :- 默认值; 只 export 空环境
#     变量无效 —— cluster.conf 的赋值优先于环境变量); 配置里完全没写该键时也走严格模式。
#   · 前置条件: 节点已装 Mellanox RDMA 网卡(ConnectX)+ MLNX_OFED/ib_core 驱动, ibstat/rdma link show
#     可见 HCA; K8s kubelet Device Plugin 特性默认开启。插件 DaemonSet 全节点跑, 无 HCA 节点空转不报错(自探测)。
#   · 数据面隔离(可选): 与 Multus CNI(模块 09_multus)配合, 基于 RDMA 网卡(master)再建 macvlan NAD 给 Pod 独立业务 IP。
#   · 离线镜像: deployments/offline-files/rdma/(联网机 tools/images/rdma-save-images.sh 生成 tar)→ 推送到
#     集群内置 registry(目标 mellanox/k8s-rdma-shared-dev-plugin, 保 repo 路径去注册域)。
#   · manifest: ConfigMap + DaemonSet 由模块 heredoc 生成(镜像行重写为镜像副本 ref; 源不落盘)。
#   · 区别于 SR-IOV: 本插件用于 PF(Physical Function)共享; 若开 SR-IOV(VF)应改用 k8s-sriov-network-device-plugin。
# 数据源: cluster.conf (RDMA_ENABLED / RDMA_SAVE_DIR / RDMA_IMAGE_TAG / RDMA_RESOURCE_PREFIX /
#         RDMA_RESOURCE_NAME / RDMA_HCA_MODE / RDMA_HCA_MAX / RDMA_IF_NAMES / RDMA_ACTIVE_ONLY /
#         RDMA_PLACEHOLDER_HCAS / RDMA_VENDORS / RDMA_UPDATE_INTERVAL / RDMA_NAMESPACE /
#         REGISTRY_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps rdma_shared_dev_plugin  或  RDMA_ENABLED=true
# 验证:   sudo ./deploy-cluster.sh --steps verify_rdma_shared_dev_plugin
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关 ----
[ "${RDMA_ENABLED:-false}" = "true" ] || { say "RDMA_ENABLED=false, 跳过 RDMA 共享设备插件"; exit 0; }

init_remote_kubectl || exit 1

# ---------------- 派生变量(全部来自 cluster.conf / load_config, 无硬编码) ----------------
SAVE_DIR="${RDMA_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/rdma}"
IMG_TAG="${RDMA_IMAGE_TAG:-v1.5.4}"            # ⚠ 官方源已迁 ghcr.io/mellanox(非 Docker Hub); 1.4.0 无 v 前缀, v1.5.1+ 带 v(默认 v1.5.4 最新: 修复 RoCE 口 issm 硬检查, 5 块 HCA 全暴露)
NS="${RDMA_NAMESPACE:-kube-system}"
# 自动检测执行所需: 全节点 SSH 身份(复用 init_remote_kubectl 的单 master 通道思路, 这里遍历每个节点)
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH_USER_D="${SSH_USER:-ubuntu}"
# skopeo push 直连端点(nodeport → master:REGISTRY_NODEPORT; metallb → VIP:5000; 见 lib-common)
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-5000}}"
# 节点可解析 registry 域名(:5000, 节点 containerd hosts.toml 已改写)
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
PUSH_REPO="${REG_DIRECT}/mellanox"
# manifest 镜像重写目标(kubectl apply 后节点按此 ref 拉取)
IMG_REF="${REG_BASE}/mellanox/k8s-rdma-shared-dev-plugin:${IMG_TAG}"

# 资源配置(全局单一 ConfigMap, 多节点同一套)
RES_PREFIX="${RDMA_RESOURCE_PREFIX:-nvidia.com}"
RES_NAME="${RDMA_RESOURCE_NAME:-mlx5_0}"
RES_FULL="${RES_PREFIX}/${RES_NAME}"
HCA_MAX="${RDMA_HCA_MAX:-100}"
# 资源模式: per-hca=每块 HCA 独立扩展资源, 资源名=实际设备名(cluster.conf.example 默认, 推荐: pod 可
#           按资源名选卡); pool=全部 HCA 聚合为单个扩展资源(兼容旧部署; 本行是**代码内建回退值**,
#           配置里没写 RDMA_HCA_MODE 键时才生效)
HCA_MODE="${RDMA_HCA_MODE:-pool}"
# ⚠ 自动检测: 默认不写死网卡名 —— 各节点 RDMA 网卡名可能不同(IB=ibsX / RoCE=ens*/manage0),
#   手写 RDMA_IF_NAMES 只适配单形态。**留空 = 模块自动扫描所有节点 /sys/class/infiniband/*
#   /device/net/ 取真实网卡名并集**, 兼容 IB + RoCE 混合集群。显式设置则尊重用户配置。
IF_NAMES="${RDMA_IF_NAMES:-}"      # 逗号分隔; 空 = 自动检测(见下方 [1/4] 检测段)
# ⚠ ACTIVE 过滤: 仅自动检测时生效, 显式 RDMA_IF_NAMES 时忽略(尊重用户配置)
ACTIVE_ONLY="${RDMA_ACTIVE_ONLY:-true}"      # true=只收录链路状态 ACTIVE 的 HCA; false=全部
# ⚠ 占位模式(纯 VM 无 RDMA 卡): 自动检测到 0 块 HCA 时, 若本项非空则以这些**占位设备名**生成
#   config.json(如 per-hca → nvidia.com/mlx5_0/1/2), 插件正常起来但**不注册任何扩展资源**。
#   cluster.conf.example 默认带 mlx5_0,mlx5_1,mlx5_2 → 无卡 VM 直接可跑通; 本行代码回退为空
#   = 严格模式(per-hca 检测不到 HCA 即报错退出, 不静默掩盖真实故障); 走严格模式要把 cluster.conf
#   该行改成 RDMA_PLACEHOLDER_HCAS=""(只 export 一个空环境变量无效, cluster.conf 赋值优先)。
#   仅作用自动检测(RDMA_IF_NAMES 为空); 检测到真实 HCA 时本项被忽略 → 物理机零影响。
PLACEHOLDER_HCAS="${RDMA_PLACEHOLDER_HCAS:-}"    # 逗号分隔; 空 = 严格模式(不启用占位)
PLACEHOLDER_MODE=0                               # 1 = 本次走了占位(由下方检测分支置位)
VENDORS="${RDMA_VENDORS:-15b3}"          # 逗号分隔; Mellanox/NVIDIA PCI Vendor ID
UPDATE_INTERVAL="${RDMA_UPDATE_INTERVAL:-300}"
CM_NAME="rdma-devices"
DS_NAME="rdma-shared-dp-ds"

# ---------------- 转 JSON 列表(逗号分隔 → ["a","b"]) ----------------
_to_json_list() {
    local IFS=',' val="$1" out="" item
    for item in ${val}; do
        item="${item// /}"
        [ -z "${item}" ] && continue
        out="${out}${out:+,}\"${item}\""
    done
    printf '[%s]' "${out}"
}
# IF_LIST / VENDOR_LIST 在 [1/4] 自动检测完成后才最终确定(IF_NAMES 可能被检测值覆盖)

# ---- [1/4] 校验离线镜像 tar ----
say "[1/4] 校验 RDMA 插件离线镜像 tar..."
[ -d "${SAVE_DIR}" ] || { err "离线镜像目录缺失: ${SAVE_DIR}(联网机: sudo bash deployments/scripts/tools/images/rdma-save-images.sh)"; exit 1; }
TAR_FILE="$(find_offline_tar "k8s-rdma-shared-dev-plugin:${IMG_TAG}" "*.tar" "${SAVE_DIR}")" || TAR_FILE=""
if [ -z "${TAR_FILE}" ]; then
    # 兜底: 按内容匹配(兼容改名/版本风格差异, 如 tar 内 tag 无 v 前缀)
    for _t in "${SAVE_DIR}"/*.tar; do
        [ -f "${_t}" ] || continue
        case "$(tar_first_image_tag "${_t}")" in
            *k8s-rdma-shared-dev-plugin*) TAR_FILE="${_t}"; break ;;
        esac
    done
fi
[ -n "${TAR_FILE}" ] || { err "未找到 k8s-rdma-shared-dev-plugin 离线 tar(应含 ghcr.io/mellanox/k8s-rdma-shared-dev-plugin:${IMG_TAG}); 请先在联网机跑 rdma-save-images.sh 生成并放入 ${SAVE_DIR}"; exit 1; }
# ★ 以 tar 内实际 tag 为准(兼容 1.4.0 / v1.4.0 风格差异): 从 tar 内容解析真实镜像 ref, 派生 IMG_TAG
_TAR_SRC="$(tar_first_image_tag "${TAR_FILE}")"
[ -n "${_TAR_SRC}" ] || { err "无法从 tar 解析镜像 ref(内容损坏?): ${TAR_FILE}"; exit 1; }
_TAR_TAG="${_TAR_SRC##*:}"
[ -n "${_TAR_TAG}" ] && IMG_TAG="${_TAR_TAG}"
IMG_REF="${REG_BASE}/mellanox/k8s-rdma-shared-dev-plugin:${IMG_TAG}"
ok "离线镜像 tar 就绪: ${TAR_FILE}(实际 tag=${IMG_TAG})"

# ═══════════ 自动检测节点 RDMA 设备(IF_NAMES 留空时; 每 HCA 一行: 设备名:网卡名:链路类型) ═══════════
# ⚠ 各节点 RDMA 网卡名可能不同(IB=ibsX / RoCE=ens*/manage0); 手写 RDMA_IF_NAMES 只适配单形态。
#   留空 = 扫描所有节点 /sys/class/infiniband/*/device/net/ 收集真实设备名+网卡名+链路类型并集(兼容 IB+RoCE 混合)。
#   全集群无 RDMA 设备时给出告警并继续(插件 DaemonSet 空转, 扩展资源不注册)。
#   链路类型: /sys/class/net/<if>/type, 32=InfiniBand(IPoIB), 1=Ethernet(RoCE)
#   ACTIVE 过滤(RDMA_ACTIVE_ONLY=true, 默认): 仅收录链路状态 ACTIVE 的 HCA。链路状态判定
#   优先 /sys/class/infiniband/<dev>/ports/*/state(内容为 1:ACTIVE / 4:DOWN 等数字), 无端口
#   时退回 /sys/class/net/operstate(up/down, 只对 RoCE/Ethernet 有效)。DISABLED/DOWN 的卡
#   (如 ConnectX-4 Lx 被禁用)会被跳过, 不生成扩展资源 —— 这样 Pod 只看到可用卡。
if [ -z "${IF_NAMES}" ]; then
    say "  RDMA_IF_NAMES 留空, 自动检测节点 RDMA 设备${ACTIVE_ONLY:+ (RDMA_ACTIVE_ONLY=${ACTIVE_ONLY})}..."
    DETECTED_HCAS=""
    # 远端检测逻辑写入临时脚本(heredoc 单独成文件, 避免 $( ) 内嵌 heredoc 的 bash 解析问题)
    _DET_TMP="$(mktemp)"
    cat > "${_DET_TMP}" <<'REMOTE_DETECT'
for d in /sys/class/infiniband/*; do
    [ -e "$d" ] || continue
    dev="$(basename "$d")"
    # 端口链路状态(内容为 "4: ACTIVE" / "1: DOWN" 等, 冒号后有空格, 末尾带换行):
    # 任一端口 ACTIVE 即视为可用。先剥离数字前缀/冒号/空格/换行, 只留状态词。
    state=""
    for p in "$d"/ports/*/state; do
        [ -e "$p" ] || continue
        v="$(tr -d '[:space:]' < "$p" 2>/dev/null)"
        v="${v##*:}"                 # "4:ACTIVE" → "ACTIVE"
        [ "$v" = "ACTIVE" ] && state=ACTIVE
        [ -z "$state" ] && [ -n "$v" ] && state="$v"
    done
    if [ "$ACTIVE_ONLY" = "true" ]; then
        [ "$state" = "ACTIVE" ] || continue
    fi
    for n in "$d"/device/net/*; do
        [ -e "$n" ] || continue
        t="$(cat /sys/class/net/"$(basename "$n")"/type 2>/dev/null || echo 0)"
        printf "%s:%s:%s:%s\n" "$dev" "$(basename "$n")" "$t" "$state"
    done
done
REMOTE_DETECT
    for _line in "${NODES[@]:-}"; do
        [ -z "${_line}" ] && continue
        node_parse "${_line}"   # → NODE_IP / NODE_ROLE ...
        [ -n "${NODE_IP:-}" ] || continue
        _ifc="$(ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
                "${SSH_USER:-ubuntu}@${NODE_IP}" "ACTIVE_ONLY=${ACTIVE_ONLY} bash -s" < "${_DET_TMP}" 2>/dev/null || true)"
        if [ -n "${_ifc}" ]; then
            # 按节点汇总到 DETECTED_HCAS(去重, 逗号分隔)
            while IFS= read -r _h; do
                [ -z "${_h}" ] && continue
                case ",${DETECTED_HCAS}," in *",${_h},"*) : ;; *) DETECTED_HCAS="${DETECTED_HCAS}${DETECTED_HCAS:+,}${_h}" ;; esac
            done <<< "${_ifc}"
            say "    ${NODE_IP}: 检测到 RDMA 设备 → $(echo "${_ifc}" | tr '\n' ' ')"
        fi
    done
    rm -f "${_DET_TMP}"
    if [ -n "${DETECTED_HCAS}" ]; then
        say "  自动检测结果: ${DETECTED_HCAS}"
        # pool 兼容模式: IF_NAMES = 去重网卡名并集
        IF_NAMES="$(echo "${DETECTED_HCAS}" | tr '\n' ',')"
        IF_NAMES="$(echo "${IF_NAMES}" | cut -d: -f2 | tr ',' '\n' | sort -u | tr '\n' ',')"
        IF_NAMES="${IF_NAMES%,}"
        say "  pool 模式 ifNames: ${IF_NAMES}"
    elif [ -n "${PLACEHOLDER_HCAS}" ]; then
        # ── 占位模式(纯 VM 无 RDMA 卡)──
        # 技巧: 只把占位名塞进 IF_NAMES —— 下游 :IF_LIST 生成 与 :DETECTED_HCAS 推导(把"网卡名"
        # 展开成 设备名:网卡名:类型 三元组)会原样处理, per-hca / pool 两种模式**均无需额外分支**。
        # 占位名(mlx5_0 等)是**设备名**不是 netdev 名, 节点上永远不存在同名网卡 → 插件 selectors
        # 永不匹配 → 空资源池, 节点 allocatable 不会出现 RDMA 扩展资源(= 需求"不真正注册")。
        PLACEHOLDER_MODE=1
        IF_NAMES="${PLACEHOLDER_HCAS}"
        warn "  全集群未检测到 RDMA 网卡, 但已配置 RDMA_PLACEHOLDER_HCAS → 走【占位模式】"
        warn "  ⚠ 占位模式不含真实 RDMA 硬件: ConfigMap 按占位名生成(${PLACEHOLDER_HCAS}), 插件空转, **不会注册任何扩展资源**"
        warn "  ⚠ 若本机本应有 RDMA 卡: 先查驱动(ibstat / rdma link show)与 RDMA_ACTIVE_ONLY(DOWN/DISABLED 会被过滤);"
        warn "    驱动修好后本项自动失效(检测到真卡即走真实配置), 再用 --steps rdma_shared_dev_plugin --fresh 重跑本模块重建 ConfigMap"
    else
        warn "  全集群未检测到 RDMA 网卡(无 /sys/class/infiniband/* 设备节点或全部链路 DOWN/DISABLED)"
        # ⚠ 提示必须与随后的**实际结果**一致: per-hca 在下方 :DETECTED_HCAS 为空处硬失败, 只有 pool 才空转。
        #   (曾统一打印"插件 DaemonSet 将空转", 与 per-hca 随后报错退出自相矛盾, 易被误判为程序 bug。)
        if [ "${HCA_MODE}" = "per-hca" ]; then
            warn "  ⚠ HCA_MODE=per-hca 且无任何 HCA → 本模块随后将报错退出:"
            warn "    纯 VM 无卡集群: 在 cluster.conf 设 RDMA_PLACEHOLDER_HCAS=\"mlx5_0,mlx5_1,mlx5_2\" 走占位模式(跑通但不注册资源)"
            warn "    或改 RDMA_HCA_MODE=pool(空转不报错); 详见 deployments/cubestack-addon/rdma/CUBESTACK.md"
        else
            warn "  HCA_MODE=pool: 插件 DaemonSet 将空转, 无扩展资源(ifNames 为空, 不报错)"
        fi
        IF_NAMES=""
    fi
fi
[ -n "${IF_NAMES}" ] && IF_LIST="$(_to_json_list "${IF_NAMES}")" || IF_LIST="[]"

# 手动指定 IF_NAMES 时的 DETECTED_HCAS 派生: per-hca 需要 设备名:网卡名:链路类型 三元组。
# 显式只给网卡名时, 回退为 网卡名:网卡名:0(链路类型未知, 插件只按网卡名匹配, 不影响资源名)。
if [ -z "${DETECTED_HCAS:-}" ]; then
    declare -a _hca_list=()
    for _i in ${IF_NAMES//,/ }; do
        [ -z "${_i}" ] && continue
        case "${_i}" in *:*) _hca_list+=("${_i}") ;; *) _hca_list+=("${_i}:${_i}:0") ;; esac
    done
    DETECTED_HCAS="$(IFS=,; echo "${_hca_list[*]}")"
fi
VENDOR_LIST="$(_to_json_list "${VENDORS}")"
# 说明: 插件过滤时缺失的 selector 会被忽略(README: missing selectors ignored), 故 ifNames 为空
#   (全集群无设备)也能启动, 只是匹配不到设备 → 空资源池, 插件正常空转。

# ── 按 HCA_MODE 生成 config.json 内容(CM_JSON) ──
# pool:    单条目, 全部 HCA 聚合到 RES_NAME 一个资源(Pod 申请 nvidia.com/mlx5_0, 旧默认)
# per-hca: 每块 HCA 独立条目 → 每块网卡独立扩展资源(如 mlx5_0 / mlx5_1 / ibs2 ...),
#          configList 条目 data 形如:
#          { "resourcePrefix":"nvidia.com", "resourceName":"mlx5_0",
#            "rdmaHcaMax":100,
#            "selectors": { "vendors":["15b3"], "ifNames":["ens5f0np0"] } }
#          同款 HCA 在全集群同名(Y 认设备名 sysfs 全局唯一), 资源名 = 设备名(如 mlx5_0)。
# 注意: configList 内资源名不得重复(同一名字的多个条目会被插件合并/报错)。
CM_JSON=""
if [ "${HCA_MODE}" = "per-hca" ]; then
    [ -n "${DETECTED_HCAS}" ] || { err "RDMA_HCA_MODE=per-hca 但未检测到任何 HCA(检查驱动 / RDMA_IF_NAMES)"; \
        err "  纯 VM 无 RDMA 卡: 在 cluster.conf 设 RDMA_PLACEHOLDER_HCAS=\"mlx5_0,mlx5_1,mlx5_2\" 走占位模式, 或改 RDMA_HCA_MODE=pool"; exit 1; }
    # 按设备名分组: 同名设备(同款 HCA)可能出现在多节点/多网卡, 合并 ifNames 并集, 只生成一个资源
    declare -A _dev_nets _dev_types
    for _h in ${DETECTED_HCAS//,/ }; do
        [ -z "${_h}" ] && continue
        _dev="${_h%%:*}"
        _rest="${_h#*:}"
        _net="${_rest%%:*}"
        _type="${_rest##*:}"
        [ -n "${_dev}" ] || continue
        case ",${_dev_nets[${_dev}]:-}," in *",${_net},"*) : ;; *) _dev_nets["${_dev}"]="${_dev_nets[${_dev}]:-}${_dev_nets[${_dev}]:+,}${_net}" ;; esac
        # 链路类型取第一个已知值(32=IB / 1=RoCE; 手动指定 IF_NAMES 时为 0=未知)
        [ -n "${_dev_types[${_dev}]:-}" ] && continue
        case "${_type}" in 32|1) _dev_types["${_dev}"]="${_type}" ;; esac
    done
    CM_JSON=""   # 资源条目(逗号分隔拼接)
    _ENTRIES=0
    for _dev in $(printf '%s\n' "${!_dev_nets[@]}" | sort); do
        _nets_json="$(_to_json_list "${_dev_nets[${_dev}]}")"
        _hint="?"
        [ "${_dev_types[${_dev}]:-}" = "32" ] && _hint="IB"
        [ "${_dev_types[${_dev}]:-}" = "1" ] && _hint="RoCE"
        # 占位模式: 设备名非真实 HCA、无对应网卡, 标注清楚避免被误读成已部署真实资源
        _from=" ← 网卡 ${_dev_nets[${_dev}]}"
        [ "${PLACEHOLDER_MODE}" = "1" ] && { _hint="占位"; _from=" ← 无真实设备(占位名匹配不到任何网卡)"; }
        CM_JSON="${CM_JSON}${CM_JSON:+,}
        {
            \"resourcePrefix\": \"${RES_PREFIX}\",
            \"resourceName\": \"${_dev}\",
            \"rdmaHcaMax\": ${HCA_MAX},
            \"selectors\": {
                \"vendors\": ${VENDOR_LIST},
                \"ifNames\": ${_nets_json}
            }
        }"
        say "    per-hca 资源: ${RES_PREFIX}/${_dev}(${_hint})${_from}"
        _ENTRIES=$((_ENTRIES + 1))
    done
    CM_JSON="$(printf '{\n    "periodicUpdateInterval": %s,\n    "configList": [\n%s\n    ]\n}\n' "${UPDATE_INTERVAL}" "${CM_JSON}")"
    say "  per-hca 模式: 生成 ${_ENTRIES} 个独立扩展资源"
else
    CM_JSON="$(printf '{\n    "periodicUpdateInterval": %s,\n    "configList": [\n        {\n            "resourcePrefix": "%s",\n            "resourceName": "%s",\n            "rdmaHcaMax": %s,\n            "selectors": {\n                "vendors": %s,\n                "ifNames": %s\n            }\n        }\n    ]\n}\n' "${UPDATE_INTERVAL}" "${RES_PREFIX}" "${RES_NAME}" "${HCA_MAX}" "${VENDOR_LIST}" "${IF_LIST}")"
    if [ "${PLACEHOLDER_MODE}" = "1" ]; then
        say "  pool 模式(占位): ${RES_FULL}(rdmaHcaMax=${HCA_MAX}, ifNames=${IF_NAMES}[占位名, 匹配不到任何网卡], vendors=${VENDORS})"
    else
        say "  pool 模式: 全部网卡聚合为 ${RES_FULL}(rdmaHcaMax=${HCA_MAX}, ifNames=${IF_NAMES}, vendors=${VENDORS})"
    fi
fi

# ---- [2/4] registry 预检 + push ----
say "[2/4] 推送镜像到集群内置 registry(${PUSH_REPO})..."
skopeo_require rdma
if ! wait_registry_ready "http://${REG_DIRECT}/v2/" 30; then
    err "集群内置 registry ${REG_DIRECT}/v2/ 30s 内不可达(检查 SERVICE_EXPOSE_MODE / registry pod / REGISTRY_DIRECT)"; exit 1
fi
if reg_has_tag "${REG_DIRECT}/mellanox" "k8s-rdma-shared-dev-plugin" "${IMG_TAG}"; then
    say "  registry 已有 mellanox/k8s-rdma-shared-dev-plugin:${IMG_TAG}, 跳过推送"
else
    push_image_skopeo "docker-archive:${TAR_FILE}" "docker://${PUSH_REPO}/k8s-rdma-shared-dev-plugin:${IMG_TAG}" \
        && ok "  镜像已推送: ${PUSH_REPO}/k8s-rdma-shared-dev-plugin:${IMG_TAG}" \
        || { err "RDMA 插件镜像推送失败(重试 3 次后); 检查宿主机能否达 ${REG_DIRECT}"; exit 1; }
fi

# ---- [3/4] ConfigMap + DaemonSet apply ----
say "[3/4] 下发 RDMA 插件 ConfigMap + DaemonSet(镜像重写为 ${IMG_REF})..."
sync_kubeconfig || { err "宿主机无法访问集群(admin.conf 同步失败)"; exit 1; }

# 3a. ConfigMap(config.json 内容由上方按 HCA_MODE 生成于 CM_JSON; 全局单份, 所有节点同一套资源)
# ⚠ YAML 块标量(config.json: |)的内容行必须比键多缩进(≥4 空格), 故用 sed 对每行加 4 空格;
#   顶格 JSON 会让 kubectl 解析失败("mapping values are not allowed in this context")。
# ⚠ 占位标注(cubestack.io/rdma-placeholder): 恒写 true/false, 让 verify 模块能**从集群实际状态**
#   判断本次是否占位(而不是读本地 cluster.conf —— 防"配置文件换了、集群没换"的错配)。
#   值必须带引号: 裸 true 会被 YAML 当布尔, kubectl 拒绝非字符串的 annotation 值。
_PH_ANNO="false"; [ "${PLACEHOLDER_MODE}" = "1" ] && _PH_ANNO="true"
_CM_TMP="$(mktemp)"
{
    echo "apiVersion: v1"
    echo "kind: ConfigMap"
    echo "metadata:"
    echo "  name: ${CM_NAME}"
    echo "  namespace: ${NS}"
    echo "  annotations:"
    echo "    cubestack.io/rdma-placeholder: \"${_PH_ANNO}\""
    echo "data:"
    echo "  config.json: |"
    sed 's/^/    /' <<< "${CM_JSON}"
} > "${_CM_TMP}"
SSH "${K} -n ${NS} apply -f -" < "${_CM_TMP}" || { err "ConfigMap apply 失败"; rm -f "${_CM_TMP}"; exit 1; }
rm -f "${_CM_TMP}"
[ "${PLACEHOLDER_MODE}" = "1" ] \
    && ok "  ConfigMap 已创建(全局单份, 多节点共用: ${NS}/${CM_NAME}; ⚠ 占位模式 rdma-placeholder=true)" \
    || ok "  ConfigMap 已创建(全局单份, 多节点共用: ${NS}/${CM_NAME})"

# 3b. DaemonSet(镜像行重写为 img ref; 与 ConfigMap 分开 apply)
_DS_TMP="$(mktemp)"
cat > "${_DS_TMP}" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${DS_NAME}
  namespace: ${NS}
  labels:
    name: rdma-shared-dp
spec:
  selector:
    matchLabels:
      name: rdma-shared-dp
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: rdma-shared-dp
    spec:
      hostNetwork: true
      tolerations:
        - operator: Exists
          effect: NoSchedule
        - operator: Exists
          effect: NoExecute
      containers:
        - name: rdma-dp
          image: @@IMG_REF@@
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
            - name: devinfiniband
              mountPath: /dev/infiniband
            - name: sysclass
              mountPath: /sys/class
              readOnly: true
            - name: config
              mountPath: /k8s-rdma-shared-dev-plugin
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
        - name: devinfiniband
          hostPath:
            path: /dev/infiniband
        # ⚠ 挂 /sys/class 而非 /sys/class/infiniband: 无 RDMA 设备节点上该子目录
        #   不存在(sysfs 按检测到的 HCA 动态生成), 直接挂载它会让 containerd 尝试
        #   mkdir → sysfs 禁止创建目录 → "operation not permitted", 容器起不来。
        #   挂父目录 /sys/class(恒存在)则无设备节点挂载成功、插件自探测 0 设备空转。
        - name: sysclass
          hostPath:
            path: /sys/class
        - name: config
          configMap:
            name: ${CM_NAME}
            items:
              - key: config.json
                path: config.json
EOF
sed -i "s#@@IMG_REF@@#${IMG_REF}#g" "${_DS_TMP}"
SSH "${K} apply -f -" < "${_DS_TMP}" || { err "DaemonSet apply 失败"; rm -f "${_DS_TMP}"; exit 1; }
rm -f "${_DS_TMP}"

# ---- [4/4] 等待 DaemonSet Ready ----
say "[4/4] 等待 ${DS_NAME} DaemonSet Ready..."
DS_READY=0
for _i in $(seq 1 45); do
    _ds="$(SSH "${K} -n ${NS} rollout status ds/${DS_NAME} --timeout=5s 2>/dev/null" || true)"
    if echo "${_ds}" | grep -qi "successfully rolled out\|available"; then
        DS_READY=1; break
    fi
    sleep 10
done
if [ "${DS_READY}" = "1" ]; then
    ok "  ${DS_NAME} DaemonSet 已全节点 Ready"
else
    warn "  ${DS_NAME} 45s 内未 Ready(用 kubectl -n ${NS} get ds/${DS_NAME} 复查; 可能节点镜像拉取慢)"
fi
unset _ds _i

echo "---------------------------------------------"
[ "${PLACEHOLDER_MODE}" = "1" ] \
    && ok "RDMA 共享设备插件部署完成(${DS_NAME} DaemonSet; ⚠ 占位模式)" \
    || ok "RDMA 共享设备插件部署完成(${DS_NAME} DaemonSet)"
echo "  镜像:   ${IMG_REF}"
if [ "${PLACEHOLDER_MODE}" = "1" ]; then
    warn "⚠ 占位模式(RDMA_PLACEHOLDER_HCAS=${PLACEHOLDER_HCAS}): 本机无真实 RDMA 硬件, ConfigMap 只按占位名生成,"
    warn "  DaemonSet 空转且【不会注册任何 RDMA 扩展资源】—— kubectl describe node 看不到 ${RES_PREFIX}/mlx5_* 属预期。"
    warn "  如需真实 RDMA: 装卡/加载驱动后**本项自动失效**(检测到真卡即走真实配置), 但已下发的 ConfigMap 仍是占位版,"
    warn "  需用 --steps rdma_shared_dev_plugin --fresh 重跑本模块重建 ConfigMap(REPEAT:0, 否则会被断点续跑跳过);"
    warn "  (--steps 只跑该组件, 不会连带 k8s_deploy; --fresh 仅清断点状态)"
fi
if [ "${HCA_MODE}" = "per-hca" ]; then
    echo "  资源:   每块 HCA 独立扩展资源(rdmaHcaMax=${HCA_MAX} 各; 全局 ConfigMap ${NS}/${CM_NAME})"
    echo "  可用资源列表(以节点实际设备名为准, 见上面日志):"
    for _dev in $(printf '%s\n' "${!_dev_nets[@]}" | sort); do
        if [ "${PLACEHOLDER_MODE}" = "1" ]; then
            echo "    ${RES_PREFIX}/${_dev}   (占位, 无真实设备 → 不会注册)"
        else
            echo "    ${RES_PREFIX}/${_dev} ← 网卡 ${_dev_nets[${_dev}]}"
        fi
    done
    echo "  验证:   --steps verify_rdma_shared_dev_plugin(逐个检查各资源在各节点 allocatable)"
    echo "  使用(给 Pod 申请指定 HCA 的 RDMA 设备):"
    echo "    resources:"
    echo "      limits:"
    echo "        ${RES_PREFIX}/<设备名>: 1    # 例如 ${RES_PREFIX}/mlx5_0: 1 选第一块卡"
else
    echo "  资源:   ${RES_FULL}(rdmaHcaMax=${HCA_MAX}; 全局 ConfigMap ${NS}/${CM_NAME})"
    echo "  验证:   --steps verify_rdma_shared_dev_plugin(检查各节点 allocatable 含 ${RES_FULL})"
    echo "  使用(给 Pod 申请 RDMA 设备):"
    echo "    resources:"
    echo "      limits:"
    echo "        ${RES_FULL}: 1"
fi
echo "  配合 Multus(数据面隔离): pod 注解 k8s.v1.cni.cncf.io/networks: <macvlan-NAD> 再挂数据网络"
echo "  清理:   kubectl -n ${NS} delete ds ${DS_NAME}; kubectl -n ${NS} delete cm ${CM_NAME}"
