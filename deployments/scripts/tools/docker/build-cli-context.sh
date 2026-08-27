#!/bin/bash
# ============================================================
# build-cli-context.sh — 生成 Docker CLI 镜像独立构建上下文(deployments/cli-context/)
# ------------------------------------------------------------
# 用途: 把"CLI 镜像需要的文件"单独生成到 cli-context/ 目录, 作为 docker build 的构建上下文,
#       与全量 offline-files 解耦 —— offline-files 未来增加镜像/组件/系统包都不影响镜像构建
#       (无需维护 .dockerignore 白名单, 也避免把 20G+ 离线文件送进构建上下文)。
# 原则: 只复制两类 → ① 源码/脚本/配置模板(scripts / kubespray 源码 / inventory group_vars /
#       cubestack-addon / skills); ② 3 个轻量 CLI 二进制(kubectl/helm/skopeo, 从
#       Dockerfile-cli 的 COPY 行自动提取文件名, 版本升级无需改本脚本)。
# 不复制: 离线大文件(images/镜像 tar/节点侧二进制/VM 镜像)、运行时生成的凭据文件
#         (hosts.yml / inventory.ini / artifacts/)。
# 用法: sudo ./build-cli-context.sh                  # 生成 deployments/cli-context/
#       sudo ./build-cli-context.sh --build           # 生成并构建镜像(增量, 基于 Harbor 基础)
#       sudo ./build-cli-context.sh --build --push    # 生成、构建并推送到 Harbor
#       sudo ./build-cli-context.sh --output /tmp/cli-ctx
# 构建(手动): 生成后执行
#       sudo docker build -f Dockerfile-cli -t harbor.isuanova.com/cubestack/cubestack-installer-cli:latest deployments/cli-context/
# 完整重建(工具链变更/基础镜像不可用时): 加 --build-arg BASE_IMAGE=ubuntu:22.04
# 说明: cli-context/ 为生成目录(gitignore), 每次构建前重新生成即可保证与源码一致。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"

OUT="${REPO_ROOT}/deployments/cli-context"
IMAGE="harbor.isuanova.com/cubestack/cubestack-installer-cli:latest"
DO_BUILD=0
DO_PUSH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUT="$2"; shift 2 ;;
        --build)  DO_BUILD=1; shift ;;
        --push)   DO_BUILD=1; DO_PUSH=1; shift ;;
        -h|--help) head -20 "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(可用 --output/--build/--push)"; exit 1 ;;
    esac
done

say "生成 CLI 镜像构建上下文 → ${OUT}"
rm -rf "${OUT}"
mkdir -p "${OUT}/deployments" "${OUT}/deployments/offline-files/kubespray"

# ---------------- 源码/脚本/配置模板(全量复制) ----------------
say "同步 deployments/scripts(排除 offline-files/virtual-machine) ..."
rsync -a --exclude 'offline-files' --exclude 'virtual-machine' \
    "${REPO_ROOT}/deployments/scripts" "${OUT}/deployments/"
say "同步 deployments/cubestack-addon ..."
rsync -a "${REPO_ROOT}/deployments/cubestack-addon" "${OUT}/deployments/"
say "同步 kubespray 源码(排除 .git / .venv 等运行期目录) ..."
rsync -a --exclude '.git' --exclude '.venv' --exclude 'venv' --exclude '.ansible' --exclude '.cache' \
    "${REPO_ROOT}/deployments/kubespray/kubespray" "${OUT}/deployments/kubespray/"
say "同步 inventory 配置模板(排除运行时凭据 hosts.yml/inventory.ini/artifacts) ..."
rsync -a --exclude 'hosts.yml' --exclude 'inventory.ini' --exclude 'artifacts' \
    "${REPO_ROOT}/deployments/kubespray/inventory" "${OUT}/deployments/kubespray/"
say "同步 skills ..."
rsync -a "${REPO_ROOT}/skills" "${OUT}/"

# ---------------- 轻量 CLI 二进制(文件名从 Dockerfile-cli COPY 行自动提取) ----------------
# 保证与镜像 COPY 内容一致: kubectl-<ver>-amd64 / helm-<ver>-linux-amd64.tar.gz / skopeo-<ver>-amd64
say "拷贝 CLI 二进制(kubectl/helm/skopeo, 文件名取自 Dockerfile-cli COPY 行) ..."
mapfile -t CLI_FILES < <(grep -oP 'deployments/offline-files/kubespray/\K[^ ]+' \
    "${REPO_ROOT}/Dockerfile-cli" 2>/dev/null | sort -u || true)
if [ "${#CLI_FILES[@]}" -eq 0 ]; then
    CLI_FILES=(kubectl-1.32.5-amd64 helm-3.16.4-linux-amd64.tar.gz skopeo-1.16.1-amd64)
fi
for f in "${CLI_FILES[@]}"; do
    [ -n "${f}" ] || continue
    if [ -f "${REPO_ROOT}/deployments/offline-files/kubespray/${f}" ]; then
        cp "${REPO_ROOT}/deployments/offline-files/kubespray/${f}" "${OUT}/deployments/offline-files/kubespray/"
        ok "  ${f}"
    else
        warn "缺失 ${f}(可先运行 tools/offline/fetch-offline-from-minio.sh 下载)"
    fi
done

echo ""
ok "构建上下文就绪: ${OUT}  ($(du -sh "${OUT}" 2>/dev/null | awk '{print $1}'))"

if [ "${DO_BUILD}" = "1" ]; then
    say "构建镜像(增量, 基于 ${IMAGE}) ..."
    docker build -f "${REPO_ROOT}/Dockerfile-cli" -t "${IMAGE}" "${OUT}" \
        || { err "构建失败"; exit 1; }
    ok "构建完成: ${IMAGE}"
    if [ "${DO_PUSH}" = "1" ]; then
        say "推送到 Harbor ..."
        docker push "${IMAGE}" || { err "推送失败(需先 docker login)"; exit 1; }
        ok "已推送: ${IMAGE}"
    fi
else
    echo "  构建镜像:"
    echo "    sudo docker build -f Dockerfile-cli -t ${IMAGE} ${OUT}"
    echo "  完整重建(工具链变更):"
    echo "    sudo docker build --build-arg BASE_IMAGE=ubuntu:22.04 -f Dockerfile-cli -t ${IMAGE} ${OUT}"
    echo "  推送:"
    echo "    sudo docker push ${IMAGE}"
fi
