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
           "$(ssh_user_for_ip "${FIRST_MASTER}")@${FIRST_MASTER}" "$@"; }
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

# ---------------- 权限探针: 非 root 真实打开设备(2026-10-13 "family N" 加固) ----------------
# 只信它: mx-smi exit 0 / device_count() 返回请求值在"设备无权限"时**全部正常**(mx-smi 只读
# sysfs 不开 /dev 节点; device_count 报的是 vendor 配置的可见集, 不是成功的 open) —— 唯一能把
# "资源分配到了但打不开"区分出来的断言 = 非 root 真实 open 设备(torch.cuda.is_available()
# 即基于真实 open)。探针 = runAsUser/runAsGroup:1000 + metax-tech.com/gpu:1, 镜像用 dev_lab
# 的 jupyter-maca-pytorch(集群 registry, 离线可用; 含 torch+MACA)。
if echo "${OUT}" | grep -q "GPU 识别节点数: 0 "; then
    say "权限探针: 跳过(集群无 GPU 节点)"
else
    _PROBE_IMG="${METAX_PERM_PROBE_IMAGE:-${REGISTRY_DOMAIN:-registry.cubestack.io}:${REGISTRY_PORT:-5000}/suanova/jupyter-maca-pytorch:${DEV_LAB_IMAGE_TAG:-latest}}"
    say "权限探针: runAsUser=1000 真实打开 /dev/mxcd + torch.cuda.is_available()(镜像 ${_PROBE_IMG})..."
    SSH "${K} -n default delete pod metax-devperm-probe --ignore-not-found >/dev/null 2>&1" || true
    if SSH "${K} -n default apply -f - >/dev/null 2>&1" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: metax-devperm-probe
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: ${_PROBE_IMG}
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
      resources:
        limits:
          metax-tech.com/gpu: 1
      command: ["python3", "-c", "import os,sys; fd=os.open('/dev/mxcd', os.O_RDWR); print('open(/dev/mxcd) OK fd', fd); os.close(fd); import torch; ok=torch.cuda.is_available(); print('torch.cuda.is_available():', ok); sys.exit(0 if ok else 1)"]
EOF
    then
        _state=""
        for _i in $(seq 1 36); do
            _state="$( (SSH "${K} -n default get pod metax-devperm-probe -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
            case "${_state}" in Succeeded|Failed) break ;; esac
            sleep 5
        done
        ( SSH "${K} -n default logs metax-devperm-probe 2>/dev/null" || true ) | sed 's/^/    /'
        SSH "${K} -n default delete pod metax-devperm-probe --ignore-not-found >/dev/null 2>&1" || true
        if [ "${_state}" = "Succeeded" ]; then
            ok "  权限探针通过: 非 root 可真实打开 GPU 设备"
        else
            err "  权限探针失败(${_state:-未结束}): 非 root 打不开 GPU 设备(资源分配了却无权限)!"
            err "    → 检查节点 /etc/containerd/config.toml 的 device_ownership_from_security_context=true;"
            err "      修复: bash deployments/scripts/tools/node/ensure-containerd-device-ownership.sh(改后需重建工作负载)"
            exit 1
        fi
    else
        warn "  权限探针 pod 创建失败(检查镜像可达: ${_PROBE_IMG} —— dev_lab 是否已推入集群 registry? 可用 METAX_PERM_PROBE_IMAGE 覆盖)"
    fi
fi