#!/bin/bash
set -euo pipefail

# Regression tests for the mirror-updated base pin receiver.
# Uses local old/new index fixtures; no network.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${ROOT}/deployments/scripts/tools/online/update-mirror-pin.py"
TMP="$(mktemp -d -t cubestack-mirror-pin-test.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

mkdir -p "${TMP}/versions"
cat > "${TMP}/versions/base.yaml" <<'EOF'
schema: 1
mirror:
  repo: suanova/container-image-mirror
  commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  path: index.json
kubespray:
  version: v2.32.0
images:
  - key: k8s:pause
    catalog_id: kubernetes/pause
    version: 3.10.1
    dest: offline-files/k8s
    tar: pause.tar
  - key: k8s:other
    catalog_id: kubernetes/other
    version: v1
    dest: offline-files/k8s
    tar: other.tar
EOF

cat > "${TMP}/old.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.isuanova.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.isuanova.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}
]}
EOF

cp "${TMP}/old.json" "${TMP}/same.json"
cat > "${TMP}/changed.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.isuanova.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.isuanova.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --index "${TMP}/same.json" --old-index "${TMP}/old.json")"
grep -q "unchanged" <<<"${out}" || fail "same index should be unchanged"
grep -q "commit: aaaaa" "${TMP}/versions/base.yaml" || fail "unchanged should not rewrite pin"
pass "no referenced base change -> no update"

cat > "${TMP}/added.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.isuanova.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.isuanova.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"},
                {"tag": "v2", "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444"}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit 1212121212121212121212121212121212121212 \
    --index "${TMP}/added.json" --old-index "${TMP}/old.json")"
grep -q "unchanged" <<<"${out}" || fail "unreferenced tag addition should be unchanged"
grep -q "commit: aaaaa" "${TMP}/versions/base.yaml" || fail "unreferenced tag addition rewrote the pin"
pass "unreferenced tag addition does not move the pin"

python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --index "${TMP}/changed.json" --old-index "${TMP}/old.json" >/dev/null
grep -q "commit: bbbbb" "${TMP}/versions/base.yaml" || fail "changed index should bump pin"
grep -q "kubernetes/pause" <<<"$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit cccccccccccccccccccccccccccccccccccccccc \
    --index "${TMP}/changed.json" --old-index "${TMP}/changed.json")" && fail "same commit should short-circuit"
pass "referenced base change bumps the mirror pin"

cp "${TMP}/versions/base.yaml" "${TMP}/before.yaml"
python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit dddddddddddddddddddddddddddddddddddddddd \
    --index "${TMP}/changed.json" --old-index "${TMP}/changed.json" --dry-run >/dev/null
cmp -s "${TMP}/before.yaml" "${TMP}/versions/base.yaml" || fail "dry-run wrote the baseline"
pass "dry-run leaves the baseline untouched"

cat > "${TMP}/missing.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.isuanova.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}
]}
EOF
if python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
    --index "${TMP}/missing.json" --old-index "${TMP}/old.json" >/dev/null 2>"${TMP}/err"; then
    fail "missing referenced id should fail"
fi
grep -q "catalog id missing" "${TMP}/err" || fail "missing id error not reported"
pass "missing referenced catalog id fails"

echo "all mirror pin tests passed"
