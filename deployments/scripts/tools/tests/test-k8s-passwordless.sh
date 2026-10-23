#!/bin/bash
# ============================================================
# test-k8s-passwordless.sh — SSH 免密模块的失败语义回归(桩式, 不连集群)
# 背景(2026-10-22 用户实机): 密码错误时 k8s_passwordless 只 warn("密码注入失败")
#   然后打印 "✅ SSH 免密配置完成" 退出 0; 部署继续跑到 node_pkgs, 才以一个
#   "Ceph/RBD 残留, 必须先重启" 的误导性错误中断 —— 真因(SSH 密码错)被埋掉。
# 覆盖:
#   ① 密钥不通 + 密码错误 → 模块必须非零退出, 明确报"密码认证失败" + 检查
#      SSH_DEFAULT_PASSWORD, 且不得打印"完成"
#   ② 密钥已就绪(即使密码错) → 幂等成功, 根本不应尝试密码注入
#   ②b 其它身份(agent/ssh_config)可登录但部署密钥未注入 → 不得误判"已就绪", 必须走密码注入
#   ②c 口令保护的部署密钥仅存在于 ssh-agent → 探测必须允许 agent 用同一把密钥签名
#   ③ 密钥不通 + 密码正确 → 注入 + 验证通过, 模块成功
# 隔离: 临时 cluster.conf + 假 ssh/sshpass(纯离线)
# 用法: bash deployments/scripts/tools/tests/test-k8s-passwordless.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MODULE="${REPO_ROOT}/deployments/scripts/modules/02_k8s/01_k8s_passwordless.sh"
SETUP="${REPO_ROOT}/deployments/scripts/tools/node/setup-passwordless.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  FAIL $1: [$3] 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }
_count() { grep -c . "$1" 2>/dev/null || true; }

cat > "${TMP}/cluster.conf" <<'EOF'
NODES=("master,m1,10.0.0.1,root,wrongpass")
SSH_USER="root"
SSH_DEFAULT_PASSWORD="wrongpass"  # secret-scan: allow(测试桩假密码, 非真实凭据)
KUBESPRAY_PROFILE="none"
EOF

mkdir -p "${TMP}/keys" "${TMP}/bin"
: > "${TMP}/keys/cubestack_k8s"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestOnly test" > "${TMP}/keys/cubestack_k8s.pub"

# 假 ssh: 按认证方式分流; 密码模式成功时留下标记, 让后续密钥验证也能通过
# ②b 用: FAKE_OTHER_IDENTITY_OK=1 模拟"别的身份(agent/ssh_config)可登录" ——
#   只有探测显式限制为部署密钥(-i + IdentitiesOnly=yes + -F /dev/null)时才不短路。
# ②c 用: FAKE_AGENT_KEY_ONLY=1 模拟"部署密钥有口令、仅 ssh-agent 持有" ——
#   探测必须允许 agent(不能 IdentityAgent=none), 且仍只认部署密钥。
cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
mode=key; host=""; idonly=0; fnull=0; key=""; agent_none=0
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    a="${args[i]}"
    case "$a" in
        PreferredAuthentications=password*) mode=password ;;
        IdentitiesOnly=yes) idonly=1 ;;
        IdentityAgent=none) agent_none=1 ;;
        -F) [ "${args[i+1]:-}" = "/dev/null" ] && fnull=1 ;;
        -i) key="${args[i+1]:-}" ;;
        *@*) host="$a" ;;
    esac
done
printf '%s %s\n' "${mode}" "${host:-?}" >> "${FAKE_SSH_LOG:-/dev/null}"
if [ "${mode}" = "password" ]; then
    if [ "${FAKE_PW_OK:-0}" = "1" ]; then
        : > "${FAKE_KEY_MARK:?}"
        exit 0
    fi
    echo "${host}: Permission denied, please try again." >&2
    exit 255
fi
if [ "${FAKE_AGENT_KEY_ONLY:-0}" = "1" ]; then
    if [ "${agent_none}" = "1" ] || [ "${idonly}" != "1" ] || [ "${fnull}" != "1" ] || [ "${key}" != "${FAKE_EXPECT_KEY:-}" ]; then
        echo "${host}: Permission denied (publickey)." >&2
        exit 255
    fi
    exit 0     # agent 持有部署密钥 → 允许用同一把密钥签名
fi
if [ "${FAKE_OTHER_IDENTITY_OK:-0}" = "1" ]; then
    if [ "${idonly}" != "1" ] || [ "${fnull}" != "1" ] || [ "${key}" != "${FAKE_EXPECT_KEY:-}" ]; then
        exit 0     # 未限制身份 → 别的身份可登录(旧行为会误判为部署密钥可用)
    fi
fi
if [ "${FAKE_KEY_OK:-0}" = "1" ] || { [ -n "${FAKE_KEY_MARK:-}" ] && [ -f "${FAKE_KEY_MARK}" ]; }; then
    exit 0
fi
echo "${host}: Permission denied (publickey)." >&2
exit 255
FAKE
# 假 sshpass: 仅记录一次调用, 然后以同样参数执行假 ssh
cat > "${TMP}/bin/sshpass" <<'FAKE'
#!/bin/bash
[ "${1:-}" = "-e" ] && shift
printf '%s\n' "$*" >> "${FAKE_SSHPASS_LOG:-/dev/null}"
exec ssh "$@"
FAKE
chmod +x "${TMP}/bin/ssh" "${TMP}/bin/sshpass"

run_module() {  # run_module <tag> [VAR=value ...] → 退出码; 输出在 $TMP/out-<tag>
    local tag="$1"; shift
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf"
        export SSH_KEY_DIR="${TMP}/keys"
        export SSH_KEY_NAME="cubestack_k8s"
        export FAKE_EXPECT_KEY="${TMP}/keys/cubestack_k8s"
        export FAKE_SSH_LOG="${TMP}/ssh-${tag}.log"
        export FAKE_SSHPASS_LOG="${TMP}/sshpass-${tag}.log"
        export FAKE_KEY_MARK="${TMP}/key-ok-${tag}"
        : > "${FAKE_SSH_LOG}"; : > "${FAKE_SSHPASS_LOG}"
        env "$@" bash "${MODULE}"
    ) > "${TMP}/out-${tag}" 2>&1
    echo $?
}

echo "== ① 密钥不通 + 密码错误: 必须在本模块明确失败 =="
rc="$(run_module authfail FAKE_KEY_OK=0 FAKE_PW_OK=0)"
chk "退出码非零(部署不得继续)" "1" "${rc}"
chk_contains "明确报密码认证失败" "密码认证失败" "${TMP}/out-authfail"
chk_contains "点名检查 SSH_DEFAULT_PASSWORD" "SSH_DEFAULT_PASSWORD" "${TMP}/out-authfail"
chk_not_contains "不得谎报免密完成" "SSH 免密配置完成" "${TMP}/out-authfail"
chk "尝试过密码注入" "1" "$(_count "${TMP}/sshpass-authfail.log")"

echo "== ② 密钥已就绪(密码即使是错的): 幂等成功, 不碰密码 =="
rc="$(run_module keyok FAKE_KEY_OK=1 FAKE_PW_OK=0)"
chk "退出码 0" "0" "${rc}"
chk_contains "报告免密已就绪" "免密登录已就绪" "${TMP}/out-keyok"
chk "未尝试密码注入" "0" "$(_count "${TMP}/sshpass-keyok.log")"

echo "== ②b 仅验证部署密钥: 其它身份可用时不得误判密钥已注入 =="
rc="$(run_module otherid FAKE_KEY_OK=0 FAKE_PW_OK=1 FAKE_OTHER_IDENTITY_OK=1)"
chk "退出码 0(密码注入 + 受限密钥验证)" "0" "${rc}"
chk "尝试过密码注入(未被其它身份短路)" "1" "$(_count "${TMP}/sshpass-otherid.log")"
chk_contains "报告注入成功" "免密登录成功" "${TMP}/out-otherid"
chk_not_contains "不误报已就绪" "免密登录已就绪" "${TMP}/out-otherid"
chk_contains "探测限制为部署密钥(IdentitiesOnly)" "IdentitiesOnly=yes" "${SETUP}"
chk_contains "探测忽略用户 ssh_config(-F /dev/null)" "-F /dev/null" "${SETUP}"
chk "探测不禁用 ssh-agent(口令密钥可经 agent 签名)" "0" \
    "$(awk '/^_key_ok\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SETUP}" \
        | grep -cF 'IdentityAgent=none' || true)"

echo "== ②c 口令密钥在 ssh-agent 中: 不得因禁用 agent 而误判 =="
rc="$(run_module agentkey FAKE_KEY_OK=0 FAKE_PW_OK=0 FAKE_AGENT_KEY_ONLY=1)"
chk "退出码 0(agent 可用同一把部署密钥)" "0" "${rc}"
chk_contains "报告免密已就绪" "免密登录已就绪" "${TMP}/out-agentkey"
chk "未尝试密码注入" "0" "$(_count "${TMP}/sshpass-agentkey.log")"

echo "== ③ 密钥不通 + 密码正确: 注入并验证成功 =="
rc="$(run_module pwok FAKE_KEY_OK=0 FAKE_PW_OK=1)"
chk "退出码 0" "0" "${rc}"
chk_contains "报告免密登录成功" "免密登录" "${TMP}/out-pwok"
chk_not_contains "不报失败" "密码认证失败" "${TMP}/out-pwok"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-k8s-passwordless: 全部通过"
else
    echo "❌ test-k8s-passwordless: 存在失败项"
fi
exit "${fail}"
