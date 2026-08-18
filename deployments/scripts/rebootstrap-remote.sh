#!/bin/bash
# ============================================================
# 远端脚本: 彻底清理旧 k8s 状态 + kubeadm join + 启动 kubelet
# 由 rebootstrap-worker.sh 复制到 worker 后以 root 执行
# 用法: sudo JOIN_CMD="..." bash /tmp/rebootstrap-remote.sh
# ============================================================
set -e
echo "[rebootstrap-remote] 开始清理旧 k8s 状态 ..."
systemctl stop kubelet 2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true
rm -rf /etc/kubernetes
rm -rf /var/lib/kubelet
ctr -n k8s.io containers list -q 2>/dev/null | xargs -r ctr -n k8s.io containers rm 2>/dev/null || true
sleep 2

echo "[rebootstrap-remote] 执行 kubeadm join ..."
eval "${JOIN_CMD}"
echo "[rebootstrap-remote] join 完成, 启动 kubelet ..."
systemctl enable --now kubelet 2>/dev/null || true
echo "[rebootstrap-remote] DONE"
exit 0