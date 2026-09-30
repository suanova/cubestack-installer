# kubespray 按版本部署实施计划

> **给执行者:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development(推荐)或
> superpowers:executing-plans 逐任务执行。步骤用 `- [ ]` 勾选跟踪。
>
> **Spec:** `docs/kubespray-versioning/design.md`(决策 D1–D8;计划从 spec 论证,执行时两份都读)

**目标:** 让 kubespray 支持"指定版本部署" —— 版本目录自带预打补丁的树与成套离线资产,单一开关
`KUBESPRAY_VERSION` 决定资产目录/树/版本钉子,离线件按版本上传下载;升级仍是独立路线。

**架构:** 两层版本目录 `offline-files/<组件>/<版本>/`(版本名 = 上游 tag 全名);入库档案
`config/profiles/<版本>.profile` 接管版本面变量;树从 `tree.tar.gz` 物化到
`deployments/kubespray/versions/<V>/`(gitignore);`LOCAL_REPO_DIR` 指向版本目录 ⇒ kubespray 侧零改动。

**技术栈:** bash 5 / git / mc(MinIO Client)/ python3(PyYAML,已有)/ kubespray vendored 树 + 补丁层。

## 全局约束(每个任务都隐含遵守)

| # | 约束 |
|---|---|
| G1 | **版本目录名 = 上游 tag 全名**(`v2.32.0`;D8),与 `galaxy.yml version:`、升级脚本 `<tag>`、`git tag` 三处一致 |
| G2 | **v2.28 只作本地验证/临时测试**:版本目录打 `LOCAL_ONLY` 标记,**不入 git、不上 MinIO**;入库的只有 v2.32 |
| G3 | **不重装现集群**;验证止于 选择/预检/物化/钉子一致/回归套件 |
| G4 | **不改升级脚本** `cubestack-kubespray-upgrade.sh`(只在文档补"与版本目录的关系") |
| G5 | 每任务收尾必须:`bash -n`(改动脚本)+ `bash deployments/scripts/tools/check-modules.sh` 全绿 |
| G6 | 提交信息用中文 conventional(`feat(kubespray):` / `fix(offline):` …),**不带 Co-Authored-By trailer** |
| G7 | 离线路径一律**经变量**(`OFFLINE_FILES_ROOT`/`OFFLINE_FILES_DIR`/`LOCAL_REPO_DIR`/`IMAGE_K8S_IMAGES_DIR`),禁止新增字面量路径 |
| G8 | 不引入新依赖;不新增需要 root 的**只读**操作(`--dry-run` 路线不得要求 root) |
| G9 | 纯函数/推导逻辑要可在**无集群、无网络、无 root**下断言(离线回归套件的基本门槛) |

---

### Task 1: 变量层与推导(OFFLINE_FILES_ROOT / KUBESPRAY_VERSION / 版本目录)

**Files:**
- Modify: `deployments/scripts/lib-common.sh:455-464`
- Modify: `deployments/config/cluster.conf.example:486-497`
- Create: `deployments/scripts/tools/tests/test-kubespray-version-select.sh`
- Modify: `deployments/scripts/tools/check-modules.sh`(⑮ 套件清单加新套件)

**Interfaces:**
- Produces: 变量 `OFFLINE_FILES_ROOT` / `KUBESPRAY_VERSION` / `OFFLINE_FILES_DIR` / `LOCAL_REPO_DIR` /
  `KUBESPRAY_BASE_DIR`(= 运行根:V == 仓库树版本 → `deployments/kubespray`,否则 `deployments/kubespray/versions/<V>`);
  函数 `kubespray_tree_version()`(输出 `vX.Y.Z` 或空)
- Consumes: 无

- [ ] **Step 1: 写失败套件(前 4 条断言)**

创建 `deployments/scripts/tools/tests/test-kubespray-version-select.sh`(风格对齐同目录
`test-update-kube-vip-addons.sh`:桩式、mktemp、`chk` 断言、退出码):

```bash
#!/bin/bash
# 桩式单元测试: kubespray 版本选择(不连集群、不联网、不碰真 offline-files)
#   · 变量推导: KUBESPRAY_VERSION → OFFLINE_FILES_DIR / LOCAL_REPO_DIR / 树
#   · 档案优先级与逃生阀(见 docs/kubespray-versioning/design.md §3.2)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

fail=0
chk() { # chk <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi
}

# 用桩 cluster.conf 跑一次 load_config, 打印关心的变量(每行 KEY=VALUE)
_conf() { printf '%s\n' "$@"; }
_probe() { # _probe <cluster.conf 行...> —— 输出 KEY=VALUE 行
    local c; c="$(mktemp)"
    _conf "$@" > "${c}"
    ( set +u
      export CLUSTER_CONF="${c}"
      export OFFLINE_FILES_ROOT="" KUBESPRAY_VERSION="" OFFLINE_FILES_DIR="" LOCAL_REPO_DIR="" KUBESPRAY_PROFILE=""
      source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      load_config >/dev/null 2>&1
      printf 'OFFLINE_FILES_ROOT=%s\nKUBESPRAY_VERSION=%s\nOFFLINE_FILES_DIR=%s\nLOCAL_REPO_DIR=%s\n' \
        "${OFFLINE_FILES_ROOT}" "${KUBESPRAY_VERSION}" "${OFFLINE_FILES_DIR}" "${LOCAL_REPO_DIR}" ) 
    rm -f "${c}"
}
_val() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }

NODES_CONF='NODES=("master,m1,10.0.0.1,ubuntu,p")'

echo "== ① 默认版本 = 仓库当前树版本(galaxy.yml 机械派生) =="
out="$(_probe "${NODES_CONF}" 'REPO_ROOT_FAKE=1')"
TREE_VER="$(awk '/^version:/{print "v"$2; exit}' "${REPO_ROOT}/deployments/kubespray/kubespray/galaxy.yml")"
chk "KUBESPRAY_VERSION = 树版本 ${TREE_VER}" "${TREE_VER}" "$(_val "${out}" KUBESPRAY_VERSION)"

echo "== ② 资产目录 = <root>/kubespray/<版本>, 且 LOCAL_REPO_DIR == 资产目录 =="
chk "OFFLINE_FILES_ROOT" "${REPO_ROOT}/deployments/offline-files" "$(_val "${out}" OFFLINE_FILES_ROOT)"
chk "OFFLINE_FILES_DIR 带版本层" \
    "${REPO_ROOT}/deployments/offline-files/kubespray/${TREE_VER}" "$(_val "${out}" OFFLINE_FILES_DIR)"
chk "LOCAL_REPO_DIR == OFFLINE_FILES_DIR" "$(_val "${out}" OFFLINE_FILES_DIR)" "$(_val "${out}" LOCAL_REPO_DIR)"
chk "KUBESPRAY_BASE_DIR = 仓库根(树版本一致时)" \
    "${REPO_ROOT}/deployments/kubespray" "$(_val "${out}" KUBESPRAY_BASE_DIR)"

echo "== ③ 不再有 CLUSTER_NAME 幽灵层 =="
case "$(_val "${out}" LOCAL_REPO_DIR)" in
    *cubestack-cluster*) chk "LOCAL_REPO_DIR 不含集群名" "无" "$(_val "${out}" LOCAL_REPO_DIR)" ;;
    *) chk "LOCAL_REPO_DIR 不含集群名" "无" "无" ;;
esac

echo "== ④ 显式 OFFLINE_FILES_DIR 最高优先(运维/容器挂载场景) =="
out2="$(OFFLINE_FILES_DIR=/mnt/big/offline-files/kubespray/vX _probe "${NODES_CONF}" 'X=1')"
chk "显式值不被覆盖" "/mnt/big/offline-files/kubespray/vX" "$(_val "${out2}" OFFLINE_FILES_DIR)"

if [ "${fail}" = "0" ]; then echo "== 全部通过 =="; else echo "== 有失败项 =="; fi
exit "${fail}"
```

> ⚠ `_probe` 里 `export CLUSTER_CONF` 之后 lib-common 才会读它;`set +u` 是因为 lib-common 内部有
> `${VAR:-}` 之外的历史写法。若 lib-common 需要更多桩变量,按报错补齐(不要改 lib-common 去迎合测试)。

- [ ] **Step 2: 跑测试确认失败**

Run: `bash deployments/scripts/tools/tests/test-kubespray-version-select.sh`
Expected: FAIL —— `OFFLINE_FILES_DIR` 实际为 `…/offline-files/kubespray`(无版本层)、
`LOCAL_REPO_DIR` 含 `cubestack-cluster`、`OFFLINE_FILES_ROOT` 为空

- [ ] **Step 3: 实现 lib-common 派生**

`lib-common.sh:455-464` 整块替换为:

```bash
    # 全局派生变量(续): 离线文件路径 —— 2026-09-30 起按**版本目录**组织
    # (设计: docs/kubespray-versioning/design.md §4; 目录名 = 上游 tag 全名, 决策 D8)
    #   OFFLINE_FILES_ROOT  offline-files **真根**(各组件目录的共同父目录)
    #   KUBESPRAY_VERSION   kubespray 版本开关(单一入口); 默认 = 仓库当前树版本(galaxy.yml 派生)
    #   OFFLINE_FILES_DIR   k8s **资产目录** = <root>/kubespray/<版本>(裸二进制 + images/ + packages/)
    #   LOCAL_REPO_DIR      = OFFLINE_FILES_DIR —— 交给 kubespray 当 local_release_dir,
    #                       ⚠ 必须恰好是"裸二进制 + images/ + packages/"的那一层(树内 dest 全按扁平名读)
    #   ⚠ 显式设置的值一律保留(运维脚本/容器挂载按显式值走), 不回写
    OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
    if [ -z "${KUBESPRAY_VERSION:-}" ]; then
        KUBESPRAY_VERSION="$(kubespray_tree_version)"
    fi
    OFFLINE_FILES_DIR="${OFFLINE_FILES_DIR:-${OFFLINE_FILES_ROOT}/kubespray/${KUBESPRAY_VERSION}}"
    if [ -z "${LOCAL_REPO_DIR:-}" ]; then
        LOCAL_REPO_DIR="${OFFLINE_FILES_DIR}"
    fi
    # 运行根(交给 cubestack-offline.sh 当 BASE_DIR): 仓库树版本 → 仓库根; 物化版本 → versions/<V>
    if [ -z "${KUBESPRAY_BASE_DIR:-}" ]; then
        if [ "${KUBESPRAY_VERSION}" = "$(kubespray_tree_version)" ]; then
            KUBESPRAY_BASE_DIR="${REPO_ROOT}/deployments/kubespray"
        else
            KUBESPRAY_BASE_DIR="${REPO_ROOT}/deployments/kubespray/versions/${KUBESPRAY_VERSION}"
        fi
    fi
    export OFFLINE_FILES_ROOT KUBESPRAY_VERSION OFFLINE_FILES_DIR LOCAL_REPO_DIR KUBESPRAY_BASE_DIR
```

在 `load_config()` **之前**(与其它 helper 并列)新增:

```bash
# 仓库当前树版本(v 前缀; 缺失/异常输出空) —— 供 KUBESPRAY_VERSION 默认值机械派生(不写死)
kubespray_tree_version() {
    local galaxy="${REPO_ROOT}/deployments/kubespray/kubespray/galaxy.yml"
    [ -f "${galaxy}" ] || return 0
    awk '/^version:/{print "v"$2; exit}' "${galaxy}"
}
```

- [ ] **Step 4: cluster.conf.example 声明新变量**

`cluster.conf.example:491-497` 的"离线资源缓存根目录"整段替换为:

```bash
# 离线文件**真根**(所有组件目录的共同父目录; 组件内再按版本分层, 见 KUBESPRAY_VERSION)
#   offline-files/
#   ├── kubespray/<版本>/   ← KUBESPRAY_VERSION 决定的 k8s 资产目录(二进制 + images/ + packages/)
#   ├── metax-gpu/  ceph/  lws/ …(组件级规范, 按需迁移, 见 docs/kubespray-versioning/)
#   ⚠ 留空即由 lib-common 派生; 显式设置会同时改变各消费者路径(运维/容器挂载用)
OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-}"
# kubespray 版本(单一开关, 目录名 = 上游 tag 全名, 如 v2.32.0)
#   默认留空 = 仓库当前树版本(deployments/kubespray/kubespray/galaxy.yml 机械派生)
KUBESPRAY_VERSION="${KUBESPRAY_VERSION:-}"
# 版本套装档案(该版本的成套版本钉子; none = 不用档案, 全部按本文件)
KUBESPRAY_PROFILE="${KUBESPRAY_PROFILE:-}"
# k8s 资产目录 / 交给 kubespray 的 local_release_dir(留空 = lib-common 按上面两项派生)
OFFLINE_FILES_DIR="${OFFLINE_FILES_DIR:-}"
LOCAL_REPO_DIR="${LOCAL_REPO_DIR:-}"
```

- [ ] **Step 5: 跑测试确认通过**

Run: `bash deployments/scripts/tools/tests/test-kubespray-version-select.sh`
Expected: `== 全部通过 ==`,rc=0

- [ ] **Step 6: 挂进 check-modules ⑮ 套件清单**

`check-modules.sh` ⑮ 的 `for _t in …` 列表末尾追加 `test-kubespray-version-select.sh`:

```bash
for _t in test-kubespray-patches.sh test-update-kube-vip-addons.sh \
           test-api-entry-mode.sh test-api-local-lb.sh test-sync-api-entry.sh \
           test-kubespray-version-select.sh; do
```

- [ ] **Step 7: 全量静态校验 + 提交**

Run:
```bash
bash -n deployments/scripts/lib-common.sh
bash deployments/scripts/tools/check-modules.sh
```
Expected: 全绿(**⑯ 必须仍绿** —— 它按 cluster.conf.example 现算期望值;若因新变量报错,修实现不改断言)

```bash
git add deployments/scripts/lib-common.sh deployments/config/cluster.conf.example \
        deployments/scripts/tools/tests/test-kubespray-version-select.sh \
        deployments/scripts/tools/check-modules.sh
git commit -m "feat(kubespray): 版本目录变量层(OFFLINE_FILES_ROOT/KUBESPRAY_VERSION)与回归套件骨架"
```

---

### Task 2: 布局探针改为显式变量 + `paths` 自检子命令

**Files:**
- Modify: `deployments/kubespray/cubestack-offline.sh:11-44`(+ `paths` 子命令、usage)
- Modify: `deployments/scripts/modules/02_k8s/06_k8s_deploy.sh:188-197`
- Modify: `deployments/scripts/modules/02_k8s/07_k8s_scale.sh:297-303`
- Test: `deployments/scripts/tools/tests/test-kubespray-version-select.sh`

**Interfaces:**
- Consumes: Task 1 的 `OFFLINE_FILES_ROOT` / `KUBESPRAY_VERSION` / `OFFLINE_FILES_DIR`
- Produces: 子命令 `bash deployments/kubespray/cubestack-offline.sh paths`(只读,打印
  `BASE_DIR/KUBESPRAY_DIR/OFFLINE_LAYOUT/OFFLINE_FILES_ROOT/OFFLINE_FILES_DIR/LOCAL_REPO_DIR/INVENTORY_DIR`
  每行 `KEY=VALUE`);环境变量 `CUBESTACK_BASE_DIR`(版本根)、`CUBESTACK_LAYOUT=repo|flat`

- [ ] **Step 1: 套件加断言(先失败)**

追加到套件(在最后 `if [ "${fail}"` 之前):

```bash
echo "== ⑤ cubestack-offline.sh paths: 版本根 → 资产目录/树 推导正确(不靠目录名判定) =="
_offline_paths() { # _offline_paths <BASE_DIR>
    ( set +u; export CUBESTACK_BASE_DIR="$1" CLUSTER_CONF=/nonexistent \
        KUBESPRAY_VERSION="" OFFLINE_FILES_ROOT="" OFFLINE_FILES_DIR="" LOCAL_REPO_DIR=""
      bash "${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh" paths 2>/dev/null )
}
_fix="$(mktemp -d)"; mkdir -p "${_fix}/kubespray" "${_fix}/inventory"
out3="$(_offline_paths "${_fix}")"
chk "BASE_DIR=版本根 → KUBESPRAY_DIR 在其下" "${_fix}/kubespray" "$(_val "${out3}" KUBESPRAY_DIR)"
chk "OFFLINE_LAYOUT=repo(不再看父目录名)" "repo" "$(_val "${out3}" OFFLINE_LAYOUT)"
chk "OFFLINE_FILES_DIR 仍带版本层" \
    "${REPO_ROOT}/deployments/offline-files/kubespray/${TREE_VER}" "$(_val "${out3}" OFFLINE_FILES_DIR)"
rm -rf "${_fix}"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash deployments/scripts/tools/tests/test-kubespray-version-select.sh`
Expected: FAIL(未知参数 `paths` / 或 `OFFLINE_LAYOUT` 为空)

- [ ] **Step 3: 实现探针替换 + `paths` 子命令**

`cubestack-offline.sh:9-44` 的"布局判定 + default_local_repo_dir"整段替换为:

```bash
# 运行根与布局(2026-09-30 起**不再靠父目录名判定** —— 物化版本树的父目录名不叫 deployments,
#   旧判据会让它在物化后静默走错目录; 见 docs/kubespray-versioning/design.md §5.3):
#   CUBESTACK_BASE_DIR  运行根(默认 = 脚本目录; 物化版本时由模块传 deployments/kubespray/versions/<V>)
#   CUBESTACK_LAYOUT    布局: repo(默认, 离线件在 <repo>/deployments/offline-files)/ flat(standalone)
BASE_DIR="${CUBESTACK_BASE_DIR:-${SCRIPT_DIR}}"
KUBESPRAY_DIR="${CUBESTACK_KUBESPRAY_DIR:-${BASE_DIR}/kubespray}"
OFFLINE_LAYOUT="${CUBESTACK_LAYOUT:-repo}"
# 离线件真根: repo 布局从**脚本位置**推(脚本始终在 <repo>/deployments/kubespray/, 与运行根无关),
# 不随 BASE_DIR 漂移 —— 这是"物化树不搬离线件"的落点。
if [ "${OFFLINE_LAYOUT}" = "flat" ]; then
    OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-${BASE_DIR}/offline-files}"
else
    OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-$(dirname "$(dirname "${SCRIPT_DIR}")")/offline-files}"
fi
# kubespray 版本(单一开关; 默认 = 仓库当前树版本)。目录名 = 上游 tag 全名(D8)。
if [ -z "${KUBESPRAY_VERSION:-}" ]; then
    KUBESPRAY_VERSION="$(awk '/^version:/{print "v"$2; exit}' "${SCRIPT_DIR}/kubespray/galaxy.yml" 2>/dev/null || true)"
fi
OFFLINE_FILES_DIR="${OFFLINE_FILES_DIR:-${OFFLINE_FILES_ROOT}/kubespray/${KUBESPRAY_VERSION}}"
# 资产目录默认值(兼容旧调用): repo 布局 = 版本目录; flat 布局 = 版本目录(不再按集群名隔离)
default_local_repo_dir() { printf '%s\n' "${OFFLINE_FILES_DIR}"; }
```

> ⚠ 保留 `default_local_repo_dir()` 这个名字(第 2278 行仍在调用),只把它收敛到版本目录。

在参数解析处(子命令分发)新增只读自检子命令(放在 `--help/-h` 分支旁):

```bash
    paths)   # 只读: 打印全部路径推导(排障 + 回归套件用; 不联网/不碰集群/不需 root)
        printf 'BASE_DIR=%s\nKUBESPRAY_DIR=%s\nOFFLINE_LAYOUT=%s\nOFFLINE_FILES_ROOT=%s\nOFFLINE_FILES_DIR=%s\nLOCAL_REPO_DIR=%s\nINVENTORY_DIR=%s\n' \
            "${BASE_DIR}" "${KUBESPRAY_DIR}" "${OFFLINE_LAYOUT}" "${OFFLINE_FILES_ROOT}" \
            "${OFFLINE_FILES_DIR}" "${CUBESTACK_LOCAL_REPO_DIR:-$(default_local_repo_dir)}" \
            "${CUBESTACK_INVENTORY_DIR:-${BASE_DIR}/inventory}"
        exit 0 ;;
```

并把 `paths` 写进 usage 块(该脚本头部 `echo "  download [名称] …"` 那一段)。

- [ ] **Step 4: 模块传入 CUBESTACK_BASE_DIR**

`06_k8s_deploy.sh:188-197` 与 `07_k8s_scale.sh:297-303` 的 `OFFLINE_ENV=( … )` 各加一行:

```bash
    "CUBESTACK_BASE_DIR=${KUBESPRAY_BASE_DIR:-${REPO_ROOT}/deployments/kubespray}"
```

- [ ] **Step 5: 跑测试 + 全量校验**

Run:
```bash
bash deployments/scripts/tools/tests/test-kubespray-version-select.sh
bash -n deployments/kubespray/cubestack-offline.sh
bash deployments/scripts/tools/check-modules.sh
```
Expected: 套件全通过;check-modules 全绿(⑨ 会 bash -n 该脚本)

- [ ] **Step 6: 提交**

```bash
git add deployments/kubespray/cubestack-offline.sh \
        deployments/scripts/modules/02_k8s/06_k8s_deploy.sh \
        deployments/scripts/modules/02_k8s/07_k8s_scale.sh \
        deployments/scripts/tools/tests/test-kubespray-version-select.sh
git commit -m "fix(kubespray): 布局探针改显式变量 + paths 自检子命令(物化树不再静默走错目录)"
```

---

### Task 3: 版本档案(profile)机制

**Files:**
- Create: `deployments/config/profiles/v2.32.0.profile`
- Modify: `deployments/scripts/lib-common.sh`(load_config 里在 source cluster.conf 之后接管版本面)
- Modify: `deployments/scripts/deploy-cluster.sh`(新增 `--profile <V>` 参数 + help)
- Test: `deployments/scripts/tools/tests/test-kubespray-version-select.sh`

**Interfaces:**
- Consumes: Task 1 的 `KUBESPRAY_VERSION`
- Produces: `KUBESPRAY_PROFILE`(值 = 档案名或 `none`);档案文件 `deployments/config/profiles/<名>.profile`
  (可被 source 的纯赋值行,含 `KUBESPRAY_VERSION=` 与版本面变量)

- [ ] **Step 1: 套件加断言(先失败)**

```bash
echo "== ⑥ 档案: 选定档案接管版本面; none = 不用档案; 缺档案 = 响亮失败 =="
_probe_prof() { # _probe_prof <档案名> <额外 conf 行...>
    local p="$1"; shift
    local c; c="$(mktemp)"
    _conf "$@" > "${c}"
    ( set +u
      export CLUSTER_CONF="${c}" KUBESPRAY_PROFILE="${p}"
      export OFFLINE_FILES_ROOT="" KUBESPRAY_VERSION="" OFFLINE_FILES_DIR="" LOCAL_REPO_DIR=""
      source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      load_config >/dev/null 2>&1
      printf 'KUBESPRAY_PROFILE=%s\nK8S_VERSION=%s\n' "${KUBESPRAY_PROFILE}" "${K8S_VERSION:-}" )
    rm -f "${c}"
}
# ⑥a 选了在库档案 → 其 K8S_VERSION 生效(cluster.conf 的同名默认不得覆盖)
outp="$(_probe_prof v2.32.0 "${NODES_CONF}" 'K8S_VERSION="${K8S_VERSION:-v9.9.9}"')"
chk "档案接管 K8S_VERSION" "$(awk -F= '/^K8S_VERSION=/{sub(/^[^=]*=/,""); print; exit}' \
    "${REPO_ROOT}/deployments/config/profiles/v2.32.0.profile")" "$(_val "${outp}" K8S_VERSION)"
# ⑥b KUBESPRAY_PROFILE=none → 完全按 cluster.conf
outn="$(_probe_prof none "${NODES_CONF}" 'K8S_VERSION="${K8S_VERSION:-v9.9.9}"')"
chk "none 时用 cluster.conf 值" "v9.9.9" "$(_val "${outn}" K8S_VERSION)"
# ⑥c 选了不存在的档案 → rc!=0 且报错(不得静默继续)
set +e
( set +u; c="$(mktemp)"; _conf "${NODES_CONF}" > "${c}"
  export CLUSTER_CONF="${c}" KUBESPRAY_PROFILE=v9.9.9
  source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
  load_config ) >/dev/null 2>&1
rc=$?
set -e
chk "缺档案 → 非零退出" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash deployments/scripts/tools/tests/test-kubespray-version-select.sh`
Expected: FAIL(档案机制不存在;`KUBESPRAY_PROFILE` 未生效)

- [ ] **Step 3: 写档案文件(值 = 当前树表值)**

创建 `deployments/config/profiles/v2.32.0.profile`(值从 `cluster.conf.example` §3.3 原样搬,
它们已被 ⑯ 断言与 v2.32 树表值一致):

```bash
# 版本套装档案: kubespray v2.32.0(k8s 1.35 线)
# 规则(见 docs/kubespray-versioning/design.md §3.2):
#   · 选定档案后, 本文件的版本面变量**接管** cluster.conf 的同名变量(档案 > cluster.conf);
#   · 要手工钉某一项 → KUBESPRAY_PROFILE=none;
#   · 字段与真值由 check-modules.sh ⑯ 对照该版本树表值断言(禁人手抄)。
KUBESPRAY_VERSION=v2.32.0
K8S_VERSION=v1.35.8
PAUSE_VERSION=3.10.1
COREDNS_VERSION=v1.12.4
DNS_NODE_CACHE_VERSION=1.25.0
ETCD_VERSION=v3.6.14
CALICO_VERSION=v3.31.7
METRICS_SERVER_VERSION=v0.9.0
CPA_VERSION=v1.10.3
API_LB_NGINX_IMAGE_TAG=1.30.1-alpine
LOCAL_VOLUME_PROVISIONER_VERSION=2.5.0
NFD_VERSION=0.19.0
```

- [ ] **Step 4: 实现档案接管**

`lib-common.sh` 的 `load_config()` 中,在 `source "${CLUSTER_CONF}"`(第 424 行)之后、
`# 宿主机物理 IP 自动检测` 之前插入:

```bash
    # 版本档案接管(2026-09-30): 选定 KUBESPRAY_PROFILE 后, 该版本的**版本面变量**以档案为准
    # (档案 > cluster.conf)。理由: 让 --profile v2.28.0 不会静默变成"v2.28 资产 + v1.35.8 钉子"。
    #   none / 空 → 不用档案(全部按 cluster.conf, 等价历史行为)
    #   选了不存在的档案 → 响亮失败(不静默继续)
    if [ -n "${KUBESPRAY_PROFILE:-}" ] && [ "${KUBESPRAY_PROFILE}" != "none" ]; then
        _prof_file="${REPO_ROOT}/deployments/config/profiles/${KUBESPRAY_PROFILE}.profile"
        if [ -f "${_prof_file}" ]; then
            # shellcheck disable=SC1090
            source "${_prof_file}"
            KUBESPRAY_PROFILE="${KUBESPRAY_PROFILE}"   # 记录实际生效的档案名
            vlog "版本档案生效: ${_prof_file}"
        else
            err "版本档案不存在: ${_prof_file}(KUBESPRAY_PROFILE=${KUBESPRAY_PROFILE}; 用 none 可禁用档案)"
            return 1
        fi
        unset _prof_file
    fi
```

> ⚠ `load_config` 目前无返回值约定;`err()` 只打印不退出 ⇒ 这里必须显式 `return 1`,并确认调用方
> (`deploy-cluster.sh` / 模块)对非零返回**会退出**;若不会,在 `load_config` 内改为 `exit 1`
> (实现时以 `grep -n 'load_config' deploy-cluster.sh` 的实际用法定,选**确实能让部署停下**的那个)。

`deploy-cluster.sh` 参数解析新增:

```bash
        --profile)  PROFILE_ARG="$2"; shift 2 ;;
        --profile=*) PROFILE_ARG="${1#*=}"; shift ;;
```
并在调用 `load_config` 之前 `[ -n "${PROFILE_ARG:-}" ] && export KUBESPRAY_PROFILE="${PROFILE_ARG}"`,
同时写进 usage(与 `--steps/--enable` 同段,示例:`--profile v2.32.0   使用该版本档案(不写回 cluster.conf)`)。

- [ ] **Step 5: 跑测试确认通过 + 全量校验**

Run:
```bash
bash deployments/scripts/tools/tests/test-kubespray-version-select.sh
bash -n deployments/scripts/lib-common.sh deployments/scripts/deploy-cluster.sh
bash deployments/scripts/tools/check-modules.sh
```
Expected: 全绿(⑯ 读 cluster.conf.example,不受档案文件影响)

- [ ] **Step 6: 提交**

```bash
git add deployments/config/profiles/v2.32.0.profile deployments/scripts/lib-common.sh \
        deployments/scripts/deploy-cluster.sh \
        deployments/scripts/tools/tests/test-kubespray-version-select.sh
git commit -m "feat(kubespray): 版本套装档案机制(档案接管版本面 + none 逃生阀 + --profile)"
```

---

### Task 4: 版本目录工具(list / verify / materialize)

**Files:**
- Create: `deployments/kubespray/cubestack-version-dir.sh`
- Test: `deployments/scripts/tools/tests/test-kubespray-version-select.sh`(新增 fixture 断言)

**Interfaces:**
- Produces: 子命令 `list` / `verify <V>` / `materialize <V>`(Plan B 的 `new` 在 Task 5 加);
  退出码 0=通过,1=校验不过,2=参数/环境错
- Consumes: `OFFLINE_FILES_ROOT`、`KUBESPRAY_VERSION`

- [ ] **Step 1: 写 fixture 断言(先失败)**

```bash
echo "== ⑦ version-dir: list/verify 对 fixture 版本目录的行为 =="
_ro="$(mktemp -d)"; _vd="${_ro}/kubespray/v9.9.9"
mkdir -p "${_vd}/images" "${_vd}/packages"
printf 'LOCAL_ONLY\n' > "${_vd}/LOCAL_ONLY"
printf 'KUBESPRAY_VERSION=v9.9.9\n' > "${_vd}/VERSION.profile"
vout="$(OFFLINE_FILES_ROOT="${_ro}" bash "${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh" list 2>&1)"
printf '%s\n' "${vout}" | grep -q 'v9.9.9' && chk "list 找到 fixture 版本" 1 1 || chk "list 找到 fixture 版本" 1 0
printf '%s\n' "${vout}" | grep -q 'LOCAL_ONLY\|本地临时' && chk "list 标注本地临时档位" 1 1 || chk "list 标注本地临时档位" 1 0
set +e
OFFLINE_FILES_ROOT="${_ro}" bash "${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh" verify v9.9.9 >/dev/null 2>&1
rc=$?
set -e
chk "verify 对残缺版本目录 → 非零(缺 tree.tar.gz)" 1 "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
rm -rf "${_ro}"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash deployments/scripts/tools/tests/test-kubespray-version-select.sh`
Expected: FAIL(脚本不存在)

- [ ] **Step 3: 实现 `cubestack-version-dir.sh`**

头部注释写清用途/退出码;核心内容(骨架 + 三个子命令):

```bash
#!/bin/bash
# ============================================================
# cubestack-version-dir.sh — kubespray 版本目录: 列出 / 校验 / 物化
#   版本目录 = ${OFFLINE_FILES_ROOT}/kubespray/<版本>/(版本名 = 上游 tag 全名, 决策 D8)
#   内容: tree.tar.gz(预打补丁的整树, 不含 .venv 与 inventory/local)+ images/ + packages/
#         + 裸二进制 + VERSION.profile + 可选 LOCAL_ONLY(本地临时版本标记, 不上 MinIO)
#   设计: docs/kubespray-versioning/design.md §9.1
# 用法: bash cubestack-version-dir.sh list
#       bash cubestack-version-dir.sh verify <版本>
#       bash cubestack-version-dir.sh materialize <版本>     # → deployments/kubespray/versions/<版本>/
# 退出码: 0=通过; 1=校验不过; 2=参数/环境错误
# ============================================================
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
OFFLINE_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
VERSIONS_DIR="${REPO_ROOT}/deployments/kubespray/versions"
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
bad()  { echo -e "\033[31m❌ $*\033[0m"; }
say()  { echo -e "\033[36m→ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }

vd_dir() { printf '%s\n' "${OFFLINE_ROOT}/kubespray/$1"; }

cmd_list() {
    local d name tier
    shopt -s nullglob
    for d in "${OFFLINE_ROOT}"/*/*/; do
        [ -d "${d}" ] || continue
        name="$(basename "${d}")"                     # 版本
        local comp; comp="$(basename "$(dirname "${d}")")"
        [ -f "${d}/LOCAL_ONLY" ] && tier="本地临时(不入库/不上 MinIO)" || tier="在库"
        local has_tree="无 tree.tar.gz"; [ -f "${d}/tree.tar.gz" ] && has_tree="有 tree.tar.gz"
        local n_img; n_img="$(find "${d}/images" -maxdepth 1 -name '*.tar' 2>/dev/null | wc -l)"
        printf '  %-12s %-10s %-28s %-16s images=%s\n' "${comp}" "${name}" "${tier}" "${has_tree}" "${n_img}"
    done
    shopt -u nullglob
}

cmd_verify() {
    local v="$1" d rc=0
    d="$(vd_dir "${v}")"
    [ -d "${d}" ] || { bad "版本目录不存在: ${d}"; return 1; }
    [ -f "${d}/tree.tar.gz" ] || { bad "缺 tree.tar.gz: ${d}"; rc=1; }
    if [ -f "${d}/tree.tar.gz.sha256" ]; then
        ( cd "${d}" && sha256sum -c --quiet tree.tar.gz.sha256 ) || { bad "tree.tar.gz 指纹不符"; rc=1; }
    else
        warn "无 tree.tar.gz.sha256(旧目录?), 跳过指纹校验"
    fi
    [ -f "${d}/VERSION.profile" ] || { bad "缺 VERSION.profile(自包含档案副本)"; rc=1; }
    [ -d "${d}/images" ] && [ -n "$(find "${d}/images" -maxdepth 1 -name '*.tar' -print -quit 2>/dev/null)" ] \
        || { bad "images/ 为空"; rc=1; }
    [ "${rc}" = "0" ] && ok "版本目录校验通过: ${v}"
    return "${rc}"
}

cmd_materialize() {
    local v="$1" d dst
    d="$(vd_dir "${v}")"; dst="${VERSIONS_DIR}/${v}"
    [ -f "${d}/tree.tar.gz" ] || { bad "缺 ${d}/tree.tar.gz"; return 1; }
    if [ -d "${dst}/kubespray" ] && [ -f "${dst}/.tree.sha256" ] \
       && [ "$(cat "${dst}/.tree.sha256")" = "$(sha256sum "${d}/tree.tar.gz" | awk '{print $1}')" ]; then
        ok "已物化且指纹一致(跳过): ${dst}"; return 0
    fi
    mkdir -p "${dst}"
    tar -xzf "${d}/tree.tar.gz" -C "${dst}"
    sha256sum "${d}/tree.tar.gz" | awk '{print $1}' > "${dst}/.tree.sha256"
    ok "已物化: ${dst}/kubespray(版本 ${v})"
}
```

`main` 分发:`list` / `verify <v>` / `materialize <v>`,未知子命令打印用法并 `exit 2`。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash deployments/scripts/tools/tests/test-kubespray-version-select.sh`
Expected: 全通过

- [ ] **Step 5: 全量校验 + 提交**

Run: `bash -n deployments/kubespray/cubestack-version-dir.sh && bash deployments/scripts/tools/check-modules.sh`
Expected: 全绿(⑮ 新套件也跑)

```bash
# 物化目录必须在首次 materialize 之前就忽略掉(否则会作为未跟踪目录出现在 git status 里)
grep -q 'deployments/kubespray/versions/' .gitignore || \
  printf '\n# 物化版本树(由 cubestack-version-dir.sh materialize 生成; 见 docs/kubespray-versioning/)\ndeployments/kubespray/versions/\n' >> .gitignore
git check-ignore -q deployments/kubespray/versions/v9.9.9/kubespray && echo "✅ versions/ 已忽略"

git add deployments/kubespray/cubestack-version-dir.sh \
        deployments/scripts/tools/tests/test-kubespray-version-select.sh .gitignore
git commit -m "feat(kubespray): 版本目录工具 list/verify/materialize + 忽略物化目录"
```

---

### Task 5: `new` 子命令(造版本目录:树 + tar + 指纹 + 档案骨架)

**Files:**
- Modify: `deployments/kubespray/cubestack-version-dir.sh`
- Test: `deployments/scripts/tools/tests/test-kubespray-version-select.sh`

**Interfaces:**
- Produces: `new <标签> --from-root <deployments/kubespray 形状的目录> [--local] [--assets-from DIR]`;
  产出 `<版本>/tree.tar.gz` + `tree.tar.gz.sha256` + `VERSION.profile` + (可选)`LOCAL_ONLY`
- Consumes: 上游树 + 该版本的 `cubestack-patch-apply.sh --check`(补丁在位判据)

- [ ] **Step 1: fixture 断言(先失败)**

用**假树**造一个最小 `--from-root`(含 `kubespray/galaxy.yml` + 桩 `cubestack-patch-apply.sh --check` rc=0):

```bash
echo "== ⑧ version-dir new: 预验证(补丁不在位必须拒收) =="
_src="$(mktemp -d)"; mkdir -p "${_src}/kubespray"
printf 'version: 9.9.9\n' > "${_src}/kubespray/galaxy.yml"
printf '#!/bin/bash\n[ "${1:-}" = "--check" ] && exit 0\n' > "${_src}/cubestack-patch-apply.sh"; chmod +x "${_src}/cubestack-patch-apply.sh"
_ro2="$(mktemp -d)"
OFFLINE_FILES_ROOT="${_ro2}" bash "${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh" \
    new v9.9.9 --from-root "${_src}" --local >/dev/null 2>&1
chk "new 成功产出 tree.tar.gz" 1 "$([ -f "${_ro2}/kubespray/v9.9.9/tree.tar.gz" ] && echo 1 || echo 0)"
chk "new 产出 VERSION.profile" 1 "$([ -f "${_ro2}/kubespray/v9.9.9/VERSION.profile" ] && echo 1 || echo 0)"
chk "--local 落 LOCAL_ONLY 标记" 1 "$([ -f "${_ro2}/kubespray/v9.9.9/LOCAL_ONLY" ] && echo 1 || echo 0)"
# 反证: 补丁不在位 → 拒收
printf '#!/bin/bash\nexit 1\n' > "${_src}/cubestack-patch-apply.sh"; chmod +x "${_src}/cubestack-patch-apply.sh"
set +e
OFFLINE_FILES_ROOT="${_ro2}" bash "${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh" \
    new v9.9.8 --from-root "${_src}" >/dev/null 2>&1
rc=$?
set -e
chk "补丁不在位 → rc!=0 且不产物" 1 "$([ "${rc}" -ne 0 ] && [ ! -d "${_ro2}/kubespray/v9.9.8" ] && echo 1 || echo 0)"
rm -rf "${_src}" "${_ro2}"
```

- [ ] **Step 2: 跑测试确认失败** → FAIL(未知子命令 new)

- [ ] **Step 3: 实现 `new`**

```bash
cmd_new() { # new <标签> --from-root DIR [--local] [--assets-from DIR]
    local v="$1"; shift
    local from_root="" local_only=0 assets_from=""
    while [ $# -gt 0 ]; do case "$1" in
        --from-root) from_root="$2"; shift 2 ;;
        --assets-from) assets_from="$2"; shift 2 ;;
        --local) local_only=1; shift ;;
        *) bad "未知参数: $1"; return 2 ;;
    esac; done
    [ -n "${from_root}" ] || { bad "缺 --from-root <部署根>(需含 kubespray/ 与 cubestack-patch-apply.sh)"; return 2; }
    [ -d "${from_root}/kubespray" ] || { bad "--from-root 下无 kubespray/: ${from_root}"; return 2; }
    local d; d="$(vd_dir "${v}")"
    [ -e "${d}" ] && { bad "版本目录已存在(先删或换版本): ${d}"; return 1; }
    # ① 预验证: 补丁必须在位 —— 只打包"已验证过"的树(设计 §5.2)
    if [ -x "${from_root}/cubestack-patch-apply.sh" ]; then
        say "预验证补丁在位: ${from_root}/cubestack-patch-apply.sh --check"
        bash "${from_root}/cubestack-patch-apply.sh" --check || { bad "补丁不在位 → 拒收(先按 docs/kubespray-upgrade.md 重放)"; return 1; }
    else
        bad "缺 cubestack-patch-apply.sh(无法证明补丁在位) → 拒收"; return 1
    fi
    # ② 树版本自洽: galaxy.yml 版本 == 目录名(去 v)
    local gal_ver; gal_ver="$(awk '/^version:/{print $2; exit}' "${from_root}/kubespray/galaxy.yml")"
    [ "v${gal_ver}" = "${v}" ] || { bad "galaxy.yml 版本 v${gal_ver} ≠ 目录名 ${v}"; return 1; }
    mkdir -p "${d}"
    say "打包树 → ${d}/tree.tar.gz(排除 .venv / inventory/local)"
    tar -czf "${d}/tree.tar.gz" -C "${from_root}/kubespray" \
        --exclude='./.venv' --exclude='./inventory/local' . || { bad "打包失败"; return 1; }
    ( cd "${d}" && sha256sum tree.tar.gz > tree.tar.gz.sha256 )
    # ③ 档案骨架: 版本面变量**从该树表值机械推导**(禁手抄)
    _derive_profile "${from_root}/kubespray" "${v}" > "${d}/VERSION.profile" || { bad "档案骨架推导失败"; return 1; }
    [ "${local_only}" = "1" ] && printf '本地临时版本: 不入 git、不上 MinIO(设计 D4)\n' > "${d}/LOCAL_ONLY"
    [ -n "${assets_from}" ] && { say "拷入资产: ${assets_from}"; cp -a "${assets_from}"/. "${d}"/ ; }
    ok "版本目录已产出: ${d}"
}
```

`_derive_profile <树> <版本>`:按 ⑯ 同款解析式从树内表取真值,**直接复用 `check-modules.sh:603-780`
的现有 awk 与 `_ksd_cmp` 取法**(kubelet_checksums 成员判定见 `:664-670`/`:718-724`;download.yml 表值
见 `:745-777`)—— 不得另造一套口径。先支持 k8s 基座 12 项;任一取不到 → 报错退出(不写空值骨架)。

- [ ] **Step 4: 跑测试确认通过**
- [ ] **Step 5: 全量校验 + 提交**

```bash
git add deployments/kubespray/cubestack-version-dir.sh deployments/scripts/tools/tests/test-kubespray-version-select.sh
git commit -m "feat(kubespray): version-dir new —— 预验证补丁在位后打包树 + 机械推导档案骨架"
```

---

### Task 6: check-modules ⑯ 逐版本 + 新增 ⑱ 版本目录自检

**Files:**
- Modify: `deployments/scripts/tools/check-modules.sh`(⑯ 扩展;新增 ⑱;头部清单同步)

**Interfaces:**
- Consumes: Task 3 的档案文件;Task 4/5 的版本目录结构
- Produces: ⑯ 对"在库档案"与"在场版本目录"逐版本断言;⑱ 断言 tar 指纹/档案副本一致/LOCAL_ONLY 不自相矛盾

- [ ] **Step 1: 写反证 fixture(先证明检查能红)**

```bash
# 在临时 OFFLINE_FILES_ROOT 里放一个"钉子与树表值不符"的 fixture, 断言 ⑯ 报错
```
(实现方式:⑯ 的版本目录分支读 `OFFLINE_FILES_ROOT` 环境变量;用 fixture 跑 `check-modules.sh --quiet`
并断言 rc!=0 且输出含"版本目录"。)

- [ ] **Step 2: 跑一次确认当前不报错(即新检查确实还没生效)** → rc=0(现 ⑯ 不覆盖)
- [ ] **Step 3: 实现 ⑯ 扩展 + ⑱**

⑯ 追加(在现有 A/B/C 断言之后):对 `deployments/config/profiles/*.profile` 逐个断言其版本面值
== 对应版本树表值(档案与树目录名同源时读仓库树;否则读该版本目录里的 `tree.tar.gz` 解出的树);
对 `${OFFLINE_FILES_ROOT}/kubespray/*/` 逐个断言:目录里 `kubeadm-${K8S_VERSION}-amd64` 等关键件存在、
`etc.d` 版本与 `VERSION.profile` 一致;**一个版本目录都没有时打印"跳过(无在场版本目录)"**。

⑱ 新增:tar 指纹(`sha256sum -c`)、`VERSION.profile` 与入库档案一致(不一致 → 告警不判死,因为
本地临时版本可以没有入库档案;但**有入库档案却内容不同** → 判死)、`LOCAL_ONLY` 与"是否有入库档案"
不矛盾(本地临时版本不应有入库档案)。

`check-modules.sh` 头部注释的项数(`1/17 … 17/17`)与清单同步改成 18 项。

- [ ] **Step 4: 跑反证 + 全量校验**

Run:
```bash
bash deployments/scripts/tools/check-modules.sh --quiet   # 期望 rc=0(当前树无版本目录 → 跳过)
# 再用 fixture 触发红:
OFFLINE_FILES_ROOT=<fixture> bash deployments/scripts/tools/check-modules.sh --quiet
```
Expected: 正例 rc=0;反例 rc=1 且点名 fixture

- [ ] **Step 5: 提交**

```bash
git commit -m "feat(check-modules): ⑯ 逐版本断言 + ⑱ 版本目录自检"
```

---

### Task 7: 离线链路 —— fetch 二级选择 / sync 排除本地临时版本 / trim 版本化

**Files:**
- Modify: `deployments/scripts/tools/offline/fetch-offline-from-minio.sh`(嵌套 `--sub`、`--kubespray-version`、`--list` 二级、help 修正)
- Modify: `deployments/scripts/tools/offline/sync-to-minio.sh`(`LOCAL_ONLY` 排除;prune 收窄 + `--force-full-prune`)
- Modify: `deployments/scripts/tools/offline/trim-offline-files.sh`(路径统一到 `OFFLINE_FILES_ROOT`;限定版本目录;多版本告警;`--dry-run` 不再要求 root)
- Test: `deployments/scripts/tools/tests/test-kubespray-version-select.sh`(新增 ⑨ 断言)

**Interfaces:**
- Produces: `fetch --kubespray-version <V>` ≡ `--sub kubespray/<V>`;`sync` 自动跳过 `LOCAL_ONLY`;
  `trim --version <V>`(默认 = `KUBESPRAY_VERSION`)

- [ ] **Step 1: 断言(先失败,全部离线可跑)**

```bash
echo "== ⑨ 离线链路: 本地临时版本排除 / trim 只动选定版本 / fetch 参数 =="
_ro3="$(mktemp -d)"; mkdir -p "${_ro3}/kubespray/v9.9.9/images" "${_ro3}/kubespray/v9.9.8/images"
printf 'LOCAL_ONLY\n' > "${_ro3}/kubespray/v9.9.9/LOCAL_ONLY"
touch "${_ro3}/kubespray/v9.9.9/images/a.tar" "${_ro3}/kubespray/v9.9.8/images/b.tar"
# ⑨a sync-to-minio: 列出"将上传/将跳过"的版本(纯函数子命令, 不碰 MinIO)
sout="$(OFFLINE_FILES_ROOT="${_ro3}" bash "${REPO_ROOT}/deployments/scripts/tools/offline/sync-to-minio.sh" \
        --plan-versions 2>&1)"
printf '%s\n' "${sout}" | grep -q 'v9.9.9.*跳过\|跳过.*v9.9.9' && chk "sync 跳过 LOCAL_ONLY 版本" 1 1 || chk "sync 跳过 LOCAL_ONLY 版本" 1 0
# ⑨b trim --dry-run(非 root 可用): 只列选定版本的删除计划, 不触碰其它版本
tout="$(OFFLINE_FILES_ROOT="${_ro3}" bash "${REPO_ROOT}/deployments/scripts/tools/offline/trim-offline-files.sh" \
        --dry-run --version v9.9.8 2>&1)"
printf '%s\n' "${tout}" | grep -q 'v9.9.9' && chk "trim 不触碰其它版本" 0 1 || chk "trim 不触碰其它版本" 0 0
# ⑨c fetch: --kubespray-version 参数被识别(离线只验参数解析, 不连 MinIO)
set +e
bash "${REPO_ROOT}/deployments/scripts/tools/offline/fetch-offline-from-minio.sh" --kubespray-version v9.9.9 --help >/dev/null 2>&1
rc=$?; set -e
chk "fetch 识别 --kubespray-version" 0 "${rc}"
rm -rf "${_ro3}"
```

- [ ] **Step 2: 跑测试确认失败** → FAIL(未知参数)
- [ ] **Step 3: 实现三处改动**

- `sync-to-minio.sh`:
  - `--plan-versions`(只读子命令:扫 `<root>/<组件>/<版本>/LOCAL_ONLY`,打印"将跳过/将上传"清单,不碰 mc);
  - 实际 mirror 前,若有 `LOCAL_ONLY` 版本 → 用 `--exclude` 逐个排除(`mc mirror` 支持
    `--exclude 'kubespray/v9.9.9/*'`)并打印;
  - `--prune` 语义收窄:无 `--sub` 且存在版本目录时,`--remove` 需显式 `--force-full-prune`,否则拒跑并说明。
- `fetch-offline-from-minio.sh`:
  - `--sub` 放宽为任意相对路径(`mc_has`/`mc mirror` 本就支持嵌套;去掉"仅第一层"的隐含假设);
  - 新增 `--kubespray-version <V>` ≡ `--sub kubespray/<V>`(与 `--sub` 互斥,同时给 → 报错);
  - `--list` 输出到二级(组件 → 版本);
  - 帮助文本补 `--all`、`--kubespray-version`(修 2.3 的"承诺与实现不一致")。
- `trim-offline-files.sh`:
  - 路径统一:`OFFLINE_ROOT="${OFFLINE_FILES_ROOT:-…}"`,`KUBE_DIR="${OFFLINE_ROOT}/kubespray/${VER}"`
    (修 2.7 ① 的硬 bug);
  - 新增 `--version <V>`(默认 `KUBESPRAY_VERSION`);删除动作只在该目录内;
  - 启动时列出同组件其它版本目录并声明"本次不触碰";
  - `--dry-run` 不再要求 root(只读)。

- [ ] **Step 4: 跑测试确认通过;全量校验**

Run:
```bash
bash deployments/scripts/tools/tests/test-kubespray-version-select.sh
bash -n deployments/scripts/tools/offline/{fetch-offline-from-minio,sync-to-minio,trim-offline-files}.sh
bash deployments/scripts/tools/check-modules.sh
```

- [ ] **Step 5: 提交**

```bash
git commit -m "feat(offline): 版本目录支持 —— fetch 二级选择/sync 排除本地临时版本/trim 版本化"
```

---

### Task 8: 迁移 v2.32 资产到 `v2.32.0/` + images.manifest 落点版本化

**Files:**
- Modify(落点): `deployments/scripts/tools/images/lib-image-manifest.sh:164-172`
- Modify: `deployments/scripts/tools/images/check-image-manifest.sh`(`--kubespray-version` 透传)
- Modify(**前置**:`.gitignore` —— 迁移前必须先放行两层 README,否则迁移瞬间 README 从 git 消失)
- Move(本地,非 git): `deployments/offline-files/kubespray/*` → `deployments/offline-files/kubespray/v2.32.0/`
- Create(本地): `.../v2.32.0/tree.tar.gz`(+`sha256`)、`VERSION.profile`、`README.md`

**Interfaces:**
- Consumes: Task 1/3 的变量与档案;Task 5 的 `new`
- Produces: 在库版本 `v2.32.0`(资产齐套 + 树 tar + 档案副本 + 版本目录 README)

- [ ] **Step 1a: `.gitignore` 放行两层 README(迁移的**前置**,顺序不能反)**

现有四行规则之后追加两行(顺序要紧:先放行二级**目录**本身,git 才会往里走,深度三的 README 才可能被放行):

```
deployments/offline-files/*
!deployments/offline-files/*/
deployments/offline-files/*/*
!deployments/offline-files/*/*/          ← 新增: 放行版本目录本身
deployments/offline-files/*/*/*          ← 新增: 重新忽略版本目录下的内容(tar/二进制)
!deployments/offline-files/*/*/README.md ← 新增: 只放行版本目录里的 README
```

**必须实测**(仓库曾被 .gitignore 顺序坑过两次,别凭推理):

```bash
touch deployments/offline-files/kubespray/v2.32.0/.ignore-probe.tar
git check-ignore -v deployments/offline-files/kubespray/v2.32.0/README.md   # 期望: 命中 !.../*/*/README.md(不忽略)
git check-ignore -v deployments/offline-files/kubespray/v2.32.0/.ignore-probe.tar  # 期望: 命中 offline-files/*/*/*
rm -f deployments/offline-files/kubespray/v2.32.0/.ignore-probe.tar
git add .gitignore deployments/offline-files/kubespray/README.md   # 此时 README 仍在原位, 先提交 ignore 规则
git commit -m "chore(offline): gitignore 放行版本目录内的 README(迁移前置)"
```

- [ ] **Step 1b: 落点版本化(代码)**

`lib-image-manifest.sh` **不 source lib-common**(文件头第 13-14 行明确:CI 上必须独立跑)⇒ 本库要
**自派生** `KUBESPRAY_VERSION`(否则会拼出 `kubespray//images`):

```bash
# 版本层(2026-09-30): k8s 资产目录 = <base>/kubespray/<版本>/images。
# ⚠ 本库不 source lib-common(CI 独立跑), 故 KUBESPRAY_VERSION 未设时**自己从树内 galaxy.yml 派生**。
_kubespray_version() {
    [ -n "${KUBESPRAY_VERSION:-}" ] && { printf '%s\n' "${KUBESPRAY_VERSION}"; return; }
    local g="${IM_REPO_ROOT}/deployments/kubespray/kubespray/galaxy.yml"
    [ -f "${g}" ] && awk '/^version:/{print "v"$2; exit}' "${g}"
}
image_group_dir() {
    local group="$1"
    local base="${IMAGE_OFFLINE_ROOT:-${IM_REPO_ROOT}/deployments/offline-files}"
    local ver; ver="$(_kubespray_version)"
    case "${group}" in
        # kubespray 基座 + ceph: 节点 containerd **预加载**走 kubespray 的 images/ 目录(必须同目录);
        #   2026-09-30 起带版本层(k8s-base/ceph 的 tar 属该 kubespray 版本, 见 design §6.5)
        k8s-base|ceph) echo "${IMAGE_K8S_IMAGES_DIR:-${base}/kubespray/${ver}/images}" ;;
        *)             echo "${base}/${group}" ;;
    esac
}
```

- [ ] **Step 2: 迁移本地资产(文件系统操作,可回滚)**

```bash
cd deployments/offline-files/kubespray
mkdir -p v2.32.0
# 先列"将移动什么"(干跑), 再执行
ls -1 | grep -v '^v2\.32\.0$' | sed 's/^/  mv /'
for x in $(ls -1 | grep -v '^v2\.32\.0$'); do mv "${x}" v2.32.0/; done
```

> ⚠ Step 1a 的 ignore 规则必须**已提交**再执行本步 —— 否则 `README.md` 迁进版本目录后会被忽略,
> 一次 `git add -A` 就会把它从库里删掉(正是 `deployments/scripts/README.md:2` 警告的那种事故)。
> 迁移后立刻核对:`git status --short deployments/offline-files/kubespray/` 应显示
> `R  README.md -> v2.32.0/README.md`(重命名),**不得**显示 `D README.md`。

- [ ] **Step 3: 产出 tree.tar.gz + VERSION.profile(用 Task 5 的工具)**

```bash
bash deployments/kubespray/cubestack-version-dir.sh new v2.32.0 \
     --from-root "$(pwd)/deployments/kubespray" --assets-from deployments/offline-files/kubespray/v2.32.0
bash deployments/kubespray/cubestack-version-dir.sh verify v2.32.0
```
⚠ `new` 会拒收补丁不在位的树 —— 这正是"预验证"闸门;若报 MISSING,先按 `docs/kubespray-upgrade.md` 处理。

- [ ] **Step 4: 校验落点**

```bash
bash deployments/scripts/tools/images/check-image-manifest.sh --kubespray      # ④/⑤ 必须过
bash deployments/scripts/tools/check-manifests.sh
bash deployments/scripts/tools/check-modules.sh                                 # ⑯ ⑱ 逐版本断言
git status --short deployments/offline-files/                                   # 只应看到 README 重命名
```
Expected: 全绿。
> 注意两条**判据边界**(免得误判"已验证"):① `check-image-manifest.sh` 的 ④b **主动跳过 k8s-base/ceph**
> (`:110-111` 的 `case`)且只是 warn —— 所以"版本目录齐套"的**真判据**是 `cubestack-version-dir.sh verify`
> + check-modules ⑱ + `check_offline_files` 预检,不是这个脚本;② ⑤(k8s-base ↔ PRELOAD_IMAGE_PATTERNS
> 交叉核对)必须仍绿 —— 它只比模式串,不受目录层级影响。

- [ ] **Step 5: 提交(只提交代码与 README;资产/tar 均 gitignored)**

```bash
git add deployments/scripts/tools/images/lib-image-manifest.sh \
        deployments/scripts/tools/images/check-image-manifest.sh
git commit -m "feat(images): k8s-base/ceph 镜像落点跟随版本目录 + v2.32 资产迁入 v2.32.0/"
```

---

### Task 9: v2.28.0 本地临时版本(机制实证,**不上传**)

**Files:**
- Create(本地,gitignored): `deployments/offline-files/kubespray/v2.28.0/`(含 `LOCAL_ONLY`)
- Create(本地): `deployments/kubespray/versions/v2.28.0/`(materialize 产物)

**Interfaces:**
- Consumes: Task 5 的 `new --local`、Task 4 的 `materialize/verify`
- Produces: 第二个真实版本目录,用于验证"选择/预检/物化/钉子"

- [ ] **Step 1: 从 tag 取 v2.28 树(不改工作区)**

```bash
_ts="$(mktemp -d)"
git archive kubespray-2.28.0-cubestack deployments/kubespray | tar -x -C "${_ts}"
ls "${_ts}/deployments/kubespray/kubespray/galaxy.yml"   # 期望 version: 2.28.0
```

- [ ] **Step 2: 造本地临时版本目录**

```bash
bash deployments/kubespray/cubestack-version-dir.sh new v2.28.0 \
     --from-root "${_ts}/deployments/kubespray" \
     --assets-from /data/offline-superseded-20260928 --local
```

- [ ] **Step 3: 按 v2.28 树表值核对资产齐套并补齐**

```bash
bash deployments/kubespray/cubestack-version-dir.sh verify v2.28.0     # 列出缺失件
# 缺件按该版本树表值补(镜像走 Harbor: harbor-save-images.sh --group k8s-base --kubespray-version v2.28.0)
# ⚠ 老 tar 的文件名是旧命名(images_*.tar), 补/改名按 lib-image-manifest.sh 的规范名
```
Expected: `verify` 全绿(或明确列出**补齐不了**的件,如实记录在 README)

- [ ] **Step 4: 物化 + 版本选择实证(不装集群)**

```bash
bash deployments/kubespray/cubestack-version-dir.sh materialize v2.28.0
KUBESPRAY_VERSION=v2.28.0 bash deployments/kubespray/cubestack-offline.sh paths | tee /tmp/p28
KUBESPRAY_VERSION=v2.32.0 bash deployments/kubespray/cubestack-offline.sh paths | tee /tmp/p32
diff /tmp/p28 /tmp/p32      # 期望: 资产目录/树/BASE_DIR 三处不同, 其余相同
KUBESPRAY_VERSION=v2.28.0 sudo bash deployments/scripts/deploy-cluster.sh --list-steps >/dev/null  # 不报错
```

- [ ] **Step 5: 记录验证结论(本地临时版本的边界)**

在 `docs/kubespray-versioning/README.md` 中记录:两版本共存实证、v2.28 的补齐情况、
**明确未做**(未真装集群)。

---

### Task 10: v2.32.0 上 MinIO + 二级下载实证(**需用户确认后执行**)

**Files:** 无代码改动(纯操作 + 记录)

- [ ] **Step 1: 干跑(只读)**

```bash
sudo bash deployments/scripts/tools/offline/sync-to-minio.sh --dry-run
```
Expected: 输出里 **v2.28.0 被跳过(本地临时版本)**、v2.32.0 的上传清单可见

- [ ] **Step 2: 请用户确认上传**(⚠ 对外动作:远端会新增对象)

- [ ] **Step 3: 真上传 + 核对**

```bash
sudo bash deployments/scripts/tools/offline/sync-to-minio.sh
mc ls minio/cubestack-installer/offline-files/kubespray/          # 期望只看到 v2.32.0/
```

- [ ] **Step 4: 二级下载实证(只拉一个小子目录,避免 4GB)**

```bash
bash deployments/scripts/tools/offline/fetch-offline-from-minio.sh --list           # 二级列表可见 v2.32.0
bash deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
     --kubespray-version v2.32.0 --sub kubespray/v2.32.0/packages --dest /tmp/fetch-probe -y
ls /tmp/fetch-probe/kubespray/v2.32.0/packages | head
```

- [ ] **Step 5: 记录**(README 里补"如何只下载指定版本"一段)

---

### Task 11: 字面路径 6 处 + `.dockerignore` / `.gitignore`

**Files:**
- Modify: `deployments/scripts/tools/node/reconcile-node-packages.sh:54-55`
- Modify: `deployments/scripts/modules/03_addon/02_ceph.sh:163-164`(lvm2 通配)
- Modify: `deployments/scripts/modules/03_addon/22_verify_registry_storage.sh:74`
- Modify: `deployments/scripts/tools/offline/sync-to-container.sh:158`
- Modify: `deployments/scripts/tools/docker/build-cli-context.sh:97-98`
- Modify: `.dockerignore:40-64`

- [ ] **Step 1: 逐处改经变量**(统一口径:`${OFFLINE_FILES_DIR}` = 版本资产目录;`${OFFLINE_FILES_ROOT}` = 真根)
- [ ] **Step 2: `.dockerignore`** 路径加版本层(`deployments/offline-files/kubespray/*/images` 等)——
  该文件无变量能力,只能逐条改;以 `Dockerfile-cli` 的 `COPY` 清单为准逐条对齐(两处必须成对改)
- [ ] **Step 3: 校验**

```bash
bash -n <改动的脚本>
bash deployments/scripts/tools/check-modules.sh
```

---

### Task 12: 文档与 skill 沉淀(交付物的一部分)

**Files:**
- Create: `docs/kubespray-versioning/README.md`(使用手册:怎么选版本/下载指定版本/产出新版本/迁移 operator)
- Modify: `docs/kubespray-upgrade.md`(补"与版本目录的关系"一节,**不动 SOP**)
- Modify: `docs/scripts-development-spec.md`(§7 指向版本目录规范)
- Modify: `.claude/skills/cubestack-deploy-scripts/SKILL.md`(新增"版本目录"小节 + 审查清单两项)
- Modify: `.claude/skills/cubestack-add-module/SKILL.md`(新模块若带离线资产 → 版本目录规范)

- [ ] **Step 1: 写 `docs/kubespray-versioning/README.md`**(含 Task 9/10 的实证结论与边界)
- [ ] **Step 2: 三处引用同步修改**
- [ ] **Step 3: 最终全量验证**

```bash
bash deployments/scripts/tools/check-modules.sh
bash deployments/scripts/tools/check-manifests.sh
bash deployments/scripts/tools/images/check-image-manifest.sh --kubespray
```
加 CI 等价快照验证(用 `git ls-files --cached --others --exclude-standard | tar` 造快照 + 抽 run 块真跑,
做法同 2026-09-30 的 CI 落地)。

- [ ] **Step 4: 提交** `docs(kubespray): 版本目录使用手册 + 升级/规范/skill 同步`

---

## Self-Review(写完计划后自检)

**Spec 覆盖:** D1(Task 5/8 的 tree.tar.gz)、D2(Task 3 档案 + Task 11 operator 规范)、D3(Task 8/10 两层目录)、
D4(Task 9/10 的 LOCAL_ONLY 与"不入库不上传")、D5(Task 9 明确不装集群)、D6(Task 12 只补文档不改脚本)、
D7(Task 12 的 operator 迁移规范)、D8(Task 1/5 的全 tag 约束)、§4(Task 1/2)、§5(Task 4/5/2)、§6(Task 7/8/10/11)、
§7(Task 6/4)、§9(Task 5/12)、§10(Task 9/12 的验证矩阵与边界)、§11(Task 1–12 逐项对应)。

**已知需要执行者现场确认的点(非占位,是真实分支):**
- Task 3 Step 4:`load_config` 失败路径要"确实能让部署停下"(以 `deploy-cluster.sh` 实际用法定)。
- Task 5 Step 3:`_derive_profile` 的取表式**复用** `check-modules.sh:603-780` 的现有 awk 与 `_ksd_cmp`,
  不得新造口径。
- Task 8 Step 1a:`.gitignore` 六行规则必须**实测**(`git check-ignore -v`)后才迁移 —— 顺序反了会让
  `kubespray/README.md` 从 git 消失(仓库文档 `deployments/scripts/README.md:2` 明写过这个坑)。
- Task 8 Step 3:`new` 会拒收补丁不在位的树 —— 若真报 MISSING,按升级 SOP 处理后再打包(不是绕过)。
- Task 9 Step 3:1.32 线缺件能否补齐取决于 Harbor/网络;补不齐就**如实记录**,不得把缺失写成已验证。
- Task 8 Step 4 的判据边界:版本目录齐套**不看** `check-image-manifest.sh` ④b(它主动跳过 k8s-base/ceph
  且只是 warn),看 `version-dir verify` + ⑱ + `check_offline_files`。
