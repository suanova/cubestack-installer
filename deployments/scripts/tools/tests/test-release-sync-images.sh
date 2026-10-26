#!/bin/bash
# ============================================================
# test-release-sync-images.sh — release-2.0 组件镜像原地刷新离线回归
# ------------------------------------------------------------
# 覆盖:
#   ① 新 tar: 上传 tar/digest, 更新 SHA256SUMS/release.json/_SUCCESS
#   ② 幂等 no-op
#   ③ 缺 _SUCCESS / _SUCCESS sha 不匹配 -> 失败
#   ④ _REFRESH_PENDING 恢复 / component 不一致
#   ⑤ 只刷新选中 component, 其他子目录字节不变
#   ⑥ --tag / source_repo / release.env 一致性
#   ⑦ chart / CLI / stale cleanup / dry-run / preflight / recover
#   ⑧ fetch --release 集成与刷新中提示
# 隔离: 临时 fake mc + fixture; 不访问 Harbor/MinIO/集群.
# 用法: bash deployments/scripts/tools/tests/test-release-sync-images.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SYNC="${REPO_ROOT}/deployments/scripts/tools/images/release-sync-images.sh"
FETCH="${REPO_ROOT}/deployments/scripts/tools/offline/fetch-offline-from-minio.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if printf '%s' "$3" | command grep -qF -- "$2"; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if printf '%s' "$3" | command grep -qF -- "$2"; then echo "  FAIL $1: 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }

# ---------------- fake mc ----------------
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/mc" <<'FAKE'
#!/bin/bash
set -uo pipefail
ALIAS="${FAKE_ALIAS:-cubestacksync}"
REMOTE="${FAKE_REMOTE:?}"
LOG="${FAKE_MC_LOG:-/dev/null}"
map() {
    local p="$1"
    case "$p" in
        "${ALIAS}"/*) p="${p#"${ALIAS}"/}" ;;
        minio/*) p="${p#minio/}" ;;
        *) printf '%s' "$p"; return 0 ;;
    esac
    printf '%s/%s' "${REMOTE}" "$p"
}
log() { printf '%s\n' "$*" >> "${LOG}"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --insecure|--quiet) shift ;;
        *) break ;;
    esac
done
cmd="${1:-}"; shift || true
case "${cmd}" in
    --version) echo "mc version FAKE";;
    alias) exit 0;;
    mb) exit 0;;
    ls)
        json=0
        [ "${1:-}" = "--json" ] && { json=1; shift; }
        p="$(map "${1:?}")"
        if [ -f "${p}" ]; then
            if [ "${json}" = "1" ]; then
                printf '{"status":"success","type":"file","key":"%s","size":%s}\n' "$(basename "${p}")" "$(stat -c %s "${p}")"
            else
                printf '0B STANDARD %s\n' "$(basename "${p}")"
            fi
        elif [ -d "${p}" ]; then
            for e in "${p}"/*; do
                [ -e "${e}" ] || continue
                if [ -d "${e}" ]; then
                    [ "${json}" = "1" ] && printf '{"status":"success","type":"dir","key":"%s/"}\n' "$(basename "${e}")" \
                        || printf '0B STANDARD %s/\n' "$(basename "${e}")"
                else
                    [ "${json}" = "1" ] && printf '{"status":"success","type":"file","key":"%s","size":%s}\n' "$(basename "${e}")" "$(stat -c %s "${e}")" \
                        || printf '0B STANDARD %s\n' "$(basename "${e}")"
                fi
            done
        else
            exit 1
        fi ;;
    stat)
        json=0
        [ "${1:-}" = "--json" ] && { json=1; shift; }
        p="$(map "${1:?}")"
        [ -e "${p}" ] || exit 1
        if [ "${json}" = "1" ]; then
            printf '{"status":"success","type":"file","key":"%s","size":%s}\n' "$(basename "${p}")" "$(stat -c %s "${p}")"
        else
            printf '%s\n' "$(basename "${p}")"
        fi ;;
    cat)
        cat "$(map "${1:?}")" ;;
    cp)
        rec=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --recursive) rec=1; shift ;;
                --overwrite|--preserve|--quiet) shift ;;
                --*) shift ;;
                *) break ;;
            esac
        done
        src="${1:?}"; dst="${2:?}"
        if [ -n "${FAKE_FAIL_CP_MATCH:-}" ] && printf '%s' "${dst}" | command grep -qF -- "${FAKE_FAIL_CP_MATCH}"; then
            log "cp-fail ${src} ${dst}"
            exit 1
        fi
        sm="$(map "${src}")"; dm="$(map "${dst}")"
        if [ "${rec}" = "1" ]; then
            mkdir -p "${dm}"; cp -a "${sm}"/. "${dm}"/
        else
            mkdir -p "$(dirname "${dm}")"; cp -a "${sm}" "${dm}"
        fi
        log "cp ${src} ${dst}" ;;
    rm)
        p="$(map "${1:?}")"
        rm -f "${p}"
        log "rm ${1}" ;;
    mirror)
        while [ $# -gt 0 ]; do case "$1" in --overwrite|--remove|--preserve) shift ;; *) break ;; esac; done
        sm="$(map "${1:?}")"; dm="$(map "${2:?}")"
        mkdir -p "${dm}"; cp -a "${sm}"/. "${dm}"/
        log "mirror ${1} ${2}" ;;
    *)
        echo "fake mc: unsupported ${cmd}" >&2; exit 1 ;;
esac
FAKE
chmod +x "${TMP}/bin/mc"
export PATH="${TMP}/bin:${PATH}"
export MC_BIN="${TMP}/bin/mc"
export FAKE_ALIAS="cubestacksync"
export FAKE_REMOTE="${TMP}/remote"
export FAKE_MC_LOG="${TMP}/mc.log"
export MINIO_ENDPOINT="http://fake" MINIO_ACCESS_KEY="x" MINIO_SECRET_KEY="y"
export MINIO_BUCKET="cubestack-installer" MINIO_INSECURE="false"
export HARBOR_MIRROR_REGISTRY="harbor.isuanova.com"
export HARBOR_MIRROR_USER="u" HARBOR_MIRROR_PASSWORD="p"
export SAVE_TLS_VERIFY="false"

REL="2.0.0"
REL_DIR="${TMP}/release"
REMOTE_ROOT="${FAKE_REMOTE}/cubestack-installer/${REL}"
REMOTE_OFF="${REMOTE_ROOT}/offline-files"
OP_REF="harbor.isuanova.com/suanova-private/cubestack-operator:v2.0.0-rc2"
BMC_REF="harbor.isuanova.com/suanova/bmc-oem-exporter:cd15d0ee"
CP_REF="harbor.isuanova.com/suanova/cubepilot-operator:v2.0.0-rc2"
UI_REF="harbor.isuanova.com/suanova/cubestack-ui:v2.0.0-rc2"
REDIS_REF="quay.io/opstree/redis:v7.0.15"
tar_name() { printf '%s' "$1" | sed 's#[/:]#_#g'; printf '.tar'; }
OP_TAR="$(tar_name "${OP_REF}")"
BMC_TAR="$(tar_name "${BMC_REF}")"
CP_TAR="$(tar_name "${CP_REF}")"
UI_TAR="$(tar_name "${UI_REF}")"
REDIS_TAR="$(tar_name "${REDIS_REF}")"
CHART_NAME="cubestack-operator-chart-2.0.0-rc2.tgz"
CHART_TGZ_CURRENT=""
CHART_DIGEST_CURRENT=""
CLI_TAR_CURRENT=""
CLI_DIGEST_CURRENT="sha256:old-cli"

make_chart() {   # <out.tgz> <version> <appversion>
    local out="$1" ver="$2" app="$3" d="${TMP}/chart-src"
    rm -rf "${d}"; mkdir -p "${d}/cubestack-operator"
    cat > "${d}/cubestack-operator/Chart.yaml" <<EOF
apiVersion: v2
name: cubestack-operator-chart
version: ${ver}
appVersion: ${app}
EOF
    tar -C "${d}" -czf "${out}" cubestack-operator
}

write_sums() {
    ( cd "${REMOTE_OFF}" && find . -type f ! -name SHA256SUMS ! -name _SUCCESS -print0 \
        | sort -z | xargs -0 sha256sum ) > "${REMOTE_OFF}/SHA256SUMS"
}
write_success() {
    local sha; sha="$(sha256sum "${REMOTE_OFF}/SHA256SUMS" | awk '{print $1}')"
    printf 'release=%s\nbuilt_at=2026-10-25T00:00:00Z\nsha256sums=%s\n' "${REL}" "${sha}" > "${REMOTE_OFF}/_SUCCESS"
}

build_fixture() {
    CHART_NAME="cubestack-operator-chart-2.0.0-rc2.tgz"
    rm -rf "${TMP}/remote" "${TMP}/src" "${TMP}/release" "${TMP}/local"
    mkdir -p "${REMOTE_OFF}/cubestack-operator/charts" "${REMOTE_OFF}/cubestack-operator/bmc" \
             "${REMOTE_OFF}/cubestack-operator/cubepilot" "${REMOTE_OFF}/cubestack-operator/portal" \
             "${TMP}/src/cubestack-operator" "${TMP}/src/charts" "${REL_DIR}"

    cat > "${REL_DIR}/release.env" <<'EOF'
RELEASE_VERSION=2.0.0
KUBESPRAY_VERSION=v2.32.0
KUBESPRAY_PROFILE=v2.32.0
CUBESTACK_OPERATOR_IMAGE_TAG=v2.0.0-rc2
CUBESTACK_OPERATOR_CHART_VERSION=2.0.0-rc2
CUBESTACK_OPERATOR_CHART_SYNC=offline
CUBESTACK_CLI_IMAGE=harbor.isuanova.com/suanova/cubestack-installer-cli:v2.0.0-rc2
DEV_LAB_CPU_TAG=py310-torch2.4-v2.0.0-rc2
DEV_LAB_MACA_TAG=3.9.0.12-py310-torch2.4-v2.0.0-rc2
DEV_LAB_CUDA_TAG=26.08-v2.0.0-rc2
RDMA_IMAGE_TAG=v1.5.4
MULTUS_IMAGE_TAG=v4.2.2-thick
NGINX_TAG=1.27
RELEASE_GROUPS="kubespray cubestack-operator"
EOF
    cp "${REL_DIR}/release.env" "${REMOTE_OFF}/release.env"

    cat > "${REL_DIR}/release-images.tsv" <<EOF
.	${OP_TAR}	${OP_REF}	${OP_REF}
bmc	${BMC_TAR}	${BMC_REF}	${BMC_REF}
cubepilot	${CP_TAR}	${CP_REF}	${CP_REF}
portal	${UI_TAR}	${UI_REF}	${UI_REF}
portal	${REDIS_TAR}	harbor.isuanova.com/mirrors/quay.io/opstree/redis:v7.0.15	${REDIS_REF}
EOF
    cat > "${REL_DIR}/components.tsv" <<'EOF'
publish	suanova/cubestack-operator	.	operator body
operator	suanova/cubestack-operator	.	alias
cubestack-operator	suanova/cubestack-operator	. bmc	meta
operator-chart	suanova/cubestack-operator	-	chart only
bmc	suanova/cubestack-operator	bmc	bmc
cubepilot	suanova/cubepilot	cubepilot	cubepilot
portal-image	suanova/cubestack	portal	portal
platform	-	. bmc cubepilot portal	first-party
cli	-	cli	CLI tar only
all	-	*	all
EOF

    # remote image tars (old)
    printf 'old-operator\n' > "${REMOTE_OFF}/cubestack-operator/${OP_TAR}"
    printf 'sha256:old-operator' > "${REMOTE_OFF}/cubestack-operator/${OP_TAR}.digest"
    printf 'old-bmc\n' > "${REMOTE_OFF}/cubestack-operator/bmc/${BMC_TAR}"
    printf 'sha256:old-bmc' > "${REMOTE_OFF}/cubestack-operator/bmc/${BMC_TAR}.digest"
    printf 'old-cubepilot\n' > "${REMOTE_OFF}/cubestack-operator/cubepilot/${CP_TAR}"
    printf 'sha256:old-cubepilot' > "${REMOTE_OFF}/cubestack-operator/cubepilot/${CP_TAR}.digest"
    printf 'old-ui\n' > "${REMOTE_OFF}/cubestack-operator/portal/${UI_TAR}"
    printf 'sha256:old-ui' > "${REMOTE_OFF}/cubestack-operator/portal/${UI_TAR}.digest"
    printf 'old-redis\n' > "${REMOTE_OFF}/cubestack-operator/portal/${REDIS_TAR}"
    printf 'sha256:old-redis' > "${REMOTE_OFF}/cubestack-operator/portal/${REDIS_TAR}.digest"
    printf 'readme\n' > "${REMOTE_OFF}/cubestack-operator/README.md"
    printf 'stale-rc\n' > "${REMOTE_OFF}/cubestack-operator/harbor.isuanova.com_suanova-private_cubestack-operator_v2.0.0-rc1.tar"
    printf 'sha256:stale-rc' > "${REMOTE_OFF}/cubestack-operator/harbor.isuanova.com_suanova-private_cubestack-operator_v2.0.0-rc1.tar.digest"

    # chart (old)
    make_chart "${REMOTE_OFF}/cubestack-operator/charts/${CHART_NAME}" "2.0.0-rc2" "v2.0.0-rc2"
    printf 'sha256:old-chart' > "${REMOTE_OFF}/cubestack-operator/charts/${CHART_NAME}.digest"

    # CLI tar + release.json
    printf 'old-cli\n' > "${REMOTE_ROOT}/cubestack-installer-cli-v2.0.0.tar"
    local cli_sha cli_size
    cli_sha="$(sha256sum "${REMOTE_ROOT}/cubestack-installer-cli-v2.0.0.tar" | awk '{print $1}')"
    cli_size="$(stat -c %s "${REMOTE_ROOT}/cubestack-installer-cli-v2.0.0.tar")"
    cat > "${REMOTE_OFF}/release.json" <<EOF
{
  "release": "2.0.0",
  "built_at": "2026-10-25T00:00:00Z",
  "operator_chart_version": "2.0.0-rc2",
  "cli_image": "harbor.isuanova.com/suanova/cubestack-installer-cli:v2.0.0-rc2",
  "cli_tar": "../cubestack-installer-cli-v2.0.0.tar",
  "cli_tar_sha256": "${cli_sha}",
  "cli_tar_size": ${cli_size}
}
EOF
    write_sums
    write_success

    # source: new operator tar same tag (digest drift), chart/CLI same
    printf 'new-operator\n' > "${TMP}/src/cubestack-operator/${OP_TAR}"
    printf 'sha256:new-operator' > "${TMP}/src/cubestack-operator/${OP_TAR}.digest"
    make_chart "${TMP}/src/charts/${CHART_NAME}" "2.0.0-rc2" "v2.0.0-rc2"
    printf 'sha256:old-chart' > "${TMP}/src/charts/${CHART_NAME}.digest"
    cp "${REMOTE_ROOT}/cubestack-installer-cli-v2.0.0.tar" "${TMP}/src/cli.tar"
    CHART_TGZ_CURRENT="${TMP}/src/charts/${CHART_NAME}"
    CHART_DIGEST_CURRENT="${TMP}/src/charts/${CHART_NAME}.digest"
    CLI_TAR_CURRENT="${TMP}/src/cli.tar"
    CLI_DIGEST_CURRENT="sha256:old-cli"
}
build_fixture

env_set() {
    python3 - "$REL_DIR/release.env" "$1" "$2" <<'PY'
import sys
path, key, val = sys.argv[1:]
lines = open(path, encoding="utf-8").read().splitlines()
out = []
for line in lines:
    s = line.strip()
    if s.startswith("export "):
        s = s[7:].lstrip()
    if s.startswith(key + "="):
        out.append(f"{key}={val}")
    else:
        out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
}
tvs_set_operator() {   # <tag>
    local tag="$1" ref="harbor.isuanova.com/suanova-private/cubestack-operator:${1}"
    local file; file="$(tar_name "${ref}")"
    python3 - "${REL_DIR}/release-images.tsv" "${file}" "${ref}" <<'PY'
import sys
path, file, ref = sys.argv[1:]
lines = open(path, encoding="utf-8").read().splitlines()
out = []
for line in lines:
    if line.startswith(".\t"):
        out.append(f".\t{file}\t{ref}\t{ref}")
    else:
        out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
}
make_cli_new() {   # <content> <digest>
    printf '%s\n' "$1" > "${TMP}/src/cli.tar"
    CLI_TAR_CURRENT="${TMP}/src/cli.tar"
    CLI_DIGEST_CURRENT="$2"
}
make_chart_new() {  # <version> <appversion> <digest>
    CHART_NAME="cubestack-operator-chart-$1.tgz"
    CHART_TGZ_CURRENT="${TMP}/src/charts/${CHART_NAME}"
    CHART_DIGEST_CURRENT="${CHART_TGZ_CURRENT}.digest"
    make_chart "${CHART_TGZ_CURRENT}" "$1" "$2"
    printf '%s' "$3" > "${CHART_DIGEST_CURRENT}"
}
remote_env_value() { sed -nE "s/^$1=//p" "${REMOTE_OFF}/release.env" | head -1; }

run_sync() {
    bash "${SYNC}" --release "${REL}" --release-dir "${REL_DIR}" \
        --source-dir "${TMP}/src" \
        --chart-tgz "${CHART_TGZ_CURRENT}" \
        --chart-digest "${CHART_DIGEST_CURRENT}" \
        --cli-tar "${CLI_TAR_CURRENT}" \
        --cli-image-digest "${CLI_DIGEST_CURRENT}" \
        --min-free-gb 0 --summary-file "${TMP}/summary.md" "$@" 2>&1
}
run_cli_sync() {
    bash "${SYNC}" --release "${REL}" --release-dir "${REL_DIR}" \
        --component cli \
        --cli-tar "${CLI_TAR_CURRENT}" \
        --cli-image-digest "${CLI_DIGEST_CURRENT}" \
        --min-free-gb 0 --summary-file "${TMP}/cli-summary.md" "$@" 2>&1
}

REMOTE_OP="${REMOTE_OFF}/cubestack-operator/${OP_TAR}"

echo "== ① 新 tar 上传 + 元数据 =="
: > "${FAKE_MC_LOG}"
out="$(run_sync --component publish)"; rc=$?
chk "退出码" "0" "${rc}"
chk_contains "summary 记录 operator" "operator" "${out}"
chk "远端 tar 已更新" "new-operator" "$(cat "${REMOTE_OP}" 2>/dev/null)"
chk "远端 digest 已更新" "sha256:new-operator" "$(cat "${REMOTE_OP}.digest" 2>/dev/null)"
( cd "${REMOTE_OFF}" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); chk "SHA256SUMS 校验" "0" "$?"
succ_sha="$(sha256sum "${REMOTE_OFF}/SHA256SUMS" | awk '{print $1}')"
chk " _SUCCESS sha256sums" "sha256sums=${succ_sha}" "$(sed -n 's/^sha256sums=//p' "${REMOTE_OFF}/_SUCCESS" | sed 's/^/sha256sums=/')"
chk "marker 已清理" "0" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"
chk "CLI 未变化" "old-cli" "$(cat "${REMOTE_ROOT}/cubestack-installer-cli-v2.0.0.tar" 2>/dev/null)"
chk "CLI 标记已补写" "sha256:old-cli" "$(cat "${REMOTE_ROOT}/_CLI_IMAGE_DIGEST" 2>/dev/null)"
last_cp="$(command grep '^cp ' "${FAKE_MC_LOG}" | command grep '/offline-files/' | tail -1)"
chk_contains "_SUCCESS 最后上传" "_SUCCESS" "${last_cp}"
chk "stale rc tar 已删除" "0" "$([ -e "${REMOTE_OFF}/cubestack-operator/harbor.isuanova.com_suanova-private_cubestack-operator_v2.0.0-rc1.tar" ] && echo 1 || echo 0)"
chk "README 保留" "readme" "$(cat "${REMOTE_OFF}/cubestack-operator/README.md" 2>/dev/null)"
chk "未选中 cubepilot 不变" "old-cubepilot" "$(cat "${REMOTE_OFF}/cubestack-operator/cubepilot/${CP_TAR}" 2>/dev/null)"
chk "CLI tar 不在 SHA256SUMS" "0" "$(command grep -cF 'cubestack-installer-cli-v2.0.0.tar' "${REMOTE_OFF}/SHA256SUMS" 2>/dev/null || true)"
chk "built_at 保留" "built_at=2026-10-25T00:00:00Z" "$(sed -n 's/^built_at=/built_at=/p' "${REMOTE_OFF}/_SUCCESS" | head -1)"

echo "== ② 幂等 no-op =="
: > "${FAKE_MC_LOG}"
out="$(run_sync --component publish)"; rc=$?
chk "退出码" "0" "${rc}"
chk "无 cp/rm" "0" "$(command grep -cE '^(cp|rm) ' "${FAKE_MC_LOG}" 2>/dev/null || true)"
chk "远端 tar 不变" "new-operator" "$(cat "${REMOTE_OP}" 2>/dev/null)"

echo "== ③ 缺 _SUCCESS =="
rm -f "${REMOTE_OFF}/_SUCCESS"
out="$(run_sync --component publish)"; rc=$?
chk "缺少 _SUCCESS 退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk_contains "提示 _SUCCESS" "_SUCCESS" "${out}"
chk "失败未写 marker" "0" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"
write_success

echo "== ④ marker 恢复 =="
printf '{"release":"2.0.0","component":"publish","subdirs":["."]}\n' > "${REMOTE_ROOT}/_REFRESH_PENDING"
rm -f "${REMOTE_OFF}/_SUCCESS"
out="$(run_sync --component publish)"; rc=$?
chk "恢复退出码" "0" "${rc}"
chk "恢复后 marker 清理" "0" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"
chk "恢复后 _SUCCESS 存在" "0" "$([ -e "${REMOTE_OFF}/_SUCCESS" ] && echo 0 || echo 1)"

echo "== ④b marker component 不一致 =="
printf '{"release":"2.0.0","component":"cubepilot","subdirs":["cubepilot"]}\n' > "${REMOTE_ROOT}/_REFRESH_PENDING"
out="$(run_sync --component publish)"; rc=$?
chk "不一致退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk "不一致保留 marker" "1" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"
rm -f "${REMOTE_ROOT}/_REFRESH_PENDING"
write_success

echo "== ⑤ tag/source_repo 校验 =="
out="$(run_sync --component publish --tag v9.9.9)"; rc=$?
chk "tag 不一致退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
out="$(run_sync --component publish --source-repo suanova/cubepilot)"; rc=$?
chk "source_repo 不一致退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"

echo "== ⑥ dry-run / preflight =="
: > "${FAKE_MC_LOG}"
out="$(run_sync --component publish --dry-run)"; rc=$?
chk "dry-run 退出码" "0" "${rc}"
chk "dry-run 无 cp/rm" "0" "$(command grep -cE '^(cp|rm) ' "${FAKE_MC_LOG}" 2>/dev/null || true)"
out="$(run_sync --component publish --preflight)"; rc=$?
chk "preflight 退出码" "0" "${rc}"

echo "== ⑦ 非法 SHA256SUMS 在 marker 前失败 =="
cp "${REMOTE_OFF}/SHA256SUMS" "${TMP}/sums.bak"
printf 'not-a-checksum\n' > "${REMOTE_OFF}/SHA256SUMS"
out="$(run_sync --component publish)"; rc=$?
chk "非法 sums 退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk "非法 sums 未写 marker" "0" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"
cp "${TMP}/sums.bak" "${REMOTE_OFF}/SHA256SUMS"
write_success

echo "== ⑧ fetch 集成 =="
bash "${FETCH}" --release "${REL}" --dest "${TMP}/local" --yes >/dev/null 2>&1
chk "fetch 退出码" "0" "$?"
bash "${FETCH}" --release "${REL}" --dest "${TMP}/local" --verify-only >/dev/null 2>&1
chk "fetch --verify-only 退出码" "0" "$?"

echo "== ⑨ fetch 刷新中提示 =="
rm -f "${REMOTE_OFF}/_SUCCESS"
printf '{"release":"2.0.0","component":"publish","subdirs":["."]}\n' > "${REMOTE_ROOT}/_REFRESH_PENDING"
out="$(bash "${FETCH}" --release "${REL}" --dest "${TMP}/local2" --yes 2>&1)"; rc=$?
chk "刷新中 fetch 非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk_contains "刷新中提示 marker" "_REFRESH_PENDING" "${out}"
rm -f "${REMOTE_ROOT}/_REFRESH_PENDING"
write_success

echo "== ⑩ 数据文件静态校验 =="
if [ -f "${REPO_ROOT}/deployments/releases/2.0.0/components.tsv" ]; then
    dup="$(command grep -vE '^[[:space:]]*#|^[[:space:]]*$' "${REPO_ROOT}/deployments/releases/2.0.0/components.tsv" \
        | awk -F'\t' '{print $1}' | sort | uniq -d)"
    chk "components.tsv alias 唯一" "" "${dup}"
    latest="$(command grep -vE '^[[:space:]]*#' "${REPO_ROOT}/deployments/releases/2.0.0/release-images.tsv" | command grep ':latest' || true)"
    chk "release-images.tsv 无 :latest" "" "${latest}"
else
    echo "  FAIL 缺少 deployments/releases/2.0.0/components.tsv"; fail=1
fi

echo "== ⑪ GA: rc2→v2.0.0 operator/chart/CLI/stale =="
build_fixture
GA_TAG="v2.0.0"
GA_REF="harbor.isuanova.com/suanova-private/cubestack-operator:${GA_TAG}"
GA_TAR="$(tar_name "${GA_REF}")"
env_set CUBESTACK_OPERATOR_IMAGE_TAG "${GA_TAG}"
env_set CUBESTACK_OPERATOR_CHART_VERSION "2.0.0"
env_set CUBESTACK_CLI_IMAGE "harbor.isuanova.com/suanova/cubestack-installer-cli:v2.0.0"
env_set DEV_LAB_CPU_TAG "py310-torch2.4-v2.0.0"
tvs_set_operator "${GA_TAG}"
printf 'ga-operator\n' > "${TMP}/src/cubestack-operator/${GA_TAR}"
printf 'sha256:ga-operator' > "${TMP}/src/cubestack-operator/${GA_TAR}.digest"
make_chart_new "2.0.0" "v2.0.0" "sha256:ga-chart"
make_cli_new "ga-cli" "sha256:ga-cli"
out="$(run_sync --component publish)"; rc=$?
chk "GA 退出码" "0" "${rc}"
chk "GA operator tar" "ga-operator" "$(cat "${REMOTE_OFF}/cubestack-operator/${GA_TAR}" 2>/dev/null)"
chk "旧 rc2 operator tar 已清理" "0" "$([ -e "${REMOTE_OFF}/cubestack-operator/${OP_TAR}" ] && echo 1 || echo 0)"
chk "GA release.env operator tag" "v2.0.0" "$(remote_env_value CUBESTACK_OPERATOR_IMAGE_TAG)"
chk "GA release.env chart" "2.0.0" "$(remote_env_value CUBESTACK_OPERATOR_CHART_VERSION)"
chk "GA release.env CLI" "harbor.isuanova.com/suanova/cubestack-installer-cli:v2.0.0" "$(remote_env_value CUBESTACK_CLI_IMAGE)"
chk "ignored DEV_LAB 保持旧值" "py310-torch2.4-v2.0.0-rc2" "$(remote_env_value DEV_LAB_CPU_TAG)"
chk "GA CLI tar" "ga-cli" "$(cat "${REMOTE_ROOT}/cubestack-installer-cli-v2.0.0.tar" 2>/dev/null)"
chk "GA CLI digest marker" "sha256:ga-cli" "$(cat "${REMOTE_ROOT}/_CLI_IMAGE_DIGEST" 2>/dev/null)"
( cd "${REMOTE_OFF}" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); chk "GA SHA256SUMS" "0" "$?"
chk "GA release.json chart" "2.0.0" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("operator_chart_version"))' "${REMOTE_OFF}/release.json" 2>/dev/null)"
chk "GA release.json cli" "harbor.isuanova.com/suanova/cubestack-installer-cli:v2.0.0" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cli_image"))' "${REMOTE_OFF}/release.json" 2>/dev/null)"
chk_contains "GA summary 记录 ignored" "out-of-scope" "${out}"
chk_contains "summary 文件写入" "images changed" "$(cat "${TMP}/summary.md" 2>/dev/null)"

echo "== ⑫ release.env 结构性变化拒绝 =="
build_fixture
env_set KUBESPRAY_VERSION "v9.9.9"
: > "${FAKE_MC_LOG}"
out="$(run_sync --component publish)"; rc=$?
chk "结构性变化退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk "结构性变化未写 marker" "0" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"
chk "结构性变化未上传" "0" "$(command grep -cE '^(cp|rm) ' "${FAKE_MC_LOG}" 2>/dev/null || true)"

echo "== ⑬ ignored env diff 不触发写入 =="
build_fixture
out="$(run_sync --component publish)"; chk "首次同步" "0" "$?"
env_set DEV_LAB_CPU_TAG "py310-torch2.4-v2.0.0"
: > "${FAKE_MC_LOG}"
out="$(run_sync --component publish)"; rc=$?
chk "ignored 退出码" "0" "${rc}"
chk "ignored 无 cp/rm" "0" "$(command grep -cE '^(cp|rm) ' "${FAKE_MC_LOG}" 2>/dev/null || true)"
chk "ignored 保持旧值" "py310-torch2.4-v2.0.0-rc2" "$(remote_env_value DEV_LAB_CPU_TAG)"
chk_contains "ignored 告警" "out-of-scope" "${out}"

echo "== ⑭ CLI 镜像变化 =="
build_fixture
run_sync --component publish >/dev/null 2>&1; chk "CLI 前置同步" "0" "$?"
env_set CUBESTACK_CLI_IMAGE "harbor.isuanova.com/suanova/cubestack-installer-cli:v2.0.0"
make_cli_new "ga-cli" "sha256:ga-cli"
out="$(run_sync --component publish)"; rc=$?
chk "CLI 退出码" "0" "${rc}"
chk "CLI tar 更新" "ga-cli" "$(cat "${REMOTE_ROOT}/cubestack-installer-cli-v2.0.0.tar" 2>/dev/null)"
chk "CLI release.env" "harbor.isuanova.com/suanova/cubestack-installer-cli:v2.0.0" "$(remote_env_value CUBESTACK_CLI_IMAGE)"
chk "CLI release.json sha" "$(sha256sum "${TMP}/src/cli.tar" | awk '{print $1}')" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cli_tar_sha256"))' "${REMOTE_OFF}/release.json" 2>/dev/null)"
( cd "${REMOTE_OFF}" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); chk "CLI sums" "0" "$?"

echo "== ⑮ CLI digest marker 变化(tag 不变) =="
make_cli_new "ga-cli2" "sha256:ga-cli2"
out="$(run_sync --component publish)"; rc=$?
chk "CLI digest 退出码" "0" "${rc}"
chk "CLI digest tar" "ga-cli2" "$(cat "${REMOTE_ROOT}/cubestack-installer-cli-v2.0.0.tar" 2>/dev/null)"
chk "CLI digest marker" "sha256:ga-cli2" "$(cat "${REMOTE_ROOT}/_CLI_IMAGE_DIGEST" 2>/dev/null)"

echo "== ⑮b cli-only: 只更新 CLI, 不动镜像/chart =="
build_fixture
run_sync --component publish >/dev/null 2>&1
before_op="$(sha256sum "${REMOTE_OFF}/cubestack-operator/${OP_TAR}" | awk '{print $1}')"
before_chart="$(sha256sum "${REMOTE_OFF}/cubestack-operator/charts/${CHART_NAME}" | awk '{print $1}')"
make_cli_new "cli-only-tar" "sha256:cli-only"
: > "${FAKE_MC_LOG}"
out="$(run_cli_sync)"; rc=$?
chk "cli-only 退出码" "0" "${rc}"
chk "cli-only tar" "cli-only-tar" "$(cat "${REMOTE_ROOT}/cubestack-installer-cli-v2.0.0.tar" 2>/dev/null)"
chk "cli-only release.json sha" "$(sha256sum "${TMP}/src/cli.tar" | awk '{print $1}')" \
    "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cli_tar_sha256"))' "${REMOTE_OFF}/release.json" 2>/dev/null)"
chk "cli-only release.json digest" "sha256:cli-only" \
    "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cli_image_digest"))' "${REMOTE_OFF}/release.json" 2>/dev/null)"
chk "cli-only marker" "sha256:cli-only" "$(cat "${REMOTE_ROOT}/_CLI_IMAGE_DIGEST" 2>/dev/null)"
chk "cli-only operator 未变" "${before_op}" "$(sha256sum "${REMOTE_OFF}/cubestack-operator/${OP_TAR}" | awk '{print $1}')"
chk "cli-only chart 未变" "${before_chart}" "$(sha256sum "${REMOTE_OFF}/cubestack-operator/charts/${CHART_NAME}" | awk '{print $1}')"
chk "cli-only 无镜像/chart cp" "0" "$(command grep -cE '^cp .*(cubestack-operator|charts)' "${FAKE_MC_LOG}" 2>/dev/null || true)"
( cd "${REMOTE_OFF}" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); chk "cli-only sums" "0" "$?"
chk "cli-only marker 清理" "0" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"
chk_contains "cli-only summary" "cli" "$(cat "${TMP}/cli-summary.md" 2>/dev/null)"

echo "== ⑮c cli-only 幂等 no-op =="
: > "${FAKE_MC_LOG}"
out="$(run_cli_sync)"; rc=$?
chk "cli-only no-op 退出码" "0" "${rc}"
chk "cli-only no-op 无 cp/rm" "0" "$(command grep -cE '^(cp|rm) ' "${FAKE_MC_LOG}" 2>/dev/null || true)"
chk_contains "cli-only no-op summary" "no-op" "${out}"

echo "== ⑮d cli-only 忽略 operator env diff + 参数校验 =="
build_fixture
make_cli_new "cli-only-env" "sha256:cli-only-env"
env_set CUBESTACK_OPERATOR_IMAGE_TAG "v9.9.9"
out="$(run_cli_sync)"; rc=$?
chk "cli-only 忽略 operator env diff 退出码" "0" "${rc}"
chk "cli-only operator env 保持旧值" "v2.0.0-rc2" "$(remote_env_value CUBESTACK_OPERATOR_IMAGE_TAG)"
chk "cli-only env tar" "cli-only-env" "$(cat "${REMOTE_ROOT}/cubestack-installer-cli-v2.0.0.tar" 2>/dev/null)"
out="$(bash "${SYNC}" --release "${REL}" --release-dir "${REL_DIR}" --component cli \
    --cli-image-digest "sha256:x" --min-free-gb 0 2>&1)"; rc=$?
chk "缺 cli-tar 退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk_contains "缺 cli-tar 提示" "--cli-tar" "${out}"
out="$(bash "${SYNC}" --release "${REL}" --release-dir "${REL_DIR}" --component cli \
    --cli-tar "${TMP}/src/cli.tar" --min-free-gb 0 2>&1)"; rc=$?
chk "缺 cli digest 退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk_contains "缺 cli digest 提示" "--cli-image-digest" "${out}"

echo "== ⑯ chart-only(operator-chart) =="
build_fixture
env_set CUBESTACK_OPERATOR_CHART_VERSION "2.0.0"
make_chart_new "2.0.0" "v2.0.0-rc2" "sha256:chart2"
out="$(run_sync --component operator-chart)"; rc=$?
chk "chart-only 退出码" "0" "${rc}"
chk "新 chart 存在" "0" "$([ -e "${REMOTE_OFF}/cubestack-operator/charts/${CHART_NAME}" ] && echo 0 || echo 1)"
chk "旧 chart 保留" "0" "$([ -e "${REMOTE_OFF}/cubestack-operator/charts/cubestack-operator-chart-2.0.0-rc2.tgz" ] && echo 0 || echo 1)"
chk "chart-only 不动 operator" "old-operator" "$(cat "${REMOTE_OFF}/cubestack-operator/${OP_TAR}" 2>/dev/null)"
chk "chart-only release.env" "2.0.0" "$(remote_env_value CUBESTACK_OPERATOR_CHART_VERSION)"
chk "chart-only release.json" "2.0.0" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("operator_chart_version"))' "${REMOTE_OFF}/release.json" 2>/dev/null)"

echo "== ⑰ first-party-only 不误删第三方 =="
build_fixture
mkdir -p "${TMP}/src/cubestack-operator/portal"
printf 'new-ui\n' > "${TMP}/src/cubestack-operator/portal/${UI_TAR}"
printf 'sha256:new-ui' > "${TMP}/src/cubestack-operator/portal/${UI_TAR}.digest"
out="$(run_sync --component portal-image --first-party-only)"; rc=$?
chk "first-party 退出码" "0" "${rc}"
chk "UI 更新" "new-ui" "$(cat "${REMOTE_OFF}/cubestack-operator/portal/${UI_TAR}" 2>/dev/null)"
chk "redis 保留" "old-redis" "$(cat "${REMOTE_OFF}/cubestack-operator/portal/${REDIS_TAR}" 2>/dev/null)"
( cd "${REMOTE_OFF}" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); chk "first-party sums" "0" "$?"

echo "== ⑱ keep-stale =="
build_fixture
out="$(run_sync --component publish --keep-stale)"; rc=$?
chk "keep-stale 退出码" "0" "${rc}"
chk "stale 保留" "0" "$([ -e "${REMOTE_OFF}/cubestack-operator/harbor.isuanova.com_suanova-private_cubestack-operator_v2.0.0-rc1.tar" ] && echo 0 || echo 1)"

echo "== ⑲ --recover =="
build_fixture
rm -f "${REMOTE_OFF}/_SUCCESS"
out="$(run_sync --component publish)"; rc=$?
chk "无 recover 失败" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
out="$(run_sync --component publish --recover)"; rc=$?
chk "recover 成功" "0" "${rc}"
chk "recover 后 _SUCCESS" "0" "$([ -e "${REMOTE_OFF}/_SUCCESS" ] && echo 0 || echo 1)"
chk "recover 后 marker 清理" "0" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"

echo "== ⑳ _SUCCESS 上传失败后恢复 =="
build_fixture
export FAKE_FAIL_CP_MATCH="offline-files/_SUCCESS"
out="$(run_sync --component publish)"; rc=$?
unset FAKE_FAIL_CP_MATCH
chk "失败注入退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk "失败注入 marker 保留" "1" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"
chk "失败注入 _SUCCESS 缺失" "1" "$([ -e "${REMOTE_OFF}/_SUCCESS" ] && echo 0 || echo 1)"
out="$(run_sync --component publish)"; rc=$?
chk "失败后重跑成功" "0" "${rc}"
chk "重跑 marker 清理" "0" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"
chk "重跑 _SUCCESS 存在" "0" "$([ -e "${REMOTE_OFF}/_SUCCESS" ] && echo 0 || echo 1)"

echo "== ㉑b SHA256SUMS 上传失败后恢复(env/json/stale 半套) =="
build_fixture
export FAKE_FAIL_CP_MATCH="offline-files/SHA256SUMS"
out="$(run_sync --component publish)"; rc=$?
unset FAKE_FAIL_CP_MATCH
chk "sums 失败退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk "sums 失败 marker 保留" "1" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"
chk "sums 失败 _SUCCESS 缺失" "1" "$([ -e "${REMOTE_OFF}/_SUCCESS" ] && echo 0 || echo 1)"
out="$(run_sync --component publish)"; rc=$?
chk "sums 失败重跑成功" "0" "${rc}"
chk "sums 重跑 marker 清理" "0" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"
( cd "${REMOTE_OFF}" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); chk "sums 重跑校验" "0" "$?"
chk "sums 重跑 _SUCCESS" "0" "$([ -e "${REMOTE_OFF}/_SUCCESS" ] && echo 0 || echo 1)"

echo "== ㉑ malformed release.json =="
build_fixture
printf '{bad json\n' > "${REMOTE_OFF}/release.json"
out="$(run_sync --component publish)"; rc=$?
chk "malformed json 退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk "malformed json 未写 marker" "0" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"

echo "== ㉒ release 数据: subdir 覆盖 =="
python3 - "${REPO_ROOT}/deployments/releases/2.0.0/components.tsv" \
    "${REPO_ROOT}/deployments/releases/2.0.0/release-images.tsv" <<'PY'
import sys
comp, tvs = sys.argv[1:]
subs = set()
for line in open(tvs, encoding="utf-8"):
    if line.strip() and not line.lstrip().startswith("#"):
        subs.add(line.split("\t")[0] or ".")
bad = []
for line in open(comp, encoding="utf-8"):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    parts = line.split("\t")
    for d in parts[2].split():
        if d not in ("-", "*", "cli") and d not in subs:
            bad.append(d)
print("\n".join(sorted(set(bad))))
PY
chk "components.tsv subdir 都存在于 release-images.tsv" "" "$(python3 - "${REPO_ROOT}/deployments/releases/2.0.0/components.tsv" "${REPO_ROOT}/deployments/releases/2.0.0/release-images.tsv" <<'PY'
import sys
comp, tvs = sys.argv[1:]
subs = set()
for line in open(tvs, encoding="utf-8"):
    if line.strip() and not line.lstrip().startswith("#"):
        subs.add(line.split("\t")[0] or ".")
bad = []
for line in open(comp, encoding="utf-8"):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    parts = line.split("\t")
    for d in parts[2].split():
        if d not in ("-", "*", "cli") and d not in subs:
            bad.append(d)
print("\n".join(sorted(set(bad))))
PY
)"

echo "== ㉓ _SUCCESS sha 不匹配 =="
build_fixture
printf 'release=2.0.0\nbuilt_at=2026-10-25T00:00:00Z\nsha256sums=%064d\n' 0 > "${REMOTE_OFF}/_SUCCESS"
out="$(run_sync --component publish)"; rc=$?
chk "_SUCCESS sha 不一致退出码非 0" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
chk "_SUCCESS sha 不一致未写 marker" "0" "$([ -e "${REMOTE_ROOT}/_REFRESH_PENDING" ] && echo 1 || echo 0)"

echo "== ㉔ 无变化首次只补 CLI digest marker =="
build_fixture
cp "${REMOTE_OFF}/cubestack-operator/${OP_TAR}" "${TMP}/src/cubestack-operator/${OP_TAR}"
cp "${REMOTE_OFF}/cubestack-operator/${OP_TAR}.digest" "${TMP}/src/cubestack-operator/${OP_TAR}.digest"
before="$(sha256sum "${REMOTE_OFF}/SHA256SUMS" | awk '{print $1}')"
: > "${FAKE_MC_LOG}"
out="$(run_sync --component publish --keep-stale)"; rc=$?
chk "no-op 退出码" "0" "${rc}"
chk "no-op 未改 sums" "${before}" "$(sha256sum "${REMOTE_OFF}/SHA256SUMS" | awk '{print $1}')"
chk "no-op 未改发布树文件" "0" "$(command grep -c '^cp .*offline-files/' "${FAKE_MC_LOG}" 2>/dev/null || true)"
chk "no-op 补写 CLI marker" "sha256:old-cli" "$(cat "${REMOTE_ROOT}/_CLI_IMAGE_DIGEST" 2>/dev/null)"

echo "== ㉕ --force 只重传 selected =="
build_fixture
run_sync --component publish >/dev/null 2>&1
printf 'force-operator\n' > "${TMP}/src/cubestack-operator/${OP_TAR}"
printf 'sha256:force-operator' > "${TMP}/src/cubestack-operator/${OP_TAR}.digest"
out="$(run_sync --component publish --force)"; rc=$?
chk "force 退出码" "0" "${rc}"
chk "force 更新 selected" "force-operator" "$(cat "${REMOTE_OFF}/cubestack-operator/${OP_TAR}" 2>/dev/null)"
chk "force 不动未选中" "old-cubepilot" "$(cat "${REMOTE_OFF}/cubestack-operator/cubepilot/${CP_TAR}" 2>/dev/null)"
( cd "${REMOTE_OFF}" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); chk "force sums" "0" "$?"

echo "== ㉖ all 通配 + bmc commit tag =="
build_fixture
mkdir -p "${TMP}/src/cubestack-operator/bmc" "${TMP}/src/cubestack-operator/cubepilot" \
         "${TMP}/src/cubestack-operator/portal"
printf 'new-bmc\n' > "${TMP}/src/cubestack-operator/bmc/${BMC_TAR}"
printf 'sha256:new-bmc' > "${TMP}/src/cubestack-operator/bmc/${BMC_TAR}.digest"
printf 'new-cubepilot\n' > "${TMP}/src/cubestack-operator/cubepilot/${CP_TAR}"
printf 'sha256:new-cubepilot' > "${TMP}/src/cubestack-operator/cubepilot/${CP_TAR}.digest"
printf 'new-ui\n' > "${TMP}/src/cubestack-operator/portal/${UI_TAR}"
printf 'sha256:new-ui' > "${TMP}/src/cubestack-operator/portal/${UI_TAR}.digest"
printf 'new-redis\n' > "${TMP}/src/cubestack-operator/portal/${REDIS_TAR}"
printf 'sha256:new-redis' > "${TMP}/src/cubestack-operator/portal/${REDIS_TAR}.digest"
out="$(run_sync --component all --tag v2.0.0-rc2)"; rc=$?
chk "all 退出码" "0" "${rc}"
chk "all bmc" "new-bmc" "$(cat "${REMOTE_OFF}/cubestack-operator/bmc/${BMC_TAR}" 2>/dev/null)"
chk "all cubepilot" "new-cubepilot" "$(cat "${REMOTE_OFF}/cubestack-operator/cubepilot/${CP_TAR}" 2>/dev/null)"
chk "all redis(第三方)" "new-redis" "$(cat "${REMOTE_OFF}/cubestack-operator/portal/${REDIS_TAR}" 2>/dev/null)"
( cd "${REMOTE_OFF}" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); chk "all sums" "0" "$?"

echo "== ㉗ tag/source_repo 匹配时通过 =="
build_fixture
out="$(run_sync --component publish --tag v2.0.0-rc2 --source-repo suanova/cubestack-operator)"; rc=$?
chk "tag/source 匹配退出码" "0" "${rc}"

echo "== ㉘ release 数据: . 行 tag 与 env 一致 =="
chk ". 行 tag" "$(sed -nE 's/^CUBESTACK_OPERATOR_IMAGE_TAG=//p' "${REPO_ROOT}/deployments/releases/2.0.0/release.env")" "$(python3 - "${REPO_ROOT}/deployments/releases/2.0.0/release-images.tsv" <<'PY'
import sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith(".\t"):
        ref = line.rstrip("\n").split("\t")[3]
        print(ref.rsplit(":", 1)[1] if ":" in ref else "")
        break
PY
)"

echo "== ㉙ workflow 静态契约 =="
WF="${REPO_ROOT}/.github/workflows/sync-release-2.0-images.yml"
CLI_WF="${REPO_ROOT}/.github/workflows/rebuild-cli-image.yml"
chk "workflow 存在" "0" "$([ -f "${WF}" ] && echo 0 || echo 1)"
chk_contains "dispatch 事件" "release-2.0-updated" "$(cat "${WF}" 2>/dev/null)"
chk "sync workflow 无 workflow_run 触发" "0" "$(command grep -cE '^[[:space:]]*workflow_run:' "${WF}" 2>/dev/null || true)"
chk "不含 push 触发" "0" "$(command grep -cE '^[[:space:]]*push:' "${WF}" 2>/dev/null || true)"
chk_contains "checkout ref" "CHECKOUT_REF" "$(cat "${WF}" 2>/dev/null)"
chk "CLI rebuild workflow 存在" "0" "$([ -f "${CLI_WF}" ] && echo 0 || echo 1)"
chk_contains "release CLI 同 job 内同步" "--component cli" "$(cat "${CLI_WF}" 2>/dev/null)"
chk_contains "release CLI tar 导出" "cubestack-installer-cli-v" "$(cat "${CLI_WF}" 2>/dev/null)"
chk_contains "release CLI 一致性断言" "--cli-image-digest" "$(cat "${CLI_WF}" 2>/dev/null)"

echo ""
if [ "${fail}" = "0" ]; then echo "✅ test-release-sync-images: 全部通过"; else echo "❌ test-release-sync-images: 有失败"; fi
exit "${fail}"
