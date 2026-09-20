#!/bin/bash
# ============================================================
# TOOL: render-check-prometheus
# DESC: 离线断言 08_prometheus 的 values 真的按预期渲染进了 kube-prometheus-stack
#       (不需要集群; 只需 helm + chart)
# 背景: CubeStack 可观测性落地时有四个**静默失效**陷阱 —— 配错了不报错, 只是功能不生效:
#   ① KSM allowlist 值含逗号, 用 --set 会被切成畸形键;
#   ② ruleSelector 按需求文档字面写会把 chart 自带的 35 个默认规则一起丢掉;
#   ③ `serviceMonitorSelector: {}` 被 chart 的 *NilUsesHelmValues=true 改写成 release 匹配;
#   ④ node-exporter 的 extraArgs 是**整体替换**, 覆盖时漏掉 chart 默认两条则 filesystem 过滤失效。
# 本工具在**部署之前**用 helm template 把这些当场抓出来(详见 docs/prometheus-observability.md §2/§6.1)。
# 用法:
#   ./render-check-prometheus.sh                 # 自动找 chart 与 helm
#   ./render-check-prometheus.sh --chart <目录>   # 指定 chart
#   HELM="docker exec <容器> helm" ./render-check-prometheus.sh   # 用容器里的 helm
# 前置: helm 3.x(可用 HELM 覆盖为任意包装命令, 如 `docker exec cubestack-install-c helm`)
# 退出码: 0=全部断言通过; 1=有断言失败(详见输出)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=""
_d="${SCRIPT_DIR}"
while [ "${_d}" != "/" ] && [ -z "${REPO_ROOT}" ]; do
    if [ -d "${_d}/deployments/scripts" ] && [ -d "${_d}/deployments/cubestack-addon" ]; then
        REPO_ROOT="${_d}"
    fi
    _d="$(dirname "${_d}")"
done
REPO_ROOT="${REPO_ROOT:-${PWD}}"

say()  { echo -e "\033[36m→  $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
err()  { echo -e "\033[31m【错误】$*\033[0m" >&2; }

CHART="${PROMETHEUS_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/observability/prometheus/kube-prometheus-stack}"
MODULE="${REPO_ROOT}/deployments/scripts/modules/03_addon/08_prometheus.sh"
HELM_BIN="${HELM:-helm}"
RELEASE="${PROMETHEUS_RELEASE_NAME:-kube-prometheus}"
NS="${PROMETHEUS_NAMESPACE:-monitoring}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --chart) CHART="${2:-}"; shift 2 ;;
        --chart=*) CHART="${1#--chart=}"; shift ;;
        -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(可用 --chart <目录>)"; exit 1 ;;
    esac
done

[ -f "${CHART}/Chart.yaml" ] || { err "chart 不存在: ${CHART}(或 --chart 指定)"; exit 1; }
[ -f "${MODULE}" ] || { err "模块不存在: ${MODULE}"; exit 1; }
${HELM_BIN} version >/dev/null 2>&1 || { err "helm 不可用: ${HELM_BIN}(可用 HELM=\"docker exec <容器> helm\" 指定)"; exit 1; }

_TMPD="$(mktemp -d)"
trap 'rm -rf "${_TMPD}"' EXIT

# ---- 1. 从模块里抽出真实的 values 生成段并执行(而不是抄一份 —— 保证测的就是模块的代码) ----
say "从模块抽出 values 生成段并执行..."
awk '/^_VALUES_YAML="\$\(mktemp\)"/{f=1} /^helm upgrade --install/{f=0} f' "${MODULE}" > "${_TMPD}/gen.sh"
[ -s "${_TMPD}/gen.sh" ] || { err "抽取失败(模块结构变了? 找 _VALUES_YAML= 与 helm upgrade 之间的段)"; exit 1; }
# 把 mktemp 固定到临时目录, 去掉 chmod 600 之外的权限操作(临时目录本来就是 700)
sed -i "s#^_VALUES_YAML=\"\$(mktemp)\"#_VALUES_YAML=\"${_TMPD}/values.yaml\"#" "${_TMPD}/gen.sh"
sed -i "/chmod 600/d" "${_TMPD}/gen.sh"
# 模块里用到的变量(与模块默认一致; 只影响渲染, 不连集群)
PROMETHEUS_NAMESPACE="${NS}"
PROMETHEUS_RELEASE_NAME="${RELEASE}"
PROMETHEUS_RETENTION_DAYS="${PROMETHEUS_RETENTION_DAYS:-15d}"
PROMETHEUS_STORAGE_SIZE="${PROMETHEUS_STORAGE_SIZE:-50Gi}"
PROMETHEUS_SCRAPE_INTERVAL="${PROMETHEUS_SCRAPE_INTERVAL:-30s}"
PROMETHEUS_EVALUATION_INTERVAL="${PROMETHEUS_EVALUATION_INTERVAL:-60s}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
# 用哨兵口令: 断言"值是否原样传到 helm", 不涉及任何真实凭据
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-rendercheck-sentinel-pw}"
export PROMETHEUS_NAMESPACE PROMETHEUS_RELEASE_NAME PROMETHEUS_RETENTION_DAYS PROMETHEUS_STORAGE_SIZE \
       PROMETHEUS_SCRAPE_INTERVAL PROMETHEUS_EVALUATION_INTERVAL GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
bash "${_TMPD}/gen.sh" >/dev/null || { err "values 生成段执行失败(模块改坏了?)"; exit 1; }
[ -s "${_TMPD}/values.yaml" ] || { err "values 文件为空"; exit 1; }
ok "  values 已生成($(wc -l < "${_TMPD}/values.yaml") 行)"

# ---- 2. 渲染 ----
say "helm template 渲染(不连集群)..."
${HELM_BIN} template "${RELEASE}" "${CHART}" \
    --namespace "${NS}" \
    -f "${_TMPD}/values.yaml" \
    --set "prometheusOperator.image.registry=${REG_BASE:-registry.cubestack.io:5000}" \
    --set "kube-state-metrics.image.registry=${REG_BASE:-registry.cubestack.io:5000}" \
    --set "prometheus-node-exporter.image.registry=${REG_BASE:-registry.cubestack.io:5000}" \
    --set "grafana.image.registry=${REG_BASE:-registry.cubestack.io:5000}" \
    > "${_TMPD}/out.yaml" 2>"${_TMPD}/err.txt" \
    || { err "helm template 失败:"; sed 's/^/    /' "${_TMPD}/err.txt"; exit 1; }
ok "  渲染成功($(grep -c '^kind:' "${_TMPD}/out.yaml") 个对象)"

# ---- 3. 断言 ----
say "断言渲染结果(抓四个静默失效陷阱)..."
# ⚠ 断言分两处: `*SelectorNilUsesHelmValues` 是 **Helm values 键**, 不是 Prometheus CR 的字段 ——
#   它只被模板消费, 渲染出来的 CR 里根本不会有。所以那三项断言的是**生成的 values 文件**,
#   而 selector 的**实际渲染值**断言的是 CR。两者都查才算真验证过。
python3 - "${_TMPD}/out.yaml" "${_TMPD}/values.yaml" <<'PY'
import sys, os, base64, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding='utf-8')) if d]
vals = yaml.safe_load(open(sys.argv[2], encoding='utf-8')) or {}
fails = []

def chk(name, cond, detail=''):
    print(("  \033[32m✅\033[0m " if cond else "  \033[31m❌\033[0m ") + name + ("" if cond else "  ← " + str(detail)))
    if not cond:
        fails.append(name)

def find(kind, name_sub=None, ns=None):
    out = []
    for d in docs:
        if d.get('kind') != kind:
            continue
        if name_sub and name_sub not in d['metadata']['name']:
            continue
        if ns and d['metadata'].get('namespace') != ns:
            continue
        out.append(d)
    return out

# ① ruleSelector 并集(陷阱②): 按需求文档字面写 matchLabels 会丢 chart 自带的 35 个规则
pres = find('Prometheus')
chk("Prometheus CR 存在(唯一)", len(pres) == 1, f"{len(pres)} 个")
ps = pres[0]['spec']
_rsel = ps.get('ruleSelector')
_want_expr = {'matchExpressions': [{'key': 'app.kubernetes.io/part-of', 'operator': 'In',
                                    'values': ['cubestack-observability', 'kube-prometheus-stack']}]}
chk("ruleSelector = part-of In [cubestack-observability, kube-prometheus-stack](陷阱②)", _rsel == _want_expr, _rsel)
# 前提: chart 自带的规则确实带 kube-prometheus-stack 值 —— 否则并集里那一项是空转
prs = find('PrometheusRule')
_kn = [d for d in prs if d['metadata'].get('labels', {}).get('app.kubernetes.io/part-of') == 'kube-prometheus-stack']
chk(f"chart 自带 PrometheusRule 带 part-of=kube-prometheus-stack({len(_kn)}/{len(prs)} 个; 并集选择器的前提)",
    len(_kn) > 0, "一个都没有 → 并集选择器里那一项选了空")

# ② 写 {} 不等于全选(陷阱③)
#    · values 文件侧: *NilUsesHelmValues 必须显式 false(否则 {} 会被改写成 release 匹配)
#    · CR 侧: selector 的实际渲染值必须是期望的那个
_spec_vals = ((vals.get('prometheus') or {}).get('prometheusSpec') or {})
for key, nilkey in (('serviceMonitorSelector', 'serviceMonitorSelectorNilUsesHelmValues'),
                    ('ruleSelector', 'ruleSelectorNilUsesHelmValues'),
                    ('scrapeConfigSelector', 'scrapeConfigSelectorNilUsesHelmValues')):
    chk(f"values 里 {nilkey}=false(陷阱③: 否则 {{}} 被改写成 release 匹配)",
        _spec_vals.get(nilkey) is False, f"{nilkey}={_spec_vals.get(nilkey)!r}")
    rendered = ps.get(key)
    if key == 'serviceMonitorSelector':
        chk(f"{key} 渲染成 {{}}(全选)", rendered == {}, rendered)
    else:
        chk(f"{key} 渲染成并集表达式", rendered == _want_expr, rendered)
for key in ('serviceMonitorNamespaceSelector', 'ruleNamespaceSelector', 'scrapeConfigNamespaceSelector'):
    chk(f"{key} = {{}}(跨 ns 发现)", ps.get(key) == {}, ps.get(key))

# ③ KSM allowlist 完整(陷阱①)
ksm = [d for d in find('Deployment', 'kube-state-metrics')]
chk("KSM Deployment 存在", len(ksm) >= 1, f"{len(ksm)} 个")
if ksm:
    args = ksm[0]['spec']['template']['spec']['containers'][0].get('args') or []
    al = [a for a in args if 'labels-allowlist' in a]
    need = ['app.kubernetes.io/part-of', 'ai.cubestack.io/inference-service',
            'ai.cubestack.io/role', 'ai.cubestack.io/dev-environment']
    good = (len(al) == 1 and all(x in al[0] for x in need)
            and 'statefulsets=[ai.cubestack.io/dev-environment]' in al[0])
    chk("KSM --metric-labels-allowlist 完整(4 个 pod label + statefulsets; 陷阱①)", good, al)

# ④ node-exporter extraArgs: IB + 默认两条(陷阱④)
ne = find('DaemonSet', 'node-exporter')
chk("node-exporter DaemonSet 存在", len(ne) >= 1, f"{len(ne)} 个")
if ne:
    args = ne[0]['spec']['template']['spec']['containers'][0].get('args') or []
    chk("node-exporter 加了 --collector.infiniband", any('--collector.infiniband' in a for a in args), args)
    chk("node-exporter 仍保留 mount-points-exclude(陷阱④: 数组是整体替换)",
        any('mount-points-exclude' in a for a in args), args)
    chk("node-exporter 仍保留 fs-types-exclude(陷阱④)",
        any('fs-types-exclude' in a for a in args), args)
    nsm = find('ServiceMonitor', 'node-exporter')
    if nsm:
        rl = nsm[0]['spec']['endpoints'][0].get('relabelings') or []
        chk("node-exporter ServiceMonitor 把 __meta_kubernetes_pod_node_name 打成 node label",
            any(r.get('targetLabel') == 'node' and '__meta_kubernetes_pod_node_name' in (r.get('sourceLabels') or [])
                for r in rl), rl)
    else:
        chk("node-exporter ServiceMonitor 存在", False, "未渲染")

# ⑤ 间隔与口令
chk("scrapeInterval 已设置", bool(ps.get('scrapeInterval')), ps.get('scrapeInterval'))
chk("evaluationInterval 已设置", bool(ps.get('evaluationInterval')), ps.get('evaluationInterval'))
_sent = None
for d in docs:
    if d.get('kind') == 'Secret' and 'grafana' in d['metadata']['name']:
        v = (d.get('data') or {}).get('admin-password')
        if v:
            try:
                _sent = base64.b64decode(v).decode()
            except Exception:
                pass
chk("grafana 口令落到 Secret 的 admin-password", _sent == os.environ.get('GRAFANA_ADMIN_PASSWORD'), _sent)

print()
if fails:
    sys.exit(1)
PY
_rc=$?
echo "---------------------------------------------"
if [ "${_rc}" -eq 0 ]; then
    ok "全部断言通过 —— values 会按预期渲染"
else
    err "有断言失败(见上) —— 这些正是部署后**不报错但功能不生效**的陷阱, 别跳过"
    err "  背景与修法见 docs/prometheus-observability.md §2"
    exit 1
fi
