#!/bin/sh
# ============================================================
# cli-toolchain-from-offline.sh — 运行期把**挂载的离线目录**里的 CLI 工具挂到 PATH
#
# 为什么需要: CLI 镜像**只含 deployments/ 代码**(2026-09-30 起, 不再把离线二进制打进镜像),
#   而容器内确实要本地调用 kubectl / helm / skopeo(见 docs/scripts-development-spec.md §1.2)。
#   它们随离线件一起挂在 /opt/cubestack-installer/deployments/offline-files/(版本目录)——
#   本脚本在登录 shell 启动时幂等地建软链, 把工具补回 PATH。
#
# 安装方式: 由 Dockerfile-cli 拷到 /etc/profile.d/50-cubestack-tools.sh
# ⚠ 只在**登录 shell**(bash -l / bash -lc)里生效 —— 部署流程文档用的就是 `bash -lc`
#   (见 deployments/scripts/README.md); 非登录 shell 下请显式 source /etc/profile 或 bash -lc。
# ⚠ 本文件会被 **source**(不是执行): 不得 exit, 不得用 bash 专有语法。
# ============================================================

_cs_repo="${CUBESTACK_REPO_ROOT:-/opt/cubestack-installer}"
_cs_ver="$(awk '/^version:/{print "v"$2; exit}' \
    "${_cs_repo}/deployments/kubespray/kubespray/galaxy.yml" 2>/dev/null)"
_cs_dir="${OFFLINE_FILES_DIR:-${_cs_repo}/deployments/offline-files/kubespray/${_cs_ver}}"

if [ -d "${_cs_dir}" ]; then
    # ① 静态二进制: kubectl / skopeo(版本目录里是 <名>-<版本>-amd64 形态)
    for _cs_b in kubectl skopeo; do
        command -v "${_cs_b}" >/dev/null 2>&1 && continue
        _cs_f="$(ls "${_cs_dir}/${_cs_b}"-* 2>/dev/null | head -1)"
        [ -n "${_cs_f}" ] && [ -x "${_cs_f}" ] && ln -sf "${_cs_f}" "/usr/local/bin/${_cs_b}" 2>/dev/null
    done
    # ② helm: 压缩包形态, 解一次放 /opt/cubestack-tools(镜像层可写即可)
    if ! command -v helm >/dev/null 2>&1; then
        _cs_h="$(ls "${_cs_dir}"/helm-*.tar.gz 2>/dev/null | head -1)"
        if [ -n "${_cs_h}" ]; then
            _cs_t="/opt/cubestack-tools"
            [ -x "${_cs_t}/helm" ] || {
                mkdir -p "${_cs_t}" 2>/dev/null
                tar xzf "${_cs_h}" -C "${_cs_t}" 2>/dev/null
                _cs_hb="$(find "${_cs_t}" -maxdepth 2 -type f -name helm 2>/dev/null | head -1)"
                [ -n "${_cs_hb}" ] && [ "${_cs_hb}" != "${_cs_t}/helm" ] && mv "${_cs_hb}" "${_cs_t}/helm" 2>/dev/null
            }
            [ -x "${_cs_t}/helm" ] && ln -sf "${_cs_t}/helm" /usr/local/bin/helm 2>/dev/null
        fi
    fi
fi
unset _cs_repo _cs_ver _cs_dir _cs_b _cs_f _cs_h _cs_t _cs_hb 2>/dev/null
