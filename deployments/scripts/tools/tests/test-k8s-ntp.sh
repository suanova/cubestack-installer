#!/bin/bash
# ============================================================
# test-k8s-ntp.sh — setup-ntp 关键行为回归(纯离线, 假 ssh)
# 背景(2026-10-26 实机):
#   · 全量部署时 master02 在负载下 SSH/sudo 延迟约 4s, 被 SSH date 差值误判成
#     "时钟偏差 4s"; 同一节点 standalone 跑却只有 256ms。
#   · 第一次全量用 ubuntu 用户时 worker05-08 无 sudo 免密, 包安装/NTP 都失败,
#     但脚本只 warn 后继续, 最终在 NTP 阶段以偏差超限误导性失败。
# 覆盖:
#   ① node_cmd: root 用户不套 sudo; 非 root 仍套 sudo
#   ② clock_offset: chrony tracking/Leap/Reach 正常时优先用 chrony 的 System time,
#      不再用 SSH date(避免把 SSH/sudo 延迟当偏差)
#   ③ clock_offset: 权威自身无上游时直接返回 0, 不再 SSH 自测吃噪声
#   ④ clock_offset: chrony 不可用/未同步时回退 SSH date(仍能返回数值)
#   ⑤ 权威 stratum 硬失败、SYNC-OK/FAIL、apply 检查 SYNC-OK 静态围栏
#   ⑥ workerbm sudo 前置 + 安装失败硬退出
# 用法: bash deployments/scripts/tools/tests/test-k8s-ntp.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SETUP="${REPO_ROOT}/deployments/scripts/tools/node/setup-ntp.sh"
WORKERBM="${REPO_ROOT}/deployments/scripts/modules/02_k8s/02_k8s_workerbm.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if printf '%s' "$3" | command grep -qF -- "$2"; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if printf '%s' "$3" | command grep -qF -- "$2"; then echo "  FAIL $1: 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }

# ---------------- 假 ssh: 记录远端命令, 按命令返回夹具 ----------------
cat > "${TMP}/ssh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_SSH_LOG:?}"
cmd="${*: -1}"
case "$cmd" in
    *"command -v chronyc"*) [ "${FAKE_CHRONY_PRESENT:-1}" = "1" ] && exit 0 || exit 1 ;;
    *"chronyc tracking"*) cat "${FAKE_TRACKING:-/dev/null}" 2>/dev/null || true ;;
    *"chronyc sources"*)  cat "${FAKE_SOURCES:-/dev/null}" 2>/dev/null || true ;;
    *"date +%s%3N"*)      cat "${FAKE_DATE:-/dev/null}" 2>/dev/null || true ;;
    *) : ;;
esac
exit 0
FAKE
chmod +x "${TMP}/ssh"
export PATH="${TMP}:${PATH}"
export FAKE_SSH_LOG="${TMP}/ssh.log"
: > "${FAKE_SSH_LOG}"

# 从脚本抽取函数(不执行主流程)
{
    echo 'SSH_OPTS=()'
    echo 'warn() { echo "WARN $*"; }'   # 模拟 lib-common: warn 默认写 stdout
    command sed -n '/^node_cmd()/,/^}/p' "${SETUP}"
    command sed -n '/^node_sudo_ready()/,/^}/p' "${SETUP}"
    command sed -n '/^clock_offset()/,/^}/p' "${SETUP}"
} > "${TMP}/functions.sh"
# shellcheck disable=SC1091
source "${TMP}/functions.sh"

echo "== ① node_cmd: root 不套 sudo =="
: > "${FAKE_SSH_LOG}"
printf '1700000000000\n' > "${TMP}/date"
FAKE_DATE="${TMP}/date" node_cmd 10.0.0.2 root pw "date +%s%3N" >/dev/null
_log="$(cat "${FAKE_SSH_LOG}")"
chk_contains "root 远端命令含 date" "date +%s%3N" "${_log}"
chk_not_contains "root 远端命令不含 sudo" "sudo date +%s%3N" "${_log}"
node_sudo_ready 10.0.0.2 root ""; chk "root node_sudo_ready=0" "0" "$?"

: > "${FAKE_SSH_LOG}"
FAKE_DATE="${TMP}/date" node_cmd 10.0.0.2 ubuntu pw "date +%s%3N" >/dev/null
_log="$(cat "${FAKE_SSH_LOG}")"
chk_contains "非 root 远端命令套 sudo" "sudo date +%s%3N" "${_log}"

echo "== ② clock_offset: chrony 优先 =="
export NTP_AUTHORITY="10.0.0.1" NTP_UPSTREAM="" AUTH_USER="root" AUTH_PW=""
cat > "${TMP}/tracking.ok" <<'EOF'
Reference ID    : 0A000001 (10.0.0.1)
Stratum         : 10
System time     : 0.004000 seconds slow of NTP time
Leap status     : Normal
EOF
cat > "${TMP}/sources.ok" <<'EOF'
377
EOF
export FAKE_TRACKING="${TMP}/tracking.ok" FAKE_SOURCES="${TMP}/sources.ok" FAKE_DATE="${TMP}/date"
off="$(clock_offset 10.0.0.2 root "")"
chk "chrony System time 4ms" "4" "${off}"

echo "== ②b Reach 17(收敛中)仍用 chrony, 不误判 =="
printf '17\n' > "${TMP}/sources.converging"
export FAKE_SOURCES="${TMP}/sources.converging"
off="$(clock_offset 10.0.0.2 root "")"
chk "Reach=17 仍用 chrony 4ms" "4" "${off}"
export FAKE_SOURCES="${TMP}/sources.ok"

echo "== ②c chrony 未安装: 明确提示 =="
_err="${TMP}/err-chrony-missing"; : > "${_err}"
off="$(FAKE_CHRONY_PRESENT=0 clock_offset 10.0.0.2 root "" 2>"${_err}")"
if printf '%s' "${off}" | command grep -qE '^[0-9]+$'; then
    echo "  ok  chrony 未安装时回退 SSH date 返回数值(${off}ms)"
else
    echo "  FAIL chrony 未安装时返回非数值: ${off}"; fail=1
fi
chk_contains "提示 chrony 未安装" "chrony 未安装" "$(cat "${_err}")"

echo "== ③ 权威自身无上游: 直接 0 =="
: > "${FAKE_SSH_LOG}"
off="$(clock_offset 10.0.0.1 root "")"
chk "权威自身 offset=0" "0" "${off}"
chk "权威自身不发 SSH 采样" "0" "$(command grep -c . "${FAKE_SSH_LOG}" 2>/dev/null || true)"

echo "== ④ chrony 未同步: 回退 SSH date =="
cat > "${TMP}/tracking.bad" <<'EOF'
Stratum         : 0
System time     : 0.000000000 seconds
Leap status     : Not synchronised
EOF
: > "${TMP}/sources.bad"
export FAKE_TRACKING="${TMP}/tracking.bad" FAKE_SOURCES="${TMP}/sources.bad"
off="$(clock_offset 10.0.0.2 root "")"
if printf '%s' "${off}" | command grep -qE '^[0-9]+$'; then
    echo "  ok  回退 SSH date 返回数值(${off}ms)"
else
    echo "  FAIL 回退 SSH date 返回非数值: ${off}"; fail=1
fi

echo "== ⑤ 静态围栏 =="
chk_contains "权威 stratum 硬失败" "chrony 未就绪" "$(cat "${SETUP}")"
chk_contains "chrony tracking 优先" "chronyc tracking 2>/dev/null" "$(cat "${SETUP}")"
chk_contains "Reach 取第 5 列" 'print \$5' "$(cat "${SETUP}")"
chk_contains "远端成功信号 SYNC-OK" "SYNC-OK" "$(cat "${SETUP}")"
chk_contains "远端失败信号 SYNC-FAIL" "SYNC-FAIL" "$(cat "${SETUP}")"
chk_contains "apply 检查 SYNC-OK" "grep -q 'SYNC-OK'" "$(cat "${SETUP}")"
chk_contains "节点 sudo 前置" "node_sudo_ready" "$(cat "${SETUP}")"
chk_contains "偏差非数字防御" '=~ ^-?[0-9]+$' "$(cat "${SETUP}")"
chk_contains "clock_offset 诊断走 stderr" '回退 SSH date 测量(受 SSH/负载延迟影响)" >&2' "$(cat "${SETUP}")"
chk_contains "客户端离线安装 chrony" "install_debs_offline /tmp/cubestack-ntp-debs chrony" "$(cat "${SETUP}")"
chk_contains "无守护进程标记" "NO-TIME-DAEMON" "$(cat "${SETUP}")"
chk_contains "SYNC-OK 要求 DAEMON_OK" 'DAEMON_OK}" = "1"' "$(cat "${SETUP}")"
chk_contains "客户端 deb 推送开关" "NTP_HAS_DEB" "$(cat "${SETUP}")"
chk_contains "authority deb 逐文件落位" '/tmp/cubestack-ntp-debs/$(basename "${deb}")' "$(cat "${SETUP}")"
chk_contains "client deb 逐文件落位" '/tmp/cubestack-ntp-debs/$(basename "${_deb}")' "$(cat "${SETUP}")"
chk "deb 推送不用目录尾斜杠" "0" "$(command grep -c 'node_scp .*cubestack-ntp-debs/"' "${SETUP}" 2>/dev/null || true)"
chk_contains "安装失败打印 dpkg 日志" "CHRONY-INSTALL-FAILED" "$(cat "${SETUP}")"
chk_contains "daemon precheck 整链 bash -c(避免 sudo builtin)" "bash -c 'command -v chronyc" "$(cat "${SETUP}")"
chk "node_cmd 不再裸跑 command -v chronyc(避免 sudo builtin)" "0" \
    "$(command grep -c 'node_cmd .*"command -v chronyc' "${SETUP}" 2>/dev/null || true)"
chk "chronyc 存在性检查至少 3 处 bash -c" "1" \
    "$([ "$(command grep -c "bash -c 'command -v chronyc" "${SETUP}" 2>/dev/null || true)" -ge 3 ] && echo 1 || echo 0)"

echo "== ⑥ workerbm 权限/失败语义 =="
chk_contains "workerbm sudo 前置" "sudo -n true" "$(cat "${WORKERBM}")"
chk_contains "workerbm 安装失败计入 PKG_FAIL" "PKG_FAIL=1" "$(cat "${WORKERBM}")"
chk_contains "workerbm 失败退出" "exit 1" "$(cat "${WORKERBM}")"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-k8s-ntp: 全部通过"; else echo "❌ test-k8s-ntp: 有失败"; fi
exit "${fail}"
