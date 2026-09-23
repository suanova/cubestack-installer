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
say "[1/11] bash -n 语法检查 ..."
SYNTAX_FAIL=0
while IFS= read -r -d '' f; do
    bash -n "$f" 2>/dev/null || { bad "语法错误: ${f#$MODULES_DIR/}"; SYNTAX_FAIL=1; FAIL=1; }
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${SYNTAX_FAIL}" = "0" ] && ok "全部 $(find "${MODULES_DIR}" -name '*.sh' | wc -l) 个模块语法通过"

# ---------- 元数据解析(与 lib-module.sh 同规则) ----------
meta() { sed -nE "s/^#[[:space:]]*${2}:[[:space:]]*(.*)$/\1/p" "$1" | head -1; }
phase_dir() { case "$(basename "$(dirname "$1")")" in
    01_env) echo "env";; 02_k8s) echo "k8s";; 03_addon) echo "addon";; *) echo "?";; esac; }

say "[2/11] 头部元数据齐全性 ..."
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

say "[3/11] MODULE key 唯一性 ..."   # 已在上面检查, 这里输出结果
[ "${FAIL}" = "0" ] || true

say "[4/11] PHASE 合法性 + 目录一致性 ..."
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    ph="$(meta "$f" PHASE)"
    case "${ph}" in env|k8s|addon) ;; *) ck_fail "${rel}: PHASE=${ph:-<空>} 非法(需 env/k8s/addon)";; esac
    [ "${ph}" = "$(phase_dir "$f")" ] || ck_fail "${rel}: PHASE=${ph} 与目录 $(basename "$(dirname "$f")") 不一致"
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${FAIL}" = "0" ] || true

# ---------- ⑤ REQUIRES 引用 + 全量拓扑 ----------
say "[5/11] REQUIRES 引用存在性 + 全量无环 ..."
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
say "[6/11] 远端 kubectl 初始化(K/SSH)调用检查 ..."
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
say "[7/11] TOGGLE 变量在 cluster.conf.example 声明 ..."
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
say "[8/11] 文件名序号规范(NN_ 前缀) ..."
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
say "[9/11] tools/ 工具脚本语法检查 ..."
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
# 为什么要有这一条: 31_cubepilot 原本**写了**"私服拉取失败就回退本地 chart",
# 但仓库里压根没有那份文件 —— 私服一抖动, 回退就是空转, 回退代码形同虚设。
# 光靠文档挡不住这种缺失(写的时候都以为回退能兜住), 所以放进静态校验。
say "[10/11] helm chart 离线副本检查 ..."
ADDON_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)/deployments/cubestack-addon"
CHART_FAIL=0; CHART_WARN=0; CHART_OKN=0
# 判据: **行首就是 helm 命令** —— 只排除注释不够, 变量/err 字符串里提到
#   "helm upgrade --install" 的地方(如 32_verify_cubepilot 的排查提示)会被误判成"装了 chart"。
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
say "[11/11] kube-vip 控制平面 VIP 配置检查 ..."
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
KV_ADDONS="${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster/group_vars/k8s_cluster/addons.yml"
KV_ALL_YML="${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster/group_vars/all/all.yml"
KV_CONF="${REPO_ROOT}/deployments/config/cluster.conf"
[ -f "${KV_CONF}" ] || KV_CONF="${CONF_EXAMPLE}"
# 在**子 shell 内**求值 cluster.conf, 只回传需要的三个值。理由:
#   ① cluster.conf 依赖 REPO_ROOT 等多个变量, 在当前 set -u 下直接 source 会中断;
#      子 shell 里 set +u 给它宽松环境, 且不污染本脚本状态(本脚本有 FAIL 等同名变量)
#   ② 用 shell 自己解析(而非正则抠字符串), 才能正确处理 "${VAR:-default}" / 字面量 / 注释
KV_SNAPSHOT="$(
    set +u
    REPO_ROOT="${REPO_ROOT}" SCRIPT_DIR="${SCRIPT_DIR}" CONF_EXAMPLE="${CONF_EXAMPLE}"
    # shellcheck disable=SC1090
    . "${KV_CONF}" >/dev/null 2>&1 || true
    printf '%s\n%s\n%s\n' \
        "${KUBE_VIP_ENABLED:-true}" "${K8S_API_VIP:-}" "${METALLB_POOL:-}"
)"
KUBE_VIP_ENABLED="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 1p)"
K8S_API_VIP="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 2p)"
METALLB_POOL="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 3p)"
unset KV_SNAPSHOT

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

# ⑪-B 开关**开启**时才有意义的取值自洽(关闭态那些值会连同 VIP 一起经清理路径收敛掉)
if [ "${KUBE_VIP_ENABLED:-true}" = "true" ]; then
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

echo "---------------------------------------------"
if [ "${FAIL}" = "0" ]; then
    ok "模块校验全部通过(${#ALLKEYS[@]} 个模块)"
    exit 0
else
    bad "模块校验存在违规(${FAIL} 类问题), 修复后重试"
    exit 1
fi
