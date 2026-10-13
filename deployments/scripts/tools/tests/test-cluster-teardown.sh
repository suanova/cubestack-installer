#!/bin/bash
# 桩式测试: 优雅覆盖链路 —— ① 登记合并(纯函数) ② 登记写回(假 SSH) ③ 引擎拆序/降级/离线 dry-run(Task 9 扩展)
#   ④ 引擎 --uninstall 离线 dry-run ⑤ 消费者停机↔恢复契约(注解标记驱动, 2026-10-13 CodeRabbit 修订)
# 隔离手段(与 test-sync-api-entry.sh 同风格):
#   ① CLUSTER_CONF 指向临时配置(load_config 只读它, 不碰真 cluster.conf)
#   ② init_remote_kubectl 之后用假 SSH 覆盖(记录调用; get cm → $FAKE_CM; apply -f - → 存 $FAKE_APPLY)
#   ③ 引擎用 CUBESTACK_TEARDOWN_TEST_INVENTORY 夹具 JSON 走离线路径(不连任何集群)
#   ⑤ 假 deploy/rs 状态机(FAKE_DEPLOY_REPLICAS=对象存在+副本数; FAKE_DEPLOY_ANNO=登记注解)
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

[ "${fail}" = "0" ] && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
