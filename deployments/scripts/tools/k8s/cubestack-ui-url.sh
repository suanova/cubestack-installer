#!/bin/bash
# ============================================================
# cubestack-ui-url.sh — 发现 CubeStack Web UI(Envoy Gateway)访问地址
# ------------------------------------------------------------
# 数据来源(只读):
#   · Gateway API: Gateway / HTTPRoute 的 status.addresses / hostnames / listeners
#   · Envoy Gateway 自动创建的 Service(按 gateway.envoyproxy.io/owning-gateway-* 标签)
#   · 节点 InternalIP(NodePort 回退)
#
# 用法:
#   cubestack-ui-url.sh [--kubeconfig <path>] [--wait <sec>] [--json]
#     --wait   URL 未发现时重试的秒数(每 5s 一次; 默认 0=不等待)
#     --json   输出 JSON: {"urls":[...]}
#
# 退出码: 0=找到 URL; 1=未发现(输出排查提示); 2=配置/kubectl 不可用。
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
KUBECONFIG_ARG=""
WAIT_SEC=0
JSON_OUT=0
MODE_ARG="${SERVICE_EXPOSE_MODE:-}"

say()  { echo -e "\033[36m→  $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m" >&2; }
err()  { echo -e "\033[31m【错误】$*\033[0m" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --kubeconfig) KUBECONFIG_ARG="${2:?--kubeconfig 需要路径}"; shift 2 ;;
        --wait) WAIT_SEC="${2:?--wait 需要秒数}"; shift 2 ;;
        --mode) MODE_ARG="${2:?--mode 需要 metallb|nodeport}"; shift 2 ;;
        --json) JSON_OUT=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1"; exit 2 ;;
    esac
done

command -v "${KUBECTL}" >/dev/null 2>&1 || { err "未找到 kubectl(KUBECTL=${KUBECTL})"; exit 2; }
if [ -n "${KUBECONFIG_ARG}" ]; then
    export KUBECONFIG="${KUBECONFIG_ARG}"
fi
# 本地无默认 kubeconfig 时, 尝试 kubespray 产出的 admin.conf(部署机常见路径)
if ! "${KUBECTL}" get ns >/dev/null 2>&1; then
    for _c in "${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster}/artifacts/admin.conf" \
              "${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster/artifacts/admin.conf" \
              "${HOME}/.kube/config"; do
        [ -f "${_c}" ] || continue
        if KUBECONFIG="${_c}" "${KUBECTL}" get ns >/dev/null 2>&1; then
            export KUBECONFIG="${_c}"
            break
        fi
    done
fi
"${KUBECTL}" get ns >/dev/null 2>&1 || { err "无法访问集群(检查 KUBECONFIG / kubectl)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
_get() {   # <resource> <outfile>
    "${KUBECTL}" get "$1" -A -o json > "$2" 2>/dev/null || echo '{"items":[]}' > "$2"
}
_get 'gateways.gateway.networking.k8s.io' "${TMP}/gateways.json"
_get 'httproutes.gateway.networking.k8s.io' "${TMP}/httproutes.json"
_get 'services' "${TMP}/services.json"
"${KUBECTL}" get nodes -o json > "${TMP}/nodes.json" 2>/dev/null || echo '{"items":[]}' > "${TMP}/nodes.json"

_discover() {
    python3 - "${TMP}/gateways.json" "${TMP}/httproutes.json" "${TMP}/services.json" "${TMP}/nodes.json" "${JSON_OUT}" "${MODE_ARG}" <<'PY'
import json, sys

def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {"items": []}

gw_doc, rt_doc, svc_doc, node_doc = (load(sys.argv[i]) for i in range(1, 5))
json_out = sys.argv[5] == "1"
mode_arg = (sys.argv[6] if len(sys.argv) > 6 else "").strip().lower()
gateways = gw_doc.get("items", []) or []
routes = rt_doc.get("items", []) or []
services = svc_doc.get("items", []) or []
nodes = node_doc.get("items", []) or []

node_ips = []
for n in nodes:
    for a in (n.get("status", {}) or {}).get("addresses", []) or []:
        if a.get("address") and a.get("type") in ("InternalIP", "ExternalIP"):
            node_ips.append(a["address"])
if not node_ips:
    for n in nodes:
        for a in (n.get("status", {}) or {}).get("addresses", []) or []:
            if a.get("address"):
                node_ips.append(a["address"])
node_ip = node_ips[0] if node_ips else ""

gw_by_key = {}
for g in gateways:
    md = g.get("metadata", {}) or {}
    gw_by_key[(md.get("namespace", "default"), md.get("name", ""))] = g

def owning_service(ns, name):
    for s in services:
        md = s.get("metadata", {}) or {}
        labels = md.get("labels", {}) or {}
        if labels.get("gateway.envoyproxy.io/owning-gateway-name") != name:
            continue
        lns = labels.get("gateway.envoyproxy.io/owning-gateway-namespace")
        if lns and lns != ns:
            continue
        if not lns and md.get("namespace") != ns:
            continue
        return s
    # 兜底: 同 namespace 且 Service 名包含 Gateway 名
    for s in services:
        md = s.get("metadata", {}) or {}
        if md.get("namespace") == ns and name and name in (md.get("name") or ""):
            return s
    return None

def listener_info(listener):
    proto = (listener.get("protocol") or "HTTP").upper()
    port = listener.get("port") or (443 if proto in ("HTTPS", "TLS") else 80)
    scheme = "https" if proto in ("HTTPS", "TLS") else "http"
    return scheme, int(port)

def gateway_endpoints(ns, name):
    g = gw_by_key.get((ns, name))
    listeners = (g.get("spec", {}) or {}).get("listeners", []) if g else []
    if not listeners:
        listeners = [{"name": "http", "protocol": "HTTP", "port": 80}]
    addrs = []
    svc = owning_service(ns, name)
    svc_type = ""
    if svc:
        st = svc.get("spec", {}) or {}
        svc_type = (st.get("type") or "ClusterIP")
        lb_addrs = []
        for i in (svc.get("status", {}) or {}).get("loadBalancer", {}).get("ingress", []) or []:
            v = i.get("ip") or i.get("hostname")
            if v:
                lb_addrs.append(v)
        for v in lb_addrs:
            addrs.append(("lb", v))
        # NodePort 回退: 显式 NodePort; 或 LoadBalancer 尚未分配 ingress(如 MetalLB 未就绪 /
        # Service 仍在 Pending)但已分配 nodePort —— 供 pick_endpoints 从 metallb 回退到 NodePort
        # (2026-10-23 CodeRabbit: 旧逻辑只认 type==NodePort, Pending LB 会得不到任何端点)。
        if node_ip and (svc_type == "NodePort" or (svc_type == "LoadBalancer" and not lb_addrs)):
            for p in st.get("ports", []) or []:
                np = p.get("nodePort")
                if np:
                    addrs.append(("nodeport", int(np)))
    # Gateway status address: only externally meaningful for LoadBalancer (or when the
    # owning Service is not visible). A ClusterIP Service's address is the private
    # gateway's internal VIP — never advertise it as the Web UI; NodePort is served
    # through node IP + spec.ports[].nodePort above.
    if g and svc_type in ("", "LoadBalancer"):
        for a in (g.get("status", {}) or {}).get("addresses", []) or []:
            if a.get("value"):
                addrs.append(("lb", a["value"]))
    out = []
    for kind, val in addrs:
        if kind == "nodeport":
            scheme, _ = listener_info(listeners[0])
            out.append({"kind": "nodeport", "host": node_ip, "port": val, "scheme": scheme})
        else:
            for l in listeners:
                scheme, port = listener_info(l)
                out.append({"kind": "lb", "host": val, "port": port, "scheme": scheme})
    # 去重
    seen, uniq = set(), []
    for e in out:
        k = (e["scheme"], e["host"], e["port"])
        if k not in seen:
            seen.add(k); uniq.append(e)
    return uniq, g

def backend_names(route):
    names = []
    for rule in (route.get("spec", {}) or {}).get("rules", []) or []:
        for br in rule.get("backendRefs", []) or []:
            n = br.get("name") or ""
            if n:
                names.append(n)
    return names

def is_ui(route):
    names = [n.lower() for n in backend_names(route)]
    for n in names:
        if n in ("cubestack-ui", "cubestack-portal"):
            return True
        if "cubestack" in n and ("ui" in n or "portal" in n):
            return True
    ns = ((route.get("metadata", {}) or {}).get("namespace") or "").lower()
    return "cubestack" in ns and any(("ui" in n or "portal" in n) for n in names)

def route_paths(route):
    paths = []
    for rule in (route.get("spec", {}) or {}).get("rules", []) or []:
        for m in rule.get("matches", []) or []:
            p = ((m.get("path", {}) or {}).get("value") or "").strip()
            if p:
                paths.append(p)
    return paths or ["/"]

def is_api_path(p):
    # UI 地址只保留页面路径; API/后端代理路径(如 /cubestack/api/cubepilot/)会 404, 不打印
    q = (p or "").lower()
    return ("/api/" in q) or q.rstrip("/").endswith("/api") or ("cubepilot" in q)

def ui_paths(route):
    return [p for p in route_paths(route) if not is_api_path(p)]

ui_routes = [r for r in routes if is_ui(r)]
if not ui_routes:
    # 兜底: 任一路由的 backend 含 ui/portal/web
    ui_routes = [r for r in routes if any(("ui" in n.lower() or "portal" in n.lower() or "web" in n.lower()) for n in backend_names(r))]

def pick_endpoints(endpoints):
    lb = [e for e in endpoints if e["kind"] == "lb"]
    np = [e for e in endpoints if e["kind"] == "nodeport"]
    if mode_arg == "nodeport":
        return (np, "nodeport") if np else (lb, "metallb")
    if mode_arg in ("metallb", "loadbalancer"):
        return (lb, "metallb") if lb else (np, "nodeport")
    if lb:
        return lb, "metallb"
    if np:
        return np, "nodeport"
    return [], "unknown"

def label_for(kind):
    return "MetalLB" if kind == "metallb" else ("NodePort" if kind == "nodeport" else "Envoy Gateway")

entries = []
def add_entry(label, url, hosts):
    entries.append({"label": label, "url": url, "hostnames": hosts})

def emit_for_parent(r, rns, pref, hostnames):
    pns = pref.get("namespace") or rns
    pname = pref.get("name")
    if not pname:
        return
    endpoints, _ = gateway_endpoints(pns, pname)
    eps, kind = pick_endpoints(endpoints)
    paths = ui_paths(r)
    if not paths:
        return
    for ep in eps:
        for path in paths:
            if not path.startswith("/"):
                path = "/" + path
            port = "" if ep["port"] in (80, 443) else f":{ep['port']}"
            add_entry(label_for(kind), f"{ep['scheme']}://{ep['host']}{port}{path}", hostnames)

for r in ui_routes:
    md = r.get("metadata", {}) or {}
    rns = md.get("namespace", "default")
    spec = r.get("spec", {}) or {}
    hostnames = [h for h in (spec.get("hostnames") or []) if h and not h.startswith("*.")]
    parents = spec.get("parentRefs") or []
    if not parents:
        cand = [g for g in gateways if (g.get("metadata", {}) or {}).get("namespace") == rns]
        if not cand:
            cand = [g for g in gateways if "cubestack" in ((g.get("metadata", {}) or {}).get("name", "") + (g.get("metadata", {}) or {}).get("namespace", "")).lower()]
        if not cand and gateways:
            cand = [gateways[0]]
        parents = [{"name": (g.get("metadata", {}) or {}).get("name"), "namespace": (g.get("metadata", {}) or {}).get("namespace", rns)} for g in cand]
    for pref in parents:
        emit_for_parent(r, rns, pref, hostnames)

# 未匹配到 UI 路由: 回退到 cubestack Gateway 的基础地址
if not entries:
    cand = [g for g in gateways if "cubestack" in ((g.get("metadata", {}) or {}).get("name", "") + (g.get("metadata", {}) or {}).get("namespace", "")).lower()]
    if not cand and gateways:
        cand = gateways[:1]
    for g in cand:
        md = g.get("metadata", {}) or {}
        endpoints, _ = gateway_endpoints(md.get("namespace", "default"), md.get("name", ""))
        eps, kind = pick_endpoints(endpoints)
        for ep in eps:
            port = "" if ep["port"] in (80, 443) else f":{ep['port']}"
            add_entry(label_for(kind), f"{ep['scheme']}://{ep['host']}{port}/", [])

# 去重
seen, uniq = set(), []
for e in entries:
    k = (e["label"], e["url"])
    if k in seen:
        continue
    seen.add(k); uniq.append(e)

if json_out:
    if uniq:
        mode = "metallb" if uniq[0]["label"] == "MetalLB" else ("nodeport" if uniq[0]["label"] == "NodePort" else "unknown")
    else:
        mode = mode_arg if mode_arg in ("metallb", "nodeport") else "unknown"
    print(json.dumps({"mode": mode, "urls": [e["url"] for e in uniq], "entries": uniq}, ensure_ascii=False))
elif uniq:
    for e in uniq:
        note = ""
        if e["hostnames"]:
            h = e["hostnames"][0]
            if e["label"] == "NodePort":
                note = f"  (HTTPRoute host: {h}; 需 curl -H 'Host: {h}' 或把该域名解析到节点)"
            else:
                note = f"  (HTTPRoute host: {h}; 配置 DNS/hosts 指向该地址后可直接用域名访问)"
        print(f"CubeStack Web UI ({e['label']}): {e['url']}{note}")
else:
    print("CubeStack Web UI: 未发现(Envoy Gateway/HTTPRoute 可能尚未就绪)", file=sys.stderr)
    print("  排查: kubectl get gateway,httproute -A", file=sys.stderr)
    sys.exit(1)
PY
}

_end=$((SECONDS + WAIT_SEC))
while :; do
    if _out="$(_discover 2>/dev/null)"; then
        echo "${_out}"
        exit 0
    fi
    [ "${SECONDS}" -ge "${_end}" ] && break
    sleep 5
done
# 最后一次把诊断信息输出(便于部署日志直接看到)
if [ "${JSON_OUT}" = "1" ]; then
    echo '{"mode":"unknown","urls":[],"entries":[]}'
else
    echo "CubeStack Web UI: 尚未发现(Envoy Gateway/HTTPRoute 可能尚未就绪; 稍后重跑: bash ${BASH_SOURCE[0]})"
fi
exit 1
