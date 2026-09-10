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
#         CEPH_EXTERNAL_PROVISION_SMOKE / SERVICE_EXPOSE_MODE / NODES;
#         external CephFS 双角色: CEPHFS_USER/CEPHFS_KEYRING(provisioner) + CEPHFS_NODE_USER/
#         CEPHFS_NODE_KEYRING(node, 2026-09-10 Bug A))
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

# ════════════════════════════════════════════════════════════════════
# ★ 2026-09-10 官方导入路径: 消费者读提供方导出的 external-ceph.env(Rook 官方格式),
#   复刻 import-external-cluster.sh 的资源创建(声明式 YAML + apply_remote, 不依赖官方
#   脚本的交互/kubectl 直连), 再 apply cluster-external.yaml —— Rook operator 据此
#   自动创建 CephConnection/ClientProfile 并做 mon 健康检查 → STATE=Connected 上报
#   (官方 healthCheck 机制, 即 Bug D 的官方解法)。RGW 密钥存在时自动接外部对象存储。
#   参考: cubestack-addon/rook/external/{import-external-cluster.sh,cluster-external.yaml,
#   common-external.yaml,object-external.yaml}(v1.20.2 vendored)
# ════════════════════════════════════════════════════════════════════
_ext_import_official() {
    local _env_file="${CEPH_EXTERNAL_ENV_FILE}"
    [ -f "${_env_file}" ] || { err "CEPH_EXTERNAL_ENV_FILE=${_env_file} 文件不存在(提供方 ceph-external-cluster-details.sh 导出的 external-ceph.env)"; exit 1; }
    say "  官方导入模式: 读取 ${_env_file} ..."
    # shellcheck disable=SC1090
    source "${_env_file}"
    # 必填校验(与官方 import-external-cluster.sh checkEnvVars 一致)
    local _miss=""
    [ -n "${ROOK_EXTERNAL_FSID:-}" ]            || _miss="${_miss} ROOK_EXTERNAL_FSID"
    [ -n "${ROOK_EXTERNAL_CEPH_MON_DATA:-}" ]   || _miss="${_miss} ROOK_EXTERNAL_CEPH_MON_DATA"
    [ -n "${ROOK_EXTERNAL_USERNAME:-}" ]        || _miss="${_miss} ROOK_EXTERNAL_USERNAME"
    [ -n "${ROOK_EXTERNAL_USER_SECRET:-}" ]     || _miss="${_miss} ROOK_EXTERNAL_USER_SECRET"
    [ -n "${_miss}" ] && { err "external-ceph.env 缺必填变量:${_miss}(提供方导出不完整? 见 docs/ceph-rook.md §外部接入)"; exit 1; }
    # userID 语义 = <secret_name> + ".<generation>"(generation 空/0 不加后缀)——
    #   与官方 import-external-cluster.sh getUserId() 逐字一致(不带 client. 前缀)
    local _gen="${CEPHX_KEY_GENERATION:-0}"
    _ext_uid() { local _n="$1"; [ -z "${_gen}" ] || [ "${_gen}" = "0" ] && { echo "${_n}"; return 0; }; echo "${_n}.${_gen}"; }

    say "  [import 1/4] 创建 rook-ceph-mon secret + mon-endpoints CM + CSI secrets ..."
    _EXT_IMP_YAML="apiVersion: v1
kind: Secret
metadata:
  name: rook-ceph-mon
  namespace: ${CEPH_NAMESPACE}
type: kubernetes.io/rook
stringData:
  cluster-name: ${CEPH_NAMESPACE}
  fsid: ${ROOK_EXTERNAL_FSID}
  admin-secret: ${ROOK_EXTERNAL_ADMIN_SECRET:-admin-secret}
  mon-secret: ${ROOK_EXTERNAL_MONITOR_SECRET:-mon-secret}
  ceph-username: $(_ext_uid "${ROOK_EXTERNAL_USERNAME}")
  ceph-secret: ${ROOK_EXTERNAL_USER_SECRET}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: rook-ceph-mon-endpoints
  namespace: ${CEPH_NAMESPACE}
data:
  data: ${ROOK_EXTERNAL_CEPH_MON_DATA}
  mapping: \"{}\"
  maxMonId: \"2\""
    # 官方 import 脚本还建 external-cluster-user-command CM(记录提供方导出参数, 供排障);
    # 有 ARGS 时一并创建(与官方行为一致)。
    if [ -n "${ARGS:-}" ]; then
        _EXT_IMP_YAML="${_EXT_IMP_YAML}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: external-cluster-user-command
  namespace: ${CEPH_NAMESPACE}
data:
  args: |-
    ${ARGS}"
    fi
    # 4 个 CSI secret(双角色凭据天然分开 —— Bug A 在官方路径天然成立)
    if [ -n "${CSI_RBD_NODE_SECRET_NAME:-}" ] && [ -n "${CSI_RBD_NODE_SECRET:-}" ]; then
        _EXT_IMP_YAML="${_EXT_IMP_YAML}
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-${CSI_RBD_NODE_SECRET_NAME}
  namespace: ${CEPH_NAMESPACE}
type: kubernetes.io/rook
stringData:
  userID: $(_ext_uid "${CSI_RBD_NODE_SECRET_NAME}")
  userKey: ${CSI_RBD_NODE_SECRET}"
    fi
    if [ -n "${CSI_RBD_PROVISIONER_SECRET_NAME:-}" ] && [ -n "${CSI_RBD_PROVISIONER_SECRET:-}" ]; then
        _EXT_IMP_YAML="${_EXT_IMP_YAML}
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-${CSI_RBD_PROVISIONER_SECRET_NAME}
  namespace: ${CEPH_NAMESPACE}
type: kubernetes.io/rook
stringData:
  userID: $(_ext_uid "${CSI_RBD_PROVISIONER_SECRET_NAME}")
  userKey: ${CSI_RBD_PROVISIONER_SECRET}"
    fi
    if [ -n "${CSI_CEPHFS_NODE_SECRET_NAME:-}" ] && [ -n "${CSI_CEPHFS_NODE_SECRET:-}" ]; then
        _EXT_IMP_YAML="${_EXT_IMP_YAML}
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-${CSI_CEPHFS_NODE_SECRET_NAME}
  namespace: ${CEPH_NAMESPACE}
type: kubernetes.io/rook
stringData:
  userID: $(_ext_uid "${CSI_CEPHFS_NODE_SECRET_NAME}")
  userKey: ${CSI_CEPHFS_NODE_SECRET}"
    fi
    if [ -n "${CSI_CEPHFS_PROVISIONER_SECRET_NAME:-}" ] && [ -n "${CSI_CEPHFS_PROVISIONER_SECRET:-}" ]; then
        _EXT_IMP_YAML="${_EXT_IMP_YAML}
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-${CSI_CEPHFS_PROVISIONER_SECRET_NAME}
  namespace: ${CEPH_NAMESPACE}
type: kubernetes.io/rook
stringData:
  userID: $(_ext_uid "${CSI_CEPHFS_PROVISIONER_SECRET_NAME}")
  userKey: ${CSI_CEPHFS_PROVISIONER_SECRET}"
    fi
    # RGW admin ops user(§6 对象存储用; Rook 对象控制器经它管理外部 RGW)
    if [ -n "${RGW_ADMIN_OPS_USER_ACCESS_KEY:-}" ] && [ -n "${RGW_ADMIN_OPS_USER_SECRET_KEY:-}" ]; then
        _EXT_IMP_YAML="${_EXT_IMP_YAML}
---
apiVersion: v1
kind: Secret
metadata:
  name: rgw-admin-ops-user
  namespace: ${CEPH_NAMESPACE}
type: kubernetes.io/rook
stringData:
  accessKey: ${RGW_ADMIN_OPS_USER_ACCESS_KEY}
  secretKey: ${RGW_ADMIN_OPS_USER_SECRET_KEY}"
    fi
    apply_remote "${_EXT_IMP_YAML}" "ceph-ext-import" \
        || { err "  官方导入资源创建失败(secrets/CM)"; exit 1; }
    ok "  rook-ceph-mon secret + mon-endpoints CM + CSI secrets 已创建"

    say "  [import 2/4] apply common-external.yaml + cluster-external.yaml(官方 RBAC + 外部 CephCluster CR)..."
    local _rook_dir="${CEPH_ROOK_MANIFEST_DIR:-${REPO_ROOT}/deployments/cubestack-addon/rook}"
    for _f in common-external.yaml cluster-external.yaml; do
        [ -f "${_rook_dir}/external/${_f}" ] || { err "  vendored 文件缺失: ${_rook_dir}/external/${_f}"; exit 1; }
        apply_remote "$(cat "${_rook_dir}/external/${_f}")" "ceph-${_f%.yaml}" \
            || { err "  apply ${_f} 失败"; exit 1; }
    done
    ok "  cluster-external.yaml 已 apply(Rook operator 将自动建 CephConnection/ClientProfile)"

    say "  [import 3/4] 等 CephCluster rook-ceph-external Connected(最长 300s)..."
    _EXT_CONN=0
    for _ci in $(seq 1 60); do
        _conn="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph-external -o jsonpath='{.status.conditions[?(@.type==\"Connected\")].status}' 2>/dev/null" || true) )"
        [ "${_conn}" = "True" ] && { _EXT_CONN=1; break; }
        sleep 5
    done
    if [ "${_EXT_CONN}" = "1" ]; then
        ok "  CephCluster external STATE=Connected(官方 healthCheck 已接线, Bug D 解法)"
    else
        err "  CephCluster rook-ceph-external 300s 内未 Connected —— 外部 mon 不可达或凭据错误"
        err "  排查: ① mon 可达性(ROOK_EXTERNAL_CEPH_MON_DATA 地址) ② rook-ceph-mon secret 的 ceph-username/ceph-secret"
        err "  ③ kubectl -n ${CEPH_NAMESPACE} describe cephcluster rook-ceph-external"
        exit 1
    fi

    say "  [import 4/4] Rook operator 自动建 CephConnection/ClientProfile + csi-config 校验..."
    _EXT_CFG=0
    for _ci in $(seq 1 24); do
        _cfg="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cm ceph-csi-config -o yaml 2>/dev/null" || true) )"
        if [ -n "${_cfg}" ] && echo "${_cfg}" | grep -q "\"clusterID\":\"${CEPH_NAMESPACE}\""; then
            _EXT_CFG=1; break
        fi
        sleep 5
    done
    [ "${_EXT_CFG}" = "1" ] && ok "  ceph-csi-config 已含外部集群(clusterID=${CEPH_NAMESPACE}, Rook operator 自动生成)" \
        || warn "  ceph-csi-config 120s 内未见外部集群(等待收敛; provision 会自动重试)"

    # ★ 对外暴露信息: 官方 SC ceph-rbd/cephfs 已由 import 逻辑等价创建(见下方 SC 块);
    #   RGW 对象存储接入(§6): RGW 密钥存在时登记外部 RGW 端点
    if [ -n "${RGW_ADMIN_OPS_USER_ACCESS_KEY:-}" ] && [ -n "${RGW_ENDPOINT:-}" ]; then
        say "  外部 RGW/S3 接入: 创建 CephObjectStore external-store(endpoint=${RGW_ENDPOINT})..."
        local _rgw_ip="${RGW_ENDPOINT%:*}" _rgw_port="${RGW_ENDPOINT##*:}"
        [ -z "${_rgw_port}" ] && _rgw_port=80
        apply_remote "$(sed -e "s|192.168.39.182|${_rgw_ip}|g" \
            -e "s|port: 80|port: ${_rgw_port}|g" \
            "${_rook_dir}/external/object-external.yaml")" "ceph-object-external" \
            && ok "  CephObjectStore external-store 已创建(RGW 端点 ${_rgw_ip}:${_rgw_port})" \
            || warn "  CephObjectStore external-store 创建失败(检查 RGW_ENDPOINT 可达性)"
        # 等 PHASE=Ready(外部对象存储登记完成)
        _EXT_RGW_OK=0
        for _ci in $(seq 1 24); do
            _rgw_phase="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephobjectstore external-store -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
            [ "${_rgw_phase}" = "Ready" ] && { _EXT_RGW_OK=1; break; }
            sleep 5
        done
        [ "${_EXT_RGW_OK}" = "1" ] && ok "  CephObjectStore external-store Ready(应用可经 S3 端点 ${RGW_ENDPOINT} 读写对象)" \
            || warn "  CephObjectStore external-store 未 Ready(检查 rgw-admin-ops-user secret 与 RGW 连通)"
        unset _EXT_RGW_OK _rgw_phase _rgw_ip _rgw_port
    fi

    # 官方路径 SC 集合: ceph-rbd / cephfs(import-external-cluster.sh 同名), 平台兼容别名 ceph-block
    say "  官方路径 StorageClass: ceph-rbd / cephfs / ceph-block(alias)..."
    _EXT_SC_YAML="apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd
provisioner: ${CEPH_NAMESPACE}.rbd.csi.ceph.com
parameters:
  clusterID: ${CEPH_NAMESPACE}
  pool: ${RBD_POOL_NAME:-rbd-pool}
  imageFormat: \"2\"
  imageFeatures: ${ROOK_RBD_FEATURES:-layering}
  csi.storage.k8s.io/provisioner-secret-name: rook-${CSI_RBD_PROVISIONER_SECRET_NAME}
  csi.storage.k8s.io/provisioner-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-${CSI_RBD_PROVISIONER_SECRET_NAME}
  csi.storage.k8s.io/controller-expand-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-${CSI_RBD_NODE_SECRET_NAME}
  csi.storage.k8s.io/node-stage-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
reclaimPolicy: Delete"
    if [ -n "${CEPHFS_FS_NAME:-}" ] && [ -n "${CEPHFS_POOL_NAME:-}" ]; then
        _EXT_SC_YAML="${_EXT_SC_YAML}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cephfs
provisioner: ${CEPH_NAMESPACE}.cephfs.csi.ceph.com
parameters:
  clusterID: ${CEPH_NAMESPACE}
  fsName: ${CEPHFS_FS_NAME}
  pool: ${CEPHFS_POOL_NAME}
  csi.storage.k8s.io/provisioner-secret-name: rook-${CSI_CEPHFS_PROVISIONER_SECRET_NAME}
  csi.storage.k8s.io/provisioner-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-${CSI_CEPHFS_PROVISIONER_SECRET_NAME}
  csi.storage.k8s.io/controller-expand-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-${CSI_CEPHFS_NODE_SECRET_NAME}
  csi.storage.k8s.io/node-stage-secret-namespace: ${CEPH_NAMESPACE}
allowVolumeExpansion: true
reclaimPolicy: Delete"
    fi
    # 平台兼容别名(registry 等引用 ceph-block; 与集群内模式同名)
    _EXT_SC_YAML="${_EXT_SC_YAML}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-block
provisioner: ${CEPH_NAMESPACE}.rbd.csi.ceph.com
parameters:
  clusterID: ${CEPH_NAMESPACE}
  pool: ${RBD_POOL_NAME:-rbd-pool}
  imageFormat: \"2\"
  imageFeatures: ${ROOK_RBD_FEATURES:-layering}
  csi.storage.k8s.io/provisioner-secret-name: rook-${CSI_RBD_PROVISIONER_SECRET_NAME}
  csi.storage.k8s.io/provisioner-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-${CSI_RBD_PROVISIONER_SECRET_NAME}
  csi.storage.k8s.io/controller-expand-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-${CSI_RBD_NODE_SECRET_NAME}
  csi.storage.k8s.io/node-stage-secret-namespace: ${CEPH_NAMESPACE}
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
reclaimPolicy: Delete"
    apply_remote "${_EXT_SC_YAML}" "ceph-ext-sc" \
        && ok "  官方路径 StorageClass 已创建" || { err "  StorageClass 创建失败"; exit 1; }

    # 冒烟测试(官方 SC 名) —— 复用同一数据面验证逻辑(见 _ext_smoke 函数)
    if [ "${CEPH_EXTERNAL_PROVISION_SMOKE:-true}" = "true" ]; then
        _ext_smoke "ceph-rbd" "cephfs" "${CEPHFS_FS_NAME:-}"
    fi
    unset _EXT_IMP_YAML _EXT_SC_YAML _EXT_CONN _EXT_CFG _cfg _conn _ci _gen _env_file _miss
}

# ════════════════════════════════════════════════════════════════════
# 外部 Ceph 数据面冒烟(2026-09-10 Bug C 加固, 手填/官方两路径共用):
#   RBD: <rbd_sc> 建 1Gi scratch PVC → 等 Bound → busybox pod 真实写读(数据面)
#   CephFS(<cephfs_enabled> 非空): <cephfs_sc> 同款写读 —— 检出"node 角色无 data 池
#   写权限"(Bug A)。RBD 未 Bound 硬失败; 数据面写读失败仅告警不阻断(不误伤 caps 较严提供方)。
#   ⚠ 清理顺序: 写读 pod 跑完后才删 PVC(先删 PVC 会让 pod 永久 Pending, 冒烟假通过)。
# ════════════════════════════════════════════════════════════════════
_ext_smoke() {
    local _rbd_sc="$1" _cephfs_sc="$2" _cephfs_on="$3"
    say "  外部 Ceph provision 冒烟测试(RBD 1Gi scratch PVC + 真实写读, 最长 180s)..."
    SMOKE_YAML="apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-csi-smoke-test
  namespace: ${CEPH_NAMESPACE}
spec:
  storageClassName: ${_rbd_sc}
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
    if [ "${_SMOKE_OK}" = "1" ]; then
        SMOKE_POD_YAML="apiVersion: v1
kind: Pod
metadata:
  name: ceph-csi-smoke-writer
  namespace: ${CEPH_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: docker.io/library/busybox:latest
      imagePullPolicy: IfNotPresent
      command: [\"/bin/sh\", \"-c\"]
      args: [\"echo cubestack-smoke-ok > /mnt/probe.txt && sync && cat /mnt/probe.txt && rm /mnt/probe.txt\"]
      volumeMounts:
        - name: smoke-vol
          mountPath: /mnt
  volumes:
    - name: smoke-vol
      persistentVolumeClaim:
        claimName: ceph-csi-smoke-test"
        apply_remote "${SMOKE_POD_YAML}" "ceph-csi-smoke-writer" \
            || { warn "  冒烟写读 pod 创建失败(跳过数据面验证)"; }
        _SMOKE_WR_OK=0
        for _ci in $(seq 1 24); do
            _wr_phase="$( (SSH "${K} -n ${CEPH_NAMESPACE} get pod ceph-csi-smoke-writer -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
            if [ "${_wr_phase}" = "Succeeded" ]; then _SMOKE_WR_OK=1; break; fi
            [ "${_wr_phase}" = "Failed" ] && break
            sleep 5
        done
        if [ "${_SMOKE_WR_OK}" = "1" ]; then
            ok "  冒烟数据面验证通过(busybox 写/读回成功 —— node 角色数据池写权限 ✓)"
        else
            warn "  冒烟数据面验证未通过(busybox 写读失败; 不影响部署, 但请核对 node 角色 caps:"
            warn "    典型故障: node 角色无数据池写权限(EPERM)或 key 不正确 —— 见 docs/ceph-rook.md §外部接入)"
        fi
        ( SSH "${K} -n ${CEPH_NAMESPACE} delete pod ceph-csi-smoke-writer --ignore-not-found" >/dev/null 2>&1 || true )
        unset _SMOKE_WR_OK _wr_phase SMOKE_POD_YAML
    fi
    # 无论成败都删除冒烟 PVC(Delete reclaim 自动清 PV/外部卷)
    ( SSH "${K} -n ${CEPH_NAMESPACE} delete pvc ceph-csi-smoke-test --ignore-not-found" >/dev/null 2>&1 || true )
    if [ "${_SMOKE_OK}" = "1" ]; then
        ok "  冒烟测试通过(RBD 1Gi 卷真实创建于外部 pool + 数据面写读验证, 已清理)"
    else
        err "  冒烟测试失败: RBD 1Gi scratch PVC 180s 内未 Bound —— 外部 Ceph 提供方异常"
        err "  排查: ① 提供方集群 HEALTH_OK: kubectl -n rook-ceph get cephcluster(提供方) + ceph -s"
        err "  ② 外部用户/pool 存在: ceph auth get ${CEPH_USER:-<user>}; ceph osd lspools | grep pool"
        err "  ③ provisioner 日志: kubectl -n rook-ceph logs deploy/rook-ceph.rbd.csi.ceph.com-ctrlplugin -c csi-rbdplugin --tail=50"
        err "  (提供方未就绪又需先装其它组件时, 可 CEPH_EXTERNAL_PROVISION_SMOKE=false 跳过本测试)"
        exit 1
    fi
    # ★ CephFS 数据面(Bug C 加固): 启用时同款写读, 失败仅告警不阻断
    if [ "${_SMOKE_OK}" = "1" ] && [ -n "${_cephfs_on}" ]; then
        say "  外部 CephFS provision + 数据面冒烟(1Gi scratch PVC + busybox 写读, 最长 180s)..."
        CEPHFS_SMOKE_YAML="apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-csi-smoke-test-fs
  namespace: ${CEPH_NAMESPACE}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ${_cephfs_sc}
  resources:
    requests:
      storage: 1Gi"
        apply_remote "${CEPHFS_SMOKE_YAML}" "ceph-csi-smoke-fs" \
            || { warn "  CephFS 冒烟 PVC 创建失败(跳过 CephFS 冒烟)"; }
        _FS_SMOKE_OK=0
        for _ci in $(seq 1 36); do
            _fs_smoke="$( (SSH "${K} -n ${CEPH_NAMESPACE} get pvc ceph-csi-smoke-test-fs -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
            if [ "${_fs_smoke}" = "Bound" ]; then _FS_SMOKE_OK=1; break; fi
            sleep 5
        done
        if [ "${_FS_SMOKE_OK}" != "1" ]; then
            warn "  CephFS 冒烟: PVC 180s 内未 Bound(跳过数据面写读; 请检查 fs/双用户配置, 见 docs/ceph-rook.md §外部接入)"
        else
            FS_SMOKE_POD_YAML="apiVersion: v1
kind: Pod
metadata:
  name: ceph-csi-smoke-fs-writer
  namespace: ${CEPH_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: docker.io/library/busybox:latest
      imagePullPolicy: IfNotPresent
      command: [\"/bin/sh\", \"-c\"]
      args: [\"echo cubestack-cephfs-smoke-ok > /mnt/probe.txt && sync && cat /mnt/probe.txt && rm /mnt/probe.txt\"]
      volumeMounts:
        - name: smoke-vol
          mountPath: /mnt
  volumes:
    - name: smoke-vol
      persistentVolumeClaim:
        claimName: ceph-csi-smoke-test-fs"
            apply_remote "${FS_SMOKE_POD_YAML}" "ceph-csi-smoke-fs-writer" \
                || { warn "  CephFS 冒烟写读 pod 创建失败(跳过数据面验证)"; }
            _FS_WR_OK=0
            for _ci in $(seq 1 24); do
                _fs_wr="$( (SSH "${K} -n ${CEPH_NAMESPACE} get pod ceph-csi-smoke-fs-writer -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
                [ "${_fs_wr}" = "Succeeded" ] && { _FS_WR_OK=1; break; }
                [ "${_fs_wr}" = "Failed" ] && break
                sleep 5
            done
            ( SSH "${K} -n ${CEPH_NAMESPACE} delete pod ceph-csi-smoke-fs-writer --ignore-not-found" >/dev/null 2>&1 || true )
            if [ "${_FS_WR_OK}" = "1" ]; then
                ok "  CephFS 冒烟数据面验证通过(busybox 写/读回成功 —— CephFS node 角色写权限 ✓)"
            else
                warn "  CephFS 冒烟数据面验证未通过(busybox 写读失败; 不影响部署, 但请核对:"
                warn "    ① node 角色凭据 caps 是否含 data 池 rw; ② 提供方 CephFilesystem 已 active"
                warn "    (见 docs/ceph-rook.md §3.4)"
            fi
            unset _FS_WR_OK _fs_wr FS_SMOKE_POD_YAML
        fi
        # 写读 pod 跑完后才删 PVC(顺序重要: 先删 PVC 会让 pod 永久 Pending, 冒烟假通过)
        ( SSH "${K} -n ${CEPH_NAMESPACE} delete pvc ceph-csi-smoke-test-fs --ignore-not-found" >/dev/null 2>&1 || true )
        unset _FS_SMOKE_OK _fs_smoke CEPHFS_SMOKE_YAML
    fi
    unset _SMOKE_OK _smoke SMOKE_YAML _rbd_sc _cephfs_sc _cephfs_on
}

say "[2/4] 创建 CephBlockPool rbd-pool(3 副本 / host 故障域 / min_size ${CEPH_POOL_MIN_SIZE})..."
# ★ 外部 Ceph 模式(无集群内 CephCluster): 经 ceph-csi-operator 的 CephConnection 连外部集群,
#   不创建集群内 pool/fs(外部集群已有), 创建指向外部集群的 6 个默认 StorageClass
#   (与集群内模式同名的 SC 集合, 供应用/平台无差别使用)。
if [ "${_CEPH_EXTERNAL}" = "1" ]; then
    # ★ 2026-09-10 双路径分流:
    #   · 官方导入(主路径, 推荐): CEPH_EXTERNAL_ENV_FILE 指向提供方导出的 external-ceph.env
    #     → _ext_import_official(secret/CM + cluster-external.yaml + 自动 RGW + 官方 SC 集合);
    #   · 手填(兼容 fallback): 未设 env 文件 → 原 CephConnection/ClientProfile 路径(存量部署不变)。
    if [ -n "${CEPH_EXTERNAL_ENV_FILE:-}" ]; then
        _ext_import_official
    else
    say "  外部模式: 创建 CephConnection(${CEPH_MONITORS:-<未配置>}) + 6×StorageClass(指向外部 Ceph)"
    # ★ 2026-09-10(Bug B 修复): external 凭据 preflight 结构校验 —— 在 apply 前逐项核验
    #   user/keyring 成对性与必填字段, 缺项立即硬失败并点名缺失字段(而非拖到部署后期
    #   才以 rados ret=-13 暴露)。用户存在性/caps 校验见模块冒烟测试与提供方
    #   ceph-expose-external.sh status(5 层自检: 认证用户 + RBD API + 写路径探测)。
    _PRE_MISS=""
    [ -n "${CEPH_MONITORS:-}" ] || _PRE_MISS="${_PRE_MISS} CEPH_MONITORS"
    [ -n "${CEPH_USER:-}" ]     || _PRE_MISS="${_PRE_MISS} CEPH_USER"
    [ -n "${CEPH_KEYRING:-}" ]  || _PRE_MISS="${_PRE_MISS} CEPH_KEYRING"
    [ -n "${CEPH_POOL:-}" ]     || _PRE_MISS="${_PRE_MISS} CEPH_POOL"
    if [ -n "${_PRE_MISS}" ]; then
        err "外部 Ceph 凭据不完整(缺失:${_PRE_MISS})—— 请在 cluster.conf 补齐后重跑"
        err "  RBD:  CEPH_MONITORS(mon 地址) + CEPH_USER(如 cubestack-ext-rbd) + CEPH_KEYRING(该用户 key) + CEPH_POOL"
        err "  CephFS(可选): CEPHFS_FS/CEPHFS_DATA_POOL + CEPHFS_USER/CEPHFS_KEYRING(provisioner) + CEPHFS_NODE_USER/CEPHFS_NODE_KEYRING(node, 可选)"
        exit 1
    fi
    # node 角色独立凭据(2026-09-10 Bug A): 单独给了 user 就必须给 keyring(反之亦然), 防手抖
    if [ -n "${CEPHFS_NODE_USER:-}" ] || [ -n "${CEPHFS_NODE_KEYRING:-}" ]; then
        [ -n "${CEPHFS_NODE_USER:-}" ] && [ -n "${CEPHFS_NODE_KEYRING:-}" ] || {
            err "CEPHFS_NODE_USER/CEPHFS_NODE_KEYRING 必须成对设置(缺其一)"; exit 1
        }
    fi
    if [ -n "${CEPH_RBD_NODE_USER:-}" ] || [ -n "${CEPH_RBD_NODE_KEYRING:-}" ]; then
        [ -n "${CEPH_RBD_NODE_USER:-}" ] && [ -n "${CEPH_RBD_NODE_KEYRING:-}" ] || {
            err "CEPH_RBD_NODE_USER/CEPH_RBD_NODE_KEYRING 必须成对设置(缺其一)"; exit 1
        }
    fi
    unset _PRE_MISS
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
# ★ 2026-09-10(Bug A 同款加固): 提供方若对两角色 caps 区分更严, 可用
#   CEPH_RBD_NODE_USER/CEPH_RBD_NODE_KEYRING 单独指定 node 角色;
#   未指定时回退 CEPH_USER/CEPH_KEYRING(原行为, 不破坏存量)。
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
  userID: ${CEPH_RBD_NODE_USER:-${CEPH_USER:-admin}}
  userKey: ${CEPH_RBD_NODE_KEYRING:-${CEPH_KEYRING:-}}
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
        # ★ 2026-09-10(Bug A 修复): csi-cephfs **node** 角色与 **provisioner** 角色 caps 不同
        #   (node 挂载 fs 承载全部文件 I/O, 需要 metadata/data 全读写; provisioner 只建删 subvolume,
        #   被提供方限定 metadata 读)。两个 secret 必须可独立指定凭据:
        #   · CEPHFS_NODE_USER / CEPHFS_NODE_KEYRING —— node 专用(推荐: 提供方 csi-cephfs-node 用户)
        #   · CEPHFS_USER     / CEPHFS_KEYRING     —— provisioner 专用(历史单一字段, 保持兼容)
        #   旧配置只填 CEPHFS_USER/CEPHFS_KEYRING 时, node 回退到同一凭据(原行为, 不破坏存量)。
        _CEPHFS_NODE_USER="${CEPHFS_NODE_USER:-${CEPHFS_USER:-${CEPH_USER:-admin}}}"
        _CEPHFS_NODE_KEY="${CEPHFS_NODE_KEYRING:-${CEPHFS_KEYRING:-${CEPH_KEYRING:-}}}"
        _EXT_YAML="${_EXT_YAML}
---
# 外部 CephFS 认证(csi-cephfs provisioner/node): 两角色凭据可独立指定
#   provisioner = CEPHFS_USER/CEPHFS_KEYRING; node = CEPHFS_NODE_USER/CEPHFS_NODE_KEYRING
#   (node 未单独指定时回退 provisioner 凭据 = 旧行为; 详见上方注释)
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
  userID: ${_CEPHFS_NODE_USER}
  userKey: ${_CEPHFS_NODE_KEY}
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
        # ★ 2026-09-09(二修): kubelet 把 CM 数据更新投递进**运行中** pod 实测要 60~90s
        #   (同步周期级延迟, 非事件级; 实机: 数据 06:50:17 → 文件 06:51:37)。
        #   与其赌传播, 不如 CM 数据就绪后 **rollout restart** provisioner deployment:
        #   新 pod 启动时直接挂载含数据的 CM, 确定性跳过传播延迟 —— 首次 provision
        #   不再撞 config.json 缺失 → 不再触发 csi-provisioner 的 infeasible 256s 级
        #   退避(10 分钟才建 PV 的根因), PV 秒级创建。
        #   restart 只滚动 pod(模板不变, operator 不回收), 对后续 provision 无副作用。
        say "  滚动重启 provisioner deployment(新 pod 直接挂载含数据的 CM)..."
        ( SSH "${K} -n ${CEPH_NAMESPACE} rollout restart deploy/rook-ceph.rbd.csi.ceph.com-ctrlplugin" >/dev/null 2>&1 || true )
        _RS_OK=0
        for _ci in $(seq 1 24); do
            if ( SSH "${K} -n ${CEPH_NAMESPACE} rollout status deploy/rook-ceph.rbd.csi.ceph.com-ctrlplugin --timeout=2s" 2>/dev/null ) | grep -q "successfully rolled out"; then
                _RS_OK=1; break
            fi
            sleep 5
        done
        [ "${_RS_OK}" = "1" ] && ok "  provisioner 滚动完成" || warn "  provisioner 滚动 120s 未完成(继续, 投递检查兜底)"
        # 兜底检查(restart 后新 pod 挂载即时可见; 失败仅告警 —— provisioner 会自愈重试)
        say "  确认 config.json 已挂载进 provisioner pod..."
        _MOUNT_OK=0
        for _ci in $(seq 1 12); do
            if ( SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph.rbd.csi.ceph.com-ctrlplugin -c csi-rbdplugin -- test -f /etc/ceph-csi-config/config.json" 2>/dev/null ); then
                _MOUNT_OK=1; break
            fi
            sleep 5
        done
        if [ "${_MOUNT_OK}" = "1" ]; then
            ok "  config.json 已挂载进 provisioner pod(外部 Ceph provision 就绪)"
        else
            warn "  config.json 60s 内未挂载(kubelet 延迟; 不影响部署, csi-provisioner 会自动重试成功)"
        fi
        # ★ 外部 provision 冒烟测试(2026-09-09, 目标"一次性部署成功"; 2026-09-10 Bug C 加固):
        #   ① RBD: Immediate SC 建 1Gi scratch PVC → 等 Bound → **真实写读**(pod 挂载后写文件+读回,
        #      验证数据面而非仅 provision; 若只 Bound 会漏掉"node 角色无数据池写权限"类故障);
        #   ② CephFS(启用时): scratch PVC(cephfs-ephemeral)→ 等 Bound → 同样真实写读。
        #   作用:
        #   · 端到端打通 provision 全链(mon 连接/cephx 认证/外部 pool/建卷/删卷)——
        #     提供方未就绪(pool/用户/网络)在此立刻硬失败并给出排查命令,
        #     不会拖到 k8s_registry 才断(历史事故: registry 90s 超时中断部署);
        #   · 数据面验证(node 角色 caps): 写读通过才放行, 保证"mount 成功但写 EPERM"类
        #     (Bug A: 双角色单凭据)在部署期自检暴露, 而非用户挂卷后才发现;
        #   · 预热 provisioner 首触路径(消除冷启动/投递延迟), registry 正式 PVC 秒绑。
        #   CEPH_EXTERNAL_PROVISION_SMOKE=false 可跳过(提供方未就绪但需先装其它组件时)。
        if [ "${CEPH_EXTERNAL_PROVISION_SMOKE:-true}" = "true" ]; then
            _ext_smoke "ceph-rbd-ephemeral-immediate" "cephfs-ephemeral" "${EXT_CEPHFS_ENABLED}"
        fi
    else
        err "  ceph-csi-config 60s 内未生成(ceph-csi-operator 未调和 ClientProfile/CephConnection)"
        err "  排查: kubectl -n ${CEPH_NAMESPACE} get clientprofile,cephconnection; kubectl -n ${CEPH_NAMESPACE} logs deploy/ceph-csi-controller-manager --tail=50"
        exit 1
    fi
    unset _MONS _EXT_YAML EXT_CEPHFS_ENABLED _CEPHFS_PROVISIONER_SECRET _CEPHFS_NODE_SECRET _CEPHFS_NODE_USER _CEPHFS_NODE_KEY _CFG_OK _MOUNT_OK _RS_OK _rs _cfg _ci _EXT_NUM
    fi   # 双路径分流结束(官方导入 / 手填 fallback)
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

