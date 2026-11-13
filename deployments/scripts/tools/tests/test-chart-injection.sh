#!/bin/bash
# ============================================================
# test-chart-injection.sh — 组件 chart / model bundle 注入的纯离线回归
# 背景(2.1): operator 镜像不再内嵌组件 chart 与 model bundle, 内容由 installer 投递:
#   · chart → 集群 registry <REG>/suanova/<chart-name>:<Chart.yaml version>
#     CR spec.components.<key>.version 告诉 operator 用哪个版本
#   · model bundle → ConfigMap cubestack-model-bundles-<digest12>, CR bundleArchive 引用
# 机制: 从 lib-common.sh 原样抽取三个函数, 直接断言解析/映射/体积门禁。
#   推送与 ConfigMap 写入需要集群与 helm, 不在这里覆盖(那是 e2e 的事)。
# 用法: bash deployments/scripts/tools/tests/test-chart-injection.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${LIB_UNDER_TEST:-${REPO_ROOT}/deployments/scripts/lib-common.sh}"
[ -f "${LIB}" ] || { echo "找不到被测库: ${LIB}"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

sed -n '/^chart_archive_name_version() {/,/^}/p' "${LIB}" > "${TMP}/fn.sh"
sed -n '/^chart_cr_key() {/,/^}/p' "${LIB}" >> "${TMP}/fn.sh"
sed -n '/^ensure_model_bundles_configmap() {/,/^}/p' "${LIB}" >> "${TMP}/fn.sh"
for f in chart_archive_name_version chart_cr_key ensure_model_bundles_configmap; do
    grep -q "^$f" "${TMP}/fn.sh" || { echo "FAIL 抽取 $f 失败"; exit 1; }
done

# 依赖桩: lib-common 的日志/远端执行
cat > "${TMP}/stub.sh" <<'EOS'
say()  { :; }
ok()   { :; }
warn() { echo "WARN $*" >&2; }
vlog() { :; }
err()  { echo "ERR $*" >&2; }
SSH()  { return 1; }          # 不会有集群: 任何远端写都必须失败而不是假装成功
K="kubectl"
EOS

run() { bash -c 'source "$1"; source "$2"; shift 2; "$@"' _ "${TMP}/stub.sh" "${TMP}/fn.sh" "$@"; }

echo "== ① chart 名/版本解析 =="
mkdir -p "${TMP}/c/mychart"
printf 'apiVersion: v2\nname: cubepilot-chart\nversion: 2.1.0\n' > "${TMP}/c/mychart/Chart.yaml"
tar -czf "${TMP}/c/cubepilot-chart.tgz" -C "${TMP}/c" mychart
chk "解析 name/version" "$(printf 'cubepilot-chart\t2.1.0')" "$(run chart_archive_name_version "${TMP}/c/cubepilot-chart.tgz")"

# 缺 Chart.yaml 必须失败(否则会把空版本注入 CR)
mkdir -p "${TMP}/c/broken/nope"; : > "${TMP}/c/broken/nope/values.yaml"
tar -czf "${TMP}/c/broken.tgz" -C "${TMP}/c/broken" nope
run chart_archive_name_version "${TMP}/c/broken.tgz" >/dev/null 2>&1
chk "缺 Chart.yaml 时返回非零" "1" "$?"

echo "== ② chart → CR 组件键映射 =="
chk "cubepilot"                     "cubepilot"                  "$(run chart_cr_key cubepilot-chart)"
chk "cuberouter"                    "cuberouter"                 "$(run chart_cr_key cuberouter-chart)"
chk "controller-manager"            "cubestackControllerManager" "$(run chart_cr_key cubestack-controller-manager-chart)"
chk "portal"                        "cubestackPortal"            "$(run chart_cr_key cubestack-portal-chart)"
chk "operator 自身不注入"            ""                           "$(run chart_cr_key cubestack-operator-chart)"
chk "未知 chart 不注入"              ""                           "$(run chart_cr_key lws)"

echo "== ③ model bundle 归档 → ConfigMap =="
head -c 1024 /dev/urandom > "${TMP}/small.tgz"
want="cubestack-model-bundles-$(sha256sum "${TMP}/small.tgz" | cut -c1-12)"
# apply 桩: 把 stdin 存下来供断言(函数内部的 SSH ... apply -f - 会读到它)
out="$(APPLY_CAPTURE="${TMP}/applied.yaml" bash -c '
  source "$1"; source "$2"
  SSH() { cat > "${APPLY_CAPTURE}"; return 0; }
  ensure_model_bundles_configmap "$3" cubestack-system' _ "${TMP}/stub.sh" "${TMP}/fn.sh" "${TMP}/small.tgz")"
chk "ConfigMap 名带 digest" "${want}" "${out}"
grep -q "name: ${want}" "${TMP}/applied.yaml" 2>/dev/null \
    && echo "  ok  ConfigMap manifest 用了同一名字" \
    || { echo "  FAIL ConfigMap manifest 未写入"; fail=1; }
grep -q "model-bundles.tgz: " "${TMP}/applied.yaml" 2>/dev/null \
    && echo "  ok  binaryData 含 model-bundles.tgz" \
    || { echo "  FAIL binaryData 缺 key"; fail=1; }

echo "== ④ 体积门禁(ConfigMap 单对象上限) =="
head -c 1000000 /dev/zero > "${TMP}/big.tgz"
run ensure_model_bundles_configmap "${TMP}/big.tgz" cubestack-system >/dev/null 2>&1
chk "超过 ~1MiB 时报错" "1" "$?"

echo "== ⑤ 归档缺失时报错 =="
run ensure_model_bundles_configmap "${TMP}/nope.tgz" cubestack-system >/dev/null 2>&1
chk "缺失归档报错" "1" "$?"

echo "== ⑥ 归档在 release 树里的位置 =="
# 回归: release 的 components/model-collection.yaml 把归档落在
# offline-files/model-collection/, 与 OFFLINE_DIR(offline-files/cubestack-operator)同级。
# 曾经写成 ${OFFLINE_DIR}/model-collection/... → 多一层, 永远找不到, 只 warn 后跳过注入。
_tool="$(dirname "${BASH_SOURCE[0]}")/../k8s/cubestack-component-update.sh"
_expr="$(sed -n 's/^ *\(_bundle_archive=.*\)$/\1/p' "${_tool}" | head -1)"
chk "工具里能定位到归档路径表达式" "yes" "$( [ -n "${_expr}" ] && echo yes )"

mkdir -p "${TMP}/tree/offline-files/model-collection" "${TMP}/tree/offline-files/cubestack-operator"
: > "${TMP}/tree/offline-files/model-collection/model-collection-bundles.tgz"
_resolved="$(OFFLINE_FILES_ROOT="${TMP}/tree/offline-files" \
             OFFLINE_DIR="${TMP}/tree/offline-files/cubestack-operator" \
             bash -c "source /dev/stdin <<< '${_expr}'; printf '%s' \"\${_bundle_archive}\"" )"
chk "路径解析到 release 树的 model-collection/" \
    "${TMP}/tree/offline-files/model-collection/model-collection-bundles.tgz" "${_resolved}"

# 开发树(未设 OFFLINE_FILES_ROOT)时回退到 OFFLINE_DIR/.., 同样命中。
_resolved_dev="$(env -u OFFLINE_FILES_ROOT \
             OFFLINE_DIR="${TMP}/tree/offline-files/cubestack-operator" \
             bash -c "source /dev/stdin <<< '${_expr}'; printf '%s' \"\${_bundle_archive}\"" )"
chk "开发树回退路径同样命中" \
    "${TMP}/tree/offline-files/model-collection/model-collection-bundles.tgz" \
    "$(cd "$(dirname "${_resolved_dev}")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "${_resolved_dev}")")"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-chart-injection: 全部通过"; else echo "❌ test-chart-injection: 有失败"; exit 1; fi
