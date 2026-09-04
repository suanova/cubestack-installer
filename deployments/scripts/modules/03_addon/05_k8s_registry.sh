#!/bin/bash
# ============================================================
# MODULE: k8s_registry
# DESC: 配置集群内置 docker registry addon(节点 hosts + containerd certs.d; REGISTRY_EXPOSE_HOST=1 时可选宿主机对外 DNAT)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: REGISTRY_ENABLED
# 说明:
#   · 集群内 registry(kubespray addon), **默认部署**(REGISTRY_ENABLED 默认 1/true)
#   · 对**已部署**集群幂等配置内置 registry, 需集群就绪后显式执行
#   · 启用方式: deploy-cluster.sh --enable k8s_registry 或 REGISTRY_ENABLED=true
#   · 集群外镜像仓库 Harbor 为预留配置(modules/01_env/04_harbor.sh, 未来实现, 默认关闭)
#   · 复用 deploy-registry.sh: 各节点 /etc/hosts 解析 REGISTRY_DOMAIN → REGISTRY_IP(MetalLB VIP),
#     containerd certs.d 信任该 HTTP registry; REGISTRY_EXPOSE_HOST=1 时配宿主机 DNAT 对外 push 入口(默认 0 只用 VIP)
#   · REGISTRY_ENABLED 控制 addons.yml 中 registry addon 是否安装(见 sync-addons-config.sh)
#   · 后端存储 + 就绪等待(重要): REGISTRY_STORAGE_CLASS 决定 registry 数据盘后端:
#       · local-path(默认)→ k8s 阶段 local-path SC 已存在, PVC 即时绑定;
#       · ceph-block → registry-pvc 在 k8s 阶段创建时 SC 尚未出现 → Pending; ceph_csi 模块
#         创建 SC 后自动绑定(WaitForFirstConsumer)。本模块部署后**必须等待 PVC Bound + pod Ready**,
#         否则后续 push 镜像的模块(gpu_operator/envoy/...)会 ImagePullBackOff 且难以定位。
#     ⚠ 顺序保证: addon 阶段按文件序号执行 metallb→ceph→ceph_csi→local_path→registry;
#       ceph/ceph_csi 模块已内置"等集群 Ready / CSI 就绪"的等待。本模块额外等 registry 自身 Ready。
# 数据源: cluster.conf (REGISTRY_DOMAIN / REGISTRY_IP / REGISTRY_PORT / REGISTRY_STORAGE_CLASS / CEPH_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关: 默认不部署, REGISTRY_ENABLED=1/true 或 --steps/--enable 显式启用
if [ "${REGISTRY_ENABLED:-0}" != "1" ] && [ "${REGISTRY_ENABLED:-false}" != "true" ]; then
    say "跳过内置 registry(集群内 registry 默认不部署, 配置 REGISTRY_ENABLED=true 可启用)"
    exit 0
fi

# 前置校验: registry 后端指定 ceph 但 Ceph 未启用 → PVC 永久 Pending, 直接中止给出指引
if [ -n "${REGISTRY_STORAGE_CLASS:-}" ] && [ "${REGISTRY_STORAGE_CLASS}" != "local-path" ] \
    && [ "${CEPH_ENABLED:-false}" != "true" ]; then
    err "REGISTRY_STORAGE_CLASS=${REGISTRY_STORAGE_CLASS} 但 CEPH_ENABLED!=true: registry 的 PVC 将永远 Pending"
    err "  请任选其一: ① cluster.conf 设 CEPH_ENABLED=true(并先准备 ceph 离线镜像/裸盘, 见 docs/ceph-rook.md);"
    err "  ② 改回 REGISTRY_STORAGE_CLASS=local-path"
    exit 1
fi

say "配置集群内置 docker registry(域名=${REGISTRY_DOMAIN:-registry.cubestack.io})..."
if [ -n "${REGISTRY_STORAGE_CLASS:-}" ] && [ "${REGISTRY_STORAGE_CLASS}" != "local-path" ]; then
    say "  后端存储: REGISTRY_STORAGE_CLASS=${REGISTRY_STORAGE_CLASS}(PVC 由 kubespray 在 k8s 阶段创建, 等该 SC 出现后自动绑定)"
fi
# ★ K/SSH/FIRST_MASTER 定义(远端 kubectl): 本模块在"就绪等待"用 SSH "${K}" 轮询 PVC/pod。
#   这些变量其他模块(metallb/ceph)在各自文件内定义, 不会跨模块可见 —— 必须在本文件定义,
#   否则 set -u 下裸引用 unbound → 部署成功(registry 已部署)后模块崩溃(本次事故根因)。
FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"
bash "${SCRIPT_DIR}/tools/lb/deploy-registry.sh"

# ---------------- 就绪等待(关键) ----------------
# registry pod 就绪前, 后续 push 镜像的模块(gpu_operator/envoy/...)会 ImagePullBackOff 且难定位。
# ceph-block 后端: registry-pvc 在 k8s 阶段创建时 SC 未出现 → Pending, ceph_csi 模块创建
# ceph-block SC 后(WaitForFirstConsumer)由首个消费者触发 RBD 卷创建/挂载, 需要额外时间。
# 就绪判定(任一层不可跳): ① PVC 已 Bound ② registry pod 1/1 Running ③ registry Service 暴露且 /v2/ 可达。
# 超时: 默认 600s(10 分钟), 覆盖首次 RBD 卷创建 + 镜像下载; CEPH/大镜像环境可 REGISTRY_WAIT_SECONDS 调整。
# ⚠ set -u 安全: 必须无条件赋默认值 —— `${VAR:-600}` 在 [ ] 判断里展开为 600 后判断为真,
#   `|| VAR=600` 永不执行 → VAR 从未赋值 → 后续裸引用 unbound(曾致模块在部署成功后崩溃)。
REGISTRY_WAIT_SECONDS="${REGISTRY_WAIT_SECONDS:-600}"
_READY=0
for _i in $(seq 1 $((REGISTRY_WAIT_SECONDS / 10))); do
    _pc="$( (SSH "${K} -n kube-system get pvc registry-pvc -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
    if [ -z "${_pc}" ] || [ "${_pc}" != "Bound" ]; then
        [ "$((_i % 6))" -eq 0 ] && say "  registry-pvc 未 Bound(当前 ${_pc:-<无>}, 等 ${REGISTRY_STORAGE_CLASS:-local-path} SC 供给), 等待第 ${_i}/$((REGISTRY_WAIT_SECONDS / 10)) 次 ..."
        sleep 10; continue
    fi
    _pod="$( (SSH "${K} -n kube-system get pod -l k8s-app=registry -o jsonpath='{.items[0].status.phase}' 2>/dev/null" || true) )"
    _rdy="$( (SSH "${K} -n kube-system get pod -l k8s-app=registry -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null" || true) )"
    if [ "${_pod}" = "Running" ] && [ "${_rdy}" = "true" ]; then
        _base=""; [ "${SERVICE_EXPOSE_MODE:-nodeport}" = "nodeport" ] && _base="http://${FIRST_MASTER:-localhost}:${REGISTRY_NODEPORT:-31148}" || _base="http://${REGISTRY_IP:-localhost}:${REGISTRY_PORT:-5000}"
        if curl -s -m 5 "${_base}/v2/" >/dev/null 2>&1; then _READY=1; break; fi
    fi
    [ "$((_i % 6))" -eq 0 ] && say "  registry pod 未就绪(${_pod:-<无>}/${_rdy:-<无>}), 等待第 ${_i}/$((REGISTRY_WAIT_SECONDS / 10)) 次 ..."
    sleep 10
done
if [ "${_READY}" = "1" ]; then
    ok "  registry 就绪: PVC ${_pc} / pod Running / ${_base}/v2/ 可达"
else
    err "  registry 未在 ${REGISTRY_WAIT_SECONDS}s 内就绪 —— 后端 ${REGISTRY_STORAGE_CLASS:-local-path}"
    err "  排查: kubectl -n kube-system get pvc,pods | grep registry(ceph-block: 先确认 ceph_csi 已建 SC ceph-block; 检查 rbd 卷创建, 见 docs/ceph-rook.md §8)"
    exit 1
fi

ok "内置 registry 配置完成"
