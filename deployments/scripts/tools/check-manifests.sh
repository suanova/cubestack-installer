#!/bin/bash
# ============================================================
# check-manifests.sh — 仓库自有 YAML 清单静态校验(开发期 + CI)
# 目的: YAML 的低级错误(缩进 / Tab / 引号未闭合 / 块标量写坏)只在**部署那一刻**才炸 ——
#   那时人已在集群前、前置模块都跑完了。本脚本把这类错误提前到提交前: 逐个文件解析一遍,
#   失败即列出 `文件:行:列` 与原因。
# 校验范围 = **仓库自有、git 跟踪**的 *.yaml/*.yml(rook/multus/lws 清单、自研 inventory、
#   .github/workflows、docker-compose.yml 等)。
# 排除三类(**都是"看着像 YAML 但确实不是普通 YAML"**, 判据即下面 python 里的 SKIP_* 三行;
#   2026-09-30 逐类反证过, 不是图省事):
#   ① deployments/kubespray/kubespray/  vendored 上游源码树(内含 Jinja / ansible 模板)
#   ② 路径含 /charts/ 或 /templates/     helm chart 的 Go 模板(实测 rook/metax/lws 三份
#      deployment 模板都解析失败 —— {{ }} 不是 YAML)⇒ 这类文件只能靠 helm template 验
#   ③ download-hosts.yml                扩展名是 .yml, 内容却是 **INI 格式** ansible
#      inventory(上游 contrib/offline 的约定), 故无法用 YAML 解析器校验
# 用法: bash check-manifests.sh           # 校验(只读, 不联网, 无需 root)
#       bash check-manifests.sh --quiet   # 只输出违规项
# 退出码: 0=全部可解析; 1=存在解析失败; 2=环境缺依赖(python3 / PyYAML)
# 依赖: python3 + PyYAML —— 缺 PyYAML 时提示安装并退出 2(不能误报成"清单有问题")
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say()  { [ "${QUIET}" = "1" ] || echo -e "\033[36m→ $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
bad()  { echo -e "\033[31m❌ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }

command -v python3 >/dev/null 2>&1 || { bad "缺 python3(本脚本用它做 YAML 解析)"; exit 2; }
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    bad "缺 PyYAML(python3 的 yaml 模块)"
    warn "安装: pip3 install pyyaml  或  apt-get install -y python3-yaml"
    exit 2
fi

# python 侧只负责"发现 + 解析 + 报结果", 输出三种以 | 分隔的行交给 bash 渲染:
#   SKIP|<文件>|<原因>            —— 显式排除(需人工确认的那类)
#   FAIL|<文件>:<行>:<列>|<原因>  —— 解析失败
#   STATS|<已校验>|<跳过>|<失败>  —— 统计
RESULT="$(python3 - "${REPO_ROOT}" <<'PY'
import os, subprocess, sys

root = sys.argv[1]
SKIP_PREFIXES = ("deployments/kubespray/kubespray/",)   # ① vendored 上游树
SKIP_COMPONENTS = ("/charts/", "/templates/")           # ② helm chart 模板
SKIP_FILES = {                                          # ③ 非 YAML 的自有文件(见头部说明)
    "deployments/kubespray/inventory/cubestack-cluster/download-hosts.yml":
        "INI 格式 ansible inventory(扩展名是 .yml, 内容不是 YAML)",
}

import yaml

# ⚠ 发现阶段失败必须**响亮地失败**: 空列表会让上面的 bash 报"0 个通过" —— 那是假绿。
try:
    ls = subprocess.run(["git", "-C", root, "ls-files", "*.yaml", "*.yml"],
                        capture_output=True, text=True, check=True)
except (subprocess.CalledProcessError, FileNotFoundError) as exc:
    sys.stderr.write(f"无法列出仓库文件(需要 git 仓库 + 可用的 git): {exc}\n")
    sys.exit(2)

files = ls.stdout.split()
if not files:
    sys.stderr.write("git ls-files 返回空 —— 仓库快照异常, 不予判定\n")
    sys.exit(2)

checked = skipped = failed = 0
for rel in files:
    if rel in SKIP_FILES:
        skipped += 1
        print(f"SKIP|{rel}|{SKIP_FILES[rel]}")
        continue
    if rel.startswith(SKIP_PREFIXES) or any(c in rel for c in SKIP_COMPONENTS):
        skipped += 1
        continue
    checked += 1
    try:
        # utf-8-sig: 容忍 BOM —— BOM 会让首个文档的键名带上不可见前缀, 上游工具同样会吃到;
        # 这里只做"能不能解析", 不替人改文件。
        with open(os.path.join(root, rel), encoding="utf-8-sig") as fh:
            list(yaml.safe_load_all(fh))
    except Exception as exc:  # noqa: BLE001 —— 解析器异常类型多(Mark/Unicode/IO), 一律按失败报
        failed += 1
        mark = getattr(exc, "problem_mark", None)
        problem = getattr(exc, "problem", None) or str(exc).splitlines()[0]
        loc = f"{rel}:{mark.line + 1}:{mark.column + 1}" if mark else rel
        print(f"FAIL|{loc}|{problem}")
print(f"STATS|{checked}|{skipped}|{failed}")
PY
)"
_py_rc=$?
if [ "${_py_rc}" != "0" ]; then
    bad "清单解析器未正常完成(rc=${_py_rc}, 原因见上方 stderr) —— 不能判定为通过"
    exit 2
fi
if ! grep -q '^STATS|' <<< "${RESULT}"; then
    bad "解析器没有给出统计结果(输出异常) —— 不能判定为通过"
    exit 2
fi

CHECKED=0 SKIPPED=0 FAILED=0
while IFS='|' read -r kind f1 f2 f3; do
    case "${kind}" in
        SKIP)  say "  跳过(非普通 YAML): ${f1} —— ${f2}" ;;
        FAIL)  bad "YAML 解析失败: ${f1} —— ${f2}" ;;
        STATS) CHECKED="${f1}"; SKIPPED="${f2}"; FAILED="${f3}" ;;
    esac
done <<< "${RESULT}"

echo "---------------------------------------------"
if [ "${FAILED}" = "0" ]; then
    ok "清单校验通过(${CHECKED} 个自有 YAML 可解析; 按规则跳过 ${SKIPPED} 个 vendored/模板/INI)"
    exit 0
fi
bad "清单校验失败(${FAILED} 个文件解析不了) —— 修好再提交"
exit 1
