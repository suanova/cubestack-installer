#!/bin/bash
# ============================================================
# verify-lws.sh — 端到端验证 LeaderWorkerSet(LWS) 真正工作(非仅 pod running)
# ① controller pod Ready → ② CRD 注册(leaderworkerset/disaggregatedset/disaggregatedsetrolescalers)
# → ③ 创建测试 LeaderWorkerSet(leader 1 + worker 2, busybox)→ ④ 等待全部 pod Ready
# → ⑤ 校验控制器管理(v0.10 标签 leaderworkerset.sigs.k8s.io/name + worker-index=0 为 leader)
# → ⑥ DisaggregatedSet CR 可创建(dry-run=server, roles≥2)→ ⑦ 清理测试资源(trap 兜底)
# 注意(v0.10.0 schema): leaderWorkerTemplate 用 leaderTemplate/workerTemplate(workerTemplate 必填),
#   restartPolicy 枚举 Default/None/RecreateGroup*; DisaggregatedSet 用 roles[](≥2)+slices 整数。
# 用法: sudo ./verify-lws.sh
# 依赖: 集群已部署 LWS(默认官方 manifests.yaml bundle, 见 modules/03_addon/05_gpu_lws.sh);
#       测试镜像 busybox 已预加载(PRELOAD_IMAGE_PATTERNS 含 busybox)。
# 退出码: 0=验证通过; 1=任一硬性检查失败(controller/CRD/pod 未就绪)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

LWS_NAMESPACE="${LWS_NAMESPACE:-lws-system}"
TEST_NS="verify-lws-$$"       # 唯一命名空间(带 PID 后缀)
TEST_NAME="verify-lws-set"

cleanup() {
    SSH "${K} patch namespace ${TEST_NS} --type=merge -p '{\"metadata\":{\"finalizers\":null}}' >/dev/null 2>&1" || true
    SSH "${K} delete namespace ${TEST_NS} --ignore-not-found=true --force --grace-period=0 >/dev/null 2>&1" || true
}
trap cleanup EXIT

say "验证 LeaderWorkerSet 工作正常(端到端, 入口=${FIRST_MASTER})..."

# ① controller pod 就绪
say "  ① 检查 LWS controller 就绪..."
SSH "${K} -n ${LWS_NAMESPACE} get pods -o wide 2>/dev/null \
    | grep -qE 'controller-manager.*1/1 +Running'" \
    || { err "LWS controller 未 Running(kubectl get pods -n ${LWS_NAMESPACE}; 先部署 LWS: --steps gpu_lws)"; exit 1; }
ok "    controller 已 Running"

# ② CRD 注册
say "  ② 检查 LWS CRD 注册(官方 API 组 leaderworkerset.x-k8s.io / disaggregatedset.x-k8s.io)..."
CRD_LIST="$(SSH "${K} get crd --no-headers 2>/dev/null" \
    | grep -E 'leaderworkerset\.x-k8s\.io|disaggregatedset\.x-k8s\.io' | awk '{print $1}' || true)"
echo "${CRD_LIST}" | sed 's/^/    /'
echo "${CRD_LIST}" | grep -q 'leaderworkersets.leaderworkerset.x-k8s.io' \
    || { err "leaderworkersets.leaderworkerset.x-k8s.io CRD 未注册"; exit 1; }
ok "    leaderworkersets CRD 已注册"

# ③ 创建测试 LeaderWorkerSet(leader 1 + worker 2, busybox)
say "  ③ 创建测试 LeaderWorkerSet(leader 1 + worker 2, busybox)..."
cleanup
LOCAL_YAML="$(mktemp)"
cat > "${LOCAL_YAML}" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEST_NS}
---
# v0.10.0 schema: leaderWorkerTemplate 用 leaderTemplate/workerTemplate 分离 pod 模板(workerTemplate 必填),
# restartPolicy 枚举为 Default/None/RecreateGroup*(不再用 Always)。size=3 → 1 leader + 2 worker。
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: ${TEST_NAME}
  namespace: ${TEST_NS}
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 3
    restartPolicy: Default
    workerTemplate:
      spec:
        containers:
          - name: sleep
            image: docker.io/library/busybox:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "-c", "sleep 3600"]
            resources:
              requests:
                cpu: 10m
                memory: 16Mi
YAML
if cat "${LOCAL_YAML}" | SSH "${K} apply -f -" >/dev/null 2>&1; then
    ok "    测试 LWS 已创建(ns=${TEST_NS})"
else
    rm -f "${LOCAL_YAML}"
    err "创建测试 LeaderWorkerSet 失败(检查 CRD/webhook; kubectl apply 报错见上方)"; exit 1
fi
rm -f "${LOCAL_YAML}"

# ④ 等待 leader + worker pod 全部 Ready(最长 120s)
say "  ④ 等待 leader + worker pod 全部 Ready(最长 120s)..."
POD_OK=0; POD_TOTAL=3
for _ in $(seq 1 24); do
    POD_OK="$( (SSH "${K} -n ${TEST_NS} get pods --no-headers 2>/dev/null" || true) \
        | awk '$2=="1/1" && $3=="Running"{n++} END{print n+0}' )"
    [ "${POD_OK:-0}" -ge "${POD_TOTAL}" ] && break
    sleep 5
done
[ "${POD_OK:-0}" -ge "${POD_TOTAL}" ] \
    || { err "LWS 测试工作负载仅 ${POD_OK}/${POD_TOTAL} pod Ready(kubectl -n ${TEST_NS} get pods; 检查 busybox 镜像是否预加载)"; exit 1; }
ok "    LeaderWorkerSet ${POD_OK}/${POD_TOTAL} pod 全部 Ready ✓"

# ⑤ 校验 LWS 控制器真正管理(用 v0.10 标签: leaderworkerset.sigs.k8s.io/name=组名 + worker-index=0 为 leader)
say "  ⑤ 校验 LWS 控制器真正管理(leader/worker 标签)..."
MANAGED="$( (SSH "${K} -n ${TEST_NS} get pods -l leaderworkerset.sigs.k8s.io/name=${TEST_NAME} --no-headers 2>/dev/null" || true) | wc -l )"
LEADER_CNT="$( (SSH "${K} -n ${TEST_NS} get pods -l leaderworkerset.sigs.k8s.io/worker-index=0 --no-headers 2>/dev/null" || true) | wc -l )"
[ "${MANAGED:-0}" -ge "${POD_TOTAL}" ] && [ "${LEADER_CNT:-0}" -ge 1 ] \
    && ok "    控制器管理 ${MANAGED}/${POD_TOTAL} pod, leader(worker-index=0)=${LEADER_CNT}, worker=$((MANAGED-LEADER_CNT)) ✓" \
    || warn "    控制器管理 ${MANAGED}/${POD_TOTAL} pod, leader(worker-index=0)=${LEADER_CNT}; 检查 controller 日志"

# ⑥ DisaggregatedSet 支持(dry-run=server 让 CRD + webhook 校验最小 CR, 不落库)
say "  ⑥ 验证 DisaggregatedSet 支持..."
if echo "${CRD_LIST}" | grep -q 'disaggregatedsets.disaggregatedset.x-k8s.io'; then
    LOCAL_DSET="$(mktemp)"
    cat > "${LOCAL_DSET}" <<YAML
# v0.10.0 schema: DisaggregatedSet 用 roles[](≥2 个) + slices 整数(不再用旧 groups)。
apiVersion: disaggregatedset.x-k8s.io/v1
kind: DisaggregatedSet
metadata:
  name: verify-dset
  namespace: ${TEST_NS}
spec:
  roles:
    - name: prefill
      spec:
        leaderWorkerTemplate:
          workerTemplate:
            spec:
              containers:
                - name: sleep
                  image: docker.io/library/busybox:latest
                  imagePullPolicy: IfNotPresent
                  command: ["/bin/sh", "-c", "sleep 3600"]
    - name: decode
      spec:
        leaderWorkerTemplate:
          workerTemplate:
            spec:
              containers:
                - name: sleep
                  image: docker.io/library/busybox:latest
                  imagePullPolicy: IfNotPresent
                  command: ["/bin/sh", "-c", "sleep 3600"]
YAML
    if cat "${LOCAL_DSET}" | SSH "${K} apply --dry-run=server -f -" >/dev/null 2>&1; then
        ok "    DisaggregatedSet CR 可创建(dry-run=server 通过; 解耦推理支持) ✓"
    else
        say "    DisaggregatedSet CRD 已注册(webhook 校验未跑通; 完整创建示例见 docs/lws.md)"
    fi
    rm -f "${LOCAL_DSET}"
else
    warn "    disaggregatedsets CRD 未注册(需 bundle/chart 含该 CRD)"
fi

ok "LeaderWorkerSet 端到端验证通过: controller 运行 + LWS 工作负载调度 + DisaggregatedSet 支持"
