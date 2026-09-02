#!/bin/bash
# ============================================================
# MODULE: ceph_csi
# DESC: Ceph CSI 供给层: CephBlockPool + StorageClass(ceph-block), 可选 CephFS/RGW(依赖 ceph 模块)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: CEPH_CSI_ENABLED
# 说明:
#   · 断点续跑: REPEAT:0 → 成功后写状态; --fresh 重装。
#   · 前置: Ceph 模块(07_ceph)已就绪(rook operator + CephCluster HEALTH_OK)。
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

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
CEPH_POOL_REPLICAS="${CEPH_POOL_REPLICAS:-3}"
CEPH_POOL_MIN_SIZE="${CEPH_POOL_MIN_SIZE:-2}"
CEPHFS_ENABLED="${CEPHFS_ENABLED:-false}"
CEPH_RGW_ENABLED="${CEPH_RGW_ENABLED:-false}"

# 前置: CephCluster Ready
_ph="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
[ "${_ph}" = "Ready" ] || { err "CephCluster 未 Ready(phase=${_ph}); 请先部署 ceph 模块(CEPH_ENABLED=true)并等 HEALTH_OK"; exit 1; }

say "[1/4] 确认 CSI 插件(ceph-csi-operator 调和)csi-rbdplugin / csi-cephfsplugin 就绪(最长 240s)..."
CSI_OK=0
for i in $(seq 1 24); do
    _rbd="$( (SSH "${K} -n ${CEPH_NAMESPACE} get ds -l app=csi-rbdplugin --no-headers 2>/dev/null" || true) )"
    _ctr="$( (SSH "${K} -n ${CEPH_NAMESPACE} get deploy ceph-csi-controller-manager --no-headers 2>/dev/null" || true) )"
    if [ -n "${_rbd}" ] && [ -n "${_ctr}" ]; then
        _rdy="$( (SSH "${K} -n ${CEPH_NAMESPACE} get deploy ceph-csi-controller-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null" || true) )"
        [ "${_rdy:-0}" -ge 1 ] 2>/dev/null && { CSI_OK=1; break; }
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

# 可选项: CephFS(metadata/data 池 + MDS + cephfs/cephfs-models SC)
if [ "${CEPHFS_ENABLED}" = "true" ]; then
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

# 可选项: RGW/S3
if [ "${CEPH_RGW_ENABLED}" = "true" ]; then
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
