#!/bin/bash
# ============================================================
# MODULE: ceph_csi
# DESC: Ceph CSI 供给层: CephBlockPool + StorageClass(ceph-block), 可选 CephFS/RGW(依赖 ceph 模块)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: CEPH_CSI_ENABLED
# REQUIRES: ceph
# 说明:
#   · 断点续跑: REPEAT:0 → 成功后写状态; --fresh 重装。
#   · 前置: Ceph 模块(02_ceph)已就绪(rook operator + CephCluster HEALTH_OK)。
#   · 设计: rook v1.20 中 CSI 由 csi-operator.yaml + operator 调和自动部署(ceph-csi-operator);
#     本模块负责"存储供给层": rbd-pool(3 副本/host 故障域/min_size 2)+ StorageClass ceph-block;
#     CEPHFS_ENABLED=true 时创建 CephFilesystem + cephfs(WaitForFirstConsumer)与 cephfs-models(Retain/Immediate);
#     CEPH_RGW_ENABLED=true 时创建 CephObjectStore(RGW/S3, 集群内)。
#   · registry 后端(需求 6): 把 REGISTRY_STORAGE_CLASS 设为 ceph-block 后,
#     registry 的 PVC 走 ceph RBD —— 本模块须在 registry 配置模块之前执行(设计顺序见 docs/ceph-rook.md)。
#   · 参考: docs/ceph-rook.md
# 数据源: cluster.conf (CEPH_CSI_ENABLED / CEPH_ENABLED / CEPH_* / CEPHFS_ENABLED / CEPH_RGW_ENABLED / NODES)
# 用法:   sudo ./deploy-cluster.sh --enable ceph_csi  或  CEPH_CSI_ENABLED=true
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关 ----
[ "${CEPH_CSI_ENABLED:-false}" = "true" ] || { say "CEPH_CSI_ENABLED=false, 跳过 Ceph CSI"; exit 0; }
[ "${CEPH_ENABLED:-false}" = "true" ] || { err "Ceph CSI 依赖 Ceph 存储底座(CEPH_ENABLED=true 先部署模块 ceph)"; exit 1; }

init_remote_kubectl || exit 1

CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
CEPH_POOL_REPLICAS="${CEPH_POOL_REPLICAS:-3}"
CEPH_POOL_MIN_SIZE="${CEPH_POOL_MIN_SIZE:-2}"
CEPHFS_ENABLED="${CEPHFS_ENABLED:-false}"
CEPH_RGW_ENABLED="${CEPH_RGW_ENABLED:-false}"
CEPH_EXTERNAL_MONITORS="${CEPH_EXTERNAL_MONITORS:-}"   # 外部 Ceph monitors(节点<3 无集群内 CephCluster 时连接用)

# 前置: 集群内 CephCluster 已 Ready; 若无集群内 CephCluster 但配置了外部 monitors →
# 走"外部 Ceph 连接"模式(由 csi-operator 连外部, 跳过 rbd-pool/集群资源创建)。
_PH="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --no-headers 2>/dev/null" || true) )"
_CEPH_EXTERNAL=0
if [ -n "${_PH}" ]; then
    # CephCluster 存在但未 Ready: Progressing 是"首次建集群 / 备份 fsid 认领旧 OSD 数据"期间的
    # 正常瞬态(mon 逐个拉起 → mgr → OSD 认领, 恢复路径可达 10+ 分钟)。02_ceph 模块在备份恢复
    # 路径下也可能提前返回(集群仍在收敛) → 此处等待 Ready(最长 600s)而非立即失败,
    # 避免"集群还没起来, ceph_csi 一进来就把整个部署打断"(本次事故的直接触发点)。
    _PHASE="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
    _CLUSTER_READY=0
    for i in $(seq 1 60); do
        [ "${_PHASE}" = "Ready" ] && { _CLUSTER_READY=1; break; }
        [ "${i}" -eq 1 ] && say "  CephCluster phase=${_PHASE:-未知}, 等待 Ready(最长 600s; 恢复旧集群/首次建集群收敛较慢)..."
        sleep 10
        _PHASE="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
    done
    if [ "${_CLUSTER_READY}" = "1" ]; then
        say "  集群内 CephCluster Ready → 使用集群内存储"
    else
        err "  CephCluster 600s 内未 Ready(phase=${_PHASE:-未知}); 请先等 Ceph 集群 HEALTH_OK 后重跑本模块"
        err "  查看: kubectl -n ${CEPH_NAMESPACE} get cephcluster,pods; 集群卡死时可 --fresh 重装 ceph 模块"
        exit 1
    fi
    unset _CLUSTER_READY
elif [ -n "${CEPH_EXTERNAL_MONITORS}" ]; then
    _CEPH_EXTERNAL=1
    say "  无集群内 CephCluster, 但已配置 CEPH_EXTERNAL_MONITORS=${CEPH_EXTERNAL_MONITORS} → 外部 Ceph 连接模式"
else
    warn "  集群内无 CephCluster 且未配置 CEPH_EXTERNAL_MONITORS —— 无法创建 Ceph StorageClass"
    warn "  请先: ① 部署集群内 ceph(节点≥3); 或 ② cluster.conf 设 CEPH_EXTERNAL_MONITORS 连接外部 Ceph"
    exit 1
fi

say "[1/4] 确认 CSI 插件(ceph-csi-operator 调和)csi-rbdplugin / csi-cephfsplugin 就绪(最长 240s)..."
CSI_OK=0
for i in $(seq 1 24); do
    # rook v1.20: csi-operator 调和的 DS 名为 <driver>-nodeplugin(label app=<driver>-nodeplugin),
    # 不是旧版 app=csi-rbdplugin; controller 为 ceph-csi-controller-manager。
    _rbd="$( (SSH "${K} -n ${CEPH_NAMESPACE} get ds rook-ceph.rbd.csi.ceph.com-nodeplugin --no-headers 2>/dev/null" || true) )"
    _ctr="$( (SSH "${K} -n ${CEPH_NAMESPACE} get deploy ceph-csi-controller-manager --no-headers 2>/dev/null" || true) )"
    if [ -n "${_rbd}" ] && [ -n "${_ctr}" ]; then
        _rdy="$( (SSH "${K} -n ${CEPH_NAMESPACE} get deploy ceph-csi-controller-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null" || true) )"
        _dsrdy="$( (SSH "${K} -n ${CEPH_NAMESPACE} get ds rook-ceph.rbd.csi.ceph.com-nodeplugin -o jsonpath='{.status.numberReady}' 2>/dev/null" || true) )"
        [ "${_rdy:-0}" -ge 1 ] 2>/dev/null && [ "${_dsrdy:-0}" -ge 1 ] 2>/dev/null && { CSI_OK=1; break; }
    fi
    sleep 10
done
[ "${CSI_OK}" = "1" ] && ok "  ceph-csi 控制器/插件就绪" || warn "  ceph-csi 未完全就绪(检查 rook operator 日志; rook v1.20 必须已 apply csi-operator.yaml)"

apply_remote() {   # <本地YAML内容> <临时文件名> → 远端 kubectl apply
    local content="$1" name="$2"
    printf '%s' "${content}" | ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "cat > /tmp/${name}.yaml && ${K} apply -f /tmp/${name}.yaml"
}

say "[2/4] 创建 CephBlockPool rbd-pool(3 副本 / host 故障域 / min_size ${CEPH_POOL_MIN_SIZE})..."
# ★ 外部 Ceph 模式(无集群内 CephCluster): 经 ceph-csi-operator 的 CephConnection 连外部集群,
#   不创建集群内 pool(外部集群已有 pool), 仅建指向外部集群的 StorageClass。
if [ "${_CEPH_EXTERNAL}" = "1" ]; then
    CEPH_EXTERNAL_POOL="${CEPH_EXTERNAL_POOL:-rbd}"
    CEPH_EXTERNAL_USER="${CEPH_EXTERNAL_USER:-admin}"
    CEPH_EXTERNAL_KEYRING="${CEPH_EXTERNAL_KEYRING:-}"   # 外部 Ceph client keyring(base64 原文或明文 key)
    say "  外部模式: 创建 CephConnection(${CEPH_EXTERNAL_MONITORS}) + StorageClass ceph-block(pool=${CEPH_EXTERNAL_POOL})"
    [ -n "${CEPH_EXTERNAL_KEYRING}" ] || { err "外部 Ceph 需要认证: 请在 cluster.conf 设 CEPH_EXTERNAL_KEYRING(外部 Ceph client keyring, 如 admin 的 key)"; exit 1; }
    # monitors "a:6789","b:6789"(逗号分隔 → YAML 数组); CephConnection CRD spec.monitors(无 connection 层级)
    _MONS="$(echo "${CEPH_EXTERNAL_MONITORS}" | sed 's/,/","/g')"
    _EXT_YAML="apiVersion: csi.ceph.io/v1
kind: CephConnection
metadata:
  name: ceph-connection
  namespace: ${CEPH_NAMESPACE}
spec:
  monitors: [\"${_MONS}\"]
---
# 外部集群认证(admin keyring): csi-rbd 依赖这些 secret 连外部 Ceph
apiVersion: v1
kind: Secret
metadata:
  name: rook-csi-rbd-provisioner
  namespace: ${CEPH_NAMESPACE}
stringData:
  userID: ${CEPH_EXTERNAL_USER}
  userKey: ${CEPH_EXTERNAL_KEYRING}
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-csi-rbd-node
  namespace: ${CEPH_NAMESPACE}
stringData:
  userID: ${CEPH_EXTERNAL_USER}
  userKey: ${CEPH_EXTERNAL_KEYRING}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  pool: ${CEPH_EXTERNAL_POOL}
  clusterID: ceph-connection
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${CEPH_NAMESPACE}
  imageFormat: \"2\"
  imageFeatures: layering,fast-diff,object-map,deep-flatten,exclusive-lock
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer"
    apply_remote "${_EXT_YAML}" "ceph-ext-rbd" \
        && ok "  外部 CephConnection + 认证 secret + StorageClass ceph-block 已创建(外部 pool: ${CEPH_EXTERNAL_POOL})" \
        || { err "  创建外部 CephConnection/StorageClass 失败"; exit 1; }
    unset _MONS _EXT_YAML
else
RBD_POOL_YAML="apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: rbd-pool
  namespace: ${CEPH_NAMESPACE}
spec:
  failureDomain: host
  replicated:
    size: ${CEPH_POOL_REPLICAS}
    requireSafeReplicaSize: true
  enableCrushUpdates: true
  parameters:
    min_size: \"${CEPH_POOL_MIN_SIZE}\"
  compressionMode: none
  application: rbd
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  pool: rbd-pool
  clusterID: rook-ceph
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-expand-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-expand-secret-namespace: ${CEPH_NAMESPACE}
  imageFormat: \"2\"
  imageFeatures: layering,fast-diff,object-map,deep-flatten,exclusive-lock
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer"
apply_remote "${RBD_POOL_YAML}" "ceph-rbd" \
    && ok "  CephBlockPool rbd-pool + StorageClass ceph-block 已创建" \
    || { err "  创建 rbd-pool/StorageClass 失败"; exit 1; }
fi

# 可选项: CephFS(metadata/data 池 + MDS + cephfs/cephfs-models SC) —— 仅集群内模式(外部 Ceph 由外部集群提供 CephFS)
if [ "${_CEPH_EXTERNAL}" = "0" ] && [ "${CEPHFS_ENABLED}" = "true" ]; then
    say "[3/4] 创建 CephFilesystem + cephfs StorageClass..."
    apply_remote "apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: cephfs
  namespace: ${CEPH_NAMESPACE}
spec:
  metadataPool:
    replicated: { size: ${CEPH_POOL_REPLICAS}, requireSafeReplicaSize: true }
    failureDomain: host
  dataPools:
    - replicated: { size: ${CEPH_POOL_REPLICAS}, requireSafeReplicaSize: true }
      failureDomain: host
  metadataServer:
    activeCount: 1
    activeStandby: true
    placement:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
                - key: app
                  operator: In
                  values: [rook-ceph-mds]
            topologyKey: kubernetes.io/hostname
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cephfs
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  fsName: cephfs
  pool: cephfs-data0
  clusterID: rook-ceph
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${CEPH_NAMESPACE}
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer" "cephfs" \
        && ok "  CephFilesystem cephfs + StorageClass cephfs 已创建(等 MDS Running)" || warn "  CephFS 创建失败"
fi

# 可选项: RGW/S3 —— 仅集群内模式(外部 Ceph 由外部集群提供 RGW)
if [ "${_CEPH_EXTERNAL}" = "0" ] && [ "${CEPH_RGW_ENABLED}" = "true" ]; then
    say "[3/4] 创建 CephObjectStore(RGW/S3, 集群内)..."
    apply_remote "apiVersion: ceph.rook.io/v1
kind: CephObjectStore
metadata:
  name: my-store
  namespace: ${CEPH_NAMESPACE}
spec:
  metadataPool:
    replicated: { size: ${CEPH_POOL_REPLICAS} }
    failureDomain: host
  dataPool:
    replicated: { size: ${CEPH_POOL_REPLICAS} }
    failureDomain: host
  gateway:
    port: 80
    instances: 1" "rgw" \
        && ok "  CephObjectStore my-store 已创建" || warn "  RGW 创建失败"
fi

say "[4/4] 验证 StorageClass 与池..."
SC_LIST="$( (SSH "${K} get sc --no-headers 2>/dev/null" || true) )"
echo "${SC_LIST}" | grep -E 'ceph-block|cephfs' | sed 's/^/    /' || true
echo "  registry 后端: REGISTRY_STORAGE_CLASS=${REGISTRY_STORAGE_CLASS:-local-path}(设 ceph-block 后 registry PVC 走 ceph RBD)"

ok "Ceph CSI 供给层完成(StorageClass: ceph-block)"
echo "  使用: PVC storageClassName=ceph-block(块, 可多挂); 详见 docs/ceph-rook.md §9"
echo "  卸载: kubectl delete sc ceph-block; kubectl -n ${CEPH_NAMESPACE} delete cephblockpool rbd-pool"
