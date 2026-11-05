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
# Options:
#   --baseline PATH       versions/base.yaml (default: <repo>/versions/base.yaml)
#   --index PATH          container-image-mirror index.json (required)
#   --offline-root PATH   offline-files root (default: <repo>/deployments/offline-files)
#   --force               rebuild tars that already exist
#   --dry-run             print the skopeo commands without running them
#   --continue-on-error   keep going when one image fails; exit non-zero at the end

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
BASELINE="${REPO_ROOT}/versions/base.yaml"
INDEX=""
OFFLINE_ROOT="${REPO_ROOT}/deployments/offline-files"
FORCE=0
DRY_RUN=0
CONTINUE_ON_ERROR=0

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) BASELINE="${2:?--baseline needs a path}"; shift 2 ;;
        --index) INDEX="${2:?--index needs a path}"; shift 2 ;;
        --offline-root) OFFLINE_ROOT="${2:?--offline-root needs a path}"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --continue-on-error) CONTINUE_ON_ERROR=1; shift ;;
        --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -n "${INDEX}" ] || die "--index is required"
for cmd in python3 jq skopeo; do
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is required"
done

PLAN="$(mktemp -t cubestack-base-plan.XXXXXX.json)"
trap 'rm -f "${PLAN}"' EXIT

python3 "${SCRIPT_DIR}/lib-base-catalog.py" \
    --baseline "${BASELINE}" --index "${INDEX}" >"${PLAN}"

mkdir -p "${OFFLINE_ROOT}"
say "baseline: ${BASELINE}"
say "catalog:  ${INDEX}"
say "root:     ${OFFLINE_ROOT}"

failed=0
total=0
copied=0
skipped=0

while IFS= read -r item; do
    [ -n "${item}" ] || continue
    total=$((total + 1))
    key="$(jq -r '.key' <<<"${item}")"
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

say "done: total=${total} copied=${copied} skipped=${skipped} failed=${failed}"
[ "${failed}" -eq 0 ]
