#!/bin/bash
# ============================================================
# TOOL: pack-observability-assets — 把 CubeStack 可观测性文本资产装配成**离线包目录**
#
# ── 为什么要这个工具(installer-requirements §5) ──
# 需求文档要求离线包把这些放到部署机 `/opt/cubestack/observability/`:
#   observability/recording-rules/                  ← 6 个 PrometheusRule yaml
#   observability/dashboards/grafana/               ← 11 个 Grafana dashboard json
#   observability/helm/cubestack-bmc-exporter-chart/ ← BMC exporter chart(tgz + digest)
# 本仓库这些资产**已随 git vendored**(deployments/cubestack-addon/...), 所以"仓库/CLI 镜像一起走"
# 的场景本来就能用(模块 08 的回退链第 4 级直接读 vendored)。缺的是**只走 offline-files 的纯离线投递**:
# 本工具把 vendored 源**装配**成 `deployments/offline-files/observability/`, 于是:
#   · sync-to-minio.sh 自动带上它(无需改白名单) → fetch-offline-from-minio.sh 自动拉取(自动发现新子目录)
#   · trim-offline-files.sh 不碰它(它只裁 kubespray/metax-gpu 的镜像与二进制)
#   · 模块 08 / 28_verify_prometheus 的回退链第 3 级读它
# 也可用 --dir 直接产出到需求约定的 /opt/cubestack/observability(单机离线包场景)。
#
# ⚠ 输出目录是**生成物**: 每次运行会先清空三个受管子目录再复制, 保证与 vendored 源一致
#   (否则源里删掉的旧规则会一直残留在离线包里, 部署时被一起 apply)。
#
# 数据源: 仓库内 vendored(不联网; 刷新 vendored 源见 tools/observability/fetch-observability-assets.sh)
# 用法:   bash deployments/scripts/tools/offline/pack-observability-assets.sh
#         bash deployments/scripts/tools/offline/pack-observability-assets.sh --dir /opt/cubestack/observability
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"       # .../deployments/scripts/tools/offline
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

say()  { echo -e "\033[36m→  $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
err()  { echo -e "\033[31m【错误】$*\033[0m" >&2; }

SRC_OBS="${REPO_ROOT}/deployments/cubestack-addon/observability/cubestack"
SRC_BMC="${REPO_ROOT}/deployments/cubestack-addon/bmc-exporter"
OUT_DIR="${REPO_ROOT}/deployments/offline-files/observability"

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)   shift; OUT_DIR="${1:?--dir 需要目录参数}"; [ -n "${OUT_DIR}" ] || { err "--dir 不能为空"; exit 1; } ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(用法见 --help)"; exit 1 ;;
    esac
    shift
done

# ---- 源检查: 缺一个就停, 不产出半套离线包 ----
[ -d "${SRC_OBS}/recording-rules" ]     || { err "源缺失: ${SRC_OBS}/recording-rules(先跑 tools/observability/fetch-observability-assets.sh 刷新)"; exit 1; }
[ -d "${SRC_OBS}/dashboards/grafana" ]  || { err "源缺失: ${SRC_OBS}/dashboards/grafana"; exit 1; }
[ -d "${SRC_BMC}" ]                     || { err "源缺失: ${SRC_BMC}(BMC exporter chart 离线副本)"; exit 1; }
_n_rules="$(find "${SRC_OBS}/recording-rules" -maxdepth 1 -name '*.yaml' | wc -l)"
_n_dash="$(find "${SRC_OBS}/dashboards/grafana" -maxdepth 1 -name '*.json' | wc -l)"
_bmc_tgz="$(find "${SRC_BMC}" -maxdepth 1 -name '*.tgz' | head -1)"
[ "${_n_rules}" -gt 0 ] || { err "recording-rules 里没有 *.yaml"; exit 1; }
[ "${_n_dash}" -gt 0 ]  || { err "dashboards/grafana 里没有 *.json"; exit 1; }
[ -n "${_bmc_tgz}" ]    || { err "${SRC_BMC} 里没有 chart tgz"; exit 1; }

say "装配可观测性离线资产 → ${OUT_DIR}"
echo "  源: recording-rules ${_n_rules} 个 / dashboards ${_n_dash} 个 / bmc chart $(basename "${_bmc_tgz}")"

# ---- 清空受管子目录(输出是生成物; 保证与源一致, 不留旧文件) ----
rm -rf "${OUT_DIR}/recording-rules" "${OUT_DIR}/dashboards" "${OUT_DIR}/helm"
mkdir -p "${OUT_DIR}/recording-rules" "${OUT_DIR}/dashboards/grafana" "${OUT_DIR}/helm/cubestack-bmc-exporter-chart"

# ---- 复制三类资产 ----
cp -f "${SRC_OBS}/recording-rules/"*.yaml      "${OUT_DIR}/recording-rules/"
cp -f "${SRC_OBS}/dashboards/grafana/"*.json   "${OUT_DIR}/dashboards/grafana/"
# BMC chart: tgz + digest 边车一起(模块 33 用 digest 比对是否刷新), 说明文档一并带上便于离线查阅
cp -f "${SRC_BMC}/"*.tgz "${SRC_BMC}/"*.tgz.digest "${OUT_DIR}/helm/cubestack-bmc-exporter-chart/" 2>/dev/null || \
    cp -f "${SRC_BMC}/"*.tgz "${OUT_DIR}/helm/cubestack-bmc-exporter-chart/"
[ -f "${SRC_BMC}/CUBESTACK.md" ] && cp -f "${SRC_BMC}/CUBESTACK.md" "${OUT_DIR}/helm/cubestack-bmc-exporter-chart/"

# ---- 生成 README(git 只跟踪 offline-files 二级的 README.md; 没有它新目录提交后会消失) ----
cat > "${OUT_DIR}/README.md" <<'README_EOF'
# offline-files/observability — CubeStack 可观测性离线资产

**本目录是生成物**, 由 `deployments/scripts/tools/offline/pack-observability-assets.sh` 装配,
源为仓库内 vendored 副本(`deployments/cubestack-addon/observability/cubestack/` 与
`deployments/cubestack-addon/bmc-exporter/`)。**不要手工编辑这里的文件** —— 改了下次装配会被覆盖。

| 子目录 | 内容 | 消费方 |
|---|---|---|
| `recording-rules/` | 6 个 PrometheusRule yaml | 模块 `08_prometheus`(apply 到集群) + `28_verify_prometheus`(逐组断言实际加载) |
| `dashboards/grafana/` | 11 个 Grafana dashboard json(→ ConfigMap, sidecar 自动导入) | 同上 |
| `helm/cubestack-bmc-exporter-chart/` | BMC exporter chart(tgz + digest 边车) | 模块 `33_bmc_exporter`(实际安装用仓库 vendored 副本, 这里供离线包完整性) |

分发: 本目录随 `sync-to-minio.sh` 推到 MinIO, 部署机用 `fetch-offline-from-minio.sh` 拉取
(两者都自动发现新子目录, 无需白名单); `trim-offline-files.sh` 不处理本目录。

模块侧的查找顺序(`08_prometheus.sh` / `28_verify_prometheus.sh` 同一口径):
`CUBESTACK_OBSERVABILITY_DIR` > `/opt/cubestack/observability` > 本目录 > 仓库内 vendored。

刷新: 先 `tools/observability/fetch-observability-assets.sh` 更新 vendored 源(联网机, 从上游
suanova/cubestack 取), **提交**后再跑本工具重新装配。
README_EOF

# ---- 装配清单(便于核对离线包里到底是什么版本) ----
{
    echo "# 由 pack-observability-assets.sh 生成  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "recording_rules: ${_n_rules}"
    echo "dashboards: ${_n_dash}"
    echo "bmc_chart: $(basename "${_bmc_tgz}")"
    echo "--- files ---"
    (cd "${OUT_DIR}" && find recording-rules dashboards helm -type f | sort)
} > "${OUT_DIR}/MANIFEST.txt"

echo "---------------------------------------------"
ok "已装配: ${_n_rules} 条规则 + ${_n_dash} 个看板 + 1 个 chart → ${OUT_DIR}"
echo "  校验: cat ${OUT_DIR}/MANIFEST.txt"
echo "  下一步(纯离线投递):"
echo "    ① 联网机: bash deployments/scripts/tools/offline/sync-to-minio.sh"
echo "    ② 部署机: bash deployments/scripts/tools/offline/fetch-offline-from-minio.sh"
echo "       (或在单机场景直接把本目录拷到 /opt/cubestack/observability)"
