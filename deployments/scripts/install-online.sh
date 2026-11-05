#!/bin/bash
set -euo pipefail

# Open-source online install entry point.
#
# Reads versions/base.yaml + the mirror catalog, materializes the base images,
# prefetches k8s binaries through the existing deploy flow, and then runs
# deploy-cluster.sh. It never touches MinIO or commercial packaging.
#
# Node prerequisite packages are not installed. A warn-only check runs by
# default; --check-os-packages makes it blocking, --no-check-os-packages skips it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BASELINE="${REPO_ROOT}/versions/base.yaml"
INDEX="${CUBESTACK_MIRROR_INDEX:-}"
INDEX_URL="${CUBESTACK_MIRROR_INDEX_URL:-}"
INDEX_IS_EXPLICIT=0
[ -n "${INDEX}" ] && INDEX_IS_EXPLICIT=1
OFFLINE_ROOT=""
MATERIALIZE=1
FORCE_INDEX=0
CHECK_OS_MODE="warn"
DRY_RUN=0
WITH_DEV_LAB=0
WITH_METAX=0
CHECK_MATERIALS=0
PROFILE_ARG=""
PASSTHRU=()
MIRROR_REPO=""
MIRROR_COMMIT=""
MIRROR_PATH=""
TMP_INDEX=""
BASELINE_ENV_JSON="$(mktemp -t cubestack-baseline-env.XXXXXX.json)"
cleanup() { rm -f "${BASELINE_ENV_JSON}" ${TMP_INDEX:+"${TMP_INDEX}"}; }
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

usage() {
    cat <<'USAGE'
Usage: install-online.sh [online options] [deploy-cluster options]

Reads versions/base.yaml + the mirror catalog, materializes the base images,
prefetches k8s binaries, then runs deploy-cluster.sh. It never touches MinIO or
commercial packaging. Node prerequisite packages are not installed; a warn-only
pre-check runs by default.

The mirror catalog is fetched at the commit pinned by versions/base.yaml
(mirror.repo / mirror.commit / mirror.path). CUBESTACK_MIRROR_INDEX_URL or
--index override it explicitly.

Online options:
  --baseline PATH          versions/base.yaml (default: <repo>/versions/base.yaml)
  --index PATH             local mirror index.json (skips the pinned download)
  --offline-root PATH      offline-files root (default: from cluster config)
  --no-materialize         skip image materialization
  --with-dev-lab           also materialize the optional dev-lab images
  --with-metax             require MetaX vendor materials and enable GPU operator
  --check-materials        report missing vendor materials (warn only)
  --require-materials      fail when a declared vendor material is missing
  --force-index            re-download the mirror index
  --check-os-packages      run a blocking node prerequisite pre-check
                           (default is warn-only)
  --no-check-os-packages   skip the pre-check
  --dry-run                print actions without materializing or deploying
  --profile NAME           pass through to deploy-cluster.sh (also used for
                           version resolution)

All other arguments are passed to deploy-cluster.sh.

Host prerequisites for online install: python3 + PyYAML, jq, skopeo, curl.
USAGE
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) BASELINE="${2:?--baseline needs a path}"; shift 2 ;;
        --index) INDEX="${2:?--index needs a path}"; INDEX_IS_EXPLICIT=1; shift 2 ;;
        --offline-root) OFFLINE_ROOT="${2:?--offline-root needs a path}"; shift 2 ;;
        --no-materialize) MATERIALIZE=0; shift ;;
        --with-dev-lab) WITH_DEV_LAB=1; shift ;;
        --with-metax) WITH_METAX=1; CHECK_MATERIALS=2; shift ;;
        --check-materials) CHECK_MATERIALS=1; shift ;;
        --require-materials) CHECK_MATERIALS=2; shift ;;
        --force-index) FORCE_INDEX=1; shift ;;
        --check-os-packages) CHECK_OS_MODE="fail"; shift ;;
        --no-check-os-packages) CHECK_OS_MODE="off"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --profile) PROFILE_ARG="${2:?--profile needs a name}"; PASSTHRU+=("$1" "$2"); shift 2 ;;
        --help|-h) usage ;;
        --) shift; PASSTHRU+=("$@"); break ;;
        *) PASSTHRU+=("$1"); shift ;;
    esac
done

# Load cluster config so ${K8S_VERSION} etc. can be resolved before the deploy
# flow starts. The baseline env is authoritative for online installs; defaults
# and profiles only fill private/derived values not present there.
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

load_baseline_env() {
    local baseline="$1" out
    if ! out="$(python3 - "${baseline}" "${BASELINE_ENV_JSON}" <<'PY'
import json
import shlex
import sys
from pathlib import Path
import yaml

data = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
env = data.get("env") or {}
Path(sys.argv[2]).write_text(
    json.dumps({str(k): str(v) for k, v in env.items()}),
    encoding="utf-8",
)
mirror = data.get("mirror") or {}
for key in ("repo", "commit", "path"):
    print(f"export MIRROR_{key.upper()}={shlex.quote(str(mirror.get(key, '')))}")
for key, value in sorted(env.items()):
    print(f"export {key}={shlex.quote(str(value))}")
PY
)"; then
        die "cannot read baseline env from ${baseline} (python3 + PyYAML required)"
    fi
    eval "${out}"
}
load_baseline_env "${BASELINE}"

if [ -n "${PROFILE_ARG}" ]; then
    export KUBESPRAY_PROFILE="${PROFILE_ARG}"
fi
set -a
load_config
set +a

# The baseline owns the version surface. A kubespray profile or cluster.conf
# that disagrees would silently materialize different images than it deploys.
python3 - "${BASELINE_ENV_JSON}" <<'PY' || die "baseline env and effective config disagree"
import json
import os
import sys

baseline = json.loads(open(sys.argv[1], encoding="utf-8").read())
mismatch = []
for key, want in baseline.items():
    got = os.environ.get(key)
    if got is not None and got != str(want):
        mismatch.append((key, str(want), got))
if mismatch:
    for key, want, got in mismatch:
        print(f"  {key}: baseline={want} effective={got}", file=sys.stderr)
    print("online install is baseline-driven; align the profile/cluster config "
          "with versions/base.yaml, or change the baseline", file=sys.stderr)
    sys.exit(1)
PY

if [ -z "${OFFLINE_ROOT}" ]; then
    OFFLINE_ROOT="${OFFLINE_FILES_ROOT}"
fi
[ -n "${OFFLINE_ROOT}" ] || die "cannot determine offline-files root"
export OFFLINE_FILES_ROOT="${OFFLINE_ROOT}"
mkdir -p "${OFFLINE_ROOT}"

if [ -z "${INDEX_URL}" ]; then
    [ -n "${MIRROR_REPO}" ] && [ -n "${MIRROR_COMMIT}" ] && [ -n "${MIRROR_PATH}" ] \
        || die "baseline mirror pin is incomplete (mirror.repo/commit/path)"
    INDEX_URL="https://raw.githubusercontent.com/${MIRROR_REPO}/${MIRROR_COMMIT}/${MIRROR_PATH}"
fi

if [ -z "${INDEX}" ]; then
    # Cache per pinned commit so a new pin cannot silently reuse an old index.
    if [ -n "${MIRROR_COMMIT}" ]; then
        INDEX="${OFFLINE_ROOT}/mirror/${MIRROR_COMMIT}/index.json"
    else
        INDEX="${OFFLINE_ROOT}/index.json"
    fi
    if [ ! -s "${INDEX}" ] || [ "${FORCE_INDEX}" = "1" ]; then
        command -v curl >/dev/null 2>&1 || die "curl is required to download the mirror index"
        say "downloading mirror index: ${INDEX_URL}"
        if [ "${DRY_RUN}" = "1" ]; then
            TMP_INDEX="$(mktemp -t cubestack-mirror-index.XXXXXX.json)"
            curl -fsSL "${INDEX_URL}" -o "${TMP_INDEX}"
            INDEX="${TMP_INDEX}"
        else
            mkdir -p "$(dirname "${INDEX}")"
            curl -fsSL "${INDEX_URL}" -o "${INDEX}.part"
            mv "${INDEX}.part" "${INDEX}"
        fi
    fi
fi
[ -s "${INDEX}" ] || die "mirror index not found: ${INDEX}"
if [ "${INDEX_IS_EXPLICIT}" = "0" ]; then
    say "mirror index pinned by baseline: ${MIRROR_REPO}@${MIRROR_COMMIT}"
fi

if [ "${MATERIALIZE}" = "1" ]; then
    args=(--baseline "${BASELINE}" --index "${INDEX}" --offline-root "${OFFLINE_ROOT}")
    [ "${WITH_DEV_LAB}" = "1" ] && args+=(--include-optional)
    if [ "${DRY_RUN}" = "1" ]; then
        args+=(--dry-run)
    fi
    bash "${SCRIPT_DIR}/tools/online/materialize-base-images.sh" "${args[@]}"
else
    say "skipping image materialization (--no-materialize)"
fi

if [ "${CHECK_OS_MODE}" != "off" ]; then
    hosts=""
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        node_matches "${NODE_HOSTNAME}" || continue
        hosts+="${NODE_USER}@${NODE_IP},"
    done
    hosts="${hosts%,}"
    [ -n "${hosts}" ] || die "no target nodes found for node prerequisite pre-check"
    check_args=(--baseline "${BASELINE}" --hosts "${hosts}"
        --key "${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}")
    if [ -n "${SSH_DEFAULT_PASSWORD:-}" ]; then
        check_args+=(--password "${SSH_DEFAULT_PASSWORD}")
    fi
    if [ "${CHECK_OS_MODE}" = "warn" ]; then
        check_args+=(--warn-only)
        say "node prerequisite pre-check (warn-only)"
    else
        say "node prerequisite pre-check (blocking)"
    fi
    if [ "${DRY_RUN}" = "1" ]; then
        check_args+=(--dry-run)
    fi
    bash "${SCRIPT_DIR}/tools/online/check-os-packages.sh" "${check_args[@]}"
else
    say "node prerequisite pre-check skipped (--no-check-os-packages)"
fi

if [ "${CHECK_MATERIALS}" != "0" ]; then
    material_args=(--baseline "${BASELINE}" --offline-root "${OFFLINE_ROOT}")
    if [ "${CHECK_MATERIALS}" = "1" ]; then
        material_args+=(--warn-only)
        say "vendor materials check (warn-only)"
    else
        say "vendor materials check (blocking)"
    fi
    if [ "${DRY_RUN}" = "1" ]; then
        material_args+=(--dry-run)
    fi
    bash "${SCRIPT_DIR}/tools/online/check-materials.sh" "${material_args[@]}"
else
    say "vendor materials check skipped (--check-materials / --with-metax to enable)"
fi

export CUBESTACK_OS_CHECK_DONE=1
export CUBESTACK_ONLINE=1
export CUBESTACK_OPERATOR_ENABLED=false
[ "${WITH_METAX}" = "1" ] && export GPU_OPERATOR_ENABLED=true
if [ "${WITH_DEV_LAB}" = "1" ]; then
    export DEV_LAB_ENABLED=true
else
    export DEV_LAB_ENABLED=false
fi
export MODEL_IMAGES_ENABLED=false

say "starting deploy-cluster.sh (online mode)"
if [ "${DRY_RUN}" = "1" ]; then
    echo "would exec: ${SCRIPT_DIR}/deploy-cluster.sh ${PASSTHRU[*]:-}"
    exit 0
fi
exec bash "${SCRIPT_DIR}/deploy-cluster.sh" "${PASSTHRU[@]}"
