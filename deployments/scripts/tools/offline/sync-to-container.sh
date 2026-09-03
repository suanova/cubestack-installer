#!/bin/bash
# ============================================================
# sync-to-container.sh — 把宿主机仓库(~/cubestack-installer)的 Ceph 离线部署改动
# 同步进 cubestack-install 容器(/opt/cubestack-installer, standalone 副本, 非 git)
# 用途: 用户用容器 CLI 重新部署集群前, 把本仓库已修改的脚本/playbook/rook manifests 拷进容器。
# 背景: 容器 /opt/cubestack-installer 是独立副本(无 git, 不自动跟随仓库);
#       docker cp 覆盖 overlay 可写层即可。
# 流程(用户要求): 【本地修改完成 → sudo docker cp 到容器】—— 不在容器内跑 sed。
#   cluster.conf: 本地先把 CEPH_ENABLED / CEPH_CSI_ENABLED 置 true(其余行不动),
#   然后整体 docker cp; 容器内原配置先备份为 .bak.ceph。
# ⚠ 需 sudo(本机 docker 无普通用户权限)。
# 用法: sudo bash deployments/scripts/tools/offline/sync-to-container.sh
# ============================================================
set -euo pipefail

CONTAINER="${CONTAINER:-cubestack-install}"
# 仓库根 = 本脚本 ../../../../..(deployments/scripts/tools/offline/ → 仓库根)
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
CT="/opt/cubestack-installer"
LOCAL_CONF="${REPO}/deployments/config/cluster.conf"
CT_CONF="${CT}/deployments/config/cluster.conf"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "【错误】需要 root(docker), 请 sudo 执行: sudo bash $0" >&2; exit 1; }; }
need_root

docker ps --filter "name=${CONTAINER}" --format '{{.Names}}' | grep -qx "${CONTAINER}" \
    || { echo "【错误】容器 ${CONTAINER} 未在运行(docker ps -a 查看)"; exit 1; }

echo "── 0. 本地 cluster.conf: 启用 Ceph(仅翻两个开关行, 其余行不动) ──"
[ -f "${LOCAL_CONF}" ] || { echo "【错误】本地配置不存在: ${LOCAL_CONF}"; exit 1; }
cp "${LOCAL_CONF}" "${LOCAL_CONF}.bak.ceph"
sed -E 's|^(CEPH_ENABLED)="\$\{CEPH_ENABLED:-false\}".*|CEPH_ENABLED="\${CEPH_ENABLED:-true}"   # Ceph 存储底座(默认部署; sync-to-container)|; s|^(CEPH_CSI_ENABLED)="\$\{CEPH_CSI_ENABLED:-false\}".*|CEPH_CSI_ENABLED="\${CEPH_CSI_ENABLED:-true}"   # Ceph CSI(默认部署; sync-to-container)|' "${LOCAL_CONF}" > "${LOCAL_CONF}.tmp" \
    && mv "${LOCAL_CONF}.tmp" "${LOCAL_CONF}"
grep -nE '^(CEPH_ENABLED|CEPH_CSI_ENABLED)=' "${LOCAL_CONF}" | sed 's/^/  /'
echo "  原配置已备份到 ${LOCAL_CONF}.bak.ceph"

echo ""
echo "── 1. 同步代码文件(repo → 容器 ${CONTAINER}:${CT}) ──"
FILES=(
    deployments/scripts/lib-common.sh
    deployments/scripts/lib-module.sh
    deployments/scripts/deploy-cluster.sh
    deployments/scripts/modules/02_k8s/06_k8s_deploy.sh
    deployments/scripts/modules/03_addon/02_ceph.sh
    deployments/scripts/modules/03_addon/03_ceph_csi.sh
    deployments/scripts/modules/03_addon/04_local_path.sh
    deployments/scripts/modules/03_addon/05_k8s_registry.sh
    deployments/scripts/tools/images/ceph-save-images.sh
    deployments/scripts/tools/images/ceph-sync-images.sh
    deployments/scripts/tools/k8s/ceph-detect-disks.sh
    deployments/scripts/tools/k8s/rook-fetch-manifests.sh
    deployments/scripts/tools/offline/fetch-lvm-packages.sh
    deployments/scripts/tools/vm/create-vms.sh
    deployments/kubespray/cubestack-offline.sh
    deployments/kubespray/kubespray/patch-playbooks/install-packages.yml
    # rook 离线 manifests(容器当前缺失, ceph 模块前置检查会硬失败)
    deployments/cubestack-addon/rook/common.yaml
    deployments/cubestack-addon/rook/crds.yaml
    deployments/cubestack-addon/rook/csi-operator.yaml
    deployments/cubestack-addon/rook/operator.yaml
    deployments/cubestack-addon/rook/toolbox.yaml
)
for f in "${FILES[@]}"; do
    [ -f "${REPO}/${f}" ] || { echo "  ⚠ 跳过(仓库无此文件): ${f}"; continue; }
    docker cp "${REPO}/${f}" "${CONTAINER}:${CT}/${f}"
    echo "  ✅ ${f}"
done

echo ""
echo "── 2. 推送 cluster.conf(含 ceph 开关)──"
# 先备份容器内原配置
docker exec "${CONTAINER}" bash -c "cp ${CT_CONF} ${CT_CONF}.bak.ceph 2>/dev/null || true"
docker cp "${LOCAL_CONF}" "${CONTAINER}:${CT_CONF}"
echo "  已推送 ${LOCAL_CONF} → ${CT_CONF}(容器原配置备份 .bak.ceph)"

echo ""
echo "── 3. 清理断点续跑状态(建议 --fresh 重新部署)──"
docker exec "${CONTAINER}" bash -c 'rm -f /opt/cubestack-installer/deployments/config/.deploy.state 2>/dev/null || true; echo "  已清除 .deploy.state"'

echo ""
echo "── 4. 验证(容器内)──"
docker exec "${CONTAINER}" bash -c '
  echo "  cluster.conf 开关:"; grep -nE "^(CEPH_ENABLED|CEPH_CSI_ENABLED)=" '"${CT_CONF}"'
  echo "  06_k8s_deploy.sh Ceph 预检:"; grep -c "Ceph 部署前确认" '"${CT}"/deployments/scripts/modules/02_k8s/06_k8s_deploy.sh' || true
  echo "  deploy-cluster 开始前倒计时:"; grep -c "部署开始前最后确认存储节点/裸盘" '"${CT}"/deployments/scripts/deploy-cluster.sh' || true
  echo "  02_ceph.sh 显式盘:"; grep -c "CEPH_DATA_DISKS" '"${CT}"/deployments/scripts/modules/03_addon/02_ceph.sh' || true
  echo "  detect python3 -c:"; grep -c "python3 -c" '"${CT}"/deployments/scripts/tools/k8s/ceph-detect-disks.sh' || true
  echo "  install-packages offline_dir:"; grep -c "offline_dir" '"${CT}"/deployments/kubespray/kubespray/patch-playbooks/install-packages.yml' || true
  echo "  rook manifests:"; ls '"${CT}"/deployments/cubestack-addon/rook/'*.yaml 2>/dev/null | wc -l
  echo "  lvm 离线包:"; ls '"${CT}"/deployments/offline-files/kubespray/packages/lvm2_'*.deb 2>/dev/null | wc -l
  echo "  METALLB_POOL(注意是否与节点同网段):"; grep -E "^METALLB_POOL=" '"${CT_CONF}"' | head -1
'

echo ""
echo "同步完成。接下来在容器内重新部署(建议):"
echo "  sudo docker exec -it cubestack-install bash"
echo "  cd /opt/cubestack-installer && sudo ./deployments/scripts/deploy-cluster.sh --fresh"
echo "⚠ 若 registry 之前用 local-path 建过 PVC, 重装后新 PVC 自动走 ceph-block;"
echo "  旧集群节点数据不影响 ceph 全新部署。"
