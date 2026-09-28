#!/bin/bash
# ============================================================
# check-modules.sh — 部署模块静态校验(开发期 + CI)
# 目的: 新模块/新 feature 合入前先过一遍本检查, 保证不破坏既有模块框架:
#   ① 全部模块 bash -n 语法通过
#   ② 头部元数据齐全(MODULE/DESC/PHASE/DEFAULT/REPEAT; TOGGLE 可选)
#   ③ MODULE key 唯一且合法(小写字母/数字/下划线, 非 verify_* 保留前缀)
#   ④ PHASE 合法且与所在目录(NN_ 前缀)一致
#   ⑤ REQUIRES 引用的模块都存在; 全量拓扑排序无循环
#   ⑥ 使用远端 kubectl(K/SSH/SSH_CMD/FIRST_MASTER)的模块必须调用 init_remote_kubectl
#      (历史事故: 新模块少复制初始化块 → set -u 下 "K: unbound variable" 部署崩溃)
#   ⑦ TOGGLE 变量在 cluster.conf.example 中有默认声明(防漏配)
#   ⑧ 文件序号 NN_ 与目录序号在发现结果中不重名冲突
#   ⑨ tools/ 下全部脚本 bash -n 通过
#   ⑩ 安装 helm chart 的模块必须有 vendored 离线副本
#   ⑪ kube-vip: 单一写入者契约(kube_vip_enabled 恒 false)+ 启用时取值自洽(address / 不与 MetalLB 抢地址)
#   ⑬ API 入口: all.yml 本地代理语义自洽(localhost: true ⇒ loadbalancer_apiserver 块必须被注释)
#   ⑭ 离线预加载: PRELOAD_IMAGE_PATTERNS 四处副本逐字节一致(漂移会被备料静默 trim 掉)
#   ⑮ kubespray 补丁在位(cubestack-patch-apply.sh --check 全绿; 换树后没重放会静默降级)
# 用法: bash check-modules.sh           # 校验全部模块(只读, 无需 root)
#       bash check-modules.sh --quiet   # 只输出违规项
# 退出码: 0=全部通过; 1=存在违规(列出清单)
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/modules"
CONF_EXAMPLE="$(cd "${SCRIPT_DIR}/../.." && pwd)/config/cluster.conf.example"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "${QUIET}" = "1" ] || echo -e "\033[36m→ $*\033[0m"; }
ok()  { echo -e "\033[32m✅ $*\033[0m"; }
bad() { echo -e "\033[31m❌ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }

FAIL=0
ck_fail() { bad "$*"; FAIL=1; }

say "==== 模块静态校验(${MODULES_DIR}) ===="

# ---------- ① bash -n 语法 ----------
say "[1/15] bash -n 语法检查 ..."
SYNTAX_FAIL=0
while IFS= read -r -d '' f; do
    bash -n "$f" 2>/dev/null || { bad "语法错误: ${f#$MODULES_DIR/}"; SYNTAX_FAIL=1; FAIL=1; }
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${SYNTAX_FAIL}" = "0" ] && ok "全部 $(find "${MODULES_DIR}" -name '*.sh' | wc -l) 个模块语法通过"

# ---------- 元数据解析(与 lib-module.sh 同规则) ----------
meta() { sed -nE "s/^#[[:space:]]*${2}:[[:space:]]*(.*)$/\1/p" "$1" | head -1; }
phase_dir() { case "$(basename "$(dirname "$1")")" in
    01_env) echo "env";; 02_k8s) echo "k8s";; 03_addon) echo "addon";; *) echo "?";; esac; }

say "[2/15] 头部元数据齐全性 ..."
declare -A KEYS=()
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    for field in MODULE DESC PHASE DEFAULT REPEAT; do
        [ -n "$(meta "$f" "$field")" ] || ck_fail "${rel}: 缺少 # ${field}: 元数据"
    done
    key="$(meta "$f" MODULE)"
    if [ -n "${key}" ]; then
        if [ -n "${KEYS[$key]:-}" ]; then ck_fail "MODULE key 重复: ${key} (${KEYS[$key]} 与 ${rel})"; fi
        KEYS[$key]="${rel}"
        case "${key}" in
            *[!a-z0-9_]*) ck_fail "${rel}: MODULE key 含非法字符: ${key}(仅小写字母/数字/下划线)" ;;
        esac
    fi
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${FAIL}" = "0" ] && ok "元数据齐全"

say "[3/15] MODULE key 唯一性 ..."   # 已在上面检查, 这里输出结果
[ "${FAIL}" = "0" ] || true

say "[4/15] PHASE 合法性 + 目录一致性 ..."
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    ph="$(meta "$f" PHASE)"
    case "${ph}" in env|k8s|addon) ;; *) ck_fail "${rel}: PHASE=${ph:-<空>} 非法(需 env/k8s/addon)";; esac
    [ "${ph}" = "$(phase_dir "$f")" ] || ck_fail "${rel}: PHASE=${ph} 与目录 $(basename "$(dirname "$f")") 不一致"
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${FAIL}" = "0" ] || true

# ---------- ⑤ REQUIRES 引用 + 全量拓扑 ----------
say "[5/15] REQUIRES 引用存在性 + 全量无环 ..."
REQ_FAIL=0
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    for d in $(meta "$f" REQUIRES); do
        # 引用必须命中某个模块的 MODULE key
        hit=""
        while IFS= read -r -d '' g; do
            [ "$(meta "$g" MODULE)" = "${d}" ] && { hit=1; break; }
        done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
        [ -n "${hit}" ] || { ck_fail "${rel}: REQUIRES 引用未知模块: ${d}"; REQ_FAIL=1; }
    done
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
# 全量拓扑(Kahn 式, 与 lib-module.sh _topo_sort_requires 同算法): 全部模块必须可排序
declare -A ALLKEYS=() REMAIN=() DONE=()
while IFS= read -r -d '' f; do
    k="$(meta "$f" MODULE)"; ALLKEYS[$k]="$f"; REMAIN[$k]=1
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
ORDER=(); PROG=1
while [ "${#REMAIN[@]}" -gt 0 ] && [ "${PROG}" = "1" ]; do
    PROG=0
    while IFS= read -r -d '' f; do
        k="$(meta "$f" MODULE)"
        [ -n "${REMAIN[$k]:-}" ] || continue
        okdeps=1
        for d in $(meta "$f" REQUIRES); do
            [ -n "${DONE[$d]:-}" ] || { okdeps=0; break; }
        done
        if [ "${okdeps}" = "1" ]; then
            ORDER+=("${k}"); unset REMAIN["$k"]; DONE["$k"]=1; PROG=1
        fi
    done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
done
if [ "${#REMAIN[@]}" -gt 0 ]; then
    ck_fail "REQUIRES 依赖循环(无法排序): ${!REMAIN[*]}"
else
    ok "REQUIRES 全量拓扑排序通过(${#ORDER[@]} 个模块无环)"
fi

# ---------- ⑥ init_remote_kubectl 使用检查 ----------
say "[6/15] 远端 kubectl 初始化(K/SSH)调用检查 ..."
INIT_MISS=0
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    # 使用 K/SSH/SSH_CMD/FIRST_MASTER 的模块必须调用 init_remote_kubectl
    uses_k=$(grep -cE '\$\{K\}|"\$\{K\}|SSH_CMD' "$f" 2>/dev/null)
    uses_ssh=$(grep -cE 'SSH "\$\{K\}"|SSH_CMD' "$f" 2>/dev/null)
    if [ "${uses_k}" -gt 0 ] || [ "${uses_ssh}" -gt 0 ]; then
        grep -q 'init_remote_kubectl' "$f" || { ck_fail "${rel}: 使用了 K/SSH 但未调用 init_remote_kubectl(历史事故: unbound K 崩溃)"; INIT_MISS=1; }
    fi
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${INIT_MISS}" = "0" ] && ok "使用 K/SSH 的模块均已调用 init_remote_kubectl"

# ---------- ⑦ TOGGLE 与 cluster.conf.example 一致性 ----------
say "[7/15] TOGGLE 变量在 cluster.conf.example 声明 ..."
if [ -f "${CONF_EXAMPLE}" ]; then
    TOG_MISS=0
    while IFS= read -r -d '' f; do
        tgl="$(meta "$f" TOGGLE)"
        [ -n "${tgl}" ] || continue
        # TOGGLE 支持空格分隔多变量(OR, 如 ceph: CEPH_ENABLED CEPH_CSI_ENABLED) → 逐个校验
        for tv in ${tgl}; do
            grep -qE "${tv}=" "${CONF_EXAMPLE}" || { ck_fail "$(basename "$f"): TOGGLE=${tv} 未在 cluster.conf.example 中声明默认值"; TOG_MISS=1; }
        done
    done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
    [ "${TOG_MISS}" = "0" ] && ok "全部 TOGGLE 变量均有 cluster.conf.example 默认值"
else
    warn "  未找到 ${CONF_EXAMPLE}, 跳过 TOGGLE 一致性检查"
fi

# ---------- ⑧ 文件序号与目录 ----------
say "[8/15] 文件名序号规范(NN_ 前缀) ..."
NUM_FAIL=0
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    base="$(basename "$f")"
    case "${base}" in
        [0-9][0-9]_*) ;;
        *) ck_fail "${rel}: 文件名缺 NN_ 序号前缀(需 01_xxx.sh 格式)"; NUM_FAIL=1 ;;
    esac
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${NUM_FAIL}" = "0" ] && ok "文件名序号规范"

# ---------- ⑨ tools/ 工具脚本语法检查 ----------
# 模块外的部署工具(tools/**/*.sh: ceph-backup/deploy-registry/... )同样参与部署,
# 漏检会在运行期炸(历史: registry 就绪等待 K unbound 崩溃)。
say "[9/15] tools/ 工具脚本语法检查 ..."
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
T_FAIL=0
while IFS= read -r -d '' f; do
    bash -n "$f" 2>/dev/null || { ck_fail "tools 语法错误: ${f#$TOOLS_DIR/}"; T_FAIL=1; }
done < <(find "${TOOLS_DIR}" -name '*.sh' -print0)
[ "${T_FAIL}" = "0" ] && ok "全部 $(find "${TOOLS_DIR}" -name '*.sh' | wc -l) 个 tools 脚本语法通过"

# ---------- ⑩ helm chart 离线副本(全仓库约定) ----------
# 规则: 凡安装 helm chart 的模块, 其 chart **必须有一份 vendored 在 deployments/cubestack-addon/**
# 下并随 git 分发 —— 模块安装时**恒用这份本地副本**, 在线只用于比对刷新
# (见 lib-common 的 helm_chart_ensure, 以及 docs/scripts-development-spec.md §2.4)。
# 为什么要有这一条: 曾有模块**写了**"私服拉取失败就回退本地 chart",
# 但仓库里压根没有那份文件 —— 私服一抖动, 回退就是空转, 回退代码形同虚设。
# 光靠文档挡不住这种缺失(写的时候都以为回退能兜住), 所以放进静态校验。
say "[10/15] helm chart 离线副本检查 ..."
ADDON_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)/deployments/cubestack-addon"
CHART_FAIL=0; CHART_WARN=0; CHART_OKN=0
# 判据: **行首就是 helm 命令** —— 只排除注释不够, 变量/err 字符串里提到
#   "helm upgrade --install" 的地方(如 verify 模块的排查提示)会被误判成"装了 chart"。
HELM_RE='^[[:space:]]*helm[[:space:]]+(upgrade[[:space:]]+--install|install)[[:space:]]'
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    grep -qE "${HELM_RE}" "$f" || continue
    grep -q 'addon_stub ' "$f" && continue      # 伪代码占位(未实现), 不参与本检查
    # 提取该模块引用的 cubestack-addon/<路径> 候选(含被变量截断的前缀, 后面靠存在性过滤)
    cands="$(sed -n 's#.*cubestack-addon/\([A-Za-z0-9_./-]*\).*#\1#p' "$f" | sort -u || true)"
    if [ -z "${cands}" ]; then
        warn "  ${rel}: 装了 helm chart 却未引用 cubestack-addon/ 下任何路径"
        warn "     → 无法静态确认离线副本; 若 chart 在仓库外(占位/特例), 请忽略本告警"
        CHART_WARN=$((CHART_WARN + 1)); continue
    fi
    hit=0
    while IFS= read -r c; do
        [ -z "${c}" ] && continue
        p="${ADDON_DIR}/${c}"
        if [ -f "${p}" ]; then
            case "${p}" in *.tgz) hit=1 ;; esac
        elif [ -d "${p}" ]; then
            # 目录里直接含 .tgz 或 Chart.yaml 才算 vendored chart(与各组件实际布局一致)
            ls "${p}"/*.tgz >/dev/null 2>&1 && hit=1
            [ -f "${p}/Chart.yaml" ] && hit=1
        fi
        [ "${hit}" = "1" ] && break
    done <<< "${cands}"
    if [ "${hit}" = "1" ]; then
        CHART_OKN=$((CHART_OKN + 1))
    else
        ck_fail "${rel}: 引用了 cubestack-addon/ 却**找不到 vendored chart**(.tgz 或 Chart.yaml)"
        ck_fail "      → 模块安装时恒用本地副本, 缺了它私服/上游一抖动就装不上(回退代码会空转)"
        ck_fail "      → 修法: 把 chart 放进 deployments/cubestack-addon/<组件>/ 并提交,"
        ck_fail "             tgz 形式请一并提交 <tgz>.digest 边车(供 helm_chart_ensure 比对刷新)"
        CHART_FAIL=$((CHART_FAIL + 1))
    fi
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${CHART_FAIL}" = "0" ] && ok "安装 chart 的模块均有 vendored 离线副本(${CHART_OKN} 个模块通过)"

# ---------- ⑪ kube-vip 控制平面 VIP(与 kubespray inventory 的一致性) ----------
say "[11/15] kube-vip 控制平面 VIP 配置检查 ..."
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
KV_ADDONS="${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster/group_vars/k8s_cluster/addons.yml"
KV_ALL_YML="${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster/group_vars/all/all.yml"
KV_CONF="${REPO_ROOT}/deployments/config/cluster.conf"
[ -f "${KV_CONF}" ] || KV_CONF="${CONF_EXAMPLE}"
# 在**子 shell 内**求值 cluster.conf, 只回传需要的五个值。理由:
#   ① cluster.conf 依赖 REPO_ROOT 等多个变量, 在当前 set -u 下直接 source 会中断;
#      子 shell 里 set +u 给它宽松环境, 且不污染本脚本状态(本脚本有 FAIL 等同名变量)
#   ② 用 shell 自己解析(而非正则抠字符串), 才能正确处理 "${VAR:-default}" / 字面量 / 注释
KV_SNAPSHOT="$(
    set +u
    REPO_ROOT="${REPO_ROOT}" SCRIPT_DIR="${SCRIPT_DIR}" CONF_EXAMPLE="${CONF_EXAMPLE}"
    # shellcheck disable=SC1090
    . "${KV_CONF}" >/dev/null 2>&1 || true
    printf '%s\n%s\n%s\n%s\n%s\n' \
        "${KUBE_VIP_ENABLED:-false}" "${K8S_API_VIP:-}" "${METALLB_POOL:-}" \
        "${API_LOCAL_LB_ENABLED:-}" "${KUBE_VIP_LOCAL_PROXY:-false}"
)"
KUBE_VIP_ENABLED="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 1p)"
K8S_API_VIP="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 2p)"
METALLB_POOL="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 3p)"
API_LOCAL_LB_RAW="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 4p)"
KUBE_VIP_LOCAL_PROXY_RAW="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 5p)"
unset KV_SNAPSHOT

# 本地代理是否启用 —— 与 lib-common#api_local_lb_enabled 同语义:
#   显式 API_LOCAL_LB_ENABLED 优先; 为空则回退旧别名 KUBE_VIP_LOCAL_PROXY。
# (本脚本不 source lib-common, 只能就地复刻; 两者若漂移, 本项判据就会与部署行为脱节)
case "${API_LOCAL_LB_RAW}" in
    '')            case "${KUBE_VIP_LOCAL_PROXY_RAW}" in 1|true|yes|on) _LOCAL_LB=1 ;; *) _LOCAL_LB=0 ;; esac ;;
    1|true|yes|on) _LOCAL_LB=1 ;;
    *)             _LOCAL_LB=0 ;;
esac
_LOCAL_LB_TXT="关闭"; [ "${_LOCAL_LB}" = "1" ] && _LOCAL_LB_TXT="开启"

# ⑪-A 单一写入者契约 —— **与 KUBE_VIP_ENABLED 无关, 恒成立**
#   addons.yml 的 kube_vip_enabled 控制的是"kubespray 要不要写这个静态 Pod"; 而静态 Pod 归
#   02_k8s/09_kube_vip.sh 独占, 所以它必须恒为 false。若为 true: kubespray 会回来写同一个文件,
#   且对**首台** master 用 super-admin.conf(roles/kubernetes/node/tasks/loadbalancer/kube-vip.yml:26-31),
#   与本模块渲染的 admin.conf 不同 → 每次全量运行该文件被改写两次, kube-vip pod 跟着重启两次。
#   注: 纯 checkout(CI)里这个键就是 kubespray 模板里的 false, 故本条在 CI 上同样成立、不会误报。
if [ ! -f "${KV_ADDONS}" ]; then
    warn "  未找到 ${KV_ADDONS}, 跳过 kube-vip 单一写入者契约校验(未生成 inventory?)"
else
    kv_en="$(awk -F': *' '/^kube_vip_enabled:/{print $2; exit}' "${KV_ADDONS}")"
    kv_svc="$(awk -F': *' '/^kube_vip_services_enabled:/{print $2; exit}' "${KV_ADDONS}")"
    if [ "${kv_en}" = "true" ]; then
        ck_fail "addons.yml 的 kube_vip_enabled=true —— 违反单一写入者契约(kubespray 会与本模块抢写同一个 manifest)" \
            "      → 静态 Pod 由 02_k8s/09_kube_vip.sh 独占; 置 false 后重跑 tools/k8s/sync-kubespray-config.sh" \
            "      → 详见 docs/kube-vip-api-ha.md 第 18 节"
    fi
    # 无条件违规项: 与是否部署过无关, 只要写进 inventory 就是错的
    if [ "${kv_svc}" = "true" ]; then
        ck_fail "kube_vip_services_enabled=true —— kube-vip 与 MetalLB 都在实现 LoadBalancer, 会互相抢地址" \
            "      → 服务 LB 归 MetalLB(见 docs/kube-vip-api-ha.md 决策 D1); 修法: 置 false 后重跑 sync"
    fi
fi

# ⑪-C 兜底默认一致性(2026-09-24 增补): 同一个开关的**默认值**散落在多处兜底里 ——
#   cluster.conf.example(模板) / 09_kube_vip.sh(渲染调用) / lib-common.sh(addons.yml 写入)
#   / render-kube-vip-manifest.py(CLI 默认)。改默认时漏改一处 → 行为随调用路径漂移
#   (本仓库实测踩过: 文档与代码不同步; KUBE_VIP_ENABLED 当年也是改了 11 处兜底才一致)。
#   这里只断言"各处彼此一致", **不写死具体值** —— 将来再翻转也不会误报。
_cpd="$(grep -rhoE 'KUBE_VIP_CP_DETECT:-[a-z]+' \
        "${CONF_EXAMPLE}" \
        "${REPO_ROOT}/deployments/scripts/modules/02_k8s/09_kube_vip.sh" \
        "${REPO_ROOT}/deployments/scripts/lib-common.sh" 2>/dev/null | sed 's/.*:-//' | sort -u)"
_cpdr="$(grep -oE '"--cp-detect", default="[a-z]+"' \
         "${REPO_ROOT}/deployments/scripts/tools/k8s/render-kube-vip-manifest.py" 2>/dev/null | grep -oE '(true|false)' | head -1)"
if [ -n "${_cpd}" ] && [ "$(printf '%s\n' "${_cpd}" | grep -c .)" = "1" ] && [ "${_cpd}" = "${_cpdr}" ]; then
    ok "KUBE_VIP_CP_DETECT 各处兜底默认一致(${_cpd})"
else
    ck_fail "KUBE_VIP_CP_DETECT 兜底默认不一致: shell 侧=[${_cpd:-未取到}] 渲染器=[${_cpdr:-未取到}]" \
        "      → 改默认须同时改: cluster.conf.example / 02_k8s/09_kube_vip.sh / lib-common.sh / tools/k8s/render-kube-vip-manifest.py"
fi

# ⑪-B 开关**开启**时才有意义的取值自洽(关闭态那些值会连同 VIP 一起经清理路径收敛掉)
if [ "${KUBE_VIP_ENABLED:-false}" = "true" ]; then
    if [ ! -f "${KV_ADDONS}" ]; then
        warn "  未找到 ${KV_ADDONS}, 跳过(未生成 inventory?)"
    else
        kv_addr="$(awk -F': *' '/^kube_vip_address:/{print $2; exit}' "${KV_ADDONS}")"
        lb_addr="$(awk '/^loadbalancer_apiserver:/{f=1; next} f && /^[[:space:]]+address:/{print $2; exit}' "${KV_ALL_YML}" 2>/dev/null || true)"

        # ★ 门禁看**实际部署**, 不看配置开关(与 verify_* 模块同一惯例):
        #   kube_vip_address 是 sync-kubespray-config.sh 在部署流程里才写的, 纯 checkout(如 CI)
        #   里它必然还不存在 —— 此时"为空"是"待部署"而非"不一致", 判失败会让 CI 在干净仓库上
        #   必然挂。已部署过(k8s_deploy 有断点)才做非空断言。
        #   `.deploy.state` 在 .gitignore 内, 故 CI 上恒不存在, 本条自动跳过。
        KV_DEPLOYED=0
        if [ -f "${REPO_ROOT}/deployments/config/.deploy.state" ] && \
           grep -q '^k8s_deploy=' "${REPO_ROOT}/deployments/config/.deploy.state" 2>/dev/null; then
            KV_DEPLOYED=1
        fi

        if [ "${KV_DEPLOYED}" = "1" ]; then
            [ -n "${kv_addr}" ] || ck_fail "KUBE_VIP_ENABLED=true 但 kube_vip_address 为空(静态 Pod 拿不到 VIP, 证书 SAN 也会丢 VIP)" \
                "      → 修法: 重跑 tools/k8s/sync-kubespray-config.sh(K8S_API_VIP 留空会自动推导)"
        fi

        # VIP 不得落在 MetalLB 地址池内
        if [ -n "${K8S_API_VIP:-}" ] && [ -n "${METALLB_POOL:-}" ]; then
            case "${METALLB_POOL}" in
                *-*) _lo="${METALLB_POOL%%-*}"; _hi="${METALLB_POOL##*-}"
                     # 本脚本不 source lib-common, 自带一个最小 IP→整数转换
                     _ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }
                     if [ "$(_ip2int "${K8S_API_VIP}")" -ge "$(_ip2int "${_lo}")" ] && \
                        [ "$(_ip2int "${K8S_API_VIP}")" -le "$(_ip2int "${_hi}")" ]; then
                         ck_fail "K8S_API_VIP=${K8S_API_VIP} 落在 METALLB_POOL=${METALLB_POOL} 内" \
                             "      → MetalLB 可能把它分配给某个 Service, 抢走控制平面入口"
                     fi
                     unset _lo _hi ;;
            esac
        fi
        # 存量两阶段: 入口尚未切到 VIP 时是**正常**的阶段一状态, 只提示不判失败
        if [ -n "${kv_addr}" ] && [ -n "${lb_addr}" ] && [ "${kv_addr}" != "${lb_addr}" ]; then
            say "  ℹ️ API 入口(${lb_addr})≠ kube_vip_address(${kv_addr}) —— 阶段一状态(VIP 就位后重跑即切换)"
        fi
        [ "${FAIL}" = "0" ] && ok "kube-vip 配置自洽(单一写入者契约成立, VIP=${kv_addr:-<未设置>}, 已部署=${KV_DEPLOYED})"
    fi
else
    say "  KUBE_VIP_ENABLED≠true —— 跳过启用态断言(⑪-A 的单一写入者契约不受开关影响, 仍已校验)"
fi

# ---------- ⑫ ceph 磁盘链路回归测试(离线 stub, 不连真机) ----------
# 为什么放进静态校验: ceph-disk-classify.py / ceph-cleanup.sh 是**会销毁磁盘数据**的代码,
# 判错一类盘就是毁一块业务盘。它们的判定分支(整盘 LVM PV、未激活 VG、混合盘、nbd…)
# 在普通 fixture 里造不出来、在真机上又不敢试 —— 所以用 stub ssh + lsblk fixture 驱动真实
# 脚本, 把"选哪些盘 / 拒哪些盘 / 远端载荷"全断言一遍。用例已做过变异验证(故意改坏判定会红)。
say "[12/15] ceph 磁盘链路回归测试(离线 stub) ..."
CEPH_TEST_SH="${SCRIPT_DIR}/tests/ceph-disk-tests.sh"
if [ -f "${CEPH_TEST_SH}" ]; then
    if CEPH_TEST_OUT="$(bash "${CEPH_TEST_SH}" 2>&1)"; then
        ok "$(grep -E '通过 [0-9]+' <<< "${CEPH_TEST_OUT}" | tail -1)"
    else
        printf '%s\n' "${CEPH_TEST_OUT}" | sed 's/^/    /'
        ck_fail "ceph 磁盘链路回归测试未通过(详见上方失败项)"
    fi
    unset CEPH_TEST_OUT
else
    warn "  跳过(未找到 ${CEPH_TEST_SH})"
fi

# ---------- ⑬ API 入口: 本地代理语义与 all.yml 的自洽 ----------
# 背景: kubespray 的 kube_apiserver_endpoint 模板里 `loadbalancer_apiserver is defined` 分支
#   **优先于** localhost 分支 —— 只要 all.yml 里还有**未注释**的 loadbalancer_apiserver 块,
#   kubelet 就仍走 <域名>:6443, 本地代理(nginx-proxy 静态 Pod)装了也没有流量 = **静默假修复**。
# 判据(裁定 R11): 看 all.yml **自身两个字段是否自洽**, 而不是"配置开关开了就必须注释"。
#   这两个字段由 tools/k8s/sync-kubespray-config.sh **同一次写入**成对落盘:
#     本地代理开 → loadbalancer_apiserver_localhost: true  + 块被注释
#     本地代理关 → loadbalancer_apiserver_localhost: false + 块取消注释
#   所以:
#     localhost: true  ⇒ 块必须处于注释态; 否则**真违规**(kubespray 按本地代理装了, 却仍走域名单点)
#     localhost ≠ true ⇒ 属"尚未同步到本地代理语义"(纯 checkout / 开发机的常态) —— 只提示跳过
#   为什么不用配置开关当门: 本地工作副本还没跑过 sync, all.yml 仍是旧形态, 用开关当门会在
#   干净仓库上必然误报(⑪ 已因同一根因提示着, 再加一条只是噪音)。开关值仅在诊断信息里出现。
say "[13/15] API 入口: 本地代理语义与 all.yml 一致性 ..."
API_HA_BAD=0
if [ ! -f "${KV_ALL_YML}" ]; then
    warn "  未找到 ${KV_ALL_YML}, 跳过 ⑬(未生成 inventory?)"
else
    # 与 ⑪ 读的是同一个文件(KV_ALL_YML 在上方已推导), 不重复定义路径
    lb_localhost="$(awk -F': *' '/^loadbalancer_apiserver_localhost:/{print $2; exit}' "${KV_ALL_YML}" | tr -d '[:space:]')"
    if [ "${lb_localhost}" = "true" ]; then
        if grep -qE '^loadbalancer_apiserver:[[:space:]]*$' "${KV_ALL_YML}"; then
            ck_fail "all.yml 自相矛盾: loadbalancer_apiserver_localhost=true 但 loadbalancer_apiserver 块未注释" \
                "      → kubespray 走域名单点分支, 节点本地代理形同虚设(静默假修复; 配置开关 API_LOCAL_LB_ENABLED=${_LOCAL_LB_TXT})" \
                "      → 修法: 重跑 tools/k8s/sync-kubespray-config.sh(它会按开关成对改写这两个字段)"
            API_HA_BAD=1
        else
            ok "  ⑬ all.yml 本地代理语义自洽(localhost=true 且 loadbalancer_apiserver 块已注释)"
        fi
    else
        if [ "${_LOCAL_LB}" = "1" ]; then
            say "  all.yml 的 loadbalancer_apiserver_localhost≠true(现值: ${lb_localhost:-<未设置>}) —— 尚未同步到本地代理语义, 跳过 ⑬"
        else
            say "  loadbalancer_apiserver_localhost≠true 且本地代理开关=${_LOCAL_LB_TXT} —— 跳过 ⑬(节点走 loadbalancer_apiserver 块的回退形态)"
        fi
    fi
fi

# ---------- ⑭ 离线预加载: PRELOAD_IMAGE_PATTERNS 四处副本一致性(裁定 R6) ----------
# 不变量(Global Constraints): 同一份模式串必须在**四处逐字节一致** ——
#   ① deployments/config/cluster.conf                             本地部署配置(未纳入 git, 含密码)
#   ② deployments/config/cluster.conf.example                     模板(随 git 分发; CI 上唯一在场的那份)
#   ③ deployments/scripts/tools/offline/trim-offline-files.sh:41  备料时**真正执行** trim 用的默认值
#   ④ deployments/kubespray/cubestack-offline.sh               standalone 直跑预加载脚本时的内置兜底
#      (该文件里有两条赋值: 上面那条是环境变量透传, 底下 elif 分支里的才是内置默认模式串 ——
#       断言取后者, 见 _preload_patterns 的说明)
# 为什么必须有这一条: 既有 CI 只覆盖「trim ↔ images.manifest」一对(check-image-manifest.sh ⑤),
#   漂移若只发生在 ①/②, CI 照样通过 → 联网机备料后镜像**仍被静默 trim 掉**(装了却没有镜像)。
# 比较的是**模式串本身**(各处变量名可能不同), 不是整行; 引号/行尾注释等写法差异先归一化掉。
# 注: 第 ④ 份曾长期陈旧(缺 lws_manager / library_nginx), 2026-09-28 Task 7 已补齐并与前三分逐字节相同,
#     故自本轮起纳入断言(此前注释写的"有意不纳入"已过期)。
say "[14/15] PRELOAD_IMAGE_PATTERNS 四处副本一致性 ..."

# 取某个文件里 PRELOAD_IMAGE_PATTERNS 的**模式串本身**(取不到时输出空串, 由调用方判存在性)。
# 兼容三种写法: PRELOAD_IMAGE_PATTERNS="${VAR:-<串>}"(本仓库四处均如此) / "<串>" / <串>
# ⚠ 一个文件里可能有**多条**赋值行: cubestack-offline.sh 上面那条是"环境变量透传"
#   (PRELOAD_IMAGE_PATTERNS="${CUBESTACK_PRELOAD_IMAGE_PATTERNS}"), elif 分支里那条才是内置默认模式串。
#   断言要的是后者 —— 故逐条扫描并**跳过解不出字面量的 ${...} 引用行**(只取 -m1 会拿到透传行 → 假红)。
_preload_patterns() {
    local line v
    while IFS= read -r line; do
        v="${line#*=}"                               # 去键名
        v="${v%%[[:space:]]#*}"                      # 去行尾注释(模式串里不含 ' #')
        v="${v%"${v##*[![:space:]]}"}"               # 去尾随空白
        v="${v#\"}"; v="${v%\"}"                     # 去包裹引号
        case "${v}" in '${'*:-*) v="${v#*:-}"; v="${v%\}}" ;; esac   # 去 ${VAR:- ... } 包装
        case "${v}" in '${'*) continue ;; esac       # 仍是 ${...} 引用(纯透传行) → 解不出, 看下一条
        printf '%s' "${v}"; return 0
    done < <(grep '^[[:space:]]*PRELOAD_IMAGE_PATTERNS=' "$1" 2>/dev/null || true)
    return 0
}

PRELOAD_BAD=0; PRELOAD_N=0
PRELOAD_PATHS=(
    "${REPO_ROOT}/deployments/config/cluster.conf"
    "${CONF_EXAMPLE}"
    "${REPO_ROOT}/deployments/scripts/tools/offline/trim-offline-files.sh"
    "${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
)
PRELOAD_NAMES=( cluster.conf cluster.conf.example trim-offline-files.sh cubestack-offline.sh )
PRELOAD_VALS=(); PRELOAD_SEEN=()
for _i in "${!PRELOAD_PATHS[@]}"; do
    _p="${PRELOAD_PATHS[$_i]}"; _n="${PRELOAD_NAMES[$_i]}"
    if [ ! -f "${_p}" ]; then
        warn "  未找到 ${_p}(跳过该副本; cluster.conf 不入库, CI 上属正常)"
        continue
    fi
    _v="$(_preload_patterns "${_p}")"
    if [ -z "${_v}" ]; then
        ck_fail "⑭ ${_n}: 解析不出 PRELOAD_IMAGE_PATTERNS 的取值" \
            "      → 赋值行应形如 PRELOAD_IMAGE_PATTERNS=\"\${VAR:-<模式串>}\""
        PRELOAD_BAD=1
        continue
    fi
    PRELOAD_VALS+=("${_v}"); PRELOAD_SEEN+=("${_n}"); PRELOAD_N=$((PRELOAD_N + 1))
done

if [ "${PRELOAD_N}" -ge 2 ]; then
    _ref="${PRELOAD_VALS[0]}"; _drift=0
    for _j in "${!PRELOAD_VALS[@]}"; do
        [ "${PRELOAD_VALS[$_j]}" = "${_ref}" ] || _drift=1
    done
    if [ "${_drift}" = "1" ]; then
        ck_fail "PRELOAD_IMAGE_PATTERNS 各副本不一致(必须逐字节一字不差; 漂移会让镜像被备料静默 trim 掉)" \
            "      → 修法: 把四处改成同一份模式串(新增镜像时四处都要加)"
        for _j in "${!PRELOAD_VALS[@]}"; do
            bad "      ${PRELOAD_SEEN[$_j]}(${#PRELOAD_VALS[$_j]} 字符): ${PRELOAD_VALS[$_j]}"
        done
        PRELOAD_BAD=1
    fi
else
    say "  可用副本不足 2 份(共 ${PRELOAD_N} 份) —— 跳过 ⑭"
fi
[ "${PRELOAD_BAD}" = "0" ] && [ "${PRELOAD_N}" -ge 2 ] && \
    ok "  ⑭ PRELOAD_IMAGE_PATTERNS ${PRELOAD_N} 份副本逐字节一致(${#PRELOAD_VALS[0]} 字符)"
unset _i _j _p _n _v _ref _drift

# ---------- ⑮ kubespray 补丁在位(树被换/被覆盖过就能查出来) ----------
# 补丁层 = deployments/kubespray/cubestack-patches/*.patch(我们对 vendored kubespray 树的全部源码改动);
# 判据 = cubestack-patch-apply.sh --check:全在位则静默 rc=0, 缺位打印 MISSING 并 rc=1。
# 为什么必须有这一条: 换树/手工覆盖树之后, 补丁若没重放, 部署**照样能跑**但缺我们的修复
#   (metallb CRD 竞态 / registry 顺序 / 离线备料建目录 / SAN 与 join 守卫…), 属静默降级。
# 见 docs/kubespray-upgrade.md(升级 SOP 与历次记录)。
say "[15/15] kubespray 补丁在位 ..."
if [ -x "${REPO_ROOT}/deployments/kubespray/cubestack-patch-apply.sh" ]; then
    if _out="$(bash "${REPO_ROOT}/deployments/kubespray/cubestack-patch-apply.sh" --check 2>&1)"; then
        ok "  ⑮ kubespray 补丁全部在位"
    else
        ck_fail "⑮ kubespray 补丁缺失/不匹配:" "$(printf '%s' "${_out}" | grep -E 'MISSING|CONFLICT' | head -5)"
    fi
else
    warn "  跳过 ⑮(未找到 cubestack-patch-apply.sh)"
fi

echo "---------------------------------------------"
if [ "${FAIL}" = "0" ]; then
    ok "模块校验全部通过(${#ALLKEYS[@]} 个模块)"
    exit 0
else
    bad "模块校验存在违规(${FAIL} 类问题), 修复后重试"
    exit 1
fi
