#!/bin/bash
set -euo pipefail

# Regression tests for the netshoot digest pin updater.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${ROOT}/deployments/scripts/tools/online/update-netshoot-pin.py"
TMP="$(mktemp -d -t cubestack-netshoot-pin-test.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

mkdir -p "${TMP}/versions"
cat > "${TMP}/versions/base.yaml" <<'YAML'
schema: 1
# keep this comment
env:
  KUBESPRAY_VERSION: v2.32.0
images:
- key: k8s:pause
  catalog_id: kubernetes/pause
  version: 3.10.1
  dest: offline-files/k8s
  tar: pause.tar
os: []
YAML

D1="sha256:1111111111111111111111111111111111111111111111111111111111111111"
D2="sha256:2222222222222222222222222222222222222222222222222222222222222222"

out="$(python3 "${TOOL}" --root "${TMP}" \
    --image harbor.isuanova.com/suanova/netshoot-rdma \
    --tag 2.1-latest --digest "${D1}")"
[ "${out}" = "changed" ] || fail "first update should change"
grep -q 'key: netshoot:netshoot-rdma' "${TMP}/versions/base.yaml" || fail "entry not inserted"
grep -q 'version: 2.1-latest' "${TMP}/versions/base.yaml" || fail "tag not written"
grep -q "digest: ${D1}" "${TMP}/versions/base.yaml" || fail "digest not written"
grep -q 'NETSHOOT_RDMA_VERSION: 2.1-latest' "${TMP}/versions/base.yaml" || fail "env tag not written"
grep -q 'keep this comment' "${TMP}/versions/base.yaml" || fail "comment was lost"
pass "inserts the pin and env without rewriting comments"

out="$(python3 "${TOOL}" --root "${TMP}" \
    --image harbor.isuanova.com/suanova/netshoot-rdma \
    --tag 2.1-latest --digest "${D1}")"
[ "${out}" = "unchanged" ] || fail "same digest should be unchanged"
[ "$(grep -c 'key: netshoot:netshoot-rdma' "${TMP}/versions/base.yaml")" = "1" ] \
    || fail "entry duplicated"
pass "same digest is idempotent"

python3 "${TOOL}" --root "${TMP}" \
    --image harbor.isuanova.com/suanova/netshoot-rdma \
    --tag 26.04.17-r2 --digest "${D2}" >/dev/null
grep -q 'version: 26.04.17-r2' "${TMP}/versions/base.yaml" || fail "tag not updated"
grep -q "digest: ${D2}" "${TMP}/versions/base.yaml" || fail "digest not updated"
grep -q 'NETSHOOT_RDMA_VERSION: 26.04.17-r2' "${TMP}/versions/base.yaml" || fail "env tag not updated"
pass "updates tag, digest and env in place"

if python3 "${TOOL}" --root "${TMP}" \
    --image harbor.isuanova.com/suanova/netshoot-rdma \
    --tag 2.1-latest --digest "sha256:bad" >/dev/null 2>&1; then
    fail "invalid digest should fail"
fi
pass "rejects an invalid digest"

echo "all netshoot pin tests passed"
