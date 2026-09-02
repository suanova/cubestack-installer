#!/bin/bash
# ============================================================
# fetch-lvm-packages.sh — 离线下载 lvm2 及依赖 .deb 到 offline-files/kubespray/packages
# 用途: Ceph/Rook OSD 需要 lvm2(节点重启后逻辑卷重新激活); 离线集群需预置 .deb 包。
#       在联网(或内网 apt 源可达)的 Ubuntu 22.04 机器上执行, 自动 apt-get download
#       lvm2 + 依赖, 输出到 deployments/offline-files/kubespray/packages。
# 安装: 部署时由 install-worker-packages.sh / patch-playbooks/install-packages.yml
#       (packages 目录)拷到节点 dpkg -i; ceph 模块部署前也会校验/补装。
# 用法: sudo ./fetch-lvm-packages.sh
# 说明: 仅 Ubuntu/Debian(.deb); 其它发行版请自行放置对应 rpm 包。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ "$(id -u)" -eq 0 ] || { err "需要 root(apt-get download), 请 sudo 执行"; exit 1; }

# 目标目录: offline-files/kubespray/packages(与 install-packages.yml / install-worker-packages.sh 兼容)
PKG_DIR="${PKG_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray/packages}"
mkdir -p "${PKG_DIR}"

say "下载 lvm2 及依赖 .deb → ${PKG_DIR}(需要联网或内网 apt 源) ..."
apt-get update -qq 2>/dev/null || true

# 用 apt-get install --download-only 自动解析 lvm2 依赖(thin-provisioning-tools/dmeventd/libdevmapper 等),
# 下载到临时目录后拷贝到 packages/; 已存在则跳过(幂等)。
TMP_DL="$(mktemp -d)"
if ! apt-get install --download-only --no-install-recommends -y lvm2 \
        -o Dir::Cache::archives="${TMP_DL}" >/dev/null 2>&1; then
    rm -rf "${TMP_DL}"
    err "apt-get download lvm2 失败(检查网络/apt 源); 请手工把 lvm2 与依赖 .deb 放到 ${PKG_DIR}"
    exit 1
fi
count=0
for deb in "${TMP_DL}"/*.deb; do
    [ -f "${deb}" ] || continue
    if [ ! -f "${PKG_DIR}/$(basename "${deb}")" ]; then
        cp "${deb}" "${PKG_DIR}/"
        count=$((count + 1))
    fi
done
rm -rf "${TMP_DL}"

echo "---------------------------------------------"
[ "${count}" -gt 0 ] && ok "新增 ${count} 个 .deb" || say "无新增(均已存在)"
ok "lvm2 离线包目录: ${PKG_DIR}"
ls -1 "${PKG_DIR}"/*.deb 2>/dev/null | sed 's/^/  /' || true
echo "  安装: 部署时 install-packages.yml / ceph 模块自动 dpkg -i(也可手工拷到节点)"
