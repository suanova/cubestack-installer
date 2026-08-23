#!/bin/bash
# ============================================================
# verify-metax-gpu.sh — 验证集群节点是否识别沐曦 GPU(metax-tech.com/gpu)
# 检查每个节点: metax-tech.com/gpu capacity/allocatable、GPU 相关 label、是否可调度(污点/uncordon)
# 输出: 节点清单表格 + 汇总(识别 GPU 的节点数/总 GPU 数) + 异常提示
# 用法: sudo ./verify-metax-gpu.sh
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

say "验证集群节点 GPU 识别情况(metax-tech.com/gpu, 入口=${FIRST_MASTER})..."

# 注: `cmd | python3 << heredoc` 会把 heredoc 当 stdin 覆盖管道 → 用临时文件传 JSON
NODES_JSON="$(SSH "${K} get nodes -o json 2>/dev/null" || true)"
[ -n "${NODES_JSON}" ] || { err "无法获取节点列表(集群不可达?)"; exit 1; }
_TMP="$(mktemp)"; echo "${NODES_JSON}" > "${_TMP}"

OUT="$(python3 - "${_TMP}" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))

def gpu_of(n, field):
    return (n.get("status", {}).get(field, {}) or {}).get("metax-tech.com/gpu")

rows = []
gpu_nodes = []     # 有 gpu allocatable 的节点
total = 0
anomaly = []       # gpu.installed=true 但 allocatable 为空
for n in d["items"]:
    meta = n["metadata"]
    name = meta["name"]
    labels = meta.get("labels", {})
    spec = n.get("spec", {})
    roles = [k.rsplit("/", 1)[-1] for k in labels if k.startswith("node-role.kubernetes.io/")]
    role = ",".join(roles) if roles else "worker"
    taints = [f"{t.get('key','')}:{t.get('effect','')}" for t in spec.get("taints", [])]
    unsched = spec.get("unschedulable", False)
    no_schedule = any(":NoSchedule" in t for t in taints)   # 有 NoSchedule 污点 → 普通 pod 不可调度
    cap = gpu_of(n, "capacity")
    alloc = gpu_of(n, "allocatable")
    if alloc:
        gpu_nodes.append(name); total += int(alloc)
    installed = labels.get("metax-tech.com/gpu.installed", "-")
    if installed == "true" and not alloc:
        anomaly.append(name)
    prod = labels.get("metax-tech.com/gpu.product", "-")
    mem = labels.get("metax-tech.com/gpu.memory", "-")
    ready = "/".join([
        labels.get("metax-tech.com/driver.ready", "-"),
        labels.get("metax-tech.com/maca.ready", "-"),
        labels.get("metax-tech.com/runtime.ready", "-"),
    ])
    sched = "否" if (unsched or no_schedule) else "是"
    rows.append((name, role, cap or "-", alloc or "-", prod, mem, installed, ready, sched, ";".join(taints) or "-"))

print("节点 GPU 识别清单:")
print(f"{'NODE':<16}{'ROLE':<14}{'CAP':<8}{'ALLOC':<8}{'PRODUCT':<12}{'MEM':<8}{'INSTALLED':<10}{'DRV/MACA/RUN':<16}{'SCHED':<6}{'TAINTS'}")
for r in rows:
    print(f"{r[0]:<16}{r[1]:<14}{r[2]:<8}{r[3]:<8}{r[4]:<12}{r[5]:<8}{r[6]:<10}{r[7]:<16}{r[8]:<6}{r[9]}")
print()
print(f"GPU 识别节点数: {len(gpu_nodes)}  总 GPU(allocatable): {total}")
if anomaly:
    print(f"⚠ 异常: 节点 {anomaly} 已打 gpu.installed=true 但 allocatable 为空(设备插件未注册, 检查 metax-gpu-device pod)")
if not gpu_nodes:
    print("⚠ 未检测到任何节点识别 GPU(检查 gpu-label/gpu-device DaemonSet 与 metax 硬件)")
PY
)"
rm -f "${_TMP}"
echo "${OUT}"