#!/bin/bash
# ============================================================
# fetch-lvm-packages.sh — 离线下载 lvm2 及依赖 .deb 到 offline-files/kubespray/packages
# 用途: Ceph/Rook OSD 需要 lvm2(节点重启后逻辑卷重新激活); 离线集群需预置 .deb 包。
#       在联网(或内网 apt 源可达)的 Ubuntu 22.04 机器上执行, 自动 apt-get download
#       lvm2 + 依赖, 输出到 deployments/offline-files/kubespray/packages。
# ⚠ 执行顺序(必须): 本脚本生成 lvm2 离线包 **之后**, 才能部署 ceph 集群 ——
#       modules/03_addon/02_ceph.sh 部署前预检"packages/ 含 lvm2_*.deb 或节点已在线装 lvm",
#       均不满足则硬失败。请先在联网机执行本脚本, 再把 packages/ 目录同步到部署机。
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

# ⚠ 不能用 apt-get install --download-only(本机若已装 lvm2 → "0 upgraded" 什么都不下载)。
# 改为显式 apt-get download 全清单(lvm2 + 依赖 + 工具), 与"本机是否已装"无关, 必然拉取 .deb。
LVM_PACKAGES="lvm2 dmsetup dmeventd thin-provisioning-tools
libdevmapper1.02.1 libdevmapper-event1.02.1 liblvm2cmd2.03
libaio1 libudev1 libreadline8 libedit2"
TMP_DL="$(mktemp -d)"
say "  下载: ${LVM_PACKAGES}(apt-get download, 与本地是否已装 lvm2 无关)"
_FAIL=0
for _pkg in ${LVM_PACKAGES}; do
    if ! (cd "${TMP_DL}" && apt-get download "${_pkg}" >/dev/null 2>&1); then
        warn "    apt-get download ${_pkg} 失败(可能无此包/源缺该版本), 跳过"
        _FAIL=1
    fi
done
if [ "${_FAIL}" = "1" ]; then
    warn "部分依赖下载失败(见上); 请检查 apt 源是否含 lvm2 全家桶, 失败包需手工补齐到 ${PKG_DIR}"
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
