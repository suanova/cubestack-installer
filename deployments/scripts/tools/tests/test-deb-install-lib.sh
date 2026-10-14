#!/bin/bash
# ============================================================
# 夹具: 离线 deb 安装原语(lib-common::deb_install_remote_lib / pkg_conflict_providers)
# 钉住 2026-10-14 三轮实机事故的行为口径(防回归):
#   ① 互斥提供者预卸(time-daemon 系: chrony↔systemd-timesyncd)
#   ② 已装即跳(任何版本; 只补缺不升级 —— 防打断既有版本钉, 实机 libtinfo6↔libncurses6)
#   ③ 批量 dpkg 失败 → 逐包隔离重试(一包不连坐)
#   ④ 互斥表两处(lib-common 宿主版 / DEBLIB 节点版)保持同步
#   ⑤ setup-ntp 静态围栏: 权威可达性预检在位; **无可执行**的 apt --fix-broken(禁令)
# 机制: 假 dpkg/dpkg-query/dpkg-deb 垫片(记录调用 + 可控已装库/失败注入), 根因见 lib-common 注释。
# ============================================================
set -uo pipefail

_DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # = deployments/(tests→tools→scripts→deployments)
# shellcheck source=lib-common.sh
source "${_DEPLOY_DIR}/scripts/lib-common.sh"

_fail=0
chk() {  # <名称> <期望> <实际>
    if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1 (期望=$2 实际=$3)"; _fail=1; fi
}

SB="$(mktemp -d)"; trap 'rm -rf "${SB}"' EXIT
export SB
mkdir -p "${SB}/debs.d" "${SB}/debs"

# ── 假 dpkg 三件套(垫片) ──
cat > "${SB}/dpkg-query" <<'EOF'
#!/bin/bash
# 本夹具只用 `dpkg-query -W -f='${Status}' <pkg>` 一种形态
pkg="${@: -1}"
if grep -qx "${pkg}" "${SB}/installed.list" 2>/dev/null; then
    echo "install ok installed"; exit 0
fi
echo "unknown ok not-installed"; exit 1
EOF
cat > "${SB}/dpkg-deb" <<'EOF'
#!/bin/bash
# `dpkg-deb -f <file> Package`
f="$2"
cat "${SB}/debs.d/$(basename "${f}").pkg" 2>/dev/null || true
EOF
cat > "${SB}/dpkg" <<'EOF'
#!/bin/bash
echo "dpkg $*" >> "${SB}/calls.log"
if [ "$1" = "--purge" ]; then
    sed -i "/^$2$/d" "${SB}/installed.list" 2>/dev/null || true
    exit 0
fi
n=0; has_fail=0
for a in "$@"; do
    case "$a" in *.deb) n=$((n + 1)) ;; esac
    case "$a" in *faildeb*) has_fail=1 ;; esac
done
# 注入: 批量(>1 个)时失败; 单包且是 faildeb 时失败(隔离重试里仍会失败)
if [ "${SB_FAIL_BATCH:-0}" = "1" ] && [ "${n}" -gt 1 ]; then exit 1; fi
if [ "${has_fail}" = "1" ] && [ "${n}" -ge 1 ]; then exit 1; fi
exit 0
EOF
chmod +x "${SB}"/dpkg-query "${SB}"/dpkg-deb "${SB}"/dpkg
export PATH="${SB}:${PATH}"

mk_deb() { touch "${SB}/debs/$1.deb"; echo "$1" > "${SB}/debs.d/$1.deb.pkg"; }
mk_deb chrony; mk_deb libfoo

_run_lib() {  # <debs目录> <关注包>
    ( deb_install_remote_lib; printf '\ninstall_debs_offline %q %s\n' "$1" "$2" ) | bash
}

echo "== ① 互斥预卸 + 已装即跳 =="
printf 'systemd-timesyncd\nlibfoo\n' > "${SB}/installed.list"   # timesyncd 已装(互斥提供者); libfoo 已装(应跳过)
: > "${SB}/calls.log"
_run_lib "${SB}/debs" "chrony" > "${SB}/out1" 2>&1 || true
chk "①预卸互斥包 timesyncd" "1" "$(grep -c -- '--purge systemd-timesyncd' "${SB}/calls.log")"
chk "①只装未装的 chrony(不含已装 libfoo)" "0" "$(grep -c 'libfoo.deb' "${SB}/calls.log")"
chk "①chrony 进入了安装" "1" "$(grep -c 'chrony.deb' "${SB}/calls.log")"
chk "①预卸发生在安装之前" "1" \
    "$(awk '/--purge/{p=NR} /chrony.deb/{c=NR} END{print (p && c && p < c) ? 1 : 0}' "${SB}/calls.log")"

echo "== ② 批量失败 → 逐包隔离 =="
printf 'systemd-timesyncd\n' > "${SB}/installed.list"           # 不触发预卸场景; libfoo 未装
mk_deb faildeb
: > "${SB}/calls.log"
export SB_FAIL_BATCH=1
_run_lib "${SB}/debs" "chrony" > "${SB}/out2" 2>&1 || true
unset SB_FAIL_BATCH
chk "②出现逐包隔离重试(单包 dpkg 调用 ≥2)" "1" \
    "$(awk '/dpkg -i/{n++; if (n>=2) f=1} END{print (f ? 1 : 0)}' "${SB}/calls.log")"
chk "②隔离结果输出含'隔离结果'" "1" "$(grep -c '隔离结果' "${SB}/out2")"

echo "== ③ 互斥表两处同步 =="
_host_tbl="$(pkg_conflict_providers chrony)"
_emit_tbl="$( { deb_install_remote_lib; echo '_pkg_conflict_providers chrony'; } | bash )"
chk "③宿主表 = 节点表(chrony)" "${_host_tbl}" "${_emit_tbl}"

echo "== ④ setup-ntp 静态围栏 =="
_SETUP_NTP="${_DEPLOY_DIR}/scripts/tools/node/setup-ntp.sh"
chk "④权威可达性预检在位" "1" "$(grep -c 'NTP 权威 ${NTP_AUTHORITY} 不可达' "${_SETUP_NTP}")"
chk "④无可执行的 apt --fix-broken(禁令)" "0" "$(grep -cE '^[[:space:]]*apt-get --fix-broken' "${_SETUP_NTP}")"
chk "④离线安装改调共享原语" "1" "$(grep -c 'install_debs_offline /tmp/cubestack-ntp-debs chrony' "${_SETUP_NTP}")"

echo "---------------------------------------------"
if [ "${_fail}" = "0" ]; then echo "✅ deb 安装原语夹具全部通过"; else echo "❌ 存在失败断言"; exit 1; fi
