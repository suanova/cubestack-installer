#!/bin/bash
# ============================================================
# metax-save-images.sh — 把沐曦(MetaX)镜像从本地 docker docker save 成 tar 到离线目录
# 用途: 在已有这些镜像的机器(在线/内网)上把镜像导出为 tar, 供离线环境用
#       gpu-operator 模块 tar 模式(METAX_IMAGE_MODE=tar) / metax-load-images.sh 从该目录加载。
# 数据源: cluster.conf (METAX_OFFLINE_DIR / METAX_SAVE_PATTERN / METAX_SAVE_EXCLUDE)
# 枚举范围: 本地 docker 中匹配 METAX_SAVE_PATTERN 的镜像, 跳过 METAX_SAVE_EXCLUDE(默认 sglang)与 digest 引用。
#   源仓库默认 harbor.isuanova.com/metax(内网 Harbor); 也可选 cr.metax-tech.com/cloud(沐曦官方仓库,
#   改 METAX_SAVE_PATTERN=^cr\.metax-tech\.com/cloud/ 即可; 两者同内容, 选其一)。
# 文件名: <repo:tag> 把 / 与 : 替换为 _ → .tar(与仓库镜像 tar 命名一致, 加载端自动识别)。
# 用法:   sudo ./metax-save-images.sh [额外排除正则]
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ "$(id -u)" -eq 0 ] || { err "需要 root(docker 访问), 请 sudo 执行"; exit 1; }
mkdir -p "${METAX_OFFLINE_DIR}"

PATTERN="${METAX_SAVE_PATTERN:-^harbor\.isuanova\.com/metax/}"
EXCLUDE="${1:-${METAX_SAVE_EXCLUDE:-sglang}}"

say "枚举本地 docker 中匹配 [${PATTERN}] 的沐曦镜像 → ${METAX_OFFLINE_DIR}"
say "  排除: ${EXCLUDE}"

_IMG_LIST="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E "${PATTERN}" \
    | grep -viE "${EXCLUDE}" || true)"

[ -n "${_IMG_LIST}" ] || { warn "本地 docker 未找到匹配 [${PATTERN}] 的镜像(检查 METAX_SAVE_PATTERN, 或先 docker pull/tag)"; exit 0; }

count=0; skip=0
for img in ${_IMG_LIST}; do
    [[ "${img}" == *"@"* ]] && { skip=$((skip+1)); continue; }   # 跳过 digest 引用
    fname="$(echo "${img}" | sed 's#/#_#g; s#:#_#g').tar"
    dest="${METAX_OFFLINE_DIR}/${fname}"
    if [ -f "${dest}" ]; then
        echo "  [已存在] ${fname}"
        skip=$((skip+1)); continue
    fi
    echo "  save ${img} → ${fname}"
    if ! docker save "${img}" -o "${dest}"; then
        warn "  save 失败: ${img}"; rm -f "${dest}"; continue
    fi
    count=$((count+1))
done

echo "---------------------------------------------"
ok "保存完成: 新增 ${count} 个, 跳过 ${skip} 个(已存在/排除), 目录: ${METAX_OFFLINE_DIR}"
du -sh "${METAX_OFFLINE_DIR}" 2>/dev/null | awk '{print "  总大小: "$1}'
echo "  加载:  metax-load-images.sh(本目录) 或 gpu-operator 模块 METAX_IMAGE_MODE=tar"
