#!/bin/bash
# 回归锚点: 10_api_local_lb.sh 的 fail-closed 契约(**离线**: 不连集群、不碰任何真实节点)
#
# 夹具: 节点 IP 一律用 RFC 5737 TEST-NET-1(192.0.2.0/24) —— 该网段全局不可路由, SSH 必然
#       连接超时, 因此本测试**结构上不可能**碰到真实机器, 也不需要任何集群。
#       KUBE_VIP_ENABLED=false 让 api_entry_addr() 走 node 分支(不做 VIP 探测, 不拖时间)。
#
# 判别锚点(R9 修复的两个静默假成功缺陷 —— **修复前这两条会 EXIT=0 并打印 ✅**):
#   ① enabled  模式 + 节点不可达 → 退出码必须非 0
#      (修复前: `converge_hosts … && vlog …` 吞掉 SSH 失败, 随后无条件打印 "✅ …已收敛到 …")
#   ② disabled 模式 + 节点不可达 → 退出码必须非 0
#      (修复前: 不可达被当成"已干净", 打印 "✅ 清理完成")
#   ③ `_workers` / `_all_nodes` 的退出码不许依赖"末节点角色"
#      (修复前: 末节点是 master 时函数返回 1 → 将来有人写 `IPS=$(_all_nodes)` 会在 set -e 下静默中止模块)
#   ④ 源码契约(防"简化"回去): 不许再出现 `… && vlog …` / `… || true` 这类吞失败写法;
#      清理前必须有显式探活; 删除后必须有 crictl 复核
#   · (R10, 对应测试 §⑥) 关闭态末尾必须提示"随后重跑 k8s_deploy" —— 只提示不拦停
#      (删 manifest 是本模块的活, 把 kubelet.conf 改回域名是上游 k8s_deploy 的活;
#       不提示的话, 只跑 `--steps api_local_lb` 关开关会留下 kubelet 仍指 localhost 的窗口)
#
# 用法:
#   bash deployments/scripts/tools/tests/test-api-local-lb.sh
#
# 变异实验(证明本锚点真能抓缺陷 —— 拿修复前的模块跑, ①③④⑤ 必须转红):
#   ⚠ 变异体必须放在**被测模块同目录**: 模块用 `source ../../lib-common.sh`(相对自身路径)定位库,
#     拷到 /tmp 会因找不到 lib-common 而在 set -e 下立刻死掉 —— 那会让"退出码非 0"变成**假阳性**
#     (本锚点第一版就被这么骗过, 所以 ① 里加了"模块确实跑到分派"的有效性断言)。
#   后缀故意用非 .sh: check-modules 的 `find modules -name '*.sh'` 与自动发现都不会看到它。
#   M=deployments/scripts/modules/02_k8s/10_api_local_lb.mutant
#   git show 5481f2c:deployments/scripts/modules/02_k8s/10_api_local_lb.sh > "$M"
#   MODULE_UNDER_TEST="$PWD/$M" bash deployments/scripts/tools/tests/test-api-local-lb.sh
#   rm -f "$M"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${MODULE_UNDER_TEST:-${REPO_ROOT}/deployments/scripts/modules/02_k8s/10_api_local_lb.sh}"
[ -f "${MOD}" ] || { echo "找不到被测模块: ${MOD}"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

echo "被测模块: ${MOD}"
echo "夹具网段: 192.0.2.0/24 (RFC 5737 TEST-NET-1, 不可路由 → SSH 必然失败)"
fail=0; n=0
chk() {  # chk <描述> <期望> <实际>
    n=$((n + 1))
    if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi
}
cnt() { grep -c "$1" "$2" 2>/dev/null | tr -d ' '; }   # 无匹配时 grep -c 退出码非 0, 但输出仍是 0

# 夹具 conf: NODES 全用 TEST-NET-1; 开关用 ${VAR:-default} 形式以便环境变量覆盖
mk_conf() {  # mk_conf <文件> <NODES 条目…(已带引号)>
    local f="$1"; shift
    {
        printf 'NODES=(%s)\n' "$*"
        printf 'KUBE_VIP_ENABLED="false"\n'
        printf 'API_DOMAIN="k8s-api.invalid"\n'
        printf 'API_LOCAL_LB_ENABLED="${API_LOCAL_LB_ENABLED:-true}"\n'
    } > "${f}"
}

run_mod() {  # run_mod <conf> [额外环境变量…] → stdout = 模块退出码; 日志写 ${TMP}/last.log
    local conf="$1"; shift
    env CLUSTER_CONF="${conf}" "$@" bash "${MOD}" > "${TMP}/last.log" 2>&1
    echo $?
}
as_ok() { [ "$1" != "0" ] && echo "非0" || echo "0"; }   # 把"非 0"断言写得可读

# ============================================================
# ① enabled 模式 + 只有 master(没有 worker → 修复前唯一的失败点就是 hosts 收敛)
# ============================================================
mk_conf "${TMP}/m_only.conf" '"master,fake-m1,192.0.2.10,ubuntu,-"'
rc="$(run_mod "${TMP}/m_only.conf")"
# ⚠ 先证"模块真的跑到了分派": 模块用 `source ../../lib-common.sh`(相对自身路径),
#   若把它拷到别处跑(如 /tmp), lib-common 找不到 → set -e 直接死, 于是"非 0 退出"变成假阳性。
#   本锚点第一版就是这么被骗的 —— 夹具有效性必须先断言。
chk "① 模块确实跑到分派(夹具有效性)" "1" "$(cnt '本地代理模式' "${TMP}/last.log")"
chk "① enabled/节点不可达 → 退出码非 0(修复前 EXIT=0)" "非0" "$(as_ok "${rc}")"
chk "① 报错点名'域名行收敛失败'" "1" "$(cnt '域名行收敛失败' "${TMP}/last.log")"
chk "① 不打假成功('已收敛到' 不该出现)" "0" "$(cnt '已收敛到' "${TMP}/last.log")"
chk "① SSH 确实失败(夹具有效性)" "1" "$(cnt 'Connection timed out' "${TMP}/last.log")"

# ============================================================
# ② enabled 模式 + master & worker(可达性前置: 不许把 SSH 故障误诊成"上游没装")
# ============================================================
mk_conf "${TMP}/mw.conf" '"master,fake-m1,192.0.2.10,ubuntu,-"' '"worker,fake-w1,192.0.2.11,ubuntu,-"'
rc="$(run_mod "${TMP}/mw.conf")"
chk "② 模块确实跑到分派(夹具有效性)" "1" "$(cnt '本地代理模式' "${TMP}/last.log")"
chk "② enabled/worker 不可达 → 退出码非 0" "非0" "$(as_ok "${rc}")"
chk "② 文案说'SSH 不可达'(不再误诊)" "1" "$(cnt 'SSH 不可达' "${TMP}/last.log")"
chk "② 不再出现误导文案'上游未部署本地代理?'" "0" "$(cnt '上游未部署本地代理' "${TMP}/last.log")"

# ============================================================
# ③ disabled 模式 + 节点不可达(修复前: ✅ 清理完成 + EXIT=0)
# ============================================================
rc="$(run_mod "${TMP}/m_only.conf" API_LOCAL_LB_ENABLED=false)"
chk "③ 模块确实跑到分派(夹具有效性)" "1" "$(cnt '本地代理已关闭' "${TMP}/last.log")"
chk "③ disabled/节点不可达 → 退出码非 0(修复前 EXIT=0)" "非0" "$(as_ok "${rc}")"
chk "③ 明确计入'不可达'(不当作已干净)" "1" "$(cnt '(不可达)' "${TMP}/last.log")"
chk "③ 不打假成功('✅ 清理完成' 不该出现)" "0" "$(cnt '清理完成' "${TMP}/last.log")"
chk "③ 报'清理未完成'明细" "1" "$(cnt '清理未完成' "${TMP}/last.log")"

# ============================================================
# ④ _workers/_all_nodes 退出码与"末节点角色"无关(修复前会在 set -e 下静默中止)
# ============================================================
# 从被测模块**原样抽出**这两个函数(到行首 `}` 为止), 配一个桩 node_parse + 末节点是 master 的 NODES。
extract_fn() { sed -n "/^$1() {/,/^}/p" "${MOD}"; }
{
    echo 'node_parse() { IFS=, read -r NODE_ROLE _host NODE_IP _rest <<<"$1"; }'
    echo 'NODES=("worker,w1,192.0.2.11,u,-" "master,m1,192.0.2.10,u,-")'   # ⚠ 末节点是 master
    extract_fn _workers
    extract_fn _all_nodes
    echo 'set -e'                                  # 故意开 errexit: 赋值语义下退 1 会静默中止
    echo '_w="$(_workers)";  echo "assign_workers=$?"'
    echo '_a="$(_all_nodes)"; echo "assign_all=$?"'
    echo 'echo "workers=[$_w] all=[$_a]"'
} > "${TMP}/fns.sh"
fns_out="$(bash "${TMP}/fns.sh" 2>&1 || true)"
grep -q '^assign_workers=0$' <<<"${fns_out}" && _w_rc="0" || _w_rc="$(grep -m1 '^assign_workers=' <<<"${fns_out}" || echo "(静默中止/无输出)")"
grep -q '^assign_all=0$'     <<<"${fns_out}" && _a_rc="0" || _a_rc="$(grep -m1 '^assign_all='     <<<"${fns_out}" || echo "(静默中止/无输出)")"
chk "④ _workers 显式 return 0(末节点是 master)" "0" "${_w_rc}"
chk "④ _all_nodes 显式 return 0(末节点是 master)" "0" "${_a_rc}"
chk "④ 抽取的函数真在跑(能列出节点)" "1" "$(grep -c '^workers=\[' <<<"${fns_out}")"

# ============================================================
# ⑤ 源码契约(防止将来被"简化"回静默写法)
# ============================================================
# ⚠ 必须剥掉注释行再数: 修复说明里**引用**了被禁的写法(`… && vlog …` / `|| true`),
#   不剥注释会把"说明"当成"违规"(本锚点第一版就这么误报过)。
src_of() { sed -n "/^$1() {/,/^}/p" "${MOD}"; }
code_of() { src_of "$1" | grep -v '^[[:space:]]*#'; }
chk "⑤ run_enabled 里没有 '&& vlog' 吞失败" "0" "$(code_of run_enabled | grep -c 'converge_hosts .*&&')"
chk "⑤ run_disabled 里没有 '|| true' 吞失败" "0" "$(code_of run_disabled | grep -c '|| true')"
chk "⑤ 清理前有显式探活(_hssh <ip> true)" "1" "$(code_of run_disabled | grep -c '_hssh "${ip}" "true"')"
chk "⑤ 删除后有 crictl 复核(容器确实消失)" "1" "$(code_of run_disabled | grep -c 'crictl ps')"
chk "⑤ _workers 有显式 return 0" "1" "$(code_of _workers | grep -c 'return 0')"
chk "⑤ _all_nodes 有显式 return 0" "1" "$(code_of _all_nodes | grep -c 'return 0')"
chk "⑤ 模块头写明 fail-closed 约定" "1" "$(grep -c '节点不可达必须响亮失败' "${MOD}")"

# ============================================================
# ⑥ 关闭态的操作顺序提示(R10): 删 manifest 只是本模块的活, 把 kubelet.conf 从 localhost:6443
#    改回域名是**上游 k8s_deploy** 的活 → 必须提示"随后重跑 k8s_deploy", 否则运维只跑
#    `--steps api_local_lb` 关开关会留下"代理已删、kubelet 仍指 localhost"的窗口 = 节点 NotReady。
#    按仓库惯例只提示不拦停(不能用 err/return 1 中断)。
# ============================================================
chk "⑥ 关闭态明确提示'随后重跑 k8s_deploy'" "1" "$(code_of run_disabled | grep -c '请随后重跑 k8s_deploy')"
chk "⑥ 该提示走 warn(不是 err/拦停)" "1" "$(code_of run_disabled | grep -c '^\s*warn "  请随后重跑 k8s_deploy')"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then
    echo "✅ 全部 ${n} 项断言通过(${MOD})"
else
    echo "❌ 存在失败断言(${MOD}) —— 详见上面 FAIL 行"
fi
exit "${fail}"
