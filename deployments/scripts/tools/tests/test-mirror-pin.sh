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
   "target": "harbor.example.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}
]}
EOF

cp "${TMP}/old.json" "${TMP}/same.json"
cat > "${TMP}/changed.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.example.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --index "${TMP}/same.json" --old-index "${TMP}/old.json")"
grep -q "unchanged" <<<"${out}" || fail "same index should be unchanged"
grep -q "commit: aaaaa" "${TMP}/versions/base.yaml" || fail "unchanged should not rewrite pin"
pass "no referenced base change -> no update"

cat > "${TMP}/unreferenced-id.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.example.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"}]},
  {"id": "kubernetes/unused", "source": "registry.k8s.io/unused",
   "target": "harbor.example.com/mirrors/registry.k8s.io/unused",
   "versions": [{"tag": "v1", "digest": "sha256:5555555555555555555555555555555555555555555555555555555555555555",
                 "platforms": ["linux/amd64"]}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit 1313131313131313131313131313131313131313 \
    --index "${TMP}/unreferenced-id.json" --old-index "${TMP}/old.json")"
grep -q "unchanged" <<<"${out}" || fail "unreferenced catalog id should be unchanged"
grep -q "commit: aaaaa" "${TMP}/versions/base.yaml" || fail "unreferenced catalog id rewrote the pin"
pass "new tag on an unreferenced catalog id does not move the pin"

cat > "${TMP}/nodigest.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.example.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"},
                {"tag": "v2"}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit 1414141414141414141414141414141414141414 \
    --index "${TMP}/nodigest.json" --old-index "${TMP}/old.json")"
grep -q "unchanged" <<<"${out}" || fail "new tag without a digest should be unchanged"
grep -q "commit: aaaaa" "${TMP}/versions/base.yaml" || fail "new tag without a digest rewrote the pin"
pass "new tag without a digest does not move the pin"

cat > "${TMP}/arm64.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.example.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"},
                {"tag": "v2", "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
                 "platforms": ["linux/arm64"]}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit 1515151515151515151515151515151515151515 \
    --index "${TMP}/arm64.json" --old-index "${TMP}/old.json")"
grep -q "unchanged" <<<"${out}" || fail "new tag without amd64 should be unchanged"
grep -q "commit: aaaaa" "${TMP}/versions/base.yaml" || fail "new tag without amd64 rewrote the pin"
pass "new tag without linux/amd64 does not move the pin"

cat > "${TMP}/platforms-empty.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.example.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"},
                {"tag": "v2", "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444"}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit 1616161616161616161616161616161616161616 \
    --index "${TMP}/platforms-empty.json" --old-index "${TMP}/old.json")"
grep -q "newly usable tag" <<<"${out}" || fail "new tag without a platforms list should be reported"
grep -q "commit: 1616" "${TMP}/versions/base.yaml" || fail "new tag without a platforms list did not bump the pin"
pass "new tag without a platforms list moves the pin"

cat > "${TMP}/multiarch.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.example.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"},
                {"tag": "v2", "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
                 "platforms": ["linux/arm64", "linux/amd64"]}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit 1717171717171717171717171717171717171717 \
    --index "${TMP}/multiarch.json" --old-index "${TMP}/old.json")"
grep -q "newly usable tag" <<<"${out}" || fail "multi-platform tag with amd64 should be reported"
grep -q "commit: 1717" "${TMP}/versions/base.yaml" || fail "multi-platform tag with amd64 did not bump the pin"
pass "multi-platform tag including linux/amd64 moves the pin"

cat > "${TMP}/added.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.example.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"},
                {"tag": "v2", "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
                 "platforms": ["linux/amd64"]}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit 1212121212121212121212121212121212121212 \
    --index "${TMP}/added.json" --old-index "${TMP}/old.json")"
grep -q "newly usable tag" <<<"${out}" || fail "new usable tag should be reported"
grep -q "commit: 1212" "${TMP}/versions/base.yaml" || fail "new usable tag did not bump the pin"
pass "new usable tag on a referenced catalog id moves the pin"

cat > "${TMP}/old-nodigest.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.example.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"},
                {"tag": "v2"}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit 1818181818181818181818181818181818181818 \
    --index "${TMP}/added.json" --old-index "${TMP}/old-nodigest.json")"
grep -q "newly usable tag" <<<"${out}" || fail "tag gaining a digest should be reported"
grep -q "commit: 1818" "${TMP}/versions/base.yaml" || fail "tag gaining a digest did not bump the pin"
pass "tag becomes usable when its digest appears"

cat > "${TMP}/old-arm64.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.example.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"},
                {"tag": "v2", "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
                 "platforms": ["linux/arm64"]}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit 1919191919191919191919191919191919191919 \
    --index "${TMP}/multiarch.json" --old-index "${TMP}/old-arm64.json")"
grep -q "newly usable tag" <<<"${out}" || fail "tag gaining amd64 should be reported"
grep -q "commit: 1919" "${TMP}/versions/base.yaml" || fail "tag gaining amd64 did not bump the pin"
pass "tag becomes usable when linux/amd64 appears"

cat > "${TMP}/old-usable.json" <<'EOF'
{"schema": 1, "images": [
  {"id": "kubernetes/pause", "source": "registry.k8s.io/pause",
   "target": "harbor.example.com/mirrors/registry.k8s.io/pause",
   "versions": [{"tag": "3.10.1", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
  {"id": "kubernetes/other", "source": "registry.k8s.io/other",
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
   "versions": [{"tag": "v1", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"},
                {"tag": "v2", "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
                 "platforms": ["linux/amd64"]}]}
]}
EOF

out="$(python3 "${TOOL}" --root "${TMP}" --repo suanova/container-image-mirror \
    --commit 2020202020202020202020202020202020202020 \
    --index "${TMP}/added.json" --old-index "${TMP}/old-usable.json")"
grep -q "unchanged" <<<"${out}" || fail "already usable tag should be unchanged"
grep -q "commit: 1919" "${TMP}/versions/base.yaml" || fail "already usable tag rewrote the pin"
pass "already usable tag with the same digest stays put"

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
   "target": "harbor.example.com/mirrors/registry.k8s.io/other",
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
