#!/bin/bash
# ============================================================
# 远端脚本: 同步集群 CA + 更新 kubelet.conf + 重启 kubelet
# 由 sync-ca.sh 复制到节点后以 root 执行
# ============================================================
set -e
mkdir -p /etc/kubernetes/pki /etc/kubernetes/ssl
cp /tmp/cubestack-ca.crt /etc/kubernetes/pki/ca.crt
cp /tmp/cubestack-ca.crt /etc/kubernetes/ssl/ca.crt
chmod 644 /etc/kubernetes/pki/ca.crt /etc/kubernetes/ssl/ca.crt

# 更新 kubelet.conf 内嵌 CA data(kubelet 用它验证 apiserver, 而非 pki/ca.crt)
if [ -f /etc/kubernetes/kubelet.conf ]; then
    CA_B64="$(base64 -w0 /tmp/cubestack-ca.crt)"
    sed -i "s|^[[:space:]]*certificate-authority-data: .*|    certificate-authority-data: ${CA_B64}|" /etc/kubernetes/kubelet.conf
fi

rm -f /tmp/cubestack-ca.crt
systemctl restart kubelet || true
exit 0