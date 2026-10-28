#!/bin/bash
# ============================================================
# MODULE: cephfs_mount
# DESC: 自动把 CephFS 子目录挂载到**每台节点**的宿主机路径(DaemonSet + mount propagation)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: CEPHFS_MOUNT_ENABLED
# REQUIRES: k8s_deploy
# UNINSTALL: 1
# 说明:
#   · 目标: 节点上 /mnt/cephfs/models 直接可见 CephFS 内的 models 目录(共享模型等大文件)。
#   · 实现: 用集群已部署的 cephcsi 镜像(自带 mount.ceph)跑 DaemonSet, 在容器内执行
#     mount -t ceph; hostPath 目标带 mountPropagation: Bidirectional → 挂载传播到宿主机同名路径。
#     节点**无需安装 ceph-common**, 不写 fstab/systemd; 节点重启由 DaemonSet 自动重挂。
#   · 文件系统: internal 复用 CEPHFS_ENABLED 自动创建的 CephFilesystem(默认 cephfs), 本模块不重复建 FS;
#     external 读外部 CephFS(external-ceph.env 自动派生 mon/FS/CSI node 凭据, 或 external-cephfs.env
#     专用文件); CephFS 内子目录(默认 models)不存在时由容器自动创建并 chmod(默认 0777)。
#   · 只读: CEPHFS_MOUNT_READ_ONLY=true → mount -o ro, 不创建子目录(要求已存在), 验证用 ls/只读选项,
#     适合外部提供方给的 client.linux-host-ro 这类只读 key。
#   · 凭据: internal 模式创建专用 cephx 用户(mon allow r / mds allow rw fsname=<fs> /
#     osd allow rw tag cephfs metadata|data=<fs>), 密钥只存 K8s Secret + Pod 内 secretfile;
#     external 模式复用 CEPHFS_NODE_USER/KEYRING(或 CEPHFS_USER/KEYRING、CEPH_USER/KEYRING),
#     未显式配置时从 external-ceph.env 的 CSI_CEPHFS_NODE_SECRET* / ROOK_EXTERNAL_* 派生
#     (user/keyring **成对**派生: 任一显式设置即不派生另一个, 避免不同 CephX 身份混配)。
#   · mon 地址: internal 从 ConfigMap rook-ceph-mon-endpoints 归一化; external 用 CEPH_MONITORS
#     (未显式配置时从 external-ceph.env 的 ROOK_EXTERNAL_CEPH_MON_DATA 派生)。
#   · 依赖: REQUIRES k8s_deploy(集群必须先存在); 不再 REQUIRES ceph_csi —— external 只做宿主机挂载时不需要导入外部 CSI;
#     --steps cephfs_mount 在已部署集群上: k8s_deploy 状态 done(REPEAT:0) → 闭包跳过, 不会重跑; 全新集群则先部署 k8s。
#     internal 全量部署仍按文件序号(03 ceph_csi → 07 cephfs_mount)保证顺序, 单独 --steps
#     internal 时请一并跑 ceph,ceph_csi(模块会预检 CephCluster/CephFilesystem 并就绪)。
#   · 验证: DaemonSet Ready 后逐台 Ready 节点 SSH 校验(fstype=ceph + mds_namespace=选定 FS +
#     读写/只读探针); 预检会卸载 FS/只读状态不一致的旧挂载(DS 只按 fstype 判"已挂载")。
#   · 卸载: 删 DaemonSet + 等 Pod 退出 + **逐节点显式 umount**(传播到宿主机的挂载不会必然随
#     Pod 退出消失, 2026-10-19 实机验证) + Secret + internal 专用 cephx 用户;
#     **任一节点仍有 ceph 挂载残留 → 非零退出**(不能静默成功, 否则 Ceph 销毁后挂载变僵尸态);
#     保留 CephFS 内数据与宿主机空目录。REPEAT:1 → 每次部署重新 apply/验证(修正漂移)。
#   · 回归: bash deployments/scripts/tools/tests/test-cephfs-mount.sh
# 数据源: cluster.conf (CEPHFS_MOUNT_ENABLED / CEPHFS_MOUNT_* / CEPHFS_ENABLED / CEPH_MODE /
#         CEPHFS_FS / CEPH_MONITORS / CEPHFS_NODE_USER / CEPHFS_NODE_KEYRING / CEPH_NAMESPACE /
#         CEPH_EXTERNAL_ENV_FILE / CEPHFS_MOUNT_ENV_FILE / CEPHCSI_VERSION / NODES)
# 用法:   sudo ./deploy-cluster.sh --steps cephfs_mount
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---------------- external CephFS 参数自动派生(2026-10-27) ----------------
# 容器 d 实机现状: 用户只有提供方导出的 external-ceph.env(Rook 官方格式), 里面是
#   ROOK_EXTERNAL_CEPH_MON_DATA / CEPHFS_FS_NAME / CSI_CEPHFS_NODE_SECRET*;
# 原模块只认 CEPH_MONITORS/CEPHFS_FS/CEPHFS_NODE_KEYRING, 于是 external 宿主机挂载永远
# 要用户重复抄一遍。这里在默认值之前补全:
#   ① CEPHFS_MOUNT_ENV_FILE(专用, 默认 deployments/config/external-cephfs.env): 文件里出现的
#      变量优先(挂载专用, 含只读 key; 用户可用它覆盖 path/subdir/read_only);
#   ② 其次 CEPH_EXTERNAL_ENV_FILE(默认 deployments/config/external-ceph.env)的 Rook 导出:
#      只补空值, 显式 cluster.conf / 环境变量始终优先;
#   ③ 只读开关未显式设置时读专用文件。
# 凭据选择: CSI_CEPHFS_NODE_SECRET(节点角色) > ROOK_EXTERNAL_USER_SECRET(healthchecker 兜底);
#   仅当 CEPHFS_NODE_USER 与 CEPHFS_NODE_KEYRING **都未显式设置**时才派生, 且两者成对派生
#   (只显式给一个时, 另一个保持空 → 由缺凭据预检明确报错, 不会跨身份凑对)。
# 只读提供方用专用文件写 CEPHFS_MOUNT_READ_ONLY=true, 不要把只读 key 写进仓库。
_normalize_mons() {
    local raw part out=""
    raw="$(printf '%s' "$1" | tr -d '[:space:]')"
    local IFS=','
    for part in ${raw}; do
        part="${part#*=}"
        part="${part#v2:}"; part="${part#v1:}"
        part="${part%%/*}"
        [ -n "${part}" ] || continue
        out="${out:+${out},}${part}"
    done
    printf '%s' "${out}"
}

# 在子 shell 中 source env 文件并取一个变量(不污染本模块全局变量)
_env_get() {
    local _f="$1" _v="$2"
    [ -f "${_f}" ] || return 0
    (
        set +u
        # shellcheck disable=SC1090
        . "${_f}" >/dev/null 2>&1
        printf '%s' "${!_v:-}"
    )
}

_load_external_cephfs_env() {
    [ "${CEPH_MODE:-internal}" = "external" ] || return 0
    local _ext_env _mount_env _v _val _raw _nu _ru _nk _rk _ro _gen
    local _user_explicit _key_explicit
    _ext_env="${CEPH_EXTERNAL_ENV_FILE:-${REPO_ROOT}/deployments/config/external-ceph.env}"
    _mount_env="${CEPHFS_MOUNT_ENV_FILE:-${REPO_ROOT}/deployments/config/external-cephfs.env}"

    # ① 专用挂载 env: **该文件里出现的变量优先**(它是挂载专用的唯一配置源; 含只读 key)。
    if [ -f "${_mount_env}" ]; then
        for _v in CEPH_MONITORS CEPHFS_FS CEPHFS_NODE_USER CEPHFS_NODE_KEYRING \
                  CEPHFS_MOUNT_READ_ONLY CEPHFS_MOUNT_PATH CEPHFS_MOUNT_SUBDIR; do
            _val="$(_env_get "${_mount_env}" "${_v}")"
            [ -n "${_val}" ] && printf -v "${_v}" '%s' "${_val}"
        done
    fi

    # ② Rook 官方 external-ceph.env(只补未显式设置的变量)
    # ★ 凭据必须"成对"派生(2026-10-28): CEPHFS_NODE_USER / CEPHFS_NODE_KEYRING 属于同一个
    #   CephX 身份。只要用户**显式给了其中任一个**(cluster.conf/env 变量, 或上面的专用 mount
    #   env), 另一个就**不再**从 external-ceph.env 派生 —— 否则会把 CSI node secret(或
    #   ROOK_EXTERNAL_*)的 key 配到另一个用户名上, 直到 mount 时才认证失败(根因难定位)。
    #   此时缺 keyring 会落在下方"external 模式缺凭据"预检, 给出明确错误。
    _user_explicit="${CEPHFS_NODE_USER:-}"
    _key_explicit="${CEPHFS_NODE_KEYRING:-}"
    if [ -z "${CEPH_MONITORS:-}" ]; then
        _raw="$(_env_get "${_ext_env}" ROOK_EXTERNAL_CEPH_MON_DATA)"
        [ -n "${_raw}" ] && CEPH_MONITORS="$(_normalize_mons "${_raw}")"
    fi
    [ -n "${CEPHFS_FS:-}" ] || CEPHFS_FS="$(_env_get "${_ext_env}" CEPHFS_FS_NAME)"
    if [ -z "${CEPHFS_NODE_USER:-}" ] && [ -z "${_key_explicit}" ]; then
        _nu="$(_env_get "${_ext_env}" CSI_CEPHFS_NODE_SECRET_NAME)"
        _gen="$(_env_get "${_ext_env}" CEPHX_KEY_GENERATION)"
        if [ -n "${_nu}" ]; then
            # 与 03_ceph_csi.sh 的 _ext_uid 同口径: generation 非空/非 0 时 username = <secret_name>.<gen>
            if [ -n "${_gen}" ] && [ "${_gen}" != "0" ]; then _nu="${_nu}.${_gen}"; fi
            CEPHFS_NODE_USER="${_nu}"
        else
            _ru="$(_env_get "${_ext_env}" ROOK_EXTERNAL_USERNAME)"
            [ -n "${_ru}" ] && CEPHFS_NODE_USER="${_ru#client.}"
        fi
    fi
    if [ -z "${CEPHFS_NODE_KEYRING:-}" ] && [ -z "${_user_explicit}" ]; then
        _nk="$(_env_get "${_ext_env}" CSI_CEPHFS_NODE_SECRET)"
        [ -n "${_nk}" ] && CEPHFS_NODE_KEYRING="${_nk}"
        if [ -z "${CEPHFS_NODE_KEYRING:-}" ]; then
            _rk="$(_env_get "${_ext_env}" ROOK_EXTERNAL_USER_SECRET)"
            [ -n "${_rk}" ] && CEPHFS_NODE_KEYRING="${_rk}"
        fi
    fi
    # ③ 只读开关: 未显式设置时读专用文件
    if [ -z "${CEPHFS_MOUNT_READ_ONLY:-}" ]; then
        _ro="$(_env_get "${_mount_env}" CEPHFS_MOUNT_READ_ONLY)"
        [ -n "${_ro}" ] && CEPHFS_MOUNT_READ_ONLY="${_ro}"
    fi
    return 0
}
_load_external_cephfs_env

# ---------------- 变量与默认值 ----------------
CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
CEPH_MODE="${CEPH_MODE:-internal}"
CEPHFS_MOUNT_ENABLED="${CEPHFS_MOUNT_ENABLED:-${CEPHFS_ENABLED:-false}}"
CEPHFS_MOUNT_PATH="${CEPHFS_MOUNT_PATH:-/mnt/cephfs/models}"
CEPHFS_MOUNT_SUBDIR="${CEPHFS_MOUNT_SUBDIR:-models}"
CEPHFS_MOUNT_DIR_MODE="${CEPHFS_MOUNT_DIR_MODE:-0777}"
CEPHFS_MOUNT_USER="${CEPHFS_MOUNT_USER:-cubestack-cephfs-models}"
CEPHFS_MOUNT_IMAGE="${CEPHFS_MOUNT_IMAGE:-}"
CEPHFS_MOUNT_DS_NAME="${CEPHFS_MOUNT_DS_NAME:-cephfs-models-mount}"
CEPHFS_MOUNT_SECRET="${CEPHFS_MOUNT_SECRET:-cephfs-models-client}"
CEPHFS_MOUNT_ENV_FILE="${CEPHFS_MOUNT_ENV_FILE:-}"
CEPHFS_FS="${CEPHFS_FS:-}"
CEPHFS_NODE_USER="${CEPHFS_NODE_USER:-}"
CEPHFS_NODE_KEYRING="${CEPHFS_NODE_KEYRING:-}"
CEPHFS_MOUNT_READ_ONLY="${CEPHFS_MOUNT_READ_ONLY:-false}"
case "${CEPHFS_MOUNT_READ_ONLY,,}" in
    true|1|yes|on)   CEPHFS_MOUNT_READ_ONLY="true" ;;
    false|0|no|off|"") CEPHFS_MOUNT_READ_ONLY="false" ;;
    *)
        if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
            warn "CEPHFS_MOUNT_READ_ONLY 非法, 卸载时忽略: '${CEPHFS_MOUNT_READ_ONLY}'"
            CEPHFS_MOUNT_READ_ONLY="false"
        else
            err "CEPHFS_MOUNT_READ_ONLY 非法: '${CEPHFS_MOUNT_READ_ONLY}'(可用 true/false)"
            exit 1
        fi ;;
esac
CEPHFS_FS_NAME=""

# ---------------- 输入安全校验(路径会进入 sed/YAML/远端 shell) ----------------
_validate_inputs() {
    if ! printf '%s' "${CEPHFS_MOUNT_PATH}" | grep -qE '^/[A-Za-z0-9._/-]+$' \
        || printf '%s' "${CEPHFS_MOUNT_PATH}" | grep -q '/\.\.\?/' \
        || [ "${CEPHFS_MOUNT_PATH}" = "/" ]; then
        err "CEPHFS_MOUNT_PATH 非法: '${CEPHFS_MOUNT_PATH}'(只允许 / 开头的安全字符, 不得为根/含 ..)"
        return 1
    fi
    if ! printf '%s' "${CEPHFS_MOUNT_SUBDIR}" | grep -qE '^[A-Za-z0-9._-]+$' \
        || [ "${CEPHFS_MOUNT_SUBDIR}" = "." ] || [ "${CEPHFS_MOUNT_SUBDIR}" = ".." ]; then
        err "CEPHFS_MOUNT_SUBDIR 非法: '${CEPHFS_MOUNT_SUBDIR}'(只允许单层安全字符)"
        return 1
    fi
    if ! printf '%s' "${CEPHFS_MOUNT_DIR_MODE}" | grep -qE '^0?[0-7]{3,4}$'; then
        err "CEPHFS_MOUNT_DIR_MODE 非法: '${CEPHFS_MOUNT_DIR_MODE}'(示例: 0777 / 0755)"
        return 1
    fi
    if [ "${CEPH_MODE}" != "external" ] \
        && ! printf '%s' "${CEPHFS_MOUNT_USER}" | grep -qE '^[A-Za-z0-9._-]+$'; then
        err "CEPHFS_MOUNT_USER 非法: '${CEPHFS_MOUNT_USER}'"
        return 1
    fi
    return 0
}

# 逐节点 SSH: 优先密钥; 失败回退 NODES 中的密码(需 sshpass)
_node_ssh() {
    local ip="$1"; shift
    local user pw line
    user="$(ssh_user_for_ip "${ip}")"
    if timeout 30 ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${user}@${ip}" "$@" 2>/dev/null; then
        return 0
    fi
    pw="$(
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            node_parse "${line}"
            [ "${NODE_IP}" = "${ip}" ] && { printf '%s' "${NODE_PW}"; break; }
        done
    )"
    if [ -n "${pw}" ] && command -v sshpass >/dev/null 2>&1; then
        timeout 30 sshpass -p "${pw}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=8 "${user}@${ip}" "$@"
        return $?
    fi
    return 1
}

# ---------------- 卸载分支(必须在 TOGGLE 检查之前) ----------------
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    _validate_inputs || exit 1
    init_remote_kubectl || exit 1
    say "卸载 CephFS 宿主机挂载(DaemonSet ${CEPHFS_MOUNT_DS_NAME})..."
    # ① 删 DS: Pod 终止(注意: 传播到宿主机的 mount 不会必然随 namespace 销毁而消失,
    #    必须下面逐节点显式 umount —— 2026-10-19 实机验证)
    SSH "${K}" -n "${CEPH_NAMESPACE}" delete ds "${CEPHFS_MOUNT_DS_NAME}" --ignore-not-found --timeout=120s \
        || warn "  删除 DaemonSet 失败/超时(继续清理其余对象)"
    # ② 等 Pod 退出(有界 120s), 避免卸载时仍有进程占用挂载。
    #    DaemonSet 不支持稳定的 scale 子资源; 删除 DS 才能让控制器停止重建 Pod —— 效果等价于
    #    "先 scale 0, 再等 Pod 退出", 但不会留下一个会被误重建的 DS 对象。
    for _i in $(seq 1 24); do
        _pods="$( (SSH "${K}" -n "${CEPH_NAMESPACE}" get pods -l "app.kubernetes.io/name=${CEPHFS_MOUNT_DS_NAME}" --no-headers 2>/dev/null) || true )"
        [ -z "${_pods}" ] && break
        sleep 5
    done
    # ③ 逐节点卸载 ceph 挂载(可能有历史堆叠, 最多 20 层; 不动非 ceph 文件系统)
    # ★ 2026-10-26: external 模式保留宿主机挂载 —— 外部 Ceph 不是本次 K8s 覆盖的资产,
    #   卸载它既不必要也可能因消费者 busy 而失败; 新部署的 cephfs_mount 会复用可读挂载,
    #   不可读时再按安装前预检 lazy umount。internal 模式仍需严格卸载(随后 Ceph 会被销毁)。
    _unmount_fail=0
    if [ "${CEPH_MODE}" = "external" ]; then
        say "  CEPH_MODE=external → 保留宿主机 CephFS 挂载 ${CEPHFS_MOUNT_PATH}(外部 Ceph 资源; 新部署可复用)"
    else
    for _line in "${NODES[@]:-}"; do
        [ -z "${_line}" ] && continue
        node_parse "${_line}"
        _host="${NODE_HOSTNAME}"; _ip="${NODE_IP}"
        [ -n "${_ip}" ] || continue
        _unmount_cmd="n=0
while [ \${n} -lt 20 ]; do
  fs=\$(findmnt -n -o FSTYPE -T '${CEPHFS_MOUNT_PATH}' 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
  [ \"\${fs}\" = ceph ] || break
  sudo umount -l '${CEPHFS_MOUNT_PATH}' 2>/dev/null || sudo umount -f '${CEPHFS_MOUNT_PATH}' 2>/dev/null || exit 2
  n=\$((n+1))
done
fs=\$(findmnt -n -o FSTYPE -T '${CEPHFS_MOUNT_PATH}' 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
[ \"\${fs}\" != ceph ] || exit 3
echo CEPH_UNMOUNT_OK"
        _out="$(_node_ssh "${_ip}" "${_unmount_cmd}" 2>&1 || true)"
        case "${_out}" in
            *CEPH_UNMOUNT_OK*) ok "  ${_host}(${_ip}) 宿主机挂载已卸载" ;;
            *)
                _unmount_fail=1
                _err_tail="$(printf '%s\n' "${_out}" | command grep -v '^Warning: Permanently added' | tail -3 | tr '\n' ' ' || true)"
                warn "  ${_host}(${_ip}) 卸载失败/仍有 ceph 挂载: ${_err_tail:-<无输出>}"
                ;;
        esac
    done
    fi
    SSH "${K}" -n "${CEPH_NAMESPACE}" delete secret "${CEPHFS_MOUNT_SECRET}" --ignore-not-found >/dev/null 2>&1 \
        || warn "  删除 Secret 失败(继续)"
    if [ "${CEPH_MODE}" != "external" ]; then
        # 专用 cephx 用户删除(不存在时 ceph 返回 ENOENT, 忽略)。
        # ★ 2026-10-19 实机根因: 旧实现无超时地 kubectl exec; Ceph 已删/rook-ceph-tools
        #   已在 Terminating 时 exec 永久挂起 → 整个 --fresh 优雅卸载卡死(直到 600s timeout)。
        #   仅当 CephCluster 仍 Ready 时才尝试, 且 kubectl/ceph 双超时; 否则幂等跳过。
        _cc_phase="$( (SSH "${K}" -n "${CEPH_NAMESPACE}" get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null) || true )"
        if [ "${_cc_phase}" = "Ready" ]; then
            SSH "timeout 30 ${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- timeout 20 ceph auth del client.${CEPHFS_MOUNT_USER}" >/dev/null 2>&1 \
                || true
        else
            say "  CephCluster 非 Ready(${_cc_phase:-无}) → 跳过 cephx 用户删除(集群已销毁/未就绪, 幂等)"
        fi
        unset _cc_phase
    fi
    if [ "${_unmount_fail}" != "0" ]; then
        # 不能静默成功: 残留挂载会在 Ceph 销毁后变成僵尸态(内核 ceph 无限重试),
        # 后续 node_pkgs/apt 可能 D 状态卡死。让调用方(cluster-teardown)如实看到失败。
        err "  部分节点仍有 ceph 挂载残留: ${CEPHFS_MOUNT_PATH}"
        err "  请先逐节点 umount 后重跑卸载; 否则 Ceph 销毁后挂载会变成僵尸态"
        exit 1
    fi
    ok "卸载完成(保留 CephFS 内数据与宿主机空目录 ${CEPHFS_MOUNT_PATH})"
    exit 0
fi

# ---------------- 开关/模式门禁 ----------------
[ "${CEPHFS_MOUNT_ENABLED}" = "true" ] || { say "CEPHFS_MOUNT_ENABLED=false, 跳过 CephFS 宿主机挂载"; exit 0; }

if [ "${CEPH_MODE}" = "external" ]; then
    CEPHFS_FS_NAME="${CEPHFS_FS:-}"
    [ -n "${CEPHFS_FS_NAME}" ] || {
        err "external 模式未配置 CephFS: CEPHFS_FS 为空, 且 CEPH_EXTERNAL_ENV_FILE/CEPHFS_MOUNT_ENV_FILE 未提供 CEPHFS_FS_NAME"
        err "  修法: 在 cluster.conf 设 CEPHFS_FS, 或提供 external-ceph.env(CEPHFS_FS_NAME=...) / external-cephfs.env(CEPHFS_FS=...)"
        exit 1
    }
else
    [ "${CEPHFS_ENABLED:-false}" = "true" ] || { say "CEPHFS_ENABLED=false(无 CephFS), 跳过宿主机挂载"; exit 0; }
    # 兜底(2026-10-22 用户实机): Ceph 基座与 CSI 都未启用时, 即使本模块开关被旧配置/显式
    # 误开, 也不得继续 —— 否则会去预检一个根本不存在的 CephCluster, 把部署打断在一个
    # 与用户配置(CEPH_ENABLED=false)矛盾的模块上。external 模式走外部 Ceph, 不适用。
    if [ "${CEPH_ENABLED:-false}" != "true" ] && [ "${CEPH_CSI_ENABLED:-false}" != "true" ]; then
        say "Ceph 未启用(CEPH_ENABLED/CEPH_CSI_ENABLED=false), 跳过 CephFS 宿主机挂载"
        exit 0
    fi
    CEPHFS_FS_NAME="cephfs"
fi

# FS 名进入 YAML/内核挂载选项(mds_namespace=), 只允许安全字符
if ! printf '%s' "${CEPHFS_FS_NAME}" | grep -qE '^[A-Za-z0-9._-]+$'; then
    err "CEPHFS_FS_NAME 非法: '${CEPHFS_FS_NAME}'(只允许字母数字/./_/-)"
    exit 1
fi

init_remote_kubectl || exit 1
_validate_inputs || exit 1

# ---------------- 远端执行助手 ----------------
# YAML 经 stdin 直送 kubectl apply(不落远端 /tmp, 避免 sticky/protected_regular 残留问题;
# 对 Secret 也避免密钥落盘)。
_apply_yaml() {
    local content="$1"
    printf '%s' "${content}" | ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${FIRST_MASTER_USER}@${FIRST_MASTER}" "${K} apply -f -"
}

# ---------------- 预检: Ceph 集群 / CephFilesystem ----------------
if [ "${CEPH_MODE}" != "external" ]; then
    say "预检 Ceph 集群与 CephFilesystem '${CEPHFS_FS_NAME}'..."
    _phase="$( (SSH "${K}" -n "${CEPH_NAMESPACE}" get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null) || true )"
    [ "${_phase}" = "Ready" ] \
        || { err "CephCluster phase='${_phase}'(应为 Ready); 先部署/修复 ceph 模块"; exit 1; }
    _fs_phase="$( (SSH "${K}" -n "${CEPH_NAMESPACE}" get cephfilesystem "${CEPHFS_FS_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null) || true )"
    [ "${_fs_phase}" = "Ready" ] \
        || { err "CephFilesystem '${CEPHFS_FS_NAME}' phase='${_fs_phase}'(应为 Ready); 先设置 CEPHFS_ENABLED=true 并部署 ceph_csi"; exit 1; }
    ok "  CephCluster / CephFilesystem 就绪"
fi

# ---------------- mon 地址 ----------------
if [ "${CEPH_MODE}" = "external" ]; then
    _mons_raw="${CEPH_MONITORS:-}"
else
    _mons_raw="$( (SSH "${K}" -n "${CEPH_NAMESPACE}" get cm rook-ceph-mon-endpoints -o jsonpath='{.data.data}' 2>/dev/null) || true )"
fi
MON_ADDRS="$(_normalize_mons "${_mons_raw}")"
if ! printf '%s' "${MON_ADDRS}" | grep -qE '^[A-Za-z0-9._-]+:[0-9]+(,[A-Za-z0-9._-]+:[0-9]+)*$'; then
    err "mon 地址为空或格式非法(原始: '${_mons_raw}'): 期望 ip:port[,ip:port...]"
    exit 1
fi
ok "  mon 地址: ${MON_ADDRS}"

# ---------------- 镜像 ----------------
IMAGE="${CEPHFS_MOUNT_IMAGE}"
if [ -z "${IMAGE}" ]; then
    IMAGE="$( (SSH "${K}" -n "${CEPH_NAMESPACE}" get ds rook-ceph.cephfs.csi.ceph.com-nodeplugin \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || true )"
fi
[ -n "${IMAGE}" ] || IMAGE="quay.io/cephcsi/cephcsi:${CEPHCSI_VERSION:-v3.17.0}"
if ! printf '%s' "${IMAGE}" | grep -qE '^[A-Za-z0-9._/@:-]+$'; then
    err "镜像引用非法: '${IMAGE}'"; exit 1
fi
ok "  运行镜像: ${IMAGE}"

# ---------------- 凭据 ----------------
if [ "${CEPH_MODE}" = "external" ]; then
    CEPH_USER_NAME="${CEPHFS_NODE_USER:-${CEPHFS_USER:-${CEPH_USER:-admin}}}"
    CEPH_USER_KEY="${CEPHFS_NODE_KEYRING:-${CEPHFS_KEYRING:-${CEPH_KEYRING:-}}}"
    [ -n "${CEPH_USER_KEY}" ] \
        || {
            err "external 模式缺凭据: 设置 CEPHFS_NODE_KEYRING 或 CEPHFS_KEYRING/CEPH_KEYRING"
            if [ -n "${CEPHFS_NODE_USER:-}" ]; then
                err "  注: 显式给了 CEPHFS_NODE_USER 时不会从 external-ceph.env 借用 key(不同身份不能混配); 需成对提供 CEPHFS_NODE_KEYRING"
            fi
            exit 1
        }
    ok "  凭据: 复用 external 用户 client.${CEPH_USER_NAME}"
else
    say "确保专用 cephx 用户 client.${CEPHFS_MOUNT_USER} 存在..."
    _entity="client.${CEPHFS_MOUNT_USER}"
    _caps_mds="allow rw fsname=${CEPHFS_FS_NAME}"
    _caps_osd="allow rw tag cephfs metadata=${CEPHFS_FS_NAME}, allow rw tag cephfs data=${CEPHFS_FS_NAME}"
    _create_out="$( (SSH "${K}" -n "${CEPH_NAMESPACE}" exec deploy/rook-ceph-tools -- \
        ceph auth get-or-create "${_entity}" mon "'allow r'" mds "'${_caps_mds}'" osd "'${_caps_osd}'" 2>&1) || true )"
    CEPH_USER_NAME="${CEPHFS_MOUNT_USER}"
    CEPH_USER_KEY="$( (SSH "${K}" -n "${CEPH_NAMESPACE}" exec deploy/rook-ceph-tools -- \
        ceph auth print-key "${_entity}" 2>/dev/null) || true )"
    CEPH_USER_KEY="$(printf '%s' "${CEPH_USER_KEY}" | tr -d '[:space:]')"
    [ -n "${CEPH_USER_KEY}" ] \
        || { err "创建/读取 cephx 用户失败: ${_create_out}"; err "  检查 toolbox: kubectl -n ${CEPH_NAMESPACE} get deploy rook-ceph-tools"; exit 1; }
    ok "  凭据: client.${CEPH_USER_NAME}(专用用户)"
fi
if ! printf '%s' "${CEPH_USER_NAME}" | grep -qE '^[A-Za-z0-9._-]+$'; then
    err "cephx 用户非法: '${CEPH_USER_NAME}'(只允许字母数字/./_/-; 会进入 mount 选项)"
    exit 1
fi
if ! printf '%s' "${CEPH_USER_KEY}" | grep -qE '^[A-Za-z0-9+/=]+$'; then
    err "cephx key 格式非法(拒绝写入 Secret)"; exit 1
fi
KEY_SHA="$(printf '%s' "${CEPH_USER_KEY}" | sha256sum | cut -c1-16)"

# ---------------- Secret ----------------
say "写入 Secret ${CEPH_NAMESPACE}/${CEPHFS_MOUNT_SECRET}..."
SECRET_YAML="$(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${CEPHFS_MOUNT_SECRET}
  namespace: ${CEPH_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: cubestack-installer
type: Opaque
stringData:
  key: "${CEPH_USER_KEY}"
EOF
)"
_apply_yaml "${SECRET_YAML}" >/dev/null || { err "写入 Secret 失败"; exit 1; }
ok "  Secret 已就绪"

# ---------------- 预清理旧集群 CephFS 残留(2026-10-19 实机) ----------------
# 新 Ceph 集群 FSID 与旧挂载不匹配时, /mnt/cephfs/models 仍是 ceph fstype 但 ls/stat
# 永久超时; DS 容器会以为"已挂载"而跳过, Pod 卡 ContainerCreating, 写读探针进 D 状态。
# 这里在 apply DS 前逐节点探测: 现有 ceph 挂载的 fstype/只读状态/**文件系统**都与期望一致
# 且可读 → 保留复用; 否则 lazy umount 让 DS 按当前配置重挂。
# ⚠ DS 的 mounted_ok 只看 fstype(和只读), **不看 mds_namespace** —— CEPHFS_FS_NAME 变更后
#   若不在这里处理, 旧 FS 的可读挂载会被一直复用, 脚本报新 FS 成功而消费者读的是旧数据。
#   mds_namespace 由 DS 的 mount -o 传入, 内核 5.15 的 findmnt OPTIONS 可见(实机验证);
#   缺失该选项同样按不匹配处理(不当作匹配)。
say "预检节点现有 CephFS 挂载(旧集群残留/FS/只读变更自动 lazy umount)..."
_STALE_FAIL=0
for _line in "${NODES[@]:-}"; do
    [ -z "${_line}" ] && continue
    node_parse "${_line}"
    _host="${NODE_HOSTNAME}"; _ip="${NODE_IP}"
    [ -n "${_ip}" ] || continue
    _fs="$(_node_ssh "${_ip}" "findmnt -n -o FSTYPE -T '${CEPHFS_MOUNT_PATH}' 2>/dev/null | tail -1 | tr -d '[:space:]'" 2>/dev/null || true)"
    [ "${_fs}" = "ceph" ] || continue
    # 只读开关/文件系统与现有挂载选项不一致时先卸载, 否则 DS 会以为"已挂载"而跳过
    # (ro/rw 切换、更换 CEPHFS_FS_NAME 都不生效)。
    _opts="$(_node_ssh "${_ip}" "findmnt -n -o OPTIONS -T '${CEPHFS_MOUNT_PATH}' 2>/dev/null | tail -1 | tr -d '[:space:]'" 2>/dev/null || true)"
    _is_ro=false
    case ",${_opts}," in *,ro,*) _is_ro=true ;; esac
    _mns=""
    case ",${_opts}," in
        *,mds_namespace=*) _mns="${_opts#*mds_namespace=}"; _mns="${_mns%%,*}" ;;
    esac
    if [ "${_is_ro}" != "${CEPHFS_MOUNT_READ_ONLY}" ] || [ "${_mns}" != "${CEPHFS_FS_NAME}" ]; then
        warn "  ${_host}(${_ip}) 现有 ceph 挂载 ro=${_is_ro}(期望 ${CEPHFS_MOUNT_READ_ONLY}), fs='${_mns:-<无 mds_namespace>}'(期望 ${CEPHFS_FS_NAME}) 不一致, lazy umount..."
        _node_ssh "${_ip}" "timeout 20 sudo umount -l '${CEPHFS_MOUNT_PATH}' 2>/dev/null || timeout 20 sudo umount -f '${CEPHFS_MOUNT_PATH}' 2>/dev/null || true" || true
        _fs2="$(_node_ssh "${_ip}" "findmnt -n -o FSTYPE -T '${CEPHFS_MOUNT_PATH}' 2>/dev/null | tail -1 | tr -d '[:space:]'" 2>/dev/null || true)"
        if [ "${_fs2}" = "ceph" ]; then
            err "  ${_host}(${_ip}) 卸载后仍有 ceph 挂载, 无法切换只读选项/文件系统 —— 需停 kubelet/containerd 后重启该节点"
            _STALE_FAIL=1
        fi
        continue
    fi
    if _node_ssh "${_ip}" "timeout 5 ls '${CEPHFS_MOUNT_PATH}' >/dev/null 2>&1"; then
        ok "  ${_host}(${_ip}) 现有 ceph 挂载可读, 保留复用"
        continue
    fi
    warn "  ${_host}(${_ip}) 现有 ceph 挂载不可读(疑似旧集群残留), lazy umount..."
    _node_ssh "${_ip}" "timeout 20 sudo umount -l '${CEPHFS_MOUNT_PATH}' 2>/dev/null || timeout 20 sudo umount -f '${CEPHFS_MOUNT_PATH}' 2>/dev/null || true" || true
    _fs2="$(_node_ssh "${_ip}" "findmnt -n -o FSTYPE -T '${CEPHFS_MOUNT_PATH}' 2>/dev/null | tail -1 | tr -d '[:space:]'" 2>/dev/null || true)"
    if [ "${_fs2}" = "ceph" ]; then
        err "  ${_host}(${_ip}) lazy umount 后仍有 ceph 挂载 —— 需停 kubelet/containerd 后重启该节点"
        _STALE_FAIL=1
    else
        ok "  ${_host}(${_ip}) 旧 ceph 挂载已 lazy umount"
    fi
done
[ "${_STALE_FAIL}" = "0" ] || { err "存在无法清理的旧 CephFS 挂载, 拒绝继续(否则 DS/探针会 D 状态卡死)"; exit 1; }

# ---------------- DaemonSet ----------------
TEMPLATE="${REPO_ROOT}/deployments/cubestack-addon/rook/cephfs/04-host-mount-daemonset.yaml"
[ -f "${TEMPLATE}" ] || { err "清单模板不存在: ${TEMPLATE}"; exit 1; }
say "应用 DaemonSet ${CEPHFS_MOUNT_DS_NAME}(目标: 每台节点 ${CEPHFS_MOUNT_PATH})..."
DS_YAML="$(sed \
    -e "s|__NAMESPACE__|${CEPH_NAMESPACE}|g" \
    -e "s|__DS_NAME__|${CEPHFS_MOUNT_DS_NAME}|g" \
    -e "s|__IMAGE__|${IMAGE}|g" \
    -e "s|__TARGET__|${CEPHFS_MOUNT_PATH}|g" \
    -e "s|__USER__|${CEPH_USER_NAME}|g" \
    -e "s|__SECRET__|${CEPHFS_MOUNT_SECRET}|g" \
    -e "s|__MON_ADDRS__|${MON_ADDRS}|g" \
    -e "s|__FS_NAME__|${CEPHFS_FS_NAME}|g" \
    -e "s|__SUBDIR__|${CEPHFS_MOUNT_SUBDIR}|g" \
    -e "s|__DIR_MODE__|${CEPHFS_MOUNT_DIR_MODE}|g" \
    -e "s|__KEY_SHA__|${KEY_SHA}|g" \
    -e "s|__READ_ONLY__|${CEPHFS_MOUNT_READ_ONLY}|g" \
    "${TEMPLATE}")"
_apply_yaml "${DS_YAML}" >/dev/null || { err "应用 DaemonSet 失败"; exit 1; }

ROLLOUT_OK=0
if ( SSH "${K}" -n "${CEPH_NAMESPACE}" rollout status "ds/${CEPHFS_MOUNT_DS_NAME}" --timeout=180s >/dev/null 2>&1 ); then
    ROLLOUT_OK=1; ok "  DaemonSet 已滚动完成"
else
    # 2026-10-19 实机: 旧 CephFS 挂载 lazy umount 后, 内核 ceph 客户端仍可能卡住 →
    #   kubelet 对 hostPath(host-target)的 bind mount 超时("unmounted volumes=[host-target]:
    #   context deadline exceeded"), Pod 永远 ContainerCreating。这种 D 状态只能重启节点。
    _ds_diag="$( (SSH "${K}" -n "${CEPH_NAMESPACE}" describe pods -l "app.kubernetes.io/name=${CEPHFS_MOUNT_DS_NAME}" 2>/dev/null) || true )"
    if printf '%s' "${_ds_diag}" | grep -q 'host-target' \
        && printf '%s' "${_ds_diag}" | grep -qE 'context deadline exceeded|MountVolume.SetUp failed|FailedMount'; then
        err "  DaemonSet Pod 的 hostPath(host-target)挂载超时 —— 节点内核 ceph 客户端/旧挂载仍处于 D 状态"
        err "  处置: systemctl stop kubelet containerd; systemctl reboot -f"
        err "        重启后重跑 --steps cephfs_mount(不要在 Pod 卡住时继续)"
        exit 1
    fi
    warn "  DaemonSet 180s 内未完成滚动(继续逐节点校验; 失败节点会列出)"
fi

# ---------------- 逐节点真实验证 ----------------
say "逐节点验证宿主机挂载(需 Ready + fstype=ceph + 写读探针)..."
VERIFY_FAIL=""
VERIFIED=0
for _line in "${NODES[@]:-}"; do
    [ -z "${_line}" ] && continue
    node_parse "${_line}"
    _host="${NODE_HOSTNAME}"; _ip="${NODE_IP}"
    [ -n "${_ip}" ] || continue
    # --no-headers + awk 取 STATUS 列: 避免把含 ?(...) 的 jsonpath 传给远端 shell
    # (远端 shell 会因未加引号的 ( 报语法错, 曾致所有节点被误判 NotReady)
    _ready="$( (SSH "${K}" get node "${_host}" --no-headers 2>/dev/null) || true )"
    _ready="$(printf '%s' "${_ready}" | awk '{print $2}')"
    if [ "${_ready}" != "Ready" ]; then
        warn "  节点 ${_host}(${_ip}) 状态='${_ready:-未知}'(非 Ready), 跳过挂载校验"
        continue
    fi
    _verify_cmd="set -e
fstype=\$(findmnt -n -o FSTYPE -T '${CEPHFS_MOUNT_PATH}' 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
[ \"\${fstype}\" = ceph ] || { echo \"NOT_MOUNTED:\${fstype}\"; exit 2; }
opts=\$(findmnt -n -o OPTIONS -T '${CEPHFS_MOUNT_PATH}' 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
# 验的是**选定的 FS**: 只看 fstype 会放过旧 FS 的可读挂载(DS 不重挂), 场景见上方预清理注释。
mns=\"\"
case \",\${opts},\" in
    *,mds_namespace=*) mns=\"\${opts#*mds_namespace=}\"; mns=\"\${mns%%,*}\" ;;
esac
[ \"\${mns}\" = '${CEPHFS_FS_NAME}' ] || { echo \"WRONG_FS:期望 ${CEPHFS_FS_NAME}; opts=\${opts}\"; exit 4; }
if [ '${CEPHFS_MOUNT_READ_ONLY}' = 'true' ]; then
    case \",\${opts},\" in
        *,ro,*) ;;
        *) echo \"NOT_READONLY:\${opts}\"; exit 3 ;;
    esac
    timeout 10 ls '${CEPHFS_MOUNT_PATH}' >/dev/null
else
    p='${CEPHFS_MOUNT_PATH}/.cubestack-probe-'\$\$
    printf 'cubestack-probe-ok\\n' > \"\${p}\"
    grep -q 'cubestack-probe-ok' \"\${p}\"
    rm -f \"\${p}\"
fi
echo CEPH_MOUNT_OK"
    _out="$(_node_ssh "${_ip}" "${_verify_cmd}" 2>&1 || true)"
    case "${_out}" in
        *CEPH_MOUNT_OK*) VERIFIED=$((VERIFIED + 1)); ok "  ${_host}(${_ip}) 挂载 OK" ;;
        *) VERIFY_FAIL="${VERIFY_FAIL}${_host}(${_ip}) "; warn "  ${_host}(${_ip}) 校验失败: $(printf '%s' "${_out}" | tail -1)" ;;
    esac
done
if [ "${VERIFIED}" -eq 0 ]; then
    err "没有节点完成挂载校验(全部非 Ready 或 SSH 失败) —— 不能判定成功"
    err "  排查: kubectl -n ${CEPH_NAMESPACE} get ds ${CEPHFS_MOUNT_DS_NAME}; kubectl get nodes"
    exit 1
fi
if [ -n "${VERIFY_FAIL}" ]; then
    err "以下节点未通过 ${CEPHFS_MOUNT_PATH} 挂载校验: ${VERIFY_FAIL}"
    err "  排查: kubectl -n ${CEPH_NAMESPACE} get ds ${CEPHFS_MOUNT_DS_NAME}; kubectl -n ${CEPH_NAMESPACE} logs ds/${CEPHFS_MOUNT_DS_NAME}"
    exit 1
fi
[ "${ROLLOUT_OK}" = "1" ] || warn "  逐节点校验通过, 但 rollout status 曾超时(可能有节点在滚动, 请复查)"

record_installed_component "cephfs_mount"
ok "CephFS 宿主机挂载完成: 每台节点 ${CEPHFS_MOUNT_PATH} → ${CEPHFS_FS_NAME}:/${CEPHFS_MOUNT_SUBDIR}"
