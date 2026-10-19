#!/bin/bash
# ============================================================
# test-cephfs-mount.sh — cephfs_mount 模块离线桩式回归(不连集群)
# 覆盖:
#   ① 模块/清单/配置默认值存在且元数据合规
#   ② 门禁: CEPHFS_MOUNT_ENABLED=false → 跳过(不 apply)
#   ③ internal 模式渲染: mon 归一化 / Secret / DaemonSet 关键字段(privileged + 双向传播 + 目标路径)
#   ④ 全节点真实验证命令覆盖(NODES 中每台都发 findmnt/探针)
#   ⑤ 幂等重跑(第二次仍 exit 0)
#   ⑥ uninstall 分支: 删 DS / Secret / cephx 用户, 且不 apply
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

# 假 ssh: 跳过选项, 记录 host/cmd, 按命令内容回放夹具
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
    *"findmnt"*) echo "CEPH_MOUNT_OK" ;;
    *"delete ds "*) echo 'daemonset.apps "cephfs-models-mount" deleted' ;;
    *"delete secret "*) echo 'secret "cephfs-models-client" deleted' ;;
    *"ceph auth del"*) echo "deleted" ;;
    *) : ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin/ssh"

run_module() {  # run_module <mode> → 退出码; 输出在 $TMP/run-<mode>.out
    local mode="$1"
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf"
        export FAKE_SSH_LOG="${TMP}/ssh-${mode}.log"
        export FAKE_APPLY_LOG="${TMP}/apply-${mode}.log"
        : > "${FAKE_SSH_LOG}"; : > "${FAKE_APPLY_LOG}"
        case "${mode}" in
            uninstall) CUBESTACK_MODULE_ACTION=uninstall bash "${MODULE}" ;;
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
[ -f "${MODULE}" ] && chk_contains "元数据 REQUIRES" "REQUIRES: ceph_csi" "${MODULE}"
[ -f "${MODULE}" ] && chk_contains "可卸载声明" "UNINSTALL: 1" "${MODULE}"
[ -f "${DEFAULTS}" ] && chk_contains "默认值 CEPHFS_MOUNT_PATH" 'CEPHFS_MOUNT_PATH="${CEPHFS_MOUNT_PATH:-/mnt/cephfs/models}"' "${DEFAULTS}"
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

echo "== ② 门禁: 关闭时不 apply =="
rc="$(run_module disabled)"
chk "disabled 退出码" "0" "${rc}"
chk_not_contains "disabled 无 apply" "=== APPLY ===" "${TMP}/apply-disabled.log"
chk_contains "disabled 输出跳过" "跳过" "${TMP}/run-disabled.out"

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
chk_contains "旧挂载预清理" "旧集群残留自动 lazy umount" "${MODULE}"
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
