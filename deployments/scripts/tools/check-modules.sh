#!/bin/bash
# ============================================================
# check-modules.sh — 部署模块静态校验(开发期 + CI)
# 目的: 新模块/新 feature 合入前先过一遍本检查, 保证不破坏既有模块框架:
#   ① 全部模块 bash -n 语法通过
#   ② 头部元数据齐全(MODULE/DESC/PHASE/DEFAULT/REPEAT; TOGGLE 可选)
#   ③ MODULE key 唯一且合法(小写字母/数字/下划线, 非 verify_* 保留前缀)
#   ④ PHASE 合法且与所在目录(NN_ 前缀)一致
#   ⑤ REQUIRES 引用的模块都存在; 全量拓扑排序无循环
#   ⑥ 使用远端 kubectl(K/SSH/SSH_CMD/FIRST_MASTER)的模块必须调用 init_remote_kubectl
#      (历史事故: 新模块少复制初始化块 → set -u 下 "K: unbound variable" 部署崩溃)
#   ⑦ TOGGLE 变量在 cluster.conf.example 中有默认声明(防漏配)
#   ⑧ 文件序号 NN_ 与目录序号在发现结果中不重名冲突
# 用法: bash check-modules.sh           # 校验全部模块(只读, 无需 root)
#       bash check-modules.sh --quiet   # 只输出违规项
# 退出码: 0=全部通过; 1=存在违规(列出清单)
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/modules"
CONF_EXAMPLE="$(cd "${SCRIPT_DIR}/../.." && pwd)/config/cluster.conf.example"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "${QUIET}" = "1" ] || echo -e "\033[36m→ $*\033[0m"; }
ok()  { echo -e "\033[32m✅ $*\033[0m"; }
bad() { echo -e "\033[31m❌ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }

FAIL=0
ck_fail() { bad "$*"; FAIL=1; }

say "==== 模块静态校验(${MODULES_DIR}) ===="

# ---------- ① bash -n 语法 ----------
say "[1/8] bash -n 语法检查 ..."
SYNTAX_FAIL=0
while IFS= read -r -d '' f; do
    bash -n "$f" 2>/dev/null || { bad "语法错误: ${f#$MODULES_DIR/}"; SYNTAX_FAIL=1; FAIL=1; }
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${SYNTAX_FAIL}" = "0" ] && ok "全部 $(find "${MODULES_DIR}" -name '*.sh' | wc -l) 个模块语法通过"

# ---------- 元数据解析(与 lib-module.sh 同规则) ----------
meta() { sed -nE "s/^#[[:space:]]*${2}:[[:space:]]*(.*)$/\1/p" "$1" | head -1; }
phase_dir() { case "$(basename "$(dirname "$1")")" in
    01_env) echo "env";; 02_k8s) echo "k8s";; 03_addon) echo "addon";; *) echo "?";; esac; }

say "[2/8] 头部元数据齐全性 ..."
declare -A KEYS=()
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    for field in MODULE DESC PHASE DEFAULT REPEAT; do
        [ -n "$(meta "$f" "$field")" ] || ck_fail "${rel}: 缺少 # ${field}: 元数据"
    done
    key="$(meta "$f" MODULE)"
    if [ -n "${key}" ]; then
        if [ -n "${KEYS[$key]:-}" ]; then ck_fail "MODULE key 重复: ${key} (${KEYS[$key]} 与 ${rel})"; fi
        KEYS[$key]="${rel}"
        case "${key}" in
            *[!a-z0-9_]*) ck_fail "${rel}: MODULE key 含非法字符: ${key}(仅小写字母/数字/下划线)" ;;
        esac
    fi
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${FAIL}" = "0" ] && ok "元数据齐全"

say "[3/8] MODULE key 唯一性 ..."   # 已在上面检查, 这里输出结果
[ "${FAIL}" = "0" ] || true

say "[4/8] PHASE 合法性 + 目录一致性 ..."
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    ph="$(meta "$f" PHASE)"
    case "${ph}" in env|k8s|addon) ;; *) ck_fail "${rel}: PHASE=${ph:-<空>} 非法(需 env/k8s/addon)";; esac
    [ "${ph}" = "$(phase_dir "$f")" ] || ck_fail "${rel}: PHASE=${ph} 与目录 $(basename "$(dirname "$f")") 不一致"
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${FAIL}" = "0" ] || true

# ---------- ⑤ REQUIRES 引用 + 全量拓扑 ----------
say "[5/8] REQUIRES 引用存在性 + 全量无环 ..."
REQ_FAIL=0
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    for d in $(meta "$f" REQUIRES); do
        # 引用必须命中某个模块的 MODULE key
        hit=""
        while IFS= read -r -d '' g; do
            [ "$(meta "$g" MODULE)" = "${d}" ] && { hit=1; break; }
        done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
        [ -n "${hit}" ] || { ck_fail "${rel}: REQUIRES 引用未知模块: ${d}"; REQ_FAIL=1; }
    done
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
# 全量拓扑(Kahn 式, 与 lib-module.sh _topo_sort_requires 同算法): 全部模块必须可排序
declare -A ALLKEYS=() REMAIN=() DONE=()
while IFS= read -r -d '' f; do
    k="$(meta "$f" MODULE)"; ALLKEYS[$k]="$f"; REMAIN[$k]=1
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
ORDER=(); PROG=1
while [ "${#REMAIN[@]}" -gt 0 ] && [ "${PROG}" = "1" ]; do
    PROG=0
    while IFS= read -r -d '' f; do
        k="$(meta "$f" MODULE)"
        [ -n "${REMAIN[$k]:-}" ] || continue
        okdeps=1
        for d in $(meta "$f" REQUIRES); do
            [ -n "${DONE[$d]:-}" ] || { okdeps=0; break; }
        done
        if [ "${okdeps}" = "1" ]; then
            ORDER+=("${k}"); unset REMAIN["$k"]; DONE["$k"]=1; PROG=1
        fi
    done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
done
if [ "${#REMAIN[@]}" -gt 0 ]; then
    ck_fail "REQUIRES 依赖循环(无法排序): ${!REMAIN[*]}"
else
    ok "REQUIRES 全量拓扑排序通过(${#ORDER[@]} 个模块无环)"
fi

# ---------- ⑥ init_remote_kubectl 使用检查 ----------
say "[6/8] 远端 kubectl 初始化(K/SSH)调用检查 ..."
INIT_MISS=0
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    # 使用 K/SSH/SSH_CMD/FIRST_MASTER 的模块必须调用 init_remote_kubectl
    uses_k=$(grep -cE '\$\{K\}|"\$\{K\}|SSH_CMD' "$f" 2>/dev/null)
    uses_ssh=$(grep -cE 'SSH "\$\{K\}"|SSH_CMD' "$f" 2>/dev/null)
    if [ "${uses_k}" -gt 0 ] || [ "${uses_ssh}" -gt 0 ]; then
        grep -q 'init_remote_kubectl' "$f" || { ck_fail "${rel}: 使用了 K/SSH 但未调用 init_remote_kubectl(历史事故: unbound K 崩溃)"; INIT_MISS=1; }
    fi
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${INIT_MISS}" = "0" ] && ok "使用 K/SSH 的模块均已调用 init_remote_kubectl"

# ---------- ⑦ TOGGLE 与 cluster.conf.example 一致性 ----------
say "[7/8] TOGGLE 变量在 cluster.conf.example 声明 ..."
if [ -f "${CONF_EXAMPLE}" ]; then
    TOG_MISS=0
    while IFS= read -r -d '' f; do
        tgl="$(meta "$f" TOGGLE)"
        [ -n "${tgl}" ] || continue
        grep -qE "${tgl}=" "${CONF_EXAMPLE}" || { ck_fail "$(basename "$f"): TOGGLE=${tgl} 未在 cluster.conf.example 中声明默认值"; TOG_MISS=1; }
    done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
    [ "${TOG_MISS}" = "0" ] && ok "全部 TOGGLE 变量均有 cluster.conf.example 默认值"
else
    warn "  未找到 ${CONF_EXAMPLE}, 跳过 TOGGLE 一致性检查"
fi

# ---------- ⑧ 文件序号与目录 ----------
say "[8/8] 文件名序号规范(NN_ 前缀) ..."
NUM_FAIL=0
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    base="$(basename "$f")"
    case "${base}" in
        [0-9][0-9]_*) ;;
        *) ck_fail "${rel}: 文件名缺 NN_ 序号前缀(需 01_xxx.sh 格式)"; NUM_FAIL=1 ;;
    esac
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${NUM_FAIL}" = "0" ] && ok "文件名序号规范"

echo "---------------------------------------------"
if [ "${FAIL}" = "0" ]; then
    ok "模块校验全部通过(${#ALLKEYS[@]} 个模块)"
    exit 0
else
    bad "模块校验存在违规(${FAIL} 类问题), 修复后重试"
    exit 1
fi
