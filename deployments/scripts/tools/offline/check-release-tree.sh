#!/bin/bash
# Reject an unassembled full package. The installer only consumes trees built
# by fetch-offline.sh; it no longer extracts meta/payload tars itself.
set -euo pipefail

ROOT="${1:?usage: check-release-tree.sh <release-root> <version>}"
VERSION="${2:?usage: check-release-tree.sh <release-root> <version>}"

case "${VERSION}" in
    ""|.*|*[!A-Za-z0-9._-]*) echo "ERROR: invalid release version: ${VERSION}" >&2; exit 2 ;;
esac

DIR="${ROOT}/${VERSION}"
META="${DIR}/cubestack-${VERSION}.meta.tar.zst"

if [ -f "${META}" ] && [ ! -f "${DIR}/offline-files/release.env" ]; then
    cat >&2 <<EOF
ERROR: 检测到未组装的 full package: ${META}
installer 不再自动解包。请先执行：
  fetch-offline.sh --package-dir ${DIR} --dest ${DIR} --no-download
（或在联网机器上用 --source s3://... 下载后拷贝过来）
EOF
    exit 3
fi

exit 0
