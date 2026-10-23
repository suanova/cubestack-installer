#!/bin/bash
# ============================================================
# test-release-mode.sh — release 模式离线回归(无需 MinIO/Harbor/集群)
# 覆盖:
#   ① load_config: CUBESTACK_RELEASE 派生 OFFLINE_FILES_ROOT + 11 个目录变量
#   ② 缺少 release.env 时硬失败(退出码 1)
#   ②b CUBESTACK_RELEASE 格式校验(拒绝 ../、绝对路径、空白/元字符; 不误杀合法版本名)
#   ③ fetch-offline-from-minio.sh --release: 下载布局/SHA256SUMS/CLI tar 校验
#   ④ --verify-only 通过; 篡改文件后失败
#   ⑤ --list-releases 输出可用版本
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
printf 'cli-tar-bytes\n' > "${TMP}/remote/cubestack-installer/2.0.0/cubestack-installer-cli.tar"
cli_sha="$(sha256sum "${TMP}/remote/cubestack-installer/2.0.0/cubestack-installer-cli.tar" | awk '{print $1}')"
printf '{"cli_tar_sha256":"%s"}\n' "${cli_sha}" > "${TMP}/remote/cubestack-installer/2.0.0/offline-files/release.json"
( cd "${TMP}/remote/cubestack-installer/2.0.0/offline-files" && sha256sum ./ceph/test.txt ./release.env ./release.json > SHA256SUMS )

cat > "${TMP}/bin/mc" <<'FAKE'
#!/bin/bash
set -uo pipefail
REMOTE="${FAKE_REMOTE:?}"
p() { local a="$1"; a="${a#minio/cubestack-installer/}"; printf '%s' "${REMOTE}/cubestack-installer/${a}"; }
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
        mkdir -p "${2:?}"; cp -a "$(p "${1:?}")"/. "${2}"/ ;;
    cp)
        mkdir -p "$(dirname "${2:?}")"; cp -a "$(p "${1:?}")" "${2}" ;;
    cat) cat "$(p "${1:?}")" ;;
    *) echo "fake mc: unsupported ${cmd}" >&2; exit 1 ;;
esac
FAKE
chmod +x "${TMP}/bin/mc"
export PATH="${TMP}/bin:${PATH}"
export FAKE_REMOTE="${TMP}/remote"
export MINIO_ENDPOINT="http://fake" MINIO_ACCESS_KEY="x" MINIO_SECRET_KEY="y"

bash "${FETCH}" --release 2.0.0 --dest "${TMP}/local" --yes >/dev/null 2>&1
chk "fetch --release 退出码" "0" "$?"
chk "发布树落盘" "hello" "$(cat "${TMP}/local/2.0.0/offline-files/ceph/test.txt" 2>/dev/null)"
chk "CLI tar 落盘" "cli-tar-bytes" "$(cat "${TMP}/local/2.0.0/cubestack-installer-cli.tar" 2>/dev/null)"

bash "${FETCH}" --release 2.0.0 --verify-only --dest "${TMP}/local" >/dev/null 2>&1
chk "verify-only 通过" "0" "$?"
printf 'tampered\n' >> "${TMP}/local/2.0.0/offline-files/ceph/test.txt"
bash "${FETCH}" --release 2.0.0 --verify-only --dest "${TMP}/local" >/dev/null 2>&1
rc=$?
chk "篡改后 verify-only 失败" "1" "${rc}"

out="$(bash "${FETCH}" --list-releases 2>/dev/null)"
chk_contains "list-releases 输出版本" "2.0.0" "${out}"

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

echo "---------------------------------------------"
[ "${fail}" = "0" ] && { echo "✅ release 模式回归通过"; exit 0; } || { echo "❌ release 模式回归失败"; exit 1; }
