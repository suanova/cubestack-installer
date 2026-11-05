#!/bin/bash
set -euo pipefail

# Regression tests for the vendor materials index and preflight.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CHECK="${ROOT}/deployments/scripts/tools/online/check-materials.sh"
TMP="$(mktemp -d -t cubestack-materials-test.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

cat > "${TMP}/base.yaml" <<'YAML'
schema: 1
env:
  METAX_VERSION: "0.15.3"
materials:
  - key: metax:k8s-images
    module: gpu_operator
    version: ${METAX_VERSION}
    file: metax-k8s-images.${METAX_VERSION}.run
    dest: offline-files/metax-gpu
    optional: true
    source:
      type: vendor-portal
      provider: metax
      account_required: true
YAML

if "${CHECK}" --baseline "${TMP}/base.yaml" --offline-root "${TMP}/offline" >/dev/null 2>&1; then
    fail "missing material should fail"
fi
pass "missing material fails by default"

if ! "${CHECK}" --baseline "${TMP}/base.yaml" --offline-root "${TMP}/offline" \
    --warn-only >/dev/null 2>&1; then
    fail "warn-only should exit 0"
fi
pass "warn-only reports missing material without failing"

mkdir -p "${TMP}/offline/metax-gpu"
printf 'vendor bytes\n' > "${TMP}/offline/metax-gpu/metax-k8s-images.0.15.3.run"
"${CHECK}" --baseline "${TMP}/base.yaml" --offline-root "${TMP}/offline" >/dev/null \
    || fail "present material should pass"
pass "present material passes"

digest="$(sha256sum "${TMP}/offline/metax-gpu/metax-k8s-images.0.15.3.run" | awk '{print $1}')"
python3 - "$TMP/base.yaml" "$digest" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
p.write_text(p.read_text().replace(
    "    optional: true\n",
    f"    digest: sha256:{sys.argv[2]}\n    optional: true\n",
))
PY
"${CHECK}" --baseline "${TMP}/base.yaml" --offline-root "${TMP}/offline" >/dev/null \
    || fail "matching digest should pass"
pass "matching digest passes"

printf 'tampered\n' > "${TMP}/offline/metax-gpu/metax-k8s-images.0.15.3.run"
if "${CHECK}" --baseline "${TMP}/base.yaml" --offline-root "${TMP}/offline" >/dev/null 2>&1; then
    fail "digest mismatch should fail"
fi
pass "digest mismatch fails"

echo "all materials tests passed"
