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
#   ⑥ 冒烟 CR 显式全禁用 + retain(不继承默认组件/不卸载真实资源)
#   ⑦ 默认保留 chart 的 8 个 model bundles + modelBundles 开启(开关默认 true, 仅 false 分支裁剪)
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

echo "== ⑦ 默认保留 chart 的 model bundles(开关默认 true) =="
# 2026-10-20 用户口径: 单步 --steps cubestack_operator 与全量部署都必须默认 bundles 非空;
# 以 chart values.yaml 为主; 开关 CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED 放在 cluster.defaults.conf,
# 默认 true; 只有 false 分支才清空 bundles / 关 modelBundles。
DEFAULTS="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
chk_contains "defaults 定义 bundles 开关(默认 true)" \
    'CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED="${CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED:-true}"' "${DEFAULTS}"
chk_contains "模块默认读取 true" 'CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED:-true' "${MOD}"
chk_contains "保留 CR_VALUES_FILE 覆盖通道" 'CUBESTACK_OPERATOR_CR_VALUES_FILE' "${MOD}"
chk_not_contains "模块不关闭 bmc(chart 默认保留)" 'clusterCR.spec.components.exporters.bmc.enabled=false' "${MOD}"
# 裁剪语句只允许出现在 BUNDLES_ENABLED != true 的分支里
_BUNDLE_BLOCK="$(awk '/BUNDLES_ENABLED.*!=.*"true"/{f=1} f{print} f&&/^    fi$/{exit}' "${MOD}")"
if [ -n "${_BUNDLE_BLOCK}" ]; then
    echo "  ok  找到 BUNDLES_ENABLED=false 分支"
else
    echo "  FAIL 未找到 BUNDLES_ENABLED=false 分支"; fail=1
fi
chk "bundles 裁剪仅在 false 分支" "1" "$(printf '%s\n' "${_BUNDLE_BLOCK}" | grep -cF 'clusterCR.spec.bundles=[]' || true)"
chk "modelBundles 关闭仅在 false 分支" "1" "$(printf '%s\n' "${_BUNDLE_BLOCK}" | grep -cF 'clusterCR.spec.components.modelBundles.enabled=false' || true)"
chk "模块中 bundles 清空仅此一处" "1" "$(grep -cF 'clusterCR.spec.bundles=[]' "${MOD}" || true)"
chk "模块中 modelBundles 关闭仅此一处" "1" "$(grep -cF 'clusterCR.spec.components.modelBundles.enabled=false' "${MOD}" || true)"
CHART_DIR="${REPO_ROOT}/deployments/cubestack-addon/cubestack-operator"
CHART_TGZ="$(ls "${CHART_DIR}"/*.tgz 2>/dev/null | head -1 || true)"
if [ -n "${CHART_TGZ}" ]; then
    _VALS_PATH="$(tar -tzf "${CHART_TGZ}" 2>/dev/null | grep -m1 '/values.yaml$' || true)"
    if [ -n "${_VALS_PATH}" ]; then
        _VALS="$(tar -xOzf "${CHART_TGZ}" "${_VALS_PATH}" 2>/dev/null || true)"
        _N_BUNDLES="$(printf '%s\n' "${_VALS}" | sed -n '/^    bundles:/,/^    components:/p' | grep -c '^      - ' || true)"
        if [ "${_N_BUNDLES:-0}" -ge 1 ]; then
            echo "  ok  chart 默认 bundles 非空(${_N_BUNDLES} 个)"
        else
            echo "  FAIL chart 默认 bundles 为空(chart=${CHART_TGZ})"; fail=1
        fi
        if printf '%s\n' "${_VALS}" | sed -n '/modelBundles:/,/enabled:/p' | grep -q 'enabled: true'; then
            echo "  ok  chart 默认 modelBundles.enabled=true"
        else
            echo "  FAIL chart 默认未开启 modelBundles"; fail=1
        fi
    else
        echo "  FAIL chart 内未找到 values.yaml(${CHART_TGZ})"; fail=1
    fi
else
    echo "  SKIP 未找到 vendored chart tgz(干净 checkout 属预期缺省)"
fi

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-cubestack-operator-update: 全部通过"
else
    echo "❌ test-cubestack-operator-update: 存在失败项"
fi
exit "${fail}"
