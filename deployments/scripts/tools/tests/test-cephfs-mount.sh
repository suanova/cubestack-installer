#!/bin/bash
# ============================================================
# test-cephfs-mount.sh — cephfs_mount 模块离线桩式回归(不连集群)
# 覆盖:
#   ① 模块/清单/配置默认值存在且元数据合规
#   ①b 调度: Ceph 全关时计划里**不得**出现 cephfs_mount(2026-10-22 用户实机)
#   ② 门禁: CEPHFS_MOUNT_ENABLED=false → 跳过(不 apply)
#   ②b Ceph 全关(CEPH_ENABLED/CEPH_CSI_ENABLED=false): 默认不启用、不预检、不发 SSH
#   ②c 门禁兜底: 即使 CEPHFS_MOUNT_ENABLED 被显式误开, Ceph 未部署也不得去预检
#   ③ internal 模式渲染: mon 归一化 / Secret / DaemonSet 关键字段(privileged + 双向传播 + 目标路径)
#   ④ 全节点真实验证命令覆盖(NODES 中每台都发 findmnt/探针)
#   ⑤ 幂等重跑(第二次仍 exit 0)
#   ⑥ uninstall 分支: 删 DS / Secret / cephx 用户, 且不 apply
#   ⑧ external 自动派生 external-ceph.env(Rook 导出: mon/FS/CSI node 凭据)
#   ⑨ external 只读挂载(专用 external-cephfs.env + CEPHFS_MOUNT_READ_ONLY)
#   ⑩ external 凭据成对派生: 只显式给 user 时不借用其他身份的 key(预检失败); 显式成对优先
#   ⑪ 预清理按 mds_namespace 判 FS: 旧 FS/缺少 mds_namespace → lazy umount; 匹配 → 保留复用
# 隔离: CLUSTER_CONF=临时配置 + PATH 前置假 ssh(纯离线; 无集群/无网络)
# 用法: bash deployments/scripts/tools/tests/test-cephfs-mount.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MODULE="${REPO_ROOT}/deployments/scripts/modules/03_addon/07_cephfs_mount.sh"
MANIFEST="${REPO_ROOT}/deployments/cubestack-addon/rook/cephfs/04-host-mount-daemonset.yaml"
DEFAULTS="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  FAIL $1: [$3] 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }

# 临时配置(3 节点)。显式 KUBESPRAY_PROFILE=none, 避免 load_config 走版本档案。
cat > "${TMP}/cluster.conf" <<'EOF'
NODES=(
  "master,m1,10.0.0.1,root,-"
  "master,m2,10.0.0.2,root,-"
  "worker,w1,10.0.0.11,root,-"
)
SSH_USER="root"
SSH_KEY_NAME="cubestack_k8s"
KUBESPRAY_PROFILE="none"
CEPH_ENABLED="true"
CEPH_CSI_ENABLED="true"
CEPH_MODE="internal"
CEPHFS_ENABLED="true"
EOF

# Ceph 全关(用户报告的场景): 不设置任何 CEPHFS_* 变量, 默认值必须让它保持关闭。
cat > "${TMP}/cluster.conf.ceph-off" <<'EOF'
NODES=(
  "master,m1,10.0.0.1,root,-"
  "master,m2,10.0.0.2,root,-"
  "worker,w1,10.0.0.11,root,-"
)
SSH_USER="root"
SSH_KEY_NAME="cubestack_k8s"
KUBESPRAY_PROFILE="none"
CEPH_ENABLED="false"
CEPH_CSI_ENABLED="false"
EOF

# 显式误开 CEPHFS_MOUNT_ENABLED、但 Ceph 未部署: 模块自身也必须兜底跳过。
cat > "${TMP}/cluster.conf.ceph-off-forced" <<'EOF'
NODES=(
  "master,m1,10.0.0.1,root,-"
)
SSH_USER="root"
SSH_KEY_NAME="cubestack_k8s"
KUBESPRAY_PROFILE="none"
CEPH_ENABLED="false"
CEPH_CSI_ENABLED="false"
CEPHFS_ENABLED="true"
CEPHFS_MOUNT_ENABLED="true"
EOF

# external Ceph 模式: 覆盖安装时不得 umount 宿主机 CephFS(外部资源), 也不得删 cephx 用户。
cat > "${TMP}/cluster.conf.external" <<'EOF'
NODES=(
  "master,m1,10.0.0.1,root,-"
  "master,m2,10.0.0.2,root,-"
  "worker,w1,10.0.0.11,root,-"
)
SSH_USER="root"
SSH_KEY_NAME="cubestack_k8s"
KUBESPRAY_PROFILE="none"
CEPH_ENABLED="false"
CEPH_CSI_ENABLED="true"
CEPH_MODE="external"
CEPHFS_ENABLED="true"
CEPHFS_MOUNT_ENABLED="true"
EOF

# 2026-10-27: 只给 external-ceph.env(Rook 官方导出), 不手填 CEPH_MONITORS/CEPHFS_FS/凭据 ——
# 模块必须自动派生, 否则 external 宿主机挂载永远要用户重复配置(实机容器 d 的现状)。
cat > "${TMP}/external-ceph.env" <<'EOF'
export ROOK_EXTERNAL_FSID=1fa1539b-c40f-4e4a-a68f-64118766121f
export ROOK_EXTERNAL_USERNAME=client.healthchecker
export ROOK_EXTERNAL_USER_SECRET=AQBHealthKey==  # secret-scan: allow(fake test fixture)
export ROOK_EXTERNAL_CEPH_MON_DATA=a=10.0.0.5:6789,b=10.0.0.6:6789
export CEPHFS_FS_NAME=cubestack-ext-fs
export CSI_CEPHFS_NODE_SECRET=AQBCsiNodeKey==  # secret-scan: allow(fake test fixture)
export CSI_CEPHFS_NODE_SECRET_NAME=csi-cephfs-node
export CEPHX_KEY_GENERATION=1
EOF
cat > "${TMP}/cluster.conf.external-env" <<'EOF'
NODES=(
  "master,m1,10.0.0.1,root,-"
  "master,m2,10.0.0.2,root,-"
  "worker,w1,10.0.0.11,root,-"
)
SSH_USER="root"
SSH_KEY_NAME="cubestack_k8s"
KUBESPRAY_PROFILE="none"
CEPH_ENABLED="false"
CEPH_CSI_ENABLED="true"
CEPH_MODE="external"
CEPHFS_ENABLED="true"
CEPHFS_MOUNT_ENABLED="true"
CEPHFS_MOUNT_PATH="/mnt/cephfs/models"
EOF

# 2026-10-27: 只读 external 提供方(用户手册 client.linux-host-ro):
# 凭据/网段/FS 放专用 external-cephfs.env(gitignored), 不在 cluster.conf 重复。
cat > "${TMP}/external-cephfs.env" <<'EOF'
CEPH_MONITORS="10.0.0.5:6789"
CEPHFS_FS="cephfs-ro"
CEPHFS_NODE_USER="linux-host-ro"
CEPHFS_NODE_KEYRING="AQBReadOnlyKey=="  # secret-scan: allow(fake test fixture)
CEPHFS_MOUNT_READ_ONLY="true"
CEPHFS_MOUNT_PATH="/mnt/cephfs/ro-env"
EOF
cat > "${TMP}/cluster.conf.external-ro" <<'EOF'
NODES=(
  "master,m1,10.0.0.1,root,-"
  "master,m2,10.0.0.2,root,-"
  "worker,w1,10.0.0.11,root,-"
)
SSH_USER="root"
SSH_KEY_NAME="cubestack_k8s"
KUBESPRAY_PROFILE="none"
CEPH_ENABLED="false"
CEPH_CSI_ENABLED="true"
CEPH_MODE="external"
CEPHFS_ENABLED="true"
CEPHFS_MOUNT_ENABLED="true"
CEPHFS_MOUNT_PATH="/mnt/cephfs/ro-conf"
EOF

# 2026-10-28: 凭据必须成对派生 —— 只显式给 node 用户名(与 CSI node secret 不同身份)时,
# 不得从 external-ceph.env 借用 CSI node key; 应在"external 模式缺凭据"预检失败。
cat > "${TMP}/cluster.conf.external-user-only" <<'EOF'
NODES=(
  "master,m1,10.0.0.1,root,-"
  "master,m2,10.0.0.2,root,-"
  "worker,w1,10.0.0.11,root,-"
)
SSH_USER="root"
SSH_KEY_NAME="cubestack_k8s"
KUBESPRAY_PROFILE="none"
CEPH_ENABLED="false"
CEPH_CSI_ENABLED="true"
CEPH_MODE="external"
CEPHFS_ENABLED="true"
CEPHFS_MOUNT_ENABLED="true"
CEPHFS_NODE_USER="custom-node-user"
EOF
# 显式成对凭据(优先): 不被 external-ceph.env 的 CSI node 凭据覆盖。
cat > "${TMP}/cluster.conf.external-explicit" <<'EOF'
NODES=(
  "master,m1,10.0.0.1,root,-"
  "master,m2,10.0.0.2,root,-"
  "worker,w1,10.0.0.11,root,-"
)
SSH_USER="root"
SSH_KEY_NAME="cubestack_k8s"
KUBESPRAY_PROFILE="none"
CEPH_ENABLED="false"
CEPH_CSI_ENABLED="true"
CEPH_MODE="external"
CEPHFS_ENABLED="true"
CEPHFS_MOUNT_ENABLED="true"
CEPHFS_NODE_USER="explicit-node"
CEPHFS_NODE_KEYRING="AQBExplicitPair=="  # secret-scan: allow(fake test fixture)
EOF

# 假 ssh: 跳过选项, 记录 host/cmd, 按命令内容回放夹具
mkdir -p "${TMP}/bin" "${TMP}/mnt-state"
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
cmd="${cmd//$'\n'/ }"
printf '%s\t%s\n' "${host}" "${cmd}" >> "${FAKE_SSH_LOG}"
case "${cmd}" in
    *"apply -f -"*)
        { echo "=== APPLY ==="; cat; } >> "${FAKE_APPLY_LOG}"
        echo "configured" ;;
    *"get cephcluster"*) echo "Ready" ;;
    *"get cephfilesystem"*) echo "Ready" ;;
    *"get cm rook-ceph-mon-endpoints"*) echo "a=10.0.0.5:6789,b=10.0.0.6:6789,c=10.0.0.7:6789" ;;
    *"get ds rook-ceph.cephfs.csi.ceph.com-nodeplugin"*) echo "quay.io/cephcsi/cephcsi:v3.17.0" ;;
    *"ceph auth get-or-create"*) echo "[client.cubestack-cephfs-models]" ;;
    *"ceph auth print-key"*) echo "AQBTestKey1234567890abcdef==" ;;
    *"rollout status"*) echo 'daemon set "cephfs-models-mount" successfully rolled out' ;;
    *"get node "*) if [ "${FAKE_NOTREADY:-0}" = "1" ]; then echo "node NotReady <none> 1m v1.35.8"; else echo "node Ready <none> 1m v1.35.8"; fi ;;
    *"CEPH_UNMOUNT_OK"*) echo "CEPH_UNMOUNT_OK" ;;
    *"echo CEPH_MOUNT_OK"*) echo "CEPH_MOUNT_OK" ;;
    *"-o FSTYPE"*)
        if [ "${FAKE_MNT_STUB:-0}" = "1" ]; then
            h="${host#*@}"
            [ -f "${FAKE_MNT_STATE_DIR}/${h}.mounted" ] && echo ceph || echo ""
        else
            echo "CEPH_MOUNT_OK"
        fi ;;
    *"-o OPTIONS"*)
        if [ "${FAKE_MNT_STUB:-0}" = "1" ]; then
            h="${host#*@}"
            [ -f "${FAKE_MNT_STATE_DIR}/${h}.mounted" ] && cat "${FAKE_MNT_STATE_DIR}/${h}.mounted" || true
        else
            echo "CEPH_MOUNT_OK"
        fi ;;
    *"umount"*)
        if [ "${FAKE_MNT_STUB:-0}" = "1" ]; then
            h="${host#*@}"; rm -f "${FAKE_MNT_STATE_DIR}/${h}.mounted"; echo "unmounted"
        fi ;;
    *"findmnt"*) echo "CEPH_MOUNT_OK" ;;
    *"delete ds "*) echo 'daemonset.apps "cephfs-models-mount" deleted' ;;
    *"delete secret "*) echo 'secret "cephfs-models-client" deleted' ;;
    *"ceph auth del"*) echo "deleted" ;;
    *) : ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin/ssh"

run_module() {  # run_module <mode> [conf] → 退出码; 输出在 $TMP/run-<mode>.out
    local mode="$1" conf="${2:-${TMP}/cluster.conf}"
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${conf}"
        export FAKE_SSH_LOG="${TMP}/ssh-${mode}.log"
        export FAKE_APPLY_LOG="${TMP}/apply-${mode}.log"
        : > "${FAKE_SSH_LOG}"; : > "${FAKE_APPLY_LOG}"
        case "${mode}" in
            uninstall|uninstall-external) CUBESTACK_MODULE_ACTION=uninstall bash "${MODULE}" ;;
            disabled)  CEPHFS_MOUNT_ENABLED=false bash "${MODULE}" ;;
            notready)  FAKE_NOTREADY=1 bash "${MODULE}" ;;
            *)         bash "${MODULE}" ;;
        esac
    ) > "${TMP}/run-${mode}.out" 2>&1
    echo $?
}

echo "== ① 模块/清单/默认值存在性 =="
[ -f "${MODULE}" ]   && echo "  ok  module exists"   || { echo "  FAIL module missing: ${MODULE}"; fail=1; }
[ -f "${MANIFEST}" ] && echo "  ok  manifest exists" || { echo "  FAIL manifest missing: ${MANIFEST}"; fail=1; }
[ -f "${MODULE}" ] && chk_contains "元数据 MODULE" "MODULE: cephfs_mount" "${MODULE}"
[ -f "${MODULE}" ] && chk_contains "元数据 TOGGLE" "TOGGLE: CEPHFS_MOUNT_ENABLED" "${MODULE}"
# 2026-10-27: external 只做宿主机挂载时不应被 REQUIRES 强拉整个 ceph_csi 外部导入;
# 全量部署仍按文件序号(03 ceph_csi → 07 cephfs_mount)保证 internal 顺序。
[ -f "${MODULE}" ] && chk_not_contains "不 REQUIRES ceph_csi(允许 external 单独挂载)" "REQUIRES: ceph_csi" "${MODULE}"
[ -f "${MODULE}" ] && chk_contains "REQUIRES: k8s_deploy(集群必须先存在)" "REQUIRES: k8s_deploy" "${MODULE}"
[ -f "${MODULE}" ] && chk_contains "可卸载声明" "UNINSTALL: 1" "${MODULE}"
CEPH_MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh"
CEPH_CLEANUP="${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-cleanup.sh"
chk_contains "02_ceph external CR 保护" "external CephCluster" "${CEPH_MOD}"
chk_contains "02_ceph spec.external.enable" "spec.external.enable" "${CEPH_MOD}"
chk_contains "ceph-cleanup 拒绝 external" "外部 Ceph 不是本安装器资产" "${CEPH_CLEANUP}"
[ -f "${DEFAULTS}" ] && chk_contains "默认值 CEPHFS_MOUNT_PATH" 'CEPHFS_MOUNT_PATH="${CEPHFS_MOUNT_PATH:-/mnt/cephfs/models}"' "${DEFAULTS}"
# 2026-10-22 用户实机: Ceph 两个总开关都 false, 计划里却仍有 cephfs_mount, 然后去预检
# CephCluster 失败。默认值必须跟随 Ceph CSI, 不能无条件 true。
[ -f "${DEFAULTS}" ] && chk_contains "CEPHFS_ENABLED 默认跟随 CEPH_CSI_ENABLED" 'CEPHFS_ENABLED="${CEPHFS_ENABLED:-${CEPH_CSI_ENABLED:-false}}"' "${DEFAULTS}"
[ -f "${DEFAULTS}" ] && chk_contains "CEPH_RGW_ENABLED 默认跟随 CEPH_CSI_ENABLED" 'CEPH_RGW_ENABLED="${CEPH_RGW_ENABLED:-${CEPH_CSI_ENABLED:-false}}"' "${DEFAULTS}"
[ -f "${DEFAULTS}" ] && chk_contains "CEPHFS_MOUNT_ENABLED 默认跟随 CEPHFS_ENABLED" 'CEPHFS_MOUNT_ENABLED="${CEPHFS_MOUNT_ENABLED:-${CEPHFS_ENABLED}}"' "${DEFAULTS}"
[ -f "${DEFAULTS}" ] && chk_contains "只读挂载开关默认值" 'CEPHFS_MOUNT_READ_ONLY="${CEPHFS_MOUNT_READ_ONLY:-false}"' "${DEFAULTS}"
[ -f "${DEFAULTS}" ] && chk_contains "挂载专用 env 文件开关" 'CEPHFS_MOUNT_ENV_FILE="${CEPHFS_MOUNT_ENV_FILE:-}"' "${DEFAULTS}"
# 回归(实机踩坑 2026-10-19): hostPath 在容器里本身就是 bind mount, mountpoint -q 恒真;
# 若据此判"目标已被其他文件系统挂载"会拒绝工作。必须只按 fstype=ceph 判断。
[ -f "${MANIFEST}" ] && chk_contains "仅按 fstype 判断是否已挂载" 'findmnt -n -o FSTYPE -T "${TARGET}"' "${MANIFEST}"
[ -f "${MANIFEST}" ] && chk_contains "挂载栈取最上层" 'findmnt -n -o FSTYPE -T "${TARGET}" 2>/dev/null | tail -1' "${MANIFEST}"
[ -f "${MANIFEST}" ] && chk_not_contains "不得用 mountpoint 判外部挂载" 'if mountpoint -q "${TARGET}" 2>/dev/null; then' "${MANIFEST}"
[ -f "${MODULE}" ] && chk_contains "验证也取最上层" "findmnt -n -o FSTYPE -T '\${CEPHFS_MOUNT_PATH}' 2>/dev/null | tail -1" "${MODULE}"
[ -f "${MODULE}" ] && chk_contains "逐节点 SSH 有硬超时" "timeout 30 ssh" "${MODULE}"
if [ -f "${MODULE}" ] && grep -qx 'sync' "${MODULE}"; then
    echo "  FAIL 验证不得使用全局 sync(CephFS 上会挂住)"; fail=1
else
    echo "  ok  验证不使用全局 sync"
fi

echo "== ①b 调度: Ceph 全关时计划不得包含 cephfs_mount =="
if ! _plan="$(CLUSTER_CONF="${TMP}/cluster.conf.ceph-off" \
    bash "${REPO_ROOT}/deployments/scripts/deploy-cluster.sh" --list 2>&1)"; then
    echo "  FAIL 无法生成部署计划: ${_plan}"; fail=1
fi
_plan_line="$(printf '%s\n' "${_plan}" | grep -m1 '本次执行模块' || true)"
if printf '%s' "${_plan_line}" | grep -qw 'cephfs_mount'; then
    echo "  FAIL 计划仍包含 cephfs_mount: ${_plan_line}"; fail=1
else
    echo "  ok  计划不含 cephfs_mount"
fi

echo "== ② 门禁: 关闭时不 apply =="
rc="$(run_module disabled)"
chk "disabled 退出码" "0" "${rc}"
chk_not_contains "disabled 无 apply" "=== APPLY ===" "${TMP}/apply-disabled.log"
chk_contains "disabled 输出跳过" "跳过" "${TMP}/run-disabled.out"

echo "== ②b Ceph 全关: 默认不启用、不预检、不发 SSH =="
rc="$(run_module cephoff "${TMP}/cluster.conf.ceph-off")"
chk "ceph-off 退出码" "0" "${rc}"
chk_contains "ceph-off 输出跳过" "跳过" "${TMP}/run-cephoff.out"
chk_not_contains "ceph-off 不做 Ceph 预检" "预检 Ceph 集群" "${TMP}/run-cephoff.out"
chk "ceph-off 未发起 SSH" "0" "$(wc -l < "${TMP}/ssh-cephoff.log")"

echo "== ②c 兜底: CEPHFS_MOUNT_ENABLED 误开但 Ceph 未部署 → 仍跳过 =="
rc="$(run_module cephoffforced "${TMP}/cluster.conf.ceph-off-forced")"
chk "ceph-off-forced 退出码" "0" "${rc}"
chk_contains "明确报 Ceph 未启用" "Ceph 未启用" "${TMP}/run-cephoffforced.out"
chk_not_contains "ceph-off-forced 不做 Ceph 预检" "预检 Ceph 集群" "${TMP}/run-cephoffforced.out"
chk "ceph-off-forced 未发起 SSH" "0" "$(wc -l < "${TMP}/ssh-cephoffforced.log")"

echo "== ③ 首次部署渲染 =="
rc="$(run_module install1)"
chk "install 退出码" "0" "${rc}"
APPLY1="${TMP}/apply-install1.log"
chk_contains "Secret key" "AQBTestKey1234567890abcdef==" "${APPLY1}"
chk_contains "Secret 名" "name: cephfs-models-client" "${APPLY1}"
chk_contains "DaemonSet kind" "kind: DaemonSet" "${APPLY1}"
chk_contains "DaemonSet 名" "name: cephfs-models-mount" "${APPLY1}"
chk_contains "privileged" "privileged: true" "${APPLY1}"
chk_contains "mountPropagation" "mountPropagation: Bidirectional" "${APPLY1}"
chk_contains "宿主目标路径" "path: /mnt/cephfs/models" "${APPLY1}"
chk_contains "mon 归一化" "10.0.0.5:6789,10.0.0.6:6789,10.0.0.7:6789" "${APPLY1}"
chk_contains "CephFS 子目录挂载" ':/${SUBDIR}' "${APPLY1}"
chk_contains "镜像自动取 CSI" "quay.io/cephcsi/cephcsi:v3.17.0" "${APPLY1}"
chk_not_contains "不把 key 放明文环境变量" "AQBTestKey1234567890abcdef==" <(grep -v '^  key:' "${APPLY1}" || true)
chk_contains "创建专用 cephx 用户" "get-or-create client.cubestack-cephfs-models" "${TMP}/ssh-install1.log"

echo "== ④ 全节点验证 =="
for ip in 10.0.0.1 10.0.0.2 10.0.0.11; do
    if grep -q "${ip}.*findmnt" "${TMP}/ssh-install1.log"; then
        echo "  ok  节点 ${ip} 已执行挂载校验"
    else
        echo "  FAIL 节点 ${ip} 未执行挂载校验"; fail=1
    fi
done

echo "== ⑤ 幂等重跑 =="
rc="$(run_module install2)"
chk "第二次退出码" "0" "${rc}"
chk_contains "第二次仍 apply DaemonSet" "name: cephfs-models-mount" "${TMP}/apply-install2.log"

echo "== ⑥ uninstall 分支 =="
rc="$(run_module uninstall)"
chk "uninstall 退出码" "0" "${rc}"
chk_not_contains "uninstall 不 apply" "=== APPLY ===" "${TMP}/apply-uninstall.log"
chk_contains "删除 DaemonSet" "delete ds cephfs-models-mount" "${TMP}/ssh-uninstall.log"
chk_contains "删除 Secret" "delete secret cephfs-models-client" "${TMP}/ssh-uninstall.log"
chk_contains "删除 cephx 用户" "ceph auth del client.cubestack-cephfs-models" "${TMP}/ssh-uninstall.log"
# 2026-10-19 实机: Ceph 已删后无超时 kubectl exec 会永久挂起, --fresh 优雅卸载卡死。
chk_contains "cephx 删除仅在 CephCluster Ready 时执行" 'if [ "${_cc_phase}" = "Ready" ]' "${MODULE}"
chk_contains "cephx 删除带 kubectl/ceph 双超时" 'timeout 30 ${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- timeout 20 ceph auth del' "${MODULE}"
chk_contains "Ceph 非 Ready 时幂等跳过" 'CephCluster 非 Ready' "${MODULE}"
chk_contains "逐节点卸载宿主机挂载" "CEPH_UNMOUNT_OK" "${TMP}/ssh-uninstall.log"
chk_contains "执行 umount" "sudo umount -l '/mnt/cephfs/models'" "${TMP}/ssh-uninstall.log"
chk_contains "卸载必须 sudo(ubuntu 用户非 root)" "sudo umount -l" "${MODULE}"
chk_contains "旧挂载预清理" "旧集群残留/FS/只读变更自动 lazy umount" "${MODULE}"
chk_contains "预清理使用 lazy umount" "umount -l" "${MODULE}"
chk_contains "hostPath 超时快速失败" "hostPath(host-target)挂载超时" "${MODULE}"
chk_contains "给出 stop kubelet/containerd + reboot 指引" "systemctl reboot -f" "${MODULE}"
for ip in 10.0.0.1 10.0.0.2 10.0.0.11; do
    if grep -q "${ip}.*umount" "${TMP}/ssh-uninstall.log"; then
        echo "  ok  节点 ${ip} 已执行卸载"
    else
        echo "  FAIL 节点 ${ip} 未执行卸载"; fail=1
    fi
done
chk_contains "残留时明确报错" "部分节点仍有 ceph 挂载残留" "${MODULE}"
if awk '/部分节点仍有 ceph 挂载残留/{f=1} f&&/exit 1/{found=1} END{exit !found}' "${MODULE}"; then
    echo "  ok  残留时非零退出(不静默成功)"
else
    echo "  FAIL 残留时未非零退出"; fail=1
fi

echo "== ⑥b external uninstall: 保留宿主机挂载 =="
rc="$(run_module uninstall-external "${TMP}/cluster.conf.external")"
chk "external uninstall 退出码" "0" "${rc}"
chk_not_contains "external 不执行 umount" "sudo umount" "${TMP}/ssh-uninstall-external.log"
chk_not_contains "external 不删 cephx 用户" "ceph auth del" "${TMP}/ssh-uninstall-external.log"
chk_contains "external 保留挂载提示" "保留宿主机 CephFS 挂载" "${TMP}/run-uninstall-external.out"
chk_contains "external 仍删除 DaemonSet" "delete ds cephfs-models-mount" "${TMP}/ssh-uninstall-external.log"

echo "== ⑧ external 自动派生 external-ceph.env(Rook 官方导出) =="
export CEPH_EXTERNAL_ENV_FILE="${TMP}/external-ceph.env"
export CEPHFS_MOUNT_ENV_FILE="${TMP}/absent-mount.env"   # 隔离: 不读本机 gitignored 默认文件
rc="$(run_module external-env "${TMP}/cluster.conf.external-env")"
unset CEPH_EXTERNAL_ENV_FILE CEPHFS_MOUNT_ENV_FILE
chk "external-env 退出码" "0" "${rc}"
APPLY_ENV="${TMP}/apply-external-env.log"
chk_contains "mon 自动派生" '10.0.0.5:6789,10.0.0.6:6789' "${APPLY_ENV}"
chk_contains "CephFS 名自动派生" 'cubestack-ext-fs' "${APPLY_ENV}"
chk_contains "节点用户自动派生(含 generation 后缀)" 'csi-cephfs-node.1' "${APPLY_ENV}"
chk_contains "节点 key 自动派生" 'AQBCsiNodeKey==' "${APPLY_ENV}"
chk_not_contains "不用 healthchecker 兜底(有 CSI node secret 时)" 'healthchecker' "${APPLY_ENV}"

echo "== ⑨ external 只读挂载(专用 external-cephfs.env + CEPHFS_MOUNT_READ_ONLY) =="
export CEPHFS_MOUNT_ENV_FILE="${TMP}/external-cephfs.env"
unset CEPH_EXTERNAL_ENV_FILE
rc="$(run_module external-ro "${TMP}/cluster.conf.external-ro")"
unset CEPHFS_MOUNT_ENV_FILE
chk "external-ro 退出码" "0" "${rc}"
APPLY_RO="${TMP}/apply-external-ro.log"
chk_contains "只读用户" 'linux-host-ro' "${APPLY_RO}"
chk_contains "只读 key" 'AQBReadOnlyKey==' "${APPLY_RO}"
chk_contains "只读 FS" 'cephfs-ro' "${APPLY_RO}"
chk_contains "只读标志写入 DaemonSet" 'CEPHFS_READ_ONLY' "${APPLY_RO}"
chk_contains "只读值为 true" 'value: "true"' "${APPLY_RO}"
chk_contains "专用 env 覆盖挂载路径" 'path: /mnt/cephfs/ro-env' "${APPLY_RO}"
chk_contains "只读挂载选项" 'MOUNT_OPTS' "${APPLY_RO}"
chk_contains "只读不创建子目录" 'read-only 模式: 不创建子目录' "${APPLY_RO}"
chk_contains "验证区分只读" 'NOT_READONLY' "${MODULE}"
chk_contains "只读用 ls 验证" "timeout 10 ls" "${MODULE}"

echo "== ⑩ external 凭据成对派生: 只显式给 user 时不得借用其他身份的 key =="
export CEPH_EXTERNAL_ENV_FILE="${TMP}/external-ceph.env"
export CEPHFS_MOUNT_ENV_FILE="${TMP}/absent-mount.env"
rc="$(run_module external-user-only "${TMP}/cluster.conf.external-user-only")"
unset CEPH_EXTERNAL_ENV_FILE CEPHFS_MOUNT_ENV_FILE
chk "user-only 退出码非 0" "1" "${rc}"
chk_contains "user-only 在缺凭据预检失败" "缺凭据" "${TMP}/run-external-user-only.out"
chk_not_contains "user-only 不写 Secret/DaemonSet" "=== APPLY ===" "${TMP}/apply-external-user-only.log"

export CEPH_EXTERNAL_ENV_FILE="${TMP}/external-ceph.env"
export CEPHFS_MOUNT_ENV_FILE="${TMP}/absent-mount.env"
rc="$(run_module external-explicit "${TMP}/cluster.conf.external-explicit")"
unset CEPH_EXTERNAL_ENV_FILE CEPHFS_MOUNT_ENV_FILE
chk "显式成对凭据退出码 0" "0" "${rc}"
APPLY_EXPL="${TMP}/apply-external-explicit.log"
chk_contains "显式 node 用户生效" 'explicit-node' "${APPLY_EXPL}"
chk_contains "显式 node key 生效" 'AQBExplicitPair==' "${APPLY_EXPL}"
chk_not_contains "不被 CSI node 身份覆盖" 'csi-cephfs-node.1' "${APPLY_EXPL}"

echo "== ⑪ 预清理按 mds_namespace 判 FS: 旧 FS/缺选项 → umount; 匹配 → 复用 =="
_seed_mount() {   # _seed_mount "<findmnt OPTIONS>" → 所有节点视为已挂载且可读
    rm -f "${TMP}/mnt-state"/* 2>/dev/null || true
    local ip
    for ip in 10.0.0.1 10.0.0.2 10.0.0.11; do
        printf '%s\n' "$1" > "${TMP}/mnt-state/${ip}.mounted"
    done
}
export FAKE_MNT_STUB=1 FAKE_MNT_STATE_DIR="${TMP}/mnt-state"
# 旧 FS 的可读挂载: 必须 lazy umount 让 DS 挂当前 CEPHFS_FS_NAME(cephfs)
_seed_mount "rw,noatime,name=csi-cephfs-node,acl,mds_namespace=old-fs"
rc="$(run_module fs-mismatch "${TMP}/cluster.conf")"
chk "旧 FS 不一致退出码" "0" "${rc}"
chk_contains "点名旧 FS 与期望 FS" "fs='old-fs'(期望 cephfs)" "${TMP}/run-fs-mismatch.out"
chk_contains "旧 FS 执行 lazy umount" "umount -l '/mnt/cephfs/models'" "${TMP}/ssh-fs-mismatch.log"
chk_contains "旧 FS 卸载后继续 apply" "name: cephfs-models-mount" "${TMP}/apply-fs-mismatch.log"
# FS 与只读状态匹配: 保留复用, 不 umount
_seed_mount "rw,noatime,name=csi-cephfs-node,acl,mds_namespace=cephfs"
rc="$(run_module fs-match "${TMP}/cluster.conf")"
chk "FS 匹配退出码" "0" "${rc}"
chk_contains "FS 匹配保留复用" "保留复用" "${TMP}/run-fs-match.out"
chk_not_contains "FS 匹配不 umount" "umount" "${TMP}/ssh-fs-match.log"
# 缺少 mds_namespace(旧 DS/手工挂载): 不得当作匹配
_seed_mount "rw,noatime,name=csi-cephfs-node,acl"
rc="$(run_module fs-absent "${TMP}/cluster.conf")"
chk "缺少 mds_namespace 退出码" "0" "${rc}"
chk_contains "缺少选项按不匹配处理" "无 mds_namespace" "${TMP}/run-fs-absent.out"
chk_contains "缺少选项执行 lazy umount" "umount -l '/mnt/cephfs/models'" "${TMP}/ssh-fs-absent.log"
unset FAKE_MNT_STUB FAKE_MNT_STATE_DIR

echo "== ⑦ 零节点验证必须失败(不得假成功) =="
rc="$(run_module notready)"
chk "notready 退出码非 0" "1" "${rc}"
chk_contains "notready 明确报错" "没有节点完成挂载校验" "${TMP}/run-notready.out"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-cephfs-mount: 全部通过"
else
    echo "❌ test-cephfs-mount: 存在失败项"
fi
exit "${fail}"
