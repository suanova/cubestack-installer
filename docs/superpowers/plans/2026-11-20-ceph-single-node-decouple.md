# 单节点 Ceph 与 Ceph 模式变量重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保持多节点 Ceph 行为不变的前提下，新增单节点 Ceph 部署、把 Ceph 配置收敛为单一 `CEPH_MODE` 变量、解耦单/多节点脚本，并默认回退 local-path。

**Architecture:** `lib-common.sh` 负责模式/拓扑/有效参数/安装条件；`tools/k8s/lib-ceph.sh` 承载单/多节点共享的 Rook 运行时原语；`02_ceph.sh` 作为分发器（single → 独立脚本，multi/external → 原有流程）；`03_ceph_csi.sh` 按有效参数渲染同一套 SC 资源。

**Tech Stack:** Bash 5、Rook v1.21.1、Ceph v20.2.2、ceph-csi-operator v1.1.0、kubespray、现有 `check-modules.sh` 静态门禁。

**Spec:** `docs/superpowers/specs/2026-11-20-ceph-single-node-decouple-design.md`

> **执行修订（2026-11-20，用户确认）**：Task 5/7 改为“独立入口脚本 + 复用 `ceph_engine_main`
> 引擎”（单节点只设置 profile 参数），不再抽取 `tools/k8s/lib-ceph.sh`。原因：零重复、
> 多节点行为零风险；单/多节点差异由拓扑与有效参数驱动。其余 Task 不变。

## Global Constraints

- 多节点部署的步骤、顺序、命令必须保持等价；共享原语抽取后逐字段核对 CephCluster CR。
- `CEPH_ENABLED` / `CEPH_CSI_ENABLED` 在实现完成后不得再出现于任何脚本/配置/文档/测试（历史迁移代码除外，见 Task 1）。
- 所有 Bash 脚本 `set -euo pipefail`；模块内错误分支显式 `exit 1`；`err()` 只打印不退出。
- 模块必须 `init_remote_kubectl`，禁止手抄 SSH 初始化。
- 新增/修改脚本必须通过 `bash -n` 与 `bash deployments/scripts/tools/check-modules.sh`。
- 所有写远端 `/tmp` 固定名文件必须先 `sudo rm -f` 再写、用完删除（`fs.protected_regular`）。
- 不自动提交；每项验证通过后等用户确认再 commit。
- 单节点是降级拓扑（无跨主机冗余），文档必须明确标注。

---

### Task 1: `CEPH_MODE` 归一化、legacy 映射与配置模板

**Files:**
- Modify: `deployments/scripts/lib-common.sh`（Ceph 归一化段 ~1240-1285；新增纯函数）
- Modify: `deployments/config/cluster.conf.example:59-63`
- Modify: `deployments/config/cluster.defaults.conf:316-455`
- Test: `deployments/scripts/tools/tests/test-ceph-mode.sh`（新建）
- Modify: `deployments/scripts/tools/check-modules.sh:744-750`（注册测试）

**Interfaces:**
- Produces: `ceph_norm_lower <v>` → stdout 小写去空白；`ceph_norm_bool <v>` → `true|false`；
  `ceph_resolve_mode <mode> <legacy_enabled> <legacy_csi> <mode_was_set>` → stdout `none|external|internal`；
  `ceph_normalize_ceph_vars`（当前 shell 内归一化所有 `CEPH_*` 布尔/枚举）；
  load_config 导出 `CEPH_MODE`，`unset CEPH_ENABLED CEPH_CSI_ENABLED`。

- [ ] **Step 1: 写失败测试**

```bash
#!/bin/bash
# test-ceph-mode.sh — CEPH_MODE 归一化 / legacy 映射 / 布尔归一化
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

run() {  # run <shell-code>
    ( set +u
      source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      eval "$1" )
}

echo "== 归一化 =="
chk "None"   "$(run 'ceph_norm_lower " NOne "')" "none"
chk "TRUE"   "$(run 'ceph_norm_bool TRUE')" "true"
chk "Off"    "$(run 'ceph_norm_bool Off')" "false"
chk "yes"    "$(run 'ceph_norm_bool yes')" "true"

echo "== legacy 映射 =="
chk "both true"      "$(run 'ceph_resolve_mode "" true true 0')" "internal"
chk "csi only"       "$(run 'ceph_resolve_mode "" false true 0')" "external"
chk "cluster only"   "$(run 'ceph_resolve_mode "" true false 0')" "internal"
chk "both false"     "$(run 'ceph_resolve_mode "" false false 0')" "none"
chk "explicit wins"  "$(run 'ceph_resolve_mode "NOne" true true 1')" "none"
chk "invalid fails"  "$(run 'if ceph_resolve_mode "bogus" "" "" 1; then echo ok; else echo bad; fi')" "bad"

echo "== load_config 映射与子开关 =="
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
printf 'NODES=()\nCEPH_MODE=nOne\n' > "${tmp}/cluster.conf"
out="$( ( set +u
    CLUSTER_CONF="${tmp}/cluster.conf"
    CLUSTER_DEFAULTS_CONF="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
    source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
    load_config >/dev/null 2>&1
    printf '%s|%s|%s|%s\n' "${CEPH_MODE}" "${CEPHFS_ENABLED}" "${LOCAL_PATH_ENABLED}" "${REGISTRY_STORAGE_CLASS}" ) )"
chk "mode none → 子开关关闭" "${out}" "none|false|true|local-path"

printf 'NODES=()\nCEPH_ENABLED=true\nCEPH_CSI_ENABLED=true\n' > "${tmp}/legacy.conf"
out="$( ( set +u
    CLUSTER_CONF="${tmp}/legacy.conf"
    CLUSTER_DEFAULTS_CONF="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
    source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
    load_config >/dev/null 2>&1
    printf '%s|%s\n' "${CEPH_MODE}" "${CEPH_ENABLED+unset}" ) )"
chk "legacy → internal 且旧变量 unset" "${out}" "internal|unset"

exit "${fail}"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash deployments/scripts/tools/tests/test-ceph-mode.sh`
Expected: FAIL `ceph_norm_lower: command not found`。

- [ ] **Step 3: 在 lib-common.sh 新增纯函数**

```bash
# ---------------- Ceph 配置归一化(2026-11-20 单一开关 CEPH_MODE) ----------------
ceph_norm_lower() { printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'; }
ceph_norm_bool() {
    case "$(ceph_norm_lower "${1:-}")" in
        1|true|yes|y|on)   printf 'true' ;;
        0|false|no|n|off|'') printf 'false' ;;
        *) printf 'false' ;;
    esac
}
# ceph_resolve_mode <mode> <legacy_enabled> <legacy_csi> <mode_was_set>
# stdout: none|external|internal；非法 mode 返回 1。
ceph_resolve_mode() {
    local mode legacy_e legacy_c was_set
    mode="$(ceph_norm_lower "${1:-}")"
    legacy_e="$(ceph_norm_bool "${2:-false}")"
    legacy_c="$(ceph_norm_bool "${3:-false}")"
    was_set="${4:-0}"
    if [ "${was_set}" = "1" ] || [ -n "${mode}" ]; then
        case "${mode}" in
            none|external|internal) printf '%s' "${mode}"; return 0 ;;
            *) return 1 ;;
        esac
    fi
    if [ "${legacy_e}" = "true" ] && [ "${legacy_c}" = "true" ]; then printf 'internal'
    elif [ "${legacy_c}" = "true" ]; then printf 'external'
    elif [ "${legacy_e}" = "true" ]; then printf 'internal'
    else printf 'none'; fi
}
ceph_normalize_ceph_vars() {
    local _v _val _norm
    for _v in CEPH_FALLBACK_TO_LOCALPATH CEPHFS_ENABLED CEPH_RGW_ENABLED \
              CEPH_DASHBOARD_ENABLED CEPH_HOST_NETWORK CEPH_ENABLE_MASTER_SCHEDULE \
              CEPH_CLEAN_STALE_LOCAL_PATH CEPH_EXTERNAL_EXPOSE CEPHFS_MOUNT_ENABLED \
              CEPHFS_MOUNT_READ_ONLY CEPH_EXTERNAL_PROVISION_SMOKE CEPH_PRE_CLEANUP_EXISTING \
              CEPH_CLEANUP_ALLOW_EXTERNAL CEPHFS_MDS_ACTIVE_STANDBY; do
        eval "_val=\"\${${_v}:-}\""
        [ -n "${_val}" ] || continue
        _norm="$(ceph_norm_bool "${_val}")"
        printf -v "${_v}" '%s' "${_norm}"
        export "${_v}"
    done
    for _v in CEPH_TOPOLOGY CEPH_DATA_DISK_POLICY CEPH_EXPOSE_MODE \
              CEPH_EXTERNAL_EXPOSE_MODE CEPH_RGW_EXPOSE_MODE CEPH_POOL_FAILURE_DOMAIN; do
        eval "_val=\"\${${_v}:-}\""
        [ -n "${_val}" ] || continue
        _norm="$(ceph_norm_lower "${_val}")"
        printf -v "${_v}" '%s' "${_norm}"
        export "${_v}"
    done
}
```

- [ ] **Step 4: 替换 load_config 的 Ceph 段**

在 `load_config` 内、source defaults 之后，记录“是否显式设置过 CEPH_MODE”：
```bash
_ceph_mode_set=0
[ -n "${CEPH_MODE+set}" ] && _ceph_mode_set=1
_legacy_ceph=0
if [ -n "${CEPH_ENABLED+set}" ] || [ -n "${CEPH_CSI_ENABLED+set}" ]; then
    _legacy_ceph=1
fi
```
把原 1240-1285 段替换为：
```bash
ceph_normalize_ceph_vars
if ! CEPH_MODE="$(ceph_resolve_mode "${CEPH_MODE:-}" "${CEPH_ENABLED:-false}" "${CEPH_CSI_ENABLED:-false}" "${_ceph_mode_set}")"; then
    err "CEPH_MODE 非法: '${CEPH_MODE}'(只允许 none|external|internal)"
    exit 1
fi
if [ "${_legacy_ceph}" = "1" ]; then
    if [ "${_ceph_mode_set}" = "1" ]; then
        warn "CEPH_ENABLED/CEPH_CSI_ENABLED 已弃用并被忽略; 以 CEPH_MODE=${CEPH_MODE} 为准"
    else
        warn "CEPH_ENABLED/CEPH_CSI_ENABLED 已弃用; 已自动映射为 CEPH_MODE=${CEPH_MODE}"
        warn "  请改为 cluster.conf 只写 CEPH_MODE=none|external|internal"
    fi
fi
unset CEPH_ENABLED CEPH_CSI_ENABLED _legacy_ceph _ceph_mode_set
case "${CEPH_MODE}" in
    none)
        CEPHFS_ENABLED="false"; CEPH_RGW_ENABLED="false"; CEPHFS_MOUNT_ENABLED="false"
        ;;
    *)
        if [ "${CEPH_MODE}" = "external" ]; then
            CEPH_POOL="${CEPH_POOL:-rbd}"; CEPH_USER="${CEPH_USER:-admin}"
        fi
        ;;
esac
CEPH_POOL="${CEPH_POOL:-rbd}"; CEPH_USER="${CEPH_USER:-admin}"
export CEPH_MODE CEPH_POOL CEPH_USER CEPH_KEYRING CEPHFS_ENABLED CEPH_RGW_ENABLED CEPHFS_MOUNT_ENABLED
if [ "${CEPH_MODE}" != "none" ]; then
    REGISTRY_STORAGE_CLASS="ceph-block"
    LOCAL_PATH_ENABLED="false"
else
    [ -n "${REGISTRY_STORAGE_CLASS:-}" ] || REGISTRY_STORAGE_CLASS="local-path"
fi
export REGISTRY_STORAGE_CLASS LOCAL_PATH_ENABLED
```
注意：保留原 `CEPH_EXTERNAL_MONITORS` 旧外部变量迁移逻辑，放在 `ceph_resolve_mode` 之前；
迁移后设置 `CEPH_MODE=external` 并把 `_ceph_mode_set=1`。

- [ ] **Step 5: 配置模板**

`cluster.conf.example` 用以下内容替换旧两行：
```bash
CEPH_MODE="${CEPH_MODE:-none}"               # none=不装Ceph/CSI | external=仅CSI接外部 | internal=集群内Ceph+CSI
CEPH_TOPOLOGY="${CEPH_TOPOLOGY:-auto}"       # auto | single | multi(单节点自动识别)
# → 回退/子能力/凭据见 cluster.defaults.conf §4.3b
```
`cluster.defaults.conf`：
- `CEPHFS_ENABLED="${CEPHFS_ENABLED:-true}"`、`CEPH_RGW_ENABLED="${CEPH_RGW_ENABLED:-true}"`。
- 删除所有 `CEPH_ENABLED`/`CEPH_CSI_ENABLED` 引用；`REGISTRY_STORAGE_CLASS` 默认块改为
  `case "$(ceph_norm_lower "${CEPH_MODE:-none}")" in internal|external) ceph-block;; *) local-path;; esac`。
- 新增：
```bash
CEPH_TOPOLOGY="${CEPH_TOPOLOGY:-auto}"
CEPH_FALLBACK_TO_LOCALPATH="${CEPH_FALLBACK_TO_LOCALPATH:-true}"
CEPH_POOL_FAILURE_DOMAIN="${CEPH_POOL_FAILURE_DOMAIN:-}"
CEPHFS_MDS_ACTIVE_COUNT="${CEPHFS_MDS_ACTIVE_COUNT:-}"
CEPHFS_MDS_ACTIVE_STANDBY="${CEPHFS_MDS_ACTIVE_STANDBY:-}"
CEPH_RGW_INSTANCES="${CEPH_RGW_INSTANCES:-}"
```

- [ ] **Step 6: 运行测试与静态检查**
Run: `bash deployments/scripts/tools/tests/test-ceph-mode.sh && bash -n deployments/scripts/lib-common.sh`
Expected: exit 0。

- [ ] **Step 7: 注册测试**（加入 check-modules ⑮ 列表）。

---

### Task 2: 枚举 TOGGLE 框架 + `ceph_single` 别名

**Files:**
- Modify: `deployments/scripts/lib-module.sh:161-169, 312-330, 408-423`
- Modify: `deployments/scripts/deploy-cluster.sh:330-360`
- Modify: `deployments/scripts/tools/check-modules.sh:165-180`
- Test: `deployments/scripts/tools/tests/test-module-toggle-enum.sh`（新建）

**Interfaces:**
- `# TOGGLE: CEPH_MODE=internal,external` 语义：值在逗号列表即启用。
- `module_default_on <i>` 支持枚举；`--enable ceph` 写 `CEPH_MODE=internal`。
- `MODULE_ALIAS[ceph_single]=ceph`。

- [ ] **Step 1: 失败测试**（抽取 `module_default_on` 原文，断言枚举匹配/不匹配/大小写）。

- [ ] **Step 2: 修改 `module_default_on`**

```bash
module_default_on() {
    local i="$1" tgl val _var _vals
    [ "${MODULE_DEFAULT[$i]:-0}" = "1" ] && return 0
    tgl="${MODULE_TOGGLE[$i]:-}"
    [ -n "${tgl}" ] || return 1
    for tgl in ${tgl}; do
        case "${tgl}" in
            *=*)
                _var="${tgl%%=*}"; _vals="${tgl#*=}"
                val="$(printf '%s' "${!_var:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
                case ",${_vals,,}," in *",${val},"*) return 0 ;; esac
                ;;
            *)
                val="${!tgl:-false}"
                case "${val,,}" in true|1|yes|on) return 0 ;; esac
                ;;
        esac
    done
    return 1
}
```

- [ ] **Step 3: `--enable` 持久化枚举值**

`_enable_persist` 内解析：
```bash
local tgl_var="$tgl" tgl_val=""
case "${tgl}" in *=*) tgl_var="${tgl%%=*}"; tgl_val="${tgl#*=}"; tgl_val="${tgl_val%%,*}" ;; esac
```
比较与写入使用 `tgl_var`/`tgl_val`；枚举时写 `VAR=value`，布尔时保持 `VAR=true`。
`--enable` 帮助文本补一句：枚举开关写入第一个值（`ceph` → `CEPH_MODE=internal`）。

- [ ] **Step 4: 禁止枚举 TOGGLE 自动导出**

`resolve_run_steps` 后的导出循环：
```bash
for i in "${!MODULE_KEY[@]}"; do
    tgl="${MODULE_TOGGLE[$i]:-}"
    [ -n "${tgl}" ] || continue
    module_default_on "${i}" && continue
    tgl="${tgl%% *}"
    case "${tgl}" in *=*) continue ;; esac   # 枚举开关不静默开启(防误触发 Ceph 磁盘清理)
    ...
done
```

- [ ] **Step 5: 别名**
在 `MODULE_ALIAS` 增加 `[ceph_single]=ceph`。`--list-steps` 说明中标注 `ceph` 自动按拓扑分发。

- [ ] **Step 6: check-modules ⑦ 拆分 `VAR=values`**
```bash
for tv in ${tgl}; do
    tv="${tv%%=*}"
    ...
done
```

- [ ] **Step 7: 测试 + `bash -n` + check-modules 单跑该测试。**

---

### Task 3: 拓扑解析与有效参数

**Files:**
- Modify: `deployments/scripts/lib-common.sh`（新增 `ceph_topology_resolve`、`ceph_apply_effective_spec`）
- Test: `deployments/scripts/tools/tests/test-ceph-topology.sh`（新建）

**Interfaces:**
- `ceph_topology_resolve <desired> <node_count> <min_nodes>` → stdout `single|multi|ineligible`；
  `ineligible` 时第二行给出原因。
- `ceph_apply_effective_spec <topology>` → 设置 `CEPH_EFF_*`、`CEPH_TOPOLOGY_EFFECTIVE`，
  使用 load_config 捕获的 `CEPH_EXPLICIT_*` 标志。

- [ ] **Step 1: 测试**（1→single, 3/5→multi, 0/2→ineligible, desired=single + count=2→ineligible,
  desired=multi + count=2→ineligible；单节点参数表）。

- [ ] **Step 2: 实现拓扑纯函数**

```bash
ceph_topology_resolve() {
    local desired count min
    desired="$(ceph_norm_lower "${1:-auto}")"; count="${2:-0}"; min="${3:-3}"
    case "${desired}" in
        single) [ "${count}" -eq 1 ] && printf 'single' || { printf 'ineligible\n单节点拓扑要求存储节点恰好 1 台(当前 %s 台)' "${count}"; return 1; } ;;
        multi)  [ "${count}" -ge "${min}" ] && printf 'multi' || { printf 'ineligible\n多节点拓扑要求存储节点 >= %s 台(当前 %s 台)' "${min}" "${count}"; return 1; } ;;
        auto)
            if [ "${count}" -eq 1 ]; then printf 'single'
            elif [ "${count}" -ge "${min}" ]; then printf 'multi'
            else printf 'ineligible\n存储节点 %s 台: 1 台走单节点, >= %s 台走多节点; 2 节点需显式 CEPH_NODES 选 1 台或 CEPH_TOPOLOGY=multi 且调整 CEPH_MIN_NODES' "${count}" "${min}"; return 1
            fi ;;
        *) printf 'ineligible\nCEPH_TOPOLOGY 非法: %s(只允许 auto|single|multi)' "${desired}"; return 1 ;;
    esac
}
```

- [ ] **Step 3: 捕获显式覆盖**

`load_config` 在 source defaults **之前**捕获：
```bash
_ceph_pre_mon="${CEPH_MON_COUNT:-}"; _ceph_pre_mgr="${CEPH_MGR_COUNT:-}"
_ceph_pre_rep="${CEPH_POOL_REPLICAS:-}"; _ceph_pre_min="${CEPH_POOL_MIN_SIZE:-}"
_ceph_pre_fd="${CEPH_POOL_FAILURE_DOMAIN:-}"
_ceph_pre_mds="${CEPHFS_MDS_ACTIVE_COUNT:-}"; _ceph_pre_std="${CEPHFS_MDS_ACTIVE_STANDBY:-}"
_ceph_pre_rgw="${CEPH_RGW_INSTANCES:-}"
```
source defaults 后设置 `CEPH_EXPLICIT_*` 0/1 并导出。

- [ ] **Step 4: 实现 `ceph_apply_effective_spec`**

```bash
ceph_apply_effective_spec() {
    local topo; topo="$(ceph_norm_lower "${1:-multi}")"
    CEPH_TOPOLOGY_EFFECTIVE="${topo}"
    if [ "${topo}" = "single" ]; then
        CEPH_EFF_MON_COUNT=1
        [ "${CEPH_EXPLICIT_MGR:-0}" = "1" ] && CEPH_EFF_MGR_COUNT="${CEPH_MGR_COUNT}" || CEPH_EFF_MGR_COUNT=1
        [ "${CEPH_EXPLICIT_REPLICAS:-0}" = "1" ] && CEPH_EFF_POOL_REPLICAS="${CEPH_POOL_REPLICAS}" || CEPH_EFF_POOL_REPLICAS=1
        [ "${CEPH_EXPLICIT_MIN_SIZE:-0}" = "1" ] && CEPH_EFF_POOL_MIN_SIZE="${CEPH_POOL_MIN_SIZE}" || CEPH_EFF_POOL_MIN_SIZE=1
        [ "${CEPH_EXPLICIT_FAILURE_DOMAIN:-0}" = "1" ] && CEPH_EFF_FAILURE_DOMAIN="${CEPH_POOL_FAILURE_DOMAIN}" || CEPH_EFF_FAILURE_DOMAIN=osd
        [ "${CEPH_EXPLICIT_MDS:-0}" = "1" ] && CEPH_EFF_MDS_ACTIVE_COUNT="${CEPHFS_MDS_ACTIVE_COUNT}" || CEPH_EFF_MDS_ACTIVE_COUNT=1
        [ "${CEPH_EXPLICIT_MDS_STANDBY:-0}" = "1" ] && CEPH_EFF_MDS_ACTIVE_STANDBY="${CEPHFS_MDS_ACTIVE_STANDBY}" || CEPH_EFF_MDS_ACTIVE_STANDBY=false
        [ "${CEPH_EXPLICIT_RGW:-0}" = "1" ] && CEPH_EFF_RGW_INSTANCES="${CEPH_RGW_INSTANCES}" || CEPH_EFF_RGW_INSTANCES=1
    else
        CEPH_EFF_MON_COUNT="${CEPH_MON_COUNT:-3}"
        CEPH_EFF_MGR_COUNT="${CEPH_MGR_COUNT:-2}"
        CEPH_EFF_POOL_REPLICAS="${CEPH_POOL_REPLICAS:-3}"
        CEPH_EFF_POOL_MIN_SIZE="${CEPH_POOL_MIN_SIZE:-2}"
        CEPH_EFF_FAILURE_DOMAIN="${CEPH_POOL_FAILURE_DOMAIN:-host}"
        CEPH_EFF_MDS_ACTIVE_COUNT="${CEPHFS_MDS_ACTIVE_COUNT:-2}"
        CEPH_EFF_MDS_ACTIVE_STANDBY="${CEPHFS_MDS_ACTIVE_STANDBY:-true}"
        CEPH_EFF_RGW_INSTANCES="${CEPH_RGW_INSTANCES:-2}"
    fi
    [ "${CEPH_EFF_POOL_MIN_SIZE}" -le "${CEPH_EFF_POOL_REPLICAS}" ] || {
        err "CEPH_POOL_MIN_SIZE(${CEPH_EFF_POOL_MIN_SIZE}) > CEPH_POOL_REPLICAS(${CEPH_EFF_POOL_REPLICAS})"; return 1; }
    if [ "${CEPH_EFF_POOL_REPLICAS}" -ge 3 ]; then
        CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE=true
    else
        CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE=false
    fi
    case "${CEPH_EFF_FAILURE_DOMAIN}" in host|osd) ;; *) err "CEPH_POOL_FAILURE_DOMAIN 非法: ${CEPH_EFF_FAILURE_DOMAIN}"; return 1 ;; esac
    export CEPH_TOPOLOGY_EFFECTIVE CEPH_EFF_MON_COUNT CEPH_EFF_MGR_COUNT \
           CEPH_EFF_POOL_REPLICAS CEPH_EFF_POOL_MIN_SIZE CEPH_EFF_FAILURE_DOMAIN \
           CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE CEPH_EFF_MDS_ACTIVE_COUNT \
           CEPH_EFF_MDS_ACTIVE_STANDBY CEPH_EFF_RGW_INSTANCES
}
```

- [ ] **Step 5: 测试通过 + `bash -n`。**

---

### Task 4: 真实安装条件探测 + 默认回退 + 计划修正

**Files:**
- Modify: `deployments/scripts/lib-common.sh`（`ceph_installable_check` ~1315-1357；新增 `ceph_preflight_node_ssh`）
- Modify: `deployments/scripts/deploy-cluster.sh:486-530`（提前回退）、`:668-720`（删除旧块）、`:936-944`
- Modify: `deployments/scripts/tools/k8s/cluster-teardown.sh:269-290`
- Test: `deployments/scripts/tools/tests/test-ceph-fallback.sh`（新建，stub ssh/kubectl）

**Interfaces:**
- `ceph_installable_check --probe` → stdout 缺失项（空=具备）；返回 0/1。
- `ceph_apply_fallback_decision` → 0=未回退/无需；10=已回退；1=硬失败（fallback=false）。
- teardown 在 `CEPH_MODE=none` 时强制过滤 `ceph`。

- [ ] **Step 1: 测试**（stub `ceph-detect-disks.sh` 输出空盘 → 回退；有盘 → 不回退；
  external env 完整 → 不回退；fallback=false → 非零）。

- [ ] **Step 2: 扩展 `ceph_installable_check`**

关键逻辑：
```bash
ceph_installable_check() {
    local _probe=0 _miss="" _hn _ip _out _disk_nodes=0 _osd_total=0
    [ "${1:-}" = "--probe" ] && _probe=1
    if [ "${CEPH_MODE}" = "external" ]; then
        local _env="${CEPH_EXTERNAL_ENV_FILE:-${REPO_ROOT}/deployments/config/external-ceph.env}"
        if [ -f "${_env}" ]; then
            for _k in ROOK_EXTERNAL_FSID ROOK_EXTERNAL_CEPH_MON_DATA ROOK_EXTERNAL_USERNAME ROOK_EXTERNAL_USER_SECRET; do
                grep -qE "^${_k}=." "${_env}" || _miss="${_miss} ${_k}(env)"
            done
        else
            [ -n "${CEPH_MONITORS:-}" ] || _miss="${_miss} CEPH_MONITORS"
            [ -n "${CEPH_USER:-}" ] || _miss="${_miss} CEPH_USER"
            [ -n "${CEPH_KEYRING:-}" ] || _miss="${_miss} CEPH_KEYRING"
        fi
        [ -z "${_miss}" ] && return 0
        echo "外部 Ceph 参数缺失/不成对:${_miss}"; return 1
    fi
    [ -f "${CEPH_ROOK_MANIFEST_DIR}/operator.yaml" ] && [ -f "${CEPH_ROOK_MANIFEST_DIR}/csi-operator.yaml" ] \
        || { echo "Rook manifest 缺失(${CEPH_ROOK_MANIFEST_DIR})"; return 1; }
    local _count; _count="$(ceph_storage_host_count)"
    local _topo; _topo="$(ceph_topology_resolve "${CEPH_TOPOLOGY:-auto}" "${_count}" "${CEPH_MIN_NODES:-3}")" \
        || { echo "${_topo#*$'\n'}"; return 1; }
    if [ "${_topo}" = "single" ]; then
        [ "${_count}" -eq 1 ] || { echo "单节点拓扑要求 1 台存储节点"; return 1; }
    else
        [ "${_count}" -ge "${CEPH_MIN_NODES:-3}" ] || { echo "存储节点 ${_count} < CEPH_MIN_NODES"; return 1; }
    fi
    if [ -z "${CEPH_DATA_DISKS:-}" ] && [ "${_probe}" = "1" ]; then
        while IFS= read -r _hn; do
            [ -n "${_hn}" ] || continue
            _ip="$(...node ip lookup...)"
            _out="$(timeout 40 bash "${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-detect-disks.sh" --node "${_hn}" -m 2>/dev/null || true)"
            case "${_out}" in *":") : ;; *:?*) _disk_nodes=$((_disk_nodes+1)); _osd_total=$((_osd_total + $(awk -F: '{print split($2,a,",")}' <<<"${_out}")));; esac
        done < <(ceph_storage_hosts)
        [ "${_disk_nodes}" -gt 0 ] || { echo "未检测到空闲/旧 Ceph 裸盘(或 SSH 探测失败)"; return 1; }
        if [ "${_topo}" = "multi" ]; then
            [ "${_disk_nodes}" -ge "${CEPH_POOL_REPLICAS:-3}" ] || { echo "有盘节点 ${_disk_nodes} < CEPH_POOL_REPLICAS"; return 1; }
        else
            [ "${_osd_total}" -ge "${CEPH_POOL_REPLICAS:-1}" ] || { echo "单节点磁盘 ${_osd_total} < CEPH_POOL_REPLICAS"; return 1; }
        fi
    elif [ -z "${CEPH_DATA_DISKS:-}" ]; then
        echo "未显式指定 CEPH_DATA_DISKS(自动检测未启用)"; return 1
    fi
    # lvm2 探测(有 probe 时)
    if [ "${_probe}" = "1" ]; then
        while IFS= read -r _hn; do
            _ip="..."; ceph_preflight_node_ssh "${_ip}" 'command -v lvs >/dev/null' \
                || _miss="${_miss} lvm2@${_hn}"
        done < <(ceph_storage_hosts)
    fi
    [ -z "${_miss}" ] && return 0
    echo "缺失:${_miss}"; return 1
}
```
`ceph_preflight_node_ssh`：
```bash
ceph_preflight_node_ssh() {  # <ip> <cmd>
    ssh -i "${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}" \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 "$(ssh_user_for_ip "$1")@$1" "$2" </dev/null
}
```

- [ ] **Step 3: deploy-cluster 提前回退**

在 `ensure_node_ssh_access` 之后（~488）插入 `ceph_apply_fallback_decision` 调用；
删除原 673-717 块。回退函数设置 `CEPH_MODE=none` 等后：
```bash
if [ "${_fallback}" = "10" ]; then
    resolve_run_steps "${STEPS_ARG}" "${SKIP_ARG}" "${ENABLE_ARG}" "${PHASE_ARG}" >/dev/null || exit 1
    case " ${RUN_STEPS[*]} " in *" local_path "*) : ;; *) RUN_STEPS+=(local_path) ;; esac
fi
```
同时导出 `CUBESTACK_CEPH_FALLBACK=1`。

- [ ] **Step 4: teardown 计划门禁**

`cluster-teardown.sh` 在计划解析处增加：
```bash
if [ "${CEPH_MODE:-none}" = "none" ]; then
    _order="$(printf '%s\n' "${_order}" | awk -F'\t' '$1 != "ceph"')"
fi
```
并在缺少 `ceph` 时同样打印“保留 Ceph 数据”。

- [ ] **Step 5: 测试 + `bash -n` + check-modules。**

---

### Task 5: 抽取 `tools/k8s/lib-ceph.sh` 共享原语

**Files:**
- Create: `deployments/scripts/tools/k8s/lib-ceph.sh`
- Modify: `deployments/scripts/modules/03_addon/02_ceph.sh`
- Modify: `deployments/scripts/tools/tests/test-ceph-placement.sh`
- Test: `deployments/scripts/tools/tests/test-ceph-lib.sh`（新建）

**Interfaces (lib-ceph.sh):**
- 依赖调用方已 source lib-common、load_config、init_remote_kubectl，并设置 `CEPH_NODE_HOSTS[]`、`NODE_DISKS{}`。
- `ceph_nbd_clear_one <ip> <user>` / `ceph_nbd_restore_one <ip> <user>`
- `ceph_emit_daemon_placement <daemon>` → stdout YAML（替代 `_emit_placement`）
- `ceph_render_cluster_cr <mon> <mgr>` → stdout CephCluster YAML
- `ceph_select_disks`（设置 `NODE_DISKS`/`NODE_TSV`）
- `ceph_show_disk_confirmation`
- `ceph_storage_node_preflight`
- `ceph_ensure_master_schedulable`
- `ceph_prepare_storage_nodes`
- `ceph_ensure_images`
- `ceph_install_rook_operator`
- `ceph_toolbox_ready`
- `ceph_wait_cluster_healthy <min_osd>`
- `ceph_uninstall_live_state`
- `ceph_prepare_existing_cluster`（返回 0=继续新建，1=已跳过）
- `ceph_restore_consumers`

- [ ] **Step 1: 新建文件并搬移函数**

按 `02_ceph.sh` 现有行号搬移（保持函数体逐字不变，仅改名）：
- 117-182 → `ceph_nbd_*`
- 284-379 → `ceph_select_disks`
- 381-566 → `ceph_storage_node_preflight`
- 568-622 → `ceph_show_disk_confirmation`
- 624-658 → `ceph_ensure_master_schedulable`
- 662-707 → `ceph_prepare_storage_nodes`
- 709-743 → `ceph_ensure_images`
- 745-934 → `ceph_install_rook_operator`（内部 `_patch_rook_operator_placement`/`_patch_ceph_daemon_placement` 一并搬移）
- 936-1115 → `ceph_prepare_existing_cluster`
- 1124-1200 → `ceph_render_cluster_cr`
- 1208-1249 → `ceph_toolbox_ready`
- 1251-1443 → `ceph_wait_cluster_healthy`
- 1539-1573 → `ceph_restore_consumers`
- 52-92 → `ceph_uninstall_live_state`

- [ ] **Step 2: 02_ceph.sh 改为调用**

在 `load_config` 后加 `source "${SCRIPT_DIR}/tools/k8s/lib-ceph.sh"`；
原地删除已搬移的代码，按原顺序调用函数。CR 渲染：
```bash
LOCAL_CR="$(mktemp)"
ceph_render_cluster_cr "${CEPH_EFF_MON_COUNT}" "${CEPH_EFF_MGR_COUNT}" > "${LOCAL_CR}"
```
多节点调用前执行 `ceph_apply_effective_spec multi`。

- [ ] **Step 3: 测试**

`test-ceph-lib.sh`：
- stub `SSH`/`ceph_storage_hosts`/`ceph-detect-disks.sh`，调用 `ceph_select_disks` 断言 `NODE_DISKS`。
- 设置 `CEPH_NODE_HOSTS=(m1)`、`NODE_DISKS[m1]="/dev/vdb /dev/vdc"`，调用
  `ceph_render_cluster_cr 1 1`，断言 `count: 1`、`mgr count: 1`、两个 device。
- 多节点 `ceph_render_cluster_cr 3 2` 断言 `count: 3`、`mgr 2`、nodes 列表。

- [ ] **Step 4: 更新 `test-ceph-placement.sh`** 从 `lib-ceph.sh` 抽取 `ceph_emit_daemon_placement`。

- [ ] **Step 5: `bash -n` 两文件 + 测试 + check-modules。**

---

### Task 6: `02_ceph.sh` 模式门禁与单节点分发

**Files:**
- Modify: `deployments/scripts/modules/03_addon/02_ceph.sh:8, 94-104, 218-267, 1557`
- Test: `deployments/scripts/tools/tests/test-ceph-dispatch.sh`（新建）

**Interfaces:**
- `CEPH_MODE=none` → 跳过；`internal` + `single` → `exec bash tools/k8s/ceph-single-node.sh`；
  `internal` + `multi` → 现有流程；`external` → 现有 external 流程。

- [ ] **Step 1: 修改元数据**
```
# TOGGLE: CEPH_MODE=internal,external
```
- [ ] **Step 2: 模式门禁**
```bash
case "${CEPH_MODE:-none}" in
    none) say "CEPH_MODE=none, 跳过 Ceph"; exit 0 ;;
    internal|external) : ;;
    *) err "CEPH_MODE 非法: ${CEPH_MODE}"; exit 1 ;;
esac
```
- [ ] **Step 3: 分发**

在 `CEPH_NODE_HOSTS` 构建后（原 226 行后）：
```bash
if [ "${CEPH_MODE}" = "internal" ]; then
    _topo="$(ceph_topology_resolve "${CEPH_TOPOLOGY:-auto}" "${#CEPH_NODE_HOSTS[@]}" "${CEPH_MIN_NODES:-3}")" || {
        err "Ceph 拓扑不满足: ${_topo#*$'\n'}"; exit 1; }
    if [ "${_topo}" = "single" ]; then
        say "CEPH_TOPOLOGY=${CEPH_TOPOLOGY:-auto} → 单节点 Ceph(独立脚本)"
        exec bash "${SCRIPT_DIR}/tools/k8s/ceph-single-node.sh"
    fi
fi
```
外部模式不解析拓扑。
- [ ] **Step 4: 修复 7.9 空等**
```bash
if [ "${CEPH_MODE}" = "internal" ] && [ "${_CEPH_SKIP_CLUSTER:-0}" = "0" ]; then
```
- [ ] **Step 5: 删除 `CEPH_ENABLED/CEPH_CSI_ENABLED` 引用，summary 用 `CEPH_MODE`。**
- [ ] **Step 6: 测试分发**（抽取门禁/分发代码，stub `exec` 为 echo；断言 single 调用脚本）。

---

### Task 7: `tools/k8s/ceph-single-node.sh`

**Files:**
- Create: `deployments/scripts/tools/k8s/ceph-single-node.sh`
- Test: `deployments/scripts/tools/tests/test-ceph-single-node.sh`（新建）

**Interfaces:**
- 直接执行或由 02 exec；`CUBESTACK_MODULE_ACTION=uninstall` → `ceph_uninstall_live_state`。
- 使用 lib-ceph 的共享原语；`record_installed_component "ceph"`。

- [ ] **Step 1: 写脚本骨架**

```bash
#!/bin/bash
# ============================================================
# ceph-single-node.sh — 单节点 Rook-Ceph 部署(内部模式, 拓扑 single)
# 由 02_ceph.sh 在 CEPH_MODE=internal + 单存储节点时 exec; 也可单独执行。
# 数据源: cluster.conf CEPH_* / NODES / SSH_* ; 共享原语见 lib-ceph.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib-common.sh
source "${SCRIPT_DIR}/../../lib-common.sh"
load_config
# shellcheck source=lib-ceph.sh
source "${SCRIPT_DIR}/lib-ceph.sh"

if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    ceph_uninstall_live_state
    exit $?
fi
[ "${CEPH_MODE:-none}" = "internal" ] || { say "CEPH_MODE=${CEPH_MODE:-none}, 跳过单节点 Ceph"; exit 0; }

init_remote_kubectl || exit 1
CEPH_NODE_HOSTS=()
while IFS= read -r _h; do [ -n "${_h}" ] && CEPH_NODE_HOSTS+=("${_h}"); done < <(ceph_storage_hosts)
[ "${#CEPH_NODE_HOSTS[@]}" -eq 1 ] || { err "单节点 Ceph 要求恰好 1 台存储节点(当前 ${#CEPH_NODE_HOSTS[@]})"; exit 1; }
ceph_apply_effective_spec single || exit 1
CEPH_POOL_REPLICAS="${CEPH_EFF_POOL_REPLICAS}"
CEPH_POOL_MIN_SIZE="${CEPH_EFF_POOL_MIN_SIZE}"

ceph_select_disks || exit 1
ceph_storage_node_preflight || exit 1
ceph_show_disk_confirmation || exit 1
ceph_ensure_master_schedulable
ceph_prepare_storage_nodes || exit 1
ceph_ensure_images
ceph_install_rook_operator || exit 1
if ceph_prepare_existing_cluster; then
    LOCAL_CR="$(mktemp)"
    ceph_render_cluster_cr "${CEPH_EFF_MON_COUNT}" "${CEPH_EFF_MGR_COUNT}" > "${LOCAL_CR}"
    SSH "sudo rm -f /tmp/cephcluster.yaml" >/dev/null 2>&1 || true
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "${LOCAL_CR}" "${FIRST_MASTER_USER}@${FIRST_MASTER}:/tmp/cephcluster.yaml" >/dev/null 2>&1
    SSH "${K} apply -f /tmp/cephcluster.yaml" || { rm -f "${LOCAL_CR}"; err "应用 CephCluster CR 失败"; exit 1; }
    SSH "rm -f /tmp/cephcluster.yaml" >/dev/null 2>&1 || true
    rm -f "${LOCAL_CR}"
    ceph_toolbox_ready
    ceph_wait_cluster_healthy "${CEPH_EFF_POOL_REPLICAS}" || exit 1
fi
ceph_restore_consumers
record_installed_component "ceph"
ok "单节点 Ceph 部署完成(mon=1/mgr=${CEPH_EFF_MGR_COUNT}/size=${CEPH_EFF_POOL_REPLICAS})"
```

- [ ] **Step 2: 补齐调优/nbd 恢复/rbd 清理**（从 02 的 1445-1536 提取为共享函数或在单脚本调用）。
- [ ] **Step 3: 测试**
  - 抽取 `ceph_render_cluster_cr`，单节点断言 mon=1/mgr=1、无 host 故障域相关字段。
  - stub `ceph_storage_hosts` 返回 2 台 → 脚本退出非 0。
  - `CUBESTACK_MODULE_ACTION=uninstall` → 断言调用 `ceph_uninstall_live_state`。
- [ ] **Step 4: `bash -n` + 测试 + check-modules。**

---

### Task 8: `03_ceph_csi.sh` 与 Rook 清单拓扑化

**Files:**
- Modify: `deployments/cubestack-addon/rook/rbd/01-cephblockpool-rbd-pool.yaml`
- Modify: `deployments/cubestack-addon/rook/cephfs/01-cephfilesystem.yaml`
- Modify: `deployments/cubestack-addon/rook/rgw/01-cephobjectstore-s3-store.yaml`
- Modify: `deployments/scripts/modules/03_addon/03_ceph_csi.sh:9, 71-95, 176-187, 1179-1206`
- Test: `deployments/scripts/tools/tests/test-ceph-csi-topology.sh`（新建）

- [ ] **Step 1: 清单占位符**

`rbd/01`：
```yaml
  failureDomain: __FAILURE_DOMAIN__
  replicated:
    size: __REPLICAS__
    requireSafeReplicaSize: __REQUIRE_SAFE_REPLICA_SIZE__
```
`cephfs/01`：metadataPool/dataPools 两处同上；`metadataServer`：
```yaml
    activeCount: __MDS_ACTIVE_COUNT__
    activeStandby: __MDS_ACTIVE_STANDBY__
```
`rgw/01`：两个 pool 同上；`gateway.instances: __RGW_INSTANCES__`。

- [ ] **Step 2: 模块读取有效参数**

模块头 `TOGGLE: CEPH_MODE=internal,external`。在 `_ceph_external` 判定后：
```bash
if [ "${_CEPH_EXTERNAL}" = "0" ]; then
    _ph_count="$(ceph_storage_host_count)"
    _topo="$(ceph_topology_resolve "${CEPH_TOPOLOGY:-auto}" "${_ph_count}" "${CEPH_MIN_NODES:-3}")" \
        || { err "Ceph 拓扑不满足: ${_topo#*$'\n'}"; exit 1; }
    ceph_apply_effective_spec "${_topo}" || exit 1
fi
```
- [ ] **Step 3: `_ceph_yaml_file` 增加替换**
```bash
-e "s|__FAILURE_DOMAIN__|${CEPH_EFF_FAILURE_DOMAIN}|g" \
-e "s|__REQUIRE_SAFE_REPLICA_SIZE__|${CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE}|g" \
-e "s|__MDS_ACTIVE_COUNT__|${CEPH_EFF_MDS_ACTIVE_COUNT}|g" \
-e "s|__MDS_ACTIVE_STANDBY__|${CEPH_EFF_MDS_ACTIVE_STANDBY}|g" \
-e "s|__RGW_INSTANCES__|${CEPH_EFF_RGW_INSTANCES}|g" \
```
`__REPLICAS__`/`__MIN_SIZE__` 改用 `CEPH_EFF_*`。
- [ ] **Step 4: 日志/默认值**
`[2/4]` 日志改为 `${CEPH_EFF_POOL_REPLICAS}`；模块内 `CEPH_POOL_REPLICAS=` 默认行改为
`CEPH_POOL_REPLICAS="${CEPH_EFF_POOL_REPLICAS:-${CEPH_POOL_REPLICAS:-3}}"`。
- [ ] **Step 5: 测试**
  - 单节点 sed 后断言 `failureDomain: osd`、`requireSafeReplicaSize: false`、`activeCount: 1`、`activeStandby: false`、`instances: 1`。
  - 多节点断言 host/true/2/true/2。
  - SC 名称/默认标记不变。
- [ ] **Step 6: `bash -n` + `check-manifests.sh` + 测试。**

---

### Task 9: 清理旧开关引用与文档/帮助

**Files:**
- Modify: `deployments/scripts/modules/03_addon/05_k8s_registry.sh:150-157`
- Modify: `deployments/scripts/modules/03_addon/07_cephfs_mount.sh:377-379`
- Modify: `deployments/scripts/modules/03_addon/27_verify_ceph.sh:31-32`
- Modify: `deployments/scripts/deploy-cluster.sh`（help / print_plan / banner）
- Modify: `deployments/scripts/lib-module.sh`（TOGGLE 注释示例）
- Modify: `docs/ceph-rook.md`
- Modify: `deployments/scripts/README.md`（如涉及）
- Test: `deployments/scripts/tools/tests/test-ceph-legacy-refs.sh`（新建静态围栏）

- [ ] **Step 1: 全仓替换判定**

`05_k8s_registry`：
```bash
if [ "${CEPH_MODE:-none}" = "none" ]; then err "... Ceph 未启用(CEPH_MODE=none)..."; fi
```
`07_cephfs_mount` / `27_verify_ceph`：
```bash
[ "${CEPH_MODE:-none}" != "none" ] || { say "CEPH_MODE=none, 跳过"; exit 0; }
```
`deploy-cluster` 所有 `CEPH_ENABLED/CEPH_CSI_ENABLED` 判断改为 `CEPH_MODE`。

- [ ] **Step 2: 静态围栏测试**

```bash
# 除 Task 1 的 legacy 迁移块外, 全仓不得再引用旧变量
if grep -rn 'CEPH_ENABLED\|CEPH_CSI_ENABLED' \
     deployments/scripts deployments/config docs \
     | grep -v 'lib-common.sh:.*legacy\|test-ceph-mode.sh\|弃用' ; then
    echo "FAIL: 旧开关残留"; exit 1
fi
```

- [ ] **Step 3: 文档**

`docs/ceph-rook.md`：
- §3 配置示例改为 `CEPH_MODE=internal`；删除旧变量。
- 新增 §3.5 单节点 Ceph（`CEPH_TOPOLOGY=auto`、单节点参数表、降级说明）。
- §3.2 回退默认改为 true，说明探测项。
- 新开关表补 `CEPH_TOPOLOGY`/`CEPH_FALLBACK_TO_LOCALPATH`/`CEPH_POOL_FAILURE_DOMAIN`/`CEPHFS_MDS_*`/`CEPH_RGW_INSTANCES`。

- [ ] **Step 4: `deploy-cluster.sh --help`** 补单节点/模式说明；`--list-steps` 显示 `ceph_single` 别名。

---

### Task 10: 全量验证

- [ ] **Step 1: 语法**
```bash
for f in $(git diff --name-only -- '*.sh'); do bash -n "$f" || exit 1; done
```
- [ ] **Step 2: 静态门禁**
```bash
bash deployments/scripts/tools/check-modules.sh
bash deployments/scripts/tools/check-manifests.sh
```
Expected: exit 0。
- [ ] **Step 3: 新增单测全跑**
```bash
for t in test-ceph-mode test-ceph-mode-topology test-ceph-topology test-ceph-fallback \
         test-ceph-lib test-ceph-dispatch test-ceph-single-node test-ceph-csi-topology \
         test-cluster-teardown test-ceph-placement; do
  bash "deployments/scripts/tools/tests/${t}.sh" || exit 1
done
```
- [ ] **Step 4: CLI 冒烟**
```bash
sudo ./deployments/scripts/deploy-cluster.sh --list-steps | grep -E 'ceph|ceph_single'
```
- [ ] **Step 5: 真机验收（用户环境）**
  - 单节点：`CEPH_MODE=internal` 全量部署 → `verify_ceph`。
  - 多节点：原配置回归 → `verify_ceph`（确认行为未变）。
  - `CEPH_MODE=none` → local-path 默认 SC。
  - 无空闲盘 → 回退横幅 + local-path。

## Self-Review

- Spec §2（配置模型）→ Task 1/2/3；§3（拓扑参数）→ Task 3；§4（解耦）→ Task 5/6/7；
  §5（单节点流程）→ Task 7；§6（CSI）→ Task 8；§7（卸载/覆盖）→ Task 4/6；
  §8（回退）→ Task 4；§9（测试）→ 各 Task；§10/11 → Task 9/10。
- 无 TBD/占位符；函数名与调用签名在 Task 间一致（`ceph_resolve_mode`、`ceph_topology_resolve`、
  `ceph_apply_effective_spec`、`ceph_render_cluster_cr`、`ceph_uninstall_live_state`）。
- 注意：Task 5 行号基于当前 `02_ceph.sh`；执行前先 `git status` 确认文件未漂移。
