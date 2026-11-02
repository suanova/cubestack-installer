#!/bin/bash
# ============================================================
# cubestack-platform-sync.sh — 平台/组件镜像保鲜编排: Harbor → 离线 tar → MinIO(内网)
# ------------------------------------------------------------
# 定位: 跑在**能同时访问 Harbor 与 MinIO 的机器**上(Harbor 服务器 / 安装机; 2026-10-16 定案)。
#   MinIO 无 TLS: 默认不在公网/CI 托管 runner 上跑, 避免明文传密码与大流量公网传输。
#   若组织的 GitHub 托管 runner 可访问 MinIO(现有 refresh-*.yml 即走这条通路), 也可由 CI 执行;
#   两者产出同一份离线包, 选哪条取决于网络与凭据策略。
# 集合(collections; 每个 = offline-files/<集合>/ 目录 + 其 image-list.tsv 清单):
#   · cubestack-operator  平台 Operator 与各组件镜像(37 件)+ operator helm chart(charts/ 子目录)
#   · model-collection    模型推理镜像 sglang / vllm-metax(3 件 ≈33G, 大件建议 .tar.gz;
#                         2026-10-29: sglang = 0.5.14 + v0.5.12-glm5-rc4, vllm 不变)
#   · dev-lab             开发镜像 cpu / maca / cuda 家族(3 件; 顶层平铺)
#   默认全部处理; --collection 可只跑其中若干(逗号/空格分隔)。
# 流程(逐集合):
#   ① 从 MinIO 拉回现有 *.digest 边车(--exclude '*.tar' '*.tar.gz', 只拉小文件)
#      → 让第②步的"未变化即跳过"生效(增量, 不重复拉大镜像);
#   ② 调用 cubestack-platform-save-images.sh: 逐镜像 digest 比对, 变化才 skopeo 拉取+重写 tar;
#      ②b 仅 cubestack-operator: helm pull chart → 比对 Digest 边车 → 变化才原子替换(需 helm);
#   ③ 上传: mc mirror --overwrite 状态目录 → <桶>/<前缀>/<集合>/
#      (只上传本地存在者; 默认**不删**远端 —— 需要收敛历史残留时显式 --prune);
#   ④ 校验: 汇总本地/远端 tar/.tar.gz 与 chart(.tgz)数并对照。
#
# 配置(环境变量, 或 --conf <file> 指向 600 的 env 文件; 与 cluster.conf 同名):
#   MINIO_ENDPOINT(如 http://minio:9000) MINIO_ACCESS_KEY MINIO_SECRET_KEY
#   MINIO_BUCKET(默认 cubestack-installer) MINIO_REMOTE_DIR(默认 offline-files)
#   HARBOR_MIRROR_USER / HARBOR_MIRROR_PASSWORD(或 REGISTRY_AUTH_FILE; 否则用 ~/.docker/config.json)
# 用法:
#   bash tools/images/cubestack-platform-sync.sh [--state-dir <d>] [--conf <envfile>]
#        [--collection <name,..>] [--only <子串,..>] [--force] [--no-pull-state] [--prune]
#        [--seal-missing] [--dry-run] [--verify-minio] [--print-systemd]
#   · --verify-minio: 上传后逐 tar 流式 sha256 比对本地 ↔ MinIO(强一致; 会完整读远端对象,
#     大集合较慢)。--only 同时限定上传与校验范围。
#   · --no-pull-state: 不先用远端旧边车覆盖本地(本地已是最新 tar 时用, 避免无谓重拉)。
# 退出码: 0=成功; 1=有集合失败(其余集合继续)
# ============================================================
set -euo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib-common.sh
source "${_self}/../../lib-common.sh"

STATE_DIR="${CUBESTACK_SYNC_STATE:-/var/lib/cubestack-platform-sync}"
CONF=""
COLLECTIONS=""
ONLY=""
FORCE=0
PULL_STATE=1
PRUNE=0
SEAL=0
DRY=0
VERIFY_MINIO=0
PRINT_SYSTEMD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --state-dir) STATE_DIR="${2:?}"; shift 2 ;;
        --conf)      CONF="${2:?}"; shift 2 ;;
        --collection) COLLECTIONS="${COLLECTIONS} ${2//,/ }"; shift 2 ;;
        --only)      ONLY="${2:?}"; shift 2 ;;
        --force)     FORCE=1; shift ;;
        --no-pull-state) PULL_STATE=0; shift ;;
        --prune)     PRUNE=1; shift ;;
        --seal-missing) SEAL=1; shift ;;
        --dry-run)   DRY=1; shift ;;
        --verify-minio) VERIFY_MINIO=1; shift ;;   # 上传后逐个 tar 流式 sha256 比对本地↔MinIO
        --print-systemd) PRINT_SYSTEMD=1; shift ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done
[ -n "${CONF}" ] && { [ -f "${CONF}" ] || { err "配置文件不存在: ${CONF}"; exit 1; }; set -a; . "${CONF}"; set +a; }
COLLECTIONS="${COLLECTIONS:-${CUBESTACK_SYNC_COLLECTIONS:-cubestack-operator model-collection dev-lab}}"

MINIO_BUCKET="${MINIO_BUCKET:-cubestack-installer}"
MINIO_REMOTE_DIR="${MINIO_REMOTE_DIR:-offline-files}"
ALIAS="cubestack-sync"

if [ "${PRINT_SYSTEMD}" = "1" ]; then
    cat <<EOF
# ==== /etc/systemd/system/cubestack-platform-sync.service ====
[Unit]
Description=CubeStack image collections refresh (Harbor -> tars -> MinIO)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/cubestack-platform-sync.env
ExecStart=/usr/bin/bash ${_self}/cubestack-platform-sync.sh --state-dir ${STATE_DIR}

# ==== /etc/systemd/system/cubestack-platform-sync.timer ====
[Unit]
Description=Daily CubeStack image collections refresh

[Timer]
OnCalendar=*-*-* 03:37:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target

# ==== 使用 ====
#   1) 写 /etc/cubestack-platform-sync.env(权限 600):
#        MINIO_ENDPOINT=<http://minio-host:9000>
#        MINIO_ACCESS_KEY=...
#        MINIO_SECRET_KEY=...
#        HARBOR_MIRROR_USER=...
#        HARBOR_MIRROR_PASSWORD=...
#   2) systemctl daemon-reload && systemctl enable --now cubestack-platform-sync.timer
#   3) 手动验一把: bash ${_self}/cubestack-platform-sync.sh --conf /etc/cubestack-platform-sync.env
#   (默认覆盖全部集合; 单集合: --collection cubestack-operator 等)
EOF
    exit 0
fi

# ---------- 前置 ----------
for v in MINIO_ENDPOINT MINIO_ACCESS_KEY MINIO_SECRET_KEY; do
    [ -n "${!v:-}" ] || { err "缺少 ${v}(--conf 或环境变量)"; exit 1; }
done
command -v skopeo >/dev/null 2>&1 || { err "缺少 skopeo(apt-get install -y skopeo)"; exit 1; }

# mc: MC_BIN > PATH > 仓库内置(offline-files/os/mc-*)> 自动下载(aistor 官方地址, 2026-10 起)
MC="${MC_BIN:-}"
[ -n "${MC}" ] || MC="$(command -v mc || true)"
[ -n "${MC}" ] || MC="$(ls "${REPO_ROOT}"/deployments/offline-files/os/mc-*-linux-amd64 2>/dev/null | head -1 || true)"
if [ -z "${MC}" ]; then
    MC="${STATE_DIR}/bin/mc"
    if [ ! -x "${MC}" ]; then
        say "mc 未找到, 下载(aistor 官方地址)..."
        mkdir -p "$(dirname "${MC}")"
        curl -fsSL --retry 3 -o "${MC}.tmp" https://dl.min.io/aistor/mc/release/linux-amd64/mc \
            && chmod +x "${MC}.tmp" && mv "${MC}.tmp" "${MC}" \
            || { err "mc 下载失败; 可手动放置到 ${MC} 或设 MC_BIN"; exit 1; }
    fi
fi
say "  工具: skopeo=$(command -v skopeo)  mc=${MC}"

# mc 隔离配置(不碰用户 ~/.mc, 也不污染 offline-files 挂载)
export MC_CONFIG_DIR="${MC_CONFIG_DIR:-/tmp/.cubestack-platform-sync-mc}"
mkdir -p "${MC_CONFIG_DIR}"
"${MC}" alias set "${ALIAS}" "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null

# 本地产出清单计数(.tar 与 .tar.gz 都算; 排除隐藏目录)
_local_tarn() { find "$1" \( -name '*.tar' -o -name '*.tar.gz' \) -not -path '*/.*' 2>/dev/null | wc -l; }
# operator 集合 charts/ 下的 chart tgz(随镜像 tar 一起走); 其它集合为 0
_local_chartn() { find "$1" -maxdepth 1 -name '*.tgz' -not -path '*/.*' 2>/dev/null | wc -l; }

# ---------- operator chart 保鲜(仅 cubestack-operator 集合) ----------
# 源仍是 Harbor OCI; 落点改为离线包目录顶层, 与组件镜像 tar 同目录。
# digest 是 helm 报告的 OCI manifest digest(不是 tgz 的 sha256), 缺失即失败, 不猜。
_HELM_REGISTRY_TMP=""
_cleanup_helm_cfg() { [ -n "${_HELM_REGISTRY_TMP}" ] && rm -f "${_HELM_REGISTRY_TMP}" || true; }
trap _cleanup_helm_cfg EXIT
_sync_operator_chart() {   # <chart_dir>
    local dir="$1"
    local ref="${CUBESTACK_OPERATOR_CHART_REF:-oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart}"
    local ver="${CUBESTACK_OPERATOR_CHART_VERSION:-1.0.0-latest}"
    local name tgz dgfile host user pass tmpd out pulled rdig ldig
    mkdir -p "${dir}"
    name="$(basename "${ref}")"
    tgz="${dir}/${name}-${ver}.tgz"
    dgfile="${tgz}.digest"
    # 版本升级后旧文件名会留下; 只提示, 不隐式删除(避免误删历史资产)
    local _old
    for _old in "${dir}"/*-chart-*.tgz; do
        [ -f "${_old}" ] || continue
        [ "${_old}" = "${tgz}" ] && continue
        warn "  发现旧 chart 文件(未自动删除): $(basename "${_old}")"
    done

    command -v helm >/dev/null 2>&1 || { err "  缺少 helm(operator chart 保鲜需要): apt/离线安装后重跑"; return 1; }
    host="${ref#oci://}"; host="${host%%/*}"
    user="${CUBESTACK_OPERATOR_HARBOR_USER:-${HARBOR_MIRROR_USER:-}}"
    pass="${CUBESTACK_OPERATOR_HARBOR_PASSWORD:-${HARBOR_MIRROR_PASSWORD:-}}"
    if [ -n "${user}" ] && [ -n "${pass}" ]; then
        # 临时 registry config: 不覆盖用户的 helm 登录态, 凭据文件 600 且退出即删
        _HELM_REGISTRY_TMP="$(mktemp)"; chmod 600 "${_HELM_REGISTRY_TMP}"
        export HELM_REGISTRY_CONFIG="${_HELM_REGISTRY_TMP}"
        printf '%s' "${pass}" | helm registry login "${host}" -u "${user}" --password-stdin >/dev/null 2>&1 \
            || warn "  helm registry login ${host} 失败(检查凭据); 公共 chart 仍可拉取"
    fi

    # 与 State 同盘的临时目录: 拉取成功后用 mv 原子替换, 部署机不会读到半个 chart
    tmpd="$(mktemp -d "${dir}/.pull.XXXXXX")"
    if ! out="$(helm pull "${ref}" --version "${ver}" --destination "${tmpd}" 2>&1)"; then
        printf '%s\n' "${out}" | tail -3 | sed 's/^/    /' >&2
        rm -rf "${tmpd}"
        err "  chart 拉取失败: ${ref} --version ${ver}"
        return 1
    fi
    pulled="$(ls -1t "${tmpd}"/*.tgz 2>/dev/null | head -1 || true)"
    rdig="$(printf '%s\n' "${out}" | sed -n 's/^Digest:[[:space:]]*//p' | head -1)"
    if [ -z "${pulled}" ] || [ -z "${rdig}" ]; then
        [ -n "${pulled}" ] && [ -z "${rdig}" ] && err "  chart 未返回 Digest(无法确认版本身份, 不落盘)"
        [ -z "${pulled}" ] && err "  helm pull 未产出 tgz"
        rm -rf "${tmpd}"
        return 1
    fi
    ldig="$(cat "${dgfile}" 2>/dev/null || true)"
    if [ "${rdig}" = "${ldig}" ] && [ -f "${tgz}" ]; then
        say "  chart 未变化(${rdig:0:19}…), 跳过"
        rm -rf "${tmpd}"
        return 0
    fi
    if [ "${DRY}" = "1" ]; then
        say "  chart 有更新(dry-run, 不落盘): ${rdig:0:19}…"
        rm -rf "${tmpd}"
        return 0
    fi
    mv -f "${pulled}" "${tgz}"
    printf '%s' "${rdig}" > "${dgfile}.tmp" && mv -f "${dgfile}.tmp" "${dgfile}"
    rm -rf "${tmpd}"
    ok "  chart 已更新: $(basename "${tgz}")(${rdig:0:19}…)"
}

# ---------- 逐集合同步 ----------
declare -i RC=0
declare -a SUMMARY=()
for COL in ${COLLECTIONS}; do
    [ -n "${COL}" ] || continue
    say "════ 集合: ${COL} ════"
    STATE_SUB="${STATE_DIR}/offline-files/${COL}"
    REMOTE="${ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}/${COL}/"
    REPO_SUB="${REPO_ROOT}/deployments/offline-files/${COL}"
    LIST="${REPO_SUB}/image-list.tsv"
    mkdir -p "${STATE_SUB}"
    if [ ! -f "${LIST}" ]; then
        warn "  清单不存在: ${LIST}(跳过该集合)"
        SUMMARY+=("${COL}: 跳过(无清单)"); continue
    fi

    # ① 拉回现有边车(增量前提)
    if [ "${PULL_STATE}" = "1" ]; then
        say "[1/4] 从 MinIO 拉回现有 *.digest 边车(--exclude tars)..."
        _PULL_DRY=(); [ "${DRY}" = "1" ] && _PULL_DRY=(--dry-run)
        "${MC}" mirror --overwrite --exclude '*.tar' --exclude '*.tar.gz' ${_PULL_DRY[@]+"${_PULL_DRY[@]}"} \
            "${REMOTE}" "${STATE_SUB}/" 2>/dev/null || warn "  边车拉取失败(首次运行/前缀不存在? 继续全量)"
    fi

    # ② 保鲜(拉取+save; --seal-missing 仅补边车不重拉)
    say "[2/4] 逐镜像 digest 比对与保鲜..."
    SAVE_ARGS=(--list "${LIST}" --out "${STATE_SUB}")
    [ -n "${ONLY}" ] && SAVE_ARGS+=(--only "${ONLY}")
    [ "${FORCE}" = "1" ] && SAVE_ARGS+=(--force)
    [ "${SEAL}" = "1" ] && SAVE_ARGS+=(--seal-missing)
    [ "${DRY}" = "1" ] && SAVE_ARGS+=(--dry-run)
    SAVE_RC=0
    bash "${_self}/cubestack-platform-save-images.sh" "${SAVE_ARGS[@]}" || SAVE_RC=1
    # 镜像保鲜失败时不发布 chart/上传: 否则远端会短暂出现"新 chart + 旧/不全镜像"的错位。
    if [ "${SAVE_RC}" != "0" ]; then
        err "  镜像保鲜失败, 跳过 chart 刷新与上传, 保持远端集合不变"
        RC+=1; SUMMARY+=("${COL}: 失败(镜像保鲜)"); continue
    fi
    # README 保鲜(仓库里有就带上; ⚠ state-dir 即仓库目录时 源=目标, 必须跳过 —— cp 同文件会报错,
    #   set -e 下直接终止整轮同步(2026-10-16 实机踩到: 上传一步都没执行))
    _rm_src="${REPO_SUB}/README.md"
    if [ -f "${_rm_src}" ] && [ ! "${_rm_src}" -ef "${STATE_SUB}/README.md" ]; then
        cp -f "${_rm_src}" "${STATE_SUB}/README.md" || warn "  README 复制失败(不阻断): ${_rm_src}"
    fi
    _rm_charts="${REPO_SUB}/charts/README.md"
    if [ -f "${_rm_charts}" ] && [ ! "${_rm_charts}" -ef "${STATE_SUB}/charts/README.md" ]; then
        mkdir -p "${STATE_SUB}/charts"
        cp -f "${_rm_charts}" "${STATE_SUB}/charts/README.md" || warn "  charts/README 复制失败(不阻断): ${_rm_charts}"
    fi

    # ②b operator chart 保鲜(源=Harbor OCI, 落点=本集合 charts/; 失败则整集合不上传)
    if [ "${COL}" = "cubestack-operator" ]; then
        say "[2b/4] operator chart 保鲜(Harbor → 离线包 charts/)..."
        if ! _sync_operator_chart "${STATE_SUB}/charts"; then
            RC+=1; SUMMARY+=("${COL}: 失败(chart)"); continue
        fi
    fi

    # ③ 上传(防呆: --prune 且本地 0 个 tar ⇒ 拒绝, 防清空远端)
    L_PRE="$(_local_tarn "${STATE_SUB}")"
    L_PRE_C="$(_local_chartn "${STATE_SUB}/charts")"
    if [ "${L_PRE}" = "0" ]; then
        if [ "${PRUNE}" = "1" ]; then
            err "  集合 ${COL} 状态目录无任何 tar 且给了 --prune —— 拒绝上传(会清空远端)"
            err "    --state-dir 应指向**包含 offline-files/ 的根**; 先 --dry-run 核对"
            RC+=1; SUMMARY+=("${COL}: 失败(空目录+prune)"); continue
        fi
        warn "  集合 ${COL} 本地 0 个 tar, 跳过上传"
        SUMMARY+=("${COL}: 跳过(无本地 tar)"); continue
    fi
    say "[3/4] 上传到 MinIO: ${REMOTE}(本地 tar=${L_PRE} chart=${L_PRE_C})"
    UP_ARGS=(mirror --overwrite --exclude '.backup*' --exclude '.mc*' --exclude '.pull*')
    [ "${PRUNE}" = "1" ] && UP_ARGS+=(--remove)
    [ "${DRY}" = "1" ] && UP_ARGS+=(--dry-run)
    if ! "${MC}" "${UP_ARGS[@]}" "${STATE_SUB}/" "${REMOTE}"; then
        err "  mc mirror 上传失败(${COL})"; RC+=1; SUMMARY+=("${COL}: 失败(上传)"); continue
    fi

    # ④ 校验
    say "[4/4] 校验(本地/远端 tar + chart 数对照)..."
    L_N="$(_local_tarn "${STATE_SUB}")"
    L_C="$(_local_chartn "${STATE_SUB}/charts")"
    R_N="$("${MC}" ls -r "${REMOTE}" 2>/dev/null | command grep -v '/\.' | command grep -cE '\.tar(\.gz)?$' || true)"
    R_C="$("${MC}" ls -r "${REMOTE}" 2>/dev/null | command grep -v '/\.' | command grep -cE '\.tgz$' || true)"
    say "  本地 tar=${L_N} chart=${L_C}  远端 tar=${R_N} chart=${R_C}"
    _CHART_OK=1
    if [ "${COL}" = "cubestack-operator" ] && [ "${L_C}" != "${R_C}" ]; then _CHART_OK=0; fi
    if [ "${DRY}" = "1" ]; then
        SUMMARY+=("${COL}: dry-run")
    elif [ "${L_N}" = "${R_N}" ] && [ "${_CHART_OK}" = "1" ] && [ "${SAVE_RC}" = "0" ]; then
        SUMMARY+=("${COL}: OK(${L_N}${L_C:+,chart=$L_C})")
    else
        err "  集合 ${COL} 数量不一致或保鲜有失败(本地 tar ${L_N}/chart ${L_C} / 远端 tar ${R_N}/chart ${R_C}, save_rc=${SAVE_RC})"
        RC+=1; SUMMARY+=("${COL}: 失败(校验 ${L_N}+${L_C}/${R_N}+${R_C})")
    fi

    # ④b 可选: 逐文件流式 sha256 比对(本地 tar ↔ MinIO 对象) + .digest 边车比对。
    # 强一致校验; 会完整读一遍远端对象(大集合耗时/耗流量), 故默认关闭, `--verify-minio` 开启。
    # 与 --only 联动时只校验匹配的文件。
    if [ "${VERIFY_MINIO}" = "1" ] && [ "${DRY}" != "1" ]; then
        say "[4b/4] MinIO 内容校验(本地 tar/chart ↔ 远端 sha256; 仅匹配 --only)..."
        _vok=0; _vfail=0
        while IFS= read -r lf; do
            rel="${lf#"${STATE_SUB}"/}"
            if [ -n "${ONLY}" ]; then
                _hit=0
                for _o in ${ONLY//,/ }; do case "${rel}" in *"${_o}"*) _hit=1 ;; esac; done
                [ "${_hit}" = "1" ] || continue
            fi
            lsha="$(sha256sum "${lf}" | awk '{print $1}')"
            rsha="$("${MC}" cat "${REMOTE}${rel}" 2>/dev/null | sha256sum | awk '{print $1}' || true)"
            if [ -n "${rsha}" ] && [ "${lsha}" = "${rsha}" ]; then
                _vok=$((_vok+1))
            else
                err "  sha256 不一致/远端缺失: ${rel}(本地 ${lsha:0:16}… 远端 ${rsha:0:16}…)"
                _vfail=$((_vfail+1))
            fi
            if [ -f "${lf}.digest" ]; then
                ldig="$(cat "${lf}.digest" 2>/dev/null || true)"
                rdig="$("${MC}" cat "${REMOTE}${rel}.digest" 2>/dev/null || true)"
                if [ "${ldig}" != "${rdig}" ]; then
                    err "  .digest 不一致/远端缺失: ${rel}(本地=${ldig:0:19}… 远端=${rdig:0:19}…)"
                    _vfail=$((_vfail+1))
                fi
            fi
        done < <(find "${STATE_SUB}" -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' \) -not -path '*/.*' | sort)
        if [ "${_vfail}" = "0" ]; then
            ok "  MinIO 内容一致(${_vok} 个对象)"
        else
            err "  MinIO 内容校验失败(${_vfail} 处)"
            RC+=1; SUMMARY+=("${COL}: 失败(MinIO 内容 ${_vfail} 处)")
        fi
    fi
done

echo "════════════════════════════════"
say "汇总: ${SUMMARY[*]}"
if [ "${DRY}" = "1" ]; then
    ok "dry-run 完成(未实际上传)"
else
    [ "${RC}" = "0" ] && ok "全部集合同步完成" || { err "有 ${RC} 个集合未完成(见上)"; exit 1; }
fi
