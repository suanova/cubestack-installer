#!/bin/bash
# ============================================================
# build-cli-image.sh — build/push the CubeStack installer CLI images
# ------------------------------------------------------------
# Two layers:
#   · base = images/installer-cli-base/Dockerfile (system + toolchain + ansible)
#   · code = images/installer-cli/Dockerfile (FROM base + deployments/skills/versions)
#
# Build inputs are only the repository itself or the network:
#   · code layer: the repository root is the build context; .dockerignore keeps
#     offline assets and runtime credentials out
#   · base layer: a temporary context containing only requirements.txt; tools
#     (kubectl/helm/skopeo/yq/mc) are downloaded in the Dockerfile with pinned
#     versions and sha256 checksums
#
# Usage:
#   sudo ./build-cli-image.sh                  # print build commands
#   sudo ./build-cli-image.sh --build          # code layer (pull base if needed)
#   sudo ./build-cli-image.sh --build --push   # code layer + push
#   sudo ./build-cli-image.sh --base           # base layer (needs network apt/pip)
#   sudo ./build-cli-image.sh --base --push    # base layer + push
#   sudo ./build-cli-image.sh --build --engine podman
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"

# The channel comes from the repo's VERSION_LINE, so a branch cut only changes
# one file. Releases still use immutable X.Y.Z tags on top of the channel.
VERSION_LINE_FILE="${REPO_ROOT}/VERSION_LINE"
VERSION_LINE="${VERSION_LINE:-}"
if [ -z "${VERSION_LINE}" ]; then
    [ -f "${VERSION_LINE_FILE}" ] || { err "VERSION_LINE not found: ${VERSION_LINE_FILE}"; exit 1; }
    VERSION_LINE="$(tr -d '[:space:]' < "${VERSION_LINE_FILE}")"
fi
case "${VERSION_LINE}" in
    [0-9]*.[0-9]*) ;;
    *) err "invalid VERSION_LINE: ${VERSION_LINE}"; exit 1 ;;
esac
CHANNEL="${CLI_CHANNEL:-${VERSION_LINE}-latest}"
IMAGE="${CLI_IMAGE:-harbor.isuanova.com/suanova/cubestack-installer-cli:${CHANNEL}}"
BASE_IMAGE="ubuntu:22.04"
# Namespaces intentionally differ: base is pushed to cubestack, the code image
# to suanova (separate push permissions).
BASE_TAG="${CLI_BASE_TAG:-harbor.isuanova.com/cubestack/cubestack-installer-cli-base:${CHANNEL}}"
BASE_DOCKERFILE="${REPO_ROOT}/images/installer-cli-base/Dockerfile"
CODE_DOCKERFILE="${REPO_ROOT}/images/installer-cli/Dockerfile"
REQUIREMENTS="${REPO_ROOT}/deployments/kubespray/kubespray/requirements.txt"
DO_BUILD=0
DO_BASE=0
DO_PUSH=0
STAGE_DIR=""
cleanup() { [ -n "${STAGE_DIR}" ] && rm -rf "${STAGE_DIR}"; }
trap cleanup EXIT
while [ $# -gt 0 ]; do
    case "$1" in
        --build)  DO_BUILD=1; shift ;;
        --push)   DO_BUILD=1; DO_PUSH=1; shift ;;
        --incremental) DO_BUILD=1; say "note: --incremental is an alias for --build"; shift ;;
        --base)   DO_BASE=1; DO_BUILD=1; shift ;;
        --engine) ENGINE_ARG="${2:?--engine needs docker or podman}"; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "unknown option: $1 (use --build/--push/--base/--engine)"; exit 1 ;;
    esac
done

# ---------- container engine ----------
ENGINE="${ENGINE_ARG:-${CONTAINER_ENGINE:-}}"
if [ -z "${ENGINE}" ]; then
    if command -v docker >/dev/null 2>&1; then ENGINE=docker
    elif command -v podman >/dev/null 2>&1; then ENGINE=podman
    else err "no container engine found (docker/podman); install one or pass --engine"; exit 1; fi
fi
command -v "${ENGINE}" >/dev/null 2>&1 || { err "--engine ${ENGINE} is not available"; exit 1; }
ENGINE_FMT_ARGS=()
[ "${ENGINE}" = "podman" ] && ENGINE_FMT_ARGS=(--format docker)

ensure_ubuntu() {
    ${ENGINE} image inspect "${BASE_IMAGE}" >/dev/null 2>&1 && return 0
    say "pulling ${BASE_IMAGE} ..."
    ${ENGINE} pull "${BASE_IMAGE}" || { err "cannot pull ${BASE_IMAGE}"; exit 1; }
}

ensure_cli_base() {
    ${ENGINE} image inspect "${BASE_TAG}" >/dev/null 2>&1 && return 0
    say "local ${BASE_TAG} missing; pulling from Harbor ..."
    ${ENGINE} pull "${BASE_TAG}" 2>/dev/null || {
        err "missing base image ${BASE_TAG} locally and in Harbor"
        err "  → build it first: sudo $0 --base"
        exit 1
    }
}

build_base() {
    ensure_ubuntu
    [ -f "${BASE_DOCKERFILE}" ] || { err "base Dockerfile not found: ${BASE_DOCKERFILE}"; exit 1; }
    [ -f "${REQUIREMENTS}" ] || { err "requirements.txt not found: ${REQUIREMENTS}"; exit 1; }
    STAGE_DIR="$(mktemp -d -t cubestack-cli-base.XXXXXX)"
    mkdir -p "${STAGE_DIR}/deployments/kubespray/kubespray"
    cp "${REQUIREMENTS}" "${STAGE_DIR}/deployments/kubespray/kubespray/requirements.txt"
    say "building base layer -> ${BASE_TAG} ..."
    ${ENGINE} build "${ENGINE_FMT_ARGS[@]}" -f "${BASE_DOCKERFILE}" -t "${BASE_TAG}" "${STAGE_DIR}" \
        || { err "base build failed"; exit 1; }
    local layers
    layers="$(${ENGINE} history --no-trunc "${BASE_TAG}" 2>/dev/null | tail -n +2 | wc -l || true)"
    ok "base layer ready: ${BASE_TAG} (${layers:-0} layers)"
}

build_code() {
    ensure_cli_base
    [ -f "${CODE_DOCKERFILE}" ] || { err "code Dockerfile not found: ${CODE_DOCKERFILE}"; exit 1; }
    say "building code layer from ${REPO_ROOT} -> ${IMAGE} ..."
    ${ENGINE} build "${ENGINE_FMT_ARGS[@]}" -f "${CODE_DOCKERFILE}" \
        --build-arg "CLI_BASE_TAG=${BASE_TAG}" -t "${IMAGE}" "${REPO_ROOT}" \
        || { err "code build failed"; exit 1; }
    ok "image ready: ${IMAGE}"
}

if [ "${DO_BUILD}" = "1" ]; then
    [ "${DO_BASE}" = "1" ] && build_base
    build_code
    if [ "${DO_PUSH}" = "1" ]; then
        push_images=()
        [ "${DO_BASE}" = "1" ] && push_images+=("${BASE_TAG}")
        push_images+=("${IMAGE}")
        for push_image in "${push_images[@]}"; do
            say "pushing ${push_image} ..."
            ${ENGINE} push "${push_image}" || { err "push failed: ${push_image}"; exit 1; }
            ok "pushed: ${push_image}"
        done
    fi
else
    echo "Manual builds:"
    echo "  code: sudo ${ENGINE} build ${ENGINE_FMT_ARGS[*]} -f ${CODE_DOCKERFILE} --build-arg CLI_BASE_TAG=${BASE_TAG} -t ${IMAGE} ${REPO_ROOT}"
    echo "  base: sudo ${ENGINE} build ${ENGINE_FMT_ARGS[*]} -f ${BASE_DOCKERFILE} -t ${BASE_TAG} <staged-requirements-context>"
    echo "  push: sudo ${ENGINE} push ${IMAGE}"
fi
