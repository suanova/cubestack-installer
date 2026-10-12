#!/bin/bash
# ============================================================
# TOOL: cluster-teardown —— 优雅覆盖: 按安装登记"反序"卸载集群内已装组件
# 设计: docs/graceful-overwrite/design.md(方案 A: 模块自持卸载段)
#   · 候选 = 声明 `# UNINSTALL: 1` 的模块 ∪ 登记(ConfigMap cubestack-install-record)中的组件;
#   · 拆序 = 登记 seq 降序 → 未登记者按模块文件序反排插后 → ceph 强制压轴(安全不变量);
#   · 逐组件以 CUBESTACK_MODULE_ACTION=uninstall 调用其模块脚本(模块内存在性检查, 幂等);
#   · 失败/超时 → 告警不中止(后续 ceph 安全序与 kubeadm reset 兜底); 收尾汇总。
# 用法:
#   cluster-teardown.sh --list               # 只读: 打印登记表 + 计划拆序(--raw 输出 TSV 供测试)
#   cluster-teardown.sh --uninstall [--yes]  # 执行反序优雅卸载(--yes / CUBESTACK_ASSUME_YES=1 免倒计时)
#   · 非交互且未 --yes → 跳过卸载并醒目警告(节点旧集群 reset 前置会再次要求 --yes);
#   · 测试钩子: CUBESTACK_TEARDOWN_TEST_INVENTORY=<file> 以夹具 JSON 代替读集群(离线夹具用)。
# 数据源: cluster.conf (NODES 等) + 集群内 ConfigMap cubestack-install-record(kube-system)
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/../../lib-common.sh"
# shellcheck source=lib-module.sh
# ★ lib-common 被 source 时会以自身目录覆盖 SCRIPT_DIR, 故此处内联定位(与 deploy-cluster.sh 同款)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-module.sh"
load_config
discover_modules   # MODULE_KEY/MODULE_SCRIPT(文件序)供候选枚举

CM_NS="kube-system"
CM_NAME="cubestack-install-record"
COMPONENT_TIMEOUT="${TEARDOWN_COMPONENT_TIMEOUT:-600}"
CONFIRM_SLEEP="${TEARDOWN_CONFIRM_SLEEP:-30}"
TEST_INV="${CUBESTACK_TEARDOWN_TEST_INVENTORY:-}"

ACTION=""; ASSUME_YES="${CUBESTACK_ASSUME_YES:-0}"; RAW=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)      ACTION=list; shift ;;
        --uninstall) ACTION=uninstall; shift ;;
        --raw)       RAW=1; shift ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        -h|--help)   sed -n '3,15p' "$0"; exit 0 ;;
        *) err "未知参数: $1(用法: $0 --list [--raw] | --uninstall [--yes])"; exit 1 ;;
    esac
done
[ -n "${ACTION}" ] || { err "用法: $0 --list [--raw] | --uninstall [--yes]"; exit 1; }

# ---------------- 读登记(读不到 → 空登记, 调用方走全量探测降级) ----------------
read_inventory() {
    if [ -n "${TEST_INV}" ]; then
        [ -f "${TEST_INV}" ] || { printf '{"schema":1,"components":[]}'; return 0; }
        cat "${TEST_INV}"; return 0
    fi
    init_remote_kubectl >/dev/null 2>&1 || { printf '{"schema":1,"components":[]}'; return 0; }
    local j
    j="$( (SSH "${K} -n ${CM_NS} get cm ${CM_NAME} -o json 2>/dev/null") || true)"
    if [ -z "${j}" ]; then printf '{"schema":1,"components":[]}'; return 0; fi
    printf '%s' "${j}" | python3 -c '
import json, sys
try:
    cm = json.load(sys.stdin)
    rec = json.loads((cm.get("data") or {}).get("record.json") or "{}")
    if not isinstance(rec.get("components"), list):
        rec = {"schema": 1, "components": []}
except Exception:
    rec = {"schema": 1, "components": []}
print(json.dumps(rec, ensure_ascii=False))
'
}

# ---------------- 拆序 ----------------
# <inventory_json_file> → stdout: <key>\t<record|probe>\t<模块相对路径>(按拆序)
compute_order() {   # <inventory_json_file>
    local invf="$1" _mf _i _un
    _mf="$(mktemp)"
    for _i in "${!MODULE_KEY[@]}"; do
        _un="$(module_meta "${MODULES_DIR}/${MODULE_SCRIPT[$_i]}" UNINSTALL)"
        [ "${_un}" = "1" ] || continue
        printf '%s\t%s\n' "${MODULE_KEY[$_i]}" "${MODULE_SCRIPT[$_i]}" >> "${_mf}"
    done
    python3 - "${_mf}" "${invf}" <<'PY'
import json, sys
mods = {}   # key -> script(插入序 = 模块文件序)
for line in open(sys.argv[1]):
    k, s = line.rstrip("\n").split("\t")
    mods[k] = s
try:
    rec = json.load(open(sys.argv[2]))
except Exception:
    rec = {}
comps = {}
for c in (rec.get("components") or []):
    if isinstance(c, dict) and c.get("key"):
        comps[c["key"]] = c
# 主序: 有登记 seq 的按 seq 降序; 次序: 其余 UNINSTALL 模块按文件序反排; ceph 强制压轴
recorded = [k for k in mods if k in comps and isinstance(comps[k].get("seq"), int)]
recorded.sort(key=lambda k: comps[k]["seq"], reverse=True)
rest = [k for k in mods if k not in recorded][::-1]
seq = recorded + rest
if "ceph" in seq:
    seq.remove("ceph")
    seq.append("ceph")
for k in seq:
    print("%s\t%s\t%s" % (k, "record" if k in recorded else "probe", mods[k]))
PY
    rm -f "${_mf}"
}

print_inventory() {   # <inventory_json_file>(全部登记组件; 含无卸载动作的 base 组件 — 仅信息)
    python3 - "$1" <<'PY'
import json, sys
try:
    rec = json.load(open(sys.argv[1]))
except Exception:
    rec = {}
comps = rec.get("components") or []
if not comps:
    print("  <登记为空: 无记录组件(存量集群将走全量探测降级路径)>")
for c in sorted(comps, key=lambda c: c.get("seq", 0)):
    print("  seq=%-3s %-24s 首装=%s  状态=%s" % (
        c.get("seq", "?"), c.get("key", "?"),
        c.get("firstInstalledAt", "?"), c.get("status", "?")))
PY
}

print_order() {   # <inventory_json_file>
    compute_order "$1" | awk -F'\t' '{printf "  %2d. %-24s [%s]\n", NR, $1, ($2=="record" ? "登记" : "探测降级")}'
}

# ---------------- 执行 ----------------
# 组件卸载后把登记里该组件标 uninstalled(审计 + 中断可续; 失败仅告警)
mark_uninstalled() {   # <key>
    [ -n "${TEST_INV}" ] && return 0
    [ -n "${K:-}" ] || return 0
    local key="$1" j new
    j="$( (SSH "${K} -n ${CM_NS} get cm ${CM_NAME} -o json 2>/dev/null") || true)"
    [ -n "${j}" ] || return 0
    new="$(printf '%s' "${j}" | KEY="${key}" python3 -c '
import json, os, sys
key = os.environ["KEY"]
cm = json.load(sys.stdin)
try:
    rec = json.loads((cm.get("data") or {}).get("record.json") or "{}")
except Exception:
    rec = {}
for c in (rec.get("components") or []):
    if isinstance(c, dict) and c.get("key") == key:
        c["status"] = "uninstalled"
cm.setdefault("data", {})["record.json"] = json.dumps(rec, ensure_ascii=False)
print(json.dumps(cm))
')" || return 0
    printf '%s' "${new}" | SSH "${K} apply -f -" >/dev/null 2>&1 \
        || warn "  登记状态更新失败: ${key}(不影响卸载)"
}

run_component() {   # <key> <script_rel>  → 0=卸了; 1=失败/超时
    local key="$1" rel="$2" mod="${MODULES_DIR}/${rel}"
    [ -f "${mod}" ] || { warn "  模块脚本缺失: ${mod}(跳过 ${key})"; return 1; }
    say "  ▶ 卸载 ${key}(${rel})"
    if CUBESTACK_MODULE_ACTION=uninstall timeout -k 15 "${COMPONENT_TIMEOUT}" bash "${mod}"; then
        ok "  ✔ ${key} 已卸载"
        mark_uninstalled "${key}"
        return 0
    fi
    warn "  ✖ ${key} 卸载失败/超时(${COMPONENT_TIMEOUT}s) —— 继续(后续 ceph 安全序与 k8s 覆盖兜底)"
    return 1
}

# ---------------- main ----------------
_invf="$(mktemp)"
trap 'rm -f "${_invf}"' EXIT
read_inventory > "${_invf}"

case "${ACTION}" in
    list)
        if [ "${RAW}" = "1" ]; then
            compute_order "${_invf}"
            exit 0
        fi
        say "==== 安装登记(ConfigMap ${CM_NAME} @ ${CM_NS}) ===="
        print_inventory "${_invf}"
        echo ""
        say "==== 计划拆序(反序优雅卸载; 仅列可调用组件) ===="
        print_order "${_invf}"
        ;;
    uninstall)
        _order="$(compute_order "${_invf}")"
        if [ -z "${_order}" ]; then
            say "无需卸载(登记为空且无可行卸载组件)"
            exit 0
        fi
        say "==== 优雅覆盖: 按安装顺序反序卸载已装组件(候选 $(printf '%s\n' "${_order}" | wc -l) 个) ===="
        print_inventory "${_invf}"
        echo ""
        print_order "${_invf}"
        # 登记了但无卸载动作的组件(如 base) → 明确告知(不算失败)
        _noact="$(python3 - "${_invf}" "${_order}" <<'PY'
import json, sys
try:
    rec = json.load(open(sys.argv[1]))
except Exception:
    rec = {}
in_order = set(l.split("\t")[0] for l in sys.argv[2].splitlines() if l.strip())
out = [c.get("key", "?") for c in (rec.get("components") or []) if c.get("key") not in in_order]
print(" ".join(out))
PY
)"
        [ -n "${_noact}" ] && say "  (登记中无卸载动作的组件, 随 K8s 覆盖消亡: ${_noact})"
        if [ -n "${TEST_INV}" ]; then
            warn "  测试钩子生效(CUBESTACK_TEARDOWN_TEST_INVENTORY): 仅打印, 不实际执行"
            exit 0
        fi
        if [ "${ASSUME_YES}" != "1" ]; then
            if [ -t 0 ]; then
                say "将逐个调用以上组件的卸载逻辑(存在性检查→优雅停→卸载)。${CONFIRM_SLEEP}s 后继续(Ctrl-C 中止)..."
                _c="${CONFIRM_SLEEP}"
                while [ "${_c}" -gt 0 ]; do printf "\r  ⏳ %2d 秒" "${_c}"; sleep 1; _c=$((_c - 1)); done
                printf "\r  %s\n" "开始卸载..."
            else
                warn "非交互且未 --yes: 跳过优雅卸载(继续覆盖流程; 节点旧集群 reset 前置会再次要求 --yes)"
                exit 0
            fi
        fi
        init_remote_kubectl || { err "集群不可达(SSH 初始化失败), 无法执行卸载"; exit 1; }
        SSH "${K} get ns ${CM_NS} >/dev/null 2>&1" || { err "集群不可达(远端 kubectl 探测失败), 无法执行卸载"; exit 1; }
        _n_ok=0; _n_fail=0
        while IFS=$'\t' read -r _key _src _rel; do
            [ -n "${_key}" ] || continue
            if run_component "${_key}" "${_rel}"; then _n_ok=$((_n_ok + 1)); else _n_fail=$((_n_fail + 1)); fi
        done <<< "${_order}"
        echo ""
        say "优雅卸载完成: 成功 ${_n_ok} 个, 失败/跳过 ${_n_fail} 个"
        if [ "${_n_fail}" -gt 0 ]; then
            warn "有组件未完全卸净 —— 后续 ceph 安全序(⓪ 泛化扫描)与 kubeadm reset 将兜底"
        fi
        exit 0
        ;;
esac
