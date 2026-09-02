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
#   · 裸盘自动检测(需求 1): tools/k8s/ceph-detect-disks.sh 逐节点检测"未使用裸盘"
#     (整盘无分区/格式化/挂载/LVM, 且非系统盘), 生成 CephCluster CR 的 per-node devices ——
#     精确盘名而非正则, 避免误选。VM 集群请确保 VM 附加数据盘(默认 3×200GB, VM_DATA_DISKS)。
#   · 安全确认(需求 2): 应用 CR 前红底醒目列出"将使用的节点 + 各节点裸盘",
#     **sleep CEPH_CONFIRM_SLEEP(默认 60)s** 供人工 double-check(节点/盘名正确、避免覆盖系统盘);
#     核对无误自动继续。CI 可 CEPH_CONFIRM_SLEEP=0 跳过。
#   · 节点准备: 每台存储节点加载并持久化 rbd 内核模块; 确保 lvm2
#     (离线 .deb 由 tools/offline/fetch-lvm-packages.sh 放到 offline-files/kubespray/packages,
#     本模块自动检测缺失时从该目录安装)。
#   · 离线镜像(需求 5): tools/images/ceph-save-images.sh(联网机下载到 offline-files/ceph)
#     → 本模块调 ceph-sync-images.sh 同步到存储节点并 ctr import(保持原始镜像 ref)。
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
CEPH_IMAGE_DIR="${CEPH_IMAGE_DIR:-${REPO_ROOT}/deployments/offline-files/ceph}"
CEPH_ROOK_MANIFEST_DIR="${CEPH_ROOK_MANIFEST_DIR:-${REPO_ROOT}/deployments/cubestack-addon/rook}"
CEPH_CONFIRM_SLEEP="${CEPH_CONFIRM_SLEEP:-60}"
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

# 前置: rook manifest 必须就绪(联网机已 fetch); 缺失给指引
[ -f "${CEPH_ROOK_MANIFEST_DIR}/operator.yaml" ] && [ -f "${CEPH_ROOK_MANIFEST_DIR}/csi-operator.yaml" ] || {
    err "Rook manifest 缺失: ${CEPH_ROOK_MANIFEST_DIR}(缺 operator.yaml/csi-operator.yaml)。请先联网执行 tools/k8s/rook-fetch-manifests.sh(默认 Rook ${ROOK_VERSION:-v1.20.2})后拷到部署机"
    exit 1
}

# ---------------- 2) 裸盘自动检测(逐存储节点) ----------------
say "[1/8] 检测存储节点的未使用裸盘(tools/k8s/ceph-detect-disks.sh)..."
declare -A NODE_DISKS
DETECT_ARGS=()
for _hn in "${CEPH_NODE_HOSTS[@]}"; do DETECT_ARGS+=(--node "${_hn}"); done
DETECT_OUT="$(bash "${TOOLS_K8S}/ceph-detect-disks.sh" "${DETECT_ARGS[@]}" -m 2>/dev/null)" || true
if [ -z "${DETECT_OUT}" ]; then
    warn "  自动检测未返回结果; 若 VM 集群请确认 VM_DATA_DISKS>0 且已重建/附加数据盘; 可手工把盘加入 CEPH_DATA_DISKS"
fi
while IFS= read -r _l; do
    [ -z "${_l}" ] && continue
    _hn="${_l%%:*}"; _ds="${_l#*:}"
    NODE_DISKS["${_hn}"]="${_ds%,}"
done <<< "${DETECT_OUT}"
# explicit 策略覆盖(auto 未检出时手工指定 CEPH_DATA_DISKS="host:/dev/x,/dev/y;host:/dev/z")
if [ -n "${CEPH_DATA_DISKS:-}" ]; then
    while IFS=';' read -ra _grp; do
        for _g in "${_grp[@]}"; do
            _hn="${_g%%:*}"; _ds="${_g#*:}"
            [ -n "${_hn}" ] && [ -n "${_ds}" ] && NODE_DISKS["${_hn}"]="${_ds%,}"
        done
    done <<< "${CEPH_DATA_DISKS}"
fi
# 至少一个节点有盘才继续; 否则明确报错(避免生成无 OSD 集群)
_HAS_DISK=0
for _hn in "${CEPH_NODE_HOSTS[@]}"; do [ -n "${NODE_DISKS[${_hn}]:-}" ] && _HAS_DISK=1; done
[ "${_HAS_DISK}" = "1" ] || { err "所有存储节点均未检测到裸盘; 请先为节点附加数据盘(VM: VM_DATA_DISKS>0; 裸金属: 挂载新盘)或显式设 CEPH_DATA_DISKS"; exit 1; }

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
    sleep "${CEPH_CONFIRM_SLEEP}"
else
    say "CEPH_CONFIRM_SLEEP=0, 跳过等待(请务必已人工核对上方节点/裸盘)"
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
        say "    lvm2 缺失, 尝试离线 .deb 安装(packages 目录, 由 fetch-lvm-packages.sh 生成)..."
        if [ -d "${REPO_ROOT}/deployments/offline-files/kubespray/packages" ] && \
            bash "${SCRIPT_DIR}/tools/node/install-worker-packages.sh" "${_ip}" "${_user}" >/dev/null 2>&1; then
            NSSH "command -v lvm >/dev/null 2>&1" >/dev/null 2>&1 \
                && ok "    lvm2 已安装" || warn "    packages 无 lvm2 或安装失败(联网机先跑 tools/offline/fetch-lvm-packages.sh)"
        else
            warn "    lvm2 离线包不可用; 若已在线安装 lvm2 可忽略(重启后 Rook OSD 需 lvm 激活逻辑卷)"
        fi
    else
        ok "    lvm2 已就绪"
    fi
    # 4c. node label(选择部署节点)
    SSH "${K} label node ${_hn} ${CEPH_NODE_LABEL} --overwrite >/dev/null 2>&1" \
        && ok "    node label 已打: ${CEPH_NODE_LABEL}" \
        || warn "    label 失败(节点 ${_hn} 可能尚未就绪?)"
done

# ---------------- 5) 同步离线镜像到存储节点 ----------------
say "[4/8] 同步 ceph 离线镜像到存储节点(ctr import)..."
if [ -d "${CEPH_IMAGE_DIR}" ] && ls "${CEPH_IMAGE_DIR}"/*.tar >/dev/null 2>&1; then
    for _hn in "${CEPH_NODE_HOSTS[@]}"; do
        bash "${SCRIPT_DIR}/tools/images/ceph-sync-images.sh" --node "${_hn}" >/dev/null 2>&1 \
            && ok "  ${_hn} 镜像同步完成" || warn "  ${_hn} 镜像同步失败(检查 tools/images/ceph-save-images.sh 生成的 tar 与节点连通)"
    done
else
    warn "  ${CEPH_IMAGE_DIR} 无镜像 tar; 集群将尝试在线拉取(离线环境请先联网跑 tools/images/ceph-save-images.sh)"
fi

# ---------------- 6) 部署 Rook operator(crds → common → csi-operator → operator) ----------------
say "[5/8] 部署 Rook operator(manifest: ${CEPH_ROOK_MANIFEST_DIR})..."
REMOTE_DIR="/tmp/rook-manifests"
SSH "sudo rm -rf ${REMOTE_DIR} && sudo mkdir -p ${REMOTE_DIR}" >/dev/null 2>&1
for f in crds.yaml common.yaml csi-operator.yaml operator.yaml toolbox.yaml; do
    [ -f "${CEPH_ROOK_MANIFEST_DIR}/${f}" ] || { warn "  缺 manifest: ${f}(重跑 rook-fetch-manifests.sh)"; continue; }
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "${CEPH_ROOK_MANIFEST_DIR}/${f}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:${REMOTE_DIR}/${f}" >/dev/null 2>&1 || true
done
SSH "sudo chown -R \$(id -un) ${REMOTE_DIR}" >/dev/null 2>&1 || true
for f in crds.yaml common.yaml csi-operator.yaml operator.yaml; do
    say "  apply ${f} ..."
    SSH "${K} apply --server-side -f ${REMOTE_DIR}/${f} >/dev/null 2>&1" \
        || SSH "${K} apply -f ${REMOTE_DIR}/${f} >/dev/null 2>&1" \
        || { err "  apply ${f} 失败"; exit 1; }
done
say "  等待 rook-ceph-operator Running(最长 180s)..."
OP_OK=0
for i in $(seq 1 18); do
    OP_OK="$( (SSH "${K} -n rook-ceph get deploy rook-ceph-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null" || true) )"
    [ "${OP_OK:-0}" -ge 1 ] 2>/dev/null && break
    sleep 10
done
[ "${OP_OK:-0}" -ge 1 ] 2>/dev/null || { warn "  rook operator 未就绪(检查 kubectl -n rook-ceph get pods)"; }
ok "  Rook operator 已部署"

# ---------------- 7) 生成并应用 CephCluster CR(按节点+裸盘) ----------------
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

# toolbox
say "  部署 toolbox(ceph CLI)..."
SSH "${K} apply -f ${REMOTE_DIR}/toolbox.yaml >/dev/null 2>&1" || true

# 等待 CephCluster Ready + HEALTH_OK(最长 600s)
say "[7/8] 等待 Ceph 集群就绪(最长 600s, ceph -s HEALTH_OK)..."
CLUSTER_OK=0
for i in $(seq 1 60); do
    _ph="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
    if [ "${_ph}" = "Ready" ]; then
        _hl="$( (SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph -s 2>/dev/null" || true) | grep -oE 'HEALTH_(OK|WARN|ERR)' | head -1 )"
        [ "${_hl}" = "HEALTH_OK" ] && { CLUSTER_OK=1; break; }
        [ "${i}" -eq 20 ] && say "  集群 Ready 但健康状态 ${_hl:-未知}(可能初始化中, 继续等待)..."
    fi
    sleep 10
done
[ "${CLUSTER_OK}" = "1" ] && ok "  Ceph 集群 HEALTH_OK" \
    || warn "  Ceph 集群未在 600s 内 HEALTH_OK(查看: kubectl -n ${CEPH_NAMESPACE} get cephcluster / ceph -s; 常见: 磁盘未清理/内存不足/镜像未同步)"

# 调优 osd_memory_target(200G 盘 4G 已够; 大盘按文档)
say "  设置 OSD osd_memory_target=${CEPH_OSD_MEMORY_TARGET}GiB(经 toolbox)..."
SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph config set osd osd_memory_target $((CEPH_OSD_MEMORY_TARGET * 1024 * 1024 * 1024)) >/dev/null 2>&1" || true

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
