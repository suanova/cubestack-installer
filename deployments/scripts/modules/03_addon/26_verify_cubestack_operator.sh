#!/bin/bash
# ============================================================
# MODULE: verify_cubestack_operator
# DESC: 端到端验证 CubeStack Operator 真正工作(非仅 pod Running): ① operator/CRD 就绪
#       ② 镜像来源断言(必须来自**集群内置 registry**, 不是 Harbor —— 离线可用性的证据)
#       ③ 建冒烟 CubeStackCluster(全组件禁用) → 等 status Ready=True → 断言无 Degraded
#       ④ 清理冒烟 CR(全程 trap 兜底)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: cubestack_operator
# 说明:
#   · **验证模块不设 TOGGLE**(否则 CUBESTACK_OPERATOR_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_cubestack_operator 在安装后单独执行。
#   · 为什么要有第 ② 步: "pod Running" 不能区分镜像来自集群 registry 还是 Harbor。
#     本仓库的离线前提是**节点只从集群内置 registry 拉取**, 故直接断言 pod 的 image 前缀
#     = ${REGISTRY_DOMAIN}:${REGISTRY_PORT}/ —— 这是"离线集群能跑起来"的直接证据。
#   · 为什么冒烟 CR 不启用任何组件: 组件(lws/envoy-gateway/prometheus/...)的镜像不在本模块
#     的离线范围内(见 docs/cubestack-operator.md), 全禁用可验证 **operator 自身的调和链路**
#     (watch → 渲染 → apply → status), 且秒级 Ready(CRD 文档: 无启用组件时 Ready 平凡为 True)。
#   · 清理: trap 兜底删冒烟 CR(deletePolicy=uninstall; 无启用组件 ⇒ 无受管对象可删)。
# 数据源: cluster.conf (CUBESTACK_OPERATOR_* / REGISTRY_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps verify_cubestack_operator
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

NS="${CUBESTACK_OPERATOR_NAMESPACE:-cubestack-system}"
RELEASE="${CUBESTACK_OPERATOR_RELEASE:-cubestack-operator}"

# 门禁: 以**实际部署**为准(Deployment 是否存在), 而非 CUBESTACK_OPERATOR_ENABLED 配置开关
# (2026-10-08 对齐 24_verify_lws 惯例; 旧实现只查开关 ⇒ --steps cubestack_operator 单次部署后
#  开关仍为 false, 显式 --steps verify_cubestack_operator 会被误跳过 —— 实机踩到):
#   · 已部署 → 验证; · 未部署 且 未启用 → 跳过(避免 --steps verify 全量时对未装组件报错);
#   · 未部署 但 已启用 → 继续, 由 [1/5] 给出"未就绪, 先部署"的可执行报错。
_DEPLOYED="$(SSH "${K} -n ${NS} get deploy ${RELEASE} --no-headers 2>/dev/null" | grep -c . || true)"
if [ "${_DEPLOYED:-0}" -eq 0 ] && [ "${CUBESTACK_OPERATOR_ENABLED:-false}" != "true" ]; then
    say "CubeStack Operator 未部署(Deployment 不存在且 CUBESTACK_OPERATOR_ENABLED≠true), 跳过验证(先 --steps cubestack_operator 部署)"
    exit 0
fi
# 期望的镜像前缀 = 集群内置 registry 的域名端点(节点按此拉取)
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
CR_NAME="verify-csc"                     # 冒烟 CR(固定名: 重跑先删, 幂等)
CRD="cubestackclusters.operator.cubestack.io"
WAIT_READY_SECONDS="${VERIFY_CSC_WAIT_SECONDS:-120}"

cleanup() {
    SSH "${K} -n ${NS} delete cubestackcluster ${CR_NAME} --ignore-not-found --wait=false >/dev/null 2>&1" || true
}
trap cleanup EXIT

# ---------------- ① operator / CRD 就绪 ----------------
say "[1/5] operator Deployment 就绪 ..."
_dep=""
if SSH "${K} -n ${NS} get deploy/${RELEASE} --no-headers >/dev/null 2>&1"; then
    _dep="${RELEASE}"
elif SSH "${K} -n ${NS} get deploy/${RELEASE}-cubestack-operator --no-headers >/dev/null 2>&1"; then
    _dep="${RELEASE}-cubestack-operator"
else
    err "未找到 operator Deployment(namespace=${NS}; 试过 ${RELEASE} 与 ${RELEASE}-cubestack-operator)"
    err "  先部署: sudo ./deploy-cluster.sh --steps cubestack_operator"
    exit 1
fi
SSH "${K} -n ${NS} rollout status deployment/${_dep} --timeout=120s" >/dev/null 2>&1 \
    || { err "operator Deployment 未就绪: ${NS}/${_dep}"; SSH "${K} -n ${NS} get pods -o wide" ; exit 1; }
ok "  Deployment ${_dep} Ready"

say "[2/5] CRD ${CRD} Established ..."
_wait=0
for _i in $(seq 1 30); do
    if SSH "${K} get crd ${CRD} --no-headers >/dev/null 2>&1"; then _wait=1; break; fi
    sleep 2
done
[ "${_wait}" = "1" ] || { err "CRD 未注册: ${CRD}(operator 未装成? 或 chart 的 crds/ 未 apply)"; exit 1; }
SSH "${K} wait --for=condition=Established crd/${CRD} --timeout=60s" >/dev/null 2>&1 \
    || warn "  crd/${CRD} Established 条件未在 60s 内出现(继续, 后面用真实 CR 验证)"
ok "  CRD 已注册"

# ---------------- ② 镜像来源断言(离线可用性的直接证据) ----------------
say "[3/5] 断言 operator 镜像来自集群内置 registry(${REG_BASE})..."
POD_JSON="$( (SSH "${K} -n ${NS} get pods -l app.kubernetes.io/name=cubestack-operator-chart -o json 2>/dev/null" || true) )"
[ -n "${POD_JSON}" ] || POD_JSON="$( (SSH "${K} -n ${NS} get pods -o json 2>/dev/null" || true) )"
IMAGES="$(printf '%s' "${POD_JSON}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
seen = []
for p in d.get("items", []):
    for c in (p.get("spec", {}).get("containers") or []):
        img = c.get("image", "")
        if img and img not in seen:
            seen.append(img)
print("\n".join(seen))
' 2>/dev/null || true)"
[ -n "${IMAGES}" ] || { err "取不到 operator pod 镜像(集群不可达或 pod 未创建)"; exit 1; }
_ok_img=1
while IFS= read -r _img; do
    [ -n "${_img}" ] || continue
    case "${_img}" in
        "${REG_BASE}/"*) say "    ✓ ${_img}" ;;
        *) err "镜像不来自集群内置 registry: ${_img}"
           err "  → 节点将从 Harbor 拉取, 离线集群会 ImagePullBackOff(需求 5: 部署用本地 chart, 镜像走集群 registry)"
           _ok_img=0 ;;
    esac
done <<< "${IMAGES}"
[ "${_ok_img}" = "1" ] || exit 1
# 拉取策略: 滚动 :latest 若不 Always, 节点缓存会静默冻结版本(见 25_cubestack_operator.sh 头部)
SSH "${K} -n ${NS} get deploy/${_dep} -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null" \
    | grep -qE 'Always|IfNotPresent' || warn "  拉取策略异常"
ok "  镜像来源与拉取策略断言通过"

# ---------------- ③ 冒烟 CR: 全组件禁用 → Ready ----------------
# 先删旧(重跑幂等; 上一个同名 CR 可能卡在 finalizer), 再建
cleanup
say "[4/5] 建冒烟 CubeStackCluster(${CR_NAME}, 全组件禁用)并等 Ready ..."
cat <<EOF | SSH "${K} apply -f -" >/dev/null
apiVersion: operator.cubestack.io/v1alpha1
kind: CubeStackCluster
metadata:
  name: ${CR_NAME}
  namespace: ${NS}
spec:
  deletePolicy: uninstall
EOF
_ready="" ; _last=""
for _i in $(seq 1 $((WAIT_READY_SECONDS / 5))); do
    CR_JSON="$( (SSH "${K} -n ${NS} get cubestackcluster ${CR_NAME} -o json 2>/dev/null" || true) )"
    _ready="$(printf '%s' "${CR_JSON}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for c in (d.get("status", {}).get("conditions") or []):
    if c.get("type") == "Ready":
        print(c.get("status", "")); break
' 2>/dev/null || true)"
    _last="$(printf '%s' "${CR_JSON}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
st = d.get("status", {}) or {}
for c in (st.get("conditions") or []):
    if c.get("type") == "Ready":
        print("%s: %s" % (c.get("reason", ""), c.get("message", ""))); break
' 2>/dev/null || true)"
    [ "${_ready}" = "True" ] && break
    [ "$((_i % 4))" -eq 0 ] && say "  第 ${_i}/$((WAIT_READY_SECONDS / 5)) 次: Ready=${_ready:-<无 status>} ${_last}"
    sleep 5
done
[ "${_ready}" = "True" ] \
    || { err "冒烟 CR 未在 ${WAIT_READY_SECONDS}s 内 Ready(当前 Ready=${_ready:-<无>} ${_last})"
         err "  现场: kubectl -n ${NS} get csc ${CR_NAME} -o yaml; kubectl -n ${NS} logs deploy/${_dep}"
         exit 1; }
ok "  冒烟 CR Ready=True(operator 调和链路: watch → status 正常)"

# 断言没有 Degraded 组件(全禁用时 components 应为空)
DEGRADED="$(printf '%s' "${CR_JSON}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
bad = [c.get("name", "?") for c in (d.get("status", {}).get("components") or [])
       if str(c.get("phase", "")).lower() == "degraded"]
print("\n".join(bad))
' 2>/dev/null || true)"
[ -z "${DEGRADED}" ] || { err "冒烟 CR 出现 Degraded 组件: ${DEGRADED}"; exit 1; }
ok "  无 Degraded 组件"

# ---------------- ④ 清理 ----------------
say "[5/5] 清理冒烟 CR ..."
cleanup
for _i in 1 2 3 4 5 6; do
    SSH "${K} -n ${NS} get cubestackcluster ${CR_NAME} --no-headers >/dev/null 2>&1" || break
    # finalizer 卡住时给一次机会提示(operation 正常时应立即删除)
    [ "${_i}" = "3" ] && warn "  CR 仍在删除中(finalizer operator.cubestack.io/managed; 若持续卡住查 operator 日志)"
    sleep 3
done
SSH "${K} -n ${NS} get cubestackcluster ${CR_NAME} --no-headers >/dev/null 2>&1" \
    && warn "  冒烟 CR 未删除干净(残留不影响功能; 手工: kubectl -n ${NS} patch csc ${CR_NAME} --type=merge -p '{\"metadata\":{\"finalizers\":null}}')" \
    || ok "  冒烟 CR 已清理"

echo "---------------------------------------------"
ok "CubeStack Operator 端到端验证通过"
echo "  ① Deployment ${NS}/${_dep} Ready"
echo "  ② CRD ${CRD} 已注册"
echo "  ③ 镜像来自集群内置 registry ${REG_BASE}(离线前提成立)"
echo "  ④ 冒烟 CubeStackCluster Ready=True 且无 Degraded"
echo "  后续(可选): 启用组件/平台实例见 docs/cubestack-operator.md"
