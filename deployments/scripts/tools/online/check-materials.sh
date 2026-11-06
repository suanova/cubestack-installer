#!/bin/bash
set -euo pipefail

# Check vendor materials declared in versions/base.yaml.
#
# The baseline is an index: it records what the installer needs and where it
# comes from, not the bytes. Open-source installs fetch vendor artifacts with
# the user's own vendor account; commercial packaging overlays a local source.
#
# Usage:
#   ./check-materials.sh [--baseline PATH] [--offline-root PATH]
#                        [--warn-only] [--dry-run]
#
# Exit: 0 = all present (or --warn-only), 1 = missing material(s).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
BASELINE="${REPO_ROOT}/versions/base.yaml"
OFFLINE_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
WARN_ONLY=0
DRY_RUN=0

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) BASELINE="${2:?--baseline needs a path}"; shift 2 ;;
        --offline-root) OFFLINE_ROOT="${2:?--offline-root needs a path}"; shift 2 ;;
        --warn-only) WARN_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -f "${BASELINE}" ] || die "baseline not found: ${BASELINE}"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

python3 - "${BASELINE}" "${OFFLINE_ROOT}" "${WARN_ONLY}" "${DRY_RUN}" <<'PY'
import hashlib
import os
import re
import sys
from pathlib import Path

import yaml

baseline_path = Path(sys.argv[1])
offline_root = Path(sys.argv[2])
warn_only = sys.argv[3] == "1"
dry_run = sys.argv[4] == "1"
VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")

data = yaml.safe_load(baseline_path.read_text(encoding="utf-8"))
env = {str(k): str(v) for k, v in (data.get("env") or {}).items()}
env.update({k: v for k, v in os.environ.items() if k not in env})


def expand(value: str, where: str) -> str:
    def repl(match):
        name = match.group(1)
        if name not in env:
            sys.exit(f"ERROR: {where}: undefined variable ${{{name}}}")
        return env[name]

    return VAR_RE.sub(repl, value)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


materials = data.get("materials") or []
if not materials:
    print("materials: none declared")
    sys.exit(0)

missing = []
planned = 0
for idx, item in enumerate(materials):
    where = f"materials[{idx}]"
    key = str(item.get("key", "")).strip()
    file_name = expand(str(item.get("file", "")).strip(), where)
    dest = expand(str(item.get("dest", "")).strip(), where)
    rel_dest = dest[len("offline-files/"):] if dest.startswith("offline-files/") else dest
    path = offline_root / rel_dest / file_name
    source = item.get("source") or {}
    provider = str(source.get("provider", "")).strip() or source.get("type", "vendor")
    portal = str(source.get("portal", "")).strip()
    if dry_run:
        planned += 1
        print(f"  [plan] {key}: {path}")
        continue
    if not path.is_file():
        missing.append((key, path, provider, bool(source.get("account_required"))))
        print(f"  [missing] {key}: {path}")
        continue
    expected = str(item.get("digest", "")).strip()
    if expected and sha256(path) != expected:
        missing.append((key, path, provider, bool(source.get("account_required"))))
        print(f"  [bad digest] {key}: {path}")
        continue
    print(f"  [ok] {key}: {path}")

if dry_run:
    print(f"materials: {planned} planned")
    sys.exit(0)

if not missing:
    print(f"materials: {len(materials)} present")
    sys.exit(0)

print(f"materials: {len(missing)} missing", file=sys.stderr)
for key, path, provider, account_required in missing:
    hint = f"put {path.name} under {path.parent}"
    if account_required:
        where = f" at {portal}" if portal else ""
        hint += f" (download it from the {provider} vendor portal{where} with your own account)"
    print(f"  - {key}: {hint}", file=sys.stderr)
sys.exit(0 if warn_only else 1)
PY
