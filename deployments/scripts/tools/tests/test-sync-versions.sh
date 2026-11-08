#!/bin/bash
set -euo pipefail

# Regression tests for sync-versions.py: managed values feed derived files,
# display-only values are locked to their vendored source, and --check detects
# stale output.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${ROOT}/deployments/scripts/tools/k8s/sync-versions.py"
TMP="$(mktemp -d -t cubestack-sync-versions.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

mkdir -p "${TMP}/versions" "${TMP}/deployments/config/profiles" \
    "${TMP}/deployments/kubespray/inventory/cubestack-cluster/group_vars/all" \
    "${TMP}/deployments/kubespray/kubespray/roles/kubespray_defaults/defaults/main" \
    "${TMP}/deployments/kubespray/kubespray/roles/kubespray_defaults/vars/main" \
    "${TMP}/deployments/cubestack-addon/rook"

cat > "${TMP}/versions/base.yaml" <<'EOF'
schema: 1
kubespray:
  version: v2.32.0
mirror:
  repo: suanova/container-image-mirror
  commit: 350051845414c9e6a621aca402c27b74c4d7ef64
  path: index.json
env:
  KUBESPRAY_VERSION: v2.32.0
  K8S_VERSION: v1.35.8
  PAUSE_VERSION: 3.10.1
  COREDNS_VERSION: v1.12.4
  DNS_NODE_CACHE_VERSION: 1.25.0
  METRICS_SERVER_VERSION: v0.9.1
  CPA_VERSION: v1.10.3
  ETCD_VERSION: v3.6.16
  CALICO_VERSION: v3.32.2
  METALLB_VERSION: v0.13.9
  KUBE_VIP_VERSION: v1.3.1
  REGISTRY_IMAGE_TAG: 2.8.1
  LOCAL_PATH_VERSION: v0.0.37
  LOCAL_VOLUME_PROVISIONER_VERSION: 2.10.0
  NFD_VERSION: 0.20.1
  API_LB_NGINX_IMAGE_TAG: 1.30.6-alpine
  CEPH_VERSION: v20.2.2
  CEPHCSI_VERSION: v3.17.0
  CEPH_CSI_OPERATOR_VERSION: v1.0.4
  CSIADDONS_SIDECAR_VERSION: v0.14.0
  CSI_ATTACHER_VERSION: v4.5.1
  CSI_NODE_DRIVER_REGISTRAR_VERSION: v2.4.0
  CSI_PROVISIONER_VERSION: v4.0.1
  CSI_RESIZER_VERSION: v1.10.1
  CSI_SNAPSHOTTER_VERSION: v7.0.2
  NGINX_TAG: '1.27'
  ROOK_VERSION: v1.20.2
  SNAPSHOT_CONTROLLER_VERSION: v7.0.2
display_only:
  - CEPHCSI_VERSION
  - CEPH_CSI_OPERATOR_VERSION
  - CSIADDONS_SIDECAR_VERSION
  - CSI_ATTACHER_VERSION
  - CSI_NODE_DRIVER_REGISTRAR_VERSION
  - CSI_PROVISIONER_VERSION
  - CSI_RESIZER_VERSION
  - CSI_SNAPSHOTTER_VERSION
  - NGINX_TAG
  - ROOK_VERSION
  - SNAPSHOT_CONTROLLER_VERSION
checksums:
  etcd:
    amd64: sha256:1111111111111111111111111111111111111111111111111111111111111111
    arm64: sha256:2222222222222222222222222222222222222222222222222222222222222222
  calicoctl:
    amd64: sha256:3333333333333333333333333333333333333333333333333333333333333333
    arm64: sha256:4444444444444444444444444444444444444444444444444444444444444444
  calico_crds:
    no_arch: sha256:5555555555555555555555555555555555555555555555555555555555555555
EOF

cat > "${TMP}/deployments/config/cluster.defaults.conf" <<'EOF'
# >>> BEGIN GENERATED VERSIONS (versions/base.yaml; run: make sync-versions) >>>
# <<< END GENERATED VERSIONS <<<
CEPHCSI_VERSION="${CEPHCSI_VERSION:-v3.17.0}"
CEPH_CSI_OPERATOR_VERSION="${CEPH_CSI_OPERATOR_VERSION:-v1.0.4}"
CSIADDONS_SIDECAR_VERSION="${CSIADDONS_SIDECAR_VERSION:-v0.14.0}"
CSI_ATTACHER_VERSION="${CSI_ATTACHER_VERSION:-v4.5.1}"
CSI_NODE_DRIVER_REGISTRAR_VERSION="${CSI_NODE_DRIVER_REGISTRAR_VERSION:-v2.4.0}"
CSI_PROVISIONER_VERSION="${CSI_PROVISIONER_VERSION:-v4.0.1}"
CSI_RESIZER_VERSION="${CSI_RESIZER_VERSION:-v1.10.1}"
CSI_SNAPSHOTTER_VERSION="${CSI_SNAPSHOTTER_VERSION:-v7.0.2}"
NGINX_TAG="${NGINX_TAG:-1.27}"
ROOK_VERSION="${ROOK_VERSION:-v1.20.2}"
SNAPSHOT_CONTROLLER_VERSION="${SNAPSHOT_CONTROLLER_VERSION:-v7.0.2}"
EOF

cat > "${TMP}/deployments/kubespray/kubespray/roles/kubespray_defaults/defaults/main/download.yml" <<'EOF'
csi_attacher_image_tag: "v4.5.1"
csi_provisioner_image_tag: "v4.0.1"
csi_snapshotter_image_tag: "v7.0.2"
csi_resizer_image_tag: "v1.10.1"
csi_node_driver_registrar_image_tag: "v2.4.0"
snapshot_controller_supported_versions:
  '1.35': "v7.0.2"
EOF

cat > "${TMP}/deployments/cubestack-addon/rook/operator.yaml" <<'EOF'
plugin: "quay.io/cephcsi/cephcsi:v3.17.0"
addons: "quay.io/csiaddons/k8s-sidecar:v0.14.0"
image: docker.io/rook/ceph:v1.20.2
EOF

cat > "${TMP}/deployments/cubestack-addon/rook/csi-operator.yaml" <<'EOF'
image: quay.io/cephcsi/ceph-csi-operator:v1.0.4
EOF

python3 "${TOOL}" --root "${TMP}" >/dev/null
grep -q 'METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.9.1}"' \
    "${TMP}/deployments/config/cluster.defaults.conf" \
    || fail "managed value missing from defaults block"
grep -q '^METRICS_SERVER_VERSION=v0.9.1$' \
    "${TMP}/deployments/config/profiles/v2.32.0.profile" \
    || fail "managed value missing from profile"
grep -q '^metrics_server_version: "0.9.1"$' \
    "${TMP}/deployments/kubespray/inventory/cubestack-cluster/group_vars/all/k8s-versions.yml" \
    || fail "managed value missing from inventory"
grep -q '^etcd_binary_checksum: "sha256:1111' \
    "${TMP}/deployments/kubespray/inventory/cubestack-cluster/group_vars/all/k8s-versions.yml" \
    || fail "checksum scalar missing from inventory"
pass "managed values and checksums feed derived files"

python3 "${TOOL}" --root "${TMP}" --check >/dev/null \
    || fail "--check should pass after write"
before="$(sha256sum "${TMP}/deployments/config/cluster.defaults.conf")"
python3 "${TOOL}" --root "${TMP}" >/dev/null
after="$(sha256sum "${TMP}/deployments/config/cluster.defaults.conf")"
[ "${before}" = "${after}" ] || fail "write is not idempotent"
pass "write is idempotent and --check passes"

sed -i 's/METRICS_SERVER_VERSION: v0.9.1/METRICS_SERVER_VERSION: v0.9.2/' \
    "${TMP}/versions/base.yaml"
if python3 "${TOOL}" --root "${TMP}" --check >/dev/null 2>&1; then
    fail "stale generated files should fail --check"
fi
python3 "${TOOL}" --root "${TMP}" >/dev/null
pass "stale derived files are detected"

sed -i 's/CSI_ATTACHER_VERSION: v4.5.1/CSI_ATTACHER_VERSION: v9.9.9/' \
    "${TMP}/versions/base.yaml"
if out="$(python3 "${TOOL}" --root "${TMP}" --write 2>&1)"; then
    fail "display-only edit should be rejected"
fi
grep -q "does not match" <<<"${out}" || fail "display-only error not explained"
pass "display-only edits are rejected"

sed -i 's/^    amd64: sha256:1111.*/    amd64: ""/' "${TMP}/versions/base.yaml"
if python3 "${TOOL}" --root "${TMP}" --write >/dev/null 2>&1; then
    fail "missing etcd checksum should be rejected"
fi
pass "missing checksum is rejected"

echo "all sync-versions tests passed"
