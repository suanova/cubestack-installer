#!/bin/bash
# ============================================================
# test-cubestack-operator-update.sh — cubestack_operator 更新/滚动行为的静态回归
# 背景(2026-10-19 用户口径):
#   · 离线/在线都必须 pullPolicy=Always(离线镜像已推入集群 registry; 每次新建 Pod 重新解析 tag)
#   · 在线模式必须像离线一样用镜像 digest 注解触发滚动, 否则同 :latest 新镜像不会生效
#   · 镜像 tag 以 chart 自带为准(release chart 如 2.0.0); installer 不再 --set image.tag 覆盖
#   · CUBESTACK_OPERATOR_IMAGE_TAG 仅用于镜像清单/发布树登记, 不再驱动 helm
# 覆盖:
#   ① 两模式均强制 Always(operator + CR); 离线 CR 不再 IfNotPresent
#   ② chart 定位(不写死版本) + operator tag 默认/覆盖(chart / release / override)
#   ③ 在线模式识别 operator 镜像、取 digest、写 podAnnotations
#   ④ digest 取不到时 online 兜底 rollout restart
#   ⑤ 离线 loop 把 **operator 镜像** 的 digest 写入 _OPERATOR_DIGEST
#   ⑥ 冒烟 CR 显式全禁用 + retain(不继承默认组件/不卸载真实资源)
#   ⑦ operator 版本基线/bundles 开关在 cluster.conf(+example): 仅显式 false 分支裁剪, 非法值报错
#   ⑧ chart 随离线包分发: charts/ 落点 / 显式覆盖 / legacy fallback / 缺 chart 硬失败
# 用法: bash deployments/scripts/tools/tests/test-cubestack-operator-update.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/25_cubestack_operator.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
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

echo "== ② chart 定位(不写死版本) + operator tag 默认/覆盖 =="
chk_contains "chart 定位函数" 'resolve_operator_chart_tgz' "${MOD}"
chk_contains "tag 取 chart 渲染结果" '_OP_IMAGE##*:' "${MOD}"
chk_contains "release 镜像清单核对" 'release-images.tsv' "${MOD}"
chk_contains "release 禁止 :latest chart" 'release ${CUBESTACK_RELEASE} 的 operator chart 渲染出 :latest' "${MOD}"
chk_contains "显式 operator tag override" 'CUBESTACK_OPERATOR_IMAGE_TAG_OVERRIDE' "${MOD}"
chk_contains "tag 决策函数" 'operator_image_tag_for_helm' "${MOD}"
chk_contains "仅非空才传 image.tag" '_TAG_SET_ARGS+=( --set "image.tag=' "${MOD}"
chk_not_contains "不再无条件传 image.tag" '_BASE_SET_ARGS=( --set "image.tag=' "${MOD}"

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

echo "== ⑤b 离线推送后触发 ImagePullBackOff Pod 重拉 =="
chk_contains "存在重拉助手" '_reroll_stuck_pods()' "${MOD}"
chk_contains "只匹配本次平台镜像集合" '_PLATFORM_REFS+=' "${MOD}"
chk_contains "删除命中 Pod" 'delete pod ${_pod}' "${MOD}"
chk_contains "调用重拉助手" '_reroll_stuck_pods ${TARGET_REFS[@]+' "${MOD}"

echo "== ⑤c 重拉助手: ssh 不得吞掉循环输入(所有命中 Pod 都要删) =="
# 2026-10-23 A 集群实机: while read ... | ... 循环里直接调用 ssh, ssh 会把管道剩余行
# 当作自己的 stdin 读走 → 只删第一个 Pod 就结束, 其余 Pod 继续 ImagePullBackOff。
# 这里提取模块里的真实函数, 用假 SSH(delete 时读 stdin, 复现真实行为)验证删除数量。
awk '/^_reroll_stuck_pods\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${MOD}" > "${TMP}/reroll-fn.sh"
chk_contains "提取到重拉助手函数体" '_reroll_stuck_pods()' "${TMP}/reroll-fn.sh"
cat > "${TMP}/pods.json" <<'EOF'
{"items":[
 {"metadata":{"namespace":"ns","name":"p1"},"status":{"containerStatuses":[{"image":"reg/a:1","state":{"waiting":{"reason":"ImagePullBackOff"}}}]}},
 {"metadata":{"namespace":"ns","name":"p2"},"status":{"containerStatuses":[{"image":"reg/b:1","state":{"waiting":{"reason":"ErrImagePull"}}}]}},
 {"metadata":{"namespace":"ns","name":"p3"},"status":{"containerStatuses":[{"image":"reg/c:1","state":{"waiting":{"reason":"ImagePullBackOff"}}}]}},
 {"metadata":{"namespace":"ns","name":"p4"},"status":{"containerStatuses":[{"image":"reg/other:9","state":{"waiting":{"reason":"ImagePullBackOff"}}}]}}
]}
EOF
cat > "${TMP}/reroll-run.sh" <<'EOF'
set -uo pipefail
K="kubectl"
say() { :; }
SSH() {
    case "$*" in
        *" get pods "*) cat "${JSON}" ;;
        *" delete pod "*) cat >/dev/null; printf '%s\n' "$*" >> "${OUT}" ;;
    esac
    return 0
}
. "${FN}"
_reroll_stuck_pods reg/a:1 reg/b:1 reg/c:1
EOF
JSON="${TMP}/pods.json" OUT="${TMP}/deleted.txt" FN="${TMP}/reroll-fn.sh" \
    bash "${TMP}/reroll-run.sh" >/dev/null 2>&1 || true
chk "3 个命中 Pod 全部删除(ssh 未吞 stdin)" "3" "$(wc -l < "${TMP}/deleted.txt" 2>/dev/null || echo 0)"
chk_not_contains "非本次镜像集合的 Pod 不动" "p4" "${TMP}/deleted.txt"

echo "== ⑤d 组件镜像幂等: 用 config digest(内容), 不用 manifest digest =="
# docker-archive 的层未压缩, skopeo push 会重新 gzip → manifest digest 必变 → 每次重推。
# 必须比 config digest(rootfs.diff_ids 不变)才能跳过。
chk_contains "存在内容 digest 助手" '_content_digest()' "${MOD}"
chk_contains "目标侧用内容 digest" '_d_dst="$(_content_digest "${_dst}")"' "${MOD}"
chk_contains "源侧(archive)用内容 digest" '_d_src="$(_content_digest "docker-archive:${_tarfile}")"' "${MOD}"
chk_not_contains "4b/6 不再用 manifest digest 比对源" '_d_src="$(_digest "docker-archive:${_tarfile}")"' "${MOD}"
chk_contains "operator 镜像目标侧用内容 digest" '_c_dst="$(_content_digest "${_dst}")"' "${MOD}"
chk_contains "operator 镜像源侧用内容 digest" '_c_src="$(_content_digest "${_src_arg}")"' "${MOD}"

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

echo "== ⑦ model bundles 开关 + 版本基线(2026-10-23 rc: 全部在 cluster.conf) =="
# 2026-10-23: CUBESTACK_OPERATOR_{CHART_VERSION,CHART_SYNC,IMAGE_TAG_OVERRIDE,MODEL_BUNDLES_ENABLED}
# 从 cluster.defaults.conf 挪到 cluster.conf(与其它 operator 变量同节), 模板同步到 cluster.conf.example。
# 模块保留内置兜底(MODEL_BUNDLES_ENABLED=false); 仅显式 false 分支清空 bundles / 关 modelBundles;
# 其他值必须报配置错误。
DEFAULTS="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
EXAMPLE="${REPO_ROOT}/deployments/config/cluster.conf.example"
chk_contains "example 定义 bundles 开关(默认 true)" \
    'CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED="${CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED:-true}"' "${EXAMPLE}"
chk_contains "example IMAGE_TAG_OVERRIDE 默认留空" \
    'CUBESTACK_OPERATOR_IMAGE_TAG_OVERRIDE="${CUBESTACK_OPERATOR_IMAGE_TAG_OVERRIDE:-}"' "${EXAMPLE}"
for _v in CHART_VERSION CHART_SYNC IMAGE_TAG_OVERRIDE MODEL_BUNDLES_ENABLED; do
    chk_contains "example 定义 CUBESTACK_OPERATOR_${_v}" \
        "CUBESTACK_OPERATOR_${_v}=\"\${CUBESTACK_OPERATOR_${_v}:-" "${EXAMPLE}"
    chk_not_contains "defaults 不再定义 CUBESTACK_OPERATOR_${_v}" \
        "CUBESTACK_OPERATOR_${_v}=\"\${CUBESTACK_OPERATOR_${_v}:-" "${DEFAULTS}"
done
chk_contains "模块默认读取 true" 'CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED:-true' "${MOD}"
chk_contains "保留 CR_VALUES_FILE 覆盖通道" 'CUBESTACK_OPERATOR_CR_VALUES_FILE' "${MOD}"
chk_not_contains "模块不关闭 bmc(chart 默认保留)" 'clusterCR.spec.components.exporters.bmc.enabled=false' "${MOD}"
chk_contains "非法 bundles 开关值报配置错误" 'CUBESTACK_OPERATOR_MODEL_BUNDLES_ENABLED 仅接受 true|false' "${MOD}"
chk_contains "非法值分支显式 exit 1" '仅接受 true|false(当前=${BUNDLES_ENABLED})"; exit 1' "${MOD}"
chk_not_contains "不再用 != true 判断(避免笔误静默裁剪)" 'BUNDLES_ENABLED}" != "true"' "${MOD}"
# 裁剪语句只允许出现在 BUNDLES_ENABLED = false 的分支里
_BUNDLE_BLOCK="$(awk '/BUNDLES_ENABLED.*=.*"false"/{f=1} f{print} f&&/^    fi$/{exit}' "${MOD}")"
if [ -n "${_BUNDLE_BLOCK}" ]; then
    echo "  ok  找到 BUNDLES_ENABLED=false 分支"
else
    echo "  FAIL 未找到 BUNDLES_ENABLED=false 分支"; fail=1
fi
chk "bundles 裁剪仅在 false 分支" "1" "$(printf '%s\n' "${_BUNDLE_BLOCK}" | grep -cF 'clusterCR.spec.bundles=[]' || true)"
chk "modelBundles 关闭仅在 false 分支" "1" "$(printf '%s\n' "${_BUNDLE_BLOCK}" | grep -cF 'clusterCR.spec.components.modelBundles.enabled=false' || true)"
chk "模块中 bundles 清空仅此一处" "1" "$(grep -cF 'clusterCR.spec.bundles=[]' "${MOD}" || true)"
chk "模块中 modelBundles 关闭仅此一处" "1" "$(grep -cF 'clusterCR.spec.components.modelBundles.enabled=false' "${MOD}" || true)"
# ★ 2026-10-20 CodeRabbit: 必须选模块实际会用的那份 chart(由 CHART_REF/CHART_VER 派生),
#   不能 `ls | head -1` —— 目录里若同时有旧版 tgz, 会检查到错误的 chart 默认值。
_CHART_CFG="$(
    set +u
    REPO_ROOT="${REPO_ROOT}"
    [ -f "${REPO_ROOT}/deployments/config/cluster.defaults.conf" ] \
        && . "${REPO_ROOT}/deployments/config/cluster.defaults.conf" >/dev/null 2>&1 || true
    [ -f "${REPO_ROOT}/deployments/config/cluster.conf" ] \
        && . "${REPO_ROOT}/deployments/config/cluster.conf" >/dev/null 2>&1 || true
    printf '%s\t%s\n' \
        "${CUBESTACK_OPERATOR_CHART_REF:-oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart}" \
        "${CUBESTACK_OPERATOR_CHART_VERSION:-1.0.0-latest}"
)"
CHART_REF_T="${_CHART_CFG%%$'\t'*}"
CHART_VER_T="${_CHART_CFG#*$'\t'}"
CHART_NAME_T="$(basename "${CHART_REF_T}")"
OFFLINE_CHART_DIR="${REPO_ROOT}/deployments/offline-files/cubestack-operator/charts"
LEGACY_CHART_DIR="${REPO_ROOT}/deployments/cubestack-addon/cubestack-operator"
CHART_DIR="${OFFLINE_CHART_DIR}"
# 与模块同口径: 离线包优先, 旧路径只作 fallback
[ -f "${CHART_DIR}/${CHART_NAME_T}-${CHART_VER_T}.tgz" ] \
    || [ ! -f "${LEGACY_CHART_DIR}/${CHART_NAME_T}-${CHART_VER_T}.tgz" ] \
    || CHART_DIR="${LEGACY_CHART_DIR}"
CHART_TGZ="${CHART_DIR}/${CHART_NAME_T}-${CHART_VER_T}.tgz"
if [ -f "${CHART_TGZ}" ]; then
    _VALS_PATH="$(tar -tzf "${CHART_TGZ}" 2>/dev/null | grep -m1 '/values.yaml$' || true)"
    if [ -n "${_VALS_PATH}" ]; then
        _VALS="$(tar -xOzf "${CHART_TGZ}" "${_VALS_PATH}" 2>/dev/null || true)"
        _N_BUNDLES="$(printf '%s\n' "${_VALS}" | sed -n '/^    bundles:/,/^    components:/p' | grep -c '^      - ' || true)"
        # 精确断言 8 个(CodeRabbit): 该回归的目的就是保护 chart 默认的 8 bundle;
        # 用 >=1 时 chart 减到 1 个也会误过。chart 有意变更时同步更新此断言。
        if [ "${_N_BUNDLES:-0}" -eq 8 ]; then
            echo "  ok  chart 默认 bundles = 8 个"
        else
            echo "  FAIL chart 默认 bundles 数量=${_N_BUNDLES:-0}(期望 8; chart=${CHART_TGZ})"; fail=1
        fi
        if printf '%s\n' "${_VALS}" | sed -n '/modelBundles:/,/enabled:/p' | grep -q 'enabled: true'; then
            echo "  ok  chart 默认 modelBundles.enabled=true"
        else
            echo "  FAIL chart 默认未开启 modelBundles"; fail=1
        fi
    else
        echo "  FAIL chart 内未找到 values.yaml(${CHART_TGZ})"; fail=1
    fi
elif [ -n "$(find "${CHART_DIR}" -maxdepth 1 -type f -name '*.tgz' -print -quit 2>/dev/null || true)" ]; then
    echo "  FAIL 模块配置的 chart 不存在: ${CHART_TGZ}(目录中其他 tgz 不会用于部署)"; fail=1
else
    echo "  SKIP 未找到 chart tgz(干净 checkout / 未备料属预期缺省)"
fi

echo "== ⑧ chart 随离线包分发(charts/) =="
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
chk_contains "显式 chart 目录覆盖" 'CUBESTACK_OPERATOR_CHART_DIR' "${MOD}"
chk_contains "主落点 = 离线包 charts/" 'PRIMARY_CHART_DIR="${OFFLINE_DIR}/charts"' "${MOD}"
chk_contains "组件扫描跳过 charts" '"charts" ] && continue' "${MOD}"
chk_contains "显式组件列表拒绝 charts" 'CUBESTACK_OPERATOR_COMPONENTS=charts 无效' "${MOD}"
chk_not_contains "旧路径不再参与解析" 'LEGACY_CHART_DIR=' "${MOD}"
chk_contains "路径解析函数" '_resolve_chart_dir' "${MOD}"
chk_contains "缺 chart 硬失败" 'if [ ! -f "${CHART_TGZ}" ]' "${MOD}"
chk_not_contains "已删除 _legacy-readmes 处理" '_legacy-readmes' "${MOD}"
chk_contains "离线包刷新提示走同步工具" 'cubestack-platform-sync.sh --collection cubestack-operator' "${LIB}"
chk_contains "helm_chart_ensure 按路径区分提示" '*/deployments/offline-files/*' "${LIB}"
SYNC="${REPO_ROOT}/deployments/scripts/tools/images/cubestack-platform-sync.sh"
chk_contains "chart 计数扫描 charts/" 'L_C="$(_local_chartn "${STATE_SUB}/charts")"' "${SYNC}"
chk_contains "镜像保鲜失败不发布" '镜像保鲜失败, 跳过 chart 刷新与上传' "${SYNC}"

echo "== ⑨ SERVICE_EXPOSE_MODE → CR + Envoy Gateway 数据面 =="
# 2026-10-22 实机: SERVICE_EXPOSE_MODE=nodeport 时 Envoy 公网 Service 仍是 LoadBalancer
# (operator 的 serviceExposeMode 不作用于默认 EnvoyProxy) → EXTERNAL-IP <pending>。
chk_contains "CR 显式写入 serviceExposeMode" 'clusterCR.spec.global.serviceExposeMode=' "${MOD}"
chk_contains "CR 纠偏包含 serviceExposeMode" 'serviceExposeMode' "${MOD}"
chk_contains "调用 Envoy 数据面对齐" 'ensure_envoy_gateway_service_type "${SERVICE_EXPOSE_MODE' "${MOD}"
chk_contains "lib-common 设置 envoyService.type" 'envoyService:' "${LIB}"
chk_contains "lib-common 挂 parametersRef" 'parametersRef' "${LIB}"
chk_contains "组件更新也兜底对齐" 'ensure_envoy_gateway_service_type "${SERVICE_EXPOSE_MODE' \
    "${REPO_ROOT}/deployments/scripts/tools/k8s/cubestack-component-update.sh"

echo "== ⑩ operator chart 版本无关定位(release 2.0.0) =="
_cdir="${TMP}/charts"; mkdir -p "${_cdir}"
_mk_chart() {   # <version> <filename>
    local v="$1" f="$2" d="${TMP}/mk-${1}"
    mkdir -p "${d}/cubestack-operator-chart"
    printf 'apiVersion: v2\nname: cubestack-operator-chart\nversion: %s\nappVersion: %s\n' \
        "${v}" "${v}" > "${d}/cubestack-operator-chart/Chart.yaml"
    tar -czf "${_cdir}/${f}" -C "${d}" cubestack-operator-chart
}
_mk_chart 2.0.0 cubestack-operator-chart-2.0.0.tgz
_mk_chart 1.0.0-latest cubestack-operator-chart-1.0.0-latest.tgz
_resolve() (
    set +u
    # shellcheck disable=SC1090
    source "${LIB}" >/dev/null 2>&1
    resolve_operator_chart_tgz "$@"
)
chk "release 2.0.0 命中 2.0.0 chart" \
    "${_cdir}/cubestack-operator-chart-2.0.0.tgz" \
    "$(_resolve "${_cdir}" cubestack-operator-chart "" 2.0.0 | cut -f1)"
chk "desired 1.0.0-latest 命中滚动 chart" \
    "${_cdir}/cubestack-operator-chart-1.0.0-latest.tgz" \
    "$(_resolve "${_cdir}" cubestack-operator-chart 1.0.0-latest "" | cut -f1)"
chk "release 优先于 desired(两者都在)" \
    "${_cdir}/cubestack-operator-chart-2.0.0.tgz" \
    "$(_resolve "${_cdir}" cubestack-operator-chart 1.0.0-latest 2.0.0 | cut -f1)"
_cdir2="${TMP}/charts-one"; mkdir -p "${_cdir2}"
cp "${_cdir}/cubestack-operator-chart-2.0.0.tgz" "${_cdir2}/"
chk "目录仅一份 chart → 版本以 chart 自身为准" \
    "2.0.0" \
    "$(_resolve "${_cdir2}" cubestack-operator-chart 9.9.9-latest "" | cut -f2)"

echo "== ⑪ operator tag: 默认跟随 chart, 仅显式 override =="
_tag() ( set +u; source "${LIB}" >/dev/null 2>&1; operator_image_tag_for_helm "$1" )
chk "显式 override" "2.0.0-rc2" "$(_tag 2.0.0-rc2)"
chk "未设 override → chart 默认(空)" "" "$(_tag "")"
# 2026-10-22 实机: 空 override 时函数返回 1, `x="$(...)"` 在 set -e 下让模块静默退出
if ( set -e; set +u; source "${LIB}" >/dev/null 2>&1; _t="$(operator_image_tag_for_helm "")"; [ -z "${_t}" ] ); then
    echo "  ok  set -e 下空 override 赋值不退出"
else
    echo "  FAIL set -e 下空 override 赋值退出/非空"; fail=1
fi
chk_contains "模块只把 override 传给决策函数" 'operator_image_tag_for_helm "${CUBESTACK_OPERATOR_IMAGE_TAG_OVERRIDE:-}"' "${MOD}"
chk_not_contains "IMAGE_TAG 不参与 helm 覆盖" 'operator_image_tag_for_helm "${CUBESTACK_OPERATOR_IMAGE_TAG:-}"' "${MOD}"
chk_not_contains "RELEASE 不隐式覆盖 tag" 'operator_image_tag_for_helm "${CUBESTACK_RELEASE:-}"' "${MOD}"
# 组件版本必须由 operator catalog 决定; installer 不得设置 components.*.version / 组件 image.tag
if grep -qE 'clusterCR\.spec\.components\.[A-Za-z0-9]+\.version|components\.[A-Za-z0-9]+\.values\.image\.tag' "${MOD}"; then
    echo "  FAIL installer 不应覆盖 operator 内组件版本"; fail=1
else
    echo "  ok  installer 不覆盖 operator 内组件版本"
fi

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-cubestack-operator-update: 全部通过"
else
    echo "❌ test-cubestack-operator-update: 存在失败项"
fi
exit "${fail}"
