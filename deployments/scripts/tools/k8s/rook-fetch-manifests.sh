#!/bin/bash
# ============================================================
# rook-fetch-manifests.sh — 下载 Rook 官方离线 manifest 到 cubestack-addon/rook
# 用途: 在联网机上从官方 GitHub release tag(默认 v1.20.2)下载
#   rook/deploy/examples/{crds.yaml,common.yaml,csi-operator.yaml,operator.yaml,toolbox.yaml}
#   到 deployments/cubestack-addon/rook/, 供离线部署 ceph 模块使用。
# 用法: sudo ./rook-fetch-manifests.sh            # ROOK_VERSION=v1.20.2(默认)
#       ROOK_VERSION=v1.20.2 ./rook-fetch-manifests.sh
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

ROOK_VERSION="${ROOK_VERSION:-v1.20.2}"
DEST_DIR="${CEPH_ROOK_MANIFEST_DIR:-${REPO_ROOT}/deployments/cubestack-addon/rook}"
mkdir -p "${DEST_DIR}"

BASE="https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples"
FILES="crds.yaml common.yaml csi-operator.yaml operator.yaml toolbox.yaml"

say "下载 Rook ${ROOK_VERSION} manifests → ${DEST_DIR} ..."
for f in ${FILES}; do
    url="${BASE}/${f}"
    if curl -fsSL -o "${DEST_DIR}/${f}" "${url}"; then
        ok "  ${f}"
    else
        rm -f "${DEST_DIR}/${f}"
        err "  下载失败: ${url}(检查网络 / ROOK_VERSION); 可手工下载后放到 ${DEST_DIR}/"
        exit 1
    fi
done
[ -f "${DEST_DIR}/csi-operator.yaml" ] || { err "缺少 csi-operator.yaml(rook v1.20 必须, 见 docs/ceph-rook.md)"; exit 1; }
ok "Rook manifests 就绪: ${DEST_DIR}"
echo "  下一步(部署机): CEPH_ENABLED=true 部署 modules/03_addon/02_ceph.sh"
