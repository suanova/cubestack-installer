#!/bin/bash
# ============================================================
# test-multus-iface-detect.sh — Multus 自动网卡探测的"全节点必须有结果"回归(离线)
# 背景(2026-10-26 CodeRabbit):
#   _default_master_iface 旧实现用 `|| true` 忽略单节点 SSH/路由探测失败, 只要有**另一个**
#   节点返回了网卡名, 就会选中它作为集群级 NAD 的 master —— 失败节点若实际网卡不同,
#   该节点上的 Pod 会报 "Link not found"。
# 判据:
#   ① 每个配置节点都返回网卡名且一致 → 正常选出一个;
#   ② 任一节点 SSH 探测失败 / 无默认路由 → 函数返回非 0, 调用方中止(不自动选择);
#   ③ 各节点都返回但网卡名不一致 → 仍交给调用方报"不一致"(函数返回全部候选);
#   ④ 默认路由解析按 "dev <name>" 取网卡, 不写死第 5 列
#      (`default dev eth0 scope link` 的第 5 列是 link, 不是网卡名);
#   ⑤ 选中的 MASTER_IFACE 必须在**每个**节点上存在(只查首个 master 会漏掉缺网卡的 worker)。
# 机制: 从模块**原样抽取** _default_master_iface, 用假 ssh 回放(不连真机)。
# 用法: bash deployments/scripts/tools/tests/test-multus-iface-detect.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${MODULE_UNDER_TEST:-${REPO_ROOT}/deployments/scripts/modules/03_addon/09_multus.sh}"
[ -f "${MOD}" ] || { echo "找不到被测模块: ${MOD}"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
cnt() { printf '%s\n' "$1" | command grep -c . || true; }

sed -n '/^_route_iface_cmd() {/,/^}/p' "${MOD}" > "${TMP}/route_cmd.sh"
[ -s "${TMP}/route_cmd.sh" ] || { echo "FAIL 抽取 _route_iface_cmd 失败"; exit 1; }
sed -n '/^_default_master_iface() {/,/^}/p' "${MOD}" > "${TMP}/fn.sh"
[ -s "${TMP}/fn.sh" ] || { echo "FAIL 抽取 _default_master_iface 失败"; exit 1; }

# 假 ssh: 按目标 IP 末位回放 FAKE_<octet>_MODE / FAKE_<octet>_IFACE
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
target=""
for a in "$@"; do case "${a}" in *@*) target="${a##*@}" ;; esac; done
octet="${target##*.}"
eval "mode=\${FAKE_${octet}_MODE:-ok}"
eval "ifc=\${FAKE_${octet}_IFACE:-ens3}"
case "${mode}" in
    ok)    printf '%s\n' "${ifc}"; exit 0 ;;
    empty) exit 0 ;;
    fail)  exit 1 ;;
esac
FAKE
chmod +x "${TMP}/bin/ssh"

{
    cat <<'SH'
set -e
err() { echo "ERR $*" >&2; }
ssh_user_for_ip() { echo ubuntu; }
node_parse() { IFS=, read -r NODE_ROLE NODE_HOSTNAME NODE_IP _rest <<< "$1"; }
SSH_KEY=/tmp/fake-key
NODES=("master,m1,192.0.2.10,u,-" "worker,w1,192.0.2.11,u,-")
SH
    cat "${TMP}/route_cmd.sh"
    cat "${TMP}/fn.sh"
    cat <<'SH'
if out="$(_default_master_iface)"; then rc=0; else rc=$?; fi
printf '%s' "${out}"
exit "${rc}"
SH
} > "${TMP}/run.sh"

run_detect() {  # <env...> → stdout 写 ${TMP}/out, stderr 写 ${TMP}/err, echo 退出码
    env PATH="${TMP}/bin:${PATH}" "$@" bash "${TMP}/run.sh" > "${TMP}/out" 2> "${TMP}/err"
    echo $?
}

echo "== ① 全部节点一致 → 正常选出 =="
rc="$(run_detect FAKE_10_IFACE=ens3 FAKE_11_IFACE=ens3)"
chk "退出码 0" "0" "${rc}"
chk "输出 ens3" "ens3" "$(cat "${TMP}/out")"
chk "无错误输出" "0" "$(cnt "$(cat "${TMP}/err")")"

echo "== ② 单节点 SSH 探测失败 → 中止自动选择 =="
rc="$(run_detect FAKE_10_IFACE=ens3 FAKE_11_MODE=fail)"
chk "退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk "不输出任何候选网卡" "0" "$(cnt "$(cat "${TMP}/out")")"
chk "点名失败节点与原因" "1" "$(command grep -c '192\.0\.2\.11(探测失败)' "${TMP}/err" || true)"

echo "== ③ 单节点无默认路由 → 中止自动选择 =="
rc="$(run_detect FAKE_10_IFACE=ens3 FAKE_11_MODE=empty)"
chk "退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk "不输出任何候选网卡" "0" "$(cnt "$(cat "${TMP}/out")")"
chk "点名失败节点与原因" "1" "$(command grep -c '192\.0\.2\.11(无默认路由)' "${TMP}/err" || true)"

echo "== ④ 全部节点有结果但不一致 → 返回全部候选(调用方报不一致) =="
rc="$(run_detect FAKE_10_IFACE=ens3 FAKE_11_IFACE=ens4)"
chk "退出码 0" "0" "${rc}"
chk "输出两个候选" "2" "$(cnt "$(cat "${TMP}/out")")"

echo "== ⑤ 调用方必须检查探测返回码 =="
chk "调用方用 if ! 捕获失败" "1" \
    "$(command grep -cF 'if ! _ifaces="$(_default_master_iface)"; then' "${MOD}" || true)"

echo "== ⑥ 默认路由解析: 按 dev 取网卡(不写死第 5 列) =="
# `default dev eth0 scope link` 的第 5 列是 link(不是网卡名); 旧实现会选中 "link",
# 随后 `ip link show dev link` 预检失败。用假 ip 回放各种默认路由形态。
source "${TMP}/route_cmd.sh"
mkdir -p "${TMP}/ipbin"
cat > "${TMP}/ipbin/ip" <<'FAKE'
#!/bin/bash
printf '%s\n' "${FAKE_ROUTE:-}"
FAKE
chmod +x "${TMP}/ipbin/ip"
route_iface() {  # <ip route 输出> → 提取到的网卡
    env FAKE_ROUTE="$1" PATH="${TMP}/ipbin:${PATH}" bash -c "$(_route_iface_cmd)"
}
chk "via 路由 → eth0" "eth0" \
    "$(route_iface 'default via 192.168.1.1 dev eth0 proto dhcp src 192.168.1.100 metric 100')"
chk "直连路由 → eth0(旧实现取到 link)" "eth0" \
    "$(route_iface 'default dev eth0 scope link')"
chk "IPv6 via 路由 → enp1s0" "enp1s0" \
    "$(route_iface 'default via fe80::1 dev enp1s0 proto ra metric 100')"
chk "onlink 路由 → ens3" "ens3" \
    "$(route_iface 'default via 10.0.0.1 dev ens3 onlink')"
chk "无默认路由 → 空" "" "$(route_iface '')"
chk "多行取第一条" "ens3" \
    "$(route_iface $'default via 10.0.0.1 dev ens3 metric 100\ndefault via 10.0.0.1 dev ens4 metric 200')"

echo "== ⑦ 网卡存在性预检: 每个节点都要有 MASTER_IFACE =="
# 旧实现只 ssh 首个 master; worker 缺网卡时仍会 apply 集群级 NAD, 该节点 Pod 报 "Link not found"。
mkdir -p "${TMP}/linkbin"
cat > "${TMP}/linkbin/ssh" <<'FAKE'
#!/bin/bash
target=""
for a in "$@"; do case "${a}" in *@*) target="${a##*@}" ;; esac; done
octet="${target##*.}"
eval "mode=\${FAKE_${octet}_LINK:-ok}"
case "${mode}" in
    ok)      echo OK; exit 0 ;;
    noiface) echo NO_IFACE; exit 0 ;;
    fail)    exit 1 ;;
esac
FAKE
chmod +x "${TMP}/linkbin/ssh"
{
    cat <<'SH'
set -e
err() { echo "ERR $*" >&2; }
ssh_user_for_ip() { echo ubuntu; }
node_parse() { IFS=, read -r NODE_ROLE NODE_HOSTNAME NODE_IP _rest <<< "$1"; }
first_master_ip() { echo 192.0.2.10; }
SSH_KEY=/tmp/fake-key
MASTER_IFACE=eth0
NODES=("master,m1,192.0.2.10,u,-" "worker,w1,192.0.2.11,u,-")
SH
    sed -n '/^# 显式值也做存在性预检/,/^fi$/p' "${MOD}"
} > "${TMP}/preflight.sh"
[ -s "${TMP}/preflight.sh" ] || { echo "FAIL 抽取网卡预检块失败"; exit 1; }
run_preflight() {  # <env...> → stdout/stderr 写 pout/perr, echo 退出码
    env PATH="${TMP}/linkbin:${PATH}" "$@" bash "${TMP}/preflight.sh" > "${TMP}/pout" 2> "${TMP}/perr"
    echo $?
}
rc="$(run_preflight)"
chk "全部节点都有网卡 → 通过" "0" "${rc}"
rc="$(run_preflight FAKE_11_LINK=noiface)"
chk "worker 缺网卡 → 非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk "点名缺网卡的 worker" "1" "$(command grep -c '192\.0\.2\.11(无此网卡)' "${TMP}/perr" || true)"
rc="$(run_preflight FAKE_11_LINK=fail)"
chk "worker 不可达 → 非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk "点名不可达的 worker" "1" "$(command grep -c '192\.0\.2\.11(不可达)' "${TMP}/perr" || true)"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-multus-iface-detect: 全部通过"; else echo "❌ test-multus-iface-detect: 有失败"; fi
exit "${fail}"
