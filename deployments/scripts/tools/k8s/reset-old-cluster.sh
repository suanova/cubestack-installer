#!/bin/bash
# ============================================================
# reset-old-cluster.sh —— 覆盖安装前: 检测并(可选)清除节点上的旧集群残留
#
# 为什么需要(2026-09-28 实机): 默认全量运行只清**本仓库的断点状态**; 节点上残留上一代集群时,
# kubespray 会按【升级】处理, 撞两道**上游硬闸**:
#   ① etcd 版本闸: roles/etcd/tasks/clean_v2_store.yml:12 —— 读的是 **etcd 二进制 --version**
#      (install_host.yml:24), 所以**只删数据、留着旧二进制**照样会被拦;
#   ② kubeadm 不允许跨小版本(如 1.32→1.35)。
#   ⇒ 覆盖安装 = 先清旧集群(reset), 再全量部署。
#
# 判定"有旧集群残留"的证据(任一成立即算, 均为**只读探测**):
#   · 首个 master 上 kube-apiserver 静态 Pod 的镜像小版本 ≠ cluster.conf 的 K8S_VERSION;
#   · 首个 master 上残留 /usr/local/bin/{etcd,etcdctl,kubeadm,kubelet} 或 /etc/etcd.env
#     (数据目录/服务可能已不在, 但二进制残留就足以再次触发 etcd 版本闸)。
#
# 用法:
#   reset-old-cluster.sh --dry-run          # 只检测+打印计划(默认; 不做任何改动)
#   reset-old-cluster.sh --yes              # 检测到残留就**执行** reset(非交互/自动化用)
#   reset-old-cluster.sh                    # 交互: 检测到残留时 15s 倒计时(ctrl-c 可中止)
# 退出码: 0=无需处理或已处理; 1=有残留但未处理(未给 --yes 且非交互); 2=探测不到(未知)
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

DRY=0; YES=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --yes|-y)  YES=1 ;;
        *) err "未知参数: $a(见脚本头用法)"; exit 1 ;;
    esac
done

_ssh_p() {  # _ssh_p <ip> <cmd>   —— 只读探测
    ssh -i "${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}" \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${SSH_USER:-ubuntu}@${1}" "$2" 2>/dev/null
}

FM_IP="$(first_master_ip 2>/dev/null || true)"
[ -n "${FM_IP}" ] || { warn "取不到首个 master(集群不可达?)—— 跳过旧集群检测"; exit 2; }

# ---- 证据 1: 在跑的 apiserver 小版本 vs 目标 ----
_cur_k8s="$(_ssh_p "${FM_IP}" "sudo grep -m1 -o 'kube-apiserver:v[0-9.]*' /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null | head -1" || true)"
_cur_xy=''; _tgt_xy=''
[ -n "${_cur_k8s}" ] && { _cur_xy="${_cur_k8s##*:v}"; _cur_xy="${_cur_xy%.*}"; }
[ -n "${K8S_VERSION:-}" ] && { _tgt_xy="${K8S_VERSION#v}"; _tgt_xy="${_tgt_xy%.*}"; }

# ---- 证据 2: 集群没在跑时, 按**已装二进制的版本**判定(2026-09-28 修正) ----
# ⚠ 曾经的判据是"存在 /usr/local/bin/{etcd,kubeadm,...} 就算残留" —— **错的**: 任何**健康集群**
#   都装着这些二进制 ⇒ 会把刚装好的**同版本**集群误判成残留并 reset(自毁按钮)。现改为**只按版本**判:
#     · 集群在跑      → 比 apiserver 小版本(证据 1);
#     · 集群没在跑    → 问 `kubeadm version`; 它与目标不同才算残留;
#     · 都没有 kubeadm 但残留集群文件 → 算残留(半拆状态);
#     · 其它          → 干净, 不重置(与目标版本一致的二进制只是"装好的集群", 不是残留)。
#   二进制/`/etc/etcd.env` 的存在只作**补充信息**打印, 不单独构成 reset 理由。
_left="$(_ssh_p "${FM_IP}" "ls -d /usr/local/bin/etcd /usr/local/bin/etcdctl /usr/local/bin/kubeadm /usr/local/bin/kubelet /etc/etcd.env 2>/dev/null || true" || true)"
_cur_kubeadm="$(_ssh_p "${FM_IP}" "sudo /usr/local/bin/kubeadm version -o short 2>/dev/null | head -1" || true)"
_ka_xy=""
[ -n "${_cur_kubeadm}" ] && { _ka_xy="${_cur_kubeadm#v}"; _ka_xy="${_ka_xy%.*}"; }

_needs=0; _why=()
if [ -n "${_cur_xy}" ]; then
    if [ -n "${_tgt_xy}" ] && [ "${_cur_xy}" != "${_tgt_xy}" ]; then
        _needs=1; _why+=("节点上在跑 kube-apiserver v${_cur_xy}, 目标是 v${_tgt_xy}(跨小版本 ⇒ kubeadm 不允许跳)")
    fi
elif [ -n "${_ka_xy}" ]; then
    if [ -n "${_tgt_xy}" ] && [ "${_ka_xy}" != "${_tgt_xy}" ]; then
        _needs=1; _why+=("集群未运行, 但已装 kubeadm ${_cur_kubeadm}(≠ 目标 v${_tgt_xy}) ⇒ 旧集群残留")
    fi
elif [ -n "${_left}" ]; then
    _needs=1; _why+=("集群未运行且无 kubeadm, 但残留集群文件: $(echo "${_left}" | tr '\n' ' ')")
fi
# 补充信息(仅当已判定要 reset 时打印)
if [ "${_needs}" = "1" ] && [ -n "${_left}" ]; then
    _why+=("(补充)残留文件: $(echo "${_left}" | tr '\n' ' ')")
fi

if [ "${_needs}" = "0" ]; then
    ok "无需处理: 首个 master(${FM_IP})上没有**旧版本**残留(apiserver=${_cur_xy:-未运行}/kubeadm=${_cur_kubeadm:-无}/目标=${_tgt_xy:-未知}) —— 直接部署即可"
    exit 0
fi

echo "────────────────────────────────────────────────────────────"
warn "检测到旧集群残留(${FM_IP}):"
for w in "${_why[@]}"; do echo "      · ${w}"; done
echo "      跨版本/带旧二进制的集群若直接部署, kubespray 会按【升级】处理并硬失败(etcd 3.5→3.6 闸 + 跨小版本闸)。"
echo "────────────────────────────────────────────────────────────"
echo "  处理 = 清除**全部节点**(inventory 决定)上的旧集群:"
echo "      · etcd 数据目录 + etcd/kubelet/containerd 服务与配置 + 旧二进制"
echo "      · /etc/kubernetes(证书、kubeconfig、静态 Pod 清单)"
echo "      · 全部 CRI 容器与 Pod —— 该集群工作负载一并消失, **不可恢复**"
echo "      (ceph 的 OSD 数据盘不在范围内, 由 CEPH_PRE_CLEANUP_EXISTING 那套单独管)"
echo "────────────────────────────────────────────────────────────"

if [ "${DRY}" = "1" ]; then
    say "(--dry-run: 只报告, 不做任何改动。要执行: 本工具加 --yes, 或照上面手跑 reset)"
    exit 0
fi
if [ "${YES}" != "1" ]; then
    if [ ! -t 0 ]; then
        err "非交互环境且未给 --yes —— 拒绝执行 reset(避免无人值守时误清集群)"
        err "  确认要覆盖安装时: 本工具加 --yes, 或用 deploy-cluster.sh --yes"
        exit 1
    fi
    _t=15
    while [ "${_t}" -gt 0 ]; do
        printf '\r    ⚠ %d 秒后开始清除(ctrl-c 可中止)...' "${_t}"
        sleep 1; _t=$((_t - 1))
    done
    printf '\r\033[K'
fi

OFFLINE_SCRIPT="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
[ -f "${OFFLINE_SCRIPT}" ] || { err "未找到 ${OFFLINE_SCRIPT}"; exit 1; }
say "执行覆盖安装前置: 清除旧集群(reset)..."
bash "${OFFLINE_SCRIPT}" reset "${CLUSTER_NAME}" --yes || { err "reset 失败"; exit 1; }
ok "旧集群已清除 —— 后续部署将是**全新安装**(不再走升级路径)"
exit 0
