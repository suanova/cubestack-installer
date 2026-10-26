#!/bin/bash
# ============================================================
# test-inventory-ssh-user-precedence.sh — NODES 逐行 ssh_user 必须真正生效(静态回归)
# 背景(2026-10-26 实机): cluster.conf NODES 里 worker02 写的是 root,
#   master/worker01 写 ubuntu。cubestack-offline.sh 把 offline.yml(含
#   ansible_user: "${REMOTE_USER}", REMOTE_USER=首个节点的 ubuntu)用
#   `-e @offline.yml` 传给 ansible-playbook —— extra vars 优先级最高, 把
#   hosts.yml 里的逐节点 ansible_user 全压成 ubuntu ⇒ 报错:
#     ubuntu@10.6.7.135: Permission denied (publickey,password)
#   同理 `ansible ... -u "${REMOTE_USER}"` 也会覆盖 host vars。
# 覆盖:
#   ① gen-inventory.sh 按节点写 ansible_user: ${NODE_USER}(master/worker 两块)
#   ② cubestack-offline.sh 不得把 offline.yml 当 extra vars(-e @)传给 ansible
#   ③ cubestack-offline.sh 不得用 ansible -u 覆盖节点用户
#   ④ 组级兜底仍在: offline.yml 仍写在 <inventory>/group_vars/all/(按 group_vars 加载)
#   ⑤ reset / reset 后复核路径同样按节点用户(不得 -e @offline.yml, 不得写死 ubuntu)
# 隔离: 纯静态(只读脚本文本), 不连集群、不需要 ansible。
# 用法: bash deployments/scripts/tools/tests/test-inventory-ssh-user-precedence.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
GEN_INV="${REPO_ROOT}/deployments/scripts/tools/k8s/gen-inventory.sh"
OFFLINE="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
# 只在**代码行**里找(跳过 # 注释; 注释里会解释这条规则本身)
code_hits() { grep -nE -- "$1" "$2" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true; }
code_count() { code_hits "$1" "$2" | wc -l | tr -d ' '; }

echo "== ① gen-inventory.sh: 逐节点 ansible_user =="
# master 与 worker 两个 hosts 块都要用 node_parse 得出的 NODE_USER
chk "ansible_user 取自 NODE_USER(>=2 处)" "2" \
    "$(grep -cE '^[[:space:]]*echo "      ansible_user: \$\{NODE_USER\}"' "${GEN_INV}" 2>/dev/null || true)"
chk "无写死 ansible_user: ubuntu" "0" \
    "$(grep -cE 'ansible_user:[[:space:]]*"?ubuntu"?[[:space:]]*$' "${GEN_INV}" 2>/dev/null || true)"

echo "== ② offline.yml 不得作为 extra vars(-e @)传入 =="
# -e @<file> 是 Ansible extra vars(最高优先级), 会压掉 hosts.yml 的 host vars
chk "无 -e @\${OFFLINE_VARS}" "0" \
    "$(code_count '-e[[:space:]]+@\$\{OFFLINE_VARS\}' "${OFFLINE}")"
chk "无其它 -e @...offline.yml" "0" \
    "$(code_count '-e[[:space:]]+@[^[:space:]]*offline\.yml' "${OFFLINE}")"

echo "== ③ 不得用 ansible -u 覆盖节点用户 =="
# 命令行 -u 同样高于 inventory host vars(曾用于 ping 预检)
chk "无 -u \${REMOTE_USER}" "0" \
    "$(code_count '-u[[:space:]]+"\$\{REMOTE_USER\}"' "${OFFLINE}")"
chk "无 ansible ping -u" "0" \
    "$(code_count 'ansible[[:space:]]+all[[:space:]].*-m[[:space:]]+ping.*-u[[:space:]]' "${OFFLINE}")"

echo "== ④ 组级兜底仍写进 group_vars/all/ =="
chk "offline.yml 赋值(install + scale)" "2" \
    "$(code_count 'OFFLINE_VARS="\$\{INVENTORY_DIR\}/group_vars/all/offline\.yml"' "${OFFLINE}")"
chk "offline.yml 仍含 ansible_user 兜底" "2" \
    "$(code_count '^[[:space:]]*echo "ansible_user: \\"\$\{REMOTE_USER\}\\""' "${OFFLINE}")"

echo "== ⑤ reset / 复核路径同样按节点用户 =="
# reset.yml 曾把 offline.yml 用 `-e "@${ov}"` 传进去(同类 extra vars 覆盖)
chk "无 reset 的 -e \"@\${ov}\"" "0" \
    "$(code_count '-e[[:space:]]+"@\$\{ov\}"' "${OFFLINE}")"
chk "无 \${_ov[@]} 传给 ansible" "0" \
    "$(code_count '\$\{_ov\[@\]\}' "${OFFLINE}")"
# reset 后的二进制复核必须按 hosts.yml 的 ansible_user 连接(曾写死 ${SSH_USER:-ubuntu},
# 而本脚本从不设置 SSH_USER ⇒ root 节点恒按 ubuntu 连、复核静默失效)
chk "无 SSH_USER:-ubuntu 硬兜底" "0" \
    "$(code_count 'SSH_USER:-ubuntu' "${OFFLINE}")"

echo ""
if [ "${fail}" = "0" ]; then echo "✅ test-inventory-ssh-user-precedence: 全部通过"; else echo "❌ test-inventory-ssh-user-precedence: 有失败"; fi
exit "${fail}"
