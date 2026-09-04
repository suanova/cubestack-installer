#!/bin/bash
# ============================================================
# MODULE: ceph
# DESC: 部署 Rook-Ceph 存储集群(CephCluster; 自动检测裸盘 + node label 选节点 + 离线镜像/包 + 安全确认)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: CEPH_ENABLED
# 说明:
#   · 断点续跑: REPEAT:0 → 安装成功写入状态; --fresh 清状态重装。
#   · 方式: Rook Operator(离线 manifest, deployments/cubestack-addon/rook, 需先联网跑
#     tools/k8s/rook-fetch-manifests.sh)+ CephCluster CR(本模块按"检测到的节点+裸盘"生成)+
#     CephBlockPool/StorageClass 在模块 ceph_csi(08)创建。
#   · 存储节点选择(需求 3): CEPH_NODES(cluster.conf, hostname 逗号分隔; 空=全部 NODES) →
#     模块给这些节点打 node label(CEPH_NODE_LABEL, 默认 ceph-storage=rook-ceph),
#     CephCluster 的 placement/storage.nodes 只包含这些节点。
#   · master 可调度(默认): kubespray 默认给 master 打 control-plane NoSchedule taint, Rook
#     mon/osd 调度到 master 会被卡住(3 台 mon 至少需 3 台可调度节点)。本模块在部署前默认去掉
#     master 的 control-plane taint(CEPH_ENABLE_MASTER_SCHEDULE=true, 幂等), 并给 CephCluster
#     placement 加 control-plane tolerations 双保险; 恢复 taint: kubectl taint nodes <master> node-role.kubernetes.io/control-plane=:NoSchedule。
#   · 裸盘自动检测(需求 1): tools/k8s/ceph-detect-disks.sh 逐节点检测"未使用裸盘"
#     (整盘无分区/格式化/挂载/LVM, 且非系统盘), 生成 CephCluster CR 的 per-node devices ——
#     精确盘名而非正则, 避免误选。VM 集群请确保 VM 附加数据盘(默认 3×200GB, VM_DATA_DISKS)。
#   · 安全确认(需求 2): 应用 CR 前红底醒目列出"将使用的节点 + 各节点裸盘",
#     **sleep CEPH_CONFIRM_SLEEP(默认 60)s** 供人工 double-check(节点/盘名正确、避免覆盖系统盘);
#     核对无误自动继续。CI 可 CEPH_CONFIRM_SLEEP=0 跳过。
#   · 节点准备: 每台存储节点加载并持久化 rbd 内核模块; 确保 lvm2
#     (离线 .deb 由 tools/offline/fetch-lvm-packages.sh 放到 offline-files/kubespray/packages,
#     本模块部署前预检"离线包就绪 或 节点已在线装 lvm", 缺失硬失败; 部署时自动从该目录安装)。
#   · 离线镜像(需求 5): tools/images/ceph-save-images.sh(联网机下载到 offline-files/kubespray/images,
#     与 kubespray 镜像同目录) → k8s 阶段由 cluster.yml 内置预加载 play 统一同步到节点并 ctr import。
#   · registry 后端(需求 6): REGISTRY_STORAGE_CLASS=ceph-block(见 docs/ceph-rook.md)时,
#     registry 的 PVC 改走 ceph RBD(替代 local-path); 模块设计顺序在 registry 配置之前。
#   · 参考: docs/ceph-rook.md(Rook v1.20.2 / Ceph v20.2.2 生产设计: 3 副本 host 故障域 + 3 mon)
# 数据源: cluster.conf (CEPH_ENABLED / CEPH_NODES / CEPH_NODE_LABEL / CEPH_* / CEPH_IMAGE_DIR /
#                       CEPH_ROOK_MANIFEST_DIR / REGISTRY_STORAGE_CLASS / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --enable ceph  或  CEPH_ENABLED=true
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关 ----
[ "${CEPH_ENABLED:-false}" = "true" ] || { say "CEPH_ENABLED=false, 跳过 Ceph"; exit 0; }

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ---------------- 派生变量(全部来自 cluster.conf) ----------------
CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
CEPH_VERSION="${CEPH_VERSION:-v20.2.2}"
CEPH_MON_COUNT="${CEPH_MON_COUNT:-3}"
CEPH_POOL_REPLICAS="${CEPH_POOL_REPLICAS:-3}"
CEPH_POOL_MIN_SIZE="${CEPH_POOL_MIN_SIZE:-2}"
CEPH_OSD_MEMORY_TARGET="${CEPH_OSD_MEMORY_TARGET:-4}"
CEPH_NODE_LABEL="${CEPH_NODE_LABEL:-ceph-storage=rook-ceph}"
LABEL_KEY="${CEPH_NODE_LABEL%%=*}"
CEPH_IMAGE_DIR="${CEPH_IMAGE_DIR:-${OFFLINE_FILES_DIR}/images}"
CEPH_ROOK_MANIFEST_DIR="${CEPH_ROOK_MANIFEST_DIR:-${REPO_ROOT}/deployments/cubestack-addon/rook}"
CEPH_CONFIRM_SLEEP="${CEPH_CONFIRM_SLEEP:-60}"
CEPH_PRE_CLEANUP_EXISTING="${CEPH_PRE_CLEANUP_EXISTING:-true}"   # 覆盖重装: 部署前完整清空上次 ceph 所用磁盘(OSD 盘数据销毁)
CEPH_RESTORE_BACKUP="${CEPH_RESTORE_BACKUP:-false}"              # 覆盖重装: 认领旧 OSD 数据(注入旧 fsid; 与 PRE_CLEANUP 互斥)
_CEPH_PRE_CLEANUP=0
[ "${CEPH_PRE_CLEANUP_EXISTING}" = "true" ] && _CEPH_PRE_CLEANUP=1
TOOLS_K8S="${SCRIPT_DIR}/tools/k8s"

# 1) 候选 ceph 节点(hostname 列表)
CEPH_NODES="${CEPH_NODES:-}"
CEPH_NODE_HOSTS=()
if [ -n "${CEPH_NODES}" ]; then
    for _h in ${CEPH_NODES//,/ }; do CEPH_NODE_HOSTS+=("${_h}"); done
else
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        CEPH_NODE_HOSTS+=("${NODE_HOSTNAME}")
    done
fi
[ "${#CEPH_NODE_HOSTS[@]}" -ge 1 ] || { err "未找到候选存储节点(检查 NODES / CEPH_NODES)"; exit 1; }

# ★ 节点<3 不建集群内 CephCluster(mon 需 3 节点法定人数, allowMultiplePerNode=false):
#   置 _CEPH_SKIP_CLUSTER=1 → 跳过 CephCluster CR 创建/等待(下方 [6/8]/[7/8] 分支);
#   csi-operator 仍按需安装(可连外部 Ceph: cluster.conf 设 CEPH_EXTERNAL_MONITORS)。
CEPH_MIN_NODES="${CEPH_MIN_NODES:-3}"
_CEPH_SKIP_CLUSTER=0
if [ "${#CEPH_NODE_HOSTS[@]}" -lt "${CEPH_MIN_NODES}" ]; then
    warn "存储节点仅 ${#CEPH_NODE_HOSTS[@]} 台(<${CEPH_MIN_NODES}), 不创建集群内 CephCluster(mon 法定人数不足)"
    warn "  可选: ① 增加存储节点至 ≥${CEPH_MIN_NODES}; ② 或设 CEPH_EXTERNAL_MONITORS 连接外部 Ceph(见 docs/ceph-rook.md)"
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
        NSSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${_ip}" "$@"; }
        NSSH "command -v lvm >/dev/null 2>&1 && lvm version >/dev/null 2>&1" >/dev/null 2>&1 || _ALL_HAS_LVM=0
    done
    if [ "${_ALL_HAS_LVM}" = "0" ]; then
        err "lvm2 离线包未就绪且存储节点未安装 lvm —— 无法离线部署 Rook OSD(重启后逻辑卷需 lvm 激活)"
        err "  请先在**联网机**执行: sudo ./deployments/scripts/tools/offline/fetch-lvm-packages.sh"
        err "  生成 lvm2_*.deb → ${REPO_ROOT}/deployments/offline-files/kubespray/packages/, 再重跑本模块"
        exit 1
    fi
    warn "  lvm2 离线包未就绪, 但存储节点已在线安装 lvm, 继续(重启后逻辑卷激活依赖已满足)"
fi

# ---------------- 2) 裸盘选择(显式指定 或 自动检测) ----------------
# 需求: 裸盘可在 cluster.conf 显式指定(CEPH_DATA_DISKS); 未指定则自动检测。
#   explicit 格式: "hostname:盘名1,盘名2;hostname2:盘名3" —— hostname 可省略(无 ':' → 应用到全部存储节点,
#   不同环境盘名不同, 如 VM 为 /dev/vdb,/dev/vdc,/dev/vdd、裸金属为 /dev/sdb,/dev/sdc 时, 全节点同规格写法最省);
#   盘名可带或不带 /dev/ 前缀(自动补全)。
declare -A NODE_DISKS
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
    # auto 策略: 逐存储节点自动检测"未使用裸盘"(排除系统盘)
    say "[1/8] 检测存储节点的未使用裸盘(tools/k8s/ceph-detect-disks.sh)..."
    DETECT_ARGS=()
    for _hn in "${CEPH_NODE_HOSTS[@]}"; do DETECT_ARGS+=(--node "${_hn}"); done
    # 保留 stderr(不 2>/dev/null): detect 对"节点 SSH 失败/无裸盘"的 warn 必须可见, 否则人工无法判断检测是否可信
    DETECT_OUT="$(bash "${TOOLS_K8S}/ceph-detect-disks.sh" "${DETECT_ARGS[@]}" -m)" || true
    if [ -z "${DETECT_OUT}" ]; then
        warn "  自动检测未返回结果; 若 VM 集群请确认 VM_DATA_DISKS>0 且已重建/附加数据盘; 可显式设 CEPH_DATA_DISKS 指定盘"
    fi
    while IFS= read -r _l; do
        [ -z "${_l}" ] && continue
        _hn="${_l%%:*}"; _ds="${_l#*:}"
        NODE_DISKS["${_hn}"]="${_ds%,}"
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
echo -e "\033[41m\033[97m   Rook ${ROOK_VERSION:-v1.20.2} / Ceph ${CEPH_VERSION} / mon=${CEPH_MON_COUNT}\033[0m"
echo -e "\033[41m\033[97m   副本 size=${CEPH_POOL_REPLICAS} min_size=${CEPH_POOL_MIN_SIZE}(host 故障域)\033[0m"
echo -e "\033[41m\033[97m   存储节点 label: ${CEPH_NODE_LABEL}   命名空间: ${CEPH_NAMESPACE}\033[0m"
for _hn in "${CEPH_NODE_HOSTS[@]}"; do
    echo -e "\033[41m\033[97m   · ${_hn}  →  裸盘: ${NODE_DISKS[${_hn}]:-<无!>}\033[0m"
done
echo -e "\033[41m\033[97m ⚠ 确认要点: ① 盘名与节点一一对应正确(不会覆盖系统盘/在用盘)        \033[0m"
echo -e "\033[41m\033[97m   ② 每台存储节点裸盘存在且确实空闲; ③ CEPH_NODES 是你想部署的节点  \033[0m"
echo -e "\033[41m\033[97m   核对无误将自动继续; 有误请 Ctrl-C 中止修正后重跑                 \033[0m"
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
        if SSH "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get node ${_mhn} -o jsonpath='{.spec.taints}' 2>/dev/null | grep -q 'control-plane'" 2>/dev/null; then
            SSH "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes ${_mhn} node-role.kubernetes.io/control-plane- 2>/dev/null" \
                && ok "  ${_mhn}(${_mip}) 已去掉 control-plane taint(master 可调度)" \
                || warn "  ${_mhn}(${_mip}) 去 taint 失败(手动: kubectl taint nodes ${_mhn} node-role.kubernetes.io/control-plane-)"
        else
            ok "  ${_mhn}(${_mip}) 无 control-plane taint(已可调度)"
        fi
    done
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
    NSSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${_user}@${_ip}" "$@"; }
    say "  ── [${_hn}](${_ip}) ──"
    # 4a. rbd 内核模块(立即加载 + 持久化)
    NSSH "sudo modprobe rbd 2>/dev/null; grep -q '^rbd' /etc/modules-load.d/rbd.conf 2>/dev/null || echo 'rbd' | sudo tee /etc/modules-load.d/rbd.conf >/dev/null" \
        && ok "    rbd 内核模块就绪" || warn "    rbd 模块加载失败(VM 内核需支持, 检查 modprobe rbd)"
    # 4b. lvm2: 检测缺失 → 从离线 packages 安装(install-worker-packages.sh 含 offline-files/kubespray/packages)
    if ! NSSH "command -v lvm >/dev/null 2>&1 && lvm version >/dev/null 2>&1" >/dev/null 2>&1; then
        say "    lvm2 缺失, 从离线 .deb 安装(packages 目录, 由 fetch-lvm-packages.sh 生成)..."
        if [ -d "${REPO_ROOT}/deployments/offline-files/kubespray/packages" ] && \
            bash "${SCRIPT_DIR}/tools/node/install-worker-packages.sh" "${_ip}" "${_user}" >/dev/null 2>&1; then
            NSSH "command -v lvm >/dev/null 2>&1" >/dev/null 2>&1 \
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
        _has="$(SSH "sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -E 'rook/ceph:|ceph/ceph:|cephcsi' | wc -l" 2>/dev/null | tr -d ' ')"
        if [ "${_has:-0}" -lt 3 ]; then
            _MISSING+=("${_hn}")
        else
            ok "  ${_hn} ceph 镜像已就绪(rook/ceph/cephcsi 均已在 containerd)"
        fi
    done
    if [ "${#_MISSING[@]}" -gt 0 ]; then
        warn "  以下节点未检测到 ceph 镜像: ${_MISSING[*]} —— 可能预加载未覆盖(k8s 阶段 CEPH_ENABLED 需 true); 手工补救:"
        warn "    bash ${SCRIPT_DIR}/tools/images/ceph-sync-images.sh --node ${_MISSING[0]}"
        warn "    或在 cluster.conf 设 CEPH_ENABLED=true 后 --fresh 重跑 k8s_deploy 阶段"
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
# ★ 幂等重装策略(此前多起事故根因在此重构):
#   ① 集群内已有 CephCluster → 幂等更新(不重建、不读备份);
#   ② 无 CephCluster + CEPH_RESTORE_BACKUP=true + 备份 CR 存在 → 仅提取备份 status.fsid 注入
#      spec.fsid(Rook 凭 fsid 认领旧 OSD 数据), storage/placement 仍按**当前**节点/裸盘生成;
#   ③ 其余 → 全新部署(新 fsid)。
#   绝不整份恢复旧 CR: 旧 CR 的 storage.nodes/devices/placement 来自上一代环境, apply 后
#   ① 盘名/节点过时(历史残留 /dev/rbd0 → OSD 永不创建) ② 残留 mon store(/var/lib/rook/mon-*,
#   集群无关路径)被新 mon 直接复用, monmap 还是旧集群的死 IP → quorum 永久卡死。
CEPH_CR_BACKUP="${CEPH_CR_BACKUP:-${REPO_ROOT}/deployments/offline-files/cephcluster-backup.yaml}"
CEPH_RESTORE_BACKUP="${CEPH_RESTORE_BACKUP:-false}"   # 兼容旧配置: true 强制认领(自动关闭清盘); 默认按 PRE_CLEANUP 自动决定
_CEPH_FSID=""
_HAS_CC_NOW="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --no-headers 2>/dev/null" || true) )"
if [ -n "${_HAS_CC_NOW}" ]; then
    say "  集群内已有 CephCluster($(echo "${_HAS_CC_NOW}" | awk '{print $1}')), 用当前 CR 幂等更新(不重建、不读备份)"
else
    # ★ 备份自动注入(部署时手动备份 → 新集群自动认领):
    #   · 清盘模式(CEPH_PRE_CLEANUP_EXISTING=true, 默认)→ 完整清空旧盘, 全新 fsid, 不认领;
    #   · 保留数据模式(PRE_CLEANUP=false)→ **自动**从备份读取 fsid 注入新 CR 的 spec.fsid,
    #     Rook 凭 fsid 认领旧 OSD 数据(无需手工指定; 部署机备份优先, 节点根盘备份兜底)。
    #   · CEPH_RESTORE_BACKUP=true(旧配置兼容)= 强制保留数据+自动注入(自动关闭清盘)。
    if [ "${CEPH_RESTORE_BACKUP}" = "true" ] && [ "${_CEPH_PRE_CLEANUP}" = "1" ]; then
        warn "CEPH_RESTORE_BACKUP=true 与 CEPH_PRE_CLEANUP_EXISTING=true 冲突 → 认领优先, 自动关闭清盘(绝不 wipe 旧数据盘)"
        _CEPH_PRE_CLEANUP=0
    fi
    if [ "${_CEPH_PRE_CLEANUP}" = "1" ]; then
        say "  清盘模式(默认): 完整清空旧盘 → 全新 fsid(不认领旧 OSD 数据)"
    else
        # 自动注入: 部署机备份 → 节点根盘备份兜底
        if [ -s "${CEPH_CR_BACKUP}" ]; then
            _CEPH_FSID="$(awk '/^status:/{f=1} f&&/fsid:/{print $2; exit}' "${CEPH_CR_BACKUP}")"
        fi
        if [ -z "${_CEPH_FSID}" ]; then
            say "  部署机无备份, 尝试从节点备份目录读取(ceph-backup.sh fetch-fsid)..."
            _CEPH_FSID="$( (LOG_VERBOSE=0 bash "${SCRIPT_DIR}/tools/k8s/ceph-backup.sh" fetch-fsid 2>/dev/null || true) | tail -1 )"
        fi
        if [ -n "${_CEPH_FSID}" ]; then
            say "  保留数据模式 → 自动注入 spec.fsid=${_CEPH_FSID}(认领旧 OSD 数据)"
            say "  storage/placement 仍按当前节点/裸盘生成(不整份恢复旧 CR, 见上方注释)"
        else
            say "  保留数据模式但未找到备份 fsid → 全新部署(新 fsid)"
        fi
    fi
fi

# ★ 节点<3 → 跳过集群内 CephCluster 创建(mon 法定人数不足; csi-operator 仍按需安装, 可连外部 Ceph)
if [ "${_CEPH_SKIP_CLUSTER}" = "1" ]; then
    say "  存储节点 <${CEPH_MIN_NODES}, 跳过生成 CephCluster CR(未创建集群内 CephCluster)"
    say "  可选: 设 CEPH_EXTERNAL_MONITORS 由 ceph_csi 模块连接外部 Ceph 并创建 StorageClass"
else
    # ★ 全新部署(无现存 CephCluster)先清理各存储节点残留: 磁盘数据 + mon store + 遗留 rbd 设备。
    if [ -z "${_HAS_CC_NOW}" ]; then
        # --- 7a) CEPH_PRE_CLEANUP_EXISTING=true → 完整清空上次部署 ceph 所用的所有磁盘 ---
        # 只按"当前检测到的裸盘"清(不依赖旧 CR 的 storage 列表 —— 旧 CR 过时时其列表无效,
        # 曾导致 15 块盘未被 wipe, 新集群 OSD 因 "belonging to a different ceph cluster" 全部被跳过)。
        # 清盘必须覆盖 bluestore 全部签名位置:
        #   头 64MB(block 签名) + 1GB(签名块) + size/20 与 size/2(bluestore label 双副本,
        #   ceph-bluestore-tool show-label 的 locations) + 尾 64MB(superblock)。
        # 只清头尾会漏掉 locations → ceph-volume 仍报 "already prepared" → 0 OSD(此前事故根因)。
        if [ "${_CEPH_PRE_CLEANUP}" = "1" ]; then
            for _hn in "${CEPH_NODE_HOSTS[@]}"; do
                _ip=""
                for line in "${NODES[@]:-}"; do
                    [ -z "${line}" ] && continue
                    node_parse "${line}"
                    [ "${NODE_HOSTNAME}" = "${_hn}" ] && { _ip="${NODE_IP}"; break; }
                done
                [ -n "${_ip}" ] || continue
                NSSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${_ip}" "$@"; }
                for _d in ${NODE_DISKS[${_hn}]//,/ }; do
                    say "  wipe ${_hn} ${_d}(完整清盘: 头/1GB/locations/尾)..."
                    NSSH "sudo dd if=/dev/zero of=${_d} bs=1M count=64 conv=fsync status=none && \
                          sudo dd if=/dev/zero of=${_d} bs=1M seek=1024 count=64 conv=fsync status=none && \
                          _SZ=\$(sudo lsblk -b -o SIZE ${_d} 2>/dev/null | tail -1) && _SM=\$((_SZ/1048576)) && \
                          sudo dd if=/dev/zero of=${_d} bs=1M seek=\$((_SM/20)) count=64 conv=fsync status=none && \
                          sudo dd if=/dev/zero of=${_d} bs=1M seek=\$((_SM/2)) count=64 conv=fsync status=none && \
                          sudo dd if=/dev/zero of=${_d} bs=1M seek=\$((_SM-64)) count=64 conv=fsync status=none" \
                        && ok "    ${_hn} ${_d} 已完整清空" \
                        || warn "    ${_hn} ${_d} wipe 失败(请手工: dd if=/dev/zero of=${_d} bs=1M seek=\$((\$(sudo lsblk -b -o SIZE ${_d}|tail -1)/1048576/20)) count=64)"
                done
                # 遗留 rbd 设备: 曾导致 osd-prepare 的 show-label 扫到挂起 IO(AIO 读 D 状态) → prepare 永久卡死
                NSSH "ls /dev/rbd* >/dev/null 2>&1 && { sudo rm -f /dev/rbd* && echo '  残留 rbd 设备节点已删(/dev/rbd*)'; } || true" \
                    | grep -v '^$' || true
            done
            unset NSSH
        fi

        # --- 7b) 清理 /var/lib/rook 残留(mon store + osd 元数据 + config/keyring) ---
        # mon 数据在集群无关路径 <dataDirHostPath>/mon-*(如 /var/lib/rook/mon-a), 上一代集群删除后
        # 仍残留; 新 mon 复用后从旧 store 恢复旧 monmap(死 IP)→ quorum 永久卡死(此前事故根因)。
        # PRE_CLEANUP=true(清盘)时连 osd 元数据/配置一起清(盘已 wipe, 元数据无保留价值);
        # 仅认领模式(CEPH_RESTORE_BACKUP=true)只清 mon-*, 保留 osd 元数据辅助认领。
        for _hn in "${CEPH_NODE_HOSTS[@]}"; do
            _ip=""
            for line in "${NODES[@]:-}"; do
                [ -z "${line}" ] && continue
                node_parse "${line}"
                [ "${NODE_HOSTNAME}" = "${_hn}" ] && { _ip="${NODE_IP}"; break; }
            done
            [ -n "${_ip}" ] || continue
            NSSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${_ip}" "$@"; }
            if [ "${_CEPH_PRE_CLEANUP}" = "1" ]; then
                say "  清理 ${_hn} /var/lib/rook 残留(mon-* + rook-ceph/osd 元数据 + config/keyring)..."
                NSSH "sudo rm -rf /var/lib/rook/mon-* /var/lib/rook/rook-ceph 2>/dev/null; true" \
                    && ok "    ${_hn} /var/lib/rook 已清空" || warn "    ${_hn} /var/lib/rook 清理失败"
            else
                say "  清理 ${_hn} 残留 mon store(/var/lib/rook/mon-*, 全新 mon 状态)..."
                NSSH "sudo rm -rf /var/lib/rook/mon-*" || warn "    ${_hn} mon store 清理失败(节点全新无残留可忽略)"
            fi
        done
    fi
    # 生成并应用 CephCluster CR(当前节点/裸盘; _CEPH_FSID 非空时注入 spec.fsid 认领旧 OSD 数据)。
    # 无论是否注入 fsid, 都必须走到下方 [7/8] 就绪等待 —— 此前 toolbox/[7/8] 等待/调优只写在部分
    # 分支里, 曾导致"apply 完 CR 直接宣布完成(集群仍在 Progressing), ceph_csi 一进来就报错打断部署"。
    say "[6/8] 生成并应用 CephCluster CR(mon=${CEPH_MON_COUNT}, 副本=${CEPH_POOL_REPLICAS}/${CEPH_POOL_MIN_SIZE})..."
    LOCAL_CR="$(mktemp)"
{
    echo "apiVersion: ceph.rook.io/v1"
    echo "kind: CephCluster"
    echo "metadata:"
    echo "  name: rook-ceph"
    echo "  namespace: ${CEPH_NAMESPACE}"
    echo "spec:"
    if [ -n "${_CEPH_FSID}" ]; then
        echo "  fsid: ${_CEPH_FSID}"
    fi
    echo "  cephVersion:"
    echo "    image: quay.io/ceph/ceph:${CEPH_VERSION}"
    echo "    allowUnsupported: false"
    echo "  dataDirHostPath: /var/lib/rook"
    echo "  mon:"
    echo "    count: ${CEPH_MON_COUNT}"
    echo "    allowMultiplePerNode: false"
    echo "  mgr:"
    echo "    count: 1"
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
    echo "  placement:"
    echo "    mon:"
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
    echo "    osd:"
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

    # 等待 CephCluster Ready + HEALTH_OK(最长 900s; 备份恢复认领旧 OSD 数据比新建更慢)
    # 每 10s 轮询; Ready 后经 toolbox 执行 ceph -s 提取关键行(health/mon/osd/pgs),
    # 每 30s 打印一行状态到终端(= 完整部署日志 /tmp/cubestack-cluster-install.log), 便于观察收敛进度。
    say "[7/8] 等待 Ceph 集群就绪(最长 900s, ceph -s HEALTH_OK)..."
    CLUSTER_OK=0
    for i in $(seq 1 90); do
        _ph="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
        if [ "${_ph}" = "Ready" ]; then
            _CEPH_SUM="$( (SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph -s 2>/dev/null" || true) )"
            _hl="$(printf '%s\n' "${_CEPH_SUM}" | grep -oE 'HEALTH_(OK|WARN|ERR)' | head -1 )"
            if [ "${_hl}" = "HEALTH_OK" ]; then
                ok "  Ceph 集群 HEALTH_OK"
                # ★ 部署成功 → 保存恢复备份到节点根盘(部署时手动备份, 防 wipe/防覆盖)。
                #   备份文件含 status.fsid: 下次保留数据模式(PRE_CLEANUP=false)重装时自动注入认领;
                #   即使集群崩溃(k8s 不可用), 根盘 /var/lib/ceph/backup/ 的历史备份仍可读。
                _CR_DUMP="$(mktemp)"
                ( SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o yaml" > "${_CR_DUMP}" 2>/dev/null || true )
                if [ -s "${_CR_DUMP}" ]; then
                    _META="$(mktemp)"
                    printf 'backup_time: %s\n' "$(date +%Y%m%d_%H%M%S)" > "${_META}"
                    printf 'nodes:\n' >> "${_META}"
                    for _hn2 in "${CEPH_NODE_HOSTS[@]}"; do
                        printf '  %s: %s\n' "${_hn2}" "${NODE_DISKS[${_hn2}]:-<无>}" >> "${_META}"
                    done
                    bash "${SCRIPT_DIR}/tools/k8s/ceph-backup.sh" save "${_CR_DUMP}" "${_META}" \
                        || warn "  Ceph 备份到节点失败(不影响部署; 可手工 tools/k8s/ceph-backup.sh save)"
                    rm -f "${_META}"
                else
                    warn "  拉取 CephCluster CR 失败, 跳过自动备份(可手工 tools/k8s/ceph-backup.sh save)"
                fi
                rm -f "${_CR_DUMP}"
                CLUSTER_OK=1
                break
            fi
            if [ "${i}" -eq 1 ] || [ $((i % 3)) -eq 0 ]; then
                _mon="$(printf '%s\n' "${_CEPH_SUM}" | grep -E '^\s+mon:' | sed 's/^\s*//')"
                _osd="$(printf '%s\n' "${_CEPH_SUM}" | grep -E '^\s+osd:' | sed 's/^\s*//')"
                _pgs="$(printf '%s\n' "${_CEPH_SUM}" | grep -E '^\s+pgs:' | sed 's/^\s*//')"
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

    # 调优 osd_memory_target(200G 盘 4G 已够; 大盘按文档)
    say "  设置 OSD osd_memory_target=${CEPH_OSD_MEMORY_TARGET}GiB(经 toolbox)..."
    SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph config set osd osd_memory_target $((CEPH_OSD_MEMORY_TARGET * 1024 * 1024 * 1024)) >/dev/null 2>&1" || true
    # 放宽 mon 时钟偏差告警阈值(默认 0.05s 太严: NTP 同步后节点偏差仍可能 0.2~0.5s → 恒 HEALTH_WARN;
    # 放宽到 0.5s 消除误报, 实际偏差已在 k8s NTP 模块收敛 ≤500ms)
    say "  设置 mon clock skew 阈值=0.5s(默认 0.05s 过严, NTP 同步后消除 HEALTH_WARN)..."
    SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph config set mon mon_clock_drift_allowed 0.5 >/dev/null 2>&1" || true
fi   # _CEPH_SKIP_CLUSTER=1 → 跳过集群内 CephCluster 创建

# ---------------- 8) 汇总 ----------------
echo "---------------------------------------------"
ok "Ceph 存储集群部署完成(Rook ${ROOK_VERSION:-v1.20.2} / Ceph ${CEPH_VERSION})"
echo "  命名空间:    ${CEPH_NAMESPACE}   存储节点 label: ${CEPH_NODE_LABEL}"
echo "  存储节点与裸盘:"
for _hn in "${CEPH_NODE_HOSTS[@]}"; do echo "    ${_hn}: ${NODE_DISKS[${_hn}]:-<无>}"; done
echo "  资源查看:    kubectl -n ${CEPH_NAMESPACE} get cephcluster,pods;  exec deploy/rook-ceph-tools -- ceph -s"
echo "  下一步:      CEPH_CSI_ENABLED=true 部署模块 ceph_csi(创建 rbd-pool + StorageClass ceph-block)"
echo "  registry 后端: REGISTRY_STORAGE_CLASS=ceph-block 时 registry PVC 走 ceph RBD(替代 local-path)"
echo "  使用文档:    docs/ceph-rook.md"
echo "  卸载:        先删 CephCluster(cleanupPolicy yes-really-destroy-data), 见 docs/ceph-rook.md §卸载"
