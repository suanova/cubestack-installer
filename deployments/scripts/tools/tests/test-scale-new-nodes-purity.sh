#!/bin/bash
# 回归夹具: 07_k8s_scale.sh 的 _auto_detect_new_nodes 输出纯度
# 事故(2026-10-12, 容器 d): master 缺失警告(warn, stdout)漏加 >&2 → 被 NEW_NODE_HOSTS=$(...)
#   捕获 → SCALE_NODES 导给 gen-inventory → 按空白切词逐 token 写进 hosts.yml 的 new_node.hosts
#   → kubespray "Inventory 解析失败"。根因同 2026-09-22 vlog 写 stdout 事故。
# 手法: 从真实模块文件**提取函数体**执行(不跑模块主流程); 依赖桩化:
#   _query_cluster_nodes(桩) / NODES(桩); node_parse + say/ok/warn/vlog 用真 lib-common。
# 断言: 捕获输出必须是**纯 hostname 列表**(诊断文本只许走 stderr —— 含 ⚠/空白即红)。
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCALE="${REPO_ROOT}/deployments/scripts/modules/02_k8s/07_k8s_scale.sh"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

# 提取函数体: 从 "_auto_detect_new_nodes() {" 起, 至首个顶格 "}" 止(模块版式: 函数内嵌套均缩进)
FN="$(awk '/^_auto_detect_new_nodes\(\)/{f=1} f{print} f && /^}$/{exit}' "${SCALE}")"
[ -n "${FN}" ] || { echo "FAIL: 未从模块提取到 _auto_detect_new_nodes(版式变了?)"; exit 1; }

run_detect() {   # <集群节点列表(多行 name|ip|eip)> → stdout=函数返回值(捕获视图)
    (
        set +u
        source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
        NODES=("master,master01,10.0.0.1,u,p" "master,master02,10.0.0.2,u,p" "worker,worker01,10.0.0.11,u,p" "worker,worker02,10.0.0.12,u,p")
        # 桩: 模块对 _query_cluster_nodes 是**无参调用**, 桩数据经闭包变量传入
        _STUB_CLUSTER="$1"
        _query_cluster_nodes() { printf '%s\n' "${_STUB_CLUSTER}"; }
        eval "${FN}"
        out="$(_auto_detect_new_nodes)"
        printf '%s' "${out}"
    ) 2>/dev/null
}

echo "== ① master 缺失(警告不许进 stdout) =="
OUT1="$(run_detect "master01|10.0.0.1|10.0.0.1
worker01|10.0.0.11|10.0.0.11")"
chk "① 输出=仅新 worker(纯 hostname)" "worker02" "${OUT1}"
chk "① 输出不含 ⚠" "0" "$(printf '%s' "${OUT1}" | grep -c '⚠' || true)"
chk "① 输出不含空白/换行" "0" "$(printf '%s' "${OUT1}" | grep -c '[[:space:]]' || true)"

echo "== ② 无 master 缺失(对照: 本就纯净) =="
OUT2="$(run_detect "master01|10.0.0.1|10.0.0.1
master02|10.0.0.2|10.0.0.2
worker01|10.0.0.11|10.0.0.11")"
chk "② 输出=worker02" "worker02" "${OUT2}"

echo "== ③ 全部已在集群 → 空输出(消费者将走\"无需扩容\") =="
OUT3="$(run_detect "master01|10.0.0.1|10.0.0.1
master02|10.0.0.2|10.0.0.2
worker01|10.0.0.11|10.0.0.11
worker02|10.0.0.12|10.0.0.12")"
chk "③ 空" "" "${OUT3}"

[ "${fail}" = "0" ] && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
