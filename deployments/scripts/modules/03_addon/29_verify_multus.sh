#!/bin/bash
# ============================================================
# MODULE: verify_multus
# DESC: 端到端验证 Multus CNI 真正工作(非仅 DaemonSet Running):
#       ① kube-multus-ds pod 全 Running + /etc/cni/net.d/00-multus.conf 存在
#       → ② NAD CRD 注册 + 目标示例 NAD 存在
#       → ③ 创建官方 samplepod(注解 k8s.v1.cni.cncf.io/networks)并等待 Running
#       → ④ exec ip a 断言 net1 附加接口出现 + network-status 注解含示例网络
#       → ⑤ 清理测试资源(trap 兜底)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: multus
# 说明:
#   · **验证模块不设 TOGGLE**(否则 MULTUS_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_multus 在安装后单个执行。
#   · **门禁看实际部署, 不看配置开关**(仿 verify_lws): 只要 kube-multus-ds 实际在跑
#     就验证(无论 MULTUS_ENABLED true/false, 例如 --steps multus 单独部署过);
#     仅当"DaemonSet 不在 且 MULTUS_ENABLED≠true"才跳过。
#   · 验证依赖 macvlan 示例 NAD(模块 09_multus 默认创建); 若被删/改名, 用集群真实
#     NAD 名覆盖 MULTUS_NAD_NAME 再跑, 或先重跑 --steps multus 重建示例网络。
# 数据源: cluster.conf (MULTUS_NAD_NAME / MULTUS_MASTER_IFACE / NODES / SSH_KEY_NAME)
# 用法: sudo ./deploy-cluster.sh --steps verify_multus
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

NAD_NAME="${MULTUS_NAD_NAME:-multus-nad}"
NAD_NS="${MULTUS_NAD_NAMESPACE:-kube-system}"
TEST_NS="default"
TEST_POD="multus-verify-sample"
TEST_IMAGE="busybox"
TEST_IMAGE_REF=""
# 例: 模块 09_multus 建在 kube-system; 测试 pod 在 default, 注解需带 namespace 前缀
NAD_ANNOTATION="${NAD_NS}/${NAD_NAME}"

# ---- 门禁: 以实际部署为准(DaemonSet 是否在跑) ----
DEPLOYED="$( (SSH "${K}" -n kube-system get ds kube-multus-ds --no-headers 2>/dev/null || true) | wc -l )"
if [ "${DEPLOYED:-0}" -eq 0 ] && [ "${MULTUS_ENABLED:-false}" != "true" ]; then
    say "Multus 未部署(DaemonSet 不存在且 MULTUS_ENABLED≠true), 跳过验证(先 --steps multus 部署)"
    exit 0
fi

cleanup() {
    # 清理测试 pod(幂等; trap 兜底保证不残留)
    SSH "${K}" -n ${TEST_NS} delete pod ${TEST_POD} --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

say "Verify Multus: DaemonSet → NAD → 测试 pod 附加接口(net 接口真实出现?)..."

say "  ① 检查 kube-multus-ds pod 全 Running + 节点 00-multus.conf..."
_NRUN="$( (SSH "${K}" -n kube-system get pods -l name=multus --no-headers 2>/dev/null || true) | awk '$3=="Running"{n++} END{print n+0}' )"
_NTOT="$( (SSH "${K}" -n kube-system get pods -l name=multus --no-headers --ignore-not-found 2>/dev/null || true) | wc -l )"
[ "${_NRUN:-0}" -ge 1 ] || { err "kube-multus-ds 无 Running pod(${_NRUN}/${_NTOT}); 检查镜像拉取/privileged 状态"; exit 1; }
ok "    multus pod Running ${_NRUN}/${_NTOT} ✓"
# 00-multus.conf: 在首个 master 上检查自动生成的 Multus 主配置
_CNI_CONF="$(SSH "sudo ls /etc/cni/net.d/00-multus.conf 2>/dev/null" || true)"
[ -n "${_CNI_CONF}" ] && ok "    节点已生成 /etc/cni/net.d/00-multus.conf ✓" \
    || warn "    未在首个 master 找到 /etc/cni/net.d/00-multus.conf(等 DaemonSet 初始化后再查)"

say "  ② 检查 NAD CRD + 目标示例 NAD..."
_CRD="$(SSH "${K}" get crd network-attachment-definitions.k8s.cni.cncf.io --no-headers 2>/dev/null || true)"
[ -n "${_CRD}" ] && ok "    NAD CRD 已注册 ✓" || { err "NAD CRD 未注册(multus DaemonSet 未正常初始化)"; exit 1; }
_NAD="$(SSH "${K}" -n ${NAD_NS} get networkattachmentdefinitions ${NAD_NAME} --no-headers 2>/dev/null || true)"
[ -n "${_NAD}" ] && ok "    示例 NAD ${NAD_NS}/${NAD_NAME} 存在 ✓" \
    || { err "示例 NAD ${NAD_NS}/${NAD_NAME} 不存在(先 --steps multus 重建, 或设 MULTUS_NAD_NAME 指向已有 NAD)"; exit 1; }

say "  ③ 创建测试 pod(${TEST_POD}; 注解 networks=${NAD_ANNOTATION})并等待 Running..."
# 镜像: 优先本地 registry(离线可用); 不额外推 busybox —— 用 ensure_registry_nginx? 不, 走集群已有镜像
#   直接用默认 busybox(若节点含 containerd 预加载过)或 registry 里的 busybox。
#   ★ 2026-09-14: 官方 quickstart 用 alpine, 本项目节点 containerd 已预载 busybox(见
#     PRELOAD_IMAGE_PATTERNS), 用 busybox 即可; 若拉不到自动重试。
SSH "${K}" -n ${TEST_NS} delete pod ${TEST_POD} --ignore-not-found --wait=false >/dev/null 2>&1 || true
sleep 2
SSH "${K} -n ${TEST_NS} apply -f -" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  annotations:
    k8s.v1.cni.cncf.io/networks: ${NAD_ANNOTATION}
spec:
  containers:
  - name: ${TEST_POD}
    command: ["/bin/sh", "-c", "trap : TERM INT; sleep infinity & wait"]
    image: ${TEST_IMAGE}
EOF
_POD_RUNNING=0
for _i in $(seq 1 36); do
    _st="$(SSH "${K}" -n ${TEST_NS} get pod ${TEST_POD} -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "${_st}" = "Running" ] && { _POD_RUNNING=1; break; }
    _st2="$(SSH "${K}" -n ${TEST_NS} get pod ${TEST_POD} -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || true)"
    if echo "${_st2}" | grep -q "ImagePullBackOff\|ErrImage"; then
        err "测试 pod 镜像拉取失败(${_st2}); 检查 ${TEST_IMAGE} 在节点 containerd 是否预载"; exit 1;
    fi
    sleep 5
done
[ "${_POD_RUNNING}" = "1" ] || { err "测试 pod 60s 内未 Running(检查多网卡 CNI 调用 / kubelet 日志)"; exit 1; }
ok "    测试 pod Running ✓"

say "  ④ 断言附加接口 net 存在 + network-status 注解..."
# 从首个 master exec: 容器 bridge 网络到不了 pod overlay IP, 必须经 SSH 到节点(kubectl exec 走 apiserver→kubelet)
_NET_IFACE="$(SSH "${K}" -n ${TEST_NS} exec ${TEST_POD} -- ip -o link show 2>/dev/null || true | grep -oE '^[0-9]+: net[0-9]+' || true)"  # net1/net2...
if [ -n "${_NET_IFACE}" ]; then
    ok "    附加接口出现: $(echo "${_NET_IFACE}" | head -1) ✓"
else
    _IFACES="$(SSH "${K}" -n ${TEST_NS} exec ${TEST_POD} -- ip -o link show 2>/dev/null || true)"
    if [ -n "${_IFACES}" ]; then
        warn "    pod 内接口: $(echo "${_IFACES}" | awk '{print $2}' | tr '\n' ' ') 未含 net(检查 NAD config / master 网卡是否存在)"
        exit 1
    fi
    err "    exec ip a 无输出(容器无法执行 ip 命令?)"; exit 1
fi
# network-status 注解: kubectl describe 含 k8s.v1.cni.cncf.io/network-status 且含示例网络
_NSTATUS="$(SSH "${K}" -n ${TEST_NS} get pod ${TEST_POD} -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' 2>/dev/null || true)"
echo "${_NSTATUS}" | grep -q "${NAD_NAME}" && ok "    network-status 注解含 ${NAD_NAME} ✓" \
    || warn "    network-status 注解未见 ${NAD_NAME}(CNI 元数据可能未写, 但 net 接口已出现)"

echo "---------------------------------------------"
ok "Multus 验证通过: DaemonSet → NAD → pod 附加接口(${_NET_IFACE})全链可用"
echo "  清理: 测试 pod 已自动删除; 示例网络保留(kubectl -n ${NAD_NS} get networkattachmentdefinitions ${NAD_NAME})"
unset _NRUN _NTOT _CRD _NAD _POD_RUNNING _NET_IFACE _NSTATUS _IFACES _st _st2 _i
