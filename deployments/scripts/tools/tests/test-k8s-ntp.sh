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
#   ⑥ workerbm 装包为 opt-in: 默认关闭, 仅 WORKER_PKGS_ENABLED=true 时调用装包脚本
#   ⑦ 装包与同步解耦(2026-11-19): setup-ntp 不再内嵌 chrony/OS 装包;
#      首 master 缺 chrony 硬失败并指向可选模块 chrony_pkgs
# 用法: bash deployments/scripts/tools/tests/test-k8s-ntp.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SETUP="${REPO_ROOT}/deployments/scripts/tools/node/setup-ntp.sh"
WORKERBM="${REPO_ROOT}/deployments/scripts/modules/02_k8s/02_k8s_workerbm.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
# contains 判定用 bash 内建: printf|grep -q 在 pipefail 下会因 grep 匹配后提前退出
# 让 printf 收 SIGPIPE, 大输入(如整份 setup-ntp.sh)时偶发假红(2026-10-26 CI 全红根因)。
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if [[ "$3" == *"$2"* ]]; then echo "  FAIL $1: 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }

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
chk_contains "客户端缺 chrony 时回退 timesyncd" "CHRONY-NOT-INSTALLED" "$(cat "${SETUP}")"
# 2026-11-19 用户口径: 装包与 NTP 同步解耦 —— k8s_ntp 不再内嵌任何 OS 装包;
#   chrony 由可选模块 chrony_pkgs 负责, 首 master 缺 chrony 时硬失败并给启用指引。
chk_contains "首 master 缺 chrony 硬失败" "CHRONY-NOT-INSTALLED" "$(cat "${SETUP}")"
chk_contains "首 master 缺 chrony 指向手动脚本" "install-os-packages.sh" "$(cat "${SETUP}")"
chk_contains "旧 chrony_pkgs 标注已停用" "chrony_pkgs" "$(cat "${SETUP}")"
chk_not_contains "NTP 模块不内嵌离线装包" "install_debs_offline" "$(cat "${SETUP}")"
chk_not_contains "NTP 模块不引用 chrony 专用安装集" "os/packages/chrony" "$(cat "${SETUP}")"
chk_not_contains "NTP 模块不内嵌 deb 安装原语" "deb_install_remote_lib" "$(cat "${SETUP}")"
chk_contains "无守护进程标记" "NO-TIME-DAEMON" "$(cat "${SETUP}")"
chk_contains "SYNC-OK 要求 DAEMON_OK" 'DAEMON_OK}" = "1"' "$(cat "${SETUP}")"
chk_contains "daemon precheck 整链 bash -c(避免 sudo builtin)" "bash -c 'command -v chronyc" "$(cat "${SETUP}")"
chk "node_cmd 不再裸跑 command -v chronyc(避免 sudo builtin)" "0" \
    "$(command grep -c 'node_cmd .*"command -v chronyc' "${SETUP}" 2>/dev/null || true)"
chk "chronyc 存在性检查至少 2 处 bash -c" "1" \
    "$([ "$(command grep -c "bash -c 'command -v chronyc" "${SETUP}" 2>/dev/null || true)" -ge 2 ] && echo 1 || echo 0)"

echo "== ⑤b fallback: 渲染时序 + chrony 客户端不指向 timesyncd master =="
chk_contains "apply 在 fallback 判定后渲染客户端脚本" 'render_node_script "${_client_server}"' "$(cat "${SETUP}")"
chk_contains "fallback 清空 chrony SERVER" '_client_server=""' "$(cat "${SETUP}")"
chk_contains "fallback 清空 timesyncd 上游" 'NTP_TIMESYNCD_SERVER=""' "$(cat "${SETUP}")"
chk_contains "--check 也渲染模板(不探测 master)" 'render_node_script "${NTP_AUTHORITY}"' "$(cat "${SETUP}")"
chk_contains "生成脚本保留既有 chrony 上游" "不重写任何上游配置" "$(cat "${SETUP}")"
chk_contains "fallback 启动已装 chrony" "systemctl enable --now chrony" "$(cat "${SETUP}")"
chk_contains "fallback 启动 timesyncd 兜底" "systemctl enable --now systemd-timesyncd" "$(cat "${SETUP}")"
chk_contains "fallback 要求 timesyncd 已同步" "timesyncd 已同步" "$(cat "${SETUP}")"
chk_contains "fallback 分支确认守护进程" "systemctl is-active chrony" "$(cat "${SETUP}")"
chk_contains "chrony 源检查要求 chrony active" "systemctl is-active --quiet chrony || systemctl is-active --quiet chronyd" "$(cat "${SETUP}")"
chk_contains "verify: timesyncd 需 NTPSynchronized=yes" "NTPSynchronized --value" "$(cat "${SETUP}")"
chk_contains "fallback timesyncd 未同步不置 DAEMON_OK" "TIMESYNCD-NOT-SYNCHRONIZED" "$(cat "${SETUP}")"
chk_not_contains "不再在生成后立即用旧默认值替换" 'sed -i "s|__AUTHORITY__|${NTP_AUTHORITY}|g" "${NODE_SCRIPT}"' "$(cat "${SETUP}")"

echo "== ⑤c fallback: 启动已装但未运行的时间服务(不改配置) =="
NODESCRIPT="${TMP}/ntp-node.sh"
awk '/^SERVER="__AUTHORITY__"/{f=1} f && /^EOF$/{exit} f{print}' "${SETUP}" > "${NODESCRIPT}"
sed -i -e 's|__AUTHORITY__||' -e 's|__TIMESYNCD_SERVER__||' "${NODESCRIPT}"
mkdir -p "${TMP}/ntpbin"
cat > "${TMP}/ntpbin/systemctl" <<'EOF'
#!/bin/bash
case "$1" in
    is-active) [ -f "${NTP_STATE_DIR}/$2.active" ]; exit $? ;;
    enable) svc="${@: -1}"; : > "${NTP_STATE_DIR}/${svc}.active"
            [ "${svc}" = "systemd-timesyncd" ] && : > "${NTP_STATE_DIR}/timesyncd-synced"
            exit 0 ;;
esac
exit 0
EOF
cat > "${TMP}/ntpbin/timedatectl" <<'EOF'
#!/bin/bash
if [ "$1" = "show" ] && [ "$2" = "-p" ] && [ "$3" = "NTPSynchronized" ] && [ "$4" = "--value" ]; then
    [ -f "${NTP_STATE_DIR}/timesyncd-synced" ] && echo yes || echo no
    exit 0
fi
exit 0
EOF
cat > "${TMP}/ntpbin/date" <<'EOF'
#!/bin/bash
if [ "$1" = "+%s%3N" ] && [ -n "${FAKE_NOW_MS:-}" ]; then echo "${FAKE_NOW_MS}"; exit 0; fi
exec /bin/date "$@"
EOF
chmod +x "${TMP}/ntpbin/systemctl" "${TMP}/ntpbin/timedatectl" "${TMP}/ntpbin/date"
: > "${TMP}/ntpbin/chronyd"; chmod +x "${TMP}/ntpbin/chronyd"
_ntp_ms=1700000000000
mkdir -p "${TMP}/ntpstate-a"
out_ntp="$(NTP_STATE_DIR="${TMP}/ntpstate-a" FAKE_NOW_MS="${_ntp_ms}" PATH="${TMP}/ntpbin" \
    /bin/bash "${NODESCRIPT}" apply "${_ntp_ms}" 2>&1)"
chk_contains "fallback 启动 chrony 后 SYNC-OK" "SYNC-OK" "${out_ntp}"
chk "fallback 已启动 chrony" "1" "$([ -f "${TMP}/ntpstate-a/chrony.active" ] && echo 1 || echo 0)"
chk "fallback 未额外启动 timesyncd" "0" "$([ -f "${TMP}/ntpstate-a/systemd-timesyncd.active" ] && echo 1 || echo 0)"
# 已 active 的 timesyncd(且已同步)不被 chrony 启动覆盖
mkdir -p "${TMP}/ntpstate-b"; : > "${TMP}/ntpstate-b/systemd-timesyncd.active"; : > "${TMP}/ntpstate-b/timesyncd-synced"
out_ntp2="$(NTP_STATE_DIR="${TMP}/ntpstate-b" FAKE_NOW_MS="${_ntp_ms}" PATH="${TMP}/ntpbin" \
    /bin/bash "${NODESCRIPT}" apply "${_ntp_ms}" 2>&1)"
chk_contains "active timesyncd 下仍 SYNC-OK" "SYNC-OK" "${out_ntp2}"
chk "active timesyncd 不被覆盖" "0" "$([ -f "${TMP}/ntpstate-b/chrony.active" ] && echo 1 || echo 0)"
# 无 chrony: 启动 timesyncd
rm -f "${TMP}/ntpbin/chronyd"
mkdir -p "${TMP}/ntpstate-c"
out_ntp3="$(NTP_STATE_DIR="${TMP}/ntpstate-c" FAKE_NOW_MS="${_ntp_ms}" PATH="${TMP}/ntpbin" \
    /bin/bash "${NODESCRIPT}" apply "${_ntp_ms}" 2>&1)"
chk_contains "无 chrony 启动 timesyncd 后 SYNC-OK" "SYNC-OK" "${out_ntp3}"
chk "无 chrony 启动 timesyncd" "1" "$([ -f "${TMP}/ntpstate-c/systemd-timesyncd.active" ] && echo 1 || echo 0)"
# timesyncd active 但未同步: 不得仅凭 active/一次性 date 报 SYNC-OK
mkdir -p "${TMP}/ntpstate-d"; : > "${TMP}/ntpstate-d/systemd-timesyncd.active"
out_ntp4="$(NTP_STATE_DIR="${TMP}/ntpstate-d" FAKE_NOW_MS="${_ntp_ms}" PATH="${TMP}/ntpbin" \
    /bin/bash "${NODESCRIPT}" apply "${_ntp_ms}" 2>&1)"
chk_contains "timesyncd 未同步给出明确提示" "TIMESYNCD-NOT-SYNCHRONIZED" "${out_ntp4}"
if printf '%s' "${out_ntp4}" | command grep -q 'SYNC-OK'; then
    echo "  FAIL timesyncd 未同步不应 SYNC-OK"; fail=1
else
    echo "  ok  timesyncd 未同步不报 SYNC-OK"
fi
chk "timesyncd 未同步不启动 chrony" "0" "$([ -f "${TMP}/ntpstate-d/chrony.active" ] && echo 1 || echo 0)"

echo "== ⑥ workerbm 自动装包已停用(OS 预装/手动) =="
chk_contains "workerbm 停用提示" "已停用" "$(cat "${WORKERBM}")"
chk_contains "workerbm 指向手动工具" "install-worker-packages" "$(cat "${WORKERBM}")"
chk_contains "workerbm 默认关闭自检" "WORKER_PKGS_ENABLED=false" "$(cat "${WORKERBM}")"
chk_contains "workerbm TOGGLE 声明" "TOGGLE: WORKER_PKGS_ENABLED" "$(cat "${WORKERBM}")"
chk "workerbm 不再调用自动装包" "0" \
    "$(command grep -c 'bash .*install-worker-packages' "${WORKERBM}" 2>/dev/null || true)"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-k8s-ntp: 全部通过"; else echo "❌ test-k8s-ntp: 有失败"; fi
exit "${fail}"
