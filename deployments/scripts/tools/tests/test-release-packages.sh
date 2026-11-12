#!/usr/bin/env bash
# Local release package selection: required/optional filtering + sha checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${ROOT}/deployments/scripts/tools/offline/release-packages.py"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
chk() { [ "$2" = "$3" ] || fail "$1: expected [$3] got [$2]"; echo "ok - $1"; }

mkdir -p "${TMP}/artifacts/payloads/sha256"
for name in platform base-runtime models dev-lab vendor; do
  printf '%s' "${name}" > "${TMP}/artifacts/payloads/sha256/${name}.tar.zst"
done
python3 - "${TMP}" <<'PY'
import hashlib
import sys
from pathlib import Path
import yaml
root = Path(sys.argv[1])
packages = [
    ("platform", True),
    ("base-runtime", True),
    ("models", False),
    ("dev-lab", False),
    ("vendor", False),
]
items = []
for name, required in packages:
    p = root / "artifacts/payloads/sha256" / f"{name}.tar.zst"
    items.append({
        "name": name,
        "path": f"artifacts/payloads/sha256/{name}.tar.zst",
        "sha256": "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest(),
        "size": p.stat().st_size,
        "required": required,
    })
(root / "release.yaml").write_text(yaml.safe_dump({"packages": items}))
header = "path\tartifact\textract\tmode\tsize\tsha256\tgroup\tpackage\n"
rows = "".join(
    f"{name}.txt\tartifacts/x/{name}\tfalse\t0644\t0\tsha256:{'a'*64}\t\t{name}\n"
    for name, _ in packages
)
(root / "tree.tsv").write_text(header + rows)
PY

python3 "${TOOL}" --root "${TMP}" --write-tree "${TMP}/required.tsv" >/dev/null
chk "required only" "$(wc -l < "${TMP}/required.tsv")" "3"

python3 "${TOOL}" --root "${TMP}" --with models --write-tree "${TMP}/models.tsv" >/dev/null
chk "required + models" "$(wc -l < "${TMP}/models.tsv")" "4"

python3 "${TOOL}" --root "${TMP}" --with all --write-tree "${TMP}/all.tsv" >/dev/null
chk "all packages" "$(wc -l < "${TMP}/all.tsv")" "6"

rm "${TMP}/artifacts/payloads/sha256/models.tar.zst"
if python3 "${TOOL}" --root "${TMP}" --with models >/dev/null 2>&1; then
  fail "missing optional payload should fail when selected"
fi
echo "ok - missing selected payload fails"

printf '%s' changed > "${TMP}/artifacts/payloads/sha256/models.tar.zst"
if python3 "${TOOL}" --root "${TMP}" --with models >/dev/null 2>&1; then
  fail "digest mismatch should fail"
fi
echo "ok - digest mismatch fails"

printf '{}\n' > "${TMP}/release.yaml"
out="$(python3 "${TOOL}" --root "${TMP}")"
chk "legacy tree" "${out}" "legacy: release.yaml has no packages[]; use the full tree"
