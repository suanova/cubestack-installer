#!/bin/bash
# ============================================================
# test-node-hosts-sync.sh — 节点侧 /etc/hosts(hostname → IP)同步回归
# 背景(2026-10-23 实机 MCCL/RoCE): NODES hostname 是 K8s 节点名, 但 installer 只写部署机
#   /etc/hosts; hostNetwork Pod 按 hostname 找对端失败 → 回退 127.0.0.1 → 多机通信失败。
# 覆盖:
#   ① NODES 全量 hostname→IP 写入每台节点; 不改节点实际 hostname(127.0.1.1 行保留)
#   ② 重复执行幂等(每个 hostname 恰好一行)
#   ③ NODES IP 变更后旧行被替换(不残留旧 IP)
#   ④ 某节点不可达 → 非 0 + 明确列出失败节点
# 隔离: 假 ssh 把远端脚本里的 /etc/hosts 替换为临时文件执行(不碰本机 /etc/hosts)
# 用法: bash deployments/scripts/tools/tests/test-node-hosts-sync.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

mkdir -p "${TMP}/bin" "${TMP}/keys" "${TMP}/hosts"
: > "${TMP}/keys/fake_key"
printf '127.0.0.1 localhost\n127.0.1.1 node-01\n10.9.9.9 m1\n'  > "${TMP}/hosts/10.0.0.1.hosts"
printf '127.0.0.1 localhost\n127.0.1.1 node-02\n10.9.9.9 w1\n'  > "${TMP}/hosts/10.0.0.2.hosts"
printf '127.0.0.1 localhost\n127.0.1.1 node-03\n'               > "${TMP}/hosts/10.0.0.3.hosts"
printf '127.0.0.1 localhost\n127.0.1.1 node-11\n10.9.9.9 m1\n'  > "${TMP}/hosts/10.0.0.11.hosts"

# 假 ssh: 读取 stdin 的远端脚本 → 把 /etc/hosts 换成该 IP 的临时文件 → 本地执行
cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
ip=""
for a in "$@"; do case "$a" in *@*) ip="${a#*@}" ;; esac; done
[ "${FAKE_FAIL_IP:-}" = "${ip}" ] && exit 255
tmp="$(mktemp)"
cat > "${tmp}"
sed "s#/etc/hosts#${FAKE_HOSTS_DIR}/${ip}.hosts#g" "${tmp}" > "${tmp}.run"
/bin/bash "${tmp}.run" || { rm -f "${tmp}" "${tmp}.run"; exit 1; }
rm -f "${tmp}" "${tmp}.run"
FAKE
chmod +x "${TMP}/bin/ssh"

_run() {   # _run <node-line...> → 在子 shell 中跑 sync_nodes_hosts_remote, 输出 stdout+stderr
    (
        export PATH="${TMP}/bin:${PATH}"
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        export FAKE_HOSTS_DIR="${TMP}/hosts"
        export FAKE_FAIL_IP="${FAKE_FAIL_IP:-}"
        NODES=("$@")
        set +u
        # shellcheck disable=SC1090
        source "${LIB}" >/dev/null 2>&1
        sync_nodes_hosts_remote
    ) 2>&1
}

_n1() { command grep -cE "(^|[[:space:]])m1([[:space:]]|$)" "${TMP}/hosts/10.0.0.1.hosts" || true; }
_w1() { command grep -cE "(^|[[:space:]])w1([[:space:]]|$)" "${TMP}/hosts/10.0.0.1.hosts" || true; }

echo "== ① 写入所有节点(保留实际 hostname) =="
out="$(_run "master,m1,10.0.0.1,root,-" "worker,w1,10.0.0.2,root,-")"
chk "退出码 0" "0" "$?"
chk_contains "汇总信息" "节点侧 /etc/hosts 同步完成" "${out}"
chk "node1 m1 解析到 10.0.0.1" "10.0.0.1 m1" "$(command grep -E '(^|[[:space:]])m1([[:space:]]|$)' "${TMP}/hosts/10.0.0.1.hosts" | head -1)"
chk "node1 w1 解析到 10.0.0.2" "10.0.0.2 w1" "$(command grep -E '(^|[[:space:]])w1([[:space:]]|$)' "${TMP}/hosts/10.0.0.1.hosts" | head -1)"
chk_contains "保留节点实际 hostname" "127.0.1.1 node-01" "$(cat "${TMP}/hosts/10.0.0.1.hosts")"
chk "旧 IP 行已删除(10.9.9.9 m1)" "0" "$(command grep -cF '10.9.9.9 m1' "${TMP}/hosts/10.0.0.1.hosts" || true)"

echo "== ② 重复执行幂等(每 hostname 一行) =="
_run "master,m1,10.0.0.1,root,-" "worker,w1,10.0.0.2,root,-" >/dev/null
chk "node1 m1 行数=1" "1" "$(_n1)"
chk "node1 w1 行数=1" "1" "$(_w1)"
chk "node2 m1 行数=1" "1" "$(command grep -cE '(^|[[:space:]])m1([[:space:]]|$)' "${TMP}/hosts/10.0.0.2.hosts" || true)"

echo "== ③ NODES IP 变更: 现役节点上的旧行替换 =="
# m1 从 10.0.0.1 改为 10.0.0.11: 现役节点(10.0.0.2)与"新地址节点"(10.0.0.11)都应更新;
# 旧地址 10.0.0.1 已不在 NODES 中, 不再对其写入(节点已下线/换 IP 的合理语义)。
out="$(_run "master,m1,10.0.0.11,root,-" "worker,w1,10.0.0.2,root,-")"
chk "退出码 0" "0" "$?"
chk "node2 m1 新 IP" "10.0.0.11 m1" "$(command grep -E '(^|[[:space:]])m1([[:space:]]|$)' "${TMP}/hosts/10.0.0.2.hosts" | head -1)"
chk "node2 m1 行数=1" "1" "$(command grep -cE '(^|[[:space:]])m1([[:space:]]|$)' "${TMP}/hosts/10.0.0.2.hosts" || true)"
chk "node2 无旧 IP 10.0.0.1 m1" "0" "$(command grep -cF '10.0.0.1 m1' "${TMP}/hosts/10.0.0.2.hosts" || true)"
chk "新节点 10.0.0.11 m1 行数=1" "1" "$(command grep -cE '(^|[[:space:]])m1([[:space:]]|$)' "${TMP}/hosts/10.0.0.11.hosts" || true)"
chk "新节点无旧 IP 10.9.9.9 m1" "0" "$(command grep -cF '10.9.9.9 m1' "${TMP}/hosts/10.0.0.11.hosts" || true)"

echo "== ④ 节点不可达: 非 0 + 列出失败节点 =="
out="$(FAKE_FAIL_IP=10.0.0.3 _run "master,m1,10.0.0.11,root,-" "worker,w2,10.0.0.3,root,-")"
rc=$?
chk "退出码非 0" "1" "${rc}"
chk_contains "点名失败节点" "w2(10.0.0.3)" "${out}"
chk_contains "提示 hostNetwork 风险" "127.0.0.1" "${out}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-node-hosts-sync: 全部通过"
else
    echo "❌ test-node-hosts-sync: 存在失败项"
fi
exit "${fail}"
