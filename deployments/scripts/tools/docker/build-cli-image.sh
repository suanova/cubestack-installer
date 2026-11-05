#!/bin/bash
# ============================================================
# build-cli-image.sh — build/push the CubeStack installer CLI images
# ------------------------------------------------------------
# Two layers:
#   · base = images/installer-cli-base/Dockerfile (system + toolchain + ansible)
#   · code = images/installer-cli/Dockerfile (FROM base + deployments/skills/versions)
#
# The code layer builds directly from the repository root; .dockerignore keeps
# offline assets and runtime credentials out of the context. The base layer
# needs kubectl/helm/skopeo/yq/mc, which are not in git: they are staged from
# the offline version directory (or the host) into a temporary context that is
# removed after the build.
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

IMAGE="harbor.isuanova.com/suanova/cubestack-installer-cli:latest"
BASE_IMAGE="ubuntu:22.04"
# Namespaces intentionally differ: base is pushed to cubestack, the code image
# to suanova (separate push permissions).
CLI_BASE_TAG="harbor.isuanova.com/cubestack/cubestack-installer-cli-base:latest"
BASE_DOCKERFILE="${REPO_ROOT}/images/installer-cli-base/Dockerfile"
CODE_DOCKERFILE="${REPO_ROOT}/images/installer-cli/Dockerfile"
OS_TAR="${REPO_ROOT}/deployments/offline-files/os/ubuntu-22.04.tar"
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
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

ensure_base_image() {
    if ${ENGINE} image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
        return 0
    fi
    if [ -f "${OS_TAR}" ]; then
        say "local ${BASE_IMAGE} missing; loading ${OS_TAR} ..."
        ${ENGINE} load -i "${OS_TAR}"
    else
        err "base image ${BASE_IMAGE} missing and ${OS_TAR} not found"
        err "  → provide the offline tar or run: ${ENGINE} pull ${BASE_IMAGE}"
        exit 1
    fi
}

ensure_cli_base() {
    if ${ENGINE} image inspect "${CLI_BASE_TAG}" >/dev/null 2>&1; then
        return 0
    fi
    say "local ${CLI_BASE_TAG} missing; pulling from Harbor ..."
    ${ENGINE} pull "${CLI_BASE_TAG}" 2>/dev/null || {
        err "missing base image ${CLI_BASE_TAG} locally and in Harbor"
        err "  → build it first: sudo $0 --base"
        exit 1
    }
}

# ---------- base layer: stage the pinned toolchain ----------
stage_toolchain() {
    local bin_dir="$1"
    mkdir -p "${bin_dir}"
    # Prefer the newest materialized kubespray version dir, then the host.
    local kv_dir=""
    kv_dir="$(ls -d "${REPO_ROOT}/deployments/offline-files/kubespray"/v*/ 2>/dev/null | sort -V | tail -1 || true)"

    _tool_one() {
        local out="$1" pat="$2" src=""
        if [ -n "${kv_dir}" ]; then
            src="$(ls "${kv_dir}"${pat}-* 2>/dev/null | head -1 || true)"
        fi
        if [ -z "${src}" ] && command -v "${pat}" >/dev/null 2>&1; then
            src="$(command -v "${pat}")"
        fi
        if [ -n "${src}" ] && [ -f "${src}" ]; then
            cp "${src}" "${bin_dir}/${out}"
            ok "  ${out} <- ${src#${REPO_ROOT}/}"
        else
            err "cannot find ${pat} (offline version dir and host both lack it)"
            return 1
        fi
    }

    say "staging toolchain into ${bin_dir} (source: ${kv_dir:-host}) ..."
    _tool_one kubectl kubectl || exit 1
    _tool_one skopeo  skopeo  || exit 1
    _tool_one yq      yq      || exit 1

    local helm_src=""
    [ -n "${kv_dir}" ] && helm_src="$(ls "${kv_dir}"helm-*.tar.gz 2>/dev/null | head -1 || true)"
    if [ -z "${helm_src}" ]; then
        err "cannot find helm-*.tar.gz in ${kv_dir:-the offline version dir}"
        exit 1
    fi
    cp "${helm_src}" "${bin_dir}/helm-archive.tar.gz"
    ok "  helm-archive.tar.gz <- ${helm_src#${REPO_ROOT}/}"

    # mc bootstraps MinIO downloads; it cannot be supplied by a mount.
    local mc_src="" mc_arch
    mc_arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
    case "${mc_arch}" in amd64|arm64) ;; *) mc_arch="amd64" ;; esac
    local mc_machine=3e00
    [ "${mc_arch}" = "arm64" ] && mc_machine=b700
    local candidate
    for candidate in "${REPO_ROOT}/deployments/offline-files/os"/mc-*; do
        [ -f "${candidate}" ] && { mc_src="${candidate}"; break; }
    done
    if [ -z "${mc_src}" ]; then
        local mc_url="https://dl.min.io/aistor/mc/release/linux-${mc_arch}/mc"
        warn "no offline mc, trying ${mc_url}"
        if wget -q -O "${bin_dir}/mc" "${mc_url}" 2>/dev/null && [ -s "${bin_dir}/mc" ]; then
            chmod +x "${bin_dir}/mc"
            if "${bin_dir}/mc" --version >/dev/null 2>&1; then
                mc_src="${mc_url}"
            else
                rm -f "${bin_dir}/mc"
            fi
        fi
    fi
    if [ -z "${mc_src}" ] && command -v mc >/dev/null 2>&1; then
        mc_src="$(command -v mc)"
        warn "using host mc: ${mc_src}"
    fi
    if [ -z "${mc_src}" ]; then
        err "cannot find mc (offline-files/os/mc-* and host both lack it)"
        exit 1
    fi
    if [ "${mc_src}" != *"://"* ]; then
        [ -f "${mc_src}" ] || { err "mc source not found: ${mc_src}"; exit 1; }
        cp "${mc_src}" "${bin_dir}/mc"
        ok "  mc <- ${mc_src#${REPO_ROOT}/}"
    else
        ok "  mc <- ${mc_src}"
    fi
    # Reject an architecture-mismatched binary before it enters the image.
    if [ "$(od -An -tx1 -N4 "${bin_dir}/mc" | tr -d ' \n')" != "7f454c46" ] \
        || [ "$(od -An -tx1 -j18 -N2 "${bin_dir}/mc" | tr -d ' \n')" != "${mc_machine}" ]; then
        err "mc binary architecture does not match ${mc_arch}"
        exit 1
    fi
}

build_base() {
    ensure_base_image
    [ -f "${BASE_DOCKERFILE}" ] || { err "base Dockerfile not found: ${BASE_DOCKERFILE}"; exit 1; }
    STAGE_DIR="$(mktemp -d -t cubestack-cli-base.XXXXXX)"
    stage_toolchain "${STAGE_DIR}/bin"
    say "building base layer -> ${CLI_BASE_TAG} ..."
    ${ENGINE} build "${ENGINE_FMT_ARGS[@]}" -f "${BASE_DOCKERFILE}" -t "${CLI_BASE_TAG}" "${STAGE_DIR}" \
        || { err "base build failed"; exit 1; }
    local layers
    layers="$(${ENGINE} history --no-trunc "${CLI_BASE_TAG}" 2>/dev/null | tail -n +2 | wc -l || true)"
    ok "base layer ready: ${CLI_BASE_TAG} (${layers:-0} layers)"
}

build_code() {
    ensure_cli_base
    [ -f "${CODE_DOCKERFILE}" ] || { err "code Dockerfile not found: ${CODE_DOCKERFILE}"; exit 1; }
    say "building code layer from ${REPO_ROOT} -> ${IMAGE} ..."
    ${ENGINE} build "${ENGINE_FMT_ARGS[@]}" -f "${CODE_DOCKERFILE}" \
        --build-arg "CLI_BASE_TAG=${CLI_BASE_TAG}" -t "${IMAGE}" "${REPO_ROOT}" \
        || { err "code build failed"; exit 1; }
    ok "image ready: ${IMAGE}"
}

if [ "${DO_BUILD}" = "1" ]; then
    [ "${DO_BASE}" = "1" ] && build_base
    build_code
    if [ "${DO_PUSH}" = "1" ]; then
        push_images=()
        [ "${DO_BASE}" = "1" ] && push_images+=("${CLI_BASE_TAG}")
        push_images+=("${IMAGE}")
        for push_image in "${push_images[@]}"; do
            say "pushing ${push_image} ..."
            ${ENGINE} push "${push_image}" || { err "push failed: ${push_image}"; exit 1; }
            ok "pushed: ${push_image}"
        done
    fi
else
    echo "Manual builds:"
    echo "  code: sudo ${ENGINE} build ${ENGINE_FMT_ARGS[*]} -f ${CODE_DOCKERFILE} --build-arg CLI_BASE_TAG=${CLI_BASE_TAG} -t ${IMAGE} ${REPO_ROOT}"
    echo "  base: sudo ${ENGINE} build ${ENGINE_FMT_ARGS[*]} -f ${BASE_DOCKERFILE} -t ${CLI_BASE_TAG} <staged-context>"
    echo "  push: sudo ${ENGINE} push ${IMAGE}"
fi
