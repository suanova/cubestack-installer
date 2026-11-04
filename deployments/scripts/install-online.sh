#!/bin/bash
set -euo pipefail

# Open-source online install entry point.
#
# Reads versions/base.yaml + the mirror catalog, materializes the base images,
# prefetches k8s binaries through the existing deploy flow, and then runs
# deploy-cluster.sh. It never touches MinIO or cubestack-release.
#
# OS packages are not installed. The pre-check tool is available but disabled by
# default in 2.1; pass --check-os-packages to run it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BASELINE="${REPO_ROOT}/versions/base.yaml"
INDEX="${CUBESTACK_MIRROR_INDEX:-}"
INDEX_URL="${CUBESTACK_MIRROR_INDEX_URL:-https://raw.githubusercontent.com/suanova/container-image-mirror/main/index.json}"
OFFLINE_ROOT=""
MATERIALIZE=1
FORCE_INDEX=0
CHECK_OS=0
DRY_RUN=0
PROFILE_ARG=""
PASSTHRU=()

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

usage() {
    cat <<'USAGE'
Usage: install-online.sh [online options] [deploy-cluster options]

Reads versions/base.yaml + the mirror catalog, materializes the base images,
prefetches k8s binaries, then runs deploy-cluster.sh. It never touches MinIO or
cubestack-release. OS packages are not installed; the optional pre-check is
disabled by default in 2.1.

Online options:
  --baseline PATH          versions/base.yaml (default: <repo>/versions/base.yaml)
  --index PATH             mirror index.json (default: download from
                           CUBESTACK_MIRROR_INDEX_URL)
  --offline-root PATH      offline-files root (default: from cluster config)
  --no-materialize         skip image materialization
  --force-index            re-download the mirror index
  --check-os-packages      run the optional OS package pre-check
  --dry-run                print actions without materializing or deploying
  --profile NAME           pass through to deploy-cluster.sh (also used for
                           version resolution)

All other arguments are passed to deploy-cluster.sh.
USAGE
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) BASELINE="${2:?--baseline needs a path}"; shift 2 ;;
        --index) INDEX="${2:?--index needs a path}"; shift 2 ;;
        --offline-root) OFFLINE_ROOT="${2:?--offline-root needs a path}"; shift 2 ;;
        --no-materialize) MATERIALIZE=0; shift ;;
        --force-index) FORCE_INDEX=1; shift ;;
        --check-os-packages) CHECK_OS=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --profile) PROFILE_ARG="${2:?--profile needs a name}"; PASSTHRU+=("$1" "$2"); shift 2 ;;
        --help|-h) usage ;;
        --) shift; PASSTHRU+=("$@"); break ;;
        *) PASSTHRU+=("$1"); shift ;;
    esac
done

# Load cluster config so ${K8S_VERSION} etc. can be resolved before the deploy
# flow starts. deploy-cluster.sh will load it again in its own process.
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"
if [ -n "${PROFILE_ARG}" ]; then
    export KUBESPRAY_PROFILE="${PROFILE_ARG}"
fi
set -a
load_config
set +a

if [ -z "${OFFLINE_ROOT}" ]; then
    OFFLINE_ROOT="${OFFLINE_FILES_ROOT}"
fi
[ -n "${OFFLINE_ROOT}" ] || die "cannot determine offline-files root"
export OFFLINE_FILES_ROOT="${OFFLINE_ROOT}"
mkdir -p "${OFFLINE_ROOT}"

if [ -z "${INDEX}" ]; then
    INDEX="${OFFLINE_ROOT}/index.json"
    if [ ! -s "${INDEX}" ] || [ "${FORCE_INDEX}" = "1" ]; then
        command -v curl >/dev/null 2>&1 || die "curl is required to download the mirror index"
        say "downloading mirror index: ${INDEX_URL}"
        if [ "${DRY_RUN}" = "1" ]; then
            :
        else
            mkdir -p "$(dirname "${INDEX}")"
            curl -fsSL "${INDEX_URL}" -o "${INDEX}.part"
            mv "${INDEX}.part" "${INDEX}"
        fi
    fi
fi
[ -s "${INDEX}" ] || die "mirror index not found: ${INDEX}"

if [ "${MATERIALIZE}" = "1" ]; then
    args=(--baseline "${BASELINE}" --index "${INDEX}" --offline-root "${OFFLINE_ROOT}")
    if [ "${DRY_RUN}" = "1" ]; then
        args+=(--dry-run)
    fi
    bash "${SCRIPT_DIR}/tools/online/materialize-base-images.sh" "${args[@]}"
else
    say "skipping image materialization (--no-materialize)"
fi

if [ "${CHECK_OS}" = "1" ]; then
    hosts=""
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        node_matches "${NODE_HOSTNAME}" || continue
        hosts+="${NODE_USER}@${NODE_IP},"
    done
    hosts="${hosts%,}"
    [ -n "${hosts}" ] || die "no target nodes found for OS package pre-check"
    check_args=(--baseline "${BASELINE}" --hosts "${hosts}"
        --key "${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}")
    if [ -n "${SSH_DEFAULT_PASSWORD:-}" ]; then
        check_args+=(--password "${SSH_DEFAULT_PASSWORD}")
    fi
    if [ "${DRY_RUN}" = "1" ]; then
        check_args+=(--dry-run)
    fi
    bash "${SCRIPT_DIR}/tools/online/check-os-packages.sh" "${check_args[@]}"
else
    say "OS package pre-check skipped (2.1 default; pass --check-os-packages to enable)"
fi

export CUBESTACK_ONLINE=1
export CUBESTACK_OPERATOR_ENABLED=false
export DEV_LAB_ENABLED=false
export MODEL_IMAGES_ENABLED=false

say "starting deploy-cluster.sh (online mode)"
if [ "${DRY_RUN}" = "1" ]; then
    echo "would exec: ${SCRIPT_DIR}/deploy-cluster.sh ${PASSTHRU[*]:-}"
    exit 0
fi
exec bash "${SCRIPT_DIR}/deploy-cluster.sh" "${PASSTHRU[@]}"
