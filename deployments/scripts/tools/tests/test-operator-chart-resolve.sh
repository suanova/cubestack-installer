#!/bin/bash
# ============================================================
# test-operator-chart-resolve.sh — operator chart 定位回归
#
# release 树的 chart 文件名不带版本号(tree.tsv 不重命名制品), 版本只在
# Chart.yaml(issue #183)。resolve_operator_chart_tgz 必须:
#   ① 接受 <name>.tgz, 版本从 Chart.yaml 读;
#   ② 仍然优先匹配 desired/release 版本(同目录有多个候选时);
#   ③ 找不到时返回 1, 不猜。
# 同时校验 operator_chart_dir_extras 会把无版本号残留当作多余文件清理。
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${ROOT}/deployments/scripts/lib-common.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

# lib-common 顶层会 source 校验器/门禁并探测宿主, 单测只抽取 chart 定位/tag 函数块。
sed -n '/^operator_image_tag_for_helm() {/,/^# ---------------- 共享 nginx/p' "${LIB}" | sed '$d' > "${TMP}/lib-chart.sh"
# shellcheck disable=SC1090
source "${TMP}/lib-chart.sh"

mk_chart() {   # <out.tgz> <version>
    local out="$1" ver="$2" src
    src="$(mktemp -d "${TMP}/src.XXXXXX")"
    printf 'apiVersion: v2\nname: cubestack-operator-chart\nversion: %s\n' "${ver}" > "${src}/Chart.yaml"
    tar -C "${src}" -czf "${out}" .
}

WANT="2.1.0-shaac48dd0"
echo "== ① 无版本号文件名 =="
mkdir -p "${TMP}/unversioned"
mk_chart "${TMP}/unversioned/cubestack-operator-chart.tgz" "${WANT}"
out="$(resolve_operator_chart_tgz "${TMP}/unversioned" cubestack-operator-chart "")" || out=""
chk "按 Chart.yaml 解析" "${TMP}/unversioned/cubestack-operator-chart.tgz"$'\t'"${WANT}" "${out}"

echo "== ② desired 版本匹配无版本号文件 =="
out="$(resolve_operator_chart_tgz "${TMP}/unversioned" cubestack-operator-chart "${WANT}")" || out=""
chk "desired 命中" "${TMP}/unversioned/cubestack-operator-chart.tgz"$'\t'"${WANT}" "${out}"

echo "== ③ desired 不匹配时回退唯一候选 =="
out="$(resolve_operator_chart_tgz "${TMP}/unversioned" cubestack-operator-chart "9.9.9")" || out=""
chk "唯一候选仍可用" "${TMP}/unversioned/cubestack-operator-chart.tgz"$'\t'"${WANT}" "${out}"

echo "== ④ 多候选取版本匹配的那份 =="
mkdir -p "${TMP}/multi"
mk_chart "${TMP}/multi/cubestack-operator-chart-2.0.0.tgz" "2.0.0"
mk_chart "${TMP}/multi/cubestack-operator-chart.tgz" "${WANT}"
out="$(resolve_operator_chart_tgz "${TMP}/multi" cubestack-operator-chart "${WANT}" "2.1.0")" || out=""
chk "选中无版本号的新 chart" "${TMP}/multi/cubestack-operator-chart.tgz"$'\t'"${WANT}" "${out}"

echo "== ⑤ 缺失返回 1 =="
mkdir -p "${TMP}/empty"
if resolve_operator_chart_tgz "${TMP}/empty" cubestack-operator-chart "${WANT}" >/dev/null; then rc=0; else rc=$?; fi
chk "无候选返回 1" "1" "${rc}"

echo "== ⑥ 残留清理包含无版本号文件 =="
extras="$(operator_chart_dir_extras "${TMP}/multi" cubestack-operator-chart cubestack-operator-chart-2.0.0.tgz)"
chk "无版本号 chart 视为多余" "cubestack-operator-chart.tgz" "${extras}"
extras="$(operator_chart_dir_extras "${TMP}/multi" cubestack-operator-chart cubestack-operator-chart.tgz)"
chk "保留无版本号 chart" "cubestack-operator-chart-2.0.0.tgz" "${extras}"

echo "== ⑦ release 默认镜像 tag =="
chk "override 最优先" "manual-tag" "$(operator_image_tag_for_helm "manual-tag" "${WANT}")"
chk "无 override 用 release 默认" "${WANT}" "$(operator_image_tag_for_helm "" "${WANT}")"
chk "都为空回到 chart 默认" "" "$(operator_image_tag_for_helm "" "")"

echo "== ⑧ 只给 desired(无 release)也扫描 Chart.yaml =="
out="$(resolve_operator_chart_tgz "${TMP}/multi" cubestack-operator-chart "${WANT}")" || out=""
chk "desired 命中无版本号 chart" "${TMP}/multi/cubestack-operator-chart.tgz"$'\t'"${WANT}" "${out}"

echo "== ⑨ 引号与嵌套 version =="
mkdir -p "${TMP}/quoted-src"
printf 'name: cubestack-operator-chart\nversion: "%s"\ndependencies:\n  - name: sub\n    version: 0.0.0\n' \
    "${WANT}" > "${TMP}/quoted-src/Chart.yaml"
tar -C "${TMP}/quoted-src" -czf "${TMP}/quoted.tgz" .
chk "去引号且忽略嵌套 version" "${WANT}" "$(operator_chart_version "${TMP}/quoted.tgz")"

echo "== ⑩ 子 chart 清单在前时取父 chart =="
mkdir -p "${TMP}/ordered-src/cubestack-operator-chart/charts/sub"
printf 'name: sub\nversion: 9.9.9\n' > "${TMP}/ordered-src/cubestack-operator-chart/charts/sub/Chart.yaml"
printf 'name: cubestack-operator-chart\nversion: %s\n' "${WANT}" > "${TMP}/ordered-src/cubestack-operator-chart/Chart.yaml"
tar -C "${TMP}/ordered-src" -czf "${TMP}/ordered.tgz" \
    cubestack-operator-chart/charts/sub/Chart.yaml cubestack-operator-chart/Chart.yaml
chk "取最浅 Chart.yaml" "${WANT}" "$(operator_chart_version "${TMP}/ordered.tgz")"

[ "${fail}" = "0" ] && echo "✅ operator chart 定位回归通过" || { echo "❌ operator chart 定位回归失败"; exit 1; }
