#!/bin/bash
# 桩式单元测试: SSH 用户单一旋钮(root|ubuntu) —— 不连集群, 只验解析/派生纯逻辑。
# 语义(2026-10-15, 用户口径): SSH_USER = 全局默认(默认 ubuntu); NODES 第4字段 "-"/空 → 跟随
# 全局; 显式写用户名 = 该节点覆盖。覆盖点:
#   ① load_config 归一化(环境变量 / cluster.conf 两条来源; 默认 ubuntu)
#   ② node_parse 的 "-" 继承(新5字段 + 旧10字段两格式)与显式覆盖
#   ③ ssh_user_for_ip: 命中逐行用户 / 未命中回退全局 / 不污染调用方 NODE_* 全局量
#   ④ warn_ssh_user_mismatch: 一致安静, 不一致点名(含节点名与用户)
#   ⑤ init_remote_kubectl: FIRST_MASTER_USER/SSH_CMD 按**首个 master 的逐行用户**
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export CLUSTER_CONF="$(mktemp)"
fail=0
chk() { # chk <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi
}

_run() { # _run <conf 内容> <表达式>   (环境变量可前置: SSH_USER=root _run ...)
    printf '%s\n' "$1" > "${CLUSTER_CONF}"
    ( set +u; source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      load_config >/dev/null 2>&1
      eval "$2" )
}

M5_DASH='NODES=("master,m1,10.0.0.1,-,p")'          # 新5字段: 用户 "-" = 跟随全局
M5_UBU='NODES=("master,m1,10.0.0.1,ubuntu,p")'      # 新5字段: 显式 ubuntu
M10_DASH='NODES=("master,m1,10.0.0.1,52:54:00:aa:bb:cc,16,4,100,,p,bm")'   # 旧10字段: 第8位空
M10_UBU='NODES=("master,m1,10.0.0.1,52:54:00:aa:bb:cc,16,4,100,ubuntu,p,bm")'

echo "== SSH_USER 归一化(默认/环境变量/cluster.conf) =="
chk "未设置 → 默认 ubuntu" "ubuntu" "$(_run 'X=1' 'echo "${SSH_USER}"')"
chk "环境变量 root 生效" "root" "$(SSH_USER=root _run 'X=1' 'echo "${SSH_USER}"')"
chk "cluster.conf 显式 root 生效" "root" "$(_run 'SSH_USER=root
X=1' 'echo "${SSH_USER}"')"

echo "== node_parse: \"-\" 继承 与 显式覆盖 =="
chk '5字段 "-" 跟随默认 ubuntu' "ubuntu" "$(_run "${M5_DASH}" 'node_parse "master,m1,10.0.0.1,-,p"; echo "${NODE_USER}"')"
chk '5字段 "-" 跟随全局 root' "root" "$(SSH_USER=root _run "${M5_DASH}" 'node_parse "master,m1,10.0.0.1,-,p"; echo "${NODE_USER}"')"
chk "5字段显式 ubuntu 不随全局 root" "ubuntu" "$(SSH_USER=root _run "${M5_UBU}" 'node_parse "master,m1,10.0.0.1,ubuntu,p"; echo "${NODE_USER}"')"
chk "旧10字段: 第8位空 → 继承全局 root" "root" "$(SSH_USER=root _run "${M10_DASH}" 'node_parse "master,m1,10.0.0.1,52:54:00:aa:bb:cc,16,4,100,,p,bm"; echo "${NODE_USER}"')"
chk "旧10字段: 第8位显式 ubuntu 不随全局" "ubuntu" "$(SSH_USER=root _run "${M10_UBU}" 'node_parse "master,m1,10.0.0.1,52:54:00:aa:bb:cc,16,4,100,ubuntu,p,bm"; echo "${NODE_USER}"')"

echo "== ssh_user_for_ip: 命中/回退/隔离 =="
chk '命中(逐行 "-") → 全局 root' "root" "$(SSH_USER=root _run "${M5_DASH}" 'ssh_user_for_ip 10.0.0.1')"
chk "命中(逐行显式)覆盖全局" "ubuntu" "$(SSH_USER=root _run "${M5_UBU}" 'ssh_user_for_ip 10.0.0.1')"
chk "未命中 IP → 回退全局 root" "root" "$(SSH_USER=root _run "${M5_DASH}" 'ssh_user_for_ip 192.0.2.99')"
chk "NODES 为空 → 回退全局" "ubuntu" "$(_run 'X=1' 'ssh_user_for_ip 192.0.2.99')"
chk "不污染调用方 NODE_* 全局量" "sentinel" \
    "$(SSH_USER=root _run "${M5_DASH}" 'NODE_USER=sentinel; ssh_user_for_ip 10.0.0.1 >/dev/null; echo "${NODE_USER}"')"

echo "== warn_ssh_user_mismatch: 一致安静 / 不一致点名 =="
chk "全一致 → 不打印" "0" "$(_run "${M5_UBU}" 'warn_ssh_user_mismatch' | grep -c 'SSH 用户不一致')"
chk '逐行 "-" 与全局一致 → 不打印' "0" "$(SSH_USER=root _run "${M5_DASH}" 'warn_ssh_user_mismatch' | grep -c 'SSH 用户不一致')"
chk "不一致 → 打印告警" "1" "$(SSH_USER=root _run "${M5_UBU}" 'warn_ssh_user_mismatch' | grep -c 'SSH 用户不一致')"
chk "告警点名 节点名(用户)" "1" "$(SSH_USER=root _run "${M5_UBU}" 'warn_ssh_user_mismatch' | grep -c 'm1(ubuntu)')"
chk "恒返回 0(不拦停)" "0" "$(SSH_USER=root _run "${M5_UBU}" 'warn_ssh_user_mismatch >/dev/null 2>&1; echo $?')"

echo "== init_remote_kubectl: 首个 master 的逐行用户 =="
chk "FIRST_MASTER_USER = 首 master 逐行用户(覆盖全局)" "root" \
    "$(_run "${M5_UBU/ubuntu/root}" 'init_remote_kubectl >/dev/null 2>&1; echo "${FIRST_MASTER_USER}"')"
chk "SSH_CMD 用户名与之一致" "1" \
    "$(_run "${M5_UBU/ubuntu/root}" 'init_remote_kubectl >/dev/null 2>&1; case "${SSH_CMD}" in *"root@10.0.0.1"*) echo yes;; esac' | grep -c '^yes$')"
chk '逐行 "-" + 全局 root → SSH_CMD 用 root' "1" \
    "$(SSH_USER=root _run "${M5_DASH}" 'init_remote_kubectl >/dev/null 2>&1; case "${SSH_CMD}" in *"root@10.0.0.1"*) echo yes;; esac' | grep -c '^yes$')"

rm -f "${CLUSTER_CONF}"
echo ""
if [ "${fail}" = "0" ]; then echo "✅ test-ssh-user: 全部通过"; else echo "❌ test-ssh-user: 有失败"; fi
exit "${fail}"
