#!/bin/bash
# ============================================================
# MODULE: verify_cubestack_operator
# DESC: 端到端验证 CubeStack Operator 真正工作(非仅 pod Running): ① operator/CRD 就绪
#       ② 镜像来源断言(离线=**集群内置 registry**; 在线=Harbor —— 按部署模式分叉)
#       ③ 建冒烟 CubeStackCluster(全组件禁用) → 等 status Ready=True → 断言无 Degraded
#       ④ 清理冒烟 CR(全程 trap 兜底)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: cubestack_operator
# 说明:
#   · **验证模块不设 TOGGLE**(否则 CUBESTACK_OPERATOR_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_cubestack_operator 在安装后单独执行。
#   · 为什么要有第 ② 步: "pod Running" 不能区分镜像来源。离线模式断言 pod image 前缀
#     = ${REGISTRY_DOMAIN}:${REGISTRY_PORT}/ (节点只从内置 registry 拉); 在线模式断言
#     前缀 = Harbor (chart 定义从 Harbor 拉) —— 两种模式都验证来源符合预期。
#   · 为什么冒烟 CR 必须**显式**全组件禁用 + deletePolicy=retain(2026-10-19 实机事故):
#     省略 `spec.components` 并不等于"没有组件" —— operator 会继承 catalog/chart 默认值
#     (新版 chart 默认启用 lws/envoyGateway/...)。冒烟 CR 原先只写 deletePolicy=uninstall,
#     清理时 operator 按默认组件执行 uninstall, 把**真实**的 lws-system 命名空间
#     (SA/ConfigMap/Secret/RBAC)删掉了, 真正的 LWS 控制器随后 CrashLoopBackOff。
#     ⇒ 现在显式写全部 components.enabled=false + bundles=[] + deletePolicy=retain(双保险)。
#   · 清理: trap 兜底删冒烟 CR(retain ⇒ 即使默认值再次漂移, 也不会卸载/删除任何共享资源)。
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
# (2026-08-08 起对齐各 verify 模块惯例; 旧实现只查开关 ⇒ --steps cubestack_operator 单次部署后
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
# 镜像来源断言按部署模式分叉(2026-10-22): 离线=集群内置 registry; 在线=Harbor。
ONLINE_DEPLOY="${ONLINE_DEPLOY_CUBESTACK_OPERATOR:-false}"
HARBOR_HOST="${CUBESTACK_OPERATOR_HARBOR_HOST:-${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}}"
if [ "${ONLINE_DEPLOY}" = "true" ]; then
    EXPECTED_IMG_PREFIX="${HARBOR_HOST}"; IMG_SRC_LABEL="Harbor(在线模式)"
else
    EXPECTED_IMG_PREFIX="${REG_BASE}"; IMG_SRC_LABEL="集群内置 registry"
fi
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

# ---------------- ② 镜像来源断言(按部署模式: 离线=内置 registry / 在线=Harbor) ----------------
say "[3/5] 断言 operator/组件镜像来自 ${IMG_SRC_LABEL}(${EXPECTED_IMG_PREFIX})..."
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
        "${EXPECTED_IMG_PREFIX}/"*) say "    ✓ ${_img}" ;;
        *) err "镜像不来自 ${IMG_SRC_LABEL}: ${_img}"
           if [ "${ONLINE_DEPLOY}" = "true" ]; then
               err "  → 在线模式要求 operator/组件镜像来自 ${HARBOR_HOST}(chart 定义); 检查 CR global.imageRegistry / imagePullSecrets"
           else
               err "  → 节点将从 Harbor 拉取, 离线集群会 ImagePullBackOff(需求 5: 部署用本地 chart, 镜像走集群 registry)"
           fi
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
  # ⚠ 必须显式全禁用: 省略 components 会继承 catalog/chart 默认(新版默认启用 lws 等),
  #   清理时曾把真实 lws-system 命名空间删掉(2026-10-19 实机事故)。
  deletePolicy: retain
  bundles: []
  components:
    lws: { enabled: false }
    envoyGateway: { enabled: false }
    aiGateway: { enabled: false }
    cubestackControllerManager: { enabled: false }
    modelBundles: { enabled: false }
    prometheus: { enabled: false }
    perses: { enabled: false }
    cuberouter: { enabled: false }
    cubepilot: { enabled: false }
    cubestackPortal: { enabled: false }
    observability: { enabled: false }
    exporters:
      bmc: { enabled: false }
      metax: { enabled: false }
EOF
# 清理前的最后一道护栏: 若 operator 仍因默认值/未来新增组件启用了任何组件, 立即中止,
# 不执行 cleanup 的卸载路径(cleanup 本身已是 retain, 但仍不让它碰任何共享资源)。
_CR_JSON="$( (SSH "${K} -n ${NS} get csc ${CR_NAME} -o json 2>/dev/null") || true )"
_ENABLED_ANY="$(printf '%s' "${_CR_JSON}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
try:
    comps = d["spec"]["components"]
except Exception:
    comps = {}
def walk(name, v):
    if isinstance(v, dict):
        if v.get("enabled") is True:
            print(name)
        for k, x in v.items():
            if k != "enabled" and isinstance(x, dict):
                walk(name + "." + k if name else k, x)
for k, v in comps.items():
    walk(k, v)
' 2>/dev/null || true)"
if [ -n "${_ENABLED_ANY}" ]; then
    err "冒烟 CR ${CR_NAME} 出现了启用组件: ${_ENABLED_ANY}"
    err "  → 中止验证, 不执行清理卸载(deletePolicy=retain 已兜底); 请检查 operator 默认组件值"
    exit 1
fi
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
echo "  ③ 镜像来自 ${IMG_SRC_LABEL} ${EXPECTED_IMG_PREFIX}"
echo "  ④ 冒烟 CubeStackCluster Ready=True 且无 Degraded"
echo "  后续(可选): 启用组件/平台实例见 docs/cubestack-operator.md"
