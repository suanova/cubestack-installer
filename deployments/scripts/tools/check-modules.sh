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
#   ⑨ tools/ 与 deployments/kubespray/ 顶格脚本 bash -n 通过
#   ⑩ 安装 helm chart 的模块必须有 vendored 离线副本
#   ⑪ kube-vip: 写入者契约(kube_vip_enabled 必须**跟随** KUBE_VIP_ENABLED —— 2026-09-28 收编后静态 Pod
#      改由 kubespray 渲染)+ 启用时取值自洽(address / 不与 MetalLB 抢地址)
#   ⑬ API 入口: all.yml 本地代理语义自洽(localhost: true ⇒ loadbalancer_apiserver 块必须被注释)
#   ⑭ 离线预加载: PRELOAD_IMAGE_PATTERNS 四处副本逐字节一致(漂移会被备料静默 trim 掉)
#   ⑮ kubespray 补丁在位(cubestack-patch-apply.sh --check 全绿; 换树后没重放会静默降级)
#      + 两个离线回归套件(tests/test-kubespray-patches.sh、test-update-kube-vip-addons.sh)实跑通过
#   ⑯ k8s 基座钉子闭环(三件):
#      A) 钉子 vs 上游树内表值 —— cluster.conf 的 K8S/CALICO/ETCD/COREDNS/PAUSE/DNS_NODE_CACHE/
#         METRICS_SERVER/CPA/LOCAL_VOLUME_PROVISIONER/NFD + API_LB_NGINX_IMAGE_TAG 必须与
#         vendored kubespray 的表一致
#         (只判一致, 期望值现算不写死; 换树/换钉子即报)
#      B) 两个无模块开关键(LOCAL_VOLUME_PROVISIONER_ENABLED / NFD_ENABLED)的 .example 默认声明
#      C) **写入者闭环**: inventory 的 group_vars/all/k8s-versions.yml 里 10 个 kubespray 版本变量
#         确实存在且 == cluster.conf 的钉子(写入者 = tools/k8s/sync-kubespray-config.sh 3.2 节)
#      A 只证"钉子自洽"(== 表值), C 才证"部署真会用钉子"; 缺 C 时删掉写入节/改错值照样全绿。
#   ⑰ 凭据卫生: 含密钥的"生成物"(external-ceph 导出 / minio.conf / cluster.conf)必须**未被 git 跟踪**
#      且被 .gitignore 覆盖 —— ⚠ 忽略规则对**已跟踪**文件无效, "看着封堵了"≠"封堵了"
#   ⑱ 版本目录 ↔ 档案闭合: 入库档案逐版本 ↔ 其树表值; 在场版本目录的 VERSION.profile ↔ 入库档案、
#      tree.tar.gz 指纹、关键二进制与 K8S_VERSION 匹配、LOCAL_ONLY 语义自洽(无目录则跳过)
#      (设计 docs/kubespray-versioning/design.md; 反证见 tools/tests/test-kubespray-version-select.sh 同类夹具)
# 用法: bash check-modules.sh           # 校验全部模块(只读, 无需 root)
#       bash check-modules.sh --quiet   # 只输出违规项
# 退出码: 0=全部通过; 1=存在违规(列出清单)
# CI: .github/workflows/ci-validate.yml 在每次 PR / 推送 main 时跑本脚本(全 17 项);
#     同一条命令本地可复现 —— 见 docs/scripts-development-spec.md §7。
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

FAIL=0
ck_fail() { bad "$*"; FAIL=1; }

say "==== 模块静态校验(${MODULES_DIR}) ===="

# ---------- ① bash -n 语法 ----------
say "[1/18] bash -n 语法检查 ..."
SYNTAX_FAIL=0
while IFS= read -r -d '' f; do
    bash -n "$f" 2>/dev/null || { bad "语法错误: ${f#$MODULES_DIR/}"; SYNTAX_FAIL=1; FAIL=1; }
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${SYNTAX_FAIL}" = "0" ] && ok "全部 $(find "${MODULES_DIR}" -name '*.sh' | wc -l) 个模块语法通过"

# ---------- 元数据解析(与 lib-module.sh 同规则) ----------
meta() { sed -nE "s/^#[[:space:]]*${2}:[[:space:]]*(.*)$/\1/p" "$1" | head -1; }
phase_dir() { case "$(basename "$(dirname "$1")")" in
    01_env) echo "env";; 02_k8s) echo "k8s";; 03_addon) echo "addon";; *) echo "?";; esac; }

say "[2/18] 头部元数据齐全性 ..."
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

say "[3/18] MODULE key 唯一性 ..."   # 已在上面检查, 这里输出结果
[ "${FAIL}" = "0" ] || true

say "[4/18] PHASE 合法性 + 目录一致性 ..."
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    ph="$(meta "$f" PHASE)"
    case "${ph}" in env|k8s|addon) ;; *) ck_fail "${rel}: PHASE=${ph:-<空>} 非法(需 env/k8s/addon)";; esac
    [ "${ph}" = "$(phase_dir "$f")" ] || ck_fail "${rel}: PHASE=${ph} 与目录 $(basename "$(dirname "$f")") 不一致"
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
[ "${FAIL}" = "0" ] || true

# ---------- ⑤ REQUIRES 引用 + 全量拓扑 ----------
say "[5/18] REQUIRES 引用存在性 + 全量无环 ..."
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
say "[6/18] 远端 kubectl 初始化(K/SSH)调用检查 ..."
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
say "[7/18] TOGGLE 变量在 cluster.conf.example 声明 ..."
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
say "[8/18] 文件名序号规范(NN_ 前缀) ..."
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
# ★ 2026-09-28(评审 I6): 范围补上 deployments/kubespray/ 的**顶格**入口脚本(cubestack-offline.sh /
#   cubestack-patch-apply.sh / cubestack-kubespray-upgrade.sh)—— 它们既不是模块也不在 scripts/ 下,
#   于是本支新增的两个脚本从未被 bash -n 过(写错一行要到实机升级时才发现)。
#   只取**顶格一层**: vendored 树与 cubestack-patches/ 里的 .sh 属上游/数据文件, 不归本项管。
say "[9/18] tools/ + kubespray 入口脚本语法检查 ..."
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
KSD_SH_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)/deployments/kubespray"
SH_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
T_FAIL=0
T_N=0
while IFS= read -r -d '' f; do
    bash -n "$f" 2>/dev/null || { ck_fail "语法错误: ${f#${SH_ROOT}/}"; T_FAIL=1; }
    T_N=$((T_N + 1))
done < <(find "${TOOLS_DIR}" -name '*.sh' -print0; find "${KSD_SH_DIR}" -maxdepth 1 -name '*.sh' -print0)
[ "${T_FAIL}" = "0" ] && ok "全部 ${T_N} 个 tools/kubespray 脚本语法通过"
unset SH_ROOT 2>/dev/null || true

# ---------- ⑩ helm chart 离线副本(全仓库约定) ----------
# 规则: 凡安装 helm chart 的模块, 其 chart **必须有一份 vendored 在 deployments/cubestack-addon/**
# 下并随 git 分发 —— 模块安装时**恒用这份本地副本**, 在线只用于比对刷新
# (见 lib-common 的 helm_chart_ensure, 以及 docs/scripts-development-spec.md §2.4)。
# 为什么要有这一条: 曾有模块**写了**"私服拉取失败就回退本地 chart",
# 但仓库里压根没有那份文件 —— 私服一抖动, 回退就是空转, 回退代码形同虚设。
# 光靠文档挡不住这种缺失(写的时候都以为回退能兜住), 所以放进静态校验。
say "[10/18] helm chart 离线副本检查 ..."
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
say "[11/18] kube-vip 控制平面 VIP 配置检查 ..."
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

# ⑪-A kube-vip 写入者契约(2026-09-28 收编后)—— addons.yml 的 kube_vip_enabled 必须**跟随** KUBE_VIP_ENABLED:
#   静态 Pod 改由 kubespray 渲染(roles/kubernetes/node/tasks/loadbalancer/kube-vip.yml), 我们的
#   02_k8s/09_kube_vip.sh 只负责 VIP 推导/变量校验/收敛核验/关闭清理。两者不一致的后果:
#   开关开着而 inventory 里是 false → 静态 Pod 永不出现; 开关关了而 inventory 里是 true →
#   kubespray 每轮把清单写回来, 我们的清理白做。
#   历史: 2026-09-22~09-28 此处曾是"恒 false"的单一写入者契约(自持渲染器已删除, 见 docs/api-ha/07)。
#   注: 纯 checkout(CI)里该键来自 kubespray 模板(false), 与 cluster.conf.example 的默认 false 一致 ⇒ 不误报。
if [ ! -f "${KV_ADDONS}" ]; then
    warn "  未找到 ${KV_ADDONS}, 跳过 kube-vip 契约校验(未生成 inventory?)"
else
    kv_en="$(awk -F': *' '/^kube_vip_enabled:/{print $2; exit}' "${KV_ADDONS}")"
    kv_svc="$(awk -F': *' '/^kube_vip_services_enabled:/{print $2; exit}' "${KV_ADDONS}")"
    kv_addr_chk="$(awk -F': *' '/^kube_vip_address:/{print $2; exit}' "${KV_ADDONS}")"
    _kv_want="${KUBE_VIP_ENABLED:-false}"
    # ★ 门禁看**实际同步过没有**, 不看配置开关(与 ⑪-B 同一哲学): kube_vip_address 是 sync 在
    #   部署流程里才写的 ⇒ 它为空就意味着"这份 inventory 还没按当前 cluster.conf 同步过",
    #   此时开关与存量值不一致属"待同步"而非"写错了"。仅在**已同步**(address 非空)时才硬判 ——
    #   那时两者还不一致才是真 bug(kubespray 每轮把清单写回/或永不渲染)。
    #   注: 仓库里那份 tracked 示例 inventory(10.244.x)与本机未入库的 cluster.conf 常处于此形态。
    if [ -n "${kv_en}" ] && [ "${kv_en}" != "${_kv_want}" ]; then
        if [ -z "${kv_addr_chk}" ]; then
            say "  ℹ️ inventory 的 kube_vip_enabled=${kv_en} ≠ cluster.conf 的 ${_kv_want}: 该 inventory 尚未同步(kube_vip_address 为空)⇒ 视为待同步, 不判失败"
        else
            ck_fail "addons.yml 的 kube_vip_enabled=${kv_en} 与 cluster.conf 的 KUBE_VIP_ENABLED=${_kv_want} 不一致(且 inventory 已同步过)" \
                "      → 静态 Pod 由 kubespray 按该键渲染: 不一致会得到『开关开着却没有 VIP』或『关掉了清单又被写回』" \
                "      → 修法: 重跑 tools/k8s/sync-kubespray-config.sh(按 cluster.conf 重写该块); 详见 docs/api-ha/07"
        fi
    fi
    # 无条件违规项: 与是否部署过无关, 只要写进 inventory 就是错的
    if [ "${kv_svc}" = "true" ]; then
        ck_fail "kube_vip_services_enabled=true —— kube-vip 与 MetalLB 都在实现 LoadBalancer, 会互相抢地址" \
            "      → 服务 LB 归 MetalLB(见 docs/kube-vip-api-ha.md 决策 D1); 修法: 置 false 后重跑 sync"
    fi
fi

# ⑪-C 兜底默认一致性(2026-09-24 增补; 2026-09-28 收编后去掉渲染器那处): 同一个开关的**默认值**
#   散落在多处兜底里 —— cluster.conf.example(模板) / 09_kube_vip.sh(前置校验与清理) /
#   lib-common.sh(addons.yml 写入)。改默认时漏改一处 → 行为随调用路径漂移
#   (本仓库实测踩过: 文档与代码不同步; KUBE_VIP_ENABLED 当年也是改了 11 处兜底才一致)。
#   这里只断言"各处彼此一致", **不写死具体值** —— 将来再翻转也不会误报。
_cpd="$(grep -rhoE 'KUBE_VIP_CP_DETECT:-[a-z]+' \
        "${CONF_EXAMPLE}" \
        "${REPO_ROOT}/deployments/scripts/modules/02_k8s/09_kube_vip.sh" \
        "${REPO_ROOT}/deployments/scripts/lib-common.sh" 2>/dev/null | sed 's/.*:-//' | sort -u)"
if [ -n "${_cpd}" ] && [ "$(printf '%s\n' "${_cpd}" | grep -c .)" = "1" ]; then
    ok "KUBE_VIP_CP_DETECT 各处兜底默认一致(${_cpd})"
else
    ck_fail "KUBE_VIP_CP_DETECT 兜底默认不一致: [${_cpd:-未取到}]" \
        "      → 改默认须同时改: cluster.conf.example / 02_k8s/09_kube_vip.sh / lib-common.sh"
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
        [ "${FAIL}" = "0" ] && ok "kube-vip 配置自洽(开关↔inventory 一致, VIP=${kv_addr:-<未设置>}, 已部署=${KV_DEPLOYED})"
    fi
else
    say "  KUBE_VIP_ENABLED≠true —— 跳过启用态断言(⑪-A 的单一写入者契约不受开关影响, 仍已校验)"
fi

# ---------- ⑫ ceph 磁盘链路回归测试(离线 stub, 不连真机) ----------
# 为什么放进静态校验: ceph-disk-classify.py / ceph-cleanup.sh 是**会销毁磁盘数据**的代码,
# 判错一类盘就是毁一块业务盘。它们的判定分支(整盘 LVM PV、未激活 VG、混合盘、nbd…)
# 在普通 fixture 里造不出来、在真机上又不敢试 —— 所以用 stub ssh + lsblk fixture 驱动真实
# 脚本, 把"选哪些盘 / 拒哪些盘 / 远端载荷"全断言一遍。用例已做过变异验证(故意改坏判定会红)。
say "[12/18] ceph 磁盘链路回归测试(离线 stub) ..."
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
say "[13/18] API 入口: 本地代理语义与 all.yml 一致性 ..."
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
say "[14/18] PRELOAD_IMAGE_PATTERNS 四处副本一致性 ..."

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
say "[15/18] kubespray 补丁在位 + 离线套件 ..."
if [ -x "${REPO_ROOT}/deployments/kubespray/cubestack-patch-apply.sh" ]; then
    if _out="$(bash "${REPO_ROOT}/deployments/kubespray/cubestack-patch-apply.sh" --check 2>&1)"; then
        ok "  ⑮ kubespray 补丁全部在位"
    else
        ck_fail "⑮ kubespray 补丁缺失/不匹配:" "$(printf '%s' "${_out}" | grep -E 'MISSING|CONFLICT' | head -5)"
    fi
else
    warn "  跳过 ⑮(未找到 cubestack-patch-apply.sh)"
fi
# ★ 2026-09-28(评审 I6): 离线回归套件此前**无人调度** —— 写了就当"有测试", 但全仓没有任何入口
#   会跑它们(当时本仓库还没有 CI)→ 回归等于不存在。挂在这里正合适: ⑮ 本就是"补丁层可用的证据", 而这些
#   套件正是它的回归(test-kubespray-patches 覆盖重放器三态/退休判定;
#   test-update-kube-vip-addons 覆盖 2026-09-28 收编后的开关↔addons.yml 映射与幂等)。
# ★ 2026-09-30: CI 已落地(.github/workflows/ci-validate.yml)⇒ 本项全 17 项现在每次 PR 都跑,
#   这些套件不再依赖"人记得跑"。⚠ 套件本身必须**入库**: test-update-kube-vip-addons.sh 曾被
#   .gitignore 的"整个 tests/ 目录忽略"规则吞掉(从未提交)而 ⑮ 对缺失是硬失败 —— 上 CI 才发现;
#   现规则只放行 test-*.sh, 新增套件若发现"本地绿、CI 红", 先查 git ls-files 里有没有它。
#   两者都只用仓库内 fixture, 不联网、不碰集群, 秒级完成。
#   ⚠ 任一失败即 ck_fail(与 ⑮ 主判据同口径): 套件跑不起来 = 没有证据, 不能算通过。
# ★ 2026-09-28: 把 api-ha 线写的三个套件也挂进来 —— 它们此前**从来没被调度过** ⇒ test-sync-api-entry
#   在 sync 新增"10 个版本钉子"要求后静默变红(用例 ⑤ 断言退出码)而无人发现。这四类回归
#   (补丁层 / 收编映射 / 入口模式 / 本地代理)现在每轮 check-modules 都会跑到。
for _t in test-kubespray-patches.sh test-update-kube-vip-addons.sh \
           test-api-entry-mode.sh test-api-local-lb.sh test-sync-api-entry.sh \
           test-kubespray-version-select.sh; do
    _tp="${REPO_ROOT}/deployments/scripts/tools/tests/${_t}"
    if [ ! -f "${_tp}" ]; then
        ck_fail "⑮ 离线套件缺失: ${_tp#${REPO_ROOT}/}(⑮ 的回归证据没了)"
    elif _tout="$(bash "${_tp}" 2>&1)"; then
        ok "  ⑮ 离线套件通过: ${_t}"
    else
        ck_fail "⑮ 离线套件失败: ${_t}" "$(printf '%s' "${_tout}" | grep -E '^  FAIL' | head -5)"
    fi
done
unset _t _tp _tout 2>/dev/null || true

# ---------- ⑯ k8s 基座钉子闭环: A 钉子 vs 树内表值 / B 无模块开关键 / C 写入者(inventory) ----------
# 为什么必须有 A: cluster.conf 的"k8s 基座组"是**显式钉子**(离线 tar / Harbor 同步需要确定的
#   ref —— images.manifest 直接以 ${VAR} 引用它们), 而它们的真值在 vendored kubespray 的版本表里。
#   两边漂移时**部署期才发现**: 表里没有该补丁 / addon 版本与表不符 → 离线集群拉不到镜像。
#   人工抄表必然出错(版本靠人记), 所以这里每次跑 check 都**从树内表机械重算一遍**期望值。
#   ⚠ 与 ⑪-C 同原则: **不写死任何期望值** —— 换树/换钉子后本项自动给出新的期望值。
# 期望值取法(与上游 kubespray 的解析式逐条对应; 上游用 Jinja 求值, 这里用 awk 复刻同一语义):
#   K8S_VERSION            → kubelet_checksums 表**成员判定**。上游 kube_version 默认取表首(=最新线,
#                            当前 1.36.4), 而我们**有意**钉在 1.35 线(设计 D1: 1.33 不可用、1.36
#                            生态兼容面窄), 故只断言"钉值在表内" —— 与 cubestack-kubespray-upgrade.sh
#                            [4/8] 的核验口径一致(它也只判成员)。
#   CALICO_VERSION         → calicoctl_binary_checksums['amd64'] 首键(上游 calico_version 的定义)
#   ETCD_VERSION           → etcd_supported_versions[kube_major] → etcd_binary_checksums 里
#                            **文件顺序首个** < 该线上界 的键(上游 Jinja `select(version, B, '<')[0]`)
#   COREDNS_VERSION        → coredns_supported_versions[kube_major]
#   PAUSE_VERSION          → pod_infra_supported_versions[kube_major](上游 pod_infra_version)
#   DNS_NODE_CACHE_VERSION → nodelocaldns_version
#   METRICS_SERVER_VERSION → metrics_server_version
#   CPA_VERSION            → dnsautoscaler_version(上游镜像 tag 为 v{{ ... }})
#   API_LB_NGINX_IMAGE_TAG → nginx_image_tag(节点侧 API 本地代理静态 Pod; 上游是**带形态的全值**,
#                            不能用 v 前缀规则改写 —— 1.30.1-alpine 是一整个 tag)
#   kube_major 一律由**本文件自己的 K8S_VERSION 钉值**推出(1.35.8 → '1.35'), 故钉子换线时
#   其余 7 项的期望值会跟着换线, 而不是静默沿用旧线。
# ⑯-B(裁定 R23): LOCAL_VOLUME_PROVISIONER_ENABLED / NFD_ENABLED 在 cluster.conf.example 里
#   必须有默认声明 —— 这两个键由 tools/k8s/sync-addons-config.sh 消费、**没有对应模块**, 而
#   ⑦ 是"模块 TOGGLE → example"的单向断言 → 照不到它们, 误删(或漏加)无护栏。
# ⑯-C(2026-09-28 评审 Critical 的闭环): A 只断言"钉子 == 表值"(钉子自洽), **照不到钉子有没有
#   被写进 inventory**。在此之前那 8 个变量在 vendored 树之外**没有任何写入者**, 于是部署按
#   **树内默认**解析(ansible 实测 kube_version=1.36.4 / coredns=1.14.2 / pod_infra=3.10.2),
#   与我们钉的 1.35 线**不是同一套** → 离线 tar 与部署期要的镜像不符, download/validate 阶段
#   响亮失败(与 images.manifest:49 的"必须与 kubespray 实际解析出的版本一致"自相矛盾)。
#   写入者已落地 = tools/k8s/sync-kubespray-config.sh 3.2 节(group_vars/all/k8s-versions.yml),
#   C 断言其产物与钉子逐键一致 —— 删掉写入节 / 手工改错值 / 换了 conf 忘跑 sync 都会被点名。
say "[16/18] k8s 基座钉子闭环(A 树内表值 / B 无模块开关 / C inventory 写入者) ..."

KSD_ROLE="${REPO_ROOT}/deployments/kubespray/kubespray/roles/kubespray_defaults"
KSD_DL="${KSD_ROLE}/defaults/main/download.yml"
KSD_CK="${KSD_ROLE}/vars/main/checksums.yml"
KSD_VM="${KSD_ROLE}/vars/main/main.yml"

# 取 conf 里某变量的**声明值**(支持 VAR="${VAR:-<v>}" / VAR="<v>" / VAR=<v>; 解不出则输出空)。
# 取"声明值"而非 source 结果: 环境里的同名变量不该改变"这个文件钉了什么"的判定。
_ksd_conf_value() {   # <file> <VAR>
    local line v
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" 2>/dev/null | head -1)" || true
    [ -n "${line}" ] || return 0
    v="${line#*=}"
    v="${v%%[[:space:]]#*}"                                   # 去行尾注释
    v="${v%"${v##*[![:space:]]}"}"; v="${v#"${v%%[![:space:]]*}"}"   # trim 两端空白
    v="${v#\"}"; v="${v%\"}"                                  # 去包裹引号
    case "${v}" in '${'*:-*) v="${v#*:-}"; v="${v%\}}" ;; esac  # 去 ${VAR:- ... } 包装
    case "${v}" in '${'*) return 0 ;; esac                    # 仍是 ${...} 引用 → 解不出
    printf '%s' "${v}"
}

# 树内版本表解析(2026-09-30 起下沉到共享库): 口径与 cubestack-version-dir.sh 的档案骨架推导
# 共用一份, 避免"两处各写一套"必漂移(⑯-C 的教训)。库函数显式收文件路径; 下列薄包装保持
# 本脚本既有调用点(KSD_CK/KSD_DL/KSD_VM)不变。
# shellcheck source=../../kubespray/lib-kubespray-tables.sh
source "${REPO_ROOT}/deployments/kubespray/lib-kubespray-tables.sh"
_ksd_first_key()    { kb_tables_first_key "${KSD_CK}" "$@"; }
_ksd_etcd()         { kb_tables_etcd "${KSD_CK}" "${KSD_VM}" "$@"; }
_ksd_inline()       { kb_tables_inline "$@"; }
_ksd_scalar()       { kb_tables_scalar "$@"; }
_ksd_kubelet_has()  { kb_tables_kubelet_has "${KSD_CK}" "$@"; }

KSD_BAD=0
# ⑯-C 的键映射: <cluster.conf 钉子变量>:<kubespray 变量>。
# ⚠ **必须镜像** tools/k8s/sync-kubespray-config.sh 3.2 节的 _vpin_line 调用表(改一处要改两处);
#   顺序与该节一致, 便于人工对照。新增钉子进 cluster.conf 时, 这里与写入节都要加。
KSD_PINS=(
    "K8S_VERSION:kube_version"
    "PAUSE_VERSION:pod_infra_version"
    "COREDNS_VERSION:coredns_version"
    "DNS_NODE_CACHE_VERSION:nodelocaldns_version"
    "METRICS_SERVER_VERSION:metrics_server_version"
    "CPA_VERSION:dnsautoscaler_version"
    "ETCD_VERSION:etcd_version"
    "CALICO_VERSION:calico_version"
    "LOCAL_VOLUME_PROVISIONER_VERSION:local_volume_provisioner_version"
    "NFD_VERSION:node_feature_discovery_version"
)
KSD_INV_YML="${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster/group_vars/all/k8s-versions.yml"
if [ ! -f "${KSD_INV_YML}" ]; then
    ck_fail "⑯-C 未找到 inventory 版本钉子文件: ${KSD_INV_YML#${REPO_ROOT}/}" \
        "      → 它是 ⑯-C 的证据本体: 缺了它, kubespray 按**树内默认**解析版本(与离线 tar 不是一套)," \
        "        部署会在 download/validate 阶段失败; 而 ⑯-A 照样全绿(钉子自洽 ≠ 部署会用钉子)" \
        "      → 修法: 跑 bash deployments/scripts/tools/k8s/gen-inventory.sh(内部调 sync-kubespray-config.sh)"
    KSD_BAD=1
fi
if [ ! -f "${KSD_DL}" ] || [ ! -f "${KSD_CK}" ] || [ ! -f "${KSD_VM}" ]; then
    warn "  跳过 ⑯(未找到 vendored 版本表 ${KSD_ROLE#${REPO_ROOT}/})"
else
    # 钉子来源文件: cluster.conf(在盘上才查; 它不入库) + cluster.conf.example(纯 checkout 上唯一在场的那份)
    KSD_CONFS=("${CONF_EXAMPLE}")
    [ -f "${KV_CONF}" ] && [ "${KV_CONF}" != "${CONF_EXAMPLE}" ] && KSD_CONFS=("${KV_CONF}" "${CONF_EXAMPLE}")

    for _cf in "${KSD_CONFS[@]}"; do
        _cn="$(basename "${_cf}")"
        _k8s="$(_ksd_conf_value "${_cf}" K8S_VERSION)"
        if [ -z "${_k8s}" ]; then
            ck_fail "⑯ ${_cn}: 取不到 K8S_VERSION 的钉值(未声明/写法解不出)"
            KSD_BAD=1; continue
        fi
        _k8s_bare="${_k8s#v}"
        _major="${_k8s_bare%.*}"

        # ---- K8S_VERSION: 表成员判定(不是"等于表首" —— 我们有意钉在 1.35 线, 见上方注释) ----
        if [ "$(_ksd_kubelet_has "${_k8s_bare}")" = "1" ]; then
            # 表范围(跨 arch 去重; 与 cubestack-kubespray-upgrade.sh [4/8] 的口径一致)现算, 不写死
            _kb_range="$(awk '
                /^kubelet_checksums:/ { s=1; next }
                /^[a-zA-Z_]+_checksums:/ { s=0 }
                s && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+:$/ { v=$1; sub(/:$/,"",v); print v }
            ' "${KSD_CK}" | sort -Vu | awk 'NR==1 { min=$0 } { max=$0 } END { print min "–" max }')"
            say "  ${_cn}: K8S_VERSION=${_k8s} 在 kubelet_checksums 表内(表范围 ${_kb_range})"
        else
            ck_fail "⑯ ${_cn}: K8S_VERSION=${_k8s} 不在 kubespray 的 kubelet_checksums 表内(该表=可安装版本全集)" \
                "      → 表里没有的版本没有二进制校验和, 部署会失败; 修法: 改成表内版本(见 ${KSD_CK#${REPO_ROOT}/})"
            KSD_BAD=1; continue
        fi

        # ---- 其余 7 项: 与上游解析结果逐字一致(kube_major 取自本文件的 K8S_VERSION) ----
        _want_calico="$(_ksd_first_key calicoctl_binary_checksums amd64)"
        _want_etcd="$(_ksd_etcd "${_major}")"
        _want_coredns="$(_ksd_inline "${KSD_DL}" coredns_supported_versions "${_major}")"
        _want_pause="$(_ksd_inline "${KSD_VM}" pod_infra_supported_versions "${_major}")"
        _want_ndc="$(_ksd_scalar "${KSD_DL}" nodelocaldns_version)"
        _want_metrics="$(_ksd_scalar "${KSD_DL}" metrics_server_version)"
        _want_cpa="$(_ksd_scalar "${KSD_DL}" dnsautoscaler_version)"
        _want_nginx="$(_ksd_scalar "${KSD_DL}" nginx_image_tag)"
        # LVP / NFD(2026-09-28 评审 I4): 这两个钉子是 v2.32 支新加的(README 明写"须与上游同值"),
        # 却零断言 —— 上游同一文件里的标量, 取法与 metrics_server 完全一致(*_image_tag 由 *_version 拼)。
        _want_lvp="$(_ksd_scalar "${KSD_DL}" local_volume_provisioner_version)"
        _want_nfd="$(_ksd_scalar "${KSD_DL}" node_feature_discovery_version)"
        if [ -z "${_want_calico}" ] || [ -z "${_want_etcd}" ] || [ -z "${_want_coredns}" ] || \
           [ -z "${_want_pause}" ] || [ -z "${_want_ndc}" ] || [ -z "${_want_metrics}" ] || \
           [ -z "${_want_cpa}" ] || [ -z "${_want_nginx}" ] || [ -z "${_want_lvp}" ] || [ -z "${_want_nfd}" ]; then
            ck_fail "⑯ ${_cn}: 解析不出上游期望值(K8S_VERSION=${_k8s} → kube_major=${_major})" \
                "      → 树内表可能没有 ${_major} 这一线(如 1.33 在 v2.32 表里就不可用); 请改用表内线"
            KSD_BAD=1; continue
        fi

        # 比较: 只判"我方钉值 == 上游表值", **v 前缀等价**(我方钉子可带/不带 v; 上游变量侧不带 v,
        #   镜像 tag 侧另有 'v' 前缀 —— 那是 images.manifest 的职责, 本项不做形态断言)
        _ksd_cmp() {   # <变量> <上游期望> <上游出处>
            local got
            got="$(_ksd_conf_value "${_cf}" "$1")"
            if [ -z "${got}" ]; then
                ck_fail "⑯ ${_cn}: 取不到 $1 的钉值(未声明/写法解不出)"
                KSD_BAD=1; return 0
            fi
            if [ "${got#v}" = "$2" ]; then
                say "  ${_cn}: $1=${got} == 上游 $2"
            else
                ck_fail "⑯ ${_cn}: $1='${got}' 与上游表值不符(上游='$2')" \
                    "      → 上游出处: $3" \
                    "      → 修法: 把 cluster.conf 与 cluster.conf.example 的 $1 都改成 '$2'(v 前缀按现有写法保留/去掉均可)"
                KSD_BAD=1
            fi
        }
        _ksd_cmp CALICO_VERSION       "${_want_calico}"  "calicoctl_binary_checksums['amd64'] 首键(calico_version)"
        _ksd_cmp ETCD_VERSION         "${_want_etcd}"    "etcd_supported_versions['${_major}'] → etcd_binary_checksums"
        _ksd_cmp COREDNS_VERSION      "${_want_coredns}" "coredns_supported_versions['${_major}']"
        _ksd_cmp PAUSE_VERSION        "${_want_pause}"   "pod_infra_supported_versions['${_major}'](pod_infra_version)"
        _ksd_cmp DNS_NODE_CACHE_VERSION "${_want_ndc}"   "nodelocaldns_version"
        _ksd_cmp METRICS_SERVER_VERSION "${_want_metrics}" "metrics_server_version"
        _ksd_cmp CPA_VERSION          "${_want_cpa}"     "dnsautoscaler_version(cluster-proportional-autoscaler)"
        _ksd_cmp API_LB_NGINX_IMAGE_TAG "${_want_nginx}" "nginx_image_tag(download.yml:265, 节点侧 API 本地代理静态 Pod)"
        _ksd_cmp LOCAL_VOLUME_PROVISIONER_VERSION "${_want_lvp}" "local_volume_provisioner_version(download.yml:299)"
        _ksd_cmp NFD_VERSION          "${_want_nfd}"   "node_feature_discovery_version(download.yml:370)"

        # ---- ⑯-C 写入者闭环: inventory 的 10 个版本键 == 本 conf 的钉子(逐键点名) ----
        # 这一节回答的是"部署真会用这些钉子吗" —— 见文件头 ⑯-C 说明。取不到钉子侧时**不重复报**
        # (那已由上面的 ⑯-A 报过红), 只报 inventory 侧缺键/值不符。
        if [ -f "${KSD_INV_YML}" ]; then
            for _pair in "${KSD_PINS[@]}"; do
                _pv="${_pair%%:*}"; _kv="${_pair#*:}"
                _pin="$(_ksd_conf_value "${_cf}" "${_pv}")"
                [ -n "${_pin}" ] || continue
                _got="$(  # inventory 侧的取值(与上游标量同解析法)
                    grep -m1 -E "^${_kv}:" "${KSD_INV_YML}" 2>/dev/null \
                    | sed -E "s/^[^:]+:[[:space:]]*//; s/[[:space:]]*#.*//" | tr -d "\"'"
                )" || true
                if [ -z "${_got}" ]; then
                    ck_fail "⑯-C ${_cn}: inventory 缺 ${_kv} 键(${KSD_INV_YML#${REPO_ROOT}/})" \
                        "      → 对应钉子 ${_pv}=${_pin}; 缺键 ⇒ kubespray 退回**树内默认**(与离线 tar 不是一套)" \
                        "      → 修法: 跑 sync-kubespray-config.sh(3.2 节会按 cluster.conf 重新生成该文件)"
                    KSD_BAD=1
                elif [ "${_got#v}" != "${_pin#v}" ]; then
                    ck_fail "⑯-C ${_cn}: ${_kv}='${_got}' 与钉子 ${_pv}='${_pin}' 不符" \
                        "      → 部署用的是 inventory 里的 '${_got}'(不是钉子), 与离线 tar / images.manifest 对不上" \
                        "      → 修法: 重跑 sync-kubespray-config.sh(写入节会按 cluster.conf 覆盖); 勿手改该文件"
                    KSD_BAD=1
                else
                    say "  ⑯-C ${_cn}: ${_kv}=${_got} == ${_pv} 钉子(写入者在位)"
                fi
            done
            unset _pv _kv _pin _got _pair
        fi
    done
    unset -f _ksd_cmp 2>/dev/null || true
    unset _cf

    # ---- ⑯-B 两个开关键在 .example 的默认声明(⑦ 覆盖不到: 它们没有模块) ----
    for _k in LOCAL_VOLUME_PROVISIONER_ENABLED NFD_ENABLED; do
        _v="$(_ksd_conf_value "${CONF_EXAMPLE}" "${_k}")"
        if [ -z "${_v}" ]; then
            ck_fail "⑯ $(basename "${CONF_EXAMPLE}") 缺 ${_k} 的默认声明" \
                "      → 它由 tools/k8s/sync-addons-config.sh 消费(无对应模块, ⑦ 照不到); 删了会让开关静默丢默认" \
                "      → 修法: 组件开关区加 ${_k}=\"\${${_k}:-false}\", 真 cluster.conf 同步加一份"
            KSD_BAD=1
        else
            say "  ⑯-B ${_k}=${_v}(.example 声明在位)"
        fi
    done

    [ "${KSD_BAD}" = "0" ] && \
        ok "  ⑯ k8s 基座钉子闭环通过(A: K8S_VERSION 在 kubelet_checksums 表内, calico/etcd/coredns/pause/node-cache/metrics/cpa/nginx-tag/lvp/nfd 与树内表逐项对齐; B: 两个无模块开关声明在位; C: inventory 10 个版本键 == 钉子)"
fi
unset _cn _cf _k8s _k8s_bare _major _want_calico _want_etcd _want_coredns _want_pause _want_ndc _want_metrics _want_cpa _want_nginx _want_lvp _want_nfd _k _v _pv _kv _pin _got _pair KSD_PINS KSD_INV_YML 2>/dev/null || true

# ---------- ⑰ 凭据卫生: 含密钥的"生成物"不得被 git 跟踪 ----------
# 背景(2026-09-20 事故, 2026-09-29 复核才发现"其实没修好"): external-ceph 的自研导出配置由生成器
# 写成真值后被**误提交并持续跟踪**, 而 .gitignore 里早就列了它 —— ⚠ **忽略规则对已跟踪文件无效**,
# 于是"看着封堵了、其实一直在库里", 还被烧进 CLI 镜像。
# 本项把这条关系变成**可执行断言**: 这些路径 ① 必须被 .gitignore 覆盖 ② 且不得出现在 git 索引里。
say "[17/18] 凭据卫生(含密钥的生成物不得被 git 跟踪) ..."
_GIT=(git -C "${REPO_ROOT}")
_SECRET_PATHS=(
    deployments/config/external-ceph-self-define-access.conf   # 生成器写出三个真 keyring
    deployments/config/external-ceph.env                       # Rook 官方导出(mon/CSI/RGW 用户密钥)
    deployments/config/minio.conf                              # 含 MinIO 密钥
    deployments/config/cluster.conf                            # 含全部集群密码
)
for _p in "${_SECRET_PATHS[@]}"; do
    if "${_GIT[@]}" ls-files --error-unmatch "${_p}" >/dev/null 2>&1; then
        ck_fail "⑰ ${_p} **被 git 跟踪** —— 该文件含真实密钥" \
            "      → 修法: git rm --cached ${_p} && git commit(磁盘文件保留)" \
            "      → ⚠ 若已被 push: 密钥视为泄露, 必须在服务端轮换并重新导出" \
            "      → ⚠ 只加 .gitignore 不算修好: 忽略规则对**已跟踪**文件无效"
    elif ! "${_GIT[@]}" check-ignore -q "${_p}"; then
        ck_fail "⑰ ${_p} 既未被跟踪、也未被 .gitignore 覆盖 —— 一次 git add -A 就会把它带进提交" \
            "      → 修法: 仓库根 .gitignore 加一行 ${_p}"
    else
        say "  ⑰ ${_p}(未跟踪 + 已被忽略) ✓"
    fi
done
unset _GIT _SECRET_PATHS _p 2>/dev/null || true

# ---------- ⑱ 版本目录 ↔ 档案闭合(2026-09-30 起) ----------
# 为什么必须有: 版本目录是"离线可复现"的载体(设计 docs/kubespray-versioning/design.md)——
#   ① 入库档案(profiles/<版本>.profile)的版本面值必须 == **该版本树**的表值;
#   ② 在场版本目录的 VERSION.profile 必须与入库档案一致(有入库档案时);
#   ③ 目录里的关键二进制必须与其 K8S_VERSION 匹配(kubeadm/kubelet/kubectl-<ver>-amd64);
#   ④ tree.tar.gz 指纹(有边车时)必须对得上;
#   ⑤ LOCAL_ONLY(本地临时版本)与"有入库档案"不应同时出现(自相矛盾)。
# ⚠ 无任何版本目录时**跳过**(CI/纯 checkout 的常态), 不误报。
# 环境变量 OFFLINE_FILES_ROOT 可指向 fixture, 便于反证(见 tools/tests/…)。
say "[18/18] 版本目录 ↔ 档案闭合 ..."
VD_BAD=0
VD_WARN=0
VD_PROFILES_DIR="${REPO_ROOT}/deployments/config/profiles"
VD_OFFLINE_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
VD_TREE_VER="$(awk '/^version:/{print "v"$2; exit}' "${REPO_ROOT}/deployments/kubespray/kubespray/galaxy.yml" 2>/dev/null)"
_vd_profile_keys=(KUBESPRAY_VERSION K8S_VERSION PAUSE_VERSION COREDNS_VERSION DNS_NODE_CACHE_VERSION \
                  ETCD_VERSION CALICO_VERSION METRICS_SERVER_VERSION CPA_VERSION \
                  API_LB_NGINX_IMAGE_TAG LOCAL_VOLUME_PROVISIONER_VERSION NFD_VERSION)

# 取某版本对应的树目录(仓库树 / 物化树 / tar 解到临时目录); 取不到输出空
_vd_tree_for() {   # <版本>
    local v="$1" d
    [ -n "${VD_TREE_VER}" ] && [ "${v}" = "${VD_TREE_VER}" ] && { printf '%s\n' "${REPO_ROOT}/deployments/kubespray/kubespray"; return; }
    d="${REPO_ROOT}/deployments/kubespray/versions/${v}/kubespray"
    [ -d "${d}" ] && { printf '%s\n' "${d}"; return; }
    d="${VD_OFFLINE_ROOT}/kubespray/${v}/tree.tar.gz"
    [ -f "${d}" ] || return 0
    local tmp; tmp="$(mktemp -d)"
    tar -xzf "${d}" -C "${tmp}" >/dev/null 2>&1 || { rm -rf "${tmp}"; return 0; }
    printf '%s\n' "${tmp}"
}

# ① 入库档案逐版本 ↔ 其树表值
if [ -d "${VD_PROFILES_DIR}" ]; then
    for _pf in "${VD_PROFILES_DIR}"/*.profile; do
        [ -f "${_pf}" ] || continue
        _pv="$(_ksd_conf_value "${_pf}" KUBESPRAY_VERSION)"
        [ -n "${_pv}" ] || { ck_fail "⑱ $(basename "${_pf}"): 未声明 KUBESPRAY_VERSION"; VD_BAD=1; continue; }
        _ptree="$(_vd_tree_for "${_pv}")"
        if [ -z "${_ptree}" ]; then
            warn "  ⑱ 档案 ${_pv}: 无对应树(既非仓库树, 也无 versions/${_pv}/ 或离线 tree.tar.gz)⇒ 跳过逐值校验"
            continue
        fi
        _pck="${_ptree}/roles/kubespray_defaults/vars/main/checksums.yml"
        _pdl="${_ptree}/roles/kubespray_defaults/defaults/main/download.yml"
        _pvm="${_ptree}/roles/kubespray_defaults/vars/main/main.yml"
        _pk8s="$(_ksd_conf_value "${_pf}" K8S_VERSION)"
        if [ -z "${_pk8s}" ]; then
            ck_fail "⑱ $(basename "${_pf}"): 未声明 K8S_VERSION"; VD_BAD=1
        elif [ "$(kb_tables_kubelet_has "${_pck}" "${_pk8s#v}")" != "1" ]; then
            ck_fail "⑱ ${_pv}: K8S_VERSION=${_pk8s} 不在该版本树 kubelet_checksums 表内" \
                "      → 表内可选项: $(kb_tables_kubelet_list "${_pck}" | tr '\n' ' ')"
            VD_BAD=1
        else
            _pmajor="${_pk8s#v}"; _pmajor="${_pmajor%.*}"
            _vd_cmp() {   # <键> <上游期望> <出处>
                local got; got="$(_ksd_conf_value "${_pf}" "$1")"
                if [ -z "${got}" ]; then ck_fail "⑱ ${_pv}: 档案缺 $1"; VD_BAD=1; return 0; fi
                if [ "${got#v}" = "$2" ]; then
                    say "  ⑱ ${_pv}: $1=${got} == 树表 $2"
                else
                    ck_fail "⑱ ${_pv}: $1='${got}' ≠ 该版本树表值 '$2'($3)"
                    VD_BAD=1
                fi
            }
            _vd_cmp CALICO_VERSION        "$(kb_tables_first_key "${_pck}" calicoctl_binary_checksums amd64)" "calicoctl_binary_checksums 首键"
            _vd_cmp ETCD_VERSION          "$(kb_tables_version_for "${_ptree}" etcd_supported_versions "${_pmajor}")" "etcd_supported_versions['${_pmajor}'](跨版本形态由库容忍)"
            _vd_cmp COREDNS_VERSION       "$(kb_tables_version_for "${_ptree}" coredns_supported_versions "${_pmajor}")" "coredns_supported_versions['${_pmajor}']"
            _vd_cmp PAUSE_VERSION         "$(kb_tables_version_for "${_ptree}" pod_infra_supported_versions "${_pmajor}")" "pod_infra_supported_versions['${_pmajor}']"
            _vd_cmp DNS_NODE_CACHE_VERSION "$(kb_tables_scalar "${_pdl}" nodelocaldns_version)" "nodelocaldns_version"
            _vd_cmp METRICS_SERVER_VERSION "$(kb_tables_scalar "${_pdl}" metrics_server_version)" "metrics_server_version"
            _vd_cmp CPA_VERSION           "$(kb_tables_scalar "${_pdl}" dnsautoscaler_version)" "dnsautoscaler_version"
            _vd_cmp API_LB_NGINX_IMAGE_TAG "$(kb_tables_scalar "${_pdl}" nginx_image_tag)" "nginx_image_tag"
            _vd_cmp LOCAL_VOLUME_PROVISIONER_VERSION "$(kb_tables_scalar "${_pdl}" local_volume_provisioner_version)" "local_volume_provisioner_version"
            _vd_cmp NFD_VERSION           "$(kb_tables_scalar "${_pdl}" node_feature_discovery_version)" "node_feature_discovery_version"
            ok "  ⑱ 档案 ${_pv} 与树表值逐项对齐"
        fi
    done
fi

# ②/③/④/⑤ 在场版本目录自检
VD_DIRS=()
shopt -s nullglob
for _d in "${VD_OFFLINE_ROOT}"/kubespray/*/; do
    [ -d "${_d}" ] || continue
    { [ -f "${_d}/tree.tar.gz" ] || [ -f "${_d}/VERSION.profile" ] || [ -f "${_d}/LOCAL_ONLY" ]; } || continue
    VD_DIRS+=("${_d%/}")
done
shopt -u nullglob
if [ "${#VD_DIRS[@]}" -eq 0 ]; then
    say "  ⑱ 无在场版本目录(纯 checkout/未备料)⇒ 跳过 ②–⑤"
else
    for _d in "${VD_DIRS[@]}"; do
        _v="$(basename "${_d}")"
        # ⑤ LOCAL_ONLY 与入库档案不应并存(自相矛盾: 版本既是"本地临时"又"入库了")
        if [ -f "${_d}/LOCAL_ONLY" ] && [ -f "${VD_PROFILES_DIR}/${_v}.profile" ]; then
            ck_fail "⑱ ${_v}: 既有 LOCAL_ONLY 又有入库档案 profiles/${_v}.profile —— 二者语义互斥" \
                "      → 本地临时版本不入库: 删掉 LOCAL_ONLY 或删掉入库档案(设计 §3.3)"
            VD_BAD=1
        fi
        # ④ tar 指纹
        if [ -f "${_d}/tree.tar.gz" ] && [ -f "${_d}/tree.tar.gz.sha256" ]; then
            ( cd "${_d}" && sha256sum -c --quiet tree.tar.gz.sha256 ) \
                || { ck_fail "⑱ ${_v}: tree.tar.gz 指纹不符"; VD_BAD=1; }
        fi
        # ② VERSION.profile ↔ 入库档案
        if [ -f "${_d}/VERSION.profile" ] && [ -f "${VD_PROFILES_DIR}/${_v}.profile" ]; then
            for _k in "${_vd_profile_keys[@]}"; do
                _a="$(_ksd_conf_value "${_d}/VERSION.profile" "${_k}")"
                _b="$(_ksd_conf_value "${VD_PROFILES_DIR}/${_v}.profile" "${_k}")"
                [ "${_a#v}" = "${_b#v}" ] || { ck_fail "⑱ ${_v}: VERSION.profile 的 ${_k}='${_a}' ≠ 入库档案 '${_b}'"; VD_BAD=1; }
            done
        fi
        # ③ 关键二进制与 K8S_VERSION 匹配
        _k8s="$(_ksd_conf_value "${_d}/VERSION.profile" K8S_VERSION 2>/dev/null || true)"
        if [ -n "${_k8s}" ]; then
            for _b in kubeadm kubelet kubectl; do
                if [ ! -e "${_d}/${_b}-${_k8s#v}-amd64" ]; then
                    if [ -f "${_d}/LOCAL_ONLY" ]; then
                        warn "  ⑱ ${_v}(本地临时): 缺 ${_b}-${_k8s#v}-amd64(不阻断, 但该版本不可完整部署)"; VD_WARN=$((VD_WARN+1))
                    else
                        ck_fail "⑱ ${_v}: 缺关键二进制 ${_b}-${_k8s#v}-amd64" \
                            "      → 该版本无法离线部署; 补齐或用 sync/fetch 重新备料"
                        VD_BAD=1
                    fi
                fi
            done
        fi
        # 镜像: 在库版本必须有 images/*.tar, 本地临时只告警
        if [ -z "$(find "${_d}/images" -maxdepth 1 -name '*.tar' -print -quit 2>/dev/null)" ]; then
            if [ -f "${_d}/LOCAL_ONLY" ]; then
                warn "  ⑱ ${_v}(本地临时): images/ 为空(不阻断)"; VD_WARN=$((VD_WARN+1))
            else
                ck_fail "⑱ ${_v}: images/ 为空(在库版本的节点预加载镜像缺失)"; VD_BAD=1
            fi
        fi
    done
    if [ "${VD_BAD}" = "0" ]; then
        if [ "${VD_WARN}" = "0" ]; then
            ok "  ⑱ ${#VD_DIRS[@]} 个在场版本目录自检通过(指纹/档案一致/二进制齐套/LOCAL_ONLY 自洽)"
        else
            ok "  ⑱ ${#VD_DIRS[@]} 个在场版本目录自检通过(无硬性问题; ${VD_WARN} 项本地临时版本的缺口见上方 ⚠)"
        fi
    fi
fi
unset VD_BAD VD_WARN VD_PROFILES_DIR VD_TREE_VER _vd_profile_keys _pf _pv _ptree _pck _pdl _pvm _pk8s _pmajor _d _v _k _a _b _k8s _b 2>/dev/null || true

echo "---------------------------------------------"
if [ "${FAIL}" = "0" ]; then
    ok "模块校验全部通过(${#ALLKEYS[@]} 个模块)"
    exit 0
else
    bad "模块校验存在违规(${FAIL} 类问题), 修复后重试"
    exit 1
fi
