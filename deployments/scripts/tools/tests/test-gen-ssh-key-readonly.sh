#!/bin/bash
# ============================================================
# test-gen-ssh-key-readonly.sh — SSH key 只读挂载回归(issue #196)
# 背景: 文档推荐 -v $HOME/.ssh:/root/.ssh:ro; 旧 gen-ssh-key.sh 在检查 key 之前就
#   `mkdir/chmod 700` 整个目录 → 只读挂载下 chmod 报 "Read-only file system" 并使
#   set -e 退出, 即使 key 已经可用。
# 判据:
#   ① key 已存在: 不调用 chmod(用必然失败的 chmod 桩也能成功), 不改密钥内容;
#   ② key 不存在 + 目录可写: 照常生成;
#   ③ key 不存在 + 目录不可写: 明确报错(不是裸 chmod 失败);
#   ④ key 已存在 + 目录 555: 成功复用。
# 机制: 从脚本**原样抽取** key 处理块(不 source lib-common, 避免测试环境要求 root)。
# 用法: bash deployments/scripts/tools/tests/test-gen-ssh-key-readonly.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="${REPO_ROOT}/deployments/scripts/tools/node/gen-ssh-key.sh"
[ -f "${SCRIPT}" ] || { echo "找不到被测脚本: ${SCRIPT}"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

sed -n '/^SSH_KEY_DIR="\${SSH_KEY_DIR:-/,/^fi$/p' "${SCRIPT}" > "${TMP}/block.sh"
[ -s "${TMP}/block.sh" ] || { echo "FAIL 抽取 key 处理块失败"; exit 1; }

mkdir -p "${TMP}/bin"
# chmod 桩: 记录调用并**总是失败** —— 模拟只读文件系统。若 key 已存在时仍调 chmod,
# 旧实现会因 set -e 直接失败; 新实现应完全跳过。
cat > "${TMP}/bin/chmod" <<'FAKE'
#!/bin/bash
echo "$*" >> "${CHMOD_LOG:-/dev/null}"
exit 1
FAKE
chmod +x "${TMP}/bin/chmod"

cat > "${TMP}/stub.sh" <<'SH'
set -u
ok() { echo "OK $*"; }
say() { echo "SAY $*"; }
warn() { echo "WARN $*"; }
err() { echo "ERR $*"; }
SH

run_key() {  # run_key <key_dir> -> stdout+stderr; 返回块退出码
    local dir="$1"
    {
        cat "${TMP}/stub.sh"
        cat "${TMP}/block.sh"
    } > "${TMP}/run.sh"
    (
        export PATH="${TMP}/bin:${PATH}" CHMOD_LOG="${TMP}/chmod.log"
        export SSH_KEY_DIR="${dir}" SSH_KEY_NAME="cubestack_k8s" QUIET=0
        bash "${TMP}/run.sh"
    )
}

echo "== ① key 已存在 + chmod 必然失败(只读挂载) =="
d1="${TMP}/ro-ssh"; mkdir -p "${d1}"
printf 'PRIVATE-KEY-CONTENT\n' > "${d1}/cubestack_k8s"
printf 'PUB\n' > "${d1}/cubestack_k8s.pub"
: > "${TMP}/chmod.log"
out="$(run_key "${d1}")"; rc=$?
chk "退出码 0" "0" "${rc}"
chk "提示已存在" "1" "$(printf '%s' "${out}" | command grep -c '密钥已存在')"
chk "尝试收敛目录权限(失败不阻断)" "1" "$(command grep -c '^700 ' "${TMP}/chmod.log" || true)"
chk "私钥内容未改" "PRIVATE-KEY-CONTENT" "$(cat "${d1}/cubestack_k8s")"

echo "== ② key 不存在 + 目录可写: 正常生成 =="
d2="${TMP}/writable-ssh"; mkdir -p "${d2}"
out="$(run_key "${d2}")"; rc=$?
chk "退出码 0" "0" "${rc}"
chk "已生成私钥" "1" "$([ -f "${d2}/cubestack_k8s" ] && echo 1 || echo 0)"
chk "已生成公钥" "1" "$([ -f "${d2}/cubestack_k8s.pub" ] && echo 1 || echo 0)"

echo "== ③ key 不存在 + 目录不可写: 明确报错 =="
if [ "$(id -u)" = "0" ]; then
    echo "  skip (root 下 [ -w ] 恒真, 无法模拟)"
else
    d3="${TMP}/unwritable-ssh"; mkdir -p "${d3}"; chmod 555 "${d3}"
    out="$(run_key "${d3}")"; rc=$?
    chk "退出码非 0" "1" "${rc}"
    chk "点名目录不可写" "1" "$(printf '%s' "${out}" | command grep -c '不可写')"
    chmod 755 "${d3}"
fi

echo "== ④ key 已存在 + 目录 555: 成功复用 =="
d4="${TMP}/readonly-ssh"; mkdir -p "${d4}"
printf 'KEY\n' > "${d4}/cubestack_k8s"
printf 'PUB\n' > "${d4}/cubestack_k8s.pub"
chmod 555 "${d4}"
out="$(run_key "${d4}")"; rc=$?
chk "退出码 0" "0" "${rc}"
chmod 755 "${d4}"

echo "== ⑤ 私钥在、公钥缺失: 可写目录自动重建 =="
if command -v ssh-keygen >/dev/null 2>&1; then
    d5="${TMP}/pub-missing"; mkdir -p "${d5}"
    ssh-keygen -t ed25519 -N "" -f "${d5}/cubestack_k8s" >/dev/null 2>&1
    rm -f "${d5}/cubestack_k8s.pub"
    out="$(run_key "${d5}")"; rc=$?
    chk "退出码 0" "0" "${rc}"
    chk "公钥已重建且非空" "1" "$([ -s "${d5}/cubestack_k8s.pub" ] && echo 1 || echo 0)"
else
    echo "  skip (无 ssh-keygen)"
fi

echo "== ⑥ 私钥在、公钥缺失 + 目录不可写: 明确报错 =="
if [ "$(id -u)" = "0" ]; then
    echo "  skip (root 下 [ -w ] 恒真, 无法模拟)"
else
    d6="${TMP}/pub-missing-ro"; mkdir -p "${d6}"
    printf 'KEY\n' > "${d6}/cubestack_k8s"; chmod 555 "${d6}"
    out="$(run_key "${d6}")"; rc=$?
    chk "退出码非 0" "1" "${rc}"
    chk "点名公钥缺失" "1" "$(printf '%s' "${out}" | command grep -c '公钥缺失')"
    chmod 755 "${d6}"
fi

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-gen-ssh-key-readonly: 全部通过"
else
    echo "❌ test-gen-ssh-key-readonly: 存在失败项"
fi
exit "${fail}"
