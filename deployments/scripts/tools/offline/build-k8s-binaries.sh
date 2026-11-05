#!/bin/bash
set -euo pipefail

# Build the k8s binaries bundle from kubespray's files.list.
#
# This is the installer-owned asset consumed by commercial base packaging
# (kubelet/kubeadm/kubectl/crictl/CNI/containerd/runc/etcd/...). It does
# not pull container images; OS packages are a pre-install check.
#
# Usage:
#   ./build-k8s-binaries.sh [--version v2.32.0] [--arch amd64]
#                           [--output PATH] [--workdir DIR]
#
# The output is a deterministic .tar.gz with the files at the archive root, so
# packaging files[] can use extract: true.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
VERSION="${KUBESPRAY_VERSION:-v2.32.0}"
ARCH="amd64"
WORKDIR=""
OUTPUT=""

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --arch) ARCH="${2:?--arch needs a value}"; shift 2 ;;
        --output) OUTPUT="${2:?--output needs a path}"; shift 2 ;;
        --workdir) WORKDIR="${2:?--workdir needs a path}"; shift 2 ;;
        --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

for cmd in tar gzip wget python3; do
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is required"
done

if [ -z "${WORKDIR}" ]; then
    WORKDIR="$(mktemp -d -t cubestack-k8s-binaries.XXXXXX)"
fi
mkdir -p "${WORKDIR}"
if [ -z "${OUTPUT}" ]; then
    OUTPUT="${WORKDIR}/kubespray-binaries-${VERSION}-${ARCH}.tar.gz"
fi

CLUSTER_CONF="${CLUSTER_CONF:-${REPO_ROOT}/deployments/config/cluster.conf.example}"
[ -f "${CLUSTER_CONF}" ] || die "cluster config not found: ${CLUSTER_CONF}"
INV_DIR="${WORKDIR}/inventory"
OFFLINE_ROOT="${WORKDIR}/offline-files"
OFFLINE_DIR="${OFFLINE_ROOT}/kubespray/${VERSION}"

export CLUSTER_CONF KUBESPRAY_VERSION="${VERSION}"
export KUBESPRAY_INV_DIR="${INV_DIR}" CUBESTACK_INVENTORY_DIR="${INV_DIR}"
export OFFLINE_FILES_ROOT="${OFFLINE_ROOT}" OFFLINE_FILES_DIR="${OFFLINE_DIR}"
export CUBESTACK_LOCAL_REPO_DIR="${OFFLINE_DIR}"
export CUBESTACK_KUBESPRAY_DIR="${REPO_ROOT}/deployments/kubespray/kubespray"
export CUBESTACK_BASE_DIR="${REPO_ROOT}/deployments/kubespray"

say "generating inventory (${VERSION})"
bash "${REPO_ROOT}/deployments/scripts/tools/k8s/gen-inventory.sh" >/dev/null

say "downloading k8s files (no images)"
env \
    "CUBESTACK_KUBESPRAY_DIR=${CUBESTACK_KUBESPRAY_DIR}" \
    "CUBESTACK_INVENTORY_DIR=${INV_DIR}" \
    "CUBESTACK_BASE_DIR=${CUBESTACK_BASE_DIR}" \
    "OFFLINE_FILES_ROOT=${OFFLINE_ROOT}" \
    "OFFLINE_FILES_DIR=${OFFLINE_DIR}" \
    "CUBESTACK_LOCAL_REPO_DIR=${OFFLINE_DIR}" \
    "CUBESTACK_REMOTE_USER=root" \
    "KUBESPRAY_VERSION=${VERSION}" \
    bash "${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh" \
    download-files cubestack-binaries

mapfile -t files < <(find "${OFFLINE_DIR}" -maxdepth 1 -type f -printf '%f\n' | sort)
[ "${#files[@]}" -gt 0 ] || die "no binaries downloaded under ${OFFLINE_DIR}"

say "packing ${#files[@]} files -> ${OUTPUT}"
mkdir -p "$(dirname "${OUTPUT}")"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -C "${OFFLINE_DIR}" -cf - "${files[@]}" | gzip -n >"${OUTPUT}.part"
mv "${OUTPUT}.part" "${OUTPUT}"

digest="$(sha256sum "${OUTPUT}" | awk '{print $1}')"
size="$(stat -c %s "${OUTPUT}")"
echo "output=${OUTPUT}"
echo "sha256=${digest}"
echo "size=${size}"
