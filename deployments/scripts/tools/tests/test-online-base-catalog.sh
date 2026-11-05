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
    dest: "offline-files/netshoot"
    tar: "netshoot-rdma-26.04.17.tar"
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
      "scope": "base",
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
[ "$(jq -r '.images | length' <<<"${PLAN}")" = "2" ] || fail "resolver: expected 2 images"
[ "$(jq -r '.images[0].path' <<<"${PLAN}")" = "offline-files/kubespray/v2.32.0/images/registry.k8s.io_kube-apiserver_v1.35.8.tar" ] || fail "resolver: bad path"
[ "$(jq -r '.images[0].ref' <<<"${PLAN}")" = "harbor.isuanova.com/mirrors/registry.k8s.io/kube-apiserver@sha256:6a7b73e718540d2c097cbcdc84c0f2cffad7a51ebccaf7f0b8cceb464715e1d9" ] || fail "resolver: bad ref"
[ "$(jq -r '.images[0].repo_tag' <<<"${PLAN}")" = "registry.k8s.io/kube-apiserver:v1.35.8" ] || fail "resolver: bad repo_tag"
[ "$(jq -r '.images[1].ref' <<<"${PLAN}")" = "harbor.isuanova.com/suanova/netshoot-rdma:26.04.17" ] || fail "resolver: bad source_ref"
pass "resolver maps catalog and source_ref entries"

sed 's/v1.35.8/v9.9.9/' "${TMP}/baseline/versions/base.yaml" > "${TMP}/bad-tag.yaml"
if python3 "${ONLINE}/lib-base-catalog.py" --baseline "${TMP}/bad-tag.yaml" --index "${TMP}/index.json" >/dev/null 2>"${TMP}/err"; then
    fail "resolver: missing tag should fail"
fi
grep -q "not in catalog" "${TMP}/err" || fail "resolver: missing-tag error not reported"
pass "resolver rejects an unknown tag"

sed 's/"scope": "base"/"scope": "platform"/' "${TMP}/index.json" > "${TMP}/bad-scope.json"
if python3 "${ONLINE}/lib-base-catalog.py" --baseline "${TMP}/baseline/versions/base.yaml" --index "${TMP}/bad-scope.json" >/dev/null 2>"${TMP}/err"; then
    fail "resolver: non-base scope should fail"
fi
grep -q "scope must be 'base'" "${TMP}/err" || fail "resolver: scope error not reported"
pass "resolver rejects a non-base catalog entry"

sed 's/v1.35.8/${NOPE}/' "${TMP}/baseline/versions/base.yaml" > "${TMP}/bad-var.yaml"
if python3 "${ONLINE}/lib-base-catalog.py" --baseline "${TMP}/bad-var.yaml" --index "${TMP}/index.json" >/dev/null 2>"${TMP}/err"; then
    fail "resolver: unknown variable should fail"
fi
grep -q "undefined variable" "${TMP}/err" || fail "resolver: undefined-variable error not reported"
pass "resolver rejects an undefined variable"

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
[ -s "${TMP}/offline/netshoot/netshoot-rdma-26.04.17.tar" ] || fail "materializer: missing source_ref tar"
grep -q "copied=2" "${TMP}/mat.out" || fail "materializer: unexpected summary"
pass "materializer writes both tar kinds"

PATH="${TMP}/bin:${PATH}" "${ONLINE}/materialize-base-images.sh" \
    --baseline "${TMP}/baseline/versions/base.yaml" --index "${TMP}/index.json" \
    --offline-root "${TMP}/offline" >"${TMP}/mat2.out"
grep -q "skipped=2" "${TMP}/mat2.out" || fail "materializer: idempotent skip failed"
pass "materializer is idempotent"

# ---- OS pre-check ----
"${ONLINE}/check-os-packages.sh" --baseline "${TMP}/baseline/versions/base.yaml" >"${TMP}/pre.out"
grep -q "pre-check passed" "${TMP}/pre.out" || fail "pre-check: local pass missing"
pass "pre-check passes when packages exist"

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

echo "all online tool tests passed"
