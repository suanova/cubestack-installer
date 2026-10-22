#!/bin/bash
# ============================================================
# test-reconcile-node-packages.sh — 节点包对账的"卡死前检测"离线回归
# 背景(2026-10-19 实机): 旧集群拆除后 6 台节点残留 /mnt/cephfs/models ceph 挂载
#   (mons 已不可达) + 旧 rbd 映射; reconcile-node-packages.sh 的 fuser apt 锁检查
#   进入 D 状态(ceph_mdsc_wait_request) → node_pkgs 永久 pending。
# 覆盖:
#   ① D 状态/fuser 超时(僵尸态): 在 scp/装包之前就失败, 并给出重启指引
#   ② 活动且健康的 Ceph/RBD(当前集群在用): 不阻断, 正常进入装包
#   ②b 挂载不健康但未卡死: 控制器放行, 远端自动 stop/umount/rbd unmap
#   ③ 干净节点: 前置探测通过, 正常进入 scp/装包流程
#   ④ 远端脚本静态围栏: 检测在 apt 锁检查之前; 自动修复动作与 fuser timeout 在位
#   ⑤ 远端装包调用带 RECONCILE_SSH_TIMEOUT
#   ⑥ SSH 认证失败(密码/公钥被拒)/网络不可达: 必须报 SSH 问题, **不得**误导成
#      "Ceph/RBD 残留 → 重启"(2026-10-22 用户实机: 密码错 → 提示重启节点)
# 隔离: 临时 cluster.conf + OFFLINE_FILES_ROOT + 假 ssh/scp(纯离线)
# 用法: bash deployments/scripts/tools/tests/test-reconcile-node-packages.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${REPO_ROOT}/deployments/scripts/tools/node/reconcile-node-packages.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  FAIL $1: [$3] 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }

# 临时配置/离线目录
cat > "${TMP}/cluster.conf" <<'EOF'
NODES=("worker,w1,10.0.0.1,root,-")
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF
mkdir -p "${TMP}/offline/os/packages"
: > "${TMP}/offline/os/packages/dummy.deb"
mkdir -p "${TMP}/bin"
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
case "${cmd}" in
    *"findmnt -t ceph,rbd"*)
        case "${FAKE_WEDGED:-1}" in
            1) echo "ceph/rbd-mount: /mnt/cephfs/models ceph (mons unreachable)"; exit 2 ;;
            2) echo "active-ceph-ok: /mnt/cephfs/models ceph"; echo "active-rbd-ok: 2"; exit 0 ;;
            3) echo "auto-repair-needed: /mnt/cephfs/models"; exit 0 ;;
            4) echo "ubuntu@10.0.0.1: Permission denied (publickey,password)." >&2; exit 255 ;;
            5) echo "ssh: connect to host 10.0.0.1 port 22: Connection timed out" >&2; exit 255 ;;
            *) exit 0 ;;
        esac ;;
    *) exit 0 ;;
esac
FAKE
cat > "${TMP}/bin/scp" <<'FAKE'
#!/bin/bash
echo "$*" >> "${FAKE_SCP_LOG:-/dev/null}"
exit 0
FAKE
chmod +x "${TMP}/bin/ssh" "${TMP}/bin/scp"

run_tool() {  # run_tool <wedged 0|1> → stdout/stderr 在 $TMP/out
    local wedged="$1"
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline"
        export FAKE_SSH_LOG="${TMP}/ssh-${wedged}.log"
        export FAKE_SCP_LOG="${TMP}/scp-${wedged}.log"
        export FAKE_WEDGED="${wedged}"
        : > "${FAKE_SSH_LOG}"; : > "${FAKE_SCP_LOG}"
        bash "${TOOL}" --ip 10.0.0.1 --user root
    ) > "${TMP}/out-${wedged}" 2>&1
    echo $?
}

echo "== ① 残留节点: 必须在 scp/装包前失败 =="
rc="$(run_tool 1)"
chk "退出码" "1" "${rc}"
chk_contains "给出重启指引" "重启" "${TMP}/out-1"
chk_contains "点名 ceph/rbd 残留" "ceph/rbd-mount" "${TMP}/out-1"
chk "未执行 scp(未分发离线包)" "0" "$(wc -l < "${TMP}/scp-1.log")"
chk "前置探测已执行" "1" "$(grep -c 'findmnt -t ceph,rbd' "${TMP}/ssh-1.log")"

echo "== ② 干净节点: 前置探测通过并进入装包 =="
rc="$(run_tool 0)"
chk "退出码" "0" "${rc}"
chk "执行了 scp" "1" "$(wc -l < "${TMP}/scp-0.log")"
chk "执行了远端装包脚本" "1" "$(grep -c 'sudo bash /tmp/cubestack-debs/' "${TMP}/ssh-0.log")"

echo "== ②b 活动且健康的 Ceph/RBD(当前集群在用): 不阻断 =="
rc="$(run_tool 2)"
chk "退出码" "0" "${rc}"
chk "执行了 scp" "1" "$(wc -l < "${TMP}/scp-2.log")"
chk "执行了远端装包脚本" "1" "$(grep -c 'sudo bash /tmp/cubestack-debs/' "${TMP}/ssh-2.log")"
chk_contains "日志点名活动 Ceph/RBD" "活动 Ceph/RBD 健康" "${TMP}/out-2"

echo "== ②c 挂载不健康但未卡死: 控制器放行, 远端自动修复 =="
rc="$(run_tool 3)"
chk "退出码" "0" "${rc}"
chk "执行了 scp(自动修复在远端进行)" "1" "$(wc -l < "${TMP}/scp-3.log")"
chk_contains "日志点名自动卸载/解映射" "自动卸载/解映射" "${TMP}/out-3"

echo "== ②d SSH 认证失败(密码/公钥被拒): 必须报 SSH, 不得误导为 Ceph/RBD/重启 =="
rc="$(run_tool 4)"
chk "退出码" "1" "${rc}"
chk_contains "点名 SSH 认证失败" "SSH 认证失败" "${TMP}/out-4"
chk_contains "给出密码核对指引" "SSH_DEFAULT_PASSWORD" "${TMP}/out-4"
chk_not_contains "不误导为 Ceph/RBD 残留" "Ceph/RBD 残留" "${TMP}/out-4"
chk_not_contains "不提示重启节点" "reboot -f" "${TMP}/out-4"
chk "未执行 scp(认证都没过)" "0" "$(wc -l < "${TMP}/scp-4.log")"

echo "== ②e SSH 网络不可达: 报网络问题, 不提示重启 =="
rc="$(run_tool 5)"
chk "退出码" "1" "${rc}"
chk_contains "点名网络不可达" "网络不可达" "${TMP}/out-5"
chk_not_contains "不提示重启节点" "reboot -f" "${TMP}/out-5"
chk "未执行 scp" "0" "$(wc -l < "${TMP}/scp-5.log")"

echo "== ③ 远端脚本静态围栏 =="
awk '/<<.REMOTE_EOF./{f=1;next} /^REMOTE_EOF$/{f=0} f' "${TOOL}" > "${TMP}/remote.sh"
[ -s "${TMP}/remote.sh" ] && echo "  ok  远端脚本已提取" || { echo "  FAIL 远端脚本提取为空"; fail=1; }
chk_contains "检测 ceph/rbd 挂载" "findmnt -t ceph,rbd" "${TMP}/remote.sh"
chk_contains "fuser 带 timeout" "timeout 5 fuser /var/lib/dpkg/lock-frontend" "${TMP}/remote.sh"
_detect="$(grep -n 'findmnt -t ceph,rbd' "${TMP}/remote.sh" | head -1 | cut -d: -f1)"
_lock="$(grep -n 'timeout 5 fuser /var/lib/dpkg/lock-frontend' "${TMP}/remote.sh" | head -1 | cut -d: -f1)"
if [ -n "${_detect}" ] && [ -n "${_lock}" ] && [ "${_detect}" -lt "${_lock}" ]; then
    echo "  ok  ceph/rbd 检测在 apt 锁检查之前(detect=${_detect} lock=${_lock})"
else
    echo "  FAIL 检测顺序: detect=${_detect:-空} lock=${_lock:-空}"; fail=1
fi
chk_contains "D 状态匹配 rbd/ceph" "rbd|ceph" "${TMP}/remote.sh"
chk_contains "自动卸载挂载" "umount -l" "${TMP}/remote.sh"
chk_contains "自动解映射 rbd" "rbd unmap" "${TMP}/remote.sh"
chk_contains "自动修复前停 kubelet/containerd" "systemctl stop kubelet containerd" "${TMP}/remote.sh"
chk_contains "仅僵尸态提示重启" "D 状态/fuser 超时" "${TMP}/remote.sh"
chk_contains "活动健康挂载放行" "活动 Ceph/RBD(健康" "${TMP}/remote.sh"
# 2026-10-19 实机: 逐包 apt-get install 导致 systemd/udev 版本组混合(libudev1 3.22 +
#   systemd/libsystemd0 3.21), 每轮 --fresh 都告警。必须整批交给 apt 求解。
chk_contains "离线 deb 整批交给 apt 求解" '--no-remove install "${_TO_DEBS[@]}"' "${TMP}/remote.sh"
chk_contains "整批失败才逐包兜底" "整批安装失败" "${TMP}/remote.sh"

echo "== ④ 远端装包超时 =="
chk_contains "RECONCILE_SSH_TIMEOUT" "RECONCILE_SSH_TIMEOUT" "${TOOL}"
chk_contains "调用被 timeout 包裹" "timeout \"\${RECONCILE_SSH_TIMEOUT}\" ssh" "${TOOL}"

echo "== ⑤ worker 装包: Breaks ↔ 同版本 cohort =="
TOOL2="${REPO_ROOT}/deployments/scripts/tools/node/install-worker-packages.sh"
chk_contains "解析 deb Breaks 字段" 'dpkg-deb -f "$f" Breaks' "${TOOL2}"
chk_contains "Breaks 触发同版本 cohort 升级" "FORCE_COHORT" "${TOOL2}"
chk_contains "离线无可升级版时跳过(不制造半装)" "离线集无该包升级版" "${TOOL2}"
chk_contains "cohort 一并加入待装集合" "同版本 cohort 升级(版本" "${TOOL2}"
chk "Breaks 算子解析支持 << / >>(实机 udev Breaks 曾是 < 误判)" "2" \
    "$(grep -cF '([<>]{1,2}=?|=)' "${TOOL2}")"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-reconcile-node-packages: 全部通过"
else
    echo "❌ test-reconcile-node-packages: 存在失败项"
fi
exit "${fail}"
