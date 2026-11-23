#!/bin/bash
# ============================================================
# test-ceph-nbd-guards.sh — Ceph nbd/0-OSD/官方导出卡死的静态回归
# 背景(2026-10-19 实机):
#   · CSI RBD nodeplugin 显式 modprobe nbd → /sys/block/nbd0 常驻;
#   · 新集群 osd-prepare 的 ceph-volume inventory 在 nbd0 上抛
#     "No udev data could be retrieved", 跳过 vdb/vdc/vdd → 0 OSD;
#   · 0 OSD 时 ceph-expose-external 的官方 create-external-cluster-resources.py
#     在 inactive PG / 未 Ready 的 RGW realm 上无限等待(实机 pending 20min+)。
# 覆盖(源码围栏):
#   ① nbd 清理: install nbd /bin/false、卸载后校验、STILL-PRESENT/IN-USE 硬失败
#   ② OSD=0: Ceph Ready 但 OSD=0 必须 exit 1, 不再 warn 后继续
#   ③ 官方导出: OSD=0 预检跳过 + python3 timeout + RGW 未就绪省略参数
#   ④ 强制清理: 所有 --force delete 必须带 --wait=false(2026-10-20 实机 PV finalizer 卡死)
# 用法: bash deployments/scripts/tools/tests/test-ceph-nbd-guards.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CEPH="${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh"
EXPOSE="${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-expose-external.sh"
CLEANUP="${MODULE_UNDER_TEST:-${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-cleanup.sh}"
RBDC="${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-rbd-cleanup.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_not_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  FAIL $1: [$3] 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }

echo "== ① nbd 清理/校验 =="
chk_contains "install nbd /bin/false(挡显式 modprobe)" "install nbd /bin/false" "${CEPH}"
chk_contains "nbds_max=0 预载(CSI 容器内 modprobe 不读宿主机规则)" "nbds_max=0" "${CEPH}"
chk_contains "OSD 就绪后恢复 nbd 默认设备" "_ceph_nbd_restore_one" "${CEPH}"
chk_contains "卸载后校验 lsmod/设备" "STILL-PRESENT" "${CEPH}"
chk_contains "调用方硬失败标记" "_CEPH_NBD_FAIL" "${CEPH}"
chk_contains "拒绝创建 CephCluster 的报错" "拒绝继续创建 CephCluster" "${CEPH}"

echo "== ② 0 OSD / OSD 不足硬失败 =="
chk_contains "就绪判据必须 HEALTH_OK 且 OSD >= 池副本数" '[ "${_hl}" = "HEALTH_OK" ] && [ "${_osd_n:-0}" -ge "${_pool_n}" ]' "${CEPH}"
chk_contains "TOO_FEW_OSDS 识别" "TOO_FEW_OSDS" "${CEPH}"
chk_contains "OSD 不足提示 pool size" "osd_pool_default_size" "${CEPH}"
chk_contains "Ready 但 OSD=0 判定" "Ceph 集群 Ready 但 OSD=0" "${CEPH}"
chk_contains "给出 nbd 根因提示" "ceph-volume inventory" "${CEPH}"
chk_contains "OSD=0 分支 exit 1" 'exit 1' "${CEPH}"

echo "== ②b 存储节点预检 / DiskPressure / toolbox 等待 =="
chk_contains "存储节点预检函数" "_ceph_storage_node_preflight" "${CEPH}"
chk_contains "DiskPressure taint 检查" "node.kubernetes.io/disk-pressure" "${CEPH}"
chk_contains "陈旧 local-path 清理开关" "CEPH_CLEAN_STALE_LOCAL_PATH" "${CEPH}"
chk_contains "根盘空间阈值" "CEPH_NODE_MIN_FREE_GB" "${CEPH}"
chk_contains "toolbox 等待可配" "CEPH_TOOLBOX_WAIT_SECONDS" "${CEPH}"
chk_contains "无盘存储节点 fail-fast" "可用 OSD 节点" "${CEPH}"
chk_contains "7a-② 跳过无盘节点" "无可用裸盘, 跳过 7a-②" "${CEPH}"
chk_contains "池副本参数必须是正整数" "CEPH_POOL_REPLICAS 必须是正整数" "${CEPH}"
chk_contains "min_size 不得大于 replicas" "不能大于 CEPH_POOL_REPLICAS" "${CEPH}"
chk_contains "CEPH_NODES 主机不在 NODES → 预检失败" "在 NODES 中找不到该主机" "${CEPH}"
chk_contains "df 读取失败 → 预检失败" "无法读取根盘可用空间" "${CEPH}"

echo "== ③ 官方导出预检/超时/RGW =="
chk_contains "OSD=0 跳过官方导出" "Ceph OSD=0, 跳过官方" "${EXPOSE}"
chk_contains "python3 带 timeout" "timeout 120 python3" "${EXPOSE}"
chk_contains "RGW 未就绪省略参数" "CephObjectStore/RGW 未就绪" "${EXPOSE}"
chk_contains "RGW 端点可达性探测" "timeout 5 curl" "${EXPOSE}"

echo "== ④ Ceph 强制清理不得无限等待 finalizer =="
# 2026-10-20 实机: wait_ceph_volumes_gone 的 `kubectl delete pv --force --grace-period=0`
# 未带 --wait=false → PVC/PV 的 pvc-protection / external-provisioner finalizer 不清除时
# delete 无限阻塞(卡 7.5min+, 直到模块 1800s timeout)。强制清理只应发起删除、不陪等。
chk_contains "PVC 强删带 --wait=false" 'delete pvc ${_p#*/} --ignore-not-found --force --grace-period=0 --wait=false' "${CLEANUP}"
chk_contains "PV 强删带 --wait=false" 'delete pv ${_pv} --ignore-not-found --force --grace-period=0 --wait=false' "${CLEANUP}"
chk_contains "PV finalizer patch 有 timeout" 'timeout 30 ${K} patch pv' "${CLEANUP}"
_bad_force="$(grep -nE -- 'delete .*--force' "${CLEANUP}" | grep -v -- '--wait=false' || true)"
if [ -z "${_bad_force}" ]; then
    echo "  ok  所有 --force delete 都带 --wait=false"
else
    echo "  FAIL 存在 --force delete 未带 --wait=false:"
    printf '%s\n' "${_bad_force}" | sed 's/^/    /'
    fail=1
fi
# 2026-10-20 CodeRabbit: --wait=false 只代表"不陪等 finalizer", 不代表 CSI unmap 完成。
# 强制删除后必须有界复查; 仍残留则返回非零, 默认拒绝继续删 nodeplugin/CephCluster。
chk_contains "强制清理后有界复查开关" 'CEPH_CLEANUP_FORCE_RECHECK_SECONDS' "${CLEANUP}"
chk_contains "强制清理残留返回非零" '未确认 CSI unmap 完成' "${CLEANUP}"
chk_contains "复查含 ceph CSI VolumeAttachment" '_list_ceph_volumeattachments' "${CLEANUP}"
chk_contains "VolumeAttachment 消失才算 unmap" 'VolumeAttachment 已消失' "${CLEANUP}"
chk_contains "PVC 清单包含 Lost(强删 PV 后)" '"Bound", "Lost"' "${CLEANUP}"
chk "三个列表查询失败均返回非零(异常/非 List 两处)" "6" "$(grep -cF 'sys.exit(2)' "${CLEANUP}" || true)"
chk "两处复查都要求查询成功" "2" "$(grep -cF '_left_pv="$(_list_ceph_pvs' "${CLEANUP}" || true)"
chk "CephCluster 查询均用 ignore-not-found" "5" "$(grep -cF -- '--ignore-not-found -o name' "${CLEANUP}" || true)"
chk_not_contains "CephCluster 消失判断不吞查询错误" '_still="$( (SSH' "${CLEANUP}"
chk_contains "无集群预检查不吞查询错误" '查询 CephCluster 失败(无法确认是否存在)' "${CLEANUP}"
chk_contains "恢复命令带 -- 前缀" 'CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP=1 $0 --${ACTION' "${CLEANUP}"
chk_not_contains "恢复命令不再缺 --" 'CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP=1 $0 ${ACTION' "${CLEANUP}"
chk_contains "查询失败标记中止擦盘" '_CEPH_ABORT_WIPE' "${CLEANUP}"
chk_contains "CephCluster 查询失败标记" '_cluster_query_failed' "${CLEANUP}"
chk_contains "stop_consumers 检查卷清理结果" 'if ! wait_ceph_volumes_gone 120 0' "${CLEANUP}"
chk_contains "默认拒绝删 rbd nodeplugin" '拒绝删除 rbd csi nodeplugin' "${CLEANUP}"
chk_contains "显式不安全放行开关" 'CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP' "${CLEANUP}"
chk_contains "delete_cluster 二次卷检查" 'if ! wait_ceph_volumes_gone 120 1' "${CLEANUP}"
chk_contains "cleanup_all 不安全时中止清盘" '_CEPH_UNSAFE_UNMAP' "${CLEANUP}"
chk_contains "CephCluster 强删后复查开关" 'CEPH_CLEANUP_CLUSTER_FORCE_GONE_SECONDS' "${CLEANUP}"
chk_contains "CephCluster 未消失返回失败" 'CephCluster 强制删除后仍存在' "${CLEANUP}"
chk_contains "cleanup_all 传播删除失败" '_dc_rc' "${CLEANUP}"
# 2026-10-26 CodeRabbit(Critical): external CR 拒绝销毁时, cleanup_all **不看** delete_cluster
# 返回码, 只认 _CEPH_ABORT_WIPE/_CEPH_UNSAFE_UNMAP —— 拒绝分支不置位的话 --all 仍会物理清盘。
_start="$(grep -nF 'if [ -n "${_ext_cc}" ]; then' "${CLEANUP}" | head -1 | cut -d: -f1)"
_end="$(awk -v s="${_start:-0}" 'NR>s && /^    fi$/{print NR; exit}' "${CLEANUP}")"
_ext_block="$(sed -n "${_start:-1},${_end:-1}p" "${CLEANUP}")"
chk "external 拒绝分支可提取" "1" "$([ -n "${_start}" ] && [ -n "${_end}" ] && echo 1 || echo 0)"
_abort_ln="$(printf '%s\n' "${_ext_block}" | grep -nF '_CEPH_ABORT_WIPE=1' | head -1 | cut -d: -f1)"
_ret_ln="$(printf '%s\n' "${_ext_block}" | grep -nF 'return 1' | head -1 | cut -d: -f1)"
chk "external 拒绝时置 _CEPH_ABORT_WIPE" "1" "$([ -n "${_abort_ln}" ] && echo 1 || echo 0)"
chk "_CEPH_ABORT_WIPE 置位在 return 之前" "1" \
    "$([ -n "${_abort_ln}" ] && [ -n "${_ret_ln}" ] && [ "${_abort_ln}" -lt "${_ret_ln}" ] && echo 1 || echo 0)"
chk_contains "显式放行开关仍在(行为不变)" 'CEPH_CLEANUP_ALLOW_EXTERNAL=1' "${CLEANUP}"
# 2026-10-26 CodeRabbit: external 分类查询失败必须 fail-closed —— 不能 `|| true` 吞成
# "无 external"(否则后续存在性查询一旦成功, 会在未确认的情况下继续删消费者/PVC/CR)。
chk_contains "external 分类查询用 if ! 捕获失败" 'if ! _ext_rows="$(SSH' "${CLEANUP}"
chk_not_contains "external 分类查询不再 || true 吞错" \
    'EXT:.spec.external.enable --no-headers 2>/dev/null || true' "${CLEANUP}"
_ext_q_start="$(grep -nF 'if ! _ext_rows="$(SSH' "${CLEANUP}" | head -1 | cut -d: -f1)"
_ext_q_end="$(awk -v s="${_ext_q_start:-0}" 'NR>s && /^    fi$/{print NR; exit}' "${CLEANUP}")"
_ext_q_block="$(sed -n "${_ext_q_start:-1},${_ext_q_end:-1}p" "${CLEANUP}")"
chk "external 分类查询失败分支可提取" "1" "$([ -n "${_ext_q_start}" ] && [ -n "${_ext_q_end}" ] && echo 1 || echo 0)"
chk "external 查询失败置 _CEPH_ABORT_WIPE" "1" \
    "$(printf '%s\n' "${_ext_q_block}" | grep -cF '_CEPH_ABORT_WIPE=1' || true)"
chk "CRD 不存在仍视为无集群(不误拦)" "1" \
    "$(printf '%s\n' "${_ext_q_block}" | grep -cF "doesn't have a resource type" || true)"

echo "== ⑤ RBD 清理前必须证明设备空闲(2026-11-11 D 态事故) =="
chk_contains "rbd-cleanup 忙闲探测" "_rbd_device_busy" "${RBDC}"
chk_contains "ceph-cleanup 保留在用/在飞 IO 设备" "在用/有在飞 IO" "${CLEANUP}"
chk_contains "rbd-cleanup 保留在飞 IO 设备" "设备在用/有在飞 IO" "${RBDC}"
chk_contains "rbd-cleanup 无法确认 PV 时跳过清理" "无法证明 rbd 映射是孤儿" "${RBDC}"
chk_contains "ceph-cleanup 记录 holders 读取状态" "_h_rc" "${CLEANUP}"
chk_contains "ceph-cleanup 记录 open fd 读取状态" "_fd_rc" "${CLEANUP}"
chk_contains "ceph-cleanup 记录 inflight 读取状态" "_inf_rc" "${CLEANUP}"
chk_contains "ceph-cleanup 记录 findmnt 错误" "_fm_err" "${CLEANUP}"
chk_contains "rbd-cleanup 记录 holders 读取状态" "_h_rc" "${RBDC}"
chk_contains "rbd-cleanup 记录 open fd 读取状态" "_fd_rc" "${RBDC}"
chk_contains "rbd-cleanup 记录 inflight 读取状态" "_inf_rc" "${RBDC}"
chk_contains "rbd-cleanup 记录 findmnt 错误" "_fm_err" "${RBDC}"

echo "== ⑥ inventory 驱动 + 精确设备节点清理(2026-11-23) =="
chk_contains "rbd-cleanup 支持 --inventory" '--inventory) INVENTORY=' "${RBDC}"
chk_contains "rbd-cleanup 解析 ansible-inventory" 'ansible-inventory -i "${INVENTORY}" --list' "${RBDC}"
chk_contains "rbd-cleanup 使用 inventory 的 user/key" 'INVENTORY_TARGETS+=("${_i_ip}|${_i_user' "${RBDC}"
chk_contains "rbd-cleanup 递归 inventory children(Ansible 2.19)" "seen_groups" "${RBDC}"
chk_contains "fallback 仅解析 k8s 目标组" 'for group in ("kube_node", "kube_control_plane")' "${RBDC}"
chk_not_contains "fallback 不再遍历全部组" 'add_group(d.get("all")' "${RBDC}"
chk_contains "只删已确认 unmap 的 id 设备节点" 'sudo rm -f /dev/rbd${id}' "${RBDC}"
chk_not_contains "不再通配删除 /dev/rbd*" 'sudo rm -f /dev/rbd* 2>/dev/null' "${RBDC}"
chk_contains "list 模式跳过 kubelet 目录清理" 'if [ "${LIST_ONLY}" != "1" ]; then' "${RBDC}"
chk_contains "offline 守卫传 inventory" '--inventory "${INVENTORY_DIR}/hosts.yml"' "${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"

echo "== ⑦ inventory 行为: 用 hosts.yml 的主机/用户, 且 --list 只读 =="
mkdir -p "${TMP}/inv-bin"
cat > "${TMP}/inv-bin/ansible-inventory" <<'FAKE'
#!/bin/bash
[ "${FAKE_INV_FAIL:-0}" = "1" ] && exit 1
printf '%s
' '{"_meta":{"hostvars":{"inv1":{"ansible_host":"10.9.9.9","ansible_user":"invuser","ansible_ssh_private_key_file":"/tmp/fake-key"},"inv-child":{"ansible_host":"10.9.9.10","ansible_user":"invuser","ansible_ssh_private_key_file":"/tmp/fake-key"}}},"kube_control_plane":{"hosts":["inv1"]},"kube_node":{"children":["node_children"]},"node_children":{"hosts":["inv-child"]}}'
FAKE
cat > "${TMP}/inv-bin/ssh" <<'FAKE'
#!/bin/bash
printf '%s
' "$*" >> "${FAKE_INV_SSH_LOG:?}"
exit 0
FAKE
chmod +x "${TMP}/inv-bin/ansible-inventory" "${TMP}/inv-bin/ssh"
cat > "${TMP}/inv-cluster.conf" <<'EOF'
NODES=("worker,wrong,10.0.0.1,root,-")
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF
cat > "${TMP}/hosts.yml" <<'EOF'
all:
  hosts:
    inv1:
      ansible_host: 10.9.9.9
      ansible_user: invuser
EOF
: > "${TMP}/inv-ssh.log"
out="$(PATH="${TMP}/inv-bin:${PATH}" CLUSTER_CONF="${TMP}/inv-cluster.conf"     FAKE_INV_SSH_LOG="${TMP}/inv-ssh.log"     bash "${RBDC}" --list --skip-keep-query --inventory "${TMP}/hosts.yml" 2>&1)"; rc=$?
chk "inventory 模式退出码" "0" "${rc}"
chk_contains "命中 inventory 主机" "invuser@10.9.9.9" "${TMP}/inv-ssh.log"
chk_contains "命中子组 inventory 主机" "invuser@10.9.9.10" "${TMP}/inv-ssh.log"
if grep -qF 'root@10.0.0.1' "${TMP}/inv-ssh.log" 2>/dev/null; then
    echo "  FAIL 不应触碰 cluster.conf 的主机"; fail=1
else
    echo "  ok  不触碰 cluster.conf 的主机"
fi
if grep -qE 'sudo rm -f|/var/lib/kubelet' "${TMP}/inv-ssh.log" 2>/dev/null; then
    echo "  FAIL --list 不应写设备节点/kubelet 目录"; fail=1
else
    echo "  ok  --list 只读(无 rm/kubelet 目录清理)"
fi
# cluster.conf 缺失时, 只要 inventory 可用就必须继续(覆盖安装 reset 后常见)
: > "${TMP}/inv-ssh.log"
out2="$(PATH="${TMP}/inv-bin:${PATH}" CLUSTER_CONF="${TMP}/missing.conf" \
    FAKE_INV_SSH_LOG="${TMP}/inv-ssh.log" \
    bash "${RBDC}" --list --skip-keep-query --inventory "${TMP}/hosts.yml" 2>&1)"; rc2=$?
chk "无 cluster.conf 仍可运行" "0" "${rc2}"
chk_contains "无 cluster.conf 仍命中 inventory 主机" "invuser@10.9.9.9" "${TMP}/inv-ssh.log"

# 无 ansible-inventory 时的 YAML 兜底: 只取 kube_node/kube_control_plane 及子孙,
# 不能把 backup 等无关组也送进 cleanup_node(2026-11-23 CodeRabbit)。
cat > "${TMP}/hosts-fallback.yml" <<'EOF'
all:
  vars:
    ansible_user: root
  children:
    k8s_cluster:
      children:
        kube_control_plane:
          hosts:
            cp1:
              ansible_host: 10.0.0.1
        kube_node:
          vars:
            ansible_ssh_private_key_file: /tmp/group-key
          children:
            node_children:
              hosts:
                worker1:
                  ansible_host: 10.0.0.2
                  ansible_user: k8suser
    backup:
      hosts:
        backup1:
          ansible_host: 10.0.0.3
          ansible_user: backuser
EOF
: > "${TMP}/inv-ssh.log"
out3="$(PATH="${TMP}/inv-bin:${PATH}" CLUSTER_CONF="${TMP}/missing.conf" \
    FAKE_INV_FAIL=1 FAKE_INV_SSH_LOG="${TMP}/inv-ssh.log" \
    bash "${RBDC}" --list --skip-keep-query --inventory "${TMP}/hosts-fallback.yml" 2>&1)"; rc3=$?
chk "fallback 退出码" "0" "${rc3}"
chk_contains "fallback 继承 all.vars 用户" "root@10.0.0.1" "${TMP}/inv-ssh.log"
chk_contains "fallback host vars 覆盖组级用户" "k8suser@10.0.0.2" "${TMP}/inv-ssh.log"
chk_contains "fallback 继承组级私钥" "-i /tmp/group-key" "${TMP}/inv-ssh.log"
if grep -qF 'backuser@10.0.0.3' "${TMP}/inv-ssh.log" 2>/dev/null; then
    echo "  FAIL fallback 不应清理 backup 组"; fail=1
else
    echo "  ok  fallback 不清理 backup 组"
fi

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-ceph-nbd-guards: 全部通过"
else
    echo "❌ test-ceph-nbd-guards: 存在失败项"
fi
exit "${fail}"
