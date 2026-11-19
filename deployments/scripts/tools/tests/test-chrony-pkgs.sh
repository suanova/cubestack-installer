#!/bin/bash
# ============================================================
# test-chrony-pkgs.sh — chrony 可选装包与 NTP 同步解耦的离线回归
# 背景(2026-11-19 用户口径):
#   安装 os/packages/chrony 是**可选**的, NTP 同步是**必选**的, 二者必须解耦:
#   k8s_ntp 只做同步(假设 chrony 已存在), chrony 装包由独立模块 chrony_pkgs 负责。
# 覆盖:
#   ① 模块元数据: DEFAULT:0 + TOGGLE:CHRONY_PKGS_ENABLED + REQUIRES k8s_passwordless
#   ② 默认值声明: cluster.defaults.conf 中 CHRONY_PKGS_ENABLED 默认 false
#   ③ 边界: 模块/工具不写 chrony.conf、不启停 NTP 服务; 使用 install_debs_offline 装包
#   ④ 调度: 全量部署在 NTP 之前执行(早于 k8s_ntp); 扩容在 05_k8s_ntp 之前调用
#   ⑤ 工具行为(假 ssh/scp): 已装跳过 / 缺包安装 / 安装集缺失硬失败 / SSH 不可用失败
# 隔离: 临时 cluster.conf + OFFLINE_FILES_ROOT + 假 ssh/scp(纯离线, 不碰真实节点)
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MODULE="${REPO_ROOT}/deployments/scripts/modules/02_k8s/00_chrony_pkgs.sh"
TOOL="${REPO_ROOT}/deployments/scripts/tools/node/install-chrony-packages.sh"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
DEPLOY="${REPO_ROOT}/deployments/scripts/deploy-cluster.sh"
DEFAULTS="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
SCALE="${REPO_ROOT}/deployments/scripts/modules/02_k8s/07_k8s_scale.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  FAIL $1: [$3] 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }

echo "== ① 模块元数据 =="
chk_contains "DEFAULT:0" "# DEFAULT: 0" "${MODULE}"
chk_contains "TOGGLE:CHRONY_PKGS_ENABLED" "# TOGGLE: CHRONY_PKGS_ENABLED" "${MODULE}"
chk_contains "REQUIRES k8s_passwordless" "# REQUIRES: k8s_passwordless" "${MODULE}"
chk_contains "模块调用装包工具" "tools/node/install-chrony-packages.sh" "${MODULE}"
chk_contains "模块开关自检" "CHRONY_PKGS_ENABLED=false" "${MODULE}"

echo "== ② 默认值声明 =="
# 只断言"有默认值声明"(允许部署容器把默认改成 true), 不绑定具体默认值
chk_contains "defaults 声明 CHRONY_PKGS_ENABLED" 'CHRONY_PKGS_ENABLED="${CHRONY_PKGS_ENABLED:-' "${DEFAULTS}"

echo "== ③ 装包/同步边界 =="
# 模块与工具只装包: 不得出现 chrony 配置/服务操作(NTP 同步的职责)
chk_not_contains "模块不写 /etc/chrony/chrony.conf" "/etc/chrony/chrony.conf" "${MODULE}"
chk_not_contains "模块不重启 chrony" "systemctl restart chrony" "${MODULE}"
chk_not_contains "工具不写 /etc/chrony/chrony.conf" "/etc/chrony/chrony.conf" "${TOOL}"
chk_not_contains "工具不重启 chrony" "systemctl restart chrony" "${TOOL}"
chk_contains "工具使用离线装包原语" "install_debs_offline" "${TOOL}"
chk_contains "工具引用专用安装集" "os/packages/chrony" "${TOOL}"
chk_contains "工具幂等跳过已装 chrony" "已安装 chrony(install ok installed), 跳过" "${TOOL}"
# 预卸 timesyncd 的安全门: 依赖预检 / 回滚包备份 / 失败恢复
chk_contains "预卸前做离线依赖预检" "_deb_set_missing" "${LIB}"
chk_contains "预卸前备份时间提供者" "_time_daemon_backup" "${LIB}"
chk_contains "替换失败恢复时间提供者" "_time_daemon_restore" "${LIB}"
chk_contains "工具收集回滚 deb" "rollback/" "${TOOL}"
chk_contains "工具收集 timesyncd 回滚包" "systemd-timesyncd_*.deb" "${TOOL}"
chk_contains "工具就绪前校验包状态" "assert_pkgs_ready chrony" "${TOOL}"
chk_contains "工具跳过依据 dpkg 状态" "install ok installed" "${TOOL}"
chk_contains "批量成功后校验目标包" 'assert_pkgs_ready ${want}' "${LIB}"
chk_not_contains "预卸失败不再被 || true 吞掉" 'dpkg --purge "${c}" >>"${dlog}" 2>&1 || true' "${LIB}"

# setup-ntp 侧不再内嵌装包(与 test-k8s-ntp 的围栏互补)
SETUP="${REPO_ROOT}/deployments/scripts/tools/node/setup-ntp.sh"
chk_not_contains "setup-ntp 不内嵌装包原语" "install_debs_offline" "${SETUP}"
chk_not_contains "setup-ntp 不引用 chrony 专用安装集" "os/packages/chrony" "${SETUP}"

echo "== ④ 调度顺序 =="
chk_contains "deploy-cluster 有安装前 chrony 装包阶段" "CUBESTACK_EARLY_CHRONY_PKGS_DONE" "${DEPLOY}"
chk_contains "装包阶段调用 run_module chrony_pkgs" "run_module chrony_pkgs" "${DEPLOY}"
_chrony_line="$(grep -n 'CUBESTACK_EARLY_CHRONY_PKGS_DONE=1' "${DEPLOY}" | head -1 | cut -d: -f1)"
_ntp_line="$(grep -n 'CUBESTACK_EARLY_NTP_DONE=1' "${DEPLOY}" | head -1 | cut -d: -f1)"
if [ -n "${_chrony_line}" ] && [ -n "${_ntp_line}" ] && [ "${_chrony_line}" -lt "${_ntp_line}" ]; then
    echo "  ok  chrony 装包阶段在 NTP 阶段之前(chrony=${_chrony_line} ntp=${_ntp_line})"
else
    echo "  FAIL 阶段顺序: chrony=${_chrony_line:-空} ntp=${_ntp_line:-空}"; fail=1
fi
_sc="$(grep -n '00_chrony_pkgs.sh' "${SCALE}" | head -1 | cut -d: -f1)"
_sn="$(grep -n '05_k8s_ntp.sh' "${SCALE}" | head -1 | cut -d: -f1)"
if [ -n "${_sc}" ] && [ -n "${_sn}" ] && [ "${_sc}" -lt "${_sn}" ]; then
    echo "  ok  扩容先装 chrony 再做 NTP(chrony=${_sc} ntp=${_sn})"
else
    echo "  FAIL 扩容顺序: chrony=${_sc:-空} ntp=${_sn:-空}"; fail=1
fi

echo "== ⑤ 工具行为(假 ssh/scp) =="
cat > "${TMP}/cluster.conf" <<'EOF'
NODES=("master,m1,10.0.0.1,root,-")
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF
mkdir -p "${TMP}/offline/os/packages/chrony" "${TMP}/bin"
: > "${TMP}/offline/os/packages/chrony/chrony_4.2-fake_amd64.deb"
cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in
        -i|-o|-p|-l) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
host="$1"; shift
cmd="$*"
printf '%s\t%s\n' "${host}" "${cmd}" >> "${FAKE_SSH_LOG:-/dev/null}"
[ "${FAKE_SSH_DOWN:-0}" = "1" ] && exit 255
case "${cmd}" in
    true) exit 0 ;;
    *"command -v chronyd"*) [ "${FAKE_CHRONY_PRESENT:-1}" = "1" ] && exit 0 || exit 1 ;;
    *"bash /tmp/cubestack-chrony-install.sh"*) echo "CHRONY-READY:4.2-fake"; exit 0 ;;
    *) exit 0 ;;
esac
FAKE
cat > "${TMP}/bin/scp" <<'FAKE'
#!/bin/bash
echo "$*" >> "${FAKE_SCP_LOG:-/dev/null}"
exit 0
FAKE
chmod +x "${TMP}/bin/ssh" "${TMP}/bin/scp"

run_tool() {  # run_tool <chrony_present 0|1> <ssh_down 0|1> <offline_root>
    local present="$1" down="$2" root="$3"
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf"
        export OFFLINE_FILES_ROOT="${root}"
        export SSH_KEY_DIR="${TMP}/no-key"
        export FAKE_SSH_LOG="${TMP}/ssh.log"
        export FAKE_SCP_LOG="${TMP}/scp.log"
        export FAKE_CHRONY_PRESENT="${present}"
        export FAKE_SSH_DOWN="${down}"
        : > "${FAKE_SSH_LOG}"; : > "${FAKE_SCP_LOG}"
        bash "${TOOL}"
    ) > "${TMP}/out" 2>&1
    echo $?
}

rc="$(run_tool 1 0 "${TMP}/offline")"
chk "已装 chrony: 退出码 0" "0" "${rc}"
chk_contains "已装 chrony: 跳过提示" "已安装 chrony(install ok installed), 跳过" "${TMP}/out"
chk "已装 chrony: 不上传安装集" "0" "$(wc -l < "${TMP}/scp.log")"

rc="$(run_tool 0 0 "${TMP}/offline")"
chk "缺 chrony: 退出码 0" "0" "${rc}"
chk_contains "缺 chrony: 输出就绪" "CHRONY-READY" "${TMP}/out"
chk_contains "缺 chrony: 执行远端安装脚本" "bash /tmp/cubestack-chrony-install.sh" "${TMP}/ssh.log"
if [ "$(wc -l < "${TMP}/scp.log")" -ge 1 ]; then
    echo "  ok  缺 chrony: 上传安装集/脚本($(wc -l < "${TMP}/scp.log") 次 scp)"
else
    echo "  FAIL 缺 chrony: 未上传安装集/脚本"; fail=1
fi

rc="$(run_tool 0 0 "${TMP}/offline-missing")"
chk "安装集缺失: 退出码 1" "1" "${rc}"
chk_contains "安装集缺失: 明确报目录" "未找到 chrony 专用安装集目录" "${TMP}/out"

rc="$(run_tool 0 1 "${TMP}/offline")"
chk "SSH 不可用: 退出码 1" "1" "${rc}"
chk_contains "SSH 不可用: 明确报 SSH/sudo" "SSH/sudo 不可用" "${TMP}/out"
chk "SSH 不可用: 不上传安装集" "0" "$(wc -l < "${TMP}/scp.log")"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-chrony-pkgs: 全部通过"
else
    echo "❌ test-chrony-pkgs: 存在失败项"
fi
exit "${fail}"
