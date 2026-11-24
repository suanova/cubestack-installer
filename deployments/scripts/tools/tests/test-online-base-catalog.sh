#!/bin/bash
set -euo pipefail

# Regression tests for the online base catalog, materializer and OS pre-check.
# Fixtures are generated in a temp dir; skopeo/ssh are shimmed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
ONLINE="${ROOT}/deployments/scripts/tools/online"
TMP="$(mktemp -d -t cubestack-online-test.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

mkdir -p "${TMP}/bin" "${TMP}/baseline/versions/os" "${TMP}/offline"

cat > "${TMP}/baseline/versions/base.yaml" <<'EOF'
schema: 1
kubespray:
  version: v2.32.0
mirror:
  repo: suanova/container-image-mirror
  commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  path: index.json
env:
  KUBESPRAY_VERSION: v2.32.0
  TEST_VERSION: v1.35.8
  UNUSED: x
checksums:
  etcd:
    amd64: sha256:1111111111111111111111111111111111111111111111111111111111111111
    arm64: sha256:2222222222222222222222222222222222222222222222222222222222222222
  calicoctl:
    amd64: sha256:3333333333333333333333333333333333333333333333333333333333333333
    arm64: sha256:4444444444444444444444444444444444444444444444444444444444444444
  calico_crds:
    no_arch: sha256:5555555555555555555555555555555555555555555555555555555555555555
os:
  - family: debian
    id: ubuntu
    version: "22.04"
    packages_check: versions/os/test.lock
images:
  - key: "k8s-base:registry.k8s.io/kube-apiserver"
    catalog_id: "kubernetes/kube-apiserver"
    version: "v1.35.8"
    dest: "offline-files/kubespray/v2.32.0/images"
    tar: "registry.k8s.io_kube-apiserver_v1.35.8.tar"
  - key: "netshoot:netshoot-rdma"
    source_ref: "harbor.isuanova.com/suanova/netshoot-rdma"
    version: "26.04.17"
    digest: "sha256:4444444444444444444444444444444444444444444444444444444444444444"
    dest: "offline-files/netshoot"
    tar: "netshoot-rdma.tar"
  - key: "optional:demo"
    source_ref: "harbor.isuanova.com/suanova/optional-demo"
    version: "v1.0.0"
    digest: "sha256:5555555555555555555555555555555555555555555555555555555555555555"
    dest: "offline-files/optional"
    tar: "harbor.isuanova.com_suanova_optional-demo_v1.0.0.tar"
    optional: true
EOF

cat > "${TMP}/baseline/versions/os/test.lock" <<'EOF'
schema: 1
family: debian
id: ubuntu
version: "22.04"
packages:
  reconcile:
    bash: "1"
    coreutils: "1"
EOF

cat > "${TMP}/index.json" <<'EOF'
{
  "schema": 1,
  "images": [
    {
      "id": "kubernetes/kube-apiserver",
      "name": "kube-apiserver",
      "source": "registry.k8s.io/kube-apiserver",
      "target": "harbor.isuanova.com/mirrors/registry.k8s.io/kube-apiserver",
      "versions": [
        {"tag": "v1.35.8", "digest": "sha256:6a7b73e718540d2c097cbcdc84c0f2cffad7a51ebccaf7f0b8cceb464715e1d9", "platforms": ["linux/amd64"]}
      ]
    }
  ]
}
EOF

# ---- resolver ----
PLAN="$(python3 "${ONLINE}/lib-base-catalog.py" \
    --baseline "${TMP}/baseline/versions/base.yaml" --index "${TMP}/index.json")"
[ "$(jq -r '.images | length' <<<"${PLAN}")" = "3" ] || fail "resolver: expected 3 images"
[ "$(jq -r '.images[0].path' <<<"${PLAN}")" = "offline-files/kubespray/v2.32.0/images/registry.k8s.io_kube-apiserver_v1.35.8.tar" ] || fail "resolver: bad path"
[ "$(jq -r '.images[0].ref' <<<"${PLAN}")" = "harbor.isuanova.com/mirrors/registry.k8s.io/kube-apiserver@sha256:6a7b73e718540d2c097cbcdc84c0f2cffad7a51ebccaf7f0b8cceb464715e1d9" ] || fail "resolver: bad ref"
[ "$(jq -r '.images[0].repo_tag' <<<"${PLAN}")" = "registry.k8s.io/kube-apiserver:v1.35.8" ] || fail "resolver: bad repo_tag"
[ "$(jq -r '.images[1].ref' <<<"${PLAN}")" = "harbor.isuanova.com/suanova/netshoot-rdma@sha256:4444444444444444444444444444444444444444444444444444444444444444" ] || fail "resolver: bad source_ref ref"
[ "$(jq -r '.images[2].optional' <<<"${PLAN}")" = "true" ] || fail "resolver: optional flag lost"
pass "resolver maps catalog and source_ref entries"

# standalone materialization: use baseline env when the process does not export
# the version, but keep an explicit process value authoritative
sed 's/version: "v1.35.8"/version: "${TEST_VERSION}"/' \
    "${TMP}/baseline/versions/base.yaml" > "${TMP}/env-fallback.yaml"
env -u TEST_VERSION python3 "${ONLINE}/lib-base-catalog.py" \
    --baseline "${TMP}/env-fallback.yaml" --index "${TMP}/index.json" \
    > "${TMP}/plan-env-fallback.json"
[ "$(jq -r '.images[0].version' "${TMP}/plan-env-fallback.json")" = "v1.35.8" ] \
    || fail "resolver: baseline env fallback failed"
TEST_VERSION=v9.9.9 python3 "${ONLINE}/lib-base-catalog.py" \
    --baseline "${TMP}/env-fallback.yaml" --index "${TMP}/index.json" \
    >/dev/null 2>"${TMP}/err" && fail "resolver: explicit env override not applied"
grep -q "not in catalog" "${TMP}/err" || fail "resolver: explicit env override error not reported"
pass "resolver falls back to baseline env and honors explicit overrides"

sed 's/v1.35.8/v9.9.9/' "${TMP}/baseline/versions/base.yaml" > "${TMP}/bad-tag.yaml"
if python3 "${ONLINE}/lib-base-catalog.py" --baseline "${TMP}/bad-tag.yaml" --index "${TMP}/index.json" >/dev/null 2>"${TMP}/err"; then
    fail "resolver: missing tag should fail"
fi
grep -q "not in catalog" "${TMP}/err" || fail "resolver: missing-tag error not reported"
pass "resolver rejects an unknown tag"

sed 's#kubernetes/kube-apiserver#kubernetes/does-not-exist#' "${TMP}/index.json" > "${TMP}/bad-id.json"
if python3 "${ONLINE}/lib-base-catalog.py" --baseline "${TMP}/baseline/versions/base.yaml" --index "${TMP}/bad-id.json" >/dev/null 2>"${TMP}/err"; then
    fail "resolver: missing catalog id should fail"
fi
grep -q "catalog_id not found" "${TMP}/err" || fail "resolver: missing-id error not reported"
pass "resolver rejects a missing catalog id"

sed 's/v1.35.8/${NOPE}/' "${TMP}/baseline/versions/base.yaml" > "${TMP}/bad-var.yaml"
if python3 "${ONLINE}/lib-base-catalog.py" --baseline "${TMP}/bad-var.yaml" --index "${TMP}/index.json" >/dev/null 2>"${TMP}/err"; then
    fail "resolver: unknown variable should fail"
fi
grep -q "undefined variable" "${TMP}/err" || fail "resolver: undefined-variable error not reported"
pass "resolver rejects an undefined variable"

# ---- baseline validator ----
python3 "${ROOT}/deployments/scripts/tools/validate-base-baseline.py" \
    --root "${TMP}/baseline" >/dev/null || fail "validator: valid fixture rejected"
grep -v 'sha256:444444' "${TMP}/baseline/versions/base.yaml" > "${TMP}/baseline/versions/base-bad.yaml"
if python3 "${ROOT}/deployments/scripts/tools/validate-base-baseline.py" \
    --root "${TMP}/baseline" --baseline "${TMP}/baseline/versions/base-bad.yaml" >/dev/null 2>"${TMP}/err"; then
    fail "validator: source_ref without digest should fail"
fi
grep -q "source_ref requires a sha256 digest" "${TMP}/err" \
    || fail "validator: missing source_ref digest not reported"
pass "validator requires a digest on source_ref images"

# ---- materializer ----
cat > "${TMP}/bin/skopeo" <<'EOF'
#!/bin/bash
set -euo pipefail
dst="${@: -1}"
rest="${dst#docker-archive:}"
path="${rest%%:*}"
mkdir -p "$(dirname "${path}")"
printf 'fake tar\n' > "${path}"
EOF
chmod +x "${TMP}/bin/skopeo"

PATH="${TMP}/bin:${PATH}" "${ONLINE}/materialize-base-images.sh" \
    --baseline "${TMP}/baseline/versions/base.yaml" --index "${TMP}/index.json" \
    --offline-root "${TMP}/offline" >"${TMP}/mat.out"
[ -s "${TMP}/offline/kubespray/v2.32.0/images/registry.k8s.io_kube-apiserver_v1.35.8.tar" ] || fail "materializer: missing catalog tar"
[ -s "${TMP}/offline/netshoot/netshoot-rdma.tar" ] || fail "materializer: missing source_ref tar"
[ ! -e "${TMP}/offline/optional" ] || fail "materializer: optional image should be skipped by default"
grep -q "copied=2" "${TMP}/mat.out" || fail "materializer: unexpected summary"
grep -q "optional-skipped=1" "${TMP}/mat.out" || fail "materializer: optional skip not reported"
pass "materializer writes catalog/source_ref tars and skips optional images"

# --include-group selects optional images from one key group only
PATH="${TMP}/bin:${PATH}" "${ONLINE}/materialize-base-images.sh" \
    --baseline "${TMP}/baseline/versions/base.yaml" --index "${TMP}/index.json" \
    --offline-root "${TMP}/offline-group" --include-group optional >"${TMP}/mat-group.out"
[ -s "${TMP}/offline-group/optional/harbor.isuanova.com_suanova_optional-demo_v1.0.0.tar" ] \
    || fail "materializer: --include-group did not include the optional group"
grep -q "copied=3" "${TMP}/mat-group.out" \
    || fail "materializer: --include-group summary mismatch"
pass "materializer includes an optional group on request"

PATH="${TMP}/bin:${PATH}" "${ONLINE}/materialize-base-images.sh" \
    --baseline "${TMP}/baseline/versions/base.yaml" --index "${TMP}/index.json" \
    --offline-root "${TMP}/offline-group2" --include-group metax-gpu-operator \
    >"${TMP}/mat-group2.out"
[ ! -e "${TMP}/offline-group2/optional" ] \
    || fail "materializer: non-matching group included optional image"
grep -q "optional-skipped=1" "${TMP}/mat-group2.out" \
    || fail "materializer: non-matching group did not skip optional"
pass "materializer skips optional groups that were not requested"

PATH="${TMP}/bin:${PATH}" "${ONLINE}/materialize-base-images.sh" \
    --baseline "${TMP}/baseline/versions/base.yaml" --index "${TMP}/index.json" \
    --offline-root "${TMP}/offline" --include-optional >"${TMP}/mat-opt.out"
[ -s "${TMP}/offline/optional/harbor.isuanova.com_suanova_optional-demo_v1.0.0.tar" ] \
    || fail "materializer: optional image not written with --include-optional"
grep -q "copied=1 skipped=2" "${TMP}/mat-opt.out" || fail "materializer: optional include summary"
pass "materializer includes optional images on request"

PATH="${TMP}/bin:${PATH}" "${ONLINE}/materialize-base-images.sh" \
    --baseline "${TMP}/baseline/versions/base.yaml" --index "${TMP}/index.json" \
    --offline-root "${TMP}/offline" >"${TMP}/mat2.out"
grep -q "skipped=2" "${TMP}/mat2.out" || fail "materializer: idempotent skip failed"
pass "materializer is idempotent"

# ---- optional filter runs before catalog resolution ----
# An unselected optional image with a tag missing from the pinned index must
# not block base materialization; selecting it must still fail on the tag.
cp "${TMP}/baseline/versions/base.yaml" "${TMP}/metax-baseline.yaml"
cat >> "${TMP}/metax-baseline.yaml" <<'EOF'
  - key: "metax-gpu-operator:cr.metax-tech.com/cloud/gpu-label"
    catalog_id: "metax/metax-gpu-label"
    version: "0.15.4-amd64"
    dest: "offline-files/metax-gpu"
    tar: "harbor.isuanova.com_metax_gpu-label_0.15.4-amd64.tar"
    optional: true
EOF
jq '.images += [{
  "id": "metax/metax-gpu-label",
  "name": "metax-gpu-label",
  "source": "harbor.isuanova.com/metax/gpu-label",
  "target": "harbor.isuanova.com/mirrors/cr.metax-tech.com/cloud/gpu-label",
  "versions": [{"tag": "0.15.3-amd64",
                "digest": "sha256:6666666666666666666666666666666666666666666666666666666666666666",
                "platforms": ["linux/amd64"]}]
}]' "${TMP}/index.json" > "${TMP}/metax-index.json"

PATH="${TMP}/bin:${PATH}" "${ONLINE}/materialize-base-images.sh" \
    --baseline "${TMP}/metax-baseline.yaml" --index "${TMP}/metax-index.json" \
    --offline-root "${TMP}/offline-metax" >"${TMP}/mat-metax.out"
[ ! -e "${TMP}/offline-metax/metax-gpu" ] \
    || fail "materializer: unselected optional image was materialized"
grep -q "optional-skipped=2" "${TMP}/mat-metax.out" \
    || fail "materializer: unselected MetaX optional not counted"
pass "materializer filters unselected optional images before resolution"

if python3 "${ONLINE}/lib-base-catalog.py" \
    --baseline "${TMP}/metax-baseline.yaml" --index "${TMP}/metax-index.json" \
    >/dev/null 2>"${TMP}/err"; then
    fail "resolver: full-catalog validation missed a missing optional tag"
fi
grep -q "not in catalog" "${TMP}/err" \
    || fail "resolver: missing optional tag error not reported"
pass "resolver keeps full-catalog validation for maintainers"

if PATH="${TMP}/bin:${PATH}" "${ONLINE}/materialize-base-images.sh" \
    --baseline "${TMP}/metax-baseline.yaml" --index "${TMP}/metax-index.json" \
    --offline-root "${TMP}/offline-metax" --include-group metax-gpu-operator \
    >"${TMP}/mat-metax-group.out" 2>&1; then
    fail "materializer: selected optional image with missing tag should fail"
fi
pass "materializer validates selected optional images"

# ---- OS pre-check ----
"${ONLINE}/check-os-packages.sh" --baseline "${TMP}/baseline/versions/base.yaml" >"${TMP}/pre.out"
grep -q "pre-check passed" "${TMP}/pre.out" || fail "pre-check: local pass missing"
pass "pre-check passes when packages exist"

# Release trees place base.yaml at <tree>/base/base.yaml and do not carry
# versions/; the lock must resolve from the installer checkout.
mkdir -p "${TMP}/release/base"
sed 's|versions/os/test.lock|versions/os/ubuntu-22.04.lock|' \
    "${TMP}/baseline/versions/base.yaml" > "${TMP}/release/base/base.yaml"
"${ONLINE}/check-os-packages.sh" --baseline "${TMP}/release/base/base.yaml" --dry-run \
    >"${TMP}/pre-release.out" \
    || fail "pre-check: release layout could not resolve packages_check"
pass "pre-check resolves packages_check from the installer checkout"

cat > "${TMP}/baseline/versions/os/test.lock" <<'EOF'
schema: 1
family: debian
id: ubuntu
version: "22.04"
packages:
  reconcile:
    definitely-not-a-real-package: "1"
EOF
if "${ONLINE}/check-os-packages.sh" --baseline "${TMP}/baseline/versions/base.yaml" >"${TMP}/pre.out" 2>&1; then
    fail "pre-check: missing package should fail"
fi
grep -q "MISSING definitely-not-a-real-package" "${TMP}/pre.out" || fail "pre-check: missing package not reported"
pass "pre-check reports a missing package"

if ! "${ONLINE}/check-os-packages.sh" --baseline "${TMP}/baseline/versions/base.yaml" \
    --warn-only >"${TMP}/pre.out" 2>&1; then
    fail "pre-check: warn-only should exit 0"
fi
grep -q "WARNING: node prerequisite packages are missing" "${TMP}/pre.out" || fail "pre-check: warn-only warning missing"
pass "pre-check warn-only reports but does not fail"

cat > "${TMP}/baseline/versions/os/test.lock" <<'EOF'
schema: 1
family: debian
id: ubuntu
version: "22.04"
packages:
  reconcile:
    bash: "definitely-wrong"
EOF
if "${ONLINE}/check-os-packages.sh" --baseline "${TMP}/baseline/versions/base.yaml" --strict >"${TMP}/pre.out" 2>&1; then
    fail "pre-check: strict version mismatch should fail"
fi
grep -q "VERSION bash" "${TMP}/pre.out" || fail "pre-check: version mismatch not reported"
pass "pre-check reports a strict version mismatch"

cat > "${TMP}/baseline/versions/os/test.lock" <<'EOF'
schema: 1
family: debian
id: ubuntu
version: "22.04"
packages:
  reconcile:
    bash: "1"
EOF
cat > "${TMP}/bin/ssh" <<'EOF'
#!/bin/bash
exec bash -s
EOF
chmod +x "${TMP}/bin/ssh"
PATH="${TMP}/bin:${PATH}" "${ONLINE}/check-os-packages.sh" \
    --baseline "${TMP}/baseline/versions/base.yaml" --hosts root@10.0.0.1 >"${TMP}/pre.out"
grep -q "pre-check passed" "${TMP}/pre.out" || fail "pre-check: remote pass missing"
pass "pre-check runs the embedded script over ssh"

# A remote script exiting non-zero (missing packages) is not an SSH failure:
# the password fallback must not rerun the check and print the list twice.
cat > "${TMP}/baseline/versions/os/test.lock" <<'EOF'
schema: 1
family: debian
id: ubuntu
version: "22.04"
packages:
  reconcile:
    definitely-not-a-real-package: "1"
EOF
cat > "${TMP}/bin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SSH_TEST_LOG:?}"
exec bash -s
EOF
cat > "${TMP}/bin/sshpass" <<'EOF'
#!/bin/bash
printf 'SSHPASS\n' >> "${SSH_TEST_LOG:?}"
shift  # drop -e, then run the wrapped ssh command
exec "$@"
EOF
chmod +x "${TMP}/bin/ssh" "${TMP}/bin/sshpass"
: > "${TMP}/ssh.log"
rc=0
out="$(SSH_TEST_LOG="${TMP}/ssh.log" PATH="${TMP}/bin:${PATH}" "${ONLINE}/check-os-packages.sh" \
    --baseline "${TMP}/baseline/versions/base.yaml" --hosts root@10.0.0.1 --password secret 2>&1)" || rc=$?
[ "${rc}" -ne 0 ] || fail "pre-check: missing package over ssh should fail"
[ "$(grep -c 'MISSING definitely-not-a-real-package' <<<"${out}")" = "1" ] \
    || fail "pre-check: missing-package output was duplicated"
if grep -q SSHPASS "${TMP}/ssh.log"; then
    fail "pre-check: password fallback retried after a remote non-zero exit"
fi
pass "pre-check does not retry with password on a remote non-zero exit"

# ssh exiting 255 means ssh itself failed; the password fallback still applies.
cat > "${TMP}/baseline/versions/os/test.lock" <<'EOF'
schema: 1
family: debian
id: ubuntu
version: "22.04"
packages:
  reconcile:
    bash: "1"
EOF
cat > "${TMP}/bin/ssh" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    if [ "${arg}" = "BatchMode=yes" ]; then
        exit 255  # simulate key auth / connection failure
    fi
done
exec bash -s
EOF
chmod +x "${TMP}/bin/ssh"
: > "${TMP}/ssh.log"
rc=0
out="$(SSH_TEST_LOG="${TMP}/ssh.log" PATH="${TMP}/bin:${PATH}" "${ONLINE}/check-os-packages.sh" \
    --baseline "${TMP}/baseline/versions/base.yaml" --hosts root@10.0.0.1 --password secret 2>&1)" || rc=$?
[ "${rc}" -eq 0 ] || fail "pre-check: password fallback did not recover from an ssh failure"
grep -q SSHPASS "${TMP}/ssh.log" || fail "pre-check: password fallback was not attempted"
grep -q "pre-check passed" <<<"${out}" || fail "pre-check: remote pass missing after password fallback"
pass "pre-check falls back to password only when ssh itself fails"

echo "all online tool tests passed"
