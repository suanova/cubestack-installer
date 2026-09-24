#!/bin/bash
# ============================================================
# MODULE: ceph
# DESC: 部署 Rook-Ceph 存储集群(CephCluster; 自动检测裸盘 + node label 选节点 + 离线镜像/包 + 安全确认)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: CEPH_ENABLED CEPH_CSI_ENABLED
# REQUIRES: k8s_deploy k8s_passwordless k8s_workerbm k8s_ntp
# 说明:
#   · 断点续跑: REPEAT:0 → 安装成功写入状态; --fresh 清状态重装。
#   · 方式: Rook Operator(离线 manifest, deployments/cubestack-addon/rook, 需先联网跑
#     tools/k8s/rook-fetch-manifests.sh)+ CephCluster CR(本模块按"检测到的节点+裸盘"生成)+
#     CephBlockPool/StorageClass 在模块 ceph_csi(08)创建。
#   · 存储节点选择(需求 3): CEPH_NODES(cluster.conf, hostname 逗号分隔; 非空则优先),
#     否则按 CEPH_NODE_ROLE 从 NODES 里选(**默认 master** — 默认只装在 master 节点)。
#     ⚠ 唯一实现是 lib-common.sh 的 ceph_storage_hosts(); 不要在这里另写一份判断。
#     模块给这些节点打 node label(CEPH_NODE_LABEL, 默认 ceph-storage=rook-ceph),
#     CephCluster 的 placement/storage.nodes 只包含这些节点。
#   · master 可调度(默认): kubespray 默认给 master 打 control-plane NoSchedule taint, Rook
#     mon/osd 调度到 master 会被卡住(3 台 mon 至少需 3 台可调度节点)。本模块在部署前默认去掉
#     master 的 control-plane taint(CEPH_ENABLE_MASTER_SCHEDULE=true, 幂等), 并给 CephCluster
#     placement 加 control-plane tolerations 双保险; 恢复 taint: kubectl taint nodes <master> node-role.kubernetes.io/control-plane=:NoSchedule。
#   · 裸盘自动检测(需求 1): tools/k8s/ceph-detect-disks.sh **分类**逐节点磁盘 →
#     free(未使用裸盘)∪ ceph(上次 Ceph 占用的 OSD 盘, 按强证据判定: bluestore 签名 /
#     ceph 分区 GUID 或分区名 / ceph-* LVM 卷)生成 CephCluster CR 的 per-node devices ——
#     精确盘名而非正则, 避免误选; inuse(挂载/非 ceph 文件系统/非 ceph LVM/系统盘)与
#     mixed(同盘既有 ceph 又有别的数据)一律不进 CR、不清理。
#     VM 集群请确保 VM 附加数据盘(默认 3×200GB, VM_DATA_DISKS)。
#   · 安全确认(需求 2): 应用 CR 前红底醒目列出"将使用的节点 + 各节点磁盘按类分组
#     (空闲 / 上次 Ceph 占用 / 在用 / 混合)+ 判定证据", **sleep CEPH_CONFIRM_SLEEP(默认 60)s**
#     供人工 double-check; 核对无误自动继续。CI 可 CEPH_CONFIRM_SLEEP=0 跳过。
#   · 节点准备: 每台存储节点加载并持久化 rbd 内核模块; 确保 lvm2
#     (离线 .deb 由 tools/offline/fetch-lvm-packages.sh 放到 offline-files/kubespray/packages,
#     本模块部署前预检"离线包就绪 或 节点已在线装 lvm", 缺失硬失败; 部署时自动从该目录安装)。
#   · 离线镜像(需求 5): tools/images/ceph-save-images.sh(联网机下载到 offline-files/kubespray/images,
#     与 kubespray 镜像同目录) → k8s 阶段由 cluster.yml 内置预加载 play 统一同步到节点并 ctr import。
#   · registry 后端(需求 6): REGISTRY_STORAGE_CLASS=ceph-block(见 docs/ceph-rook.md)时,
#     registry 的 PVC 改走 ceph RBD(替代 local-path); 模块设计顺序在 registry 配置之前。
#   · 参考: docs/ceph-rook.md(Rook v1.20.2 / Ceph v20.2.2 生产设计: 3 副本 host 故障域 +
#     3 mon + 2 mgr; mon/osd/mgr/toolbox 全部按 label 钉在存储节点)
# 数据源: cluster.conf (CEPH_ENABLED / CEPH_NODES / CEPH_NODE_LABEL / CEPH_* / CEPH_IMAGE_DIR /
#                       CEPH_ROOK_MANIFEST_DIR / REGISTRY_STORAGE_CLASS / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --enable ceph  或  CEPH_ENABLED=true
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关 ----
# ★ TOGGLE = CEPH_ENABLED CEPH_CSI_ENABLED(任一 true 即调度本模块):
#   · internal(自建 CephCluster)→ CEPH_ENABLED=true;
#   · external(仅接入外部 Ceph)→ CEPH_ENABLED=false 但 CEPH_CSI_ENABLED=true 时仍调度本模块
#     (02 只需部署 operator/csi-operator 供 03 使用, 不创建 CephCluster)。
#   模块内部再按 CEPH_MODE 精确分流(下方开关检查)。
if [ "${CEPH_MODE:-internal}" = "external" ]; then
    [ "${CEPH_CSI_ENABLED:-false}" = "true" ] || { say "CEPH_CSI_ENABLED=false, 跳过 Ceph(external 模式需要 CSI 才运行)"; exit 0; }
else
    [ "${CEPH_ENABLED:-false}" = "true" ] || { say "CEPH_ENABLED=false, 跳过 Ceph"; exit 0; }
fi

init_remote_kubectl || exit 1

# ★ 逐节点 SSH 公共函数(替代历史 4 处重复 NSSH() 定义): node_ssh <ip> <user> <cmd...>
#   user 传 NODE_USER 或 ${SSH_USER:-ubuntu} 均可; 不依赖任何外层函数定义。
node_ssh() {
    local _nip="$1" _nuser="$2"
    shift 2
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${_nuser}@${_nip}" "$@"
}

# ---------------- 派生变量(全部来自 cluster.conf) ----------------
CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
CEPH_VERSION="${CEPH_VERSION:-v20.2.2}"
CEPH_MON_COUNT="${CEPH_MON_COUNT:-3}"
# ★ 2026-09-24: mgr 默认 2(active + standby)。原来写死 1 —— 单 mgr 是**滚动单点**:
#   它所在节点一挂/被排空, 集群就进 "no active mgr"(dashboard/模块/PG autoscaler 全停摆,
#   且重新调度+选举期间 ceph -s 一直 HEALTH_WARN)。mgr 很轻(几十 MB~百 MB), 1→2 成本可忽略。
#   两个 mgr 都会被 placement.mgr 钉在存储节点上(见下方 CR 生成), 用 CEPH_MGR_COUNT 可覆盖。
CEPH_MGR_COUNT="${CEPH_MGR_COUNT:-2}"
CEPH_POOL_REPLICAS="${CEPH_POOL_REPLICAS:-3}"
CEPH_POOL_MIN_SIZE="${CEPH_POOL_MIN_SIZE:-2}"
CEPH_OSD_MEMORY_TARGET="${CEPH_OSD_MEMORY_TARGET:-12}"
CEPH_NODE_LABEL="${CEPH_NODE_LABEL:-ceph-storage=rook-ceph}"
LABEL_KEY="${CEPH_NODE_LABEL%%=*}"
CEPH_IMAGE_DIR="${CEPH_IMAGE_DIR:-${OFFLINE_FILES_DIR}/images}"
CEPH_ROOK_MANIFEST_DIR="${CEPH_ROOK_MANIFEST_DIR:-${REPO_ROOT}/deployments/cubestack-addon/rook}"
CEPH_CONFIRM_SLEEP="${CEPH_CONFIRM_SLEEP:-60}"
CEPH_PRE_CLEANUP_EXISTING="${CEPH_PRE_CLEANUP_EXISTING:-true}"   # 覆盖安装: 部署前完整清空上次 ceph 所用磁盘(OSD 盘数据销毁);
                                                                 #   false=保留旧盘数据(备份/恢复由独立模块 ceph_backup 处理, 见 15_ceph_backup.sh)
_CEPH_PRE_CLEANUP=0
[ "${CEPH_PRE_CLEANUP_EXISTING}" = "true" ] && _CEPH_PRE_CLEANUP=1
TOOLS_K8S="${SCRIPT_DIR}/tools/k8s"

# 1) 候选 ceph 节点(hostname 列表) —— 选择规则统一在 lib-common 的 ceph_storage_hosts():
#    CEPH_NODES 显式 > CEPH_NODE_ROLE(默认 master, 即默认只装在 master 节点)
CEPH_NODES="${CEPH_NODES:-}"
CEPH_NODE_HOSTS=()
while IFS= read -r _h; do
    [ -n "${_h}" ] && CEPH_NODE_HOSTS+=("${_h}")
done < <(ceph_storage_hosts)
unset _h
[ "${#CEPH_NODE_HOSTS[@]}" -ge 1 ] || { err "未找到候选存储节点(检查 NODES / CEPH_NODES / CEPH_NODE_ROLE)"; exit 1; }

# ★ 节点<3 不建集群内 CephCluster(mon 需 3 节点法定人数, allowMultiplePerNode=false):
#   置 _CEPH_SKIP_CLUSTER=1 → 跳过 CephCluster CR 创建/等待(下方 [6/8]/[7/8] 分支);
#   csi-operator 仍按需安装(可连外部 Ceph: cluster.conf 设 CEPH_EXTERNAL_MONITORS)。
CEPH_MIN_NODES="${CEPH_MIN_NODES:-3}"
_CEPH_SKIP_CLUSTER=0
# ★ CEPH_MODE=external(外部 Ceph 接入) → 不创建集群内 CephCluster, 仅部署 operator/csi-operator,
#   由 ceph_csi 模块经 CephConnection 连外部集群。兼容旧配置: 仅设 CEPH_EXTERNAL_MONITORS 时
#   load_config 已把 CEPH_MODE 归一化为 external。
if [ "${CEPH_MODE:-internal}" = "external" ]; then
    say "CEPH_MODE=external → 不创建集群内 CephCluster(由 ceph_csi 模块接入外部 Ceph: ${CEPH_MONITORS:-<未配置>})"
    _CEPH_SKIP_CLUSTER=1
    # ★ 2026-09-10: external-ceph.env 检测 + 倒计时警告(部署前提示, 目标"一次性部署成功")
    #   · CEPH_EXTERNAL_ENV_FILE 未显式设置时探测默认目录 deployments/config/external-ceph.env;
    #   · 文件缺失 → 红底倒计时(CEPH_ENV_CONFIRM_SLEEP, 默认 60s, CI 可设 0 跳过)——
    #     未检测到该文件, 部署可能失败(官方导入路径硬依赖; 手填路径不受影响但无健康上报/对象存储)。
    _EXT_ENV_FILE="${CEPH_EXTERNAL_ENV_FILE:-${REPO_ROOT}/deployments/config/external-ceph.env}"
    if [ -n "${CEPH_EXTERNAL_ENV_FILE:-}" ] || [ -f "${_EXT_ENV_FILE}" ]; then
        [ -f "${_EXT_ENV_FILE}" ] && say "  检测到 external-ceph.env: ${_EXT_ENV_FILE}(ceph_csi 将走官方导入路径)" \
            || warn "  CEPH_EXTERNAL_ENV_FILE=${CEPH_EXTERNAL_ENV_FILE} 不存在(ceph_csi 将回退手填路径)"
    else
        warn "  ⚠ 未检测到 external-ceph.env(默认路径: ${_EXT_ENV_FILE})"
        warn "    请先把提供方导出的 external-ceph.env 放到该路径(A 侧部署完自动导出; 或手工拷贝)"
        warn "    没有该文件, ceph_csi 外部接入可能部署失败(官方导入路径硬依赖; 手填 CEPH_MONITORS 等仍可用但无健康上报)"
        # ★ 2026-09-11: deploy-cluster.sh 部署开始前已倒计时确认过(CEPH_EXT_ENV_CONFIRMED=1)时
        #   不重复倒计时(仅保留告警), 避免整轮部署中 60s 等待出现两次; 单独 --steps ceph 仍会提示。
        if [ "${CEPH_EXT_ENV_CONFIRMED:-0}" != "1" ]; then
            _ENV_SLEEP="${CEPH_ENV_CONFIRM_SLEEP:-60}"
            if [ "${_ENV_SLEEP}" -gt 0 ] 2>/dev/null; then
                for _eci in $(seq "${_ENV_SLEEP}" -1 1); do
                    printf '\r\033[31m  %3ds 后继续(放入文件后按 Ctrl-C 重启, 或等待倒计时结束)...\033[0m' "${_eci}"
                    sleep 1
                done
                echo ""
            fi
            unset _eci
        fi
    fi
    unset _EXT_ENV_FILE _ENV_SLEEP
elif [ "${#CEPH_NODE_HOSTS[@]}" -lt "${CEPH_MIN_NODES}" ]; then
    warn "存储节点仅 ${#CEPH_NODE_HOSTS[@]} 台(<${CEPH_MIN_NODES}), 不创建集群内 CephCluster(mon 法定人数不足)"
    warn "  可选: ① 增加存储节点至 ≥${CEPH_MIN_NODES}; ② 或设 CEPH_MODE=external 连接外部 Ceph(见 docs/ceph-rook.md)"
    _CEPH_SKIP_CLUSTER=1
fi

# 前置: rook manifest 必须就绪(联网机已 fetch); 缺失给指引
[ -f "${CEPH_ROOK_MANIFEST_DIR}/operator.yaml" ] && [ -f "${CEPH_ROOK_MANIFEST_DIR}/csi-operator.yaml" ] || {
    err "Rook manifest 缺失: ${CEPH_ROOK_MANIFEST_DIR}(缺 operator.yaml/csi-operator.yaml)。请先联网执行 tools/k8s/rook-fetch-manifests.sh(默认 Rook ${ROOK_VERSION:-v1.20.2})后拷到部署机"
    exit 1
}

# 前置: lvm2 离线包就绪(需求: 先准备 lvm 离线包, 再在部署 ceph 前安装)。
#   离线包来源: offline-files/kubespray/packages(lvm2_*.deb + 依赖), 由联网机
#   tools/offline/fetch-lvm-packages.sh 生成。存储节点缺 lvm 且无离线包 → 硬失败,
#   避免"看起来部署成功、OSD 因无 lvm 无法激活"的隐性失败(比 warn 更早暴露)。
_LVM_DEB_PRESENT=0
for _p in "${REPO_ROOT}"/deployments/offline-files/kubespray/packages/lvm2_*.deb \
          "${REPO_ROOT}"/deployments/offline-files/kubespray/packages/lvm2_*.rpm; do
    [ -f "${_p}" ] && _LVM_DEB_PRESENT=1
done
if [ "${_LVM_DEB_PRESENT}" = "0" ]; then
    say "检查存储节点 lvm2 是否已在线安装(离线包未就绪时以此兜底)..."
    _ALL_HAS_LVM=1
    for _hn in "${CEPH_NODE_HOSTS[@]}"; do
        _ip=""
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            node_parse "${line}"
            [ "${NODE_HOSTNAME}" = "${_hn}" ] && { _ip="${NODE_IP}"; break; }
        done
        [ -n "${_ip}" ] || continue
        node_ssh "${_ip}" "${SSH_USER:-ubuntu}" "command -v lvm >/dev/null 2>&1 && lvm version >/dev/null 2>&1" >/dev/null 2>&1 || _ALL_HAS_LVM=0
    done
    if [ "${_ALL_HAS_LVM}" = "0" ]; then
        err "lvm2 离线包未就绪且存储节点未安装 lvm —— 无法离线部署 Rook OSD(重启后逻辑卷需 lvm 激活)"
        err "  请先在**联网机**执行: sudo ./deployments/scripts/tools/offline/fetch-lvm-packages.sh"
        err "  生成 lvm2_*.deb → ${REPO_ROOT}/deployments/offline-files/kubespray/packages/, 再重跑本模块"
        exit 1
    fi
    warn "  lvm2 离线包未就绪, 但存储节点已在线安装 lvm, 继续(重启后逻辑卷激活依赖已满足)"
fi

# ★ external 模式(CEPH_MODE=external): 不涉及本地裸盘/覆盖确认, 跳过裸盘选择与安全确认段;
#   仅 internal(集群内 Rook-Ceph)需要。operator/csi-operator 部署仍执行(供 CephConnection 使用)。
if [ "${CEPH_MODE:-internal}" != "external" ]; then
# ---------------- 2) 裸盘选择(显式指定 或 自动检测) ----------------
# 需求: 裸盘可在 cluster.conf 显式指定(CEPH_DATA_DISKS); 未指定则自动检测。
#   explicit 格式: "hostname:盘名1,盘名2;hostname2:盘名3" —— hostname 可省略(无 ':' → 应用到全部存储节点,
#   不同环境盘名不同, 如 VM 为 /dev/vdb,/dev/vdc,/dev/vdd、裸金属为 /dev/sdb,/dev/sdc 时, 全节点同规格写法最省);
#   盘名可带或不带 /dev/ 前缀(自动补全)。
declare -A NODE_DISKS
# 分类结果原始 TSV(<设备>\t<分类>\t<证据>), 供确认屏按类分组显示 —— 旧版只有一个"裸盘"列表,
# 上次 Ceph 占用的盘被判为"在用"后无处显示, 屏幕上只剩 <未检测到>, 人工无从判断。
declare -A NODE_TSV
if [ -n "${CEPH_DATA_DISKS:-}" ]; then
    say "[1/8] 使用 cluster.conf 显式指定裸盘(CEPH_DATA_DISKS), 跳过自动检测..."
    # 两轮: 先处理"具体节点"条目(hostname:盘), 再处理"全部节点"条目(无 hostname)——
    # 使 hostname 条目优先, 不会被全节点条目覆盖(顺序无关)。
    _ALL_DISKS=""
    while IFS=';' read -ra _grp; do
        for _g in "${_grp[@]}"; do
            [ -z "${_g}" ] && continue
            _hn="${_g%%:*}"; _ds="${_g#*:}"
            [ -z "${_hn}" ] || [ "${_hn}" = "${_ds}" ] && { _ALL_DISKS="${_ALL_DISKS:+${_ALL_DISKS};}${_g}"; continue; }
            _norm=""
            for _d in ${_ds//,/ }; do            # 盘名补 /dev/ 前缀(兼容裸名)
                _d="/dev/${_d#/dev/}"
                _norm="${_norm:+${_norm},}${_d}"
            done
            NODE_DISKS["${_hn}"]="${_norm}"
        done
    done <<< "${CEPH_DATA_DISKS}"
    # 第二轮: "全部节点"条目(无 hostname), 仅填充尚未指定的节点
    while IFS=';' read -ra _grp; do
        for _g in "${_grp[@]}"; do
            [ -z "${_g}" ] && continue
            _hn="${_g%%:*}"; _ds="${_g#*:}"
            [ -z "${_hn}" ] || [ "${_hn}" = "${_ds}" ] || continue
            _norm=""
            for _d in ${_ds//,/ }; do
                _d="/dev/${_d#/dev/}"
                _norm="${_norm:+${_norm},}${_d}"
            done
            for _h2 in "${CEPH_NODE_HOSTS[@]}"; do
                [ -n "${NODE_DISKS[${_h2}]:-}" ] || NODE_DISKS["${_h2}"]="${_norm}"
            done
        done
    done <<< "${CEPH_DATA_DISKS}"
else
    # auto 策略: 逐存储节点**分类**磁盘(空闲裸盘 + 上次 Ceph 占用盘; 排除系统盘/在用盘)
    # ★ 2026-09-24: 旧版只取"未使用裸盘" → 上次 Ceph 用的**分区/LVM 型** OSD 盘被判为"在用"
    #   而漏选, 于是重装时那几台节点显示"未检测到可用裸盘"(清理工具也清不到它们, 等于空转)。
    #   现按分类取 free ∪ ceph: ceph 类由本模块 7a 清空后复用(覆盖安装)或直接交给 Rook 认领
    #   (保留数据模式); inuse/mixed 一律不进 CR、不清理。
    say "[1/8] 分类存储节点磁盘(空闲裸盘 + 上次 Ceph 占用盘; tools/k8s/ceph-detect-disks.sh)..."
    DETECT_ARGS=()
    for _hn in "${CEPH_NODE_HOSTS[@]}"; do DETECT_ARGS+=(--node "${_hn}"); done
    # 保留 stderr(不 2>/dev/null): detect 对"节点 SSH 失败/无裸盘"的 warn 必须可见, 否则人工无法判断检测是否可信
    DETECT_OUT="$(bash "${TOOLS_K8S}/ceph-detect-disks.sh" "${DETECT_ARGS[@]}" -m --classify)" || true
    if [ -z "${DETECT_OUT}" ]; then
        warn "  自动检测未返回结果; 若 VM 集群请确认 VM_DATA_DISKS>0 且已重建/附加数据盘; 可显式设 CEPH_DATA_DISKS 指定盘"
    fi
    while IFS=$'\t' read -r _hn _dev _cls _ev; do
        [ -n "${_hn}" ] && [ -n "${_dev}" ] || continue
        NODE_TSV["${_hn}"]="${NODE_TSV[${_hn}]:-}${_dev}"$'\t'"${_cls}"$'\t'"${_ev}"$'\n'
        case "${_cls}" in
            free|ceph)  NODE_DISKS["${_hn}"]="${NODE_DISKS[${_hn}]:-}${NODE_DISKS[${_hn}]:+,}${_dev}" ;;
        esac
    done <<< "${DETECT_OUT}"
fi
# 至少一个节点有盘才继续; 否则明确报错(避免生成无 OSD 集群)
_HAS_DISK=0
for _hn in "${CEPH_NODE_HOSTS[@]}"; do [ -n "${NODE_DISKS[${_hn}]:-}" ] && _HAS_DISK=1; done
[ "${_HAS_DISK}" = "1" ] || { err "所有存储节点均未指定/检测到裸盘; 请显式设 CEPH_DATA_DISKS(\"hostname:盘名,盘名\", 或省略 hostname 应用到全部节点)或先为节点附加数据盘"; exit 1; }

# ---------------- 3) 醒目提醒 + sleep(防覆盖磁盘 double-check) ----------------
say "[2/8] 部署前安全确认 ..."
echo ""
echo -e "\033[41m\033[97m================================================================================\033[0m"
echo -e "\033[41m\033[97m ⚠⚠⚠  Ceph 集群部署确认(将使用以下节点与裸盘, 请仔细核对)      ⚠⚠⚠\033[0m"
echo -e "\033[41m\033[97m   Rook ${ROOK_VERSION:-v1.20.2} / Ceph ${CEPH_VERSION} / mon=${CEPH_MON_COUNT} / mgr=${CEPH_MGR_COUNT}\033[0m"
echo -e "\033[41m\033[97m   副本 size=${CEPH_POOL_REPLICAS} min_size=${CEPH_POOL_MIN_SIZE}(host 故障域)\033[0m"
echo -e "\033[41m\033[97m   存储节点 label: ${CEPH_NODE_LABEL}   命名空间: ${CEPH_NAMESPACE}\033[0m"
# 确认屏用: 按分类逐行列出某节点的磁盘 + 证据(供人工核对到底动哪些盘)
_show_node_class() {   # <hostname> <分类> <标题> <颜色码>
    local _hn="$1" _want="$2" _title="$3" _color="$4" _d _c _e _list=""
    [ -n "${NODE_TSV[${_hn}]:-}" ] || return 0
    while IFS=$'\t' read -r _d _c _e; do
        [ -n "${_d}" ] || continue
        [ "${_c}" = "${_want}" ] || continue
        _list="${_list:+${_list},}${_d}"
    done <<< "${NODE_TSV[${_hn}]}"
    [ -n "${_list}" ] || return 0
    echo -e "${_color}   · ${_hn}  ${_title}: ${_list}\033[0m"
    while IFS=$'\t' read -r _d _c _e; do
        [ -n "${_d}" ] || continue
        [ "${_c}" = "${_want}" ] || continue
        echo -e "${_color}        ${_d} ← ${_e}\033[0m"
    done <<< "${NODE_TSV[${_hn}]}"
}

for _hn in "${CEPH_NODE_HOSTS[@]}"; do
    if [ -n "${NODE_TSV[${_hn}]:-}" ]; then
        _REDBG='\033[41m\033[97m'
        _show_node_class "${_hn}" free  "空闲裸盘(将作新 OSD)"            "${_REDBG}"
        _show_node_class "${_hn}" ceph  "上次 Ceph 占用(覆盖安装将清空复用)" "${_REDBG}"
        _show_node_class "${_hn}" mixed "混合盘(不清理, 需人工判断)"       "${_REDBG}"
        _show_node_class "${_hn}" inuse "在用盘(不会触碰)"                "${_REDBG}"
        [ -n "${NODE_DISKS[${_hn}]:-}" ] \
            || echo -e "${_REDBG}   · ${_hn}  →  <无可用盘! 该节点不会创建 OSD>\033[0m"
        unset _REDBG
    else
        echo -e "\033[41m\033[97m   · ${_hn}  →  裸盘(显式 CEPH_DATA_DISKS): ${NODE_DISKS[${_hn}]:-<无!>}\033[0m"
    fi
done
echo -e "\033[41m\033[97m ⚠ 确认要点: ① 盘名与节点一一对应正确(不会覆盖系统盘/在用盘)        \033[0m"
echo -e "\033[41m\033[97m   ② 「上次 Ceph 占用」的盘会被**清空数据**后复用(覆盖安装, 全新 fsid)\033[0m"
echo -e "\033[41m\033[97m      保留旧数据请设 CEPH_PRE_CLEANUP_EXISTING=false(交 Rook 认领)   \033[0m"
echo -e "\033[41m\033[97m   ③ 「在用盘/混合盘」永远不动(人工确认要清请用 ceph-cleanup.sh)     \033[0m"
echo -e "\033[41m\033[97m   ④ CEPH_NODES 是你想部署的节点; 核对无误将自动继续                 \033[0m"
echo -e "\033[41m\033[97m   有误请 Ctrl-C 中止修正后重跑                                      \033[0m"
echo -e "\033[41m\033[97m================================================================================\033[0m"
echo ""
if [ "${CEPH_CONFIRM_SLEEP:-60}" -gt 0 ] 2>/dev/null; then
    say "sleep ${CEPH_CONFIRM_SLEEP}s 供核对(CI 可设 CEPH_CONFIRM_SLEEP=0 跳过)..."
    # 逐秒刷新倒计时(单行, 红底), 与 k8s_deploy 部署前倒计时一致 —— 之前静默等待看不到进度
    for _c in $(seq "${CEPH_CONFIRM_SLEEP}" -1 1); do
        printf "\r%s" "$(printf '\033[41m\033[97m  ⏳ 倒计时 %d 秒继续(请核对上方 Ceph 存储节点/裸盘)      \033[0m' "${_c}")"
        sleep 1
    done
    printf "\r%s\n" "$(printf '\033[0m  %s             ')"
    printf "\r%s\n" "$(printf '\033[0m  %s             ')"
    unset _c
else
    say "CEPH_CONFIRM_SLEEP=0, 跳过等待(请务必已人工核对上方节点/裸盘)"
fi

# ---------------- 3.5) 让 master 节点可调度(默认) ----------------
# Rook mon/osd 会调度到 master(存储节点默认含 master, 3 副本 mon 需要 ≥3 台可调度节点);
# kubespray 默认给 master 打了 control-plane NoSchedule taint → mon/osd 无法调度到 master,
# 只有 worker 时 mon 会因 anti-affinity 卡 Pending(3 台 mon 至少要 3 台可调度节点)。
# 默认去掉 master 的 control-plane taint(整个集群工作负载均可调度到 master, 符合"master 可调度"需求;
# 需恢复 taint 时: kubectl taint nodes <master> node-role.kubernetes.io/control-plane=:NoSchedule)。
if [ "${CEPH_ENABLE_MASTER_SCHEDULE:-true}" = "true" ]; then
    say "[2.5/8] 默认允许 master 调度: 去掉 control-plane NoSchedule taint(幂等)..."
    _MASTER_IPS=()
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_ROLE}" = "master" ] && _MASTER_IPS+=("${NODE_IP}")
    done
    for _mip in "${_MASTER_IPS[@]:-}"; do
        _mhn=""
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            node_parse "${line}"
            [ "${NODE_IP}" = "${_mip}" ] && { _mhn="${NODE_HOSTNAME}"; break; }
        done
        [ -n "${_mhn}" ] || continue
        # 幂等: 有 taint 才去掉; 无 taint 直接 ok
        # (jsonpath 用命令替换取回, 避免双引号内 '$' 组合的解析坑)
        _TAINTS="$( (SSH "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get node ${_mhn} -o jsonpath={.spec.taints} 2>/dev/null" || true) )"
        if printf '%s' "${_TAINTS}" | grep -q control-plane; then
            SSH "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes ${_mhn} node-role.kubernetes.io/control-plane- 2>/dev/null" \
                && ok "  ${_mhn}(${_mip}) 已去掉 control-plane taint(master 可调度)" \
                || warn "  ${_mhn}(${_mip}) 去 taint 失败(手动: kubectl taint nodes ${_mhn} node-role.kubernetes.io/control-plane-)"
        else
            ok "  ${_mhn}(${_mip}) 无 control-plane taint(已可调度)"
        fi
        unset _TAINTS
    done
fi

fi

# ---------------- 4) 存储节点准备(rbd 模块 + lvm2 + node label) ----------------
say "[3/8] 存储节点准备(rbd 内核模块 / lvm2 离线安装 / node label)..."
for _hn in "${CEPH_NODE_HOSTS[@]}"; do
    _ip=""; _user="${SSH_USER:-ubuntu}"
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_HOSTNAME}" = "${_hn}" ] && { _ip="${NODE_IP}"; _user="${NODE_USER}"; break; }
    done
    [ -n "${_ip}" ] || { warn "  ${_hn} 不在 cluster.conf NODES 中(仅打 label 会失败), 跳过"; continue; }
    say "  ── [${_hn}](${_ip}) ──"
    # 4a. rbd 内核模块(立即加载 + 持久化)
    node_ssh "${_ip}" "${_user}" "sudo modprobe rbd 2>/dev/null; grep -q '^rbd' /etc/modules-load.d/rbd.conf 2>/dev/null || echo 'rbd' | sudo tee /etc/modules-load.d/rbd.conf >/dev/null" \
        && ok "    rbd 内核模块就绪" || warn "    rbd 模块加载失败(VM 内核需支持, 检查 modprobe rbd)"
    # 4b. lvm2: 检测缺失 → 从离线 packages 安装(install-worker-packages.sh 含 offline-files/kubespray/packages)
    if ! node_ssh "${_ip}" "${_user}" "command -v lvm >/dev/null 2>&1 && lvm version >/dev/null 2>&1" >/dev/null 2>&1; then
        say "    lvm2 缺失, 从离线 .deb 安装(packages 目录, 由 fetch-lvm-packages.sh 生成)..."
        if [ -d "${REPO_ROOT}/deployments/offline-files/kubespray/packages" ] && \
            bash "${SCRIPT_DIR}/tools/node/install-worker-packages.sh" "${_ip}" "${_user}" >/dev/null 2>&1; then
            node_ssh "${_ip}" "${_user}" "command -v lvm >/dev/null 2>&1" >/dev/null 2>&1 \
                && ok "    lvm2 已安装(离线包)" || err "    packages 无 lvm2 或安装失败 —— lvm2 离线包未就绪且节点无 lvm, 部署 OSD 必失败"
        else
            # 前置 lvm 预检已保证"离线包存在 或 节点已在线装 lvm", 走到这里 = 前置被绕过/包缺失
            err "    lvm2 离线安装失败(install-worker-packages.sh 退出非 0)。请联网机先跑 tools/offline/fetch-lvm-packages.sh 生成 lvm2_*.deb, 重跑本模块"
            exit 1
        fi
    else
        ok "    lvm2 已就绪"
    fi
    # 4c. node label(选择部署节点)
    SSH "${K} label node ${_hn} ${CEPH_NODE_LABEL} --overwrite >/dev/null 2>&1" \
        && ok "    node label 已打: ${CEPH_NODE_LABEL}" \
        || warn "    label 失败(节点 ${_hn} 可能尚未就绪?)"
done

# ---------------- 5) Ceph 离线镜像就绪校验 ----------------
# ★ 镜像已由 k8s 阶段预加载 play(cluster.yml 内置)随 kubespray 镜像一起同步到全部节点并
#   ctr import(见 cubestack-offline.sh resolve_preload_image_files: CEPH_ENABLED=true 时把
#   CEPH_IMAGE_DIR 的 *.tar 追加进 preload-images.lst)。此处不再重复同步, 只做就绪校验,
#   并给离线环境明确指引(缺失时 warn + 提供 ceph-sync-images.sh 手工补救, 不阻断)。
say "[4/8] 校验 ceph 离线镜像已预加载到节点(ctr -n k8s.io images ls)..."
# 源目录 CEPH_IMAGE_DIR 可能已删除(镜像已并入 k8s 阶段 images/ 预加载, 源目录仅为保存副本):
# 目录存在才逐节点校验缺失; 不存在则跳过校验(节点镜像由 k8s 阶段保证, 无需源目录)。
if [ -d "${CEPH_IMAGE_DIR}" ] && ls "${CEPH_IMAGE_DIR}"/*.tar >/dev/null 2>&1; then
    _MISSING=()
    for _hn in "${CEPH_NODE_HOSTS[@]}"; do
        _ip=""
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            node_parse "${line}"
            [ "${NODE_HOSTNAME}" = "${_hn}" ] && { _ip="${NODE_IP}"; break; }
        done
        [ -n "${_ip}" ] || continue
        # `|| true`: SSH 本身失败(节点瞬断)会让本地管道非 0 → 赋值非 0 → set -e 结束模块;
        # 下面本就按 `_has` 可空处理(空 = 视为缺镜像并给出补救指引)。
        _has="$(SSH "sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -E 'rook/ceph:|ceph/ceph:|cephcsi' | wc -l" 2>/dev/null | tr -d ' ' || true)"
        if [ "${_has:-0}" -lt 3 ]; then
            _MISSING+=("${_hn}")
        else
            ok "  ${_hn} ceph 镜像已就绪(rook/ceph/cephcsi 均已在 containerd)"
        fi
    done
    if [ "${#_MISSING[@]}" -gt 0 ]; then
        warn "  以下节点未检测到 ceph 镜像: ${_MISSING[*]} —— 可能预加载未覆盖(k8s 阶段 CEPH_ENABLED 需 true); 手工补救:"
        warn "    bash ${SCRIPT_DIR}/tools/images/ceph-sync-images.sh --node ${_MISSING[0]}"
        warn "    或在 cluster.conf 设 CEPH_ENABLED=true 后重跑 k8s_deploy 阶段(全量覆盖安装: ./deploy-cluster.sh --fresh)"
    fi
else
    say "  ${CEPH_IMAGE_DIR} 不存在或无镜像 tar(源目录可删除); 节点镜像由 k8s 阶段 images/ 预加载保证, 跳过校验"
fi

# ---------------- 6) 部署 Rook operator(crds → common → csi-operator → operator) ----------------
say "[5/8] 部署 Rook operator(manifest: ${CEPH_ROOK_MANIFEST_DIR})..."
REMOTE_DIR="/tmp/rook-manifests"
# ★ 先建目录并立即 chown 给 SSH 用户: 此前 sudo mkdir 后目录属 root, scp(ubuntu)写不进去,
#   5 个 manifest 全没拷过去 → apply crds.yaml 报 path does not exist(错误被 || true 吞掉)。
SSH "sudo rm -rf ${REMOTE_DIR} && sudo mkdir -p ${REMOTE_DIR} && sudo chown ${SSH_USER:-ubuntu}:${SSH_USER:-ubuntu} ${REMOTE_DIR}" >/dev/null 2>&1
for f in crds.yaml common.yaml csi-operator.yaml operator.yaml toolbox.yaml; do
    [ -f "${CEPH_ROOK_MANIFEST_DIR}/${f}" ] || { warn "  缺 manifest: ${f}(重跑 rook-fetch-manifests.sh)"; continue; }
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "${CEPH_ROOK_MANIFEST_DIR}/${f}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:${REMOTE_DIR}/${f}" \
        || { err "  scp ${f} 到 master 失败(检查 SSH 密钥/节点连通)"; exit 1; }
done
SSH "sudo chown -R \$(id -un) ${REMOTE_DIR}" >/dev/null 2>&1 || true
# apply 顺序: crds → common → csi-operator(带 CRD: operatorconfigs.csi.ceph.io 等)
for f in crds.yaml common.yaml; do
    say "  apply ${f} ..."
    SSH "${K} apply --server-side -f ${REMOTE_DIR}/${f} >/dev/null 2>&1" \
        || SSH "${K} apply -f ${REMOTE_DIR}/${f} >/dev/null 2>&1" \
        || { err "  apply ${f} 失败"; exit 1; }
done
# ★ ceph-csi-operator 按需安装(需求: 已装则不装, 未装才装):
#   csi-operator 调和 CSI 驱动(集群内 CephCluster 或外部 Ceph 都需要)。
#   已存在 ceph-csi-operator 且 CSI 驱动(csi-rbdplugin DS)已就绪 → 跳过(不需要重复安装);
#   未就绪 → 安装(需要)。用 ssh 直连规避 "函数 + $(函数 \"串\")" 嵌套解析异常。
_CSI_OP="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "${K} -n ${CEPH_NAMESPACE} get deploy ceph-csi-operator --no-headers 2>/dev/null")" || true
_CSI_DS="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "${K} -n ${CEPH_NAMESPACE} get ds rook-ceph.rbd.csi.ceph.com-nodeplugin --no-headers 2>/dev/null")" || true
if [ -n "${_CSI_OP}" ] && [ -n "${_CSI_DS}" ]; then
    say "  ceph-csi-operator + CSI 驱动已存在, 跳过安装 csi-operator.yaml(不需要重复安装)"
else
    say "  apply csi-operator.yaml ..."
    SSH "${K} apply --server-side -f ${REMOTE_DIR}/csi-operator.yaml >/dev/null 2>&1" \
        || SSH "${K} apply -f ${REMOTE_DIR}/csi-operator.yaml >/dev/null 2>&1" \
        || { err "  apply csi-operator.yaml 失败"; exit 1; }
fi
unset _CSI_OP _CSI_DS
# ★ operator.yaml 的 operatorconfig CR 依赖 csi-operator 提供的 CRD; CRD 未 Established 时
#   apply 会报 "no matches for kind"(竞态)。等 CRD Established 后再 apply, 失败留 stderr 便于定位。
say "  等待 csi-operator CRD Established(最长 120s)..."
_CRD_OK=0
for _i in $(seq 1 24); do
    if SSH "${K} get crd operatorconfigs.csi.ceph.io >/dev/null 2>&1" && \
       SSH "${K} wait --for condition=Established crd/operatorconfigs.csi.ceph.io --timeout=5s >/dev/null 2>&1"; then
        _CRD_OK=1; break
    fi
    sleep 5
done
[ "${_CRD_OK}" = "1" ] && ok "  operatorconfigs.csi.ceph.io CRD Established" \
    || warn "  CRD 120s 内未 Established(继续尝试 apply, 若失败查看下方 kubectl 报错)"
say "  apply operator.yaml ..."
# 普通 apply 也做重试(CRD 刚建立时 discovery 可能瞬时未刷新)
_OP_APPLY=0
for _i in 1 2 3; do
    if SSH "${K} apply --server-side -f ${REMOTE_DIR}/operator.yaml >/dev/null 2>&1" \
        || SSH "${K} apply -f ${REMOTE_DIR}/operator.yaml >/dev/null 2>&1"; then
        _OP_APPLY=1; break
    fi
    sleep 5
done
[ "${_OP_APPLY}" = "1" ] || {
    err "  apply operator.yaml 失败; kubectl 报错:"
    SSH "${K} apply -f ${REMOTE_DIR}/operator.yaml" 2>&1 | sed 's/^/    /' || true
    exit 1
}
unset _CRD_OK _OP_APPLY
say "  等待 rook-ceph-operator Running(最长 180s)..."
OP_OK=0
for i in $(seq 1 18); do
    OP_OK="$( (SSH "${K} -n ${CEPH_NAMESPACE} get deploy rook-ceph-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null" || true) )"
    [ "${OP_OK:-0}" -ge 1 ] 2>/dev/null && break
    sleep 10
done
[ "${OP_OK:-0}" -ge 1 ] 2>/dev/null || { warn "  rook operator 未就绪(检查 kubectl -n rook-ceph get pods)"; }
ok "  Rook operator 已部署"

# ---------------- 7) 生成并应用 CephCluster CR(按节点+裸盘) ----------------
# ★ 重装策略(2026-09-07 简化: 备份/恢复已拆出为独立模块 ceph_backup, 部署脚本只保留覆盖安装/清理):
#   ① 集群内已有 CephCluster → 幂等更新(不重建);
#   ② 无 CephCluster + CEPH_PRE_CLEANUP_EXISTING=true(默认)→ 清盘覆盖安装, 全新 fsid;
#   ③ 无 CephCluster + PRE_CLEANUP=false(保留数据)→ 不wipe不清理:
#      namespace 残留 rook-ceph-mon secret(含 fsid+keyring)时 Rook 自动认领旧 OSD 数据;
#      无 secret(整 ns 重建)→ 全新 fsid。整 ns 重建后需认领旧数据时, 先单独执行
#      --steps ceph_backup(CEPH_BACKUP_ACTION=restore)从节点根盘备份恢复 secret+mon store,
#      再以 PRE_CLEANUP=false 重跑本模块 —— 认领凭证是 secret, 不是 CR 字段
#      (CephCluster CRD 无 spec.fsid, 向 CR 注入会被 API 拒绝)。
#   绝不整份恢复旧 CR: 旧 CR 的 storage.nodes/devices/placement 来自上一代环境, apply 后
#   ① 盘名/节点过时(历史残留 /dev/rbd0 → OSD 永不创建) ② 残留 mon store(/var/lib/rook/mon-*,
#   集群无关路径)被新 mon 直接复用, monmap 还是旧集群的死 IP → quorum 永久卡死。
_HAS_CC_NOW="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --no-headers 2>/dev/null" || true) )"
# ★ 幂等卸载(2026-09-05 重构): PRE_CLEANUP=true(覆盖安装)且检测到已有 CephCluster 时,
#   先走标准卸载流程删旧集群(Rook cleanupPolicy yes-really-destroy-data 擦盘), 再走下方 7a 物理清盘。
#   支持两种幂等场景:
#     ① 只重装 Ceph(K8s 保留): --steps ceph,ceph_csi → 自动删旧集群+清盘 → 全新 fsid;
#     ② K8s 重装后盘复用: k8s 重装中 rook ns 已清(_HAS_CC_NOW 空)→ 跳过本步, 7a 直接清盘。
#   PRE_CLEANUP=false(保留数据模式)→ 不删不wipe, 保留盘上旧数据(见下方认领说明)。
if [ -n "${_HAS_CC_NOW}" ] && [ "${_CEPH_PRE_CLEANUP}" = "1" ]; then
    say "  检测到已有 CephCluster($(echo "${_HAS_CC_NOW}" | awk '{print $1}')) + CEPH_PRE_CLEANUP_EXISTING=true → 幂等卸载旧集群(Rook 擦盘)..."
    bash "${SCRIPT_DIR}/tools/k8s/ceph-cleanup.sh" --delete-cluster \
        || warn "  旧集群删除超时/失败(继续, 7a 将物理清盘兜底)"
    _HAS_CC_NOW="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --no-headers 2>/dev/null" || true) )"
fi
if [ -n "${_HAS_CC_NOW}" ]; then
    say "  集群内已有 CephCluster($(echo "${_HAS_CC_NOW}" | awk '{print $1}')), 用当前 CR 幂等更新(不重建)"
else
    # ★ 覆盖/保留决策(备份恢复走独立模块 ceph_backup, 见 15_ceph_backup.sh):
    #   · 覆盖安装(CEPH_PRE_CLEANUP_EXISTING=true, 默认)→ 完整清空旧盘, 全新 fsid(7a 执行 wipe);
    #   · 保留数据模式(PRE_CLEANUP=false)→ 不wipe不清理, 检查 namespace 残留的 rook-ceph-mon secret:
    #       - secret 在 → 直接复用, Rook 自动认领旧 OSD 数据(无需任何注入);
    #       - secret 不在(如整 ns 重建)→ 全新 fsid; 如需认领旧数据, 先 --steps ceph_backup
    #         (CEPH_BACKUP_ACTION=restore)恢复 secret+mon store 后重跑本模块。
    if [ "${_CEPH_PRE_CLEANUP}" = "1" ]; then
        say "  覆盖安装(默认): 完整清空旧盘 → 全新 fsid(不认领旧 OSD 数据)"
    else
        _MON_SECRET="$( (SSH "${K} -n ${CEPH_NAMESPACE} get secret rook-ceph-mon --no-headers 2>/dev/null" || true) )"
        if [ -n "${_MON_SECRET}" ]; then
            _SECRET_FSID="$( (SSH "${K} -n ${CEPH_NAMESPACE} get secret rook-ceph-mon -o jsonpath='{.data.fsid}' 2>/dev/null" || true) | base64 -d 2>/dev/null )"
            say "  保留数据模式 → 检测到残留 rook-ceph-mon secret(fsid=${_SECRET_FSID:-?}) → 直接复用, Rook 自动认领旧 OSD 数据"
        else
            warn "  保留数据模式但 namespace 无 rook-ceph-mon secret(整 ns 重建)→ 全新 fsid(不认领旧 OSD 数据)"
            warn "  如需认领旧数据: 先 --steps ceph_backup(CEPH_BACKUP_ACTION=restore)从节点根盘备份恢复, 再重跑本模块"
        fi
    fi
fi

# ★ 节点<3 → 跳过集群内 CephCluster 创建(mon 法定人数不足; csi-operator 仍按需安装, 可连外部 Ceph)
if [ "${_CEPH_SKIP_CLUSTER}" = "1" ]; then
    if [ "${CEPH_MODE:-internal}" = "external" ]; then
        say "  CEPH_MODE=external → 不创建集群内 CephCluster(由 ceph_csi 模块经 CephConnection 接入外部 Ceph: ${CEPH_MONITORS:-<未配置>})"
        say "  operator/csi-operator 已部署; 等待 operator Ready(供 CephConnection/CSI 使用)..."
        _OP_OK=0
        for _oi in $(seq 1 30); do
            _OP_RDY="$( (SSH "${K} -n ${CEPH_NAMESPACE} get deploy rook-ceph-operator -o jsonpath={.status.readyReplicas} 2>/dev/null" || true) )"
            [ "${_OP_RDY}" = "1" ] && { _OP_OK=1; break; }
            [ "$((_oi % 6))" -eq 0 ] && say "  rook-ceph-operator 未 Ready(等待第 ${_oi}/30 次)..."
            sleep 10
        done
        unset _OP_RDY
        if [ "${_OP_OK}" = "1" ]; then
            ok "  rook-ceph-operator Ready(外部 Ceph 接入就绪, 继续 ceph_csi 模块)"
        else
            warn "  rook-ceph-operator 300s 内未 Ready(检查 operator pod 日志; ceph_csi 模块仍会重试)"
        fi
        unset _OP_OK _oi
    else
        say "  存储节点 <${CEPH_MIN_NODES}, 跳过生成 CephCluster CR(未创建集群内 CephCluster)"
        say "  可选: 设 CEPH_MODE=external 由 ceph_csi 模块连接外部 Ceph 并创建 StorageClass"
    fi
else
    # ★ 全新部署(无现存 CephCluster)先清理各存储节点残留: 磁盘数据 + mon store + 遗留 rbd 设备。
    if [ -z "${_HAS_CC_NOW}" ]; then
        # --- 7a) CEPH_PRE_CLEANUP_EXISTING=true → 完整清空上次部署 ceph 所用的所有磁盘 ---
        # 只按"本模块 [1/8] 分类出的盘"清(不依赖旧 CR 的 storage 列表 —— 旧 CR 过时时其列表无效,
        # 曾导致 15 块盘未被 wipe, 新集群 OSD 因 "belonging to a different ceph cluster" 全部被跳过)。
        # 分两步:
        #   ① ceph-cleanup.sh --wipe-disks: 标准 Ceph 清除步骤(停进程/解 LVM·VG·dm/签名/分区表);
        #   ② 下方逐盘彻底擦除兜底(bluestore_wipe_dev): 官方 zap-device 清掉 label 的**全部副本**
        #      + 候选偏移 dd + 逐处校验。两步都保留: ① 解 LVM 才能让 ② 落到裸盘上, ② 才是
        #      "label 真没了"的保证; 只擦头尾会漏 locations → ceph-volume 仍报 "already prepared"
        #      → 0 OSD(★ 2026-09-24 实机事故根因, 详见 lib-common.sh 的 bluestore_wipe_remote_lib)。
        if [ "${_CEPH_PRE_CLEANUP}" = "1" ]; then
            # 7a-① 标准 Ceph 清除步骤(停进程 → 解 LVM/VG/dm-mapper → wipefs/分区表/bluestore 签名 →
            #   清 /var/lib/rook 等残留), 只作用于**被判为 Ceph 占用**的盘 —— 工具自带护栏,
            #   在用盘/混合盘一律不碰。旧版 7a 只有下面的 dd 擦除, 于是残留在盘上的 ceph VG/LV
            #   没人解绑 → Rook/osd-prepare 认到旧 LVM 元数据报 "already prepared" / 0 OSD。
            say "  7a) 标准清除上次 Ceph 占用的磁盘(停进程/解 LVM/dm/签名/分区表; tools/k8s/ceph-cleanup.sh)..."
            bash "${TOOLS_K8S}/ceph-cleanup.sh" --wipe-disks \
                || warn "    标准清除未全部成功(见上方输出); 继续走下面的签名擦除兜底"
            # 7a-② 逐盘彻底擦除兜底(★ 2026-09-24 事故修复: 这里原来手写 dd 只擦
            #   头 64MB/1GB/size÷20/size÷2/尾 64MB, 与 Ceph v20 **实际**的 label 副本位置
            #   (10GiB/100GiB/1000GiB, 见 `ceph-bluestore-tool show-label` 的 locations)对不上
            #   → 副本残留 → `ceph-volume raw list` 仍认得出旧 OSD(旧 fsid) → Rook osd-prepare
            #   判 "Raw device ... is already prepared" → 认领别的集群的 OSD 被跳过 →
            #   **新集群 0 OSD**(CephCluster 依然 Ready, 只报 HEALTH_WARN "OSD count 0"),
            #   部署却在 [7/8] 等待里超时/中断。现改用共享实现 lib-common.sh::
            #   bluestore_wipe_remote_lib(官方 zap-device 读 label 自带 locations, 版本无关 +
            #   候选偏移 dd 兜底 + 逐处校验; ceph-cleanup.sh 用的是同一份), 校验不过即失败。
            for _hn in "${CEPH_NODE_HOSTS[@]}"; do
                _ip=""
                for line in "${NODES[@]:-}"; do
                    [ -z "${line}" ] && continue
                    node_parse "${line}"
                    [ "${NODE_HOSTNAME}" = "${_hn}" ] && { _ip="${NODE_IP}"; break; }
                done
                [ -n "${_ip}" ] || continue
                for _d in ${NODE_DISKS[${_hn}]//,/ }; do
                    say "  wipe ${_hn} ${_d}(官方 zap-device 清 label 副本 + 头/分区表/尾, 逐处校验)..."
                    node_ssh "${_ip}" "${SSH_USER:-ubuntu}" "sudo bash -s -- ${_d}" \
                        <<< "$(bluestore_wipe_remote_lib; printf '\nbluestore_wipe_dev "$1" || exit 1\n')" \
                        && ok "    ${_hn} ${_d} 已彻底清空(无 bluestore label 残留)" \
                        || warn "    ${_hn} ${_d} 清盘未通过校验(上方已打印残留偏移) —— 该盘会被 Rook 判 already prepared → 0 OSD, 请人工复核后再继续"
                done
                # 遗留 rbd 设备: 曾导致 osd-prepare 的 show-label 扫到挂起 IO(AIO 读 D 状态) → prepare 永久卡死
                node_ssh "${_ip}" "${SSH_USER:-ubuntu}" "ls /dev/rbd* >/dev/null 2>&1 && { sudo rm -f /dev/rbd* && echo '  残留 rbd 设备节点已删(/dev/rbd*)'; } || true" \
                    | grep -v '^$' || true
            done
        fi

        # --- 7b) 清理 /var/lib/rook 残留(mon store + osd 元数据 + config/keyring) ---
        # mon 数据在集群无关路径 <dataDirHostPath>/mon-*(如 /var/lib/rook/mon-a), 上一代集群删除后
        # 仍残留; 新 mon 复用后从旧 store 恢复旧 monmap(死 IP)→ quorum 永久卡死(此前事故根因)。
        # 覆盖安装(默认)连 osd 元数据/配置一起清(盘已 wipe, 元数据无保留价值);
        # 保留数据模式(PRE_CLEANUP=false)只清 mon-*, 保留 osd 元数据辅助 Rook 认领。
        for _hn in "${CEPH_NODE_HOSTS[@]}"; do
            _ip=""
            for line in "${NODES[@]:-}"; do
                [ -z "${line}" ] && continue
                node_parse "${line}"
                [ "${NODE_HOSTNAME}" = "${_hn}" ] && { _ip="${NODE_IP}"; break; }
            done
            [ -n "${_ip}" ] || continue
            if [ "${_CEPH_PRE_CLEANUP}" = "1" ]; then
                say "  清理 ${_hn} /var/lib/rook 残留(mon-* + rook-ceph/osd 元数据 + config/keyring)..."
                node_ssh "${_ip}" "${SSH_USER:-ubuntu}" "sudo rm -rf /var/lib/rook/mon-* /var/lib/rook/rook-ceph 2>/dev/null; true" \
                    && ok "    ${_hn} /var/lib/rook 已清空" || warn "    ${_hn} /var/lib/rook 清理失败"
            else
                say "  清理 ${_hn} 残留 mon store(/var/lib/rook/mon-*, 全新 mon 状态; osd 元数据保留辅助认领)..."
                node_ssh "${_ip}" "${SSH_USER:-ubuntu}" "sudo rm -rf /var/lib/rook/mon-*" || warn "    ${_hn} mon store 清理失败(节点全新无残留可忽略)"
            fi
        done
    fi
    # 生成并应用 CephCluster CR(当前节点/裸盘)。
    # ★ 认领旧数据不依赖 CR: Rook 凭 namespace 残留的 rook-ceph-mon secret(fsid+keyring)
    #   自动复用 fsid 认领盘上旧 OSD 数据 —— CR 无需也不允许注入 spec.fsid(CRD 无此字段)。
    #   无论是否认领, 都必须走到下方 [7/8] 就绪等待 —— 此前 toolbox/[7/8] 等待/调优只写在部分
    #   分支里, 曾导致"apply 完 CR 直接宣布完成(集群仍在 Progressing), ceph_csi 一进来就报错打断部署"。
    say "[6/8] 生成并应用 CephCluster CR(mon=${CEPH_MON_COUNT}, 副本=${CEPH_POOL_REPLICAS}/${CEPH_POOL_MIN_SIZE})..."
    LOCAL_CR="$(mktemp)"
{
    echo "apiVersion: ceph.rook.io/v1"
    echo "kind: CephCluster"
    echo "metadata:"
    echo "  name: rook-ceph"
    echo "  namespace: ${CEPH_NAMESPACE}"
    echo "spec:"
    echo "  cephVersion:"
    echo "    image: quay.io/ceph/ceph:${CEPH_VERSION}"
    echo "    allowUnsupported: false"
    echo "  dataDirHostPath: /var/lib/rook"
    echo "  mon:"
    echo "    count: ${CEPH_MON_COUNT}"
    echo "    allowMultiplePerNode: false"
    echo "  mgr:"
    echo "    count: ${CEPH_MGR_COUNT}"
    echo "    modules:"
    echo "      - name: pg_autoscaler"
    echo "        enabled: true"
    echo "  crashCollector:"
    echo "    disable: false"
    echo "  dashboard:"
    echo "    enabled: ${CEPH_DASHBOARD_ENABLED:-true}"
    echo "    ssl: true"
    echo "  network:"
    echo "    provider: \"\""
    # ★ hostNetwork(2026-09-09): CEPH_HOST_NETWORK=true(默认)时, mon/osd/mgr 直接监听节点 IP;
    #   CephCluster spec.network.hostNetwork=true → mon 公告节点 IP:6789(v1)/3300(v2),
    #   外部 ceph-csi-operator / 上层 *-external NodePort 直连 mon 完整 msgr 帧不再受
    #   kube-proxy DNAT 影响(历史: NodePort 环 v1 握手发 auth 后无响应 —— CNI fabric +
    #   SNAT 对 mon 长连接 msgr 帧损坏)。hostNetwork 下对外暴露走 CEPH_EXPOSE_HOSTNETWORK
    #   (tools/k8s/ceph-expose-external.sh 改为对节点 IP 直连端口)。
    echo "    hostNetwork: $(echo "${CEPH_HOST_NETWORK:-true}" | tr '[:upper:]' '[:lower:]')"
    echo "  placement:"
    # ★ 2026-09-24 修复: 每个 Ceph **守护进程**都要显式钉到存储节点 —— 原来只手写了 mon/osd,
    #   于是 mgr(真 daemon, 也往宿主机 /var/lib/rook 写数据)被调度到 worker 上(实机: mgr-a
    #   落在 mxgpu-3-36), 还被 Rook 带出 crashcollector-mxgpu-3-36 / exporter-mxgpu-3-36 两个
    #   伴生 pod 一起写到 worker 的 /var/lib/rook —— 与文档 docs/ceph-rook.md §2"只调度到指定
    #   的存储节点(默认只装在 master 节点)"直接冲突, 也让重装清理(只清存储节点)在 worker 上留残留。
    #   ⚠ 不要图省事改用 `placement.all`: Rook 会把 `all` 一并套到 **CSI daemonsets** 上,
    #     把 rbd/cephfs nodeplugin 也钉死在存储节点 —— 那些 nodeplugin 必须跑在**每个**可能挂
    #     ceph 卷的节点(worker 上的 PVC 全靠它), 钉死 = worker 上的卷挂不上。只逐个 daemon 写。
    _emit_placement() {   # <daemon 名> → 统一的"容忍 master taint + 只调度到存储节点"
        echo "    $1:"
        echo "      tolerations:"
        echo "        - key: node-role.kubernetes.io/control-plane"
        echo "          operator: Exists"
        echo "          effect: NoSchedule"
        echo "      nodeAffinity:"
        echo "        requiredDuringSchedulingIgnoredDuringExecution:"
        echo "          nodeSelectorTerms:"
        echo "            - matchExpressions:"
        echo "                - key: ${LABEL_KEY}"
        echo "                  operator: In"
        echo "                  values:"
        echo "                    - ${CEPH_NODE_LABEL#*=}"
    }
    _emit_placement mon
    _emit_placement osd
    _emit_placement mgr
    unset -f _emit_placement
    echo "  storage:"
    echo "    useAllNodes: false"
    echo "    nodes:"
    for _hn in "${CEPH_NODE_HOSTS[@]}"; do
        _ds="${NODE_DISKS[${_hn}]:-}"
        [ -n "${_ds}" ] || continue
        echo "      - name: ${_hn}"
        echo "        devices:"
        for _d in ${_ds//,/ }; do
            echo "          - name: ${_d}"
        done
    done
} > "${LOCAL_CR}"
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
    "${LOCAL_CR}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:/tmp/cephcluster.yaml" >/dev/null 2>&1
SSH "${K} apply -f /tmp/cephcluster.yaml" || { rm -f "${LOCAL_CR}"; err "应用 CephCluster CR 失败(检查 /tmp/cephcluster.yaml 与 rook operator 日志)"; exit 1; }
rm -f "${LOCAL_CR}"

    # toolbox(ceph CLI; 供 [7/8] 就绪检查与调优使用)
    say "  部署 toolbox(ceph CLI)..."
    # ★ toolbox.yaml 官方 manifest 写的是浮动 tag ceph:v20, 而离线 tar 保存的是精确版本
    #   v20.2.2(节点 containerd 无 v20 这个 tag) → ImagePullBackOff。apply 前统一改写为 CEPH_VERSION。
    SSH "sed -i 's|quay.io/ceph/ceph:[a-zA-Z0-9._-]*|quay.io/ceph/ceph:${CEPH_VERSION}|g' ${REMOTE_DIR}/toolbox.yaml" \
        && SSH "${K} apply -f ${REMOTE_DIR}/toolbox.yaml >/dev/null 2>&1" || true
    # ★ 2026-09-24: toolbox 也钉到存储节点(与 mon/osd/mgr 同一个道理)。
    #   toolbox.yaml 是上游 manifest(无亲和性), 不钉的话它会落在 worker 上(实机落在 3-35),
    #   于是"ceph 只装在 master"这个约定看起来没生效 —— 用户实际提过这个问题。
    #   它不写本地数据、不影响数据面, 所以失败只 warn 不阻断。
    #   ⚠ 实测: Rook reconcile 不会回滚这里 patch 的 nodeSelector(改 CR 注解触发 reconcile 后仍在),
    #     故直接 patch deployment 即可, 不必往 toolbox.yaml 里塞(nodeSelector 里放 label)。
    _TB_PATCH="{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"${LABEL_KEY}\":\"${CEPH_NODE_LABEL#*=}\"},\"tolerations\":[{\"key\":\"node-role.kubernetes.io/control-plane\",\"operator\":\"Exists\",\"effect\":\"NoSchedule\"}]}}}}"
    SSH "${K} -n ${CEPH_NAMESPACE} patch deploy rook-ceph-tools --type=merge -p '${_TB_PATCH}' >/dev/null 2>&1" \
        && ok "  toolbox 已钉到存储节点(${CEPH_NODE_LABEL})" \
        || warn "  toolbox 钉节点失败(不影响部署; 它只是 CLI pod, 可能落到非存储节点)"
    unset _TB_PATCH
    # ★ 2026-09-24 事故修复: toolbox 必须重启 + 确认 ceph CLI 真的可用, 再进 [7/8]。
    #   幂等卸载旧集群时 Rook 会**删除并重建** rook-ceph-mon Secret, 而**已挂载**到旧 toolbox
    #   Pod 的 keyring 不会随 kubelet 刷新(实机: 同一 Pod 里 ceph.conf 更新到 04:55, keyring
    #   仍停在 04:17=旧集群) → 之后每次 `exec deploy/rook-ceph-tools -- ceph ...` 都报
    #   "[errno 13] RADOS permission denied"(stderr, 被下面的 2>/dev/null 吞掉, stdout 为空),
    #   后果三连: ① 预调优(clock skew / osd_memory_target)静默失效; ② [7/8] 永远等不到
    #   HEALTH_OK(白等 900s 后误报"Ready 但未 HEALTH_OK", 明明集群是好的); ③ 旧版还会因
    #   空输出把 grep 管道打成非 0 → set -e 当场中断部署(就是本轮中断的直接原因)。
    #   重启让 Pod 重新挂载新 keyring, 并在此显式确认 ceph -s 可执行 —— 后面 [7/8] 的
    #   "phase=Ready 即 toolbox 可用" 假设才成立。
    say "  重启 toolbox 并确认 ceph CLI 可用(旧集群 keyring 不会自动刷新)..."
    SSH "${K} -n ${CEPH_NAMESPACE} rollout restart deploy/rook-ceph-tools >/dev/null 2>&1" || true
    _TB_OK=0
    for _ti in $(seq 1 24); do
        if SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph -s >/dev/null 2>&1"; then
            _TB_OK=1; break
        fi
        sleep 5
    done
    [ "${_TB_OK}" = "1" ] && ok "  toolbox ceph CLI 可用" \
        || warn "  toolbox 120s 内 ceph -s 仍不可用(集群仍会继续等待; 状态行可能显示 health=unknown) —— 可手工: kubectl -n ${CEPH_NAMESPACE} rollout restart deploy/rook-ceph-tools"
    unset _TB_OK _ti

    # 等待 CephCluster Ready + HEALTH_OK(最长 900s; 备份恢复认领旧 OSD 数据比新建更慢)
    # 每 10s 轮询; Ready 后经 toolbox 执行 ceph -s 提取关键行(health/mon/osd/pgs),
    # 每 30s 打印一行状态到终端(= 完整部署日志 /tmp/cubestack-cluster-install.log), 便于观察收敛进度。
    say "[7/8] 等待 Ceph 集群就绪(最长 900s, ceph -s HEALTH_OK)..."
    CLUSTER_OK=0
    _CEPH_TUNED=0   # 阈值预调优标记(第一次 phase=Ready 时设, 避免 clock skew 卡等待)
    for i in $(seq 1 90); do
        _ph="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
        if [ "${_ph}" = "Ready" ]; then
            # ★ 2026-09-06 修复: 阈值在等待**开始前**就设置, 否则等待期间用默认 0.05s,
            #   mon 初始偏差 0.5~1.2s → 恒 HEALTH_WARN clock skew → 白等 900s 或超时。
            #   phase=Ready 即 mon 已起, 立即放宽阈值, 之后轮询才可能到 HEALTH_OK。
            #   (toolbox 是否可用由 [6/8] 的重启+闸门保证 —— 2026-09-24 起不再假设"Ready 就等于
            #    ceph CLI 能跑通", 旧 keyring 场景下这个假设是错的。)
            if [ "${_CEPH_TUNED:-0}" = "0" ]; then
                say "  预调优: mon clock skew 阈值 → 1.5s(在等待前设置, 避免 clock skew 卡 900s)..."
                SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- \
                    ceph config set mon mon_clock_drift_allowed 1.5 >/dev/null 2>&1" || true
                SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- \
                    ceph config set osd osd_memory_target $((CEPH_OSD_MEMORY_TARGET * 1024 * 1024 * 1024)) >/dev/null 2>&1" || true
                _CEPH_TUNED=1
            fi
            _CEPH_SUM="$( (SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph -s 2>/dev/null" || true) )"
            # ★★ 2026-09-24 事故修复(部署中断的直接原因): 下面每个 grep 都必须带 `|| true`。
            #   本脚本是 `set -euo pipefail`: grep 无匹配 → 管道整体非 0 → `_hl="$(...)"` 这个
            #   **赋值语句**也返回非 0 → set -e 当场终止模块(退出码 1), 日志上就是
            #   "[7/8] 等待… → 预调优… → 【错误】模块 [ceph] 执行失败", 中间什么都没有。
            #   而"ceph -s 取不到输出"是会真实发生的: 实机复现——phase 刚翻 Ready 的那一瞬
            #   toolbox 的 exec 还没通, ceph -s 返回空输出(错误在 stderr, 被 2>/dev/null 吞掉),
            #   于是一次瞬时抖动变成了整轮部署失败。语义上它只该表示"还没就绪, 继续等下一轮"。
            _hl="$(printf '%s\n' "${_CEPH_SUM}" | grep -oE 'HEALTH_(OK|WARN|ERR)' | head -1 || true)"
            if [ "${_hl}" = "HEALTH_OK" ]; then
                ok "  Ceph 集群 HEALTH_OK"
                CLUSTER_OK=1
                break
            fi
            if [ "${i}" -eq 1 ] || [ $((i % 3)) -eq 0 ]; then
                # 同上: 每个 grep 都带 `|| true`(set -e + pipefail 下无匹配会致命; 这几行只在
                # 取到 ceph -s 输出时才走到, 但输出可能是残缺的, 不能假设字段一定在)
                _mon="$(printf '%s\n' "${_CEPH_SUM}" | grep -E '^\s+mon:' | sed 's/^\s*//' || true)"
                _osd="$(printf '%s\n' "${_CEPH_SUM}" | grep -E '^\s+osd:' | sed 's/^\s*//' || true)"
                _pgs="$(printf '%s\n' "${_CEPH_SUM}" | grep -E '^\s+pgs:' | sed 's/^\s*//' || true)"
                say "  [${i}/90] phase=${_ph} health=${_hl:-unknown}; ${_mon:-mon:?} ${_osd:-osd:?} ${_pgs:-pgs:?}(继续等待)"
            fi
        elif [ "${i}" -eq 1 ] || [ $((i % 6)) -eq 0 ]; then
            say "  [${i}/90] phase=${_ph:-未知}(尚未 Ready, 继续等待)..."
        fi
        sleep 10
    done
    if [ "${CLUSTER_OK}" = "1" ]; then
        ok "  Ceph 集群 HEALTH_OK"
    else
        # 区分失败性质: Ready 但 HEALTH_WARN(如个别 OSD down)→ 可用, 警告继续;
        # 未 Ready(Progressing/Error)→ 硬失败 —— 否则 ceph_csi 模块必然报"未 Ready"且信息不如这里明确
        _ph_now="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
        if [ "${_ph_now}" = "Ready" ]; then
            warn "  Ceph 集群 Ready 但未 HEALTH_OK(ceph -s 见健康告警, 多数场景可继续)"
        else
            err "  Ceph 集群 900s 内未 Ready(phase=${_ph_now:-未知}); 查看: kubectl -n ${CEPH_NAMESPACE} get cephcluster,pods / ceph -s; 常见: 磁盘未清理/内存不足/镜像未同步"
            exit 1
        fi
        unset _ph_now
    fi

    # ★ 备份/恢复已拆出为独立模块(2026-09-07): 部署不再自动备份, 降低部署复杂度。
    #   需要备份时单独执行: --steps ceph_backup(CEPH_BACKUP_ACTION=save), 见 15_ceph_backup.sh。

    # ★ 残留 rbd 映射清理(2026-09-07): 集群重建/删 ns 后, 旧集群的 CSI RBD 卷映射残留在
    #   内核(/sys/bus/rbd/devices/*), 用旧 keyring 持续认证新集群 → 内核日志刷屏
    #   "libceph: auth protocol 'cephx' authorization to osd failed: -13"。此处自动清理
    #   (保留在用卷, 如 registry-pvc); 手动重跑: tools/k8s/ceph-rbd-cleanup.sh
    say "  清理残留 rbd 内核映射(旧集群遗留, 避免 -13 认证刷屏)..."
    bash "${SCRIPT_DIR}/tools/k8s/ceph-rbd-cleanup.sh" \
        || warn "  rbd 残留清理失败(可手工 tools/k8s/ceph-rbd-cleanup.sh; 或重启节点清除)"

    # 调优 osd_memory_target / mon clock skew 阈值 —— 已在 [7/8] 等待循环第一次 phase=Ready 时
    # 预调优(_CEPH_TUNED=1), 这里仅兜底(集群超时未 Ready 等极端场景才重复设置, 幂等无害)。
    if [ "${_CEPH_TUNED:-0}" = "0" ]; then
        say "  设置 OSD osd_memory_target=${CEPH_OSD_MEMORY_TARGET}GiB(经 toolbox)..."
        SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph config set osd osd_memory_target $((CEPH_OSD_MEMORY_TARGET * 1024 * 1024 * 1024)) >/dev/null 2>&1" || true
        # 放宽 mon 时钟偏差告警阈值(默认 0.05s 太严: NTP 同步后节点偏差仍可能 0.2~0.5s → 恒 HEALTH_WARN;
        # 2026-09-05 实测: 新 VM 时钟初始偏差可达 0.5~1.2s, chrony 收敛前会超 0.5s 阈值 → 恒 WARN。
        # 设 1.5s 消除误报(≤1.5s 对 Ceph 安全: mon 心跳/租约毫秒级, 1.5s 不影响 quorum);
        # 真实偏差由 chrony 持续收敛(见 setup-ntp.sh makestep 1 1 秒级对齐)。)
        say "  设置 mon clock skew 阈值=1.5s(默认 0.05s 过严, VM 初始偏差 0.5~1.2s 实测)..."
        SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph config set mon mon_clock_drift_allowed 1.5 >/dev/null 2>&1" || true
    fi
    # ★ 清残留 clock skew 告警(2026-09-05 事故): 时间已同步但 ceph 仍报 MON_CLOCK_SKEW ——
    #   chrony 收敛前记录的 skew 被 mon 缓存, timecheck 不会自动重采样刷新(恒定值如 1.233s)。
    #   消除方法: ① 全节点 chronyc makestep 硬对齐 ② 重启 mon deployments 触发 timecheck 重检。
    #   此前脚本只放宽阈值, 但偏差超过新阈值时仍 WARN; 现追加主动 makestep + 重启 mon, 让 HEALTH_OK 可达。
    say "  清 mon clock skew 残留告警(chronyc makestep + 重启 mon 触发 timecheck 重检)..."
    for _hn3 in "${CEPH_NODE_HOSTS[@]}"; do
        _ip3=""
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            node_parse "${line}"
            [ "${NODE_HOSTNAME}" = "${_hn3}" ] && { _ip3="${NODE_IP}"; break; }
        done
        [ -n "${_ip3}" ] || continue
        node_ssh "${_ip3}" "${SSH_USER:-ubuntu}" "sudo chronyc makestep >/dev/null 2>&1 || true; sudo chronyc -a makestep >/dev/null 2>&1 || true" || true
    done
    # 重启 mon deployments 触发 timecheck 重新采样(Rook 会重建, quorum 短暂重建, 不影响存储)
    SSH "${K} -n ${CEPH_NAMESPACE} rollout restart deploy/rook-ceph-mon-a deploy/rook-ceph-mon-b deploy/rook-ceph-mon-c >/dev/null 2>&1" || true
    SSH "${K} -n ${CEPH_NAMESPACE} rollout status deploy/rook-ceph-mon-a --timeout=120s >/dev/null 2>&1" || true
    # 重启后等 timecheck 重检(最多 60s)
    _SKEW_CLEAR=0
    for _i2 in $(seq 1 6); do
        _hl2="$( (SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph -s 2>/dev/null" || true) | grep -oE 'HEALTH_(OK|WARN)' | head -1 || true)"
        [ "${_hl2}" = "HEALTH_OK" ] && { _SKEW_CLEAR=1; break; }
        sleep 10
    done
    if [ "${_SKEW_CLEAR}" = "1" ]; then
        ok "  Ceph 集群 HEALTH_OK(clock skew 已清除)"
    else
        warn "  clock skew 未完全清除(可手工: 全节点 chronyc makestep 后 kubectl -n rook-ceph rollout restart deploy/rook-ceph-mon-a)"
    fi
fi   # _CEPH_SKIP_CLUSTER=1 → 跳过集群内 CephCluster 创建

# ---------------- 8) 汇总 ----------------
echo "---------------------------------------------"
ok "Ceph 存储集群部署完成(Rook ${ROOK_VERSION:-v1.20.2} / Ceph ${CEPH_VERSION})"
echo "  命名空间:    ${CEPH_NAMESPACE}"
if [ "${CEPH_MODE:-internal}" = "external" ]; then
    echo "  模式:        CEPH_MODE=external(外部 Ceph, 无集群内 CephCluster)"
    echo "  外部连接:    monitors=${CEPH_MONITORS:-<未配置>}  pool=${CEPH_POOL:-rbd}  user=${CEPH_USER:-admin}"
    echo "  资源查看:    kubectl -n ${CEPH_NAMESPACE} get deploy,cephconnection,csi.ceph.io"
    echo "  下一步:      CEPH_CSI_ENABLED=true 部署模块 ceph_csi(创建 StorageClass ceph-block 指向外部 Ceph)"
else
    echo "  存储节点 label: ${CEPH_NODE_LABEL}"
    echo "  存储节点与裸盘:"
    for _hn in "${CEPH_NODE_HOSTS[@]}"; do echo "    ${_hn}: ${NODE_DISKS[${_hn}]:-<无>}"; done
    echo "  资源查看:    kubectl -n ${CEPH_NAMESPACE} get cephcluster,pods;  exec deploy/rook-ceph-tools -- ceph -s"
fi
echo "  下一步:      CEPH_CSI_ENABLED=true 部署模块 ceph_csi(创建 rbd-pool + StorageClass ceph-block)"
echo "  registry 后端: REGISTRY_STORAGE_CLASS=ceph-block 时 registry PVC 走 ceph RBD(替代 local-path)"
echo "  使用文档:    docs/ceph-rook.md"
echo "  卸载:        先删 CephCluster(cleanupPolicy yes-really-destroy-data), 见 docs/ceph-rook.md §卸载"
