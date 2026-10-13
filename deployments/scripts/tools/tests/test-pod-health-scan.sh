#!/bin/bash
# 夹具: lib-module.sh 的 warn_unhealthy_pods 过滤器(从真实文件**提取 awk** 执行)
# 动机(2026-10-12 用户要求): 部署收尾巡检"未成功运行的 Pod"仅告警; 判定逻辑(状态白名单 +
#   READY 未满)必须被夹具钉住 —— 实例: 容器 d 集群 coredns CrashLoopBackOff 19 分钟无人察觉。
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-module.sh"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

# 提取 awk 程序(真实提取, 防漂移): 从 "bad=\"$(printf" 行的 awk ' 起, 到 "}' || true)\"" 止
AWK="$(python3 - "${LIB}" <<'PYEOF'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"bad=\"\$\(printf '%s\\n' \"\$\{out\}\" \| awk '([\s\S]*?)' \|\| true\)\"", s)
assert m, "未从 lib-module.sh 提取到巡检 awk(版式变了?)"
print(m.group(1))
PYEOF
)"
[ -n "${AWK}" ] || { echo "FAIL: awk 提取为空"; exit 1; }

filter() {  # <kubectl get pods -A --no-headers 形态的多行) → 过滤后的告警行
    printf '%s\n' "$1" | awk "${AWK}"
}

echo "== ① 全健康(含 Completed Job)→ 空 =="
O1="$(filter "kube-system coredns-abc 1/1 Running 0 10m
kube-system etcd-m1 1/1 Running 2 10m
default job-x 0/1 Completed 0 10m")"
chk "① 空" "" "${O1}"

echo "== ② 三类异常 → 恰好列出(健康行不出现) =="
O2="$(filter "kube-system coredns-6xzpz 0/1 CrashLoopBackOff 11 19m
rook-ceph nodeplugin-a 1/2 Running 0 62m
default pending-pod 0/1 Pending 0 5m
kube-system kube-proxy-1 1/1 Running 0 10m")"
chk "② 计数=3" "3" "$(printf '%s\n' "${O2}" | grep -c . || true)"
chk "② 含 CrashLoopBackOff" "1" "$(printf '%s' "${O2}" | grep -c 'kube-system/coredns-6xzpz  CrashLoopBackOff (READY 0/1)' || true)"
chk "② 含 1/2 Running(READY 未满)" "1" "$(printf '%s' "${O2}" | grep -c 'rook-ceph/nodeplugin-a  Running (READY 1/2)' || true)"
chk "② 含 Pending" "1" "$(printf '%s' "${O2}" | grep -c 'default/pending-pod  Pending' || true)"
chk "② 健康行不出现" "0" "$(printf '%s' "${O2}" | grep -c 'kube-proxy-1' || true)"

echo "== ③ ImagePullBackOff 与 Error 同列 =="
O3="$(filter "kube-system x 1/2 ImagePullBackOff 0 3m
default y 0/1 Error 1 3m")"
chk "③ 计数=2" "2" "$(printf '%s\n' "${O3}" | grep -c . || true)"

[ "${fail}" = "0" ] && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
