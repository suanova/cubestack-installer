#!/bin/bash
# 桩式测试: 优雅覆盖链路 —— ① 登记合并(纯函数) ② 登记写回(假 SSH) ③ 引擎拆序/降级/离线 dry-run(Task 9 扩展)
# 隔离手段(与 test-sync-api-entry.sh 同风格):
#   ① CLUSTER_CONF 指向临时配置(load_config 只读它, 不碰真 cluster.conf)
#   ② init_remote_kubectl 之后用假 SSH 覆盖(记录调用; get cm → $FAKE_CM; apply -f - → 存 $FAKE_APPLY)
#   ③ 引擎用 CUBESTACK_TEARDOWN_TEST_INVENTORY 夹具 JSON 走离线路径(不连任何集群)
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

[ "${fail}" = "0" ] && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
