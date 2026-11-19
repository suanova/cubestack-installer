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
#   ⑦ 扩容 ONLY_HOSTS 过滤: 不传 --ip 时只处理 ONLY_HOSTS 匹配的新节点, 不碰已有节点;
#      ONLY_HOSTS 未设置时保持全量行为(2026-11-19 CodeRabbit)
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
        case "${FAKE_WEDGED:-0}" in
            0) exit 0 ;;                                                  # 干净节点(无输出)
            1) echo "repair-needed: /mnt/cephfs/models"; exit 0 ;;        # 逐挂载确认读不出 → 仅卸载该挂载
            2) echo "active-ceph-ok: /mnt/cephfs/models ceph"; echo "active-rbd-ok: 2"; exit 0 ;;
            3) echo "d-state-unrelated: 123 D rsync -a /data"; exit 0 ;;  # 非存储 D 状态 → 不修复
            4) echo "ubuntu@10.0.0.1: Permission denied (publickey,password)." >&2; exit 255 ;;
            5) echo "ssh: connect to host 10.0.0.1 port 22: Connection timed out" >&2; exit 255 ;;
            6) echo "d-state-storage: 123 D dpkg --configure -a"; exit 0 ;;   # D 状态+存储 → 不自动卸载
            7) exit 124 ;;                                                # 探测超时
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

echo "== ① 存储不健康(逐挂载确认): 仅卸载确认挂载, 仍不健康则失败 =="
rc="$(run_tool 1)"
chk "退出码" "1" "${rc}"
chk_contains "给出重启指引" "重启" "${TMP}/out-1"
chk_contains "点名存储不健康" "存储不健康" "${TMP}/out-1"
chk "未执行 scp(未分发离线包)" "0" "$(wc -l < "${TMP}/scp-1.log")"
# 初探 + 修复后重探 = 2 次 findmnt 探测
chk "自动修复后重探(初探+重探=2)" "2" "$(grep -c 'findmnt -t ceph,rbd' "${TMP}/ssh-1.log")"
# 2026-11-04 (CodeRabbit): 只卸载"逐挂载检查确认读不出"的挂载(作为参数传入), 不碰健康卷
chk_contains "仅卸载确认挂载(传入参数)" "sudo bash -s -- /mnt/cephfs/models" "${TMP}/ssh-1.log"
# 修复未清除时恢复 kubelet/containerd(restore 命令以 "sudo bash -s" 结尾, 无参数)
chk "修复失败后恢复服务" "1" "$(grep -cE 'sudo bash -s$' "${TMP}/ssh-1.log")"

echo "== ①b 非存储 D 状态(rsync): 不触发修复, 继续装包 =="
rc="$(run_tool 3)"
chk "退出码" "0" "${rc}"
chk "执行了 scp(不阻断)" "1" "$(wc -l < "${TMP}/scp-3.log")"
chk_contains "日志点名非存储 D 状态" "非存储 D 状态" "${TMP}/out-3"
chk_not_contains "未触发卸载" "sudo bash -s --" "${TMP}/ssh-3.log"

echo "== ①c D 状态 + 存储挂载: 默认忽略并继续(覆盖安装口径), 不自动卸载 =="
rc="$(run_tool 6)"
chk "退出码" "0" "${rc}"
chk "执行了 scp(不阻断)" "1" "$(wc -l < "${TMP}/scp-6.log")"
chk_not_contains "未自动卸载" "sudo bash -s --" "${TMP}/ssh-6.log"
chk_contains "日志点名已忽略" "已忽略" "${TMP}/out-6"
# CodeRabbit 2026-11-05: 控制器放行 D 状态时, 远端安装器必须收到同一策略
chk_contains "远端安装器收到 --allow-dstate" "--allow-dstate" "${TMP}/ssh-6.log"

echo "== ①c2 NODE_PKGS_ALLOW_DSTATE=0: 恢复硬失败(旧行为) =="
(
    export PATH="${TMP}/bin:${PATH}"
    export CLUSTER_CONF="${TMP}/cluster.conf"
    export OFFLINE_FILES_ROOT="${TMP}/offline"
    export FAKE_SSH_LOG="${TMP}/ssh-6s.log"
    export FAKE_SCP_LOG="${TMP}/scp-6s.log"
    export FAKE_WEDGED=6
    export NODE_PKGS_ALLOW_DSTATE=0
    : > "${FAKE_SSH_LOG}"; : > "${FAKE_SCP_LOG}"
    bash "${TOOL}" --ip 10.0.0.1 --user root
) > "${TMP}/out-6s" 2>&1
chk "strict 退出码" "1" "$?"
chk "strict 未执行 scp" "0" "$(wc -l < "${TMP}/scp-6s.log")"
chk_contains "strict 提示需重启" "重启" "${TMP}/out-6s"

echo "== ①d 探测超时: 不自动修复, 失败 =="
rc="$(run_tool 7)"
chk "退出码" "1" "${rc}"
chk "未执行 scp" "0" "$(wc -l < "${TMP}/scp-7.log")"
chk_not_contains "未自动卸载" "sudo bash -s --" "${TMP}/ssh-7.log"

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

echo "== ②c (已并入 ①b: 非存储 D 状态不阻断; 存储不健康在 ① 验证) =="

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
# CodeRabbit 2026-11-05: 远端 D-state 门禁必须跟随控制器策略; fuser 超时仍硬失败;
# D 状态存在时不做挂载健康探测/自动卸载(避免误卸正被僵尸进程引用的挂载)
chk_contains "远端接受 --allow-dstate" "--allow-dstate" "${TMP}/remote.sh"
chk_contains "远端读取 ALLOW_DSTATE" "ALLOW_DSTATE" "${TMP}/remote.sh"
chk_contains "D 状态时跳过挂载修复" "_skip_ceph_repair" "${TMP}/remote.sh"
chk_contains "fuser 超时仍硬失败" "fuser /var/lib/dpkg/lock-frontend 超时" "${TMP}/remote.sh"
chk_contains "仅僵尸态提示重启" "节点存在 D 状态进程" "${TMP}/remote.sh"
chk_contains "活动健康挂载放行" "活动 Ceph/RBD(健康" "${TMP}/remote.sh"
# 2026-10-19 实机: 逐包 apt-get install 导致 systemd/udev 版本组混合(libudev1 3.22 +
#   systemd/libsystemd0 3.21), 每轮 --fresh 都告警。必须整批交给 apt 求解。
chk_contains "离线 deb 整批交给 apt 求解" '--no-remove install "${_TO_DEBS[@]}"' "${TMP}/remote.sh"
chk_contains "整批失败才逐包兜底" "整批安装失败" "${TMP}/remote.sh"

echo "== ④ 远端装包超时 =="
chk_contains "RECONCILE_SSH_TIMEOUT" "RECONCILE_SSH_TIMEOUT" "${TOOL}"
chk_contains "调用被 timeout 包裹" "timeout \"\${RECONCILE_SSH_TIMEOUT}\" ssh" "${TOOL}"
# all_node_ips 是单行空格分隔 → 回退路径必须按空白拆分, 不能 read 一行当单 IP
# 2026-11-19: 回退改为遍历 NODES + node_matches, 扩容时必须按 ONLY_HOSTS 过滤。
chk_contains "inventory 目标按 ONLY_HOSTS 过滤" 'node_matches "${_hn}"' "${TOOL}"
chk_contains "NODES 回退按 ONLY_HOSTS 过滤" 'node_matches "${NODE_HOSTNAME}"' "${TOOL}"
chk_not_contains "不再无过滤使用 all_node_ips" 'for ip in $(all_node_ips)' "${TOOL}"
# 2026-11-19 CodeRabbit: initramfs 配置恢复失败时必须保留备份并提示路径(不能 cp 失败仍 rm)
chk_contains "reconcile 恢复失败保留备份" "备份保留在" "${TOOL}"
chk_contains "reconcile 备份失败不做无备份修改" "不做无备份的修改" "${TOOL}"
# 2026-11-19 CodeRabbit: 恢复失败必须返回非零, 不能因 apt 健康就报告对账成功
chk_contains "reconcile 恢复失败让对账失败" "拒绝报告成功" "${TOOL}"

echo "== ⑤ worker 装包: Breaks ↔ 同版本 cohort =="
TOOL2="${REPO_ROOT}/deployments/scripts/tools/node/install-worker-packages.sh"
chk_contains "解析 deb Breaks 字段" 'dpkg-deb -f "$f" Breaks' "${TOOL2}"
chk_contains "Breaks 触发同版本 cohort 升级" "FORCE_COHORT" "${TOOL2}"
chk_contains "离线无可升级版时跳过(不制造半装)" "离线集无该包升级版" "${TOOL2}"
chk_contains "cohort 一并加入待装集合" "同版本 cohort 升级(版本" "${TOOL2}"
_breaks_block="$(sed -n '/# ── ①b Breaks/,/# ② 依赖预检/p' "${TOOL2}")"
chk "Breaks 算子解析支持 << / >>(实机 udev Breaks 曾是 < 误判)" "2" \
    "$(printf '%s\n' "${_breaks_block}" | grep -cF '([<>]{1,2}=?|=)')"
unset _breaks_block
# 2026-11-19 CodeRabbit: rc(config-files)/半装状态不能被当成 usable installed
chk_contains "worker 仅 ii 记为可用已装" 'ii) REMOTE_VER' "${TOOL2}"
chk_contains "worker 归一化 Status-Abbrev 尾随空格" "tr -d '[:space:]'" "${TOOL2}"
chk_contains "worker 跟踪仅剩配置(rc)" "REMOTE_CONFIG_ONLY" "${TOOL2}"
chk_contains "worker 相关破损包参与修复" "BROKEN_RELEVANT" "${TOOL2}"
chk_contains "worker 空计划前执行修复" "半装状态已执行修复" "${TOOL2}"
chk_contains "worker 修复失败不报成功" "远端半装修复失败" "${TOOL2}"
chk_contains "worker 待装时间提供者只保留一个" "本次只保留" "${TOOL2}"
chk_contains "worker 已装时间提供者优先" "节点已装 \${_td_keep}" "${TOOL2}"
# CodeRabbit 2026-11-19: fresh 节点 purge 必须在探测/选包之前, 否则 REMOTE_VER 会把
# 已被 purge 的 runc/containerd 当成满足依赖.
_purge_ln="$(grep -n 'apt-get purge -y containerd containerd.io runc' "${TOOL2}" 2>/dev/null | head -1 | cut -d: -f1)"
_probe_ln="$(grep -n '探测节点' "${TOOL2}" 2>/dev/null | head -1 | cut -d: -f1)"
if [ -n "${_purge_ln}" ] && [ -n "${_probe_ln}" ] && [ "${_purge_ln}" -lt "${_probe_ln}" ]; then
    echo "  ok  worker fresh purge 在探测/选包之前(purge=${_purge_ln} probe=${_probe_ln})"
else
    echo "  FAIL worker fresh purge 顺序: purge=${_purge_ln:-空} probe=${_probe_ln:-空}"; fail=1
fi
unset _purge_ln _probe_ln
# 2026-11-19 CodeRabbit: 系统容器包 purge 必须由调用方**显式声明 fresh** 才允许;
# kubelet inactive 不能单独作为判据(维护中的已 join worker 会被误 purge).
chk_contains "worker fresh purge 需显式声明(env)" "CUBESTACK_FRESH_NODE" "${TOOL2}"
chk_contains "worker fresh purge 支持 --fresh-node" "--fresh-node" "${TOOL2}"
chk_contains "worker 未声明 fresh 即跳过清理" "未声明 fresh 节点" "${TOOL2}"
chk_contains "worker purge 受显式 fresh 开关控制" 'if [ "${FRESH_NODE}" = "1" ]; then' "${TOOL2}"
# 2026-11-19 CodeRabbit: 探测失败不能被 `|| true` 当成空清单(会把已装包当未装,
# 用离线旧版本覆盖重装); 探测输出必须有完成哨兵, 失败要重试/中止.
chk_contains "worker 探测失败不得继续选包" "拒绝在空/残缺清单上继续选包" "${TOOL2}"
chk_contains "worker 探测输出要求完成哨兵" "probe_done=1" "${TOOL2}"
chk_contains "worker 探测失败重试" "包清单探测失败(第" "${TOOL2}"
# 2026-11-19 CodeRabbit: 依赖备选要按具体包名或 Provides 虚拟名解析
# (版本化 Provides 才满足带版本依赖; 已装/待装/离线候选三侧都要算提供者)
chk_contains "worker 依赖解析虚拟提供者" "_dep_planned_prov_ok" "${TOOL2}"
chk_contains "worker 探测采集已装 Provides" "prov|" "${TOOL2}"
# 2026-11-19 CodeRabbit: 虚拟提供者候选必须保留全部版本(精确约束 `(=2)` 可命中较低提供版本)
chk_contains "worker 虚拟候选保留全部版本" "_dep_prov_cands" "${TOOL2}"
chk_not_contains "worker 不再只保留最高提供版本" "_dep_prov_deb" "${TOOL2}"
# 2026-11-19 CodeRabbit: 依赖判定必须用"计划选中版本"的 Provides; 已装 metadata 仅对不被替换的包有效
chk_contains "worker 已装 Provides 排除计划替换包" "skip_planned" "${TOOL2}"
chk_contains "worker 计划 Provides 用选中版本" "_need_prov" "${TOOL2}"
chk_not_contains "worker 不再聚合所有归档 Provides" "_off_prov_by_pkg" "${TOOL2}"
# 2026-11-19 CodeRabbit: 修复后不能仅因"包已装"丢弃计划中的升级(可能仍需满足触发包 Breaks)
chk_contains "worker 修复后按版本决定是否保留升级" "保留本次升级" "${TOOL2}"
chk_contains "worker 修复后已装>=计划才移除" ">= 计划" "${TOOL2}"
# 2026-11-19 CodeRabbit: 依赖解析未收敛(振荡/轮次耗尽)不得带着残缺计划进入复制/安装
chk_contains "worker 依赖振荡必须失败" "依赖解析出现振荡" "${TOOL2}"
chk_contains "worker 依赖轮次耗尽必须失败" "依赖解析在 10 轮内未收敛" "${TOOL2}"
chk_contains "worker Breaks 轮次耗尽必须失败" "Breaks 复核在 10 轮内未收敛" "${TOOL2}"
# 2026-11-19 CodeRabbit: 依赖/时间提供者/Breaks 三步互相影响 → 外层 fixpoint 反复校验;
# 被裁剪移除的包禁止由依赖解析回加(否则"加回→再裁剪"振荡)
chk_contains "worker 计划裁剪外层 fixpoint" "_prune_plan_once" "${TOOL2}"
chk_contains "worker 裁剪移除包禁止回加" "_plan_blocked" "${TOOL2}"
chk_contains "worker 计划 fixpoint 不收敛必须失败" "计划裁剪在 10 轮内未收敛" "${TOOL2}"
# 2026-11-19 CodeRabbit: 远端修复(apt-get install -f)可能移除已装依赖/改版本 →
# 修复后必须重新探测状态并重跑 Depends/Breaks, 探测失败直接停止(不得用旧结论进入 staging)
chk_contains "worker 探测可重复调用" "_probe_remote" "${TOOL2}"
chk_contains "worker 状态解析可重复调用" "_parse_probe" "${TOOL2}"
chk_contains "worker 修复后重新探测" "修复后重新探测包状态并复核计划" "${TOOL2}"
chk_contains "worker 修复后重跑计划 fixpoint" "_plan_fixpoint" "${TOOL2}"
# 2026-11-19 CodeRabbit: "修复成功"不等于跳过的包已装上 —— repair-only 成功路径
# 也必须执行 DEP_SKIPPED/BREAKS_SKIPPED 检查(不能在这里静默 exit 0)
chk_contains "worker 修复成功路径仍报告跳过" "修复成功 ≠ 跳过的包已装上" "${TOOL2}"
# 2026-11-19 CodeRabbit: 同一 initramfs 备份/恢复缺陷(install payload 内联版)一并加固
chk_contains "worker 恢复失败保留备份" "备份保留在" "${TOOL2}"
chk_contains "worker 备份失败不做无备份修改" "不做无备份的修改" "${TOOL2}"
# 2026-11-19 CodeRabbit: initramfs 配置恢复失败必须让载荷/调用方非零(dpkg 失败码优先保留)
chk_contains "worker 恢复失败返回非零" "_restore_rc" "${TOOL2}"
chk_contains "worker 调用方区分恢复失败" "dpkg -i 已完成, 但恢复" "${TOOL2}"
# 2026-11-19 CodeRabbit: 非 fresh 节点(joined worker)的 repair/收尾 apt -f 不得移除运行时包
chk_contains "worker repair 非 fresh 禁止 apt 移除" "--no-remove" "${TOOL2}"
chk_contains "worker repair 注入移除许可" 'ALLOW_REMOVE=${ALLOW_REMOVE}' "${TOOL2}"
chk_contains "worker repair 跳过运行时破损清理" "跳过移除运行时包" "${TOOL2}"
# 2026-11-19 CodeRabbit: 移除许可必须是 fresh 声明 + kubelet 安全哨兵, 不能只看声明
chk_contains "worker 移除许可需 kubelet 安全哨兵" "CUBESTACK_KUBELET_SAFE=1" "${TOOL2}"
chk_not_contains "worker repair 不再注入 fresh 声明" 'echo "FRESH_NODE=${FRESH_NODE}"' "${TOOL2}"
# 修复段与收尾段都必须只看移除许可(不是 fresh 声明), 默认拒绝移除
chk_contains "worker repair 按移除许可决定 no-remove" '[ "${ALLOW_REMOVE:-0}" = "1" ] || _apt_keep="--no-remove"' "${TOOL2}"
chk_contains "worker 收尾按移除许可决定 no-remove" '[ "${ALLOW_REMOVE}" = "1" ] || _apt_keep="--no-remove"' "${TOOL2}"
chk_contains "worker 移除许可默认关闭" "ALLOW_REMOVE=0" "${TOOL2}"
chk_not_contains "worker 不再以 fresh 声明放开移除" '"${FRESH_NODE:-0}" = "1"' "${TOOL2}"
# 2026-11-19 CodeRabbit: 收尾 apt -f 的退出码必须回传 —— tail 管道与 || true 不得吞掉失败
chk_contains "worker 收尾捕获远端退出码" "_settle_rc" "${TOOL2}"
chk_contains "worker 收尾远端保留 apt 退出码" 'exit \$_rc' "${TOOL2}"
chk_contains "worker 收尾仍清理暂存目录" "sudo rm -rf /tmp/packages; exit" "${TOOL2}"
chk_contains "worker 收尾失败必须中止" "apt -f 收尾修复失败" "${TOOL2}"
chk_not_contains "worker 收尾不再无条件忽略失败" 'tail -5; sudo rm -rf /tmp/packages" 2>/dev/null || true' "${TOOL2}"
chk_contains "worker repair 破损状态容错尾随空格" '[[:space:]]*\|' "${TOOL2}"
# 2026-11-19 CodeRabbit: kubelet 状态未知(空输出/systemctl 无响应)不得当作"未运行"而 purge
chk_contains "worker purge 要求已知安全状态" "_kstate" "${TOOL2}"
chk_contains "worker 状态未知跳过并报告" "无法确定 kubelet 状态" "${TOOL2}"
# 2026-11-19 CodeRabbit: 初始 cohort 创建早于 fixpoint 助手定义/状态初始化, 不得依赖它们
chk_contains "worker 初始 cohort 独立于 fixpoint 状态" "初始 cohort 创建发生在任何裁剪/fixpoint 之前" "${TOOL2}"
chk "worker 初始 cohort 不调用后定义的助手" "0" "$(grep -c '_plan_blocked "${p}"' "${TOOL2}" 2>/dev/null || true)"
chk_contains "worker 复制双失败即退出" "离线包复制失败(rsync/scp 均失败)" "${TOOL2}"
chk_contains "worker 复制后核对大小" "离线包复制不完整" "${TOOL2}"
chk_contains "worker 安装前校验暂存集" "未成功复制到" "${TOOL2}"
# 2026-11-19 CodeRabbit: Depends 必须校验版本约束, 不能只看包名
chk_contains "worker 依赖版本比较" "_deb_ver_ok" "${TOOL2}"
chk_contains "worker 版本不满足时选择升级" "_dep_ver_by_pkg" "${TOOL2}"
chk_contains "worker 不做隐性降级" "只接受升级" "${TOOL2}"
chk_contains "worker 依赖跳过必须非零退出" "DEP_SKIPPED[*]" "${TOOL2}"
# 2026-11-19 CodeRabbit: 依赖裁剪后必须复核 Breaks(避免 cohort 升级被裁掉后冲突复现)
chk_contains "worker Breaks 最终复核" "Breaks 与最终计划/已装版本冲突" "${TOOL2}"
chk_contains "worker Breaks 复核移除触发包" "从本次安装计划移除" "${TOOL2}"
chk_contains "worker Breaks 复核循环" "_br_round" "${TOOL2}"
chk_contains "worker Breaks 冲突必须非零退出" "BREAKS_SKIPPED[*]" "${TOOL2}"

echo "== ⑦ ONLY_HOSTS 过滤(扩容只动新节点) =="
cat > "${TMP}/cluster-two.conf" <<'EOF'
NODES=("worker,w1,10.0.0.1,root,-" "worker,w2,10.0.0.2,root,-")
SSH_USER="root"
KUBESPRAY_PROFILE="none"
CLUSTER_NAME="no-such-cluster"
EOF
run_two() {  # run_two <only_hosts>
    local only="$1"
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster-two.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline"
        export CLUSTER_NAME="no-such-cluster"
        export ONLY_HOSTS="${only}"
        export FAKE_SSH_LOG="${TMP}/ssh-two.log"
        export FAKE_SCP_LOG="${TMP}/scp-two.log"
        : > "${FAKE_SSH_LOG}"; : > "${FAKE_SCP_LOG}"
        bash "${TOOL}"
    ) > "${TMP}/out-two" 2>&1
    echo $?
}
_rc="$(run_two "w1")"
chk "ONLY_HOSTS=w1: 退出码" "0" "${_rc}"
chk "ONLY_HOSTS=w1: 未触碰 10.0.0.2" "0" "$(grep -c '10.0.0.2' "${TMP}/ssh-two.log" 2>/dev/null || true)"
chk "ONLY_HOSTS=w1: 未向 10.0.0.2 分发 deb" "0" "$(grep -c '10.0.0.2' "${TMP}/scp-two.log" 2>/dev/null || true)"
if grep -q '10.0.0.1' "${TMP}/ssh-two.log" 2>/dev/null; then
    echo "  ok  ONLY_HOSTS=w1: 处理 10.0.0.1"
else
    echo "  FAIL ONLY_HOSTS=w1: 未处理 10.0.0.1"; fail=1
fi
_rc="$(run_two "")"
chk "ONLY_HOSTS 未设置: 退出码" "0" "${_rc}"
if grep -q '10.0.0.1' "${TMP}/ssh-two.log" 2>/dev/null \
   && grep -q '10.0.0.2' "${TMP}/ssh-two.log" 2>/dev/null; then
    echo "  ok  ONLY_HOSTS 未设置: 全量节点仍被处理"
else
    echo "  FAIL ONLY_HOSTS 未设置: 全量节点未被处理"; fail=1
fi
unset _rc

echo "== ⑧ ONLY_HOSTS: inventory 过期地址不得覆盖 NODES 现地址 =="
# 2026-11-19 CodeRabbit: 扩容时 hosts.yml 还是扩容前的(同一 hostname 可能挂着旧 IP),
# 而 hosts.yml 要到流程稍后才重建 —— 必须只对 NODES 指定的地址分发/对账。
_INV_TEST_DIR="${REPO_ROOT}/deployments/kubespray/inventory/cubestack-staleinv-$$"
mkdir -p "${_INV_TEST_DIR}"
trap 'rm -rf "${TMP}" "${_INV_TEST_DIR}"' EXIT
cat > "${_INV_TEST_DIR}/hosts.yml" <<'EOF'
all:
  children:
    kube_node:
      hosts:
        w1:
          ansible_host: 10.0.0.9
        w2:
          ansible_host: 10.0.0.2
        old-w1:
          ansible_host: 10.0.0.19
        new-w1:
          ansible_host: 10.0.0.1
EOF
cat > "${TMP}/cluster-stale.conf" <<EOF
NODES=("worker,w1,10.0.0.1,root,-" "worker,w2,10.0.0.2,root,-")
SSH_USER="root"
KUBESPRAY_PROFILE="none"
CLUSTER_NAME="$(basename "${_INV_TEST_DIR}")"
EOF
run_stale() {  # run_stale <only_hosts>
    local only="$1"
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster-stale.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline"
        export ONLY_HOSTS="${only}"
        export FAKE_SSH_LOG="${TMP}/ssh-stale.log"
        export FAKE_SCP_LOG="${TMP}/scp-stale.log"
        : > "${FAKE_SSH_LOG}"; : > "${FAKE_SCP_LOG}"
        bash "${TOOL}" --dry-run
    ) > "${TMP}/out-stale" 2>&1
    echo $?
}
_rc="$(run_stale "w1")"
chk "inventory 旧地址: 退出码" "0" "${_rc}"
chk "inventory 旧地址: 未触碰 10.0.0.9" "0" "$(grep -c '10.0.0.9' "${TMP}/ssh-stale.log" 2>/dev/null || true)"
if grep -q '10.0.0.1' "${TMP}/ssh-stale.log" 2>/dev/null; then
    echo "  ok  inventory 旧地址: 使用 NODES 现地址 10.0.0.1"
else
    echo "  FAIL inventory 旧地址: 未处理 10.0.0.1"; fail=1
fi
chk_contains "inventory 旧地址: 明确告警" "跳过 inventory 过期地址" "${TMP}/out-stale"
# 2026-11-19 CodeRabbit: 短 selector 同时匹配 old-w1/new-w1 时, 只认 NODES 指认的地址
chk "短 selector: 未触碰 old-w1 旧地址 10.0.0.19" "0" "$(grep -c '10.0.0.19' "${TMP}/ssh-stale.log" 2>/dev/null || true)"
chk_contains "短 selector: 非 NODES 匹配行被跳过" "跳过 inventory 行: old-w1" "${TMP}/out-stale"
unset _rc
rm -rf "${_INV_TEST_DIR}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-reconcile-node-packages: 全部通过"
else
    echo "❌ test-reconcile-node-packages: 存在失败项"
fi
exit "${fail}"
