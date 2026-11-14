#!/bin/bash
# ============================================================
# test-release-mode.sh — 版本树消费回归(无需 MinIO/Harbor/集群)
# 覆盖:
#   ① --release <版本>: OFFLINE_FILES_ROOT 指向 <root>/<版本>/offline-files, 组件目录重定向
#   ② 直接挂载版本树的 offline-files/: 自动从 release.env 识别版本
#   ③ 缺少 release.env 硬失败
#   ④ 版本名格式校验(拒绝 ../、绝对路径、空白/元字符; 不误杀合法版本名)
#   ⑤ release.env 版本不符 / 缺 KUBESPRAY_VERSION 硬失败
#   ⑥ release.env 预校验(SHA256SUMS 不符拒绝 source)
# 隔离: 临时 CLUSTER_CONF; 纯离线。
# 用法: bash deployments/scripts/tools/tests/test-release-mode.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

cat > "${TMP}/cluster.conf" <<'EOF'
NODES=()
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF

run_load() {  # run_load <env...> —— 输出 OFFLINE_FILES_ROOT 等关键变量
    env CLUSTER_CONF="${TMP}/cluster.conf" "$@" \
        bash -c 'source "$1"; load_config; printf "%s\n" "$CUBESTACK_RELEASE" "$OFFLINE_FILES_ROOT" "$CUBESTACK_RELEASE_ROOT" "$CUBESTACK_OPERATOR_OFFLINE_DIR" "$DEV_LAB_SAVE_DIR" "$MODEL_IMAGES_SAVE_DIR" "$CEPH_IMAGE_DIR" "$NETSHOOT_BASE_TAR"' _ "${LIB}" 2>/dev/null
}
rc_of() {  # rc_of <env...> —— 只取退出码/错误输出
    env CLUSTER_CONF="${TMP}/cluster.conf" "$@" \
        bash -c 'source "$1"; load_config' _ "${LIB}" 2>&1
}

# ---------------- ① 版本树 ----------------
mkdir -p "${TMP}/rel/9.9.9/offline-files"
cat > "${TMP}/rel/9.9.9/offline-files/release.env" <<'EOF'
RELEASE_VERSION=9.9.9
KUBESPRAY_VERSION=v2.32.0
EOF
echo "== ① 版本树模式 =="
out="$(run_load CUBESTACK_RELEASE=9.9.9 CUBESTACK_RELEASE_ROOT="${TMP}/rel")"
chk "release 版本" "9.9.9" "$(printf '%s\n' "${out}" | sed -n '1p')"
chk "OFFLINE_FILES_ROOT" "${TMP}/rel/9.9.9/offline-files" "$(printf '%s\n' "${out}" | sed -n '2p')"
chk "CUBESTACK_RELEASE_ROOT 保留" "${TMP}/rel" "$(printf '%s\n' "${out}" | sed -n '3p')"
chk "operator 目录重定向" "${TMP}/rel/9.9.9/offline-files/cubestack-operator" "$(printf '%s\n' "${out}" | sed -n '4p')"
chk "dev-lab 目录重定向" "${TMP}/rel/9.9.9/offline-files/dev-lab" "$(printf '%s\n' "${out}" | sed -n '5p')"
chk "model-collection 目录重定向" "${TMP}/rel/9.9.9/offline-files/model-collection" "$(printf '%s\n' "${out}" | sed -n '6p')"
chk "ceph 镜像目录重定向" "${TMP}/rel/9.9.9/offline-files/kubespray/v2.32.0/images" "$(printf '%s\n' "${out}" | sed -n '7p')"
chk "netshoot 回退 tar 重定向" "${TMP}/rel/9.9.9/offline-files/os/netshoot.tar" "$(printf '%s\n' "${out}" | sed -n '8p')"

# ---------------- ② 直接挂载 offline-files ----------------
mkdir -p "${TMP}/auto"
cat > "${TMP}/auto/release.env" <<'EOF'
RELEASE_VERSION=9.9.8
KUBESPRAY_VERSION=v2.32.0
EOF
echo "== ② 直接挂载 offline-files(自动识别) =="
out="$(run_load OFFLINE_FILES_ROOT="${TMP}/auto")"
chk "自动识别 CUBESTACK_RELEASE" "9.9.8" "$(printf '%s\n' "${out}" | sed -n '1p')"
chk "OFFLINE_FILES_ROOT 不变" "${TMP}/auto" "$(printf '%s\n' "${out}" | sed -n '2p')"
chk "不保留版本树 root" "" "$(printf '%s\n' "${out}" | sed -n '3p')"

# ---------------- ③ 缺少 release.env ----------------
echo "== ③ 缺少 release.env =="
mkdir -p "${TMP}/rel/9.9.7/offline-files"
err="$(rc_of CUBESTACK_RELEASE=9.9.7 CUBESTACK_RELEASE_ROOT="${TMP}/rel")"; rc=$?
chk "缺少 release.env 退出码" "1" "${rc}"
chk_contains "错误提示版本树路径" "未找到发布版本 9.9.7" "${err}"

# ---------------- ④ 版本名格式校验 ----------------
echo "== ④ 版本名格式校验 =="
mkdir -p "${TMP}/decoy/offline-files"
{
    printf 'touch "%s"\n' "${TMP}/pwned"
    printf 'RELEASE_VERSION=../decoy\nKUBESPRAY_VERSION=v2.32.0\n'
} > "${TMP}/decoy/offline-files/release.env"
err="$(rc_of CUBESTACK_RELEASE='../decoy' CUBESTACK_RELEASE_ROOT="${TMP}/rel")"; rc=$?
chk "路径穿越值退出码 1" "1" "${rc}"
chk "路径穿越值未 source 外部 release.env" "0" "$([ -e "${TMP}/pwned" ] && echo 1 || echo 0)"
for bad in '..' '.' '/abs' 'a/b' 'a b' 'a;b' 'a$b' '-rc1'; do
    err="$(rc_of CUBESTACK_RELEASE="${bad}" CUBESTACK_RELEASE_ROOT="${TMP}/rel")"; rc=$?
    chk "拒绝非法 release: ${bad}" "1" "${rc}"
done
err="$(rc_of CUBESTACK_RELEASE='2.1.0-rc1' CUBESTACK_RELEASE_ROOT="${TMP}/rel")"; rc=$?
chk "合法 release 名未被格式校验拦截" "1" "${rc}"
chk_contains "合法值进入 release.env 缺失分支" "未找到发布版本" "${err}"

# ---------------- ⑤ release.env 内容校验 ----------------
echo "== ⑤ release.env 内容校验 =="
mkdir -p "${TMP}/bad1/9.9.9/offline-files" "${TMP}/bad2/9.9.5/offline-files"
printf 'RELEASE_VERSION=9.9.6\nKUBESPRAY_VERSION=v2.32.0\n' > "${TMP}/bad1/9.9.9/offline-files/release.env"
err="$(rc_of CUBESTACK_RELEASE=9.9.9 CUBESTACK_RELEASE_ROOT="${TMP}/bad1")"; rc=$?
chk "版本不符退出码 1" "1" "${rc}"
chk_contains "版本不符提示" "release.env 版本不符" "${err}"
printf 'RELEASE_VERSION=9.9.5\n' > "${TMP}/bad2/9.9.5/offline-files/release.env"
err="$(rc_of CUBESTACK_RELEASE=9.9.5 CUBESTACK_RELEASE_ROOT="${TMP}/bad2")"; rc=$?
chk "缺 KUBESPRAY_VERSION 退出码 1" "1" "${rc}"
chk_contains "缺 KUBESPRAY_VERSION 提示" "缺少 KUBESPRAY_VERSION" "${err}"

# ---------------- ⑥ release.env 预校验 ----------------
echo "== ⑥ release.env 预校验(SHA256SUMS) =="
mkdir -p "${TMP}/bad3/9.9.4/offline-files"
printf 'RELEASE_VERSION=9.9.4\nKUBESPRAY_VERSION=v2.32.0\n' > "${TMP}/bad3/9.9.4/offline-files/release.env"
printf '%064d  ./release.env\n' 0 > "${TMP}/bad3/9.9.4/offline-files/SHA256SUMS"
err="$(rc_of CUBESTACK_RELEASE=9.9.4 CUBESTACK_RELEASE_ROOT="${TMP}/bad3")"; rc=$?
chk "release.env 哈希不符退出码 1" "1" "${rc}"
chk_contains "release.env 哈希不符提示" "release.env 校验失败" "${err}"

# ---------------- ⑦ 版本树附带的模块自动发现 ----------------
# 布局固定: <版本树根>/{offline-files/, modules/}。installer 自身不含私有模块,
# 这里只验"位置被正确交给模块框架", 不涉及任何具体模块名。
echo "== ⑦ 版本树模块自动发现 =="
mkdir -p "${TMP}/rel/9.9.3/offline-files" "${TMP}/rel/9.9.3/modules/03_addon"
printf 'RELEASE_VERSION=9.9.3\nKUBESPRAY_VERSION=v2.32.0\n' > "${TMP}/rel/9.9.3/offline-files/release.env"
printf '#!/bin/bash\n# MODULE: tree_mod\n# DESC: tree module\n# PHASE: addon\n' \
    > "${TMP}/rel/9.9.3/modules/03_addon/99_tree_mod.sh"
out="$(run_load CUBESTACK_RELEASE=9.9.3 CUBESTACK_RELEASE_ROOT="${TMP}/rel")"
# run_load 只打印固定变量; 用独立断言直接取 CUBESTACK_EXTRA_MODULES_DIRS
extra="$(env CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE=9.9.3 CUBESTACK_RELEASE_ROOT="${TMP}/rel" \
    bash -c 'source "$1"; load_config; printf "%s" "${CUBESTACK_EXTRA_MODULES_DIRS:-}"' _ "${LIB}" 2>/dev/null)"
chk "版本树 modules/ 被交给模块框架" "${TMP}/rel/9.9.3/modules" "${extra}"

# 没有 modules/ 的版本树(公共形态): 不得凭空设置, 否则会指向不存在的目录。
mkdir -p "${TMP}/rel2/9.9.2/offline-files"
printf 'RELEASE_VERSION=9.9.2\nKUBESPRAY_VERSION=v2.32.0\n' > "${TMP}/rel2/9.9.2/offline-files/release.env"
extra="$(env CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE=9.9.2 CUBESTACK_RELEASE_ROOT="${TMP}/rel2" \
    bash -c 'source "$1"; load_config; printf "%s" "${CUBESTACK_EXTRA_MODULES_DIRS:-}"' _ "${LIB}" 2>/dev/null)"
chk "公共版本树不设置额外模块目录" "" "${extra}"

# 调用方显式指定时以调用方为准(调试/非常规布局)。
extra="$(env CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE=9.9.3 CUBESTACK_RELEASE_ROOT="${TMP}/rel" \
    CUBESTACK_EXTRA_MODULES_DIRS=/custom/modules \
    bash -c 'source "$1"; load_config; printf "%s" "${CUBESTACK_EXTRA_MODULES_DIRS:-}"' _ "${LIB}" 2>/dev/null)"
chk "显式指定优先于自动发现" "/custom/modules" "${extra}"

if [ "${fail}" = "0" ]; then
    echo "✅ test-release-mode: 全部通过"
else
    echo "❌ test-release-mode: 存在失败项"
    exit 1
fi
