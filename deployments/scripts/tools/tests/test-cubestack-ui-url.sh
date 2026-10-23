#!/bin/bash
# ============================================================
# test-cubestack-ui-url.sh — CubeStack Web UI 地址发现离线回归
# 覆盖:
#   ① HTTPRoute hostname + Gateway status address + LoadBalancer Service
#   ② 无 hostname + NodePort Service(节点 IP + nodePort)
#   ③ 无 HTTPRoute 时回退到 cubestack Gateway 基础地址
#   ⑦ LoadBalancer 已分配 nodePort 但 ingress 未就绪 → 回退 NodePort(2026-10-23)
# 隔离: 假 kubectl(纯 JSON 夹具, 无需集群)
# 用法: bash deployments/scripts/tools/tests/test-cubestack-ui-url.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${REPO_ROOT}/deployments/scripts/tools/k8s/cubestack-ui-url.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if printf '%s' "$3" | command grep -qF -- "$2"; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if printf '%s' "$3" | command grep -qF -- "$2"; then echo "  FAIL $1: 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/kubectl" <<'FAKE'
#!/bin/bash
set -uo pipefail
case "$*" in
    *"get ns"*)                               exit 0 ;;
    *"gateways.gateway.networking.k8s.io"*)   cat "${FAKE_GW:?}" ;;
    *"httproutes.gateway.networking.k8s.io"*) cat "${FAKE_RT:?}" ;;
    *"get services"*)                         cat "${FAKE_SVC:?}" ;;
    *"get nodes"*)                            cat "${FAKE_NODES:?}" ;;
    *)                                        exit 0 ;;
esac
FAKE
chmod +x "${TMP}/bin/kubectl"

_nodes='{"items":[{"status":{"addresses":[{"type":"InternalIP","address":"10.0.0.10"}]}}]}'
_gw_addr='{"items":[{"metadata":{"name":"cubestack-gateway","namespace":"cubestack-system"},"spec":{"listeners":[{"name":"http","protocol":"HTTP","port":80}]},"status":{"addresses":[{"type":"IPAddress","value":"10.0.0.100"}]}}]}'
_gw_none='{"items":[{"metadata":{"name":"cubestack-gateway","namespace":"cubestack-system"},"spec":{"listeners":[{"name":"http","protocol":"HTTP","port":80}]},"status":{"addresses":[]}}]}'
_svc_lb='{"items":[{"metadata":{"name":"envoy-cubestack-gateway-abc","namespace":"cubestack-system","labels":{"gateway.envoyproxy.io/owning-gateway-name":"cubestack-gateway","gateway.envoyproxy.io/owning-gateway-namespace":"cubestack-system"}},"spec":{"type":"LoadBalancer","ports":[{"port":80,"nodePort":30080}]},"status":{"loadBalancer":{"ingress":[{"ip":"10.0.0.100"}]}}}]}'
_svc_np='{"items":[{"metadata":{"name":"envoy-cubestack-gateway-abc","namespace":"cubestack-system","labels":{"gateway.envoyproxy.io/owning-gateway-name":"cubestack-gateway","gateway.envoyproxy.io/owning-gateway-namespace":"cubestack-system"}},"spec":{"type":"NodePort","ports":[{"port":80,"nodePort":30080}]},"status":{"loadBalancer":{}}}]}'
# LoadBalancer 已分配 nodePort 但 MetalLB 尚未填入 ingress(Service Pending)—— 应回退 NodePort
_svc_lb_pending='{"items":[{"metadata":{"name":"envoy-cubestack-gateway-abc","namespace":"cubestack-system","labels":{"gateway.envoyproxy.io/owning-gateway-name":"cubestack-gateway","gateway.envoyproxy.io/owning-gateway-namespace":"cubestack-system"}},"spec":{"type":"LoadBalancer","ports":[{"port":80,"nodePort":30080}]},"status":{"loadBalancer":{}}}]}'
_rt_host='{"items":[{"metadata":{"name":"cubestack-ui","namespace":"cubestack-system"},"spec":{"hostnames":["ui.example.com"],"parentRefs":[{"name":"cubestack-gateway","namespace":"cubestack-system"}],"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}],"backendRefs":[{"name":"cubestack-ui","port":80}]}]}}]}'
_rt_multi='{"items":[{"metadata":{"name":"cubestack-ui","namespace":"cubestack-system"},"spec":{"parentRefs":[{"name":"cubestack-gateway","namespace":"cubestack-system"}],"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}],"backendRefs":[{"name":"cubestack-ui","port":80}]},{"matches":[{"path":{"type":"PathPrefix","value":"/cubestack"}}],"backendRefs":[{"name":"cubestack-ui","port":80}]},{"matches":[{"path":{"type":"PathPrefix","value":"/cubestack/api/cubepilot/"}}],"backendRefs":[{"name":"cubepilot-api","port":80}]}]}}]}'
_rt_nohost='{"items":[{"metadata":{"name":"cubestack-ui","namespace":"cubestack-system"},"spec":{"parentRefs":[{"name":"cubestack-gateway","namespace":"cubestack-system"}],"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}],"backendRefs":[{"name":"cubestack-ui","port":80}]}]}}]}'
_rt_none='{"items":[]}'
# 2026-10-22 实机: 公网网关(无 MetalLB → NodePort) + 私有网关(ClusterIP)。
# 旧逻辑把私有网关的 ClusterIP status address 也当成 "lb", 于是输出
# "CubeStack Web UI (MetalLB): http://10.233.54.28/" —— 实际只能从集群内访问。
_gw_pair='{"items":[
 {"metadata":{"name":"cubestack-gateway","namespace":"envoy-gateway-system"},"spec":{"listeners":[{"name":"http","protocol":"HTTP","port":80}]},"status":{"addresses":[]}},
 {"metadata":{"name":"cubestack-gateway-private","namespace":"envoy-gateway-system"},"spec":{"listeners":[{"name":"http","protocol":"HTTP","port":80}]},"status":{"addresses":[{"type":"IPAddress","value":"10.233.54.28"}]}}
]}'
_svc_pair='{"items":[
 {"metadata":{"name":"envoy-cubestack-gateway-abc","namespace":"envoy-gateway-system","labels":{"gateway.envoyproxy.io/owning-gateway-name":"cubestack-gateway","gateway.envoyproxy.io/owning-gateway-namespace":"envoy-gateway-system"}},"spec":{"type":"NodePort","ports":[{"port":80,"nodePort":30080}]},"status":{"loadBalancer":{}}},
 {"metadata":{"name":"envoy-cubestack-gateway-private-xyz","namespace":"envoy-gateway-system","labels":{"gateway.envoyproxy.io/owning-gateway-name":"cubestack-gateway-private","gateway.envoyproxy.io/owning-gateway-namespace":"envoy-gateway-system"}},"spec":{"type":"ClusterIP","ports":[{"port":80}]},"status":{"loadBalancer":{}}}
]}'
_rt_pair='{"items":[{"metadata":{"name":"cubestack-ui","namespace":"cubestack-system"},"spec":{"parentRefs":[{"name":"cubestack-gateway","namespace":"envoy-gateway-system"},{"name":"cubestack-gateway-private","namespace":"envoy-gateway-system"}],"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}],"backendRefs":[{"name":"cubestack-ui","port":80}]}]}}]}'

_run() {   # <gw> <rt> <svc> <mode> -> json
    printf '%s' "$1" > "${TMP}/gw.json"
    printf '%s' "$2" > "${TMP}/rt.json"
    printf '%s' "$3" > "${TMP}/svc.json"
    printf '%s' "$_nodes" > "${TMP}/nodes.json"
    SERVICE_EXPOSE_MODE="$4" KUBECTL="${TMP}/bin/kubectl" \
        FAKE_GW="${TMP}/gw.json" FAKE_RT="${TMP}/rt.json" \
        FAKE_SVC="${TMP}/svc.json" FAKE_NODES="${TMP}/nodes.json" \
        bash "${TOOL}" --json
}
_urls() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("urls"), ensure_ascii=False))'; }
_entries() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("entries"), ensure_ascii=False))'; }
_run_human() {   # <gw> <rt> <svc> <mode> -> human output
    printf '%s' "$1" > "${TMP}/gw.json"
    printf '%s' "$2" > "${TMP}/rt.json"
    printf '%s' "$3" > "${TMP}/svc.json"
    printf '%s' "$_nodes" > "${TMP}/nodes.json"
    SERVICE_EXPOSE_MODE="$4" KUBECTL="${TMP}/bin/kubectl" \
        FAKE_GW="${TMP}/gw.json" FAKE_RT="${TMP}/rt.json" \
        FAKE_SVC="${TMP}/svc.json" FAKE_NODES="${TMP}/nodes.json" \
        bash "${TOOL}"
}

echo "== ① metallb: Gateway VIP + hostname =="
chk "metallb URL" '["http://10.0.0.100/"]' "$(_run "$_gw_addr" "$_rt_host" "$_svc_lb" metallb | _urls)"
chk "hostname 保留在 entries" '["ui.example.com"]' "$(_run "$_gw_addr" "$_rt_host" "$_svc_lb" metallb | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["entries"][0]["hostnames"]))')"

echo "== ② nodeport: 节点 IP + nodePort =="
chk "nodeport URL" '["http://10.0.0.10:30080/"]' "$(_run "$_gw_none" "$_rt_nohost" "$_svc_np" nodeport | _urls)"

echo "== ③ no HTTPRoute -> Gateway base =="
chk "Gateway base URL" '["http://10.0.0.100/"]' "$(_run "$_gw_addr" "$_rt_none" "$_svc_lb" metallb | _urls)"

echo "== ④ human 输出带模式标签 =="
chk "json mode=nodeport" "nodeport" "$(_run "$_gw_none" "$_rt_host" "$_svc_np" nodeport | python3 -c 'import json,sys; print(json.load(sys.stdin)["mode"])')"
chk_contains "MetalLB 标签" "CubeStack Web UI (MetalLB): http://10.0.0.100/" "$(_run_human "$_gw_addr" "$_rt_host" "$_svc_lb" metallb)"
chk_contains "NodePort 标签" "CubeStack Web UI (NodePort): http://10.0.0.10:30080/" "$(_run_human "$_gw_none" "$_rt_host" "$_svc_np" nodeport)"

echo "== ⑤ 过滤 API 路径(只保留 / 与 /cubestack) =="
chk "API 路径不打印" '["http://10.0.0.100/", "http://10.0.0.100/cubestack"]' "$(_run "$_gw_addr" "$_rt_multi" "$_svc_lb" metallb | _urls)"

echo "== ⑥ 公网 NodePort + 私有 ClusterIP: 不得把私有 ClusterIP 当 MetalLB =="
chk "只输出公网 NodePort URL" '["http://10.0.0.10:30080/"]' "$(_run "$_gw_pair" "$_rt_pair" "$_svc_pair" nodeport | _urls)"
_ui_url_out="$(_run_human "$_gw_pair" "$_rt_pair" "$_svc_pair" nodeport)"
chk_contains "NodePort 标签" "CubeStack Web UI (NodePort): http://10.0.0.10:30080/" "${_ui_url_out}"
chk_not_contains "不输出私有 ClusterIP" "10.233.54.28" "${_ui_url_out}"
chk_not_contains "不误标 MetalLB" "MetalLB" "${_ui_url_out}"

echo "== ⑦ LoadBalancer 已分配 nodePort 但无 ingress → 回退 NodePort =="
# 2026-10-23 CodeRabbit: Pending 的 LB Service 有 nodePort 却没有 ingress; 旧逻辑
# 只对 type==NodePort 收集 nodePort → pick_endpoints 拿不到任何端点、报"未发现"。
chk "metallb 模式回退 NodePort" '["http://10.0.0.10:30080/"]' \
    "$(_run "$_gw_none" "$_rt_nohost" "$_svc_lb_pending" metallb | _urls)"
chk "auto 模式回退 NodePort" '["http://10.0.0.10:30080/"]' \
    "$(_run "$_gw_none" "$_rt_nohost" "$_svc_lb_pending" "" | _urls)"
chk_contains "human 标签 NodePort" "CubeStack Web UI (NodePort): http://10.0.0.10:30080/" \
    "$(_run_human "$_gw_none" "$_rt_nohost" "$_svc_lb_pending" metallb)"

echo "---------------------------------------------"
[ "${fail}" = "0" ] && { echo "✅ cubestack UI URL 发现回归通过"; exit 0; } || { echo "❌ cubestack UI URL 发现回归失败"; exit 1; }
