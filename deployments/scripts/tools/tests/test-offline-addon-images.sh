#!/bin/bash
# 离线 addon 镜像源回归(不联网/不碰集群):
#   ① mirror_image_ref / mirror_rewrite_image_refs: 上游名 → mirror 名, 关闭时原样
#   ② Rook manifest 渲染: operator/csi/toolbox 的 image 引用重写, toolbox 浮动 tag 收敛到
#      CEPH_VERSION, csi-operator ImageSet 从空值钉到预加载镜像(render-csi-imageset.py)
#
# 从源码文件里**抽取**被测函数(而不是 source lib-common): lib-common 顶层会做 root 专属的
# /etc/containers 初始化, source 在非 root 下会中止 —— 抽取后可任意用户运行。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
CEPH_MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh"
TOOL="${REPO_ROOT}/deployments/scripts/tools/k8s/render-csi-imageset.py"
PASS=0; FAIL=0
ok(){ echo "  ok  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
chk(){ [ "$2" = "$3" ] && ok "$1" || bad "$1: 期望[$2] 实际[$3]"; }

extract_fn() {   # extract_fn <函数名> <文件>  (函数体以列首 `}` 结束)
    awk -v fn="$1" '$0 ~ "^" fn "\\(\\)" {f=1} f {print} f && /^}$/ {exit}' "$2"
}

eval "$(extract_fn harbor_mirror_base "${LIB}")"
eval "$(extract_fn mirror_image_ref "${LIB}")"
eval "$(extract_fn mirror_rewrite_image_refs "${LIB}")"
eval "$(grep -m1 '^bool_is_true()' "${LIB}")"
eval "$(extract_fn _rook_stage_manifests "${CEPH_MOD}")"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
HARBOR_MIRROR_ENABLED=true
HARBOR_MIRROR_REGISTRY=harbor.isuanova.com
HARBOR_MIRROR_PROJECT=mirrors

echo "== ① mirror 前缀与引用重写 =="
chk "harbor_mirror_base" "harbor.isuanova.com/mirrors" "$(harbor_mirror_base)"
chk "docker.io → mirror" "harbor.isuanova.com/mirrors/docker.io/library/busybox:1.38.0" \
    "$(mirror_image_ref docker.io/library/busybox:1.38.0)"
chk "registry.k8s.io → mirror" "harbor.isuanova.com/mirrors/registry.k8s.io/pause:3.10.1" \
    "$(mirror_image_ref registry.k8s.io/pause:3.10.1)"
chk "已是 mirror 名 → 不变(幂等)" "harbor.isuanova.com/mirrors/quay.io/ceph/ceph:v20.2.2" \
    "$(mirror_image_ref harbor.isuanova.com/mirrors/quay.io/ceph/ceph:v20.2.2)"
chk "非已知注册域 → 不变" "myregistry.local:5000/team/app:1" \
    "$(mirror_image_ref myregistry.local:5000/team/app:1)"
HARBOR_MIRROR_ENABLED=false
chk "mirror 关闭 → harbor_mirror_base 为空" "" "$(harbor_mirror_base)"
chk "mirror 关闭 → 引用原样" "docker.io/rook/ceph:v1.21.1" \
    "$(mirror_image_ref docker.io/rook/ceph:v1.21.1)"
HARBOR_MIRROR_ENABLED=true

cat > "${TMP}/in.yaml" <<'EOF'
spec:
  containers:
    - name: rook
      image: docker.io/rook/ceph:v1.21.1
      imagePullPolicy: IfNotPresent
  # 示例文本(注释)不应被改: image: quay.io/ceph/ceph:v20.2.2
  other: quay.io/not-an-image-field/x
EOF
mirror_rewrite_image_refs "${TMP}/in.yaml" "${TMP}/out.yaml"
chk "image 行 → mirror 名" "1" "$(grep -c '^      image: harbor\.isuanova\.com/mirrors/docker\.io/rook/ceph:v1\.21\.1$' "${TMP}/out.yaml")"
chk "非 image 字段不动" "1" "$(grep -c '^  other: quay\.io/not-an-image-field/x$' "${TMP}/out.yaml")"
chk "注释示例不动" "1" "$(grep -c '^  # 示例文本(注释)不应被改: image: quay\.io/ceph/ceph:v20\.2\.2$' "${TMP}/out.yaml")"
HARBOR_MIRROR_ENABLED=false
mirror_rewrite_image_refs "${TMP}/in.yaml" "${TMP}/out-off.yaml"
chk "mirror 关闭 → 原样复制" "0" "$(grep -c 'harbor\.isuanova\.com' "${TMP}/out-off.yaml")"
HARBOR_MIRROR_ENABLED=true

echo "== ② Rook manifest 渲染(镜像源 + toolbox tag + csi ImageSet) =="
ROOK_SRC="${TMP}/rook"; STAGE="${TMP}/stage"; mkdir -p "${ROOK_SRC}"
cat > "${ROOK_SRC}/operator.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: rook-csi-operator-image-set-configmap
  namespace: rook-ceph
data:
  provisioner: ""
  attacher: ""
  resizer: ""
  snapshotter: ""
  registrar: ""
  plugin: ""
  addons: ""
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rook-ceph-operator
spec:
  template:
    spec:
      containers:
        - name: rook-ceph-operator
          image: docker.io/rook/ceph:v1.21.1
EOF
cat > "${ROOK_SRC}/csi-operator.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ceph-csi-operator
spec:
  template:
    spec:
      containers:
        - name: manager
          image: quay.io/cephcsi/ceph-csi-operator:v1.1.0
EOF
cat > "${ROOK_SRC}/toolbox.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rook-ceph-tools
spec:
  template:
    spec:
      containers:
        - name: rook-ceph-tools
          image: quay.io/ceph/ceph:v20
EOF
printf 'apiVersion: v1\nkind: Namespace\n' > "${ROOK_SRC}/common.yaml"
printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\n' > "${ROOK_SRC}/crds.yaml"

CEPH_ROOK_MANIFEST_DIR="${ROOK_SRC}"
SCRIPT_DIR="${REPO_ROOT}/deployments/scripts"
_CEPH_MIRROR_BASE="harbor.isuanova.com/mirrors"
CEPH_VERSION="v20.2.2"
ROOK_CSI_PROVISIONER_VERSION="v6.3.0"
ROOK_CSI_ATTACHER_VERSION="v4.13.0"
ROOK_CSI_RESIZER_VERSION="v2.2.1"
ROOK_CSI_SNAPSHOTTER_VERSION="v8.6.0"
ROOK_CSI_NODE_DRIVER_REGISTRAR_VERSION="v2.18.0"
CSI_SNAPSHOT_METADATA_VERSION="v1.1.0"
CEPHCSI_VERSION="v3.18.1"
CSIADDONS_SIDECAR_VERSION="v0.15.1"
if _rook_stage_manifests "${STAGE}"; then ok "渲染函数返回 0"; else bad "渲染函数返回非 0"; fi
chk "rook operator 镜像 → mirror" "1" \
    "$(grep -c '^          image: harbor\.isuanova\.com/mirrors/docker\.io/rook/ceph:v1\.21\.1$' "${STAGE}/operator.yaml")"
chk "csi-operator 镜像 → mirror" "1" \
    "$(grep -c '^          image: harbor\.isuanova\.com/mirrors/quay\.io/cephcsi/ceph-csi-operator:v1\.1\.0$' "${STAGE}/csi-operator.yaml")"
chk "toolbox 浮动 v20 → 钉死 CEPH_VERSION" "1" \
    "$(grep -c '^          image: harbor\.isuanova\.com/mirrors/quay\.io/ceph/ceph:v20\.2\.2$' "${STAGE}/toolbox.yaml")"
chk "ImageSet provisioner 已钉" "1" \
    "$(grep -c '^  provisioner: "harbor\.isuanova\.com/mirrors/registry\.k8s\.io/sig-storage/csi-provisioner:v6\.3\.0"$' "${STAGE}/operator.yaml")"
chk "ImageSet plugin 已钉" "1" \
    "$(grep -c '^  plugin: "harbor\.isuanova\.com/mirrors/quay\.io/cephcsi/cephcsi:v3\.18\.1"$' "${STAGE}/operator.yaml")"
chk "ImageSet 缺失键(snapshot-metadata)已补齐" "1" \
    "$(grep -c '^  snapshot-metadata: "harbor\.isuanova\.com/mirrors/registry\.k8s\.io/sig-storage/csi-snapshot-metadata:v1\.1\.0"$' "${STAGE}/operator.yaml")"
chk "非镜像清单原样复制" "1" \
    "$(grep -c '^kind: CustomResourceDefinition$' "${STAGE}/crds.yaml")"

echo "== ③ render-csi-imageset.py: 空版本不覆盖 / 缺 ConfigMap 报错 =="
cp "${ROOK_SRC}/operator.yaml" "${TMP}/empty.yaml"
python3 "${TOOL}" "${TMP}/empty.yaml" "harbor.isuanova.com/mirrors" "provisioner=registry.k8s.io/sig-storage/csi-provisioner="
chk "空版本 → 保持空值" "1" "$(grep -c '^  provisioner: ""$' "${TMP}/empty.yaml")"
printf 'kind: Namespace\n' > "${TMP}/nocs.yaml"
if python3 "${TOOL}" "${TMP}/nocs.yaml" "harbor.isuanova.com/mirrors" "provisioner=a/b=v1" >/dev/null 2>&1; then
    bad "缺 ImageSet ConfigMap 应失败"
else
    ok "缺 ImageSet ConfigMap → 非 0"
fi

echo "---------------------------------------------"
[ "${FAIL}" = 0 ] && { echo "✅ 全部 ${PASS} 项通过"; exit 0; } || { echo "❌ ${FAIL} 项失败"; exit 1; }
