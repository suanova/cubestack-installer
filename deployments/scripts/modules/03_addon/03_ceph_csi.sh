#!/bin/bash
# ============================================================
# MODULE: ceph_csi
# DESC: Ceph CSI 供给层: CephBlockPool + StorageClass(ceph-block), 可选 CephFS/RGW(依赖 ceph 模块)
#       + 对外暴露(默认开, mon/RGW *-external Service, 供集群外 ceph-csi-operator 接入)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: CEPH_CSI_ENABLED
# REQUIRES: ceph k8s_deploy
# 说明:
#   · 断点续跑: REPEAT:0 → 成功后写状态; --fresh 重装。
#   · 前置: Ceph 模块(02_ceph)已就绪(rook operator + CephCluster HEALTH_OK; external 模式=operator/csi-operator)。
#   · ★ REQUIRES 含 k8s_deploy: 本模块 SSH 到 master 跑 kubectl, 必须等集群部署完成 ——
#     默认模式 k8s_deploy 由 enable 循环追加在 RUN_STEPS 末尾, 若只依赖 ceph(且 ceph 不在
#     运行列表时)会被拓扑排序浮到 k8s_deploy 之前(历史事故: ceph_csi 排在 k8s_deploy 前卡死)。
#   · 设计: rook v1.20 中 CSI 由 csi-operator.yaml + operator 调和自动部署(ceph-csi-operator);
#     本模块负责"存储供给层"(对齐 docs §7 资源设计):
#     · CephBlockPool rbd-pool(3 副本/host 故障域/min_size 2)
#     · RBD StorageClass 三变体: ceph-rbd-ephemeral(WFFC/Delete, 默认) /
#       ceph-rbd-ephemeral-immediate(Immediate/Delete) / ceph-rbd-durable(WFFC/Retain)
#     · CEPHFS_ENABLED=true → CephFilesystem cephfs(activeCount 2/热备/防误删)+
#       StorageClass cephfs-ephemeral(Delete/Immediate) / cephfs-durable(Retain/Immediate)
#       + subvolume groups ephemeral/durable(§9.1 工作区/平台共享划分)
#     · CEPH_RGW_ENABLED=true → CephObjectStore s3-store(preservePoolsOnDelete, min_size 2)
#       + Model 仓库用户 rgw-model-admin/rgw-model-reader(§10.4)
#   · registry 后端(需求 6): 把 REGISTRY_STORAGE_CLASS 设为 ceph-block 后,
#     registry 的 PVC 走 ceph RBD —— 本模块须在 registry 配置模块之前执行(设计顺序见 docs/ceph-rook.md)。
#   · 参考: docs/ceph-rook.md
# 数据源: cluster.conf (CEPH_CSI_ENABLED / CEPH_ENABLED / CEPH_* / CEPHFS_ENABLED / CEPH_RGW_ENABLED /
#         CEPH_EXTERNAL_EXPOSE / CEPH_EXTERNAL_EXPOSE_MODE / CEPH_RGW_EXPOSE_MODE /
#         CEPH_EXTERNAL_PROVISION_SMOKE / SERVICE_EXPOSE_MODE / NODES)
# 用法:   sudo ./deploy-cluster.sh --enable ceph_csi  或  CEPH_CSI_ENABLED=true
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关 ----
[ "${CEPH_CSI_ENABLED:-false}" = "true" ] || { say "CEPH_CSI_ENABLED=false, 跳过 Ceph CSI"; exit 0; }
# internal(自建 CephCluster)要求 CEPH_ENABLED=true; external(仅接入外部 Ceph)已由 CEPH_CSI_ENABLED=true 放行。
if [ "${CEPH_MODE:-internal}" != "external" ] && [ "${CEPH_ENABLED:-false}" != "true" ]; then
    say "CEPH_ENABLED=false, 跳过 Ceph CSI(无 Ceph 存储底座)"; exit 0;
fi

init_remote_kubectl || exit 1

CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
CEPH_POOL_REPLICAS="${CEPH_POOL_REPLICAS:-3}"
CEPH_POOL_MIN_SIZE="${CEPH_POOL_MIN_SIZE:-2}"
CEPHFS_ENABLED="${CEPHFS_ENABLED:-false}"
CEPH_RGW_ENABLED="${CEPH_RGW_ENABLED:-false}"
# ★ CEPH_MODE=external(由 load_config 归一化; 兼容旧 CEPH_MONITORS 自动迁移):
#   不创建集群内 CephCluster, 经 ceph-csi-operator 的 CephConnection 接入外部已有 Ceph。
#   连接参数统一用 CEPH_MONITORS / CEPH_POOL / CEPH_USER / CEPH_KEYRING(见 lib-common load_config)。

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
elif [ "${CEPH_MODE:-internal}" = "external" ]; then
    _CEPH_EXTERNAL=1
    say "  无集群内 CephCluster, CEPH_MODE=external → 外部 Ceph 连接模式(monitors=${CEPH_MONITORS:-<未配置>})"
else
    warn "  集群内无 CephCluster 且 CEPH_MODE!=external —— 无法创建 Ceph StorageClass"
    warn "  请先: ① 部署集群内 ceph(节点≥3, CEPH_MODE=internal); 或 ② cluster.conf 设 CEPH_MODE=external + CEPH_MONITORS 连接外部 Ceph"
    exit 1
fi

# ★ 存储供给层 YAML 从 rook/{rbd,cephfs,rgw}/ 目录文件读取(§7 资源设计, 单一事实来源),
#   经 sed 替换模板变量 __NAMESPACE__/__REPLICAS__/__MIN_SIZE__ 后 apply。
#   文件由 tools/k8s/rook-fetch-manifests.sh 同源维护(见 cubestack-addon/rook/CUBESTACK-storage.md)。
_ceph_yaml_file() {   # <subdir/file.yaml> [<file2.yaml>...] → 各文件变量替换后按序拼接(--- 分隔), 失败返回 1
    local base="${CEPH_ROOK_MANIFEST_DIR:-${REPO_ROOT}/deployments/cubestack-addon/rook}" f out=""
    for f in "$@"; do
        [ -f "${base}/${f}" ] || { err "存储供给层 YAML 缺失: ${base}/${f}(检查 cubestack-addon/rook/ 目录)"; return 1; }
        out="${out}$(sed -e "s|__NAMESPACE__|${CEPH_NAMESPACE}|g" \
            -e "s|__REPLICAS__|${CEPH_POOL_REPLICAS}|g" \
            -e "s|__MIN_SIZE__|${CEPH_POOL_MIN_SIZE}|g" "${base}/${f}")"$'\n---\n'
    done
    printf '%s' "${out}"
}

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
#   不创建集群内 pool/fs(外部集群已有), 创建指向外部集群的 6 个默认 StorageClass
#   (与集群内模式同名的 SC 集合, 供应用/平台无差别使用)。
if [ "${_CEPH_EXTERNAL}" = "1" ]; then
    say "  外部模式: 创建 CephConnection(${CEPH_MONITORS:-<未配置>}) + 6×StorageClass(指向外部 Ceph)"
    [ -n "${CEPH_KEYRING:-}" ] || { err "外部 Ceph 需要认证: 请在 cluster.conf 设 CEPH_KEYRING(外部 Ceph client keyring, 如 admin 的 key)"; exit 1; }
    # monitors "a:b", "c:d"(逗号分隔 → YAML 数组); CephConnection CRD spec.monitors(无 connection 层级)
    _MONS="$(echo "${CEPH_MONITORS:-}" | sed 's/,/","/g')"
    # 外部 CephFS(可选): 需外部集群已创建 CephFilesystem(fs + meta/data pools).
# CEPHFS_FS 为空则跳过 CephFS 两个 SC(仅 RBD); CEPHFS_FS 非空但缺 DATA_POOL → 硬失败(明确提示缺什么)。
    EXT_CEPHFS_ENABLED="${CEPHFS_FS:-}"
    if [ -n "${EXT_CEPHFS_ENABLED}" ] && [ -z "${CEPHFS_DATA_POOL:-}" ]; then
        err "CEPHFS_FS 已设置但 CEPHFS_DATA_POOL 为空: external CephFS 需要外部集群的 data pool 名(如 cubestack-ext-cephfs-data)"; exit 1
    fi
    # RBD SC parameters(不含 `parameters:` 键头 —— 该键已由 SC 模板头写出, 避免重复键导致 YAML 解析错误;
    #   末尾固定换行, 与后续 reclaimPolicy 正常分行)
    _rbd_params() {   # 输出 RBD SC parameters 键下的字段(缩进 2 空格, secret 名固定 + 当前 pool)
        cat << RBD
  pool: ${CEPH_POOL:-rbd}
  clusterID: ceph-connection
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-expand-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-expand-secret-namespace: ${CEPH_NAMESPACE}
  imageFormat: "2"
  imageFeatures: layering,fast-diff,object-map,deep-flatten,exclusive-lock
RBD
    }
    # 构造完整 YAML(CephConnection + RBD/CephFS secret + 6 个 SC)
    _EXT_YAML="apiVersion: csi.ceph.io/v1
kind: CephConnection
metadata:
  name: ceph-connection
  namespace: ${CEPH_NAMESPACE}
spec:
  monitors: [\"${_MONS}\"]
---
# ★ ClientProfile(名字 = clusterID, 必须与 SC parameters.clusterID 一致 = ceph-connection):
#   ceph-csi-operator 据此生成 ceph-csi-config ConfigMap(config.json: clusterID→monitors)。
#   CephConnection 只提供 monitors; 无 ClientProfile → config map 为空 → provisioner 报
#   failed-to-fetch-monitor-list(using clusterID) → 全部 PVC 永久 Pending(registry 卡死,
#   NodePort 不可达)。2026-09-09 事故根因, 见 docs/troubleshooting.md 三.6。
apiVersion: csi.ceph.io/v1
kind: ClientProfile
metadata:
  name: ceph-connection
  namespace: ${CEPH_NAMESPACE}
spec:
  cephConnectionRef:
    name: ceph-connection
---
# 外部集群 RBD 认证(csi-rbd provisioner/node): 连外部 Ceph 的集群内 secret
apiVersion: v1
kind: Secret
metadata:
  name: rook-csi-rbd-provisioner
  namespace: ${CEPH_NAMESPACE}
stringData:
  userID: ${CEPH_USER:-admin}
  userKey: ${CEPH_KEYRING:-}
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-csi-rbd-node
  namespace: ${CEPH_NAMESPACE}
stringData:
  userID: ${CEPH_USER:-admin}
  userKey: ${CEPH_KEYRING:-}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:"
    _EXT_YAML="${_EXT_YAML}
$(_rbd_params)
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd-ephemeral
  annotations:
    storageclass.kubernetes.io/is-default-class: \"true\"
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
$(_rbd_params)
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd-ephemeral-immediate
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
$(_rbd_params)
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd-durable
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
$(_rbd_params)
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer"

    if [ -n "${EXT_CEPHFS_ENABLED}" ]; then
        _CEPHFS_PROVISIONER_SECRET="rook-csi-cephfs-provisioner"
        _CEPHFS_NODE_SECRET="rook-csi-cephfs-node"
        # external CephFS 必要字段(来自 ceph-external-access.conf 导入): CEPHFS_FS / CEPHFS_DATA_POOL 必填
        # CephConnection clusterID=ceph-connection; fsName/pool 指向外部集群已存在的 fs/data pool
        _CEPHFS_FS="${CEPHFS_FS:?external CephFS 需要 CEPHFS_FS(外部集群 fs 名, 如 cubestack-ext-fs)}"
        _CEPHFS_DATA_POOL="${CEPHFS_DATA_POOL:?external CephFS 需要 CEPHFS_DATA_POOL(外部集群 data pool, 如 cubestack-ext-cephfs-data)}"
        _EXT_YAML="${_EXT_YAML}
---
# 外部 CephFS 认证(csi-cephfs provisioner/node): 用外部 CephFS 专用用户
apiVersion: v1
kind: Secret
metadata:
  name: ${_CEPHFS_PROVISIONER_SECRET}
  namespace: ${CEPH_NAMESPACE}
stringData:
  userID: ${CEPHFS_USER:-${CEPH_USER:-admin}}
  userKey: ${CEPHFS_KEYRING:-${CEPH_KEYRING:-}}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${_CEPHFS_NODE_SECRET}
  namespace: ${CEPH_NAMESPACE}
stringData:
  userID: ${CEPHFS_USER:-${CEPH_USER:-admin}}
  userKey: ${CEPHFS_KEYRING:-${CEPH_KEYRING:-}}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cephfs-ephemeral
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  fsName: ${_CEPHFS_FS}
  pool: ${_CEPHFS_DATA_POOL}
  clusterID: ceph-connection
  csi.storage.k8s.io/provisioner-secret-name: ${_CEPHFS_PROVISIONER_SECRET}
  csi.storage.k8s.io/provisioner-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: ${_CEPHFS_NODE_SECRET}
  csi.storage.k8s.io/node-stage-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: ${_CEPHFS_PROVISIONER_SECRET}
  csi.storage.k8s.io/controller-expand-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-expand-secret-name: ${_CEPHFS_NODE_SECRET}
  csi.storage.k8s.io/node-expand-secret-namespace: ${CEPH_NAMESPACE}
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cephfs-durable
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  fsName: ${_CEPHFS_FS}
  pool: ${_CEPHFS_DATA_POOL}
  clusterID: ceph-connection
  csi.storage.k8s.io/provisioner-secret-name: ${_CEPHFS_PROVISIONER_SECRET}
  csi.storage.k8s.io/provisioner-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: ${_CEPHFS_NODE_SECRET}
  csi.storage.k8s.io/node-stage-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: ${_CEPHFS_PROVISIONER_SECRET}
  csi.storage.k8s.io/controller-expand-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-expand-secret-name: ${_CEPHFS_NODE_SECRET}
  csi.storage.k8s.io/node-expand-secret-namespace: ${CEPH_NAMESPACE}
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: Immediate"
        unset _CEPHFS_FS _CEPHFS_DATA_POOL
    fi

    # 外部模式 SC 数量(供完成提示; 4×RBD + 2×CephFS)
    _EXT_NUM="4"; [ -n "${EXT_CEPHFS_ENABLED}" ] && _EXT_NUM="6"
    apply_remote "${_EXT_YAML}" "ceph-ext-rbd" \
        && ok "  外部 CephConnection + 认证 secret + ${_EXT_NUM:-}个 StorageClass 已创建(外部 pool: ${CEPH_POOL:-rbd})" \
        || { err "  创建外部 CephConnection/StorageClass 失败"; exit 1; }
    # ★ 等 ceph-csi-operator 生成 ceph-csi-config ConfigMap(config.json: clusterID→monitors)。
    #   无该 CM(或内容空)→ provisioner 无法解析 clusterID, 所有 PVC 永久 Pending(registry 卡死,
    #   NodePort 不可达)。operator 调和是异步的, 等待最长 60s; 超时硬失败(防静默回归)。
    #   ⚠ 判定必须用 `-o yaml`(2026-09-09 修复): `-o jsonpath='{.data}'` 输出 map 时会把
    #   config.json 内的双引号转义成 `\"clusterID\":\"ceph-connection\"` → 未转义模式的
    #   grep 永远不匹配 → CM 实际已生成却误报 60s 超时(假阴性, 实机事故)。
    say "  等待 ceph-csi-operator 生成 ceph-csi-config(config.json, 最长 60s)..."
    _CFG_OK=0
    for _ci in $(seq 1 12); do
        _cfg="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cm ceph-csi-config -o yaml 2>/dev/null" || true) )"
        if [ -n "${_cfg}" ] && echo "${_cfg}" | grep -q '"clusterID":"ceph-connection"'; then
            _CFG_OK=1; break
        fi
        sleep 5
    done
    if [ "${_CFG_OK}" = "1" ]; then
        ok "  ceph-csi-config 已生成(clusterID=ceph-connection, 外部 Ceph 接入就绪)"
        # ★ 2026-09-09: CM 数据就绪 ≠ provisioner pod 可见 —— kubelet 把 CM 投递进
        #   /etc/ceph-csi-config/ 有 ~1 分钟同步延迟。若不等到投递完成, k8s_registry 的
        #   首次 provision 报 InvalidArgument(config.json not found) 被 csi-provisioner
        #   判为 **infeasible error** → 退避翻倍到 256s 级, registry 90s 等待超时中断部署
        #   (实机事故: 首次失败 06:50:17 → 06:58:49 才重试成功)。此处等投递完成(最长 60s,
        #   超时仅告警不硬失败 —— provisioner 会自行重试成功)。
        say "  等待 config.json 投递进 provisioner pod(最长 60s)..."
        _MOUNT_OK=0
        for _ci in $(seq 1 12); do
            if ( SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph.rbd.csi.ceph.com-ctrlplugin -c csi-rbdplugin -- test -f /etc/ceph-csi-config/config.json" 2>/dev/null ); then
                _MOUNT_OK=1; break
            fi
            sleep 5
        done
        if [ "${_MOUNT_OK}" = "1" ]; then
            ok "  config.json 已投递进 provisioner pod(外部 Ceph provision 就绪)"
        else
            warn "  config.json 60s 内未投递进 pod(kubelet 延迟; 不影响部署, csi-provisioner 会自动重试成功)"
        fi
        # ★ 外部 provision 冒烟测试(2026-09-09, 目标"一次性部署成功"): 用 Immediate 模式 SC
        #   (ceph-rbd-ephemeral-immediate)建 1Gi scratch PVC → 等 Bound → 删除。作用:
        #   · 端到端打通 provision 全链(mon 连接/cephx 认证/外部 pool/建卷/删卷)——
        #     提供方未就绪(pool/用户/网络)在此立刻硬失败并给出排查命令,
        #     不会拖到 k8s_registry 才断(历史事故: registry 90s 超时中断部署);
        #   · 预热 provisioner 首触路径(消除冷启动/投递延迟), registry 正式 PVC 秒绑。
        #   CEPH_EXTERNAL_PROVISION_SMOKE=false 可跳过(提供方未就绪但需先装其它组件时)。
        if [ "${CEPH_EXTERNAL_PROVISION_SMOKE:-true}" = "true" ]; then
            say "  外部 Ceph provision 冒烟测试(1Gi scratch PVC, 最长 180s)..."
            SMOKE_YAML="apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-csi-smoke-test
  namespace: ${CEPH_NAMESPACE}
spec:
  storageClassName: ceph-rbd-ephemeral-immediate
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi"
            apply_remote "${SMOKE_YAML}" "ceph-csi-smoke" \
                || { err "  冒烟测试 PVC 创建失败"; exit 1; }
            _SMOKE_OK=0
            for _ci in $(seq 1 36); do
                _smoke="$( (SSH "${K} -n ${CEPH_NAMESPACE} get pvc ceph-csi-smoke-test -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
                if [ "${_smoke}" = "Bound" ]; then _SMOKE_OK=1; break; fi
                sleep 5
            done
            # 无论成败都删除冒烟 PVC(Delete reclaim 自动清 PV/外部卷)
            ( SSH "${K} -n ${CEPH_NAMESPACE} delete pvc ceph-csi-smoke-test --ignore-not-found" >/dev/null 2>&1 || true )
            if [ "${_SMOKE_OK}" = "1" ]; then
                ok "  冒烟测试通过(1Gi 卷真实创建于外部 pool, 已清理)"
            else
                err "  冒烟测试失败: 1Gi scratch PVC 180s 内未 Bound —— 外部 Ceph 提供方异常"
                err "  排查: ① 提供方集群 HEALTH_OK: kubectl -n rook-ceph get cephcluster(提供方) + ceph -s"
                err "  ② 外部用户/pool 存在: ceph auth get ${CEPH_USER:-cubestack-ext-rbd}; ceph osd lspools | grep ${CEPH_POOL}"
                err "  ③ provisioner 日志: kubectl -n rook-ceph logs deploy/rook-ceph.rbd.csi.ceph.com-ctrlplugin -c csi-rbdplugin --tail=50"
                err "  (提供方未就绪又需先装其它组件时, 可 CEPH_EXTERNAL_PROVISION_SMOKE=false 跳过本测试)"
                exit 1
            fi
            unset _SMOKE_OK _smoke SMOKE_YAML
        fi
    else
        err "  ceph-csi-config 60s 内未生成(ceph-csi-operator 未调和 ClientProfile/CephConnection)"
        err "  排查: kubectl -n ${CEPH_NAMESPACE} get clientprofile,cephconnection; kubectl -n ${CEPH_NAMESPACE} logs deploy/ceph-csi-controller-manager --tail=50"
        exit 1
    fi
    unset _MONS _EXT_YAML EXT_CEPHFS_ENABLED _CEPHFS_PROVISIONER_SECRET _CEPHFS_NODE_SECRET _CFG_OK _MOUNT_OK _cfg _ci _EXT_NUM
else
_CEPH_RBD_YAML="$(_ceph_yaml_file rbd/01-cephblockpool-rbd-pool.yaml rbd/02-storageclass-rbd.yaml rbd/03-storageclass-ceph-block-alias.yaml)" || exit 1
apply_remote "${_CEPH_RBD_YAML}" "ceph-rbd" \
    && ok "  CephBlockPool rbd-pool + 3×RBD StorageClass(ephemeral WFFC / -immediate / durable Retain)已创建" \
    || { err "  创建 rbd-pool/StorageClass 失败"; exit 1; }
fi

# 可选项: CephFS(metadata/data 池 + MDS + cephfs/cephfs-models SC) —— 仅集群内模式(外部 Ceph 由外部集群提供 CephFS)
if [ "${_CEPH_EXTERNAL}" = "0" ] && [ "${CEPHFS_ENABLED}" = "true" ]; then
    say "[3/4] 创建 CephFilesystem + cephfs StorageClass..."
    apply_remote "$(_ceph_yaml_file cephfs/01-cephfilesystem.yaml cephfs/02-storageclass-cephfs.yaml)" "cephfs" \
        && ok "  CephFilesystem cephfs + StorageClass cephfs-ephemeral/cephfs-durable 已创建(等 MDS Running)" || warn "  CephFS 创建失败"
    # ★ CephFilesystemSubVolumeGroup: ephemeral(工作区)/ durable(平台共享)(§9.1)
    apply_remote "$(_ceph_yaml_file cephfs/03-subvolumegroups.yaml)" "cephfs-svgroups" \
        && ok "  CephFS subvolume groups ephemeral/durable 已创建(工作区/平台共享划分)" || warn "  CephFS subvolume groups 创建失败"
fi

# 可选项: RGW/S3 —— 仅集群内模式(外部 Ceph 由外部集群提供 RGW)
if [ "${_CEPH_EXTERNAL}" = "0" ] && [ "${CEPH_RGW_ENABLED}" = "true" ]; then
    say "[3/4] 创建 CephObjectStore(RGW/S3, 集群内)..."
    apply_remote "$(_ceph_yaml_file rgw/01-cephobjectstore-s3-store.yaml)" "rgw" \
        && ok "  CephObjectStore s3-store 已创建" || warn "  RGW 创建失败"
    # ★ Model 仓库两个全局角色用户(§10.4): rgw-model-admin(owner)/ rgw-model-reader(只读),
    #   凭证 Secret = rook-ceph-object-user-s3-store-<用户名>, 由平台复制到使用方命名空间。
    apply_remote "$(_ceph_yaml_file rgw/02-cephobjectstoreuser-model.yaml)" "rgw-users" \
        && ok "  RGW Model 用户 rgw-model-admin/rgw-model-reader 已创建(Model 仓库凭证)" || warn "  RGW Model 用户创建失败"

fi

# ★ Ceph 对外暴露(mon + RGW, YAML 声明式; 2026-09-07 重构)——
#   默认允许集群外 ceph-csi-operator(CEPH_MODE=external)接入:
#   · CEPH_EXTERNAL_EXPOSE=true(默认)→ 创建 mon/RGW *-external Service + 外部专用用户
#     + 导出 config/ceph-external-access.conf(拷贝到目标集群 cluster.conf 即可接入)
#   · 模式跟随 SERVICE_EXPOSE_MODE(nodeport→NodePort 端口自动分配 / metallb→LoadBalancer VIP),
#     可用 CEPH_EXTERNAL_EXPOSE_MODE / CEPH_RGW_EXPOSE_MODE 显式覆盖(大小写不敏感)
#   · 实现: tools/k8s/ceph-expose-external.sh(从 rook/external/ YAML 模板生成 → kubectl apply 幂等;
#     新建独立 *-external svc, 不碰 Rook 自管 ClusterIP svc, 无 operator 回滚/时序问题)
if [ "${_CEPH_EXTERNAL}" = "0" ]; then
    bash "${SCRIPT_DIR}/tools/k8s/ceph-expose-external.sh" apply \
        || warn "  Ceph 对外暴露应用失败(可 CEPH_EXTERNAL_EXPOSE=false 关闭后重跑, 或手工执行工具脚本排查)"
    # ★ 部署完成 → 终端打印外部 ceph-csi operator 接入所需信息(用户要求: 部署完可读)
    if [ -f "${REPO_ROOT}/deployments/config/ceph-external-access.conf" ]; then
        say "外部 ceph-csi operator 接入所需信息(同时写入 ${REPO_ROOT}/deployments/config/ceph-external-access.conf):"
        echo "---------------------------------------------"
        sed 's/^/  /' "${REPO_ROOT}/deployments/config/ceph-external-access.conf"
        echo "---------------------------------------------"
        ok "接入配置文件: ${REPO_ROOT}/deployments/config/ceph-external-access.conf(拷贝到目标集群 cluster.conf 设 CEPH_MODE=external 即可接入)"
    else
        warn "  未找到 ${REPO_ROOT}/deployments/config/ceph-external-access.conf(确认 expose 工具已 apply 成功)"
    fi
fi

say "[4/4] 验证 StorageClass 与池..."
SC_LIST="$( (SSH "${K} get sc --no-headers 2>/dev/null" || true) )"
echo "${SC_LIST}" | grep -E 'ceph-block|cephfs' | sed 's/^/    /' || true
echo "  registry 后端: REGISTRY_STORAGE_CLASS=${REGISTRY_STORAGE_CLASS:-local-path}(设 ceph-block 后 registry PVC 走 ceph RBD)"

ok "Ceph CSI 供给层完成(StorageClass: ceph-block)"
echo "  使用: PVC storageClassName=ceph-block(块, 可多挂); 详见 docs/ceph-rook.md §9"
echo "  卸载: kubectl delete sc ceph-block; kubectl -n ${CEPH_NAMESPACE} delete cephblockpool rbd-pool"

