#!/bin/bash
# 幂等重放 cubestack-patches/*.patch 到 kubespray 树。
# 三态: APPLY(新打) / SKIP(已在位) / CONFLICT(打不上, 点名文件并退出非 0)
# 退役判定(--check-retired): 若在**纯净树**上反向应用成功, 说明上游已等于"我们打完的样子" → RETIRE
#
# 用法: cubestack-patch-apply.sh [--root <kubespray 树根>] [--patches <补丁目录>]
#                               {--apply|--check|--check-retired|--list}
#   --root     默认 ${SELF_DIR}/kubespray      (patch -p1 的相对基准)
#   --patches  默认 ${SELF_DIR}/cubestack-patches
#   --apply          重放(幂等): APPLY / SKIP / CONFLICT
#   --check          逐补丁反向 dry-run 验证"已在位"; 在位静默, 缺位打印 MISSING
#   --check-retired  在**纯净树**(如换树后的上游新版本)上跑: 反打干净 = 上游已吸收 → RETIRE,
#                    否则 KEEP(仍需本补丁)。⚠ 在"我们自己的树"上跑必然全 RETIRE(它本就是打完的样子)。
#                    ⚠ 时机(换树升级时): **先 --check-retired, 后 --apply**——只有刚换完的纯净树上
#                    退休判定才有意义; 反过来(打完再跑)恒 RETIRE, 分不清"上游吸收了"与"我们刚打的"。
#                    (升级入口 cubestack-kubespray-upgrade.sh 的 [6]→[7] 就是这个顺序)
#   --list           只列补丁文件名, 不动树
# 退出码: 0 = 成功/全部在位; 1 = 有冲突或缺失; 2 = 参数/环境错误
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SELF_DIR}/kubespray"; PATCH_DIR="${SELF_DIR}/cubestack-patches"
MODE="--check"
while [ $# -gt 0 ]; do case "$1" in --root) ROOT="$2"; shift 2;; --patches) PATCH_DIR="$2"; shift 2;; --apply|--check|--check-retired|--list) MODE="$1"; shift;; *) echo "未知参数: $1" >&2; exit 2;; esac; done

[ -d "${ROOT}" ] || { echo "kubespray 树根不存在: ${ROOT}" >&2; exit 2; }
[ -d "${PATCH_DIR}" ] || { echo "补丁目录不存在: ${PATCH_DIR}" >&2; exit 2; }

rc=0
shopt -s nullglob
for p in "${PATCH_DIR}"/*.patch; do
    name="$(basename "$p")"
    if [ "${MODE}" = "--list" ]; then echo "  ${name}"; continue; fi
    # 在位判定: 反向应用能干净过 → 树已是"打过之后"
    if (cd "${ROOT}" && patch -p1 -R --dry-run -s -f < "${p}" >/dev/null 2>&1); then
        if [ "${MODE}" = "--check-retired" ]; then echo "  RETIRE  ${name}"; else [ "${MODE}" = "--check" ] || echo "  SKIP    ${name}"; fi
        continue
    fi
    if [ "${MODE}" = "--check" ]; then echo "  MISSING ${name}"; rc=1; continue; fi
    if [ "${MODE}" = "--check-retired" ]; then echo "  KEEP    ${name}"; continue; fi
    # --apply: 先前向 dry-run 探路(不留半成品/不产 .rej), 干净才真打
    target="$(grep -m1 '^# 目标:' "$p" | sed 's/^# 目标: //')"; [ -n "${target}" ] || target="(补丁头缺 # 目标:)"
    if ! (cd "${ROOT}" && patch -p1 --dry-run -s -f < "${p}" >/dev/null 2>&1); then
        echo "  CONFLICT ${name} → ${target}"; rc=1; continue
    fi
    if (cd "${ROOT}" && patch -p1 -s -f < "${p}" >/dev/null 2>&1); then echo "  APPLY   ${name}"
    else echo "  CONFLICT ${name} → ${target}"; rc=1; fi
done
exit "${rc}"
