#!/bin/bash
# ============================================================
# test-cubestack-operator-update.sh — cubestack_operator 更新/滚动行为的静态回归
# 背景(2026-10-19 用户口径):
#   · 离线/在线都必须 pullPolicy=Always(离线镜像已推入集群 registry; 每次新建 Pod 重新解析 tag)
#   · 在线模式必须像离线一样用镜像 digest 注解触发滚动, 否则同 :latest 新镜像不会生效
#   · CUBESTACK_OPERATOR_IMAGE_TAG 必须在两模式真正生效
# 覆盖:
#   ① 两模式均强制 Always(operator + CR); 离线 CR 不再 IfNotPresent
#   ② image.tag=${IMG_TAG} 进入 chart 渲染与 helm 安装参数
#   ③ 在线模式识别 operator 镜像、取 digest、写 podAnnotations
#   ④ digest 取不到时 online 兜底 rollout restart
#   ⑤ 离线 loop 把 **operator 镜像** 的 digest 写入 _OPERATOR_DIGEST
# 用法: bash deployments/scripts/tools/tests/test-cubestack-operator-update.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/25_cubestack_operator.sh"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  FAIL $1: [$3] 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }
count_of() { grep -cF -- "$2" "$3" 2>/dev/null || true; }

echo "== ① 两模式强制 Always =="
n_always="$(count_of x '--set "image.pullPolicy=Always"' "${MOD}")"
if [ "${n_always:-0}" -ge 2 ]; then echo "  ok  operator Always 出现在两模式(${n_always})"; else echo "  FAIL operator Always 只出现 ${n_always} 次(期望≥2)"; fail=1; fi
chk_contains "离线 CR imagePullPolicy=Always(初始 values)" 'clusterCR.spec.global.imagePullPolicy=Always' "${MOD}"
chk_contains "离线 CR 纠偏 Always" '_want_pol="Always"' "${MOD}"
chk_not_contains "离线 CR 不再 IfNotPresent" '_want_pol="IfNotPresent"' "${MOD}"

echo "== ② IMAGE_TAG 两模式生效 =="
n_tag="$(count_of x 'image.tag=${IMG_TAG}' "${MOD}")"
if [ "${n_tag:-0}" -ge 2 ]; then echo "  ok  image.tag=\${IMG_TAG} 出现 ${n_tag} 次"; else echo "  FAIL image.tag=\${IMG_TAG} 只出现 ${n_tag} 次(期望≥2: 渲染+安装)"; fail=1; fi
chk_contains "chart 渲染带 image.tag" '_BASE_SET_ARGS=( --set "image.tag=${IMG_TAG}" )' "${MOD}"

echo "== ③ 在线 digest 注解 =="
chk_contains "识别 operator 镜像" '_OP_IMAGE=' "${MOD}"
chk_contains "在线取 operator digest" '_digest "docker://${_OP_IMAGE}"' "${MOD}"
chk_contains "digest 注解" 'podAnnotations.cubestack\\.io/image-digest' "${MOD}"
chk_contains "PIN_DIGEST 门禁" 'PIN_DIGEST}" = "true"' "${MOD}"
chk_contains "在线 digest 缺失时告警/兜底" 'rollout restart deployment/${RELEASE}' "${MOD}"

echo "== ④ 离线 operator digest 精确采集 =="
chk_contains "按 operator 镜像匹配" 'if [ "${_img}" = "${_OP_IMAGE}" ]' "${MOD}"
chk_contains "采集 target digest" '_OPERATOR_DIGEST="${_d_dst}"' "${MOD}"

echo "== ⑤ RWO 单卷 Deployment 策略守护 =="
chk_contains "调用 ensure_rwo_deployments_recreate" 'ensure_rwo_deployments_recreate "${NS}"' "${MOD}"
chk_contains "默认等待上界变量" 'CUBESTACK_OPERATOR_RWO_STRATEGY_WAIT_SECONDS' "${MOD}"

echo "== ⑥ 冒烟 CR 不得继承默认组件/不得卸载真实资源 =="
VERIFY="${REPO_ROOT}/deployments/scripts/modules/03_addon/26_verify_cubestack_operator.sh"
chk_contains "冒烟 CR deletePolicy=retain" "deletePolicy: retain" "${VERIFY}"
chk_not_contains "冒烟 CR 不再使用 deletePolicy: uninstall" "deletePolicy: uninstall" "${VERIFY}"
for _k in lws envoyGateway aiGateway cubestackControllerManager modelBundles prometheus perses cuberouter cubepilot cubestackPortal observability; do
    chk_contains "冒烟 CR 显式禁用 ${_k}" "${_k}: { enabled: false }" "${VERIFY}"
done
chk_contains "冒烟 CR 显式禁用 exporters.bmc" "bmc: { enabled: false }" "${VERIFY}"
chk_contains "冒烟 CR 显式禁用 exporters.metax" "metax: { enabled: false }" "${VERIFY}"
chk_contains "清理前启用组件护栏" "_ENABLED_ANY" "${VERIFY}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-cubestack-operator-update: 全部通过"
else
    echo "❌ test-cubestack-operator-update: 存在失败项"
fi
exit "${fail}"
