#!/bin/bash
set -euo pipefail

# Materialize the base image set from the public mirror catalog.
#
# Usage:
#   ./materialize-base-images.sh --index /path/to/index.json [options]
#
# The script reads versions/base.yaml, resolves every image through the mirror
# catalog, and copies it into a docker-archive tar under offline-files/. It does
# not touch OS packages: those are a pre-install check.
#
# Optional images that are not selected by --include-optional/--include-group
# are filtered out before catalog resolution, so a missing tag on an unselected
# optional image does not block base materialization.
#
# Options:
#   --baseline PATH       versions/base.yaml (default: <repo>/versions/base.yaml)
#   --index PATH          container-image-mirror index.json (required)
#   --offline-root PATH   offline-files root (default: <repo>/deployments/offline-files)
#   --force               rebuild tars that already exist
#   --include-optional    also materialize images marked optional: true
#   --include-group NAME  materialize optional images from key group <NAME>
#                         (repeatable; e.g. metax-gpu-operator)
#   --dry-run             print the skopeo commands without running them
#   --continue-on-error   keep going when one image fails; exit non-zero at the end

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
BASELINE="${REPO_ROOT}/versions/base.yaml"
INDEX=""
OFFLINE_ROOT="${REPO_ROOT}/deployments/offline-files"
FORCE=0
DRY_RUN=0
INCLUDE_OPTIONAL=0
INCLUDE_GROUPS=()
CONTINUE_ON_ERROR=0

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) BASELINE="${2:?--baseline needs a path}"; shift 2 ;;
        --index) INDEX="${2:?--index needs a path}"; shift 2 ;;
        --offline-root) OFFLINE_ROOT="${2:?--offline-root needs a path}"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --include-optional) INCLUDE_OPTIONAL=1; shift ;;
        --include-group) INCLUDE_GROUPS+=("${2:?--include-group needs a value}"); shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --continue-on-error) CONTINUE_ON_ERROR=1; shift ;;
        --help|-h) sed -n '2,26p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -n "${INDEX}" ] || die "--index is required"
for cmd in python3 jq skopeo; do
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is required"
done

PLAN="$(mktemp -t cubestack-base-plan.XXXXXX.json)"
FILTERED="$(mktemp -t cubestack-base-filtered.XXXXXX.yaml)"
trap 'rm -f "${PLAN}" "${FILTERED}"' EXIT

# Apply the optional/group selection **before** catalog resolution: an
# unselected optional image must not fail the run just because its tag is not
# in the pinned index yet. Full-catalog validation remains available by calling
# lib-base-catalog.py directly (the resolver itself is unchanged).
SKIPPED_OPTIONAL="$(
python3 - "${BASELINE}" "${FILTERED}" "${INCLUDE_OPTIONAL}" \
    ${INCLUDE_GROUPS[@]+"${INCLUDE_GROUPS[@]}"} <<'PY'
import sys
from pathlib import Path
import yaml

baseline_path, out_path = Path(sys.argv[1]), Path(sys.argv[2])
include_optional = sys.argv[3] == "1"
groups = set(sys.argv[4:])
data = yaml.safe_load(baseline_path.read_text(encoding="utf-8"))
if not isinstance(data, dict):
    sys.exit(f"{baseline_path}: expected a YAML mapping")
images = data.get("images") or []
selected = []
skipped = 0
for image in images:
    optional = bool(image.get("optional", False))
    key = str(image.get("key", ""))
    group = key.split(":", 1)[0]
    if optional and not include_optional and group not in groups:
        skipped += 1
        continue
    selected.append(image)
data["images"] = selected
out_path.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
print(skipped)
PY
)"
case "${SKIPPED_OPTIONAL}" in
    ''|*[!0-9]*) die "failed to filter optional images from ${BASELINE}" ;;
esac

python3 "${SCRIPT_DIR}/lib-base-catalog.py" \
    --baseline "${FILTERED}" --index "${INDEX}" >"${PLAN}"

mkdir -p "${OFFLINE_ROOT}"
say "baseline: ${BASELINE}"
say "catalog:  ${INDEX}"
say "root:     ${OFFLINE_ROOT}"

failed=0
total=0
copied=0
skipped=0
skipped_optional="${SKIPPED_OPTIONAL}"

while IFS= read -r item; do
    [ -n "${item}" ] || continue
    key="$(jq -r '.key' <<<"${item}")"
    total=$((total + 1))
    path="$(jq -r '.path' <<<"${item}")"
    ref="$(jq -r '.ref' <<<"${item}")"
    repo_tag="$(jq -r '.repo_tag' <<<"${item}")"

    case "${path}" in
        offline-files/*) target="${OFFLINE_ROOT}/${path#offline-files/}" ;;
        *)                target="${REPO_ROOT}/${path}" ;;
    esac

    if [ -s "${target}" ] && [ "${FORCE}" != "1" ]; then
        echo "  [skip] ${key} -> ${target}"
        skipped=$((skipped + 1))
        continue
    fi

    echo "  [copy] ${key}"
    echo "         ${ref} -> ${target} (${repo_tag})"
    if [ "${DRY_RUN}" = "1" ]; then
        continue
    fi

    mkdir -p "$(dirname "${target}")"
    part="${target}.part"
    rm -f "${part}"
    if skopeo copy --quiet \
        --override-os linux --override-arch amd64 \
        "docker://${ref}" "docker-archive:${part}:${repo_tag}"; then
        mv "${part}" "${target}"
        copied=$((copied + 1))
    else
        rm -f "${part}"
        echo "ERROR: failed to materialize ${key} (${ref})" >&2
        failed=$((failed + 1))
        if [ "${CONTINUE_ON_ERROR}" != "1" ]; then
            exit 1
        fi
    fi
done < <(jq -c '.images[]' "${PLAN}")

say "done: total=${total} copied=${copied} skipped=${skipped} optional-skipped=${skipped_optional} failed=${failed}"
[ "${failed}" -eq 0 ]
