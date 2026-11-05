#!/bin/bash
# ============================================================
# test-reset-cleanup.sh — 旧集群清理(kubeadm reset + CRI 兜底)离线回归
# 背景(2026-11-05 实机): node_pkgs 的 Ceph 修复脚本先 `systemctl stop kubelet containerd`,
#   成功路径不重启 containerd; 紧随其后的 k8s_deploy 清理执行 `kubeadm reset -f` 时
#   CRI 不可达 → reset 只删了文件, 旧静态 Pod 容器(shim 存活)继续占用 10257/10259。
#   master01 的 kube-controller-manager 占 10257 → kubeadm init preflight 失败;
#   master02 的 kube-scheduler 占 10259 → 即使 10257 修好, join 也会失败。
#   原清理只复核 10250(kubelet 已停, 必然空) → 误报“3 台成功”。
# 覆盖:
#   ① 清理载荷仍是**单个 ssh 参数**且 `bash -n` 通过(内嵌转义没被破坏)
#   ② 载荷先启动 containerd(让 kubeadm reset 的 CRI 可用)
#   ③ 载荷在 reset 后用 crictl 兜底删除 pod sandbox / 容器
#   ④ kubeadm reset 输出不再被静默丢弃
#   ⑤ 复核端口覆盖 6443/10250/10257/10259, 且仍被占时按 pid 强杀兜底
#   ⑥ 残留探测本身也能发现“只有旧控制面容器、没有痕迹文件”的节点
#   ⑦ node_pkgs 的 Ceph 修复(成功路径)恢复 containerd
# 用法: bash deployments/scripts/tools/tests/test-reset-cleanup.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
OFFLINE="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
RECONCILE="${REPO_ROOT}/deployments/scripts/tools/node/reconcile-node-packages.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  FAIL $1: [$3] 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }

echo "== ① 清理载荷: 单参数 + 远端语法 =="
# 截取 reset_kubernetes_if_needed 里的 cleanup_out=$(ssh ...) 赋值块, 用桩 ssh 捕获
# 真正送给远端的最后一个参数(载荷)。载荷若被引号拆散, 这里会拿到错误的参数。
awk '/cleanup_out=\$\(ssh/{f=1} f{print} f&&/cleanup_rc=\$\?/{exit}' "${OFFLINE}" > "${TMP}/snippet.sh"
[ -s "${TMP}/snippet.sh" ] && echo "  ok  清理载荷赋值块已提取" || { echo "  FAIL 清理载荷赋值块提取为空"; fail=1; }
cat > "${TMP}/harness.sh" <<'HARNESS'
key=/tmp/k; user=ubuntu; host=10.0.0.1
cleanup_out=""; cleanup_rc=0
ssh() {
    local last="${!#}"
    if [ "${last#sudo timeout}" = "${last}" ]; then
        echo "PAYLOAD_NOT_LAST_ARG" > "${STUB_PAYLOAD}"
    else
        printf '%s\n' "${last}" > "${STUB_PAYLOAD}"
    fi
    return 0
}
source "${SNIPPET}"
HARNESS
SNIPPET="${TMP}/snippet.sh" STUB_PAYLOAD="${TMP}/payload.sh" bash "${TMP}/harness.sh"
chk_contains "载荷以 sudo timeout 开头(未被拆散)" "sudo timeout" "${TMP}/payload.sh"
chk_not_contains "载荷没有被拆成多个参数" "PAYLOAD_NOT_LAST_ARG" "${TMP}/payload.sh"
# ⚠ 远端脚本本身用单引号包裹(`bash -c '...'`): 脚本内出现任何未转义的单引号都会提前
#   截断解析 —— bash -n 往往仍能通过(被改写的命令恰好合法), 实机才报
#   `-c: line N: syntax error: unexpected end of file` (2026-11-05 实测)。
#   判据: 载荷里只能有外层那一对单引号。
chk "清理载荷只含外层一对单引号" "2" "$(grep -o "'" "${TMP}/payload.sh" | wc -l | tr -d ' ')"
# 抽出 `bash -c '...'` 的内层脚本单独解析 —— 与远端真实解析一致
sed -e "s/^sudo timeout -k 15 240 bash -c '//" -e "s/'[[:space:]]*$//" "${TMP}/payload.sh" > "${TMP}/payload-inner.sh"
if bash -n "${TMP}/payload-inner.sh" 2>"${TMP}/inner.syntax"; then
    echo "  ok  内层远端脚本 bash -n 通过"
else
    echo "  FAIL 内层远端脚本语法错误:"; sed 's/^/      /' "${TMP}/inner.syntax"; fail=1
fi
if bash -n "${TMP}/payload.sh" 2>"${TMP}/payload.syntax"; then
    echo "  ok  远端载荷 bash -n 通过"
else
    echo "  FAIL 远端载荷语法错误:"; sed 's/^/      /' "${TMP}/payload.syntax"; fail=1
fi

echo "== ② kubeadm reset 前确保 containerd(CRI)可用 =="
chk_contains "启动 containerd" "systemctl start containerd" "${TMP}/payload.sh"
_containerd_line="$(grep -n 'systemctl start containerd' "${TMP}/payload.sh" | head -1 | cut -d: -f1)"
_reset_line="$(grep -n 'kubeadm reset -f 2>&1' "${TMP}/payload.sh" | head -1 | cut -d: -f1)"
if [ -n "${_containerd_line}" ] && [ -n "${_reset_line}" ] && [ "${_containerd_line}" -lt "${_reset_line}" ]; then
    echo "  ok  containerd 启动在 kubeadm reset 之前(${_containerd_line} < ${_reset_line})"
else
    echo "  FAIL 顺序: containerd=${_containerd_line:-空} reset=${_reset_line:-空}"; fail=1
fi
chk_contains "等待 CRI socket" "containerd.sock" "${TMP}/payload.sh"

echo "== ③ reset 后用 crictl 兜底清除孤儿容器 =="
chk_contains "枚举 pod sandbox" "crictl pods -q" "${TMP}/payload.sh"
chk_contains "强制删 pod sandbox" "crictl rmp -f" "${TMP}/payload.sh"
chk_contains "枚举容器" "crictl ps -aq" "${TMP}/payload.sh"
chk_contains "强制删容器" "crictl rm -f" "${TMP}/payload.sh"

echo "== ④ kubeadm reset 输出/返回码不再静默丢弃 =="
chk_not_contains "不再 2>/dev/null 丢弃 reset 输出" "kubeadm reset -f 2>/dev/null" "${TMP}/payload.sh"
chk_contains "记录 reset 输出" "_reset_out" "${TMP}/payload.sh"

echo "== ⑤ 复核端口覆盖 6443/10250/10257/10259 + 仅确认旧 K8s 组件才 kill =="
chk_contains "四端口正则" "6443|10250|10257|10259" "${TMP}/payload.sh"
chk_contains "kill 前经 /proc/<pid>/exe 确认程序本体" "readlink /proc/" "${TMP}/payload.sh"
chk_contains "只对已知 kube 组件发信号" "kube-apiserver|kube-controller-manager|kube-scheduler|kubelet" "${TMP}/payload.sh"
chk_contains "未确认监听者不发信号" "未确认进程持有" "${TMP}/payload.sh"
chk_contains "失败信息打印进程名/命令" "ps -o comm= -p" "${TMP}/payload.sh"
chk_contains "最终失败信息点名控制面端口" "PORT_BUSY" "${TMP}/payload.sh"
chk_contains "失败信息不再只提 10250" "控制面端口" "${TMP}/payload.sh"
chk_contains "成功信息覆盖四端口" "6443/10250/10257/10259" "${OFFLINE}"

echo "== ⑥ 残留探测: 仅旧控制面容器(无痕迹文件)也能发现 =="
chk_contains "探测控制面端口" "port-control-plane" "${OFFLINE}"
chk_contains "探测正则含 6443/10257/10259" "6443|10257|10259" "${OFFLINE}"
# 探测载荷同样是内嵌远端脚本: 必须仍是单个 ssh 参数且语法通过(引号被拆散会静默漏检)
awk '/probe=\$\(ssh/{f=1} f{print} f&&/probe_rc=\$\?/{exit}' "${OFFLINE}" > "${TMP}/probe-snippet.sh"
[ -s "${TMP}/probe-snippet.sh" ] && echo "  ok  探测载荷赋值块已提取" || { echo "  FAIL 探测载荷提取为空"; fail=1; }
cat > "${TMP}/probe-harness.sh" <<'HARNESS'
key=/tmp/k; user=ubuntu; host=10.0.0.1
probe=""; probe_rc=0
ssh() {
    local last="${!#}"
    if [ "${last#sudo bash -c}" = "${last}" ]; then
        echo "PAYLOAD_NOT_LAST_ARG" > "${STUB_PAYLOAD}"
    else
        printf '%s\n' "${last}" > "${STUB_PAYLOAD}"
    fi
    return 0
}
source "${SNIPPET}"
HARNESS
SNIPPET="${TMP}/probe-snippet.sh" STUB_PAYLOAD="${TMP}/probe-payload.sh" bash "${TMP}/probe-harness.sh"
chk_not_contains "探测载荷没有被拆成多个参数" "PAYLOAD_NOT_LAST_ARG" "${TMP}/probe-payload.sh"
chk "探测载荷只含外层一对单引号" "2" "$(grep -o "'" "${TMP}/probe-payload.sh" | wc -l | tr -d ' ')"
sed -e "s/^sudo bash -c '//" -e "s/'[[:space:]]*$//" "${TMP}/probe-payload.sh" > "${TMP}/probe-inner.sh"
if bash -n "${TMP}/probe-inner.sh" 2>"${TMP}/probe-inner.syntax"; then
    echo "  ok  内层探测脚本 bash -n 通过"
else
    echo "  FAIL 内层探测脚本语法错误:"; sed 's/^/      /' "${TMP}/probe-inner.syntax"; fail=1
fi
if bash -n "${TMP}/probe-payload.sh" 2>"${TMP}/probe.syntax"; then
    echo "  ok  探测载荷 bash -n 通过"
else
    echo "  FAIL 探测载荷语法错误:"; sed 's/^/      /' "${TMP}/probe.syntax"; fail=1
fi

echo "== ⑦ node_pkgs Ceph 修复成功路径恢复 containerd =="
sed -n "/<<'REPAIR'/,/^REPAIR$/p" "${RECONCILE}" > "${TMP}/repair.sh"
[ -s "${TMP}/repair.sh" ] && echo "  ok  _repair 载荷已提取" || { echo "  FAIL _repair 提取为空"; fail=1; }
chk_contains "修复仍先停 kubelet/containerd" "systemctl stop kubelet containerd" "${TMP}/repair.sh"
chk_contains "成功路径恢复 containerd" "systemctl start containerd" "${TMP}/repair.sh"
chk_not_contains "成功路径不拉起旧 kubelet" "systemctl start containerd kubelet" "${TMP}/repair.sh"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-reset-cleanup: 全部通过"
else
    echo "❌ test-reset-cleanup: 存在失败项"
fi
exit "${fail}"
