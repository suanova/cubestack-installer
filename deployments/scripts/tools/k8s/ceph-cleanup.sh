#!/bin/bash
# ============================================================
# TOOL: ceph-cleanup
# DESC: 幂等卸载 Ceph + 清理"被判为 Ceph 占用"的磁盘(标准 Ceph 卸载流程: 优雅移除 OSD → 物理擦除 → 软件残留清理)
# 背景/参考:
#   · 标准流程: ① ceph osd out/purge(集群可达) ② 停止进程 + 解除 LVM/dm-mapper + wipefs/sgdisk/dd
#     ③ 清理 /var/lib/ceph /etc/ceph 等 ④ 重装。本工具自动化上述, 幂等可重复执行。
#   · Rook 场景: 删除 CephCluster(cleanupPolicy yes-really-destroy-data)由 Rook 擦盘;
#     若 Rook/operator 已不在(k8s 重装中)→ 直接跳到物理擦除(第二阶段)。
#   · 为什么清盘要用官方 zap(2026-09-24 修正): 旧版认为"ceph 工具宿主机上没有 → 只能自己 dd",
#     而手写 dd 的偏移(头/尾/size÷20/size÷2)与 Ceph v20 实际的 label 副本位置
#     (**10/100/1000GiB**, 见 ceph-bluestore-tool show-label 的 locations)对不上 →
#     副本残留 → 新集群 0 OSD。现改为: 用节点 containerd 里**预加载的 ceph 镜像**经 ctr 跑
#     `ceph-bluestore-tool zap-device`(读 label 自带 locations, 版本无关) + 候选偏移 dd 兜底
#     + 逐处校验, 实现见 lib-common.sh 的 bluestore_wipe_remote_lib(模块 02_ceph.sh 复用同一份)。
#     停止进程 → lvremove/vgremove → dmsetup remove → 这套编排仍在 wipe_node 里保留。
# ★ 选盘只依据 tools/k8s/ceph-disk-classify.py 的分类(强证据), 挂载中/非 ceph 文件系统/
#   非 ceph 的 LVM/系统盘一律不碰; 混合盘(同盘既有 Ceph 物证又有别的数据)只报告不自动清。
#   旧版 --all 只挑"空闲裸盘", 结果上次 Ceph 占用的分区/LVM 盘一块都不清(清理空转, 重装时
#   那几台节点还显示"未检测到可用裸盘")—— 本版按分类清, 正是修这个。
# 支持场景:
#   · 场景① 重装 K8s+Ceph: k8s 重装时 rook ns 已清 → --all 直接按分类清盘即可;
#   · 场景② 只重装 Ceph(K8s 保留): --all 先删 CephCluster(operator 擦盘)再逐节点清盘。
# 用法(部署机/容器内, 需 SSH 密钥): 见 --help
# 数据源: cluster.conf (NODES / CEPH_NODES / CEPH_NODE_ROLE / CEPH_NAMESPACE / SSH_USER /
#                       CEPH_DETECT_EXCLUDE)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
init_remote_kubectl || { err "init_remote_kubectl 失败(cluster.conf NODES 无 master?)"; exit 1; }

# ★ 2026-10-27 #73: ssh 默认会读取并转发**本地 stdin**。在 while-read(here-string/管道)
#   循环里, 循环体内第一条 ssh 会把剩余行一次性读空 → 循环只处理第一条。
#   ⚠ 把 `</dev/null` 写在 SSH 的**引号内**只是"远端命令的重定向", 对本地 ssh 完全无效
#   (2026-10-19 PVC 删除只删第一个、2026-10-27 依赖 CR 强删漏掉 CephFilesystem 都是这个坑:
#   残留依赖让 Rook 拒绝删除 CephCluster, 空等 900s+)。循环内/无需 stdin 的远端调用统一用
#   SSH_N(本地 stdin 恒为 /dev/null); 需要喂 stdin 的(printf | SSH patch)保持原样。
SSH_N() { SSH "$@" </dev/null; }

CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
# 强制清理语义(2026-10-20 CodeRabbit): `--wait=false` 只表示"发起删除、不陪等 finalizer",
#   **不表示 CSI unmap 已完成**。发起强制删除后再有界复查; 仍残留则返回非零, 默认拒绝继续
#   删 rbd nodeplugin / CephCluster(防 2026-09-05 的"unmap 前删插件"内核映射残留事故)。
#   CEPH_CLEANUP_FORCE_RECHECK_SECONDS: 强制删除后的复查窗口(默认 30s)
#   CEPH_CLEANUP_CLUSTER_FORCE_GONE_SECONDS: 强制删 CephCluster 后的复查窗口(默认 60s)
#   CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP=1 : 危险, 卷未确认清理时仍继续(nodeplugin/CephCluster/擦盘)
CEPH_CLEANUP_FORCE_RECHECK_SECONDS="${CEPH_CLEANUP_FORCE_RECHECK_SECONDS:-30}"
CEPH_CLEANUP_CLUSTER_FORCE_GONE_SECONDS="${CEPH_CLEANUP_CLUSTER_FORCE_GONE_SECONDS:-60}"
CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP="${CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP:-0}"
_CEPH_UNSAFE_UNMAP=0   # 1 = 卷未确认清理且未显式放行; cleanup_all 据此中止后续擦盘
_CEPH_ABORT_WIPE=0     # 1 = 关键查询失败/集群状态无法确认; cleanup_all 不得继续擦盘

# ---------------- 工具: 节点 SSH ----------------
node_cmd() {   # <ip> <user> <cmd...>
    local ip="$1" user="$2"; shift 2
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        "${user}@${ip}" "$@"
}

# ---------------- 卷清单 / 等待清理(2026-10-19 实机根因加固) ----------------
# 背景: 旧版删 PVC 的 `SSH ... | python3 ... | while read` 里 SSH 未重定向 stdin,
#   **第一次 ssh 就吞掉管道里其余 PVC 行** → 只删掉第一个 PVC。实机表现为
#   monitoring/storage-perses-0 残留 Bound + PV 存活, Rook 反复报
#   "waiting for csi volume attachments ... to be cleaned up", CephCluster 永远 Deleting。
#   下面统一: ①先收集动作再读 here-string；②所有循环内 SSH 用 SSH_N(本地 stdin=/dev/null, 见文首)；
#   ③删完 PVC 后等待 PVC/PV 真正消失(CSI unmap 完成)再删 nodeplugin / CephCluster。
#   ④强制清理(--wait=false)只发起删除、不陪等 finalizer; 之后有界复查 PVC/PV + ceph CSI
#     VolumeAttachment(attachment 状态才是 unmap 的可靠信号), 仍残留则返回非零,
#     默认拒绝删 nodeplugin/CephCluster(CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP=1 可显式放行)。
_list_ceph_pvcs() {   # <include_registry:0|1> → 每行 ns/name(仅 Bound/Lost 且 SC 含 ceph; Lost=PV 已被强删, 仍可能残留映射)
    local _inc="${1:-0}"
    SSH_N "${K} get pvc -A -o json 2>/dev/null" | INCLUDE_REGISTRY="${_inc}" python3 -c '
import json, os, sys
inc = os.environ.get("INCLUDE_REGISTRY", "0") == "1"
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(d, dict) or "items" not in d:
    sys.exit(2)
for p in d.get("items", []):
    sc = ((p.get("spec") or {}).get("storageClassName") or "")
    if "ceph" not in sc:
        continue
    if (p.get("status") or {}).get("phase") not in ("Bound", "Lost"):
        continue
    ns = p["metadata"]["namespace"]; name = p["metadata"]["name"]
    if not inc and ns == "kube-system" and name == "registry-pvc":
        continue
    print("%s/%s" % (ns, name))
'
}

_list_ceph_pvs() {   # <include_registry:0|1> → 每行 PV 名(仅 ceph CSI provisioned)
    local _inc="${1:-0}"
    SSH_N "${K} get pv -o json 2>/dev/null" | INCLUDE_REGISTRY="${_inc}" python3 -c '
import json, os, sys
inc = os.environ.get("INCLUDE_REGISTRY", "0") == "1"
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(d, dict) or "items" not in d:
    sys.exit(2)
for pv in d.get("items", []):
    spec = pv.get("spec") or {}
    driver = ((spec.get("csi") or {}).get("driver") or "")
    sc = (spec.get("storageClassName") or "")
    if "ceph" not in driver and "ceph" not in sc:
        continue
    claim = spec.get("claimRef") or {}
    if not inc and claim.get("namespace") == "kube-system" and claim.get("name") == "registry-pvc":
        continue
    print(pv["metadata"]["name"])
'
}

# ceph CSI VolumeAttachment(CodeRabbit 2026-10-20): PV/PVC 对象存在性**不能**证明 unmap——
#   强清 PV finalizer 会让 PV 立即消失、PVC 变 Lost; 而 attachment 仍在 = 节点侧仍可能持有
#   内核 rbd 映射。删 nodeplugin / CephCluster 前必须等 ceph CSI attacher 的 VA 全部消失。
#   注意: 不做 include_registry 过滤 —— 删 nodeplugin/集群前所有 ceph 卷都必须 detach。
_list_ceph_volumeattachments() {
    SSH_N "${K} get volumeattachment -o json 2>/dev/null" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(d, dict) or "items" not in d:
    sys.exit(2)
for va in d.get("items", []):
    att = ((va.get("spec") or {}).get("attacher") or "")
    if "ceph" not in att:
        continue
    print(va["metadata"]["name"])
'
}

wait_ceph_volumes_gone() {   # <timeout_seconds> <include_registry:0|1>
    local _to="${1:-120}" _inc="${2:-0}" _i _left_pvc _left_pv _left_va _rt _rtries
    _left_pvc=""; _left_pv=""; _left_va=""
    for _i in $(seq 1 $(( _to / 5 ))); do
        # ★ 2026-10-20 CodeRabbit: 查询失败不能当成"资源已消失" —— 三个查询都成功且输出为空才算完成。
        if _left_pvc="$(_list_ceph_pvcs "${_inc}")" \
            && _left_pv="$(_list_ceph_pvs "${_inc}")" \
            && _left_va="$(_list_ceph_volumeattachments)" \
            && [ -z "${_left_pvc}" ] && [ -z "${_left_pv}" ] && [ -z "${_left_va}" ]; then
            ok "  ceph PVC/PV/VolumeAttachment 已清理(CSI detach/unmap 完成)"
            return 0
        fi
        [ $((_i % 6)) -eq 0 ] && say "    等待 ceph 卷清理... $((_i * 5))s(PVC: $(printf '%s' "${_left_pvc}" | tr '\n' ' '), PV: $(printf '%s' "${_left_pv}" | tr '\n' ' '), VA: $(printf '%s' "${_left_va}" | tr '\n' ' '))"
        sleep 5
    done
    warn "  ceph 卷 ${_to}s 未清理干净: PVC=[$(printf '%s' "${_left_pvc}" | tr '\n' ' ')] PV=[$(printf '%s' "${_left_pv}" | tr '\n' ' ')] VA=[$(printf '%s' "${_left_va}" | tr '\n' ' ')] → 强制清理(数据随 Ceph 销毁)"
    # 兜底: 再删一次 PVC; 仍残留的 ceph PV 清 finalizer 后强删(只碰 ceph CSI PV,
    #   provisioner 卡死时这是唯一让 Rook 继续删除的路径; 新部署会重建卷)。
    # ★ 2026-10-20 实机: `kubectl delete` 默认**等待对象消失**; PVC 的 pvc-protection /
    #   PV 的 external-provisioner+ pv-protection finalizer 在 provisioner 卡住时不会自行
    #   清除 → delete 无限阻塞(实测卡 7.5min+, 直到模块 1800s timeout)。强制清理必须
    #   `--wait=false` + 外层 timeout, 只发起删除、不陪等 finalizer。
    while IFS= read -r _p; do
        [ -n "${_p}" ] || continue
        SSH_N "timeout 30 ${K} -n ${_p%/*} delete pvc ${_p#*/} --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1" || true
    done <<< "${_left_pvc}"
    while IFS= read -r _pv; do
        [ -n "${_pv}" ] || continue
        printf '%s' '{"metadata":{"finalizers":null}}' \
            | SSH "timeout 30 ${K} patch pv ${_pv} --type=merge --patch-file=/dev/stdin >/dev/null 2>&1" || true
        SSH_N "timeout 30 ${K} delete pv ${_pv} --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1" || true
    done <<< "${_left_pv}"
    # ★ 2026-10-20 CodeRabbit: --wait=false 只表示"不陪等 finalizer", **不等于 unmap 完成**。
    #   发起强制删除后再有界复查; 仍残留 → 返回 1, 由调用方决定是否显式放行继续。
    #   (旧实现无条件 return 0 → stop_consumers 会接着删 rbd nodeplugin, 可能失去 unmap 执行者。)
    _rt="${CEPH_CLEANUP_FORCE_RECHECK_SECONDS:-30}"
    case "${_rt}" in ''|*[!0-9]*) _rt=30 ;; esac
    _rtries=$(( _rt / 5 )); [ "${_rtries}" -ge 1 ] || _rtries=1
    for _i in $(seq 1 "${_rtries}"); do
        # 同样: 只有三项查询都成功且为空, 才算强删后 unmap 完成。
        if _left_pvc="$(_list_ceph_pvcs "${_inc}")" \
            && _left_pv="$(_list_ceph_pvs "${_inc}")" \
            && _left_va="$(_list_ceph_volumeattachments)" \
            && [ -z "${_left_pvc}" ] && [ -z "${_left_pv}" ] && [ -z "${_left_va}" ]; then
            ok "  强制清理后 ceph PVC/PV/VolumeAttachment 已消失(CSI detach/unmap 完成)"
            return 0
        fi
        sleep 5
    done
    warn "  ⚠ 强制清理后仍有残留: PVC=[$(printf '%s' "${_left_pvc}" | tr '\n' ' ')] PV=[$(printf '%s' "${_left_pv}" | tr '\n' ' ')] VA=[$(printf '%s' "${_left_va}" | tr '\n' ' ')]"
    warn "    未确认 CSI unmap 完成(默认拒绝继续删 nodeplugin/CephCluster; 可用 CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP=1 显式放行)"
    return 1
}

# ---------------- ⓪① ② 停消费者 + 触发 unmap(可独立调用; --delete-cluster 的先导步) ----------------
# 目的(2026-10-10 用户口径): ① 消灭在飞 IO(防写死死设备/内核毒化) ② 让 CSI 自然
# NodeUnpublish→Unstage(节点内核 rbd unmap) ③ 防"删了 PVC/集群, 控制器又重建 Pod"的竞态。
# 只停**消费者**; 默认并删 Bound 的 ceph PVC(触发 unmap, 不删 registry-pvc); --keep-pvcs 保留模式仅停消费者(集群保留时无需 unmap, 应用卷数据不受影响)。
stop_consumers() {
    say "  ⓪ 停用持有 ceph 卷的工作负载(消灭在飞 IO; PVC 对象保留)..."
    _RBD_OP_NS="${CUBESTACK_OPERATOR_NAMESPACE:-cubestack-system}"
    _RBD_OP_REL="${CUBESTACK_OPERATOR_RELEASE:-cubestack-operator}"
    # ★ 2026-10-13: scale 0 前登记原副本数(注解; 仅首次, 重复停机不覆盖) —— 02_ceph.sh 7.9
    #   只恢复带注解的对象(CodeRabbit 评审: 旧实现"存在即 replicas=1"会把手动扩容静默压回 1,
    #   且停机前副本数非 1 时恢复丢原值)。
    #   ⚠ registry 是 kubespray 建的**裸 ReplicaSet**(非 Deployment; 2026-10-13 实机验证)——
    #   旧代码 `scale deploy registry` 从未命中, 实际停机全靠下方扫荡的 delrs(整删 RS, 不可恢复);
    #   现改为 scale rs(对象保留), 由 7.9 标记驱动恢复。
    stop_mark_replicas deploy "${_RBD_OP_NS}" "${_RBD_OP_REL}"
    stop_mark_replicas rs kube-system registry
    SSH "${K} -n ${_RBD_OP_NS} scale deploy ${_RBD_OP_REL} --replicas=0 >/dev/null 2>&1" || true
    SSH "${K} -n kube-system scale rs registry --replicas=0 >/dev/null 2>&1" || true
    _vj="$(mktemp)"; _pj="$(mktemp)"; _rj="$(mktemp)"; _sj="$(mktemp)"
    _sweep_done=0
    for _wi in $(seq 1 12); do
        SSH_N "${K} get pvc -A -o json 2>/dev/null" > "${_vj}" || true
        SSH_N "${K} get pods -A -o json 2>/dev/null" > "${_pj}" || true
        SSH_N "${K} get rs -A -o json 2>/dev/null" > "${_rj}" || true
        SSH_N "${K} get sts -A -o json 2>/dev/null" > "${_sj}" || true
        _acts="$(python3 - "${_vj}" "${_pj}" "${_rj}" "${_sj}" <<'PYEOF'
import json, sys
def load(p):
    try:
        return json.load(open(p))
    except Exception:
        return {"items": []}
ceph = set()
for p in load(sys.argv[1]).get("items", []):
    sc = ((p.get("spec") or {}).get("storageClassName") or "")
    if "ceph" in sc and (p.get("status") or {}).get("phase") == "Bound":
        ceph.add((p["metadata"]["namespace"], p["metadata"]["name"]))
if not ceph:
    sys.exit(0)
rs = {(r["metadata"]["namespace"], r["metadata"]["name"]): r for r in load(sys.argv[3]).get("items", [])}
sts = {(s["metadata"]["namespace"], s["metadata"]["name"]): s for s in load(sys.argv[4]).get("items", [])}
for pod in load(sys.argv[2]).get("items", []):
    md = pod["metadata"]; ns = md["namespace"]; name = md["name"]
    if (pod.get("status") or {}).get("phase") in ("Succeeded", "Failed"):
        continue
    hit = False
    for v in ((pod.get("spec") or {}).get("volumes") or []):
        cn = (v.get("persistentVolumeClaim") or {}).get("claimName")
        if cn and (ns, cn) in ceph:
            hit = True; break
    if not hit:
        continue
    refs = md.get("ownerReferences") or []
    if not refs:
        print("delpod\t%s\t%s\t" % (ns, name)); continue
    k = refs[0]["kind"]; n = refs[0]["name"]
    if k == "ReplicaSet":
        _rsob = rs.get((ns, n), {})
        rr = (_rsob.get("metadata", {}).get("ownerReferences") or [])
        if rr:
            print("scale\t%s\t%s\t%s" % (ns, rr[0]["kind"], rr[0]["name"]))
        elif ((_rsob.get("spec") or {}).get("replicas", 1) == 0):
            # ★ 2026-10-13: 裸 RS 已 scale 0(如本函数刚优雅停机的 registry RS, pod 尚在
            #   优雅终结) → 保留本体。0 副本不会再重建 Pod(删本体的目的仅在于此), 而
            #   02_ceph.sh 7.9 的标记驱动恢复需要对象活着 —— 误删后 --steps ceph 路径
            #   下 registry 再也拉不回来(这曾是真实现状: deploy 空转 + 扫荡 delrs 整删)。
            pass
        else:
            # 无主的裸 RS(pod 由它直接管) → 删 RS 本体(只删 Pod 会被它重建)
            print("delrs\t%s\t%s\t" % (ns, n))
    elif k == "StatefulSet":
        sr = (sts.get((ns, n), {}).get("metadata", {}).get("ownerReferences") or [])
        if sr and sr[0]["kind"] not in ("Deployment", "StatefulSet", "ReplicaSet"):
            print("delcr\t%s\t%s\t%s" % (ns, sr[0]["kind"].lower(), sr[0]["name"]))
        else:
            print("scale\t%s\t%s\t%s" % (ns, k, n))
    elif k == "Deployment":
        print("scale\t%s\t%s\t%s" % (ns, k, n))
    elif k in ("DaemonSet", "Job", "ReplicationController"):
        print("delpod\t%s\t%s\t" % (ns, name))
    else:
        # 自定义 CR 直管 Pod(实测: CNPG 的 pod owner 就是 Cluster CR) → 删 CR 本体,
        # 由其 operator 级联收掉组件(只删 Pod 会被 operator 重建)
        print("delcr\t%s\t%s\t%s" % (ns, k.lower(), n))
PYEOF
)"
        [ -z "${_acts}" ] && { _sweep_done=1; break; }
        # ⚠ 循环内每个 SSH 都必须走 SSH_N(本地 stdin=/dev/null): ssh 默认读 stdin, 会吞掉 here-string 里
        #   其余动作(2026-10-19 实机同类 bug: PVC 删除循环只执行了第一条)。
        while IFS=$'\t' read -r _act _a1 _a2 _a3; do
            [ -n "${_act}" ] || continue
            case "${_act}" in
                scale)  say "     停用 ${_a1}/${_a2} ${_a3}(replicas=0)"; SSH_N "${K} -n ${_a1} scale ${_a2,,} ${_a3} --replicas=0 >/dev/null 2>&1" || true ;;
                delpod) say "     删除 Pod ${_a1}/${_a2}(优雅退出, ≤20s)"; SSH_N "timeout 30 ${K} -n ${_a1} delete pod ${_a2} --grace-period=20 --wait=false >/dev/null 2>&1" || true ;;
                delrs)  say "     删除裸 ReplicaSet ${_a1}/${_a2}(无 Deployment 管理, 删 Pod 会被其重建)"; SSH_N "${K} -n ${_a1} delete rs ${_a2} --wait=false >/dev/null 2>&1" || true ;;
                delcr)  say "     删除 CR ${_a2}/${_a3}(级联收掉其组件)"; SSH_N "${K} -n ${_a1} delete ${_a2} ${_a3} --wait=false >/dev/null 2>&1" || true ;;
            esac
        done <<< "${_acts}"
        sleep 10
    done
    if [ "${_sweep_done}" = "1" ]; then
        ok "  消费者已全部停用(无 Pod 再引用 ceph PVC)"
    else
        _left_pods="$(python3 - "${_vj}" "${_pj}" <<'PYEOF' 2>/dev/null || true
import json, sys
def load(p):
    try:
        return json.load(open(p))
    except Exception:
        return {"items": []}
ceph = set()
for p in load(sys.argv[1]).get("items", []):
    sc = ((p.get("spec") or {}).get("storageClassName") or "")
    if "ceph" in sc and (p.get("status") or {}).get("phase") == "Bound":
        ceph.add((p["metadata"]["namespace"], p["metadata"]["name"]))
out = []
for pod in load(sys.argv[2]).get("items", []):
    md = pod["metadata"]; ns = md["namespace"]
    for v in ((pod.get("spec") or {}).get("volumes") or []):
        cn = (v.get("persistentVolumeClaim") or {}).get("claimName")
        if cn and (ns, cn) in ceph:
            out.append("%s/%s" % (ns, md["name"])); break
print(" ".join(out[:8]))
PYEOF
)"
        warn "  仍有 Pod 引用 ceph PVC(120s 未收敛): ${_left_pods:-?} —— 继续(k8s 重置/资源删除会终结它们)"
    fi
    rm -f "${_vj}" "${_pj}" "${_rj}" "${_sj}"

    # ★ 2026-09-05 事故预防: 删除集群前先清 ceph-block PVC 并删 rbd nodeplugin DaemonSet。
    #   若直接删 CephCluster, nodeplugin 随之被删 → 节点上内核 rbd 映射无人 unmap →
    #   [rbd0-tasks] 内核线程持锁残留 → sysfs remove 被拒(EACCES) → libceph cephx -13
    #   刷屏, 只能重启节点。正确顺序: 先让 CSI 正常 unmap 卷, 再删集群。
    if [ "${KEEP_PVCS}" != "1" ]; then
        say "  ① 删除使用 ceph-block 的 PVC(触发 CSI unmap)..."
        # ★ 2026-09-24 修复: 只删 **Bound** 的 ceph PVC, 且永不删 kube-system/registry-pvc。
        #   本步目的是"删掉有后端卷的 PVC, 逼 CSI 先 unmap"; 而**没有后端卷的 PVC(Pending)删掉
        #   只是丢声明, 一个卷也 unmap 不到** —— registry-pvc 恰是这一种: 它由 kubespray 在 k8s
        #   阶段创建(roles/kubernetes-apps/registry), 之后没有任何 addon 模块会重建它。
        #   删了它 → 模块 05_k8s_registry 一直等 "registry-pvc Bound"(等一个不存在的对象)
        #   → 600s 超时 → 整轮部署在 ceph 修好之后**又**挂在 registry 上。
        #   已 Bound 的 registry-pvc 同样保护: 删了 registry 就失去存储声明(镜像数据本就随
        #   OSD 清盘没了, 要重建 registry 请人工删声明 + 重跑 k8s 阶段)。
        # ★ 2026-10-19 实机根因: 原实现 `SSH ... | python3 ... | while read` 中 SSH 未重定向
        #   stdin, 第一条 delete 就吞掉管道里其余 PVC 行 → 只删掉第一个 PVC。实机残留
        #   monitoring/storage-perses-0(Bound + PV 存活), Rook 一直
        #   "waiting for csi volume attachments ... to be cleaned up" 拒删 CephCluster。
        #   现在先收集动作再读 here-string, SSH 全部走 SSH_N(本地 stdin=/dev/null), 并在删完后等待 PVC/PV 消失
        #   (证明 CSI unmap 完成)再进入删 nodeplugin / CephCluster。
        _pvc_actions="$(SSH_N "${K} get pvc -A -o json 2>/dev/null" | python3 -c '
import sys, json
PROTECT = {("kube-system", "registry-pvc")}      # kubespray 建的 registry 声明: 删了不会自愈
try:
    d = json.load(sys.stdin)
    for pvc in d.get("items", []):
        sc = pvc.get("spec", {}).get("storageClassName", "")
        if "ceph" not in sc:
            continue
        ns, name = pvc["metadata"]["namespace"], pvc["metadata"]["name"]
        if (ns, name) in PROTECT:
            print("KEEP %s/%s (registry 存储声明, 受保护)" % (ns, name))
            continue
        if pvc.get("status", {}).get("phase") != "Bound":
            print("KEEP %s/%s (未 Bound, 无后端卷可 unmap)" % (ns, name))
            continue
        print("DEL %s/%s" % (ns, name))
except Exception:
    pass
')"
        while IFS= read -r _act _pvc _why; do
            [ -n "${_pvc:-}" ] || continue
            case "${_act}" in
                DEL)  say "     删除 PVC ${_pvc}(数据将销毁)..."
                      SSH_N "${K} -n ${_pvc%/*} delete pvc ${_pvc#*/} --wait=false >/dev/null 2>&1" || true ;;
                KEEP) say "     保留 PVC ${_pvc} ${_why:-}" ;;
            esac
        done <<< "${_pvc_actions}"
        unset _pvc_actions
        if ! wait_ceph_volumes_gone 120 0; then
            if [ "${CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP}" = "1" ]; then
                warn "  卷清理未确认完成, 但 CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP=1 → 继续删除 rbd nodeplugin"
                warn "  ⚠ 风险: 仍被挂载的卷可能失去 unmap 执行者(内核 rbd 映射/锁残留, 可能需重启节点)"
            else
                _CEPH_UNSAFE_UNMAP=1
                err "  拒绝删除 rbd csi nodeplugin: ceph PVC/PV 仍在(未确认 CSI unmap 完成)"
                err "  先排查 PVC/PV finalizer / CSI 插件状态; 确认可接受风险后显式重跑:"
                err "    CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP=1 $0 --${ACTION:-stop-consumers}"
                return 1
            fi
        fi
        say "  ② 删除 rbd csi nodeplugin DaemonSet(各节点执行内核 rbd unmap)..."
        SSH_N "${K} -n ${CEPH_NAMESPACE} delete ds rook-ceph.rbd.csi.ceph.com-nodeplugin --wait=false >/dev/null 2>&1" || true
        sleep 5
    else
        say "  保留模式(--keep-pvcs): 跳过 Bound PVC 删除与 nodeplugin 删除(集群保留, 无需 unmap; 应用卷数据不受影响)"
    fi
}

# ---------------- ① 删除现有 CephCluster(Rook 擦盘) ----------------
delete_cluster() {
    # ★ 2026-10-26: external CephCluster 是"外部 Ceph 接入声明", 不是本安装器资产。
    #   覆盖安装时若把它当 internal 旧集群删除, 会删掉 external CR/依赖 CR, 甚至触发
    #   Rook cleanupPolicy 擦盘流程。默认拒绝; 仅显式 CEPH_CLEANUP_ALLOW_EXTERNAL=1 放行。
    local _ext_rows _ext_cc _ext_err
    # ★ 2026-10-26 CodeRabbit: 分类查询失败 ≠ "没有 external" —— 必须 fail-closed。
    #   旧写法 `... 2>/dev/null || true` 会把 SSH/API 故障吞成空结果; 后续存在性查询一旦成功,
    #   就会在"未确认是否 external"的情况下继续删消费者/PVC/CR(可能破坏外部 Ceph 接入)。
    #   CRD 不存在(全新集群)仍视为"无 CephCluster" —— 与下方存在性查询同一口径。
    if ! _ext_rows="$(SSH "${K}" -n "${CEPH_NAMESPACE}" get cephcluster \
            -o custom-columns=NAME:.metadata.name,EXT:.spec.external.enable --no-headers 2>/dev/null)"; then
        _ext_err="$(SSH "${K}" -n "${CEPH_NAMESPACE}" get cephcluster \
            -o custom-columns=NAME:.metadata.name,EXT:.spec.external.enable --no-headers 2>&1 >/dev/null || true)"
        case "${_ext_err}" in
            *"doesn't have a resource type"*|*"could not find the requested resource"*) _ext_rows="" ;;
            *) _CEPH_ABORT_WIPE=1
               err "查询 CephCluster external 标记失败(无法确认是否 external): ${_ext_err:-<无 stderr>}"
               return 1 ;;
        esac
    fi
    _ext_cc="$(printf '%s\n' "${_ext_rows}" | awk '$2=="true"{print $1}' | tr '\n' ' ')"
    if [ -n "${_ext_cc}" ]; then
        err "检测到 external CephCluster(${_ext_cc}) —— 外部 Ceph 不是本安装器资产, 拒绝销毁"
        err "  如确认要清理集群内 internal Ceph, 请先手工处理 external CR;"
        err "  或显式 CEPH_CLEANUP_ALLOW_EXTERNAL=1 重跑(危险: 可能破坏外部 Ceph 接入)"
        if [ "${CEPH_CLEANUP_ALLOW_EXTERNAL:-0}" != "1" ]; then
            # ★ cleanup_all 只看 _CEPH_ABORT_WIPE/_CEPH_UNSAFE_UNMAP, **不看 delete_cluster 返回码**;
            #   不置位的话 --all 在"拒绝销毁"后仍会继续 wipe_ceph_disks_all_nodes —— 外部 Ceph
            #   若使用这些节点上的盘, 数据会被抹掉(2026-10-26 CodeRabbit Critical)。
            _CEPH_ABORT_WIPE=1
            return 1
        fi
        warn "CEPH_CLEANUP_ALLOW_EXTERNAL=1 → 继续销毁(风险自负)"
    fi
    say "删除现有 CephCluster(cleanupPolicy yes-really-destroy-data, Rook 擦盘)..."
    # 幂等: 无集群直接成功。
    # ★ 2026-10-20 CodeRabbit: 查询失败不能当成"无集群"(否则 cleanup_all 会跳过删除直接擦盘)。
    #   CRD 不存在(报 "doesn't have a resource type")= 确实没有集群, 可跳过; 其它错误必须失败。
    _exists=""
    if ! _exists="$(SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --ignore-not-found -o name 2>/dev/null")"; then
        _exist_err="$(SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --ignore-not-found -o name 2>&1 >/dev/null || true")"
        case "${_exist_err}" in
            *"doesn't have a resource type"*|*"could not find the requested resource"*) : ;;
            *) _CEPH_ABORT_WIPE=1; err "查询 CephCluster 失败(无法确认是否存在): ${_exist_err:0:200}"; return 1 ;;
        esac
    fi
    [ -z "${_exists}" ] && { ok "  无现有 CephCluster, 跳过"; return 0; }

    if ! stop_consumers; then
        err "  停止消费者/卷清理未完成 → 中止删除 CephCluster(防 unmap 前删集群/nodeplugin)"
        return 1
    fi
    # ★ 2026-10-19: 破坏性删除 Ceph 前必须删掉受保护的 registry PVC —— 否则 rbd-pool
    #   里的 registry 镜像让 CephBlockPool 永远 "contains images or snapshots",
    #   CephCluster 会一直卡 Deleting(Rook operator 日志实锤)。registry 数据本就随
    #   Ceph 销毁, 新部署会重建 registry 并重新灌镜像。
    say "  删除受保护的 registry PVC(破坏性删除 Ceph 前必须, 否则 rbd-pool 非空)..."
    SSH "${K} -n kube-system delete pvc registry-pvc --ignore-not-found --wait=false >/dev/null 2>&1" || true
    for _i in $(seq 1 24); do
        _pvc_left="$( (SSH_N "${K} -n kube-system get pvc registry-pvc --no-headers 2>/dev/null") || true )"
        [ -z "${_pvc_left}" ] && break
        sleep 5
    done
    unset _pvc_left
    # registry PVC 删掉后，其 PV 也要消失(CSI DeleteVolume)才允许删 CephBlockPool；
    # 同时兜住任何其它残留的 ceph PVC/PV(例如上一轮 stop_consumers 漏删的)。
    if ! wait_ceph_volumes_gone 120 1; then
        if [ "${CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP}" = "1" ]; then
            warn "  卷清理未确认完成, 但 CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP=1 → 继续删除 CephCluster"
            warn "  ⚠ 风险: 仍有 ceph 卷映射, 强删 CephCluster 可能导致内核 rbd 映射/锁残留"
        else
            _CEPH_UNSAFE_UNMAP=1
            err "  拒绝删除 CephCluster: ceph PVC/PV 仍在(未确认 CSI unmap 完成)"
            err "  确认可接受风险后显式重跑: CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP=1 $0 --${ACTION:-delete-cluster}"
            return 1
        fi
    fi
    # ★ 2026-10-19: registry PVC 未 Bound 时 CSI 可能已创建半成品 RBD 镜像; 只删 PVC 不会
    #   清掉它 → CephBlockPool "contains images" 永远删不掉。这里显式 purge rbd-pool。
    say "  清空 rbd-pool 残留/半成品 RBD 镜像(防 CephBlockPool 非空)..."
    SSH "timeout 60 ${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- timeout 30 sh -c 'for i in \$(rbd ls -p rbd-pool 2>/dev/null); do rbd snap purge rbd-pool/\$i >/dev/null 2>&1 || true; rbd rm rbd-pool/\$i >/dev/null 2>&1 || true; done'" >/dev/null 2>&1 || true
    SSH "${K} -n ${CEPH_NAMESPACE} patch cephcluster rook-ceph --type merge \
        -p '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}' >/dev/null 2>&1" || true
    # ★ 2026-10-19: 依赖 CR 必须先删, 否则 Rook 拒绝删父资源:
    #   CephFilesystemSubVolumeGroup(durable/ephemeral) → CephFilesystem
    #   CephObjectStoreUser(rgw-model-admin/reader)     → CephObjectStore
    #   CephBlockPool(rbd-pool, 依赖 registry PVC 已删)
    _DEP_CRS="cephfilesystemsubvolumegroup cephobjectstoreuser cephfilesystem cephobjectstore cephblockpool cephnfs cephrbdmirror"
    say "  删除 Ceph 依赖 CR(SubVolumeGroup/ObjectStoreUser → FS/ObjectStore/BlockPool)..."
    for _cr in ${_DEP_CRS}; do
        SSH_N "${K} -n ${CEPH_NAMESPACE} delete ${_cr} --all --wait=false >/dev/null 2>&1" || true
    done
    unset _cr
    # ★ 2026-10-19 实机: Ceph 不可达 / 0 OSD 时, 依赖 CR 的 finalizer 需要执行 ceph 命令,
    #   会永久卡 Terminating; Rook 因此拒绝删除 CephCluster(op 日志实锤:
    #   "will not be deleted until all dependents are removed: CephBlockPool/CephFilesystem…")。
    #   等待 120s, 仍在 → 清 finalizer 强删(数据本就随 Ceph 销毁; 只为让重建拿到干净命名空间)。
    say "  等待 Ceph 依赖 CR 终结(上限 120s)..."
    _deps_left=""
    _deps_query_failed=0
    for _i in $(seq 1 24); do
        # ★ 查询失败 ≠ "已终结": 只有查询成功且输出为空才算干净(失败按残留处理, 走强删/后置校验)。
        if _deps_left="$(SSH_N "${K} -n ${CEPH_NAMESPACE} get ${_DEP_CRS// /,} --no-headers 2>/dev/null")"; then
            [ -z "${_deps_left}" ] && break
        else
            _deps_query_failed=1
            _deps_left="<查询失败: 无法确认依赖 CR 是否终结>"
        fi
        sleep 5
    done
    if [ -n "${_deps_left}" ]; then
        if [ "${_deps_query_failed}" = "1" ]; then
            warn "  依赖 CR 终结状态无法确认(查询失败) → 按残留处理: 清 finalizer 强删..."
        else
            warn "  依赖 CR 未在 120s 内终结(Ceph 不可达时 finalizer 卡死) → 清 finalizer 强删..."
        fi
        # ★ 2026-10-27 #73: 强删循环里的 SSH 必须用 SSH_N(本地 stdin=/dev/null) —— 旧写法把
        #   `</dev/null` 写在引号内(只是远端重定向), 本地 ssh 仍会读空 here-string, 循环只处理
        #   第一条(实机: cephfilesystem 有 cubestack-ext-fs/durable 两条只删了前者,
        #   cephfilesystemsubvolumegroup 的 ephemeral 同样被漏掉) → 残留依赖让 Rook 拒绝删除
        #   CephCluster, 空等 900s+。另外强删后必须**后置校验**: 仍有残留则重试(最多 3 轮),
        #   仍不收敛直接报错中止, 绝不带着残留进入"删 CephCluster + 900s 等待"。
        _dep_clean=0
        _dep_try=1
        while [ "${_dep_try}" -le 3 ]; do
            for _cr in ${_DEP_CRS}; do
                _objs="$( (SSH_N "${K} -n ${CEPH_NAMESPACE} get ${_cr} -o name 2>/dev/null") || true )"
                [ -n "${_objs}" ] || continue
                while IFS= read -r _obj; do
                    [ -n "${_obj}" ] || continue
                    say "    强制删除 ${_obj}(第 ${_dep_try}/3 轮)"
                    printf '%s' '{"metadata":{"finalizers":null}}' \
                        | SSH "timeout 30 ${K} -n ${CEPH_NAMESPACE} patch ${_obj} --type=merge --patch-file=/dev/stdin >/dev/null 2>&1" || true
                    SSH_N "timeout 30 ${K} -n ${CEPH_NAMESPACE} delete ${_obj} --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1" || true
                done <<< "${_objs}"
            done
            unset _objs _obj _cr
            # 后置校验: 只有查询成功且输出为空才算强删完成; 查询失败同样视为未确认。
            if _deps_left="$(SSH_N "${K} -n ${CEPH_NAMESPACE} get ${_DEP_CRS// /,} --no-headers 2>/dev/null")"; then
                [ -z "${_deps_left}" ] && { _dep_clean=1; break; }
            else
                _deps_left="<查询失败: 无法确认依赖 CR 是否终结>"
            fi
            if [ "${_dep_try}" -lt 3 ]; then
                warn "  依赖 CR 仍有残留, 5s 后重试(第 $((_dep_try + 1))/3 轮): $(printf '%s' "${_deps_left}" | tr '\n' ' ')"
                sleep 5
            fi
            _dep_try=$((_dep_try + 1))
        done
        if [ "${_dep_clean}" != "1" ]; then
            _CEPH_ABORT_WIPE=1
            err "  依赖 CR 强删 3 轮后仍有残留 → 中止删除 CephCluster(否则 Rook 拒绝并空等 900s):"
            err "    $(printf '%s' "${_deps_left}" | tr '\n' ' ')"
            err "  排查: kubectl -n ${CEPH_NAMESPACE} get ${_DEP_CRS// /,} -o yaml(看 finalizer/ownerReferences)"
            return 1
        fi
        ok "  依赖 CR 已全部强删"
    else
        ok "  依赖 CR 已全部终结"
    fi
    unset _deps_left _deps_query_failed _dep_clean _dep_try _DEP_CRS
    SSH "${K} -n ${CEPH_NAMESPACE} delete cephcluster rook-ceph --wait=false >/dev/null 2>&1" || true
    _gone=0
    _cluster_query_failed=0
    # 2026-10-19: Rook 擦 9 块 OSD 盘 + MDS/RGW 收尾可能 >5min; 等待上界 900s, 每 60s
    # 打一行 phase, 避免长时间静默被误判为卡死。
    for _i in $(seq 1 180); do
        # ★ 2026-10-20 CodeRabbit: 查询失败 ≠ 对象已消失; 只有查询成功且空输出才是 NotFound。
        if _still="$(SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --ignore-not-found -o name 2>/dev/null")"; then
            [ -z "${_still}" ] && { _gone=1; break; }
        else
            _cluster_query_failed=1
        fi
        if [ $((_i % 12)) -eq 0 ]; then
            _ph="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null") || true )"
            say "    等待 CephCluster 删除... $((_i * 5))s(phase=${_ph:-unknown})"
        fi
        sleep 5
    done
    if [ "${_gone}" = "1" ]; then
        ok "  CephCluster 已删除(Rook 已擦盘)"
        return 0
    fi
    warn "  CephCluster 删除超时(900s) → 重启 rook operator 再等 300s..."
    SSH "${K} -n "${CEPH_NAMESPACE}" rollout restart deploy/rook-ceph-operator >/dev/null 2>&1" || true
    for _i in $(seq 1 60); do
        # ★ 2026-10-20 CodeRabbit: 查询失败 ≠ 对象已消失; 只有查询成功且空输出才是 NotFound。
        if _still="$(SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --ignore-not-found -o name 2>/dev/null")"; then
            [ -z "${_still}" ] && { _gone=1; break; }
        else
            _cluster_query_failed=1
        fi
        sleep 5
    done
    if [ "${_gone}" = "1" ]; then
        ok "  CephCluster 已删除(Rook 已擦盘)"
        return 0
    fi
    # ★ 2026-10-19 实机兜底: 依赖 CR 已全删但 operator 只反复打印 "no dependent ... deleting",
    #   CephCluster 仍卡 Deleting(Rook finalizer 死锁)。清 finalizer 强制移除对象, 并删旧
    #   Rook 守护工作负载; 磁盘由后续 wipe_node 物理擦除, 新 Ceph 由 02_ceph 重建。
    warn "  operator 重启后仍 Deleting → 清 finalizer + 强制删除 CephCluster(物理擦盘兜底)"
    printf '%s' '{"metadata":{"finalizers":null}}' \
        | SSH "timeout 30 ${K} -n ${CEPH_NAMESPACE} patch cephcluster rook-ceph --type=merge --patch-file=/dev/stdin >/dev/null 2>&1" || true
    SSH_N "timeout 30 ${K} -n ${CEPH_NAMESPACE} delete cephcluster rook-ceph --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1" || true
    for _lbl in "app=rook-ceph-osd" "app=rook-ceph-mds" "app=rook-ceph-rgw" "app=rook-ceph-mon" "app=rook-ceph-mgr"; do
        SSH_N "timeout 30 ${K} -n ${CEPH_NAMESPACE} delete deploy -l ${_lbl} --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1" || true
    done
    SSH_N "timeout 30 ${K} -n ${CEPH_NAMESPACE} delete jobs -l app=rook-ceph-osd-prepare --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1" || true
    unset _lbl
    # ★ 2026-10-20 CodeRabbit: --wait=false 只表示"不陪等 finalizer", 必须复查对象真的消失;
    #   否则 finalizer patch 失败/残留时会谎报"已强制移除"(旧 CR 会让下次安装撞上)。
    _force_gone=0
    _force_wait="${CEPH_CLEANUP_CLUSTER_FORCE_GONE_SECONDS:-60}"
    case "${_force_wait}" in ''|*[!0-9]*) _force_wait=60 ;; esac
    _force_tries=$(( _force_wait / 5 )); [ "${_force_tries}" -ge 1 ] || _force_tries=1
    for _i in $(seq 1 "${_force_tries}"); do
        # ★ 2026-10-20 CodeRabbit: 查询失败 ≠ 已删除; 只有查询成功且空输出才是 NotFound。
        if _still="$(SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph --ignore-not-found -o name 2>/dev/null")"; then
            [ -z "${_still}" ] && { _force_gone=1; break; }
        else
            _cluster_query_failed=1
        fi
        sleep 5
    done
    if [ "${_force_gone}" = "1" ]; then
        ok "  CephCluster 已强制移除(后续物理擦盘/重建兜底)"
        return 0
    fi
    if [ "${_cluster_query_failed:-0}" = "1" ]; then
        _CEPH_ABORT_WIPE=1
        err "  CephCluster 删除结果无法确认(查询失败; 未确认移除)"
    else
        err "  CephCluster 强制删除后仍存在(未确认移除; 下次安装可能遇到旧 CR)"
    fi
    err "    排查: kubectl -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o yaml(看 finalizer)"
    return 1
}

# ---------------- ② 清理单个节点磁盘(物理擦除, 幂等) ----------------
wipe_node() {   # <ip> <disks: "/dev/vdb,/dev/vdc"> [user]
    local ip="$1" disks="$2" user="${3:-${SSH_USER:-ubuntu}}"
    [ -n "${disks}" ] || { warn "  ${ip}: 无盘列表, 跳过"; return 1; }
    say "  清理 ${ip} 磁盘到原始状态(LVM/dm-mapper/签名/分区表/bluestore 标签)..."
    local script
    script="$(cat <<'WIPESCRIPT'
set -e
# 1) 停止可能占用磁盘的 ceph 残留进程
pkill -f "ceph-osd" 2>/dev/null || true
pkill -f "ceph-mon" 2>/dev/null || true
pkill -f "ceph-mgr" 2>/dev/null || true
pkill -f "ceph-volume" 2>/dev/null || true
sleep 1
# 2) 解除 **目标盘上** 的 LVM —— 只动这些盘上的 PV 所属 VG。
#    ★ 不按名字正则扫全节点(`lvs | grep ceph` / `vgs | grep ceph|rbd`): 那会误伤
#      "名字里恰好带 ceph" 的无关卷(如 data-vg/cephbackup、手工建的 ceph-backup VG),
#      与"不覆盖其他使用方式的磁盘"直接冲突; 本脚本的 7a 让这段跑在**默认部署流程**里,
#      影响面比人工执行 --all 时大得多, 必须按盘收敛。
_TARGET_VGS=""
for dev in __DISKS__; do
    [ -b "$dev" ] || continue
    for pv in $(lsblk -nrpo NAME,TYPE "$dev" 2>/dev/null | awk '$2=="disk" || $2=="part" {print $1}'); do
        _vg="$(pvs --noheadings -o vg_name "$pv" 2>/dev/null | tr -d ' ')"
        [ -n "${_vg}" ] && _TARGET_VGS="${_TARGET_VGS} ${_vg}"
    done
done
for vg in $(printf '%s\n' ${_TARGET_VGS} | sort -u); do
    for lv in $(lvs --noheadings -o lv_path "$vg" 2>/dev/null | tr -d ' '); do
        lvremove -f "$lv" 2>/dev/null || true
    done
    vgremove -f "$vg" 2>/dev/null || true
done
# 3) 解除 device-mapper 映射: 只拆**目标盘之上**的 dm/crypt 层(这些盘已被判定为 Ceph 占用,
#    其上的 dm 随盘一起清掉)。**不用 `dmsetup remove_all`** —— 那会拆掉本节点**所有** dm 映射
#    (未打开的业务 LV、多路径、dm-crypt 都会被映断; 数据虽不毁, 但超出"只清这些盘"的范围)。
for dev in __DISKS__; do
    [ -b "$dev" ] || continue
    for dm in $(lsblk -n -o NAME,TYPE "$dev" 2>/dev/null | awk '$2=="dm" || $2=="crypt" {print $1}'); do
        dmsetup remove -f "$dm" 2>/dev/null || true
    done
done
# 4) 擦除磁盘签名 + 分区表 + bluestore 标签(**全部 label 副本**, 见 lib-common.sh 的
#    bluestore_wipe_remote_lib)。★ 2026-09-24 事故修复: 旧版这里手写 dd 只擦
#    头/尾/size÷20/size÷2, 漏掉 Ceph v20 在 **10/100/1000GiB** 的 label 副本
#    → `ceph-volume raw list` 仍认得出旧 OSD → Rook osd-prepare 判 "already prepared"
#    → 新集群 0 OSD。现在: 官方 zap-device(读 label 自带 locations) + 候选偏移 dd + 校验,
#    校验不过就非 0 退出, 不再假装成功。
_BSTORE_FAIL=0
for dev in __DISKS__; do
    [ -b "$dev" ] || continue
    if bluestore_wipe_dev "$dev"; then
        echo "   ${dev}: bluestore 已擦净(label 副本 + 头/分区表/尾)"
    else
        echo "    !! ${dev} 未通过 bluestore 擦除校验(残留偏移见上) —— 该盘作 OSD 会被 Rook 判 already prepared"
        _BSTORE_FAIL=1
    fi
done
# 5) 清理 Rook/Ceph 数据目录 + 残留 rbd 设备(+ 2026-10-10: ceph/rook udev 规则)
rm -rf /var/lib/rook /var/lib/ceph /etc/ceph /run/ceph 2>/dev/null || true
rm -f /dev/rbd* 2>/dev/null || true
rm -f /etc/udev/rules.d/*ceph* /etc/udev/rules.d/*rook* 2>/dev/null || true
udevadm control --reload-rules >/dev/null 2>&1 || true
udevadm settle 2>/dev/null || true
# 6) ★ 内核 rbd 映射残留: **完整阶梯**(2026-10-10 定稿; 对齐官方"unmap→模块卸载→才谈重启"):
#    a) 逐映射**后台** sysfs remove + 有界复核(惰性, 本进程永不阻塞; 成功会让 b 可行)
#    b) `modprobe -r rbd` + `modprobe -r libceph` —— **模块级卸载**, unmap 成功后它能把
#       客户端会话/内核态一次性清光(根治 -13 刷屏), 这是官方推荐的"比逐条 unmap 更彻底"的手段
#    c) 仍残留(sysfs 被拒 + rmmod EBUSY = 内核持锁, 物理所限) → 响亮告警 + **硬复位**指引
echo "--- 内核 rbd 映射清理(阶梯: sysfs → 模块卸载 → 告警)---"
RBD_N=0
for d in /sys/bus/rbd/devices/*; do
    [ -d "$d" ] || continue
    RBD_N=$((RBD_N+1))
    _rid="$(basename "$d")"; _rid="${_rid#rbd}"
    echo "残留 rbd 映射: $(cat $d/name 2>/dev/null) (pool=$(cat $d/pool 2>/dev/null), id=${_rid})"
    setsid bash -c "echo ${_rid} > /sys/bus/rbd/remove_single_major 2>/dev/null || echo ${_rid} > /sys/bus/rbd/remove 2>/dev/null" >/dev/null 2>&1 &
done
if [ "$RBD_N" -gt 0 ]; then
    for _wi in 1 2 3 4 5 6 7 8 9 10; do
        ls /sys/bus/rbd/devices/* >/dev/null 2>&1 || break
        sleep 1
    done
fi
modprobe -r rbd 2>/dev/null || true
modprobe -r libceph 2>/dev/null || true
RBD_N=0
for d in /sys/bus/rbd/devices/*; do
    [ -d "$d" ] || continue
    RBD_N=$((RBD_N+1))
done
if [ "$RBD_N" -gt 0 ]; then
    echo "!! 仍残留 ${RBD_N} 个内核 rbd 映射(sysfs remove 被拒时模块卸载也 EBUSY —— 内核持锁)"
    echo "!! 处置: **硬复位**该节点后重跑本清理(⚠ 优雅重启会卡在 sync; 用 sysrq-b / reboot -f / virsh reset)"
    echo "!! (残映射无碍新集群数据面, 仅致 libceph -13 日志刷屏; 可继续部署, 择机清零)"
    exit 9
fi
echo "--- 内核 rbd 映射已清空(阶梯完成)---"
echo "--- 验证目标盘 FSTYPE/挂载(应全空) ---"
for dev in __DISKS__; do
    [ -b "$dev" ] || continue
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$dev" 2>/dev/null | tail -1
done
echo "--- 验证完成(FSTYPE 列应全空; bluestore label 副本另由 bluestore_wipe_dev 逐处校验) ---"
# ★ bluestore label 没擦净 → 非 0 退出: 调用方必须看见, 否则盘会带着旧 OSD 身份进 CR,
#   新集群 OSD 数为 0(2026-09-24 事故的静默形态)。
[ "${_BSTORE_FAIL:-0}" = "1" ] && exit 1
exit 0
WIPESCRIPT
)"
    script="${script//__DISKS__/${disks//,/ }}"
    # ★ 节点端 bluestore 擦除函数(wipescript 里直接调用)由 lib-common 提供, 避免两处各写一份
    #   (另一处: 模块 03_addon/02_ceph.sh 的 7a-② 逐盘兜底)。
    { bluestore_wipe_remote_lib; printf '\n%s\n' "${script}"; } | node_cmd "${ip}" "${user}" "sudo bash -s" \
        && ok "  ${ip} 磁盘已恢复原始状态" \
        || { warn "  ${ip} 磁盘清理失败(见上方输出; 常见: 盘被占用 lsof /dev/sdX 找进程 kill 后重试)"; return 1; }
}

# ---------------- 磁盘分类(选盘唯一依据) ----------------
# 分类实现全在 tools/k8s/ceph-disk-classify.py(经 ceph-detect-disks.sh --classify 调用),
# 与部署模块/预检复用同一份判定 —— 避免"清理判一套、部署判另一套"导致清了不该清的盘
# 或者该清的盘没清(旧版 --all 只挑"空闲裸盘", 结果上次 Ceph 占用的分区/LVM 盘一个都不碰,
# 重装时那几台节点显示"未检测到可用裸盘", 清理等于空转)。
DETECT_SH="${SCRIPT_DIR}/tools/k8s/ceph-detect-disks.sh"

classify_all_hosts() {   # stdout = TSV: <host>\t<设备>\t<分类>\t<证据>
    local args=() _h
    while IFS= read -r _h; do
        [ -n "${_h}" ] && args+=(--node "${_h}")
    done < <(ceph_storage_hosts)
    bash "${DETECT_SH}" "${args[@]}" -m --classify
}

# TSV 里取某主机某分类的设备(逗号分隔)
_tsv_devices() {   # <tsv> <host> <分类...>
    local tsv="$1" host="$2"; shift 2
    local -a want=("$@") w out=""
    for w in "${want[@]}"; do
        out="${out}$(awk -F'\t' -v h="${host}" -v c="${w}" '$1==h && $3==c {printf "%s,", $2}' <<< "${tsv}")"
    done
    printf '%s' "${out%,}"
}

# 分类结果人工可读打印(红底强调"不碰"的盘, 避免用户以为清理没跑全)
print_classified() {   # <tsv>
    local tsv="$1" _h _d _c _e
    while IFS=$'\t' read -r _h _d _c _e; do
        [ -n "${_h}" ] || continue
        case "${_c}" in
            ceph)  echo -e "\033[36m  ♻  ${_h} ${_d} — 上次 Ceph 占用, 将清理: ${_e}\033[0m" ;;
            free)  echo -e "     ${_h} ${_d} — 空闲(无需清理)" ;;
            mixed) echo -e "\033[41m\033[97m  ⚠  ${_h} ${_d} — 混合盘, 不自动清理(需人工判断): ${_e}\033[0m" ;;
            *)     echo -e "     ${_h} ${_d} — 在用盘, 不触碰: ${_e}" ;;
        esac
    done <<< "${tsv}"
}

# 解析主机名 → IP/用户名到 _HOST_IP/_HOST_USER(NODES 里查)
_resolve_host() {   # <hostname>
    _HOST_IP=""; _HOST_USER="${SSH_USER:-ubuntu}"
    local _line
    for _line in "${NODES[@]:-}"; do
        [ -z "${_line}" ] && continue
        node_parse "${_line}"
        [ "${NODE_HOSTNAME}" = "$1" ] && { _HOST_IP="${NODE_IP}"; _HOST_USER="${NODE_USER}"; return 0; }
    done
    return 1
}

# IP → hostname(cleanup 按 IP 操作, 分类结果按 hostname 索引)
_hostname_of_ip() {   # <ip> → stdout=hostname(空=不在 NODES 里)
    local _line
    for _line in "${NODES[@]:-}"; do
        [ -z "${_line}" ] && continue
        node_parse "${_line}"
        [ "${NODE_IP}" = "$1" ] && { printf '%s' "${NODE_HOSTNAME}"; return 0; }
    done
    return 1
}

# ---------------- ③ 只列出清理计划, 不动任何盘 ----------------
list_plan() {
    say "扫描各存储节点磁盘(只读, 不会修改任何磁盘)..."
    local tsv
    tsv="$(classify_all_hosts)" || { err "磁盘分类失败(节点 SSH 不可达?)"; exit 1; }
    [ -n "${tsv}" ] || { err "未获得任何节点的磁盘分类(检查 NODES / SSH 可达性)"; exit 1; }
    print_classified "${tsv}"
    echo ""
    say "图例: ♻ = 会被 --all 清理(标准 Ceph 清除步骤); 空闲盘无需清理;"
    say "      在用盘(挂载中/非 ceph 文件系统/非 ceph LVM/系统盘)与混合盘一律不动"
    say "如需强制清理某块盘: $0 --wipe-node <ip> --disks \"/dev/xxx\" [--force]"
}

# ---------------- ④ 全流程: 删集群 + 清理判为 Ceph 占用的盘 ----------------
cleanup_all() {
    local _dc_rc=0 _wipe_rc=0
    delete_cluster || _dc_rc=$?
    if [ "${_CEPH_UNSAFE_UNMAP}" = "1" ] || [ "${_CEPH_ABORT_WIPE}" = "1" ]; then
        err "ceph 集群/卷状态未确认 → 中止后续清盘(避免在状态未知时擦盘)"
        return 1
    fi
    wipe_ceph_disks_all_nodes || _wipe_rc=$?
    if [ "${_dc_rc}" != "0" ]; then
        err "CephCluster 删除未确认完成(见上方日志; 下次安装可能遇到旧 CR); 物理擦盘已按兜底继续"
        return 1
    fi
    return "${_wipe_rc}"
}

# 分类各存储节点 → 只清被判为 Ceph 占用的盘(在用/混合盘一律不动)。
# 被 --all 与部署模块的覆盖安装路径(02_ceph.sh 7a)共用 —— 两处走同一份判定与同一套清除步骤。
wipe_ceph_disks_all_nodes() {
    say "分类各存储节点磁盘(只清被判为上次 Ceph 占用的盘; 在用/混合盘一律不动)..."
    local tsv
    tsv="$(classify_all_hosts)" || { err "磁盘分类失败(节点 SSH 不可达?)"; exit 1; }
    [ -n "${tsv}" ] || { err "未获得任何节点的磁盘分类(检查 NODES / SSH 可达性)"; exit 1; }
    print_classified "${tsv}"
    echo ""
    # 按节点聚合 -- 一台节点一次 SSH 跑一遍标准清除步骤(LVM/VG 解绑只需做一次), 多盘一起擦
    local _h _ip _user _disks _n _failed=0
    _n=0
    while IFS= read -r _h; do
        [ -n "${_h}" ] || continue
        _disks="$(_tsv_devices "${tsv}" "${_h}" ceph)"
        [ -n "${_disks}" ] || continue
        _resolve_host "${_h}" || { warn "  ${_h}: NODES 中找不到该节点, 跳过"; continue; }
        [ -n "${_HOST_IP}" ] || { warn "  ${_h}: 无 IP, 跳过"; continue; }
        _ip="${_HOST_IP}"; _user="${_HOST_USER}"
        say "  节点 ${_h}(${_ip}): 清理 ${_disks}"
        if wipe_node "${_ip}" "${_disks}" "${_user}"; then
            _n=$((_n + 1))
        else
            _failed=$((_failed + 1))
        fi
    done < <(ceph_storage_hosts)
    if [ "${_failed}" -gt 0 ]; then
        err "Ceph 磁盘清理失败: ${_failed} 个节点失败, ${_n} 个节点成功"
        return 1
    fi
    if [ "${_n}" -eq 0 ]; then
        warn "没有节点需要清理(未检出任何 Ceph 占用盘; 若确认有旧 OSD 盘, 见上方分类说明)"
    fi
    ok "Ceph 磁盘清理完成(可重新安装)"
}

# ---------------- ⑤ 显式清指定节点的指定盘(带分类护栏) ----------------
# 直接落实"不覆盖其他使用方式的磁盘": 擦盘前逐块查分类, 判为 inuse/mixed/未知的一律拒擦,
# 要用 --force 才越过(此时会先把证据打印出来, 让人看清楚自己越过了什么)。
wipe_node_guarded() {   # <ip> <disks>
    local ip="$1" disks="$2" hn tsv _d _cls _ev
    local allowed=() refused=() unknown=()

    hn="$(_hostname_of_ip "${ip}" || true)"
    if [ -z "${hn}" ]; then
        warn "  ${ip} 不在 cluster.conf NODES 里 → 无法分类, 需 --force 才擦"
        for _d in ${disks//,/ }; do unknown+=("/dev/${_d#/dev/}"); done
    else
        tsv="$(classify_all_hosts)" || { err "磁盘分类失败(SSH 不可达?)"; exit 1; }
        for _d in ${disks//,/ }; do
            _d="/dev/${_d#/dev/}"
            _cls="$(awk -F'\t' -v h="${hn}" -v dev="${_d}" '$1==h && $2==dev {print $3}' <<< "${tsv}")"
            _ev="$(awk -F'\t' -v h="${hn}" -v dev="${_d}" '$1==h && $2==dev {print $4}' <<< "${tsv}")"
            case "${_cls}" in
                ceph) allowed+=("${_d}");  say "  ♻  ${_d} — 上次 Ceph 占用, 允许清理(${_ev})" ;;
                free) allowed+=("${_d}");  say "  ✅ ${_d} — 空闲盘(清理无害)" ;;
                "")   unknown+=("${_d}");  warn "  ⚠  ${_d} — 未在 lsblk 中找到该设备(盘名写错/节点不可达?)" ;;
                *)    refused+=("${_d}");  warn "  ⛔ ${_d} — 判为 ${_cls}, 拒绝清理: ${_ev}" ;;
            esac
        done
    fi

    if [ "${#refused[@]}" -gt 0 ] || [ "${#unknown[@]}" -gt 0 ]; then
        echo ""
        warn "以下磁盘未被清理(分类显示它们不像是 Ceph 盘, 或无法确认):"
        local _r
        for _r in "${refused[@]:-}" "${unknown[@]:-}"; do [ -n "${_r}" ] && warn "    ${_r}"; done
        if [ "${FORCE}" = "1" ]; then
            warn "--force 已指定 → 连同上述磁盘一并清理"
            for _r in "${refused[@]:-}" "${unknown[@]:-}"; do [ -n "${_r}" ] && allowed+=("${_r}"); done
        else
            # fail-fast: 一块盘不放行就整批不动 —— 破坏性操作用"部分执行"会让现场更难判断
            warn "本次未清理任何磁盘。确认要销毁上述盘上数据请加 --force 重跑本命令"
            return 1
        fi
    fi

    [ "${#allowed[@]}" -gt 0 ] || { warn "  无可清理的磁盘"; return 1; }
    local _joined _user="${SSH_USER:-ubuntu}"
    _joined="$(IFS=,; printf '%s' "${allowed[*]}")"
    # 用户按 NODES 第4字段每节点不同时, 这里必须用该节点自己的用户(否则认证失败)
    if [ -n "${hn}" ] && _resolve_host "${hn}"; then
        _user="${_HOST_USER}"
    fi
    wipe_node "${ip}" "${_joined}" "${_user}"
}

# ---------------- main ----------------
ACTION=""
WIPE_IP=""
WIPE_DISKS=""
FORCE=0
KEEP_PVCS=0
usage() {
    cat <<'USAGE'
用法:
  ceph-cleanup.sh --list                               # 只列出清理计划(只读, 不动盘)
  ceph-cleanup.sh --delete-cluster                     # 仅删除 CephCluster CR(等 Rook 擦盘, 最长 300s)
  ceph-cleanup.sh --stop-consumers [--keep-pvcs]       # 只停消费者; --keep-pvcs=保留全部 PVC/nodeplugin(集群保留时用)
  ceph-cleanup.sh --wipe-disks                         # 只清理判为 Ceph 占用的盘(不删集群)
  ceph-cleanup.sh --all                                # 全流程: 删集群(若在) + 清理判为 Ceph 占用的盘
  ceph-cleanup.sh --wipe-node <ip> --disks "/dev/vdb,/dev/vdc" [--force]
                                                       # 显式清指定盘(默认拒绝清在用/混合盘)
说明: 判定"哪些盘是 Ceph 盘"由 ceph-disk-classify.py 统一给出(强证据: bluestore 签名 /
      ceph 分区 GUID 或分区名 / ceph-* LVM 卷); 挂载中、非 ceph 文件系统、非 ceph LVM、
      系统盘一律不碰。混合盘(同盘既有 Ceph 又有别的数据)只报告, 需人工处理。
环境变量:
  CEPH_CLEANUP_FORCE_RECHECK_SECONDS=30   # 强制删除后的复查窗口(秒); 仍残留则拒绝继续
  CEPH_CLEANUP_CLUSTER_FORCE_GONE_SECONDS=60  # 强制删 CephCluster 后的复查窗口(秒); 仍存在则失败
  CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP=1       # 危险: 卷未确认清理时仍继续删 nodeplugin/CephCluster/擦盘
USAGE
}
while [ $# -gt 0 ]; do
    case "$1" in
        --list)           ACTION=list; shift ;;
        --delete-cluster) ACTION=delete-cluster; shift ;;
        --stop-consumers) ACTION=stop-consumers; shift ;;
        --wipe-disks)     ACTION=wipe-disks; shift ;;
        --all)            ACTION=all; shift ;;
        --wipe-node)      ACTION=wipe-node; WIPE_IP="${2:-}"; shift 2 ;;
        --disks)          WIPE_DISKS="${2:-}"; shift 2 ;;
        --force)          FORCE=1; shift ;;
        --keep-pvcs)      KEEP_PVCS=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) err "未知参数: $1"; usage; exit 1 ;;
    esac
done

case "${ACTION}" in
    list)           list_plan ;;
    # ★ 删集群/全流程路径强制默认行为(KEEP_PVCS=0): 保留模式仅 --stop-consumers 有意义
    #   (集群保留时无需 unmap; 删集群路径必须先 unmap, 否则回到 09-05 事故路径)
    delete-cluster) KEEP_PVCS=0; delete_cluster ;;
    stop-consumers) stop_consumers ;;
    wipe-disks)     wipe_ceph_disks_all_nodes ;;
    all)            KEEP_PVCS=0; cleanup_all ;;
    wipe-node)
        [ -n "${WIPE_IP}" ] && [ -n "${WIPE_DISKS}" ] \
            || { err "用法: $0 --wipe-node <ip> --disks \"/dev/vdb,/dev/vdc\" [--force]"; exit 1; }
        wipe_node_guarded "${WIPE_IP}" "${WIPE_DISKS}" ;;
    *) usage; exit 1 ;;
esac
