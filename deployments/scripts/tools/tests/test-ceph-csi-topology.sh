#!/bin/bash
# ============================================================
# test-ceph-csi-topology.sh — CSI 供给层按拓扑渲染
#
# 覆盖:
#   ① 单节点: rbd-pool failureDomain=osd / requireSafeReplicaSize=false
#   ② 单节点: CephFilesystem activeCount=1 / activeStandby=false / size=1
#   ③ 单节点: CephObjectStore instances=1 / failureDomain=osd
#   ④ 多节点: host / true / activeCount=2 / activeStandby=true / instances=2
#   ⑤ SC 名称与默认标记不变(ceph-rbd-ephemeral 默认)
#   ⑥ 渲染结果无未替换占位符
#
# 用法: bash deployments/scripts/tools/tests/test-ceph-csi-topology.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CSI_MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/03_ceph_csi.sh"
ROOK_DIR="${REPO_ROOT}/deployments/cubestack-addon/rook"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if [[ "$3" != *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 不应包含 [$2]"; fail=1; fi; }

sed -n '/^_ceph_yaml_file() {/,/^}$/p' "${CSI_MOD}" > "${TMP}/yaml.sh"
[ -s "${TMP}/yaml.sh" ] || { echo "  FAIL 无法抽取 _ceph_yaml_file"; exit 1; }

render() {  # render <replicas> <min> <fd> <safe> <mds> <std> <rgw> <files...>
    local r="$1" m="$2" fd="$3" safe="$4" mds="$5" std="$6" rgw="$7"; shift 7
    ( set +u
      err() { echo "ERR $*" >&2; }
      CEPH_ROOK_MANIFEST_DIR="${ROOK_DIR}" CEPH_NAMESPACE=rook-ceph
      CEPH_POOL_REPLICAS="${r}" CEPH_POOL_MIN_SIZE="${m}"
      CEPH_EFF_FAILURE_DOMAIN="${fd}" CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE="${safe}"
      CEPH_EFF_MDS_ACTIVE_COUNT="${mds}" CEPH_EFF_MDS_ACTIVE_STANDBY="${std}"
      CEPH_EFF_RGW_INSTANCES="${rgw}"
      _CEPH_SL_KEY=ceph-storage _CEPH_SL_VAL=rook-ceph
      . "${TMP}/yaml.sh"
      _ceph_yaml_file "$@" )
}

echo "== ① 单节点 RBD pool =="
out="$(render 1 1 osd false 1 false 1 rbd/01-cephblockpool-rbd-pool.yaml)"
chk_contains "failureDomain osd" "failureDomain: osd" "${out}"
chk_contains "requireSafe false" "requireSafeReplicaSize: false" "${out}"
chk_contains "size 1" "size: 1" "${out}"

echo "== ② 单节点 CephFS =="
out="$(render 1 1 osd false 1 false 1 cephfs/01-cephfilesystem.yaml)"
chk_contains "activeCount 1" "activeCount: 1" "${out}"
chk_contains "activeStandby false" "activeStandby: false" "${out}"
chk_contains "failureDomain osd" "failureDomain: osd" "${out}"

echo "== ③ 单节点 RGW =="
out="$(render 1 1 osd false 1 false 1 rgw/01-cephobjectstore-s3-store.yaml)"
chk_contains "instances 1" "instances: 1" "${out}"
chk_contains "failureDomain osd" "failureDomain: osd" "${out}"

echo "== ④ 多节点保持原参数 =="
out="$(render 3 2 host true 2 true 2 rbd/01-cephblockpool-rbd-pool.yaml cephfs/01-cephfilesystem.yaml rgw/01-cephobjectstore-s3-store.yaml)"
chk_contains "failureDomain host" "failureDomain: host" "${out}"
chk_contains "requireSafe true" "requireSafeReplicaSize: true" "${out}"
chk_contains "activeCount 2" "activeCount: 2" "${out}"
chk_contains "activeStandby true" "activeStandby: true" "${out}"
chk_contains "instances 2" "instances: 2" "${out}"

echo "== ⑤ SC 名称/默认标记不变 =="
sc="$(cat "${ROOK_DIR}/rbd/02-storageclass-rbd.yaml" "${ROOK_DIR}/rbd/03-storageclass-ceph-block-alias.yaml")"
chk_contains "ceph-rbd-ephemeral" "name: ceph-rbd-ephemeral" "${sc}"
chk_contains "默认 SC 标记" "storageclass.kubernetes.io/is-default-class" "${sc}"
chk_contains "ceph-block" "name: ceph-block" "${sc}"

echo "== ⑥ 无未替换占位符 =="
chk_not_contains "无双下划线占位" "__REPLICAS__" "${out}"
chk_not_contains "无故障域占位" "__FAILURE_DOMAIN__" "${out}"
chk_not_contains "无 MDS 占位" "__MDS_ACTIVE_COUNT__" "${out}"
chk_not_contains "无 RGW 占位" "__RGW_INSTANCES__" "${out}"

echo "== ⑦ 单节点外部池使用 osd 故障域 CRUSH 规则 =="
EXPOSE="${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-expose-external.sh"
chk_contains "按 EFF 故障域选择规则" 'CEPH_EFF_FAILURE_DOMAIN:-host}" = "osd"' "$(cat "${EXPOSE}")"
chk_contains "创建 osd 规则" 'osd crush rule create-replicated "${_ext_rule}" default osd' "$(cat "${EXPOSE}")"
chk_contains "RBD 池创建带规则" 'osd pool create "${EXT_RBD_POOL}" "${EXT_RBD_PG}" replicated "${_ext_rule}"' "$(cat "${EXPOSE}")"
chk_contains "已有 FS 池纠正规则" 'osd pool set "${_fp_pool}" crush_rule "${_ext_rule}"' "$(cat "${EXPOSE}")"
chk_contains "host 模式创建 host 域规则" 'osd crush rule create-replicated "${_ext_rule}" default host' "$(cat "${EXPOSE}")"
chk_contains "已有 RBD 池切换规则" 'osd pool set "${EXT_RBD_POOL}" crush_rule "${_ext_rule}"' "$(cat "${EXPOSE}")"
chk_contains "独立 apply 补有效 profile" 'ceph_apply_effective_spec "${_expose_topo}"' "$(cat "${EXPOSE}")"

echo "== ⑧ 单节点默认池(.mgr)使用 osd 故障域规则 =="
CEPH_MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh"
chk_contains "按 EFF 故障域触发" 'CEPH_EFF_FAILURE_DOMAIN:-host}" = "osd"' "$(cat "${CEPH_MOD}")"
chk_contains "创建 cubestack-osd 规则" 'ceph osd crush rule create-replicated cubestack-osd default osd' "$(cat "${CEPH_MOD}")"
chk_contains "设置默认 CRUSH 规则" 'osd_pool_default_crush_rule' "$(cat "${CEPH_MOD}")"
chk_contains ".mgr 池纠正(按规则名)" 'ceph osd pool set .mgr crush_rule cubestack-osd' "$(cat "${CEPH_MOD}")"
chk_contains ".mgr size 跟随有效副本数" 'osd pool set .mgr size "${CEPH_POOL_REPLICAS}"' "$(cat "${CEPH_MOD}")"
chk_contains ".mgr min_size 跟随有效值" 'osd pool set .mgr min_size "${CEPH_POOL_MIN_SIZE}"' "$(cat "${CEPH_MOD}")"
chk_contains ".mgr 纠正失败返回非 0(等待循环可重试)" \
    'ceph osd pool set .mgr crush_rule cubestack-osd >/dev/null 2>&1 || return 1' "$(cat "${CEPH_MOD}")"

echo "== ⑨ verify_ceph 覆盖实际 SC 名与 host-network RGW =="
VERIFY="${REPO_ROOT}/deployments/scripts/modules/03_addon/27_verify_ceph.sh"
chk_contains "CephFS SC 回退列表" 'for _fsc in cephfs-ephemeral cephfs-durable cephfs' "$(cat "${VERIFY}")"
chk_contains "PVC 使用选中的 SC" 'storageClassName: ${SC_FS}' "$(cat "${VERIFY}")"
chk_contains "host-network RGW 端点" 'RGW host-network 端点' "$(cat "${VERIFY}")"

echo "== ⑩ 单节点 PG 上限(多池小集群 HEALTH_WARN 防回归) =="
chk_contains "单节点 PG 上限函数" 'mon_max_pg_per_osd' "$(cat "${CEPH_MOD}")"
chk_contains "可配置上限" 'CEPH_SINGLE_MAX_PG_PER_OSD' "$(cat "${CEPH_MOD}")"
chk_contains "默认值声明" 'CEPH_SINGLE_MAX_PG_PER_OSD="${CEPH_SINGLE_MAX_PG_PER_OSD:-500}"' \
    "$(cat "${REPO_ROOT}/deployments/config/cluster.defaults.conf")"

echo "== ⑪ mon_list 解析 Rook v1.21 无前缀 CM(a=IP) =="
sed -n '/^mon_list() {/,/^}$/p' "${EXPOSE}" > "${TMP}/mon_list.sh"
out="$( ( set +u
    SSH() { printf 'a=10.66.3.165:6789\n'; }
    K=kubectl CEPH_NAMESPACE=rook-ceph
    . "${TMP}/mon_list.sh"
    mon_list | tr -d ' '
) )"
chk_contains "单节点解析为 a" "a" "${out}"
chk_not_contains "不误回退 a b c" "b" "${out}"
chk_contains "status host-network 直连判定" 'host-network 直连' "$(cat "${EXPOSE}")"

echo "== ⑫ 磁盘探测 stdout 纯净(防预检误回退) =="
DETECT="${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-detect-disks.sh"
chk_contains "load_config 输出走 stderr" '{ load_config; } >&2' "$(cat "${DETECT}")"
chk_contains "预检只解析本节点机器行" 'grep -E "^${_hn}:"' "$(cat "${REPO_ROOT}/deployments/scripts/lib-common.sh")"

echo "== ⑬ .mgr 池纠正行为: 成功置 size/min_size, 失败/超时返回非 0, ENOENT 才跳过 =="
sed -n '/_ceph_ensure_osd_crush_default() {/,/^    }$/p' "${CEPH_MOD}" > "${TMP}/mgr.sh"
[ -s "${TMP}/mgr.sh" ] || { echo "  FAIL 无法抽取 _ceph_ensure_osd_crush_default"; fail=1; }
# 成功路径(不注入失败点): 断言 size/min_size 调用与 size=1 确认参数
out="$( ( set +u
    warn() { :; }
    K=kubectl CEPH_NAMESPACE=rook-ceph CEPH_POOL_REPLICAS=1 CEPH_POOL_MIN_SIZE=1
    _calls=""
    SSH() { _calls="${_calls}$*"$'\n'; case "$*" in
        *'crush rule ls'*)  echo cubestack-osd ;;
        *'crush rule dump'*) echo '{"rule_id":5}' ;;
        *) return 0 ;;
      esac; }
    . "${TMP}/mgr.sh"
    _ceph_ensure_osd_crush_default; echo "rc=$?"
    printf '%s' "${_calls}" ) )"
chk_contains "成功 rc=0" "rc=0" "${out}"
chk_contains ".mgr 设 size 且 size=1 带确认参数" 'osd pool set .mgr size 1 --yes-i-really-mean-it' "${out}"
chk_contains ".mgr 设 min_size" 'osd pool set .mgr min_size 1' "${out}"
# 失败路径: .mgr crush_rule 设置失败 → 返回非 0, 让等待循环下一轮重试
out="$( ( set +u
    warn() { :; }
    K=kubectl CEPH_NAMESPACE=rook-ceph CEPH_POOL_REPLICAS=1 CEPH_POOL_MIN_SIZE=1
    SSH() { case "$*" in
        *'crush rule ls'*)  echo cubestack-osd ;;
        *'crush rule dump'*) echo '{"rule_id":5}' ;;
        *'pool set .mgr crush_rule'*) return 1 ;;
        *) return 0 ;;
      esac; }
    . "${TMP}/mgr.sh"
    _ceph_ensure_osd_crush_default; echo "rc=$?" ) )"
chk_contains ".mgr 规则失败 → rc=1" "rc=1" "${out}"
# CodeRabbit 2026-11-28: 查询超时(124)/exec 失败不能被当成"池不存在"跳过纠正并 rc=0
out="$( ( set +u
    warn() { :; }
    K=kubectl CEPH_NAMESPACE=rook-ceph CEPH_POOL_REPLICAS=1 CEPH_POOL_MIN_SIZE=1
    _calls=""
    SSH() { _calls="${_calls}$*"$'\n'; case "$*" in
        *'crush rule ls'*)  echo cubestack-osd ;;
        *'crush rule dump'*) echo '{"rule_id":5}' ;;
        *'pool get .mgr size'*) echo 'Error: command timed out' >&2; return 124 ;;
        *) return 0 ;;
      esac; }
    . "${TMP}/mgr.sh"
    _ceph_ensure_osd_crush_default; echo "rc=$?"
    printf '%s' "${_calls}" ) )"
chk_contains "查询超时 → rc=1(等待循环重试)" "rc=1" "${out}"
chk_not_contains "查询超时 → 不跳过纠正" "pool set .mgr" "${out}"
# 池确实不存在(ENOENT) → 跳过纠正并 rc=0
out="$( ( set +u
    warn() { :; }
    K=kubectl CEPH_NAMESPACE=rook-ceph CEPH_POOL_REPLICAS=1 CEPH_POOL_MIN_SIZE=1
    _calls=""
    SSH() { _calls="${_calls}$*"$'\n'; case "$*" in
        *'crush rule ls'*)  echo cubestack-osd ;;
        *'crush rule dump'*) echo '{"rule_id":5}' ;;
        *'pool get .mgr size'*) echo "Error ENOENT: unrecognized pool '.mgr'" >&2; return 2 ;;
        *) return 0 ;;
      esac; }
    . "${TMP}/mgr.sh"
    _ceph_ensure_osd_crush_default; echo "rc=$?"
    printf '%s' "${_calls}" ) )"
chk_contains "池不存在(ENOENT) → rc=0" "rc=0" "${out}"
chk_not_contains "池不存在 → 跳过纠正" "pool set .mgr" "${out}"

echo "== ⑭ 自动副本对齐: 显式 size=1 + 自动 min_size 不得继承大于 size 的运行值 =="
# CodeRabbit 2026-11-28: 显式 CEPH_POOL_REPLICAS=1 重跑在仍沿用 3/2 默认的集群上时,
# 旧实现把运行值 min_size=2 抄进 EFF → min_size > size 校验中止, 合法 1/1 profile 失败。
sed -n '/★ 2026-11-27 自动副本参数对齐/,/unset _csi_host_count _csi_topo/p' "${CSI_MOD}" > "${TMP}/csi-align.sh"
[ -s "${TMP}/csi-align.sh" ] || { echo "  FAIL 无法抽取 csi 自动副本对齐块"; fail=1; }
run_align() {   # <explicit_rep> <pool_rep> <explicit_min> <pool_min> <eff_rep> <eff_min> <run_size> <run_min>
    ( set +u
      say() { :; }; warn() { :; }; err() { echo "ERR $*" >&2; }
      ceph_auto_pool_profile() { return 1; }
      _ar_rs="$7" _ar_rm="$8"
      SSH() { case "$*" in
          *osd_pool_default_size*)    echo "${_ar_rs}" ;;
          *osd_pool_default_min_size*) echo "${_ar_rm}" ;;
          *) return 0 ;;
        esac; }
      K=kubectl CEPH_NAMESPACE=rook-ceph
      CEPH_EXPLICIT_REPLICAS="$1" CEPH_POOL_REPLICAS="$2"
      CEPH_EXPLICIT_MIN_SIZE="$3" CEPH_POOL_MIN_SIZE="$4"
      CEPH_EFF_POOL_REPLICAS="$5" CEPH_EFF_POOL_MIN_SIZE="$6"
      CEPH_EFF_FAILURE_DOMAIN=osd CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE=false
      _csi_topo=single _csi_host_count=1
      . "${TMP}/csi-align.sh"
      echo "after ${CEPH_POOL_REPLICAS}/${CEPH_POOL_MIN_SIZE}" ) 2>/dev/null
}
out="$(run_align 1 1 0 2 1 1 3 2)"
chk_contains "显式 size=1 + 运行 3/2 → 1/1(不中止)" "after 1/1" "${out}"
out="$(run_align 0 3 0 2 1 1 3 2)"
chk_contains "全自动仍镜像运行值 → 3/2" "after 3/2" "${out}"
out="$(run_align 1 1 1 1 1 1 3 2)"
chk_contains "显式 min_size 不被覆盖 → 1/1" "after 1/1" "${out}"
# 子进程 ceph-expose-external.sh: 整段自动副本对齐(读运行值 → 合并 → 成对校验 → 导出)
sed -n '/自动副本参数对齐(standalone apply)/,/^fi$/p' "${EXPOSE}" > "${TMP}/expose-align.sh"
[ -s "${TMP}/expose-align.sh" ] || { echo "  FAIL 无法抽取 expose 自动副本对齐块"; fail=1; }
run_expose() {   # <run_size|""> <run_min|""> <explicit_rep> <explicit_min> <eff_rep> <eff_min>
    ( set +u
      say() { :; }; warn() { :; }; err() { echo "ERR $*" >&2; }
      _xr_size="$1" _xr_min="$2"
      SSH() { case "$*" in
          *'get cephcluster rook-ceph'*) return 0 ;;
          *osd_pool_default_size*)       [ -n "${_xr_size}" ] && echo "${_xr_size}" || return 1 ;;
          *osd_pool_default_min_size*)   [ -n "${_xr_min}" ] && echo "${_xr_min}" || return 1 ;;
          *) return 0 ;;
        esac; }
      K=kubectl CEPH_NAMESPACE=rook-ceph CEPH_MODE=internal
      CEPH_EXPLICIT_REPLICAS="$3" CEPH_EXPLICIT_MIN_SIZE="$4"
      CEPH_EFF_POOL_REPLICAS="$5" CEPH_EFF_POOL_MIN_SIZE="$6"
      . "${TMP}/expose-align.sh"
      echo "after ${CEPH_EFF_POOL_REPLICAS}/${CEPH_EFF_POOL_MIN_SIZE}" ) 2>/dev/null
}
chk_contains "expose: 显式 size=1 + 运行 min=2 → 1/1" "after 1/1" "$(run_expose 3 2 1 0 1 1)"
chk_contains "expose: 全自动镜像运行 3/2" "after 3/2" "$(run_expose 3 2 0 0 1 1)"
chk_contains "expose: 显式 min 不被覆盖 → 1/1" "after 1/1" "$(run_expose 3 2 1 1 1 1)"
# CodeRabbit 2026-11-28(三次): size 读到 1 而 min 查询失败时, 旧 EFF min=2 会留下 1/2;
# 合并后必须校验成对有效性(非显式 min 按最终 size 派生; 显式冲突拒绝)。
chk_contains "expose: size 读到 1 / min 失败 → 修正 1/1" "after 1/1" "$(run_expose 1 "" 0 0 3 2)"
chk_not_contains "expose: 显式 min 与运行 size 冲突 → 拒绝" "after" "$(run_expose 1 "" 0 1 1 2)"
# CodeRabbit 2026-11-28(二次): 两个查询可独立失败 —— 回退只补"读取失败且未显式"的项,
# 已成功读取的值必须保留(size 读到 2/min 失败时不能按 3 OSD 改成 3)。
run_align_partial() {   # <fail_size> <fail_min> <run_size> <run_min> <osd_n>
    ( set +u
      say() { :; }; warn() { :; }; err() { echo "ERR $*" >&2; }
      _ap_fs="$1" _ap_fm="$2" _ap_rs="$3" _ap_rm="$4" _ap_osd="$5"
      SSH() { case "$*" in
          *osd_pool_default_size*)     [ "${_ap_fs}" = "1" ] && return 1; echo "${_ap_rs}" ;;
          *osd_pool_default_min_size*) [ "${_ap_fm}" = "1" ] && return 1; echo "${_ap_rm}" ;;
          *'ceph osd ls'*)             seq 1 "${_ap_osd}" ;;
          *) return 0 ;;
        esac; }
      K=kubectl CEPH_NAMESPACE=rook-ceph
      CEPH_EXPLICIT_REPLICAS=0 CEPH_POOL_REPLICAS=3
      CEPH_EXPLICIT_MIN_SIZE=0 CEPH_POOL_MIN_SIZE=2
      CEPH_EFF_POOL_REPLICAS=1 CEPH_EFF_POOL_MIN_SIZE=1
      CEPH_EFF_FAILURE_DOMAIN=osd CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE=false
      _csi_topo=single _csi_host_count=1
      . "${TMP}/csi-align.sh"
      echo "after ${CEPH_POOL_REPLICAS}/${CEPH_POOL_MIN_SIZE}" ) 2>/dev/null
}
out="$(run_align_partial 0 1 2 0 3)"
chk_contains "size 读到 2 / min 失败 → 保留 2, min 按 size 回退 1" "after 2/1" "${out}"
out="$(run_align_partial 1 0 0 1 3)"
chk_contains "size 失败 / min 读到 1 → 回填 3, 保留 min 1" "after 3/1" "${out}"
out="$(run_align_partial 1 1 0 0 3)"
chk_contains "两个都失败 → 按 3 OSD 回退 3/2" "after 3/2" "${out}"

exit "${fail}"
