#!/bin/bash
# ============================================================
# test-metallb-pool-check.sh — MetalLB 池冲突预检的**地址展开**回归(离线)
# 覆盖(2026-10-26 CodeRabbit):
#   ① 单 IP / 小 range / 小 CIDR 正常展开
#   ② range 超过 1024 个地址 → 非 0 中止(修复前无上限, 会整段物化并逐个 ping)
#   ③ CIDR 超过 1024 个地址 → 非 0(修复前 list(...hosts())[:1024] 静默截断)
#   ④ IPv6 /64 → 快速非 0(修复前 list(hosts()) 会耗尽部署机内存)
#   ⑤ 多条目合计超过 1024 → 非 0
#   ⑥ IPv6 /64 在 10s 内拒绝(修复前 list(hosts()) 会耗尽部署机内存)
#   ⑦ 已分配 VIP 按整行匹配: _alloc_ips 为多行时, 已分配地址不得再 ping(2026-10-26)
#   ⑧ 远端 IPAddressPool 用 -o json 的 .spec.addresses 比较(jsonpath 输出不是 JSON)
# 被测代码 = 从 01_metallb.sh **原样抽出**的内联 python / 冲突检查循环
# (不连集群、不 ping 真机、不写任何文件)
# 用法: bash deployments/scripts/tools/tests/test-metallb-pool-check.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${MODULE_UNDER_TEST:-${REPO_ROOT}/deployments/scripts/modules/03_addon/01_metallb.sh}"
[ -f "${MOD}" ] || { echo "找不到被测模块: ${MOD}"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
cnt() { printf '%s\n' "$1" | command grep -c . || true; }

# 抽取 _cand_ips="$(python3 ... <<'PY' ... PY 之间的原文
python3 - "${MOD}" > "${TMP}/expand.py" <<'PY' || { echo "FAIL 抽取内联 python 失败"; exit 1; }
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'_cand_ips="\$\(python3 .*?<<\'PY\'\n(.*?)\nPY\n', src, re.S)
if not m:
    sys.exit("找不到 _cand_ips 内联 python")
print(m.group(1))
PY
[ -s "${TMP}/expand.py" ] || { echo "FAIL 抽出的 python 为空"; exit 1; }
run_expand() { python3 "${TMP}/expand.py" "$1"; }

echo "== ① 正常展开 =="
out="$(run_expand '10.0.0.1,10.0.0.10-10.0.0.12')"
chk "单 IP + 小 range 数量" "4" "$(cnt "${out}")"
chk "首地址" "10.0.0.1" "$(printf '%s\n' "${out}" | sed -n 1p)"
out="$(run_expand '10.0.0.0/30')"
chk "/30 主机数" "2" "$(cnt "${out}")"
out="$(run_expand 'not-an-ip,10.0.0.9')"
chk "非法条目被忽略(保留旧行为)" "1" "$(cnt "${out}")"

echo "== ② range 超限(1025 个) =="
run_expand '10.0.0.0-10.0.4.0' > "${TMP}/o2" 2> "${TMP}/e2"; rc=$?
chk "range 超限退出码非 0" "非0" "$([ "${rc}" -ne 0 ] && echo 非0 || echo 0)"
chk "range 超限不输出候选" "0" "$(cnt "$(cat "${TMP}/o2")")"
chk "range 超限提示上限" "1" "$(command grep -c '超过冲突预检上限' "${TMP}/e2" || true)"

echo "== ③ CIDR 超限(/21 = 2046 主机) =="
run_expand '10.0.0.0/21' > "${TMP}/o3" 2> "${TMP}/e3"; rc=$?
chk "CIDR 超限退出码非 0" "非0" "$([ "${rc}" -ne 0 ] && echo 非0 || echo 0)"
chk "不再静默截断(无输出)" "0" "$(cnt "$(cat "${TMP}/o3")")"

echo "== ④ 边界: 恰好 1024 个地址允许 =="
run_expand '10.0.0.0-10.0.3.255' > "${TMP}/o4" 2> "${TMP}/e4"; rc=$?
chk "1024 个地址退出码 0" "0" "${rc}"
chk "1024 个地址全部输出" "1024" "$(cnt "$(cat "${TMP}/o4")")"

echo "== ⑤ 多条目合计超限 =="
run_expand '10.0.0.0/24,10.0.1.0/24,10.0.2.0/24,10.0.3.0/24,10.0.4.0/24' \
    > /dev/null 2> "${TMP}/e5"; rc=$?
chk "合计 >1024 退出码非 0" "非0" "$([ "${rc}" -ne 0 ] && echo 非0 || echo 0)"

echo "== ⑥ IPv6 /64 快速拒绝(不物化整表) =="
timeout 10 python3 "${TMP}/expand.py" '2001:db8::/64' > "${TMP}/o6" 2> "${TMP}/e6"; rc=$?
chk "IPv6 /64 非 0 且未超时" "非0" "$([ "${rc}" -ne 0 ] && [ "${rc}" -ne 124 ] && echo 非0 || echo 0)"
chk "IPv6 /64 提示上限" "1" "$(command grep -c '超过冲突预检上限' "${TMP}/e6" || true)"

echo "== ⑦ 已分配 VIP 按整行匹配(多 VIP 不误报冲突) =="
# 抽取冲突检查循环(_conflicts="" … done <<< "${_cand_ips}"), 用假 SSH 记录 ping 目标。
# _alloc_ips 是多行(每行一个 IP): 旧实现用 `case " ${_alloc_ips} " in *" ${_ip} "*`
# 匹配不到中间/末尾的 IP → 会把本集群已分配 VIP 当成冲突(修复前 ping 全部 3 个)。
{
    echo 'SSH() { printf "%s\n" "$*" >> "${PING_LOG}"; return 1; }'   # ping 一律失败 → 无冲突
    sed -n '/^[[:space:]]*_conflicts=""$/,/^[[:space:]]*done <<</p' "${MOD}"
} > "${TMP}/loop.sh"
[ -s "${TMP}/loop.sh" ] || { echo "FAIL 抽取冲突检查循环失败"; exit 1; }
_pinglog="${TMP}/ping.log"; : > "${_pinglog}"
_alloc_ips=$'10.0.0.2\n10.0.0.3' \
_cand_ips=$'10.0.0.1\n10.0.0.2\n10.0.0.3' \
PING_LOG="${_pinglog}" bash "${TMP}/loop.sh"
chk "只 ping 未分配地址(1 条)" "1" "$(cnt "$(cat "${_pinglog}")")"
chk "未 ping 已分配 VIP(.2/.3)" "0" "$(command grep -cE '10\.0\.0\.(2|3)' "${_pinglog}" || true)"
chk "确实 ping 了未分配地址(.1)" "1" "$(command grep -c 'ping -c1 -W1 10.0.0.1' "${_pinglog}" || true)"

echo "== ⑧ 远端池比较: 用 -o json 的 .spec.addresses(不用 jsonpath) =="
# kubectl jsonpath 打印的是 Go 切片字面量([10.0.0.1-10.0.0.2], 非法 JSON), 旧比较恒判"不同"
# → 每次重跑都 patch(只读权限的部署会失败)。改为解析整对象里的 .spec.addresses。
sed -n '/^_metallb_pool_matches() {/,/^}/p' "${MOD}" > "${TMP}/pool_match.sh"
[ -s "${TMP}/pool_match.sh" ] || { echo "FAIL 抽取 _metallb_pool_matches 失败"; exit 1; }
source "${TMP}/pool_match.sh"
_current='{"apiVersion":"metallb.io/v1beta1","kind":"IPAddressPool","metadata":{"name":"primary"},"spec":{"addresses":["10.66.3.225-10.66.3.226"]}}'
_want='["10.66.3.225-10.66.3.226"]'
chk "一致 → 1(不再无谓 patch)" "1" "$(_metallb_pool_matches "${_current}" "${_want}")"
chk "不一致 → 0" "0" "$(_metallb_pool_matches "${_current}" '["10.66.3.230-10.66.3.231"]')"
chk "远端查询失败/空 → 0(保守 patch)" "0" "$(_metallb_pool_matches "" "${_want}")"
chk "旧 jsonpath 字面量不再被当 JSON → 0" "0" "$(_metallb_pool_matches '[10.66.3.225-10.66.3.226]' "${_want}")"
chk "缺 spec.addresses → 0" "0" "$(_metallb_pool_matches '{"spec":{}}' "${_want}")"
_code() { command grep -v '^[[:space:]]*#' "${MOD}"; }
chk "模块用 -o json 取池" "1" "$(command grep -cF 'get ipaddresspool primary -o json' "${MOD}" || true)"
chk "模块不再用 jsonpath 取池(代码)" "0" "$(_code | command grep -cF "jsonpath='{.spec.addresses}'" || true)"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-metallb-pool-check: 全部通过"; else echo "❌ test-metallb-pool-check: 有失败"; fi
exit "${fail}"
