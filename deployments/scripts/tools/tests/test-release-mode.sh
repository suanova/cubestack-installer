#!/bin/bash
# ============================================================
# test-release-mode.sh — release 模式离线回归(无需 MinIO/Harbor/集群)
# 覆盖:
#   ① load_config: CUBESTACK_RELEASE 派生 OFFLINE_FILES_ROOT + 11 个目录变量
#   ② 缺少 release.env 时硬失败(退出码 1)
#   ②b CUBESTACK_RELEASE 格式校验(拒绝 ../、绝对路径、空白/元字符; 不误杀合法版本名)
#   ③ fetch-offline-from-minio.sh --release: 下载布局/SHA256SUMS/带版本 CLI tar 校验
#   ④ --verify-only 通过; 篡改文件后失败
#   ⑤ --list-releases 输出可用版本
#   ⑤b 旧布局(无版本名 CLI tar)向后兼容
#   ⑥ release 定义静态约束(无 :latest)
# 隔离: 临时 CLUSTER_CONF + 假 mc(纯离线)
# 用法: bash deployments/scripts/tools/tests/test-release-mode.sh
# ============================================================
# 刻意不开 -e: 预期失败的场景用 rc=$? 捕获并由 chk/fail 汇总; 开 -e 会让首个失败
# 直接退出、吞掉汇总(2026-10-23 CodeRabbit)。全部 set +e / set -e 切换已移除。
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
FETCH="${REPO_ROOT}/deployments/scripts/tools/offline/fetch-offline-from-minio.sh"
PUBLISH="${REPO_ROOT}/deployments/scripts/tools/images/release-publish.sh"
REL_ENV="${REPO_ROOT}/deployments/releases/2.0.0/release.env"
REL_TSV="${REPO_ROOT}/deployments/releases/2.0.0/release-images.tsv"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if printf '%s' "$3" | command grep -qF -- "$2"; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

# ---------------- ① / ② load_config ----------------
cat > "${TMP}/cluster.conf" <<'EOF'
NODES=()
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF
mkdir -p "${TMP}/rel/9.9.9/offline-files"
cat > "${TMP}/rel/9.9.9/offline-files/release.env" <<'EOF'
RELEASE_VERSION=9.9.9
KUBESPRAY_VERSION=v2.32.0
EOF

echo "== ① load_config release 模式 =="
out="$(CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE=9.9.9 CUBESTACK_RELEASE_ROOT="${TMP}/rel" \
    bash -c 'source "$1"; load_config; printf "%s\n" "$OFFLINE_FILES_ROOT" "$CUBESTACK_OPERATOR_OFFLINE_DIR" "$DEV_LAB_SAVE_DIR" "$MODEL_IMAGES_SAVE_DIR" "$CEPH_IMAGE_DIR" "$NETSHOOT_BASE_TAR"' _ "${LIB}" 2>/dev/null)"
chk "release OFFLINE_FILES_ROOT" "${TMP}/rel/9.9.9/offline-files" "$(printf '%s\n' "${out}" | sed -n '1p')"
chk "operator 目录重定向" "${TMP}/rel/9.9.9/offline-files/cubestack-operator" "$(printf '%s\n' "${out}" | sed -n '2p')"
chk "dev-lab 目录重定向" "${TMP}/rel/9.9.9/offline-files/dev-lab" "$(printf '%s\n' "${out}" | sed -n '3p')"
chk "model-collection 目录重定向" "${TMP}/rel/9.9.9/offline-files/model-collection" "$(printf '%s\n' "${out}" | sed -n '4p')"
chk "ceph 镜像目录重定向" "${TMP}/rel/9.9.9/offline-files/kubespray/v2.32.0/images" "$(printf '%s\n' "${out}" | sed -n '5p')"
chk "netshoot 回退 tar 重定向" "${TMP}/rel/9.9.9/offline-files/os/netshoot.tar" "$(printf '%s\n' "${out}" | sed -n '6p')"

echo "== ①b release flat 模式(发布定义在 repo, 资产平铺 offline-files) =="
mkdir -p "${TMP}/flat"
out="$(CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE=2.0.0 CUBESTACK_RELEASE_LAYOUT=flat \
    OFFLINE_FILES_ROOT="${TMP}/flat" \
    bash -c 'source "$1"; load_config; printf "%s\n" "$OFFLINE_FILES_ROOT" "$CUBESTACK_OPERATOR_OFFLINE_DIR" "$CEPH_IMAGE_DIR" "$CUBESTACK_OPERATOR_CHART_VERSION" "$CUBESTACK_RELEASE_ROOT"' _ "${LIB}" 2>/dev/null)"
chk "flat OFFLINE_FILES_ROOT" "${TMP}/flat" "$(printf '%s\n' "${out}" | sed -n '1p')"
chk "flat operator 目录" "${TMP}/flat/cubestack-operator" "$(printf '%s\n' "${out}" | sed -n '2p')"
chk "flat ceph 镜像目录" "${TMP}/flat/kubespray/v2.32.0/images" "$(printf '%s\n' "${out}" | sed -n '3p')"
_flat_chart="$(sed -nE 's/^CUBESTACK_OPERATOR_CHART_VERSION=//p' "${REPO_ROOT}/deployments/releases/2.0.0/release.env" | head -1)"
chk "flat release.env chart 覆盖" "${_flat_chart}" "$(printf '%s\n' "${out}" | sed -n '4p')"
chk "flat 不保留 version tree root" "" "$(printf '%s\n' "${out}" | sed -n '5p')"

echo "== ② 缺少 release.env =="
mkdir -p "${TMP}/rel/9.9.8/offline-files"
CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE=9.9.8 CUBESTACK_RELEASE_ROOT="${TMP}/rel" \
    bash -c 'source "$1"; load_config' _ "${LIB}" >/dev/null 2>&1
rc=$?
chk "缺少 release.env 退出码" "1" "${rc}"

echo "== ②b CUBESTACK_RELEASE 格式校验(路径穿越/非法字符) =="
# 反证: 不做格式校验时 '../decoy' 会让 _rel_root 落到 ${TMP}/decoy/offline-files,
# source 其中的 release.env 会执行 touch(任意脚本执行)。校验必须在此前退出。
mkdir -p "${TMP}/decoy/offline-files"
{
    printf 'touch "%s"\n' "${TMP}/pwned"
    printf 'RELEASE_VERSION=../decoy\nKUBESPRAY_VERSION=v2.32.0\n'
} > "${TMP}/decoy/offline-files/release.env"
CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE='../decoy' CUBESTACK_RELEASE_ROOT="${TMP}/rel" \
    bash -c 'source "$1"; load_config' _ "${LIB}" >/dev/null 2>&1
rc=$?
chk "路径穿越值退出码 1" "1" "${rc}"
chk "路径穿越值未 source 外部 release.env" "0" "$([ -e "${TMP}/pwned" ] && echo 1 || echo 0)"
for bad in '..' '.' '/abs' 'a/b' 'a b' 'a;b' 'a$b' '-rc1'; do
    CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE="${bad}" CUBESTACK_RELEASE_ROOT="${TMP}/rel" \
        bash -c 'source "$1"; load_config' _ "${LIB}" >/dev/null 2>&1
    rc=$?
    chk "拒绝非法 release: ${bad}" "1" "${rc}"
done
# 合法值只被"缺少 release.env"分支拦下(格式校验不误杀合法版本名):
CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE='2.0.0-rc1' CUBESTACK_RELEASE_ROOT="${TMP}/rel" \
    bash -c 'source "$1"; load_config' _ "${LIB}" >"${TMP}/legal.out" 2>&1
rc=$?
chk "合法 release 名未被格式校验拦截" "1" "${rc}"
chk_contains "合法值进入 release.env 缺失分支" "未找到发布版本" "$(cat "${TMP}/legal.out")"

# ---------------- ③~⑤ fetch --release(假 mc + 假远端) ----------------
echo "== ③~⑤ fetch --release =="
mkdir -p "${TMP}/bin" "${TMP}/remote/cubestack-installer/offline-files" \
         "${TMP}/remote/cubestack-installer/2.0.0/offline-files/ceph" "${TMP}/local"
printf 'keep\n' > "${TMP}/remote/cubestack-installer/offline-files/keep"
printf 'hello\n' > "${TMP}/remote/cubestack-installer/2.0.0/offline-files/ceph/test.txt"
printf 'RELEASE_VERSION=2.0.0\n' > "${TMP}/remote/cubestack-installer/2.0.0/offline-files/release.env"
: > "${TMP}/remote/cubestack-installer/2.0.0/offline-files/_SUCCESS"
printf 'cli-tar-bytes\n' > "${TMP}/remote/cubestack-installer/2.0.0/cubestack-installer-cli-v2.0.0.tar"
cli_sha="$(sha256sum "${TMP}/remote/cubestack-installer/2.0.0/cubestack-installer-cli-v2.0.0.tar" | awk '{print $1}')"
printf '{"cli_tar":"../cubestack-installer-cli-v2.0.0.tar","cli_tar_sha256":"%s"}\n' "${cli_sha}" > "${TMP}/remote/cubestack-installer/2.0.0/offline-files/release.json"
( cd "${TMP}/remote/cubestack-installer/2.0.0/offline-files" && sha256sum ./ceph/test.txt ./release.env ./release.json > SHA256SUMS )

cat > "${TMP}/bin/mc" <<'FAKE'
#!/bin/bash
set -uo pipefail
REMOTE="${FAKE_REMOTE:?}"
p() { local a="$1"; a="${a#minio/cubestack-installer}"; a="${a#/}"; printf '%s' "${REMOTE}/cubestack-installer/${a}"; }
cmd="${1:-}"; shift || true
case "${cmd}" in
    --version) echo "mc version FAKE";;
    alias) exit 0;;
    ls)
        d="$(p "${1:?}")"
        if [ -f "${d}" ]; then echo "0B STANDARD $(basename "${d}")"
        elif [ -d "${d}" ]; then
            for e in "${d}"/*; do [ -e "${e}" ] || continue
                if [ -d "${e}" ]; then echo "0B STANDARD $(basename "${e}")/"
                else echo "0B STANDARD $(basename "${e}")"; fi
            done
        fi ;;
    du)
        d="$(p "${1:?}")"; [ -e "${d}" ] || exit 0
        printf '%s\t1\t%s\n' "$(du -sh "${d}" 2>/dev/null | awk '{print $1}')" "${1}" ;;
    mirror)
        while [ $# -gt 0 ]; do case "$1" in --overwrite) shift ;; *) break ;; esac; done
        _src="$1"; _dst="$2"
        case "$_src" in minio/*) _src="$(p "$_src")" ;; esac
        case "$_dst" in minio/*) _dst="$(p "$_dst")" ;; esac
        mkdir -p "${_dst}"; cp -a "${_src}"/. "${_dst}"/ ;;
    cp)
        _rec=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --recursive) _rec=1; shift ;;
                --*) shift ;;
                *) break ;;
            esac
        done
        [ "${_rec}" = "1" ] && printf 'cp-recursive %s\n' "${1:-}" >> "${FAKE_MC_LOG:-/dev/null}"
        _src="$1"; _dst="$2"
        case "$_src" in minio/*) _src="$(p "$_src")" ;; esac
        case "$_dst" in minio/*) _dst="$(p "$_dst")" ;; esac
        if [ "${_rec}" = "1" ]; then
            mkdir -p "${_dst}"; cp -a "${_src}"/. "${_dst}"/
        else
            mkdir -p "$(dirname "${_dst}")"; cp -a "${_src}" "${_dst}"
        fi ;;
    cat) cat "$(p "${1:?}")" ;;
    *) echo "fake mc: unsupported ${cmd}" >&2; exit 1 ;;
esac
FAKE
chmod +x "${TMP}/bin/mc"
export PATH="${TMP}/bin:${PATH}"
export FAKE_REMOTE="${TMP}/remote"
export MINIO_ENDPOINT="http://fake" MINIO_ACCESS_KEY="x" MINIO_SECRET_KEY="y"
export FAKE_MC_LOG="${TMP}/mc-calls.log"

bash "${FETCH}" --release 2.0.0 --dest "${TMP}/local" --yes >/dev/null 2>&1
chk "fetch --release 退出码" "0" "$?"
chk "发布树落盘" "hello" "$(cat "${TMP}/local/2.0.0/offline-files/ceph/test.txt" 2>/dev/null)"
chk "CLI tar 落盘(带版本名)" "cli-tar-bytes" "$(cat "${TMP}/local/2.0.0/cubestack-installer-cli-v2.0.0.tar" 2>/dev/null)"
chk "不再生成旧名 CLI tar" "0" "$([ -e "${TMP}/local/2.0.0/cubestack-installer-cli.tar" ] && echo 1 || echo 0)"
chk_contains "release 取件使用 mc cp --recursive" "cp-recursive" "$(cat "${TMP}/mc-calls.log" 2>/dev/null)"

bash "${FETCH}" --release 2.0.0 --verify-only --dest "${TMP}/local" >/dev/null 2>&1
chk "verify-only 通过" "0" "$?"
# --verify-only 不下载任何文件, 不应做"下载需要多少空间"的预检(否则在小盘上误报)
out="$(WARN_NEED_GB=999999 bash "${FETCH}" --release 2.0.0 --verify-only --dest "${TMP}/local" 2>&1)"
rc=$?
chk "verify-only 跳过空间预检退出码" "0" "${rc}"
chk_contains "verify-only 提示跳过空间预检" "跳过下载磁盘空间预检" "${out}"
printf 'tampered\n' >> "${TMP}/local/2.0.0/offline-files/ceph/test.txt"
bash "${FETCH}" --release 2.0.0 --verify-only --dest "${TMP}/local" >/dev/null 2>&1
rc=$?
chk "篡改后 verify-only 失败" "1" "${rc}"

out="$(bash "${FETCH}" --list-releases 2>/dev/null)"
chk_contains "list-releases 输出版本" "2.0.0" "${out}"

# ---------------- ⑤b 旧布局(无版本名 CLI tar)向后兼容 ----------------
echo "== ⑤b 旧布局 CLI tar 兼容 =="
mkdir -p "${TMP}/remote/cubestack-installer/1.9.9/offline-files/ceph"
printf 'legacy\n' > "${TMP}/remote/cubestack-installer/1.9.9/offline-files/ceph/test.txt"
printf 'RELEASE_VERSION=1.9.9\n' > "${TMP}/remote/cubestack-installer/1.9.9/offline-files/release.env"
: > "${TMP}/remote/cubestack-installer/1.9.9/offline-files/_SUCCESS"
printf 'legacy-cli\n' > "${TMP}/remote/cubestack-installer/1.9.9/cubestack-installer-cli.tar"
legacy_sha="$(sha256sum "${TMP}/remote/cubestack-installer/1.9.9/cubestack-installer-cli.tar" | awk '{print $1}')"
printf '{"cli_tar":"../cubestack-installer-cli.tar","cli_tar_sha256":"%s"}\n' "${legacy_sha}" \
    > "${TMP}/remote/cubestack-installer/1.9.9/offline-files/release.json"
( cd "${TMP}/remote/cubestack-installer/1.9.9/offline-files" \
    && sha256sum ./ceph/test.txt ./release.env ./release.json > SHA256SUMS )

bash "${FETCH}" --release 1.9.9 --dest "${TMP}/local-legacy" --yes >/dev/null 2>&1
chk "旧布局 fetch 退出码" "0" "$?"
chk "旧布局 CLI tar 落盘" "legacy-cli" "$(cat "${TMP}/local-legacy/1.9.9/cubestack-installer-cli.tar" 2>/dev/null)"
bash "${FETCH}" --release 1.9.9 --verify-only --dest "${TMP}/local-legacy" >/dev/null 2>&1
chk "旧布局 verify-only 通过" "0" "$?"

# ---------------- ⑥ release 定义静态约束 ----------------
echo "== ⑥ release 定义静态约束 =="
chk_contains "RELEASE_VERSION=2.0.0" "RELEASE_VERSION=2.0.0" "$(cat "${REL_ENV}")"
if command grep -vE '^[[:space:]]*#' "${REL_TSV}" | command grep -q ':latest'; then
    echo "  FAIL release-images.tsv 含 :latest"; fail=1
else echo "  ok  release-images.tsv 无 :latest"; fi
if command grep -vE '^[[:space:]]*#' "${REL_ENV}" | command grep -q '=latest'; then
    echo "  FAIL release.env 含 =latest"; fail=1
else echo "  ok  release.env 无 =latest"; fi
bash -n "${PUBLISH}" && echo "  ok  release-publish.sh 语法" || { echo "  FAIL release-publish.sh 语法"; fail=1; }

# ⑥a 发布/取件契约: CLI tar 文件名必须带版本(如 cubestack-installer-cli-v2.0.0.tar);
#     发布完成后本地 staging 也必须落 _SUCCESS(可直接 fetch --verify-only / 离线安装演练)。
echo "== ⑥a release-publish CLI tar 带版本名 + 本地 staging _SUCCESS =="
rm -rf "${TMP}/remote/cubestack-installer/2.0.0"
mkdir -p "${TMP}/stage-publish/offline-files"
printf 'release=2.0.0\n' > "${TMP}/stage-publish/offline-files/release.env"
printf 'cli\n' > "${TMP}/stage-publish/cubestack-installer-cli-v2.0.0.tar"
public_cli_sha="$(sha256sum "${TMP}/stage-publish/cubestack-installer-cli-v2.0.0.tar" | awk '{print $1}')"
printf '{"cli_tar":"../cubestack-installer-cli-v2.0.0.tar","cli_tar_sha256":"%s"}\n' "${public_cli_sha}" \
    > "${TMP}/stage-publish/offline-files/release.json"
( cd "${TMP}/stage-publish/offline-files" && sha256sum release.env release.json > SHA256SUMS )
out="$(bash "${PUBLISH}" publish --release 2.0.0 --stage-dir "${TMP}/stage-publish" --dry-run 2>&1)"
rc=$?
chk "publish dry-run 退出码" "0" "${rc}"
[ "${rc}" = "0" ] || printf '%s\n' "${out}" >&2
chk_contains "publish 上传带版本 CLI tar" "cubestack-installer-cli-v2.0.0.tar" "${out}"

out="$(bash "${PUBLISH}" publish --release 2.0.0 --stage-dir "${TMP}/stage-publish" 2>&1)"
rc=$?
chk "publish 实际执行退出码" "0" "${rc}"
[ "${rc}" = "0" ] || printf '%s\n' "${out}" >&2
chk "本地 staging 写入 _SUCCESS" "1" \
    "$([ -f "${TMP}/stage-publish/offline-files/_SUCCESS" ] && echo 1 || echo 0)"
chk "远端 CLI tar 带版本名" "1" \
    "$([ -f "${TMP}/remote/cubestack-installer/2.0.0/cubestack-installer-cli-v2.0.0.tar" ] && echo 1 || echo 0)"
chk "远端 _SUCCESS 落位" "1" \
    "$([ -f "${TMP}/remote/cubestack-installer/2.0.0/offline-files/_SUCCESS" ] && echo 1 || echo 0)"

# ⑥b 发布树版本冻结: images.manifest 引用的版本变量必须都能由 release.env 决定,
#     否则发布树会随发布机 cluster.conf/defaults 漂移(同版本不同内容)。
echo "== ⑥b manifest 版本变量全部冻结在 release.env =="
MANIFEST="${REPO_ROOT}/deployments/config/images.manifest"
missing=""
while read -r v; do
    [ -n "${v}" ] || continue
    case "${v}" in
        # 非版本面: 注册域/项目名; BUSYBOX_TAG=latest 仅 registry 存储校验用(tar 名锁死 busybox.tar)
        BUSYBOX_TAG|CUBESTACK_OPERATOR_HARBOR_HOST|METAX_HARBOR|METAX_PROJECT) continue ;;
    esac
    command grep -qE "^${v}=" "${REL_ENV}" || missing="${missing} ${v}"
done < <(command grep -vE '^[[:space:]]*#' "${MANIFEST}" \
         | command grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | tr -d '${}' | sort -u)
chk "manifest 版本变量已冻结" "" "${missing}"

# ⑥c 冻结值不被配置层覆盖: release.env 导出的版本变量经 image_manifest_load 后必须保持不变
echo "== ⑥c release.env 版本变量优先于 cluster.conf(保护清单) =="
cat > "${TMP}/drift.conf" <<'EOF'
K8S_VERSION=v0.0.0-drift
CALICO_VERSION=v0.0.0-drift
DEV_LAB_CPU_TAG=drift
EOF
out="$(set -a; . "${REL_ENV}"; set +a
    IMAGE_MANIFEST_CONF="${TMP}/drift.conf" bash -c 'source "$1"; image_manifest_load; printf "%s %s %s\n" "$K8S_VERSION" "$CALICO_VERSION" "$DEV_LAB_CPU_TAG"' _ "${REPO_ROOT}/deployments/scripts/tools/images/lib-image-manifest.sh" 2>/dev/null)"
chk "K8S/Calico/dev-lab 版本变量未被覆盖" "v1.35.8 v3.32.2 py310-torch2.4-v2.0.0-rc2" "${out}"

echo "---------------------------------------------"
[ "${fail}" = "0" ] && { echo "✅ release 模式回归通过"; exit 0; } || { echo "❌ release 模式回归失败"; exit 1; }
