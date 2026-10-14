#!/bin/bash
# ============================================================
# TOOL: nvidia-chart-images
# DESC: 从 NVIDIA GPU Operator chart 渲染产物提取**完整镜像集**(推送/备料清单的唯一来源)。
# 用法: nvidia-chart-images.sh <chart.tgz|chart目录> [helm --set 参数...]
#   · 输出: 每行一个"上游全限定 ref"(去重排序); 供模块推送(离线)与备料工具 pull+save 使用。
#   · 口径(不依赖 pyyaml —— 部署容器没有 python3-yaml, 见 2026-10-14 实测):
#       ① podspec 里已是完整 ref 的 image 字段(含 / 与 tag)直接取(operator / NFD 等);
#       ② CR 组件三元组 (repository, image, version) 同缩进相邻落地 → 组合 repo/image:version;
#       ③ 组件被 --set 调整(开关/换源)时结果自动跟随 —— 同一组 --set 既喂渲染也喂安装, 不会漂移。
#   · ⚠ driver 镜像的特殊性: usePrecompiled=true 时**实际运行镜像**是
#     driver:<分支>-<内核>-<OS>(operator 依 NFD 内核标签在运行期组合), 渲染产物里只有
#     driver:<分支>占位 —— 调用方须丢弃 `driver:<分支>` 占位行(函数在本工具输出尾部注释标明),
#     另行补入内核化 ref(NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS × 分支)。
#   · 完整性绊线: 核心组件集(operator/toolkit/devicePlugin/dcgmExporter/gfd/migManager/driver-manager)
#     提取缺失时**硬报错**(chart 升级后形态漂移会被立刻发现, 而非静默少推镜像)。
# 依赖: helm + python3(标准库)。
# ============================================================
set -euo pipefail

CHART="${1:?用法: nvidia-chart-images.sh <chart.tgz|chart目录> [--set k=v ...]}"
shift || true

command -v helm >/dev/null 2>&1 || { echo "【错误】未找到 helm" >&2; exit 1; }

_refs="$(helm template gpu-operator "${CHART}" -n gpu-operator "$@" 2>/dev/null | python3 -c '
import sys, re
# k8s 渲染产物是规整 YAML; 用"同缩进相邻行"启发式提取:
#   完整 ref : image: 值含 "/" 且末段含 ":"(tag)  → 直接采用
#   三元组   : image: 值的同缩进 ±3 行窗口内出现 repository: 与 version: → 组合
lines = sys.stdin.read().splitlines()
refs = set()
IMG = re.compile(r"^(\s*)image:\s*\"?([^\"\s]+)\"?\s*$")
# enabled 状态机: 跟踪当前顶层组件(2 空格缩进)与其 enabled 值(4 空格缩进);
# 组件 enabled: false → 其下三元组不采集(禁用组件不进推送/备料集; 启用后自动跟随)。
# 无 enabled 键的组件按"启用"处理(保守采集 —— 漏采才是事故, 多采只是多推, 且完整性绊线兜底)。
CUR = [None, None]   # [顶层组件名, enabled("true"/"false"/None)]
TOP = re.compile(r"^  ([A-Za-z][\w.-]*):\s*$")
ENB = re.compile(r"^    enabled:\s*\"?(true|false)\"?\s*$")
for i, l in enumerate(lines):
    mt = TOP.match(l)
    if mt:
        CUR = [mt.group(1), None]
        continue
    me = ENB.match(l)
    if me and CUR[0]:
        CUR[1] = me.group(1)
        continue
    m = IMG.match(l)
    if not m:
        continue
    indent, val = m.group(1), m.group(2)
    if "/" in val and ":" in val.rsplit("/", 1)[-1]:
        refs.add(val)                      # podspec 完整 ref(operator/NFD 等, 与 CR 无关)
        continue
    if CUR[1] == "false":
        continue                           # 禁用组件的三元组
    repo = ver = None
    keyre = re.compile(re.escape(indent) + r"(repository|version):\s*\"?([^\"\s]+)\"?\s*$")
    for j in range(max(0, i - 3), min(len(lines), i + 4)):
        if j == i:
            continue
        mm = keyre.match(lines[j])
        if not mm:
            continue
        if mm.group(1) == "repository" and repo is None:
            repo = mm.group(2)
        elif mm.group(1) == "version" and ver is None:
            ver = mm.group(2)
    if repo and ver:
        refs.add(repo.rstrip("/") + "/" + val + ":" + ver)
for r in sorted(refs):
    print(r)
')"

[ -n "${_refs}" ] || { echo "【错误】chart 未渲染出任何镜像(helm template 失败? 手工确认)" >&2; exit 1; }

# ---- 完整性绊线: 核心组件必须都在(缺失=chart 形态漂移, 硬失败而不是静默少推) ----
# 注: v26 起 GFD 已并入 device-plugin 镜像(gfd.image=k8s-device-plugin), 故核 k8s-device-plugin 即可。
_missing=""
for _need in "/gpu-operator:" "/container-toolkit:" "/k8s-device-plugin:" "/dcgm-exporter:" \
             "/k8s-mig-manager:" "/k8s-driver-manager:" "/nvidia/driver:"; do
    case "${_refs}" in
        *"${_need}"*) : ;;
        *) _missing="${_missing}${_need} " ;;
    esac
done
if [ -n "${_missing}" ]; then
    echo "【错误】镜像提取不完整, 缺: ${_missing}" >&2
    echo "        → NVIDIA chart 升级后形态可能已变; 请核对本工具的提取逻辑(见文件头口径注释)" >&2
    echo "        已提取: " >&2
    printf '%s\n' "${_refs}" | sed 's/^/          /' >&2
    exit 1
fi

printf '%s\n' "${_refs}"
echo "# 注: 如为 usePrecompiled 模式, 上面 driver:<分支> 行是占位, 实际运行镜像为 driver:<分支>-<内核>-<OS>;" >&2
