#!/bin/bash
# 后台收尾: 重启 metrics-server(镜像已补) + 验证集群
# 由 nohup 启动, 会话退出后继续
set -e
SSH="ssh -i /home/supperadm/.ssh/cubestack_k8s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@192.168.122.31"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

echo "[finish] $(date) 开始收尾..."
# 1. 重启 metrics-server pod(镜像已同步, 消除 ErrImagePull + IPVS 警告)
echo "[finish] 重启 metrics-server pod ..."
$SSH "$K delete pod -n kube-system -l app.kubernetes.io/name=metrics-server --force --grace-period=0 2>/dev/null || true"
sleep 15
# 2. 验证节点
echo "[finish] 节点状态:"
$SSH "$K get nodes"
# 3. 验证 metrics-server
echo "[finish] metrics-server pod:"
$SSH "$K get pod -n kube-system -l app.kubernetes.io/name=metrics-server -o wide"
# 4. 验证全部 pod
echo "[finish] 全部 pod:"
$SSH "$K get pod -A | grep -E 'calico|metrics|NAME'"
echo "[finish] $(date) 收尾完成"
