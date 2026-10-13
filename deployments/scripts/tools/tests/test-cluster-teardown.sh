#!/bin/bash
# 桩式测试: 优雅覆盖链路 —— ① 登记合并(纯函数) ② 登记写回(假 SSH) ③ 引擎拆序/降级/离线 dry-run(Task 9 扩展)
#   ④ 引擎 --uninstall 离线 dry-run ⑤ 消费者停机↔恢复契约(注解标记驱动, 2026-10-13 CodeRabbit 修订)
#   ⑥ cubestack_operator 卸载 CR 终结门(源模块直跑 + 假 SSH/helm shim; 2026-10-13 CodeRabbit 修订)
#   ⑦ deploy-cluster 异常退出兜底接线(静态围栏; 2026-10-13 CodeRabbit 修订)
# 隔离手段(与 test-sync-api-entry.sh 同风格):
#   ① CLUSTER_CONF 指向临时配置(load_config 只读它, 不碰真 cluster.conf)
#   ② init_remote_kubectl 之后用假 SSH 覆盖(记录调用; get cm → $FAKE_CM; apply -f - → 存 $FAKE_APPLY)
#   ③ 引擎用 CUBESTACK_TEARDOWN_TEST_INVENTORY 夹具 JSON 走离线路径(不连任何集群)
#   ⑤ 假 deploy/rs 状态机(FAKE_DEPLOY_REPLICAS=对象存在+副本数; FAKE_DEPLOY_ANNO=登记注解)
#   ⑥ 假 csc/CRD 清单(FAKE_CSC_LIST/FAKE_CSC_NOW/FAKE_CRD_LIST) + PATH 裸 ssh 桩(sync_kubeconfig 下载失败 → helm 步确定性跳过)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
ENGINE="${REPO_ROOT}/deployments/scripts/tools/k8s/cluster-teardown.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
jget() { python3 -c "import json,sys;d=json.loads(sys.argv[1]);print($2)" "$1"; }

# 桩配置(最小 NODES; 其余 load_config 走默认)
cat > "${TMP}/cluster.conf" <<'EOF'
NODES=("master,m1,10.0.0.1,ubuntu,p" "master,m2,10.0.0.2,ubuntu,p" "worker,w1,10.0.0.11,ubuntu,w")
EOF

# libfn: source lib-common + load_config + init_remote_kubectl(先), 再覆盖假 SSH(后, 防被 init 覆盖);
#         stdin 原样透传给 eval 的表达式(可写 `printf ... | _record_merge_json key`)
libfn() {  # libfn <表达式>
    (
        export CLUSTER_CONF="${TMP}/cluster.conf"
        set +u
        source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
        load_config >/dev/null 2>&1
        init_remote_kubectl >/dev/null 2>&1 || true
        SSH() {
            printf '%s\n' "$*" >> "${FAKE_LOG:-/dev/null}" 2>/dev/null || true
            case "$*" in
                *"get cm"*) [ -n "${FAKE_CM:-}" ] && [ -f "${FAKE_CM}" ] && cat "${FAKE_CM}"; return 0 ;;
                *"apply -f -"*) [ -n "${FAKE_APPLY:-}" ] && cat > "${FAKE_APPLY}"; return 0 ;;
                # ⑤ 用: 假 deploy/rs 状态机 —— 副本数文件=对象存在; 注解文件=已登记标记
                *"get deploy "*|*"get rs "*)
                    if [ ! -f "${FAKE_DEPLOY_REPLICAS:-/nonexistent}" ]; then
                        return 1     # 模拟 NotFound(helper 侧已 2>/dev/null 吞错)
                    fi
                    case "$*" in
                        *".spec.replicas"*) cat "${FAKE_DEPLOY_REPLICAS}" ;;
                        *"index .metadata.annotations"*)
                            if [ -f "${FAKE_DEPLOY_ANNO:-/nonexistent}" ]; then cat "${FAKE_DEPLOY_ANNO}"; else echo "<no value>"; fi ;;
                    esac
                    return 0 ;;
                *"annotate "*"pre-stop-replicas-"*) rm -f "${FAKE_DEPLOY_ANNO:-/nonexistent}"; return 0 ;;
                *"annotate "*)
                    printf '%s' "$(printf '%s\n' "$*" | sed -E 's/.*pre-stop-replicas=([0-9]+).*/\1/')" > "${FAKE_DEPLOY_ANNO:-/dev/null}"
                    return 0 ;;
                # ⑥ 用: 假 csc/CRD 清单(文件内容; 文件缺失=空输出)
                *"get csc -o name"*) cat "${FAKE_CSC_LIST:-/nonexistent}" 2>/dev/null; return 0 ;;
                *"get csc --no-headers"*) cat "${FAKE_CSC_NOW:-/nonexistent}" 2>/dev/null; return 0 ;;
                *"get crd -o name"*) cat "${FAKE_CRD_LIST:-/nonexistent}" 2>/dev/null; return 0 ;;
            esac
            return 0
        }
        eval "$1"
    )
}

# ============================================================
echo "== ① 登记合并(纯函数 _record_merge_json) =="
J1="$(libfn 'printf "%s" "{\"schema\":1,\"components\":[]}" | _record_merge_json metallb')"
chk "① 新组件 seq=1" "1" "$(jget "${J1}" 'd["components"][0]["seq"]')"
chk "① key 正确" "metallb" "$(jget "${J1}" 'd["components"][0]["key"]')"
chk "① status=done" "done" "$(jget "${J1}" 'd["components"][0]["status"]')"

J2="$(printf '%s' "${J1}" | libfn '_record_merge_json ceph')"
chk "① 第二组件 seq=2" "2" "$(jget "${J2}" 'next(c["seq"] for c in d["components"] if c["key"]=="ceph")')"

J3="$(printf '%s' "${J2}" | libfn '_record_merge_json metallb')"
chk "① 重跑不改变首装序(metallb 仍 1)" "1" "$(jget "${J3}" 'next(c["seq"] for c in d["components"] if c["key"]=="metallb")')"
chk "① 重跑不追加重复条目" "2" "$(jget "${J3}" 'len(d["components"])')"

J4="$(printf '%s' 'not-json-at-all' | libfn '_record_merge_json netshoot')"
chk "① 坏 JSON 容错(重建空登记)" "1" "$(jget "${J4}" 'd["components"][0]["seq"]')"
chk "① 坏 JSON 容错 key" "netshoot" "$(jget "${J4}" 'd["components"][0]["key"]')"

echo "== ② 登记写回(record_installed_component + 假 SSH) =="
FAKE_APPLY="${TMP}/apply1.json" libfn 'record_installed_component github_registry' >/dev/null
chk "② apply 收到 ConfigMap" "ConfigMap" "$(jget "$(cat "${TMP}/apply1.json")" 'd["kind"]')"
chk "② CM 名" "cubestack-install-record" "$(jget "$(cat "${TMP}/apply1.json")" 'd["metadata"]["name"]')"
chk "② CM ns" "kube-system" "$(jget "$(cat "${TMP}/apply1.json")" 'd["metadata"]["namespace"]')"
chk "② record.json 内含组件" "github_registry" \
    "$(jget "$(cat "${TMP}/apply1.json")" 'json.loads(d["data"]["record.json"])["components"][0]["key"]')"

# 已有 CM(含旧登记) → 合并保留旧 seq
cat > "${TMP}/cm.json" <<EOF
{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"cubestack-install-record","namespace":"kube-system"},
 "data":{"record.json":"{\"schema\":1,\"components\":[{\"key\":\"metallb\",\"seq\":1,\"status\":\"done\"}]}"}}
EOF
FAKE_CM="${TMP}/cm.json" FAKE_APPLY="${TMP}/apply2.json" libfn 'record_installed_component ceph' >/dev/null
chk "② 合并后 metallb seq 保持" "1" \
    "$(jget "$(cat "${TMP}/apply2.json")" 'next(c["seq"] for c in json.loads(d["data"]["record.json"])["components"] if c["key"]=="metallb")')"
chk "② 合并后 ceph seq=2" "2" \
    "$(jget "$(cat "${TMP}/apply2.json")" 'next(c["seq"] for c in json.loads(d["data"]["record.json"])["components"] if c["key"]=="ceph")')"

echo "== ③ 引擎拆序(夹具登记; 离线) =="
INV="${TMP}/inv.json"
cat > "${INV}" <<'EOF'
{"schema":1,"components":[
 {"key":"metallb","seq":1,"status":"done"},
 {"key":"k8s_registry","seq":2,"status":"done"},
 {"key":"ceph","seq":3,"status":"done"},
 {"key":"multus","seq":5,"status":"done"},
 {"key":"cubestack_operator","seq":9,"status":"done"}
]}
EOF
ORDER="$(CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_TEARDOWN_TEST_INVENTORY="${INV}" bash "${ENGINE}" --list --raw 2>/dev/null)"
chk "③ ceph 压轴(最后一行)" "ceph" "$(printf '%s\n' "${ORDER}" | tail -1 | cut -f1)"
chk "③ 登记 seq 降序生效(operator 在 ceph 前)" "cubestack_operator" "$(printf '%s\n' "${ORDER}" | sed -n '1p' | cut -f1)"
chk "③ 登记 seq 降序判别(multus seq5 先于 registry seq2)" "1" "$(printf '%s\n' "${ORDER}" | awk -F'\t' '
  { n++; if ($1=="multus") a=n; if ($1=="k8s_registry") b=n }
  END { print (a>0 && b>0 && a<b) ? 1 : 0 }')"
chk "③ metallb 无 UNINSTALL → 不进拆序" "0" "$(printf '%s\n' "${ORDER}" | cut -f1 | grep -cx 'metallb')"
chk "③ ceph_csi 无 UNINSTALL → 不进拆序" "0" "$(printf '%s\n' "${ORDER}" | cut -f1 | grep -cx 'ceph_csi')"
chk "③ 探测降级组(netshoot)在登记组之后" "1" "$(printf '%s\n' "${ORDER}" | awk -F'\t' '
  { n++; if ($1=="cubestack_operator") a=n; if ($1=="netshoot") b=n }
  END { print (a>0 && b>0 && b>a) ? 1 : 0 }')"
chk "③ netshoot 来源=probe" "probe" "$(printf '%s\n' "${ORDER}" | awk -F'\t' '$1=="netshoot"{print $2}')"

echo "== ④ 引擎离线 dry-run(--uninstall + 夹具 → 只打印不执行) =="
OUT4="$(CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_TEARDOWN_TEST_INVENTORY="${INV}" bash "${ENGINE}" --uninstall 2>&1)"
RC4=$?
chk "④ 退出码 0" "0" "${RC4}"
chk "④ 提示测试钩子" "1" "$(printf '%s' "${OUT4}" | grep -c '测试钩子生效' || true)"
chk "④ 未实际执行组件(无 ▶ 卸载 行)" "0" "$(printf '%s' "${OUT4}" | grep -c '▶ 卸载' || true)"

echo "== ⑤ 消费者停机↔恢复契约(注解标记驱动; 2026-10-13 CodeRabbit 修订) =="
# 契约: 停机方 scale 0 前 stop_mark_replicas 登记原副本数(仅首次); 恢复方 stop_restore_replicas
# 只恢复带注解对象到记录值并清注解; 无注解 = 从未停机 → 不动(旧实现无条件 replicas=1)。
SRC="${REPO_ROOT}/deployments/scripts"
DREP="${TMP}/deploy_replicas"; DANNO="${TMP}/deploy_anno"; DLOG="${TMP}/deploy.log"
# ⑤a 停机登记: 原副本数=3 → 注解=3(非硬编码 1)
printf '3' > "${DREP}"; rm -f "${DANNO}"; : > "${DLOG}"
FAKE_DEPLOY_REPLICAS="${DREP}" FAKE_DEPLOY_ANNO="${DANNO}" FAKE_LOG="${DLOG}" \
    libfn 'stop_mark_replicas deploy cubestack-system cubestack-operator' >/dev/null
chk "⑤a 停机前登记原副本数 3(非硬编码 1)" "3" "$(cat "${DANNO}" 2>/dev/null)"
# ⑤b 重复停机(此刻副本已被 scale 0): 不得把恢复目标覆盖成 0
printf '0' > "${DREP}"
FAKE_DEPLOY_REPLICAS="${DREP}" FAKE_DEPLOY_ANNO="${DANNO}" FAKE_LOG="${DLOG}" \
    libfn 'stop_mark_replicas deploy cubestack-system cubestack-operator' >/dev/null
chk "⑤b 重复停机不覆盖登记值" "3" "$(cat "${DANNO}" 2>/dev/null)"
# ⑤c 恢复: 按登记值恢复 + ⑤d 清除注解(供下一轮重新登记)
: > "${DLOG}"
FAKE_DEPLOY_REPLICAS="${DREP}" FAKE_DEPLOY_ANNO="${DANNO}" FAKE_LOG="${DLOG}" \
    libfn 'stop_restore_replicas deploy cubestack-system cubestack-operator' >/dev/null
chk "⑤c 恢复按登记值 scale --replicas=3" "1" "$(grep -c 'scale deploy cubestack-operator --replicas=3' "${DLOG}")"
chk "⑤d 恢复后清除注解" "0" "$( [ -f "${DANNO}" ] && echo 1 || echo 0 )"
# ⑤e 无注解(本轮从未停机) → 一律不动(CodeRabbit 主诉场景; 旧实现会压回 1)
printf '1' > "${DREP}"; rm -f "${DANNO}"; : > "${DLOG}"
FAKE_DEPLOY_REPLICAS="${DREP}" FAKE_DEPLOY_ANNO="${DANNO}" FAKE_LOG="${DLOG}" \
    libfn 'stop_restore_replicas deploy cubestack-system cubestack-operator' >/dev/null
chk "⑤e 无标记不动(无任何 scale 调用)" "0" "$(grep -c 'scale ' "${DLOG}")"
# ⑤f 对象不存在(NotFound) → 登记/恢复均静默跳过(rs 与 deploy 同路径)
rm -f "${DREP}"; : > "${DLOG}"
FAKE_DEPLOY_REPLICAS="${DREP}" FAKE_DEPLOY_ANNO="${DANNO}" FAKE_LOG="${DLOG}" \
    libfn 'stop_mark_replicas rs kube-system registry; stop_restore_replicas rs kube-system registry' >/dev/null
chk "⑤f 对象不存在 → 无注解/无 scale" "0" "$(grep -cE 'annotate |scale ' "${DLOG}")"
# ⑤g~⑤k 静态围栏(防回退): 停机点先登记; registry 全链走 rs; 7.9 无硬编码 replicas=1
chk "⑤g 02_ceph.sh 7.9 已无硬编码 --replicas=1" "0" "$(grep -c -- '--replicas=1' "${SRC}/modules/03_addon/02_ceph.sh")"
chk "⑤h ceph-cleanup: operator 登记先于 scale 0" "1" "$(awk '
  /stop_mark_replicas deploy/ { a=NR } /scale deploy .* --replicas=0/ { b=NR }
  END { print (a>0 && b>0 && a<b) ? 1 : 0 }' "${SRC}/tools/k8s/ceph-cleanup.sh")"
chk "⑤i ceph-cleanup: registry 走 rs 且登记先于 scale 0" "1" "$(awk '
  /stop_mark_replicas rs kube-system registry/ { a=NR } /scale rs registry --replicas=0/ { b=NR }
  END { print (a>0 && b>0 && a<b) ? 1 : 0 }' "${SRC}/tools/k8s/ceph-cleanup.sh")"
chk "⑤j 05_k8s_registry: registry 走 rs 且登记先于 scale 0" "1" "$(awk '
  /stop_mark_replicas rs kube-system registry/ { a=NR } /scale rs registry --replicas=0/ { b=NR }
  END { print (a>0 && b>0 && a<b) ? 1 : 0 }' "${SRC}/modules/03_addon/05_k8s_registry.sh")"
chk "⑤k 三处代码行不再操作不存在的 deploy registry" "0" \
    "$(cat "${SRC}/tools/k8s/ceph-cleanup.sh" "${SRC}/modules/03_addon/05_k8s_registry.sh" "${SRC}/modules/03_addon/02_ceph.sh" \
       | awk '!/^[[:space:]]*#/ && /deploy registry/' | wc -l)"
chk "⑤l 扫荡保留已 scale 0 的裸 RS(replicas==0 跳过 delrs)" "1" \
    "$(grep -cF 'elif ((_rsob.get("spec") or {}).get("replicas", 1) == 0):' "${SRC}/tools/k8s/ceph-cleanup.sh")"
# ⑤m/⑤n 扫荡 python 行为夹具(从 ceph-cleanup.sh 提取首个 heredoc, 喂合成清单):
#   裸 RS replicas=0(刚优雅停机, pod 尚在终结)→ 无动作; replicas=1 → delrs 原语义保留
SWEEPPY="${TMP}/sweep.py"
awk 'f && /^PYEOF/ {exit} /<<.PYEOF./ {f=1; next} f {print}' "${SRC}/tools/k8s/ceph-cleanup.sh" > "${SWEEPPY}"
cat > "${TMP}/f_pvc.json" <<'EOF'
{"items":[{"metadata":{"namespace":"kube-system","name":"registry-pvc"},"spec":{"storageClassName":"ceph-block"},"status":{"phase":"Bound"}}]}
EOF
cat > "${TMP}/f_pods.json" <<'EOF'
{"items":[{"metadata":{"namespace":"kube-system","name":"registry-abc",
  "ownerReferences":[{"kind":"ReplicaSet","name":"registry"}]},
  "status":{"phase":"Running"},
  "spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"registry-pvc"}}]}}]}
EOF
printf '%s' '{"items":[{"metadata":{"namespace":"kube-system","name":"registry"},"spec":{"replicas":0}}]}' > "${TMP}/f_rs0.json"
printf '%s' '{"items":[{"metadata":{"namespace":"kube-system","name":"registry"},"spec":{"replicas":1}}]}' > "${TMP}/f_rs1.json"
printf '%s' '{"items":[]}' > "${TMP}/f_sts.json"
A5_0="$(python3 "${SWEEPPY}" "${TMP}/f_pvc.json" "${TMP}/f_pods.json" "${TMP}/f_rs0.json" "${TMP}/f_sts.json" 2>/dev/null)"
A5_1="$(python3 "${SWEEPPY}" "${TMP}/f_pvc.json" "${TMP}/f_pods.json" "${TMP}/f_rs1.json" "${TMP}/f_sts.json" 2>/dev/null)"
chk "⑤m 扫荡: 已停机裸 RS → 保留不动" "" "${A5_0}"
chk "⑤n 扫荡: 运行中裸 RS → delrs(原语义不变)" "$(printf 'delrs\tkube-system\tregistry\t')" "${A5_1}"
# ⑤o 消费者清单单一来源: stop_restore_known_consumers(7.9 与 deploy-cluster 失败兜底共用)整组恢复
printf '1' > "${DREP}"; printf '3' > "${DANNO}"; : > "${DLOG}"
FAKE_DEPLOY_REPLICAS="${DREP}" FAKE_DEPLOY_ANNO="${DANNO}" FAKE_LOG="${DLOG}" \
    libfn 'stop_restore_known_consumers' >/dev/null
chk "⑤o 整组恢复: operator 按标记恢复(=3)" "1" "$(grep -c 'scale deploy cubestack-operator --replicas=3' "${DLOG}")"
chk "⑤o 整组恢复: registry 无标记自动跳过" "0" "$(grep -c 'scale rs registry' "${DLOG}")"

echo "== ⑥ cubestack_operator 卸载: CR 终结门(2026-10-13 CodeRabbit; 不收敛跳过 ns 强制清理) =="
# 源模块直跑(假 SSH): 等 CR 终结门(非 Pod 计数); CR 残留则跳过 ns finalizer 清除/强制删 ns/
# CRD 清理 + 非 0 退出(引擎不标 uninstalled)。
# ⚠ 模块会重新 source lib-common(桩函数会被覆盖), 故 sync_kubeconfig 用**裸 ssh 桩**隔离:
#   ssh shim 空输出 → admin.conf 下载失败 → ② helm 步确定性跳过(不依赖本机 helm, 不触真集群)。
MOD25="${REPO_ROOT}/deployments/scripts/modules/03_addon/25_cubestack_operator.sh"
CSHIM="${TMP}/shim"; mkdir -p "${CSHIM}"
cat > "${CSHIM}/ssh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "${CSHIM}/ssh"
printf '1' > "${DREP}"     # get deploy 走 ⑤ 假臂 = 对象存在(⑤f 曾删除该文件)
printf '%s\n' 'clusterstackcluster.cubestack.io/cluster' > "${TMP}/csc_list"
: > "${TMP}/csc_now"       # 空 = 已终结
printf '%s\n' 'customresourcedefinition.apiextensions.k8s.io/clusterstackclusters.cubestack.io' > "${TMP}/crd_list"
# ⑥a 成功路径: CR 终结门通过 → ns/CRD 清理全执行
: > "${DLOG}"
CUBESTACK_MODULE_ACTION=uninstall FAKE_LOG="${DLOG}" FAKE_DEPLOY_REPLICAS="${DREP}" \
  FAKE_CSC_LIST="${TMP}/csc_list" FAKE_CSC_NOW="${TMP}/csc_now" FAKE_CRD_LIST="${TMP}/crd_list" \
  PATH="${CSHIM}:${PATH}" CUBESTACK_OPERATOR_CR_WAIT_SECONDS=10 \
    libfn "source \"${MOD25}\"" >/dev/null 2>&1
_rcA=$?
chk "⑥a 成功路径退出 0" "0" "${_rcA}"
chk "⑥a 删除 CR" "1" "$(grep -c 'delete clusterstackcluster.cubestack.io/cluster' "${DLOG}")"
chk "⑥a ns finalizer 清除 + 强制删 ns 已执行" "2" "$(grep -cE 'finalizers|delete ns ' "${DLOG}")"
chk "⑥a CRD 清理已执行" "1" "$(grep -c 'delete customresourcedefinition' "${DLOG}")"
# ⑥b 残留路径: CR 始终不消失 → 跳过三项破坏性清理 + 非 0 退出
: > "${DLOG}"
CUBESTACK_MODULE_ACTION=uninstall FAKE_LOG="${DLOG}" FAKE_DEPLOY_REPLICAS="${DREP}" \
  FAKE_CSC_LIST="${TMP}/csc_list" FAKE_CSC_NOW="${TMP}/csc_list" FAKE_CRD_LIST="${TMP}/crd_list" \
  PATH="${CSHIM}:${PATH}" CUBESTACK_OPERATOR_CR_WAIT_SECONDS=10 \
    libfn "source \"${MOD25}\"" >/dev/null 2>&1
_rcB=$?
chk "⑥b CR 残留 → 非 0 退出(引擎不标 uninstalled)" "1" "${_rcB}"
chk "⑥b 跳过 ns finalizer 清除" "0" "$(grep -c 'finalizers' "${DLOG}")"
chk "⑥b 跳过强制删 ns" "0" "$(grep -cE 'delete ns ' "${DLOG}")"
chk "⑥b 跳过 CRD 清理" "0" "$(grep -c 'delete customresourcedefinition' "${DLOG}")"
# ⑥c 静态围栏: 旧 Pod 计数判据(_nleft)已移除; 等待门先于 helm uninstall(源码序); 等待门钩子在位
chk "⑥c 旧 Pod 计数判据已移除(_nleft)" "0" "$(grep -c '_nleft' "${MOD25}")"
chk "⑥c CR 等待门先于 helm uninstall(源码序; 先杀 operator 必卡死 finalizer)" "1" "$(awk '
  /等待 CR 终结/ { w=NR } /helm uninstall .*--timeout/ { h=NR } END { print (w>0 && h>0 && w<h) ? 1 : 0 }' "${MOD25}")"
chk "⑥c CR 等待门钩子在位" "1" "$(grep -c 'CUBESTACK_OPERATOR_CR_WAIT_SECONDS' "${MOD25}" | awk '{print ($1>=2)?1:0}')"

echo "== ⑦ deploy-cluster 异常退出兜底(2026-10-13 CodeRabbit; 消费者不停在 0) =="
# 失败/中断路径: EXIT 钩子(仅非 0 退出 + 计划含 ceph/k8s_deploy)按停机标记契约整组恢复;
# 成功路径不改行为(7.9 已恢复清标 → 钩子 no-op)。
DC="${REPO_ROOT}/deployments/scripts/deploy-cluster.sh"
MODCEPH="${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh"
chk "⑦a EXIT 钩子已接线(定义+trap 共 2 处)" "2" "$(grep -c '_restore_marked_consumers_on_fail' "${DC}")"
chk "⑦b 计划门: 仅 ceph/k8s_deploy 计划挂钩子" "5" "$(grep -cE '_has_ceph_step|_has_k8s_step' "${DC}")"
chk "⑦c 仅非 0 退出执行(成功路径零改动)" "1" "$(grep -cF '[ "${_rc}" = "0" ] && return 0' "${DC}")"
chk "⑦d 挂点晚于只读退出(--list/--list-steps 不挂钩)" "1" "$(awk '
  /LIST_STEPS}/ { a=NR } /trap .*_restore_marked_consumers_on_fail/ { b=NR }
  END { print (a>0 && b>0 && a<b) ? 1 : 0 }' "${DC}")"
chk "⑦e 成功路径 7.9 与兜底共用同一函数(注释+调用)" "2" "$(grep -c 'stop_restore_known_consumers' "${MODCEPH}")"
chk "⑦f lib-common 提供共享恢复函数" "1" "$(grep -c '^stop_restore_known_consumers() {' "${REPO_ROOT}/deployments/scripts/lib-common.sh")"
chk "⑦g INT/TERM 转发接线(EXIT trap 在 Ctrl-C/kill 下可靠)" "2" "$(grep -cE "trap 'exit 1(30|43)' (INT|TERM)" "${DC}")"

[ "${fail}" = "0" ] && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
