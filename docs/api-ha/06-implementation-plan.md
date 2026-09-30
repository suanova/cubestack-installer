# API 入口高可用（本地代理 + kube-vip）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让"节点侧 API 出口"不再依赖任何一台具体 master（kubespray 原生每节点本地代理），同时保留/支持外部稳定入口（kube-vip VIP 或环境已有 LB），并支持完全没有 VIP 的场景。

**Architecture:** 在 `cluster.conf` 引入三个正交开关；由 `lib-common.sh` 提供模式判定与入口地址解析；`sync-kubespray-config.sh` 作为 `all.yml` 的唯一写入者，按模式**摘掉或保留** `loadbalancer_apiserver` 块 —— 摘掉后上游 kubespray 自动把 worker 的 kubelet/kube-proxy 指向 `localhost:6443`（本机 nginx-proxy 静态 Pod）、master 指向 `127.0.0.1:6443`。新增一个模块补齐上游不做的两件事（节点 `/etc/hosts` 域名行收敛、关闭时的 manifest 清理），并新增一个验证模块。

**Tech Stack:** Bash 5（模块化部署脚本）、kubespray（vendored）、kube-proxy ipvs、kube-vip 静态 Pod、skopeo（离线镜像流水线）

**Spec:** [docs/api-ha/04-decision.md](04-decision.md)（设计文档组：`docs/api-ha/README.md` 起）

## Global Constraints

- **本轮只改代码与文档，不对任何运行中的集群执行变更**（用户 2026-09-28 明确）。
- **只面向全新安装**：不写存量集群的迁移/证书重签流程。
- 所有模块脚本以 `set -euo pipefail` 开头，并 `source .../lib-common.sh` + `load_config`。
- **值函数契约**：任何会被 `$(...)` 捕获的函数**只准向 stdout 输出值**（IPv4 字面量），诊断一律走 `vlog` / `say`（它们写 stderr）。违反会导致 `sed: unterminated 's' command` 类事故（历史事故记录：`lib-common.sh` 的 `vlog` 曾写 stdout）。
- **`emit_ip()` 是唯一的 IP 输出通道**，新增的地址类值函数必须复用它。
- 新增模块必须带完整元数据头：`MODULE` / `DESC` / `PHASE` / `DEFAULT` / `REPEAT` / `TOGGLE` / `REQUIRES`，并遵守 `.claude/skills/cubestack-add-module/SKILL.md`。
- **提交纪律**：本工作区索引里有历史遗留的 471 个已暂存删除项。**每次提交必须用 pathspec 限定**（`git commit -- <明确路径>`），禁止裸 `git commit`。
- **提交信息不带** `Co-Authored-By` 尾注（用户明确要求）。
- 所有验证以 `bash deployments/scripts/tools/check-modules.sh` 退出码 0 为准（仓库唯一的静态校验入口）。

---

## Task 1: 离线镜像补齐 `nginx:1.27.4-alpine`

> ⚠ **2026-09-28 两处追注(本文件是当时的任务日志, 正文保留原样)**:
> ① 文中 nginx tag `1.27.4-alpine` 随 kubespray v2.32 换代已改为 **`1.30.1-alpine`**(活文档 02/04 与
>    `cluster.conf.example` 均已更新);
> ② 文中 Task 6 写的"第 ⑫ 项"在落地时为 **⑬ 项**(⑫ 被 ceph 磁盘链路回归占用),活文档 04/README 已按 ⑬ 表述。
>
> ⚠ **2026-09-29 第三处追注**：下文代码块里的 `KUBE_VIP_ENABLED:-true` 是**当时的兜底默认值**，
> 该开关 **2026-09-24 已翻转为 `false`**（理由见 [../kube-vip-api-ha.md](../kube-vip-api-ha.md) 决策 D2），
> 活代码（`lib-common.sh` 的 `api_entry_mode` / `api_entry_validate_config`）用的是 `:-false`。
> 另：kube-vip 的静态 Pod 清单在 2026-09-28 **收编**后改由 kubespray 渲染（见
> [07-kube-vip-upstream-assessment.md](07-kube-vip-upstream-assessment.md)），本文件里凡涉及"自持渲染"的描述均已作废。

**Files:**
- Modify: `deployments/config/cluster.conf.example`（镜像版本节，`NGINX_TAG` 附近）
- Modify: `deployments/config/cluster.conf`（同节）
- Modify: `deployments/config/images.manifest`（`k8s-base` 组末尾）
- Modify: `deployments/scripts/tools/offline/trim-offline-files.sh:41`（内置默认 pattern）
- Modify: `deployments/offline-files/kubespray/README.md`
- Test: `deployments/scripts/tools/images/check-image-manifest.sh`

**Interfaces:**
- Consumes: 无（本任务是最前置的准备工作）
- Produces: 节点 containerd 中存在 `docker.io/library/nginx:1.27.4-alpine`，供 Task 4 的静态 Pod 拉起

**背景（为什么落 `k8s-base` 组）**：静态 Pod 只能从节点本地 containerd 拉镜像，而预加载链路只扫
`deployments/offline-files/kubespray/images/*.tar`（`cubestack-offline.sh:490` 的 `LOCAL_REPO_DIR/images`）。
`images.manifest` 的 `k8s-base` 组正是映射到该目录（`lib-image-manifest.sh:181-190`）。
放进 `offline-files/nginx/` 会被 `ensure_registry_nginx` 的 `nginx*.tar` glob 误捞；用派生名
（`docker.io_library_nginx_1.27.4-alpine.tar`）则天然不命中该 glob，零干扰。

- [ ] **Step 1: 加版本变量（2 处，值必须一致）**

`deployments/config/cluster.conf.example` 的「镜像版本（★ 升级入口）」节、`NGINX_TAG` 行附近加：

```bash
API_LB_NGINX_IMAGE_TAG="${API_LB_NGINX_IMAGE_TAG:-1.27.4-alpine}"  # API 本地代理静态 Pod 用; 必须与 kubespray nginx_image_tag 同值
```

`deployments/config/cluster.conf` 同位置加同一行。

验证：

```bash
grep -n 'API_LB_NGINX_IMAGE_TAG' deployments/config/cluster.conf deployments/config/cluster.conf.example
# 期望：两份文件各出现 1 次
```

- [ ] **Step 2: 清单登记 1 行**

`deployments/config/images.manifest` 的 `k8s-base` 组末尾（现行 `:79` 的 busybox 行之后、下一组注释之前）追加：

```
# API 本地代理(kubespray nginx-proxy 静态 Pod)用; tag 必须与 kubespray download.yml 的 nginx_image_tag 一致
k8s-base  docker.io/library/nginx:${API_LB_NGINX_IMAGE_TAG}
```

**不要**加第 3 列（那是给"历史短名"镜像的覆盖名，用了就不走派生名机制）。

验证：

```bash
bash deployments/scripts/tools/images/check-image-manifest.sh
# 期望：① 解析成功 / ② 全限定且带 tag / ③ 无重复 ref / ④ 各 group 目录可推 —— 全部通过，退出码 0
```

- [ ] **Step 3: `PRELOAD_IMAGE_PATTERNS` 三处同步（漏一处就会被静默删除）**

三处的值必须**一字不差**，均在末尾追加 `library_nginx`：

| # | 文件 | 位置 |
|---|---|---|
| ① | `deployments/config/cluster.conf` | `:921` `PRELOAD_IMAGE_PATTERNS="${PRELOAD_IMAGE_PATTERNS:-… busybox lws_manager}"` |
| ② | `deployments/config/cluster.conf.example` | `:774` 同项 |
| ③ | `deployments/scripts/tools/offline/trim-offline-files.sh` | `:41` 内置默认值 |

改完后 ③ 的形态：

```bash
DEFAULT_PATTERNS="calico_cni calico_kube-controllers calico_node etcd kube-apiserver kube-controller-manager kube-proxy kube-scheduler coredns cluster-proportional-autoscaler k8s-dns-node-cache metrics-server pause metallb kube-vip library_registry local-path-provisioner busybox lws_manager library_nginx"
```

（变量名以该文件实际为准；只改值，不改结构。）

- [ ] **Step 4: 运行静态校验（本任务的验收测试）**

```bash
bash deployments/scripts/tools/images/check-image-manifest.sh --kubespray
```

Expected: 通过。若失败会打印：

```
❌ ⑤ k8s-base 镜像不在 PRELOAD_IMAGE_PATTERNS 内, 会被 trim 删除: docker.io_library_nginx_1.27.4-alpine.tar
```

说明 Step 3 的某一处没同步。

- [ ] **Step 5: 更新离线目录 README**

`deployments/offline-files/kubespray/README.md` 增补一条：镜像 ref、对应的版本变量、tar 名规则、
取镜像命令（`harbor-save-images.sh --group k8s-base`）、消费方（kubespray 预加载 → nginx-proxy 静态 Pod）、
升级时要同步改 `kubespray/roles/kubespray_defaults/defaults/main/download.yml` 的 `nginx_image_tag`。

- [ ] **Step 6: 提交**

```bash
git add deployments/config/images.manifest deployments/config/cluster.conf.example \
        deployments/scripts/tools/offline/trim-offline-files.sh \
        deployments/offline-files/kubespray/README.md
git commit -- deployments/config/images.manifest deployments/config/cluster.conf.example \
        deployments/scripts/tools/offline/trim-offline-files.sh \
        deployments/offline-files/kubespray/README.md \
  -m "feat(api-ha): 登记 API 本地代理所需 nginx 镜像(k8s-base 组)并同步预加载模式"
```

> `deployments/config/cluster.conf` 是各环境本地文件，**不入库**（仓库既有约定），只改不改提交。

- [ ] **Step 7: 联网侧产出 tar（在能访问 Harbor 的机器上执行，非本机）**

```bash
# 同步到 Harbor（CI 会在 push 到 main 后自动做；手工路径如下）
bash deployments/scripts/tools/images/harbor-sync-images.sh --list | grep nginx      # 先看计划
HARBOR_MIRROR_USER=<u> HARBOR_MIRROR_PASSWORD=<p> \
  bash deployments/scripts/tools/images/harbor-sync-images.sh --group k8s-base

# 拉成离线 tar
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group k8s-base
```

产物：`deployments/offline-files/kubespray/images/docker.io_library_nginx_1.27.4-alpine.tar`

验证（文件名 + tar 内容双确认，**RepoTags 为空数组 = 重下**）：

```bash
ls -l deployments/offline-files/kubespray/images/docker.io_library_nginx_1.27.4-alpine.tar
python3 -c "
import tarfile,json
p='deployments/offline-files/kubespray/images/docker.io_library_nginx_1.27.4-alpine.tar'
print(json.load(tarfile.open(p).extractfile('manifest.json'))[0]['RepoTags'])"
# 期望输出: ['docker.io/library/nginx:1.27.4-alpine']
```

---

## Task 2: `lib-common.sh` 配置模型与模式判定

**Files:**
- Modify: `deployments/scripts/lib-common.sh`
- Modify: `deployments/config/cluster.conf`、`deployments/config/cluster.conf.example`（新增 3 个开关 + 更新 kube-vip 注释块）
- Test: `deployments/scripts/tools/tests/test-api-entry-mode.sh`（新建，桩式单元测试）

**Interfaces:**
- Consumes: 既有 `bool_is_true`（`lib-common.sh:1025`）、`emit_ip`（`:143`）、`first_master_ip`、`kube_vip_resolve_target`（`:997`）、`kube_vip_recorded_address`（`:860`）
- Produces（Task 3/4/5/6/7 依赖这些名字与返回）:
  - `api_local_lb_enabled()` → 返回码 0/1
  - `api_entry_mode()` → stdout `external|vip|node`
  - `api_entry_addr()` → stdout 单个 IPv4 字面量
  - `api_entry_validate_config()` → 返回码 0/1（失败已 err）
  - `kube_vip_current_entry()` → 行为扩展（无 all.yml 值时回退 addons.yml 记录值）

- [ ] **Step 1: 先写失败的测试**

新建 `deployments/scripts/tools/tests/test-api-entry-mode.sh`：

```bash
#!/bin/bash
# 桩式单元测试: API 入口模式判定(不连集群, 只验纯函数)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export CLUSTER_CONF="$(mktemp)"
fail=0
chk() { # chk <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi
}

_run() { # _run <conf 内容> <表达式>
    printf '%s\n' "$1" > "${CLUSTER_CONF}"
    ( set +u; source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      load_config >/dev/null 2>&1
      eval "$2" )
}

echo "== api_entry_mode =="
chk "external 优先" "external" "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; API_EXTERNAL_ADDR=10.0.0.9' 'api_entry_mode')"
chk "vip" "vip" "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; KUBE_VIP_ENABLED=true' 'api_entry_mode')"
chk "node 回退" "node" "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; KUBE_VIP_ENABLED=false' 'api_entry_mode')"

echo "== api_local_lb_enabled (含兼容别名) =="
chk "显式 true" "0" "$(_run 'API_LOCAL_LB_ENABLED=true' 'api_local_lb_enabled; echo $?')"
chk "显式 false" "1" "$(_run 'API_LOCAL_LB_ENABLED=false' 'api_local_lb_enabled; echo $?')"
chk "未定义+旧开关 true → 别名生效" "0" "$(_run 'KUBE_VIP_LOCAL_PROXY=true' 'api_local_lb_enabled; echo $?')"
chk "未定义+旧开关未设 → 关(旧行为)" "1" "$(_run 'X=1' 'api_local_lb_enabled; echo $?')"

echo "== api_entry_addr =="
chk "external 直出" "10.0.0.9" "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; API_EXTERNAL_ADDR=10.0.0.9' 'api_entry_addr')"
chk "node 取首 master" "10.0.0.1" "$(_run 'NODES=("master,m1,10.0.0.1,ubuntu,p") ; KUBE_VIP_ENABLED=false' 'api_entry_addr')"

echo "== api_entry_validate_config 互斥 =="
chk "external + kube-vip → 失败" "1" "$(_run 'API_EXTERNAL_ADDR=10.0.0.9 ; KUBE_VIP_ENABLED=true' 'api_entry_validate_config; echo $?')"
chk "external + haproxy → 失败" "1" "$(_run 'API_EXTERNAL_ADDR=10.0.0.9 ; KUBE_VIP_ENABLED=false ; HAPROXY_ENABLED=true' 'api_entry_validate_config; echo $?')"
chk "external 单独 → 通过" "0" "$(_run 'API_EXTERNAL_ADDR=10.0.0.9 ; KUBE_VIP_ENABLED=false' 'api_entry_validate_config; echo $?')"
chk "非法 IP → 失败" "1" "$(_run 'API_EXTERNAL_ADDR=not-an-ip ; KUBE_VIP_ENABLED=false' 'api_entry_validate_config; echo $?')"

rm -f "${CLUSTER_CONF}"
[ "${fail}" = "0" ] && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash deployments/scripts/tools/tests/test-api-entry-mode.sh`
Expected: 多项 FAIL（`api_entry_mode: command not found` 之类）

> 说明：`deployments/scripts/tools/tests/` 是**本计划新建的目录**（仓库此前没有 shell 单元测试约定，
> 只有 `check-modules.sh` 静态校验）。已确认该路径**不被 `.gitignore` 忽略**，可以入库。
> 桩测试只做纯函数验证、不连任何集群；每个用例在子 shell 里跑，`source lib-common.sh` 的加载副作用
> （`ensure_skopeo_policy` 尝试补 `/etc/containers/policy.json`）被 `>/dev/null 2>&1` 吞掉，不影响断言。

- [ ] **Step 3: 在 `lib-common.sh` 新增四个函数**

插入位置：`bool_is_true()` 定义之后（当前 `:1025` 附近），紧邻 kube-vip 段落，便于阅读。

```bash
# ---------------- API 入口: 模式判定与地址解析(见 docs/api-ha/04-decision.md §2) ----------------

# 节点侧本地代理(kubespray nginx-proxy 静态 Pod)是否启用。
# 兼容别名: 旧开关 KUBE_VIP_LOCAL_PROXY(新方案起并入本开关, 见 cluster.conf 注释)。
# 用法: api_local_lb_enabled && echo 开
api_local_lb_enabled() {
    if [ -n "${API_LOCAL_LB_ENABLED:-}" ]; then
        bool_is_true "${API_LOCAL_LB_ENABLED}"
    else
        bool_is_true "${KUBE_VIP_LOCAL_PROXY:-false}"
    fi
}

# 入口模式三选一(优先级: external > vip > node)。纯函数, 只读开关。
# 用法: mode="$(api_entry_mode)"
api_entry_mode() {
    if [ -n "${API_EXTERNAL_ADDR:-}" ]; then printf 'external\n'; return 0; fi
    if bool_is_true "${KUBE_VIP_ENABLED:-true}"; then printf 'vip\n'; return 0; fi
    printf 'node\n'; return 0
}

# 当前生效的 API 入口地址(全部返回值都是 IPv4 字面量, 供 /etc/hosts、kubeconfig 等消费)。
#   external → API_EXTERNAL_ADDR
#   vip      → kube_vip_resolve_target(内含两阶段: 未绑=首 master / 已绑=VIP)
#   node     → 第一个 master IP(无 HA, 由 api_entry_validate_config 不拦、由调用方 warn)
# 用法: addr="$(api_entry_addr)" || exit 1
api_entry_addr() {
    case "$(api_entry_mode)" in
        external) emit_ip "${API_EXTERNAL_ADDR}" || return 1 ;;
        vip)      kube_vip_resolve_target ;;
        *)
            local _m; _m="$(first_master_ip)" || return 1
            emit_ip "${_m}" || return 1
            ;;
    esac
}

# 入口配置的硬校验(互斥 + 取值合法性)。失败即 err 并 return 1。
# 用法: api_entry_validate_config || exit 1   (须已 load_config)
api_entry_validate_config() {
    if [ -n "${API_EXTERNAL_ADDR:-}" ]; then
        if bool_is_true "${KUBE_VIP_ENABLED:-true}"; then
            err "API_EXTERNAL_ADDR=${API_EXTERNAL_ADDR} 与 KUBE_VIP_ENABLED=true 互斥 —— 入口只能有一个来源:"
            err "  复用环境已有 LB/VIP → 请设 KUBE_VIP_ENABLED=false"
            err "  由本方案自带 VIP → 请清空 API_EXTERNAL_ADDR"
            return 1
        fi
        if bool_is_true "${HAPROXY_ENABLED:-false}" || bool_is_true "${KEEPALIVED_ENABLED:-false}"; then
            err "API_EXTERNAL_ADDR 与 HAPROXY_ENABLED/KEEPALIVED_ENABLED 互斥(三者都在提供 API 入口)"
            return 1
        fi
        emit_ip "${API_EXTERNAL_ADDR}" >/dev/null 2>&1 || {
            err "API_EXTERNAL_ADDR 不是合法 IPv4 字面量: ${API_EXTERNAL_ADDR}"
            return 1
        }
    fi
    if bool_is_true "${KUBE_VIP_LOCAL_PROXY:-false}" && [ -n "${API_LOCAL_LB_ENABLED:-}" ] \
       && ! bool_is_true "${API_LOCAL_LB_ENABLED}"; then
        err "KUBE_VIP_LOCAL_PROXY=true 与 API_LOCAL_LB_ENABLED=false 冲突:"
        err "  KUBE_VIP_LOCAL_PROXY 已是 API_LOCAL_LB_ENABLED 的兼容别名, 只保留其中一个"
        return 1
    fi
    return 0
}
```

> ⚠ **实作更正（2026-09-28 C1）**：上面的 `api_entry_validate_config()` 列表**早于交付版**——
> 交付版在该函数末尾追加了 **node 模式的显式 warn**（"外部/管理入口回退第一个 master ⇒ 无 HA"，
> 进程内去重、不拦停），落实 D5 / §2.2 的承诺；`api_entry_addr()` 的注释也随之从"由调用方 warn"
> 改为"由 api_entry_validate_config 显式 warn"。**以 `deployments/scripts/lib-common.sh` 的实现为准**。

- [ ] **Step 4: 改造 `kube_vip_validate_config()` 的第 ⑤ 项**

把当前"`KUBE_VIP_LOCAL_PROXY=true` 一律硬失败"（`lib-common.sh:827-841`）替换为：

```bash
    # ⑤ 本地代理: 旧开关 KUBE_VIP_LOCAL_PROXY 已并入 API_LOCAL_LB_ENABLED, 本方案起**真正生效**
    #    (实现路径 = 摘掉 all.yml 的 loadbalancer_apiserver 块, 让上游按 localhost 分支分派)
    if bool_is_true "${KUBE_VIP_LOCAL_PROXY:-false}" && [ -n "${API_LOCAL_LB_ENABLED:-}" \
       ] && ! bool_is_true "${API_LOCAL_LB_ENABLED}"; then
        err "KUBE_VIP_LOCAL_PROXY=true 但 API_LOCAL_LB_ENABLED=false —— 两个开关冲突, 请只留一个"
        return 1
    fi
    return 0
```

并在该函数**开头**增加一行调用（保证 external 互斥也在这里被验到）：

```bash
    api_entry_validate_config || return 1
```

- [ ] **Step 5: 扩展 `kube_vip_current_entry()`（保证 VIP 不漂移）**

原实现只读 `all.yml` 的 `loadbalancer_apiserver.address`。本地代理模式下该块被注释掉 → 读不到 →
`kube_vip_derive()` 会退到"探测推导"，**每次运行都可能选到不同地址**（证书 SAN 反复变）。
在其函数体末尾（读到空值时）增加回退：

```bash
    # 本地代理模式下 all.yml 的 loadbalancer_apiserver 块保持注释 → 回退到 addons.yml 记录值,
    # 让 VIP 在多次运行间保持稳定(见 docs/kube-vip-api-ha.md 的稳定性说明)
    if [ -z "${_cur}" ]; then
        _cur="$(kube_vip_recorded_address)"
    fi
    printf '%s\n' "${_cur}"
```

（变量名以实际实现为准；核心是"读不到时回退 `kube_vip_recorded_address`"。）

- [ ] **Step 6: `cluster.conf` / `.example` 加开关**

在 kube-vip 区块（`cluster.conf:80-104`）内新增并改写：

```bash
API_EXTERNAL_ADDR="${API_EXTERNAL_ADDR:-}"              # 环境已有 LB/VIP 地址(与 KUBE_VIP_ENABLED 互斥; 留空=不用)
API_LOCAL_LB_ENABLED="${API_LOCAL_LB_ENABLED:-true}"    # 节点侧本地代理(kubespray nginx-proxy 静态 Pod): 每 worker 127.0.0.1:6443 → 全部 master
API_LOCAL_LB_TYPE="${API_LOCAL_LB_TYPE:-nginx}"         # nginx | haproxy
```

同时把 `KUBE_VIP_LOCAL_PROXY` 那行的注释改为"**兼容别名**（新方案起并入 `API_LOCAL_LB_ENABLED`，单独用仍然有效）"，
并删除 92-104 行里"路线1 推荐 / 路线2 代价"的旧结论，改为指向 `docs/api-ha/`。

- [ ] **Step 7: 运行测试确认通过**

Run: `bash deployments/scripts/tools/tests/test-api-entry-mode.sh`
Expected: 全部通过，退出码 0

- [ ] **Step 8: 静态校验**

Run: `bash deployments/scripts/tools/check-modules.sh && bash -n deployments/scripts/lib-common.sh`
Expected: 退出码 0

- [ ] **Step 9: 提交**

```bash
git add deployments/scripts/lib-common.sh deployments/scripts/tools/tests/test-api-entry-mode.sh \
        deployments/config/cluster.conf.example
git commit -- deployments/scripts/lib-common.sh deployments/scripts/tools/tests/test-api-entry-mode.sh \
        deployments/config/cluster.conf.example \
  -m "feat(api-ha): 新增 API 入口模式判定(external/vip/node)与本地代理开关"
```

---

## Task 3: `sync-kubespray-config.sh` 按模式写 `all.yml`

**Files:**
- Modify: `deployments/scripts/tools/k8s/sync-kubespray-config.sh`
- Test: `deployments/scripts/tools/tests/test-sync-api-entry.sh`（新建，桩式）

**Interfaces:**
- Consumes: Task 2 的 `api_local_lb_enabled()` / `api_entry_mode()` / `api_entry_addr()` / `api_entry_validate_config()`
- Produces: `all.yml` 的确定状态 ——
  - 本地代理开：`loadbalancer_apiserver` 块**被注释**、`loadbalancer_apiserver_localhost: true`、
    `supplementary_addresses_in_ssl_keys` 含 域名 + 全部 master IP + 入口地址
  - 本地代理关：块**取消注释**、`loadbalancer_apiserver_localhost: false`、行为同现状

- [ ] **Step 1: 先写失败的测试**

新建 `deployments/scripts/tools/tests/test-sync-api-entry.sh`：

```bash
#!/bin/bash
# 桩式测试: 验证 all.yml 在两种模式下的收敛结果(不连集群)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

mk_fixture() {  # mk_fixture <目录>
    local d="$1"; rm -rf "${d}"; mkdir -p "${d}/group_vars/all" "${d}/group_vars/k8s_cluster"
    cat > "${d}/group_vars/all/all.yml" <<'EOF'
loadbalancer_apiserver_localhost: false
apiserver_loadbalancer_domain_name: "k8s-api.cubestack.io"
loadbalancer_apiserver:
  address: 10.0.0.1
  port: 6443
supplementary_addresses_in_ssl_keys:
  - k8s-api.cubestack.io
  - 10.0.0.1
EOF
    : > "${d}/group_vars/k8s_cluster/k8s-cluster.yml"
    : > "${d}/group_vars/k8s_cluster/addons.yml"
    : > "${d}/group_vars/k8s_cluster/k8s-net-calico.yml"
}

echo "== 本地代理开: 块被注释 + localhost: true =="
D1="$(mktemp -d)"; mk_fixture "${D1}"
KUBESPRAY_INV_DIR="${D1}" API_LOCAL_LB_ENABLED=true KUBE_VIP_ENABLED=false \
  NODES=('master,m1,10.0.0.1,ubuntu,p') bash "${REPO_ROOT}/deployments/scripts/tools/k8s/sync-kubespray-config.sh" >/dev/null 2>&1
chk "loadbalancer_apiserver 已注释" "0" "$(grep -c '^loadbalancer_apiserver:' "${D1}/group_vars/all/all.yml")"
chk "localhost=true" "1" "$(grep -c '^loadbalancer_apiserver_localhost: true' "${D1}/group_vars/all/all.yml")"
rm -rf "${D1}"

echo "== 本地代理关: 块恢复 + localhost: false =="
D2="$(mktemp -d)"; mk_fixture "${D2}"
KUBESPRAY_INV_DIR="${D2}" API_LOCAL_LB_ENABLED=false KUBE_VIP_ENABLED=false \
  NODES=('master,m1,10.0.0.1,ubuntu,p') bash "${REPO_ROOT}/deployments/scripts/tools/k8s/sync-kubespray-config.sh" >/dev/null 2>&1
chk "loadbalancer_apiserver 未注释" "1" "$(grep -c '^loadbalancer_apiserver:' "${D2}/group_vars/all/all.yml")"
chk "localhost=false" "1" "$(grep -c '^loadbalancer_apiserver_localhost: false' "${D2}/group_vars/all/all.yml")"
rm -rf "${D2}"

[ "${fail}" = "0" ] && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
```

> 注：环境变量需先导出（`export API_LOCAL_LB_ENABLED=...`）才能穿透到子进程；实现时按实际调用方式调整。
> 若 `sync-kubespray-config.sh` 依赖过多集群事实而难以桩测，退化为"**只测新函数**"：
> 把 `update_api_entry_all_yml()` 写成本文件内的纯函数，测试直接 `source` 该脚本并调用它。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash deployments/scripts/tools/tests/test-sync-api-entry.sh`
Expected: FAIL（`loadbalancer_apiserver` 区块仍是未注释状态 / `localhost` 不是 true）

- [ ] **Step 3: 新增 `update_api_entry_all_yml()` 并接入主流程**

在 `sync-kubespray-config.sh` 内新增（放在 `# ---------------- 1. 更新 all.yml ----------------` 段内）：

```bash
# 按模式收敛 all.yml 的 API 入口相关三件事(幂等):
#   ① loadbalancer_apiserver 块: 本地代理开 → 注释掉(上游据此走 localhost 分支); 关 → 取消注释
#   ② loadbalancer_apiserver_localhost: true/false
#   ③ loadbalancer_apiserver_type: 仅当非默认(nginx)时写入, 默认时清掉覆盖
update_api_entry_all_yml() {
    local yml="$1"
    if api_local_lb_enabled; then
        # ① 注释掉 loadbalancer_apiserver 块(带标记, 幂等)
        awk '
            /^loadbalancer_apiserver:[[:space:]]*$/ {
                print "# [api-ha] 本地代理模式: 该块必须保持注释 —— 否则 kubelet 走域名, 本地代理静默失效"
                print "# " $0; in_b=1; next
            }
            in_b && /^[[:space:]]+/ { print "# " $0; next }
            in_b { in_b=0 }
            { print }
        ' "${yml}" > "${yml}.tmp" && mv "${yml}.tmp" "${yml}"
        # ② localhost: true
        if grep -q '^loadbalancer_apiserver_localhost:' "${yml}"; then
            sed -i -E 's/^loadbalancer_apiserver_localhost:.*/loadbalancer_apiserver_localhost: true/' "${yml}"
        else
            printf 'loadbalancer_apiserver_localhost: true\n' >> "${yml}"
        fi
        # ③ type: 仅非默认时写
        if [ "${API_LOCAL_LB_TYPE:-nginx}" != "nginx" ]; then
            grep -q '^loadbalancer_apiserver_type:' "${yml}" \
                && sed -i -E "s/^loadbalancer_apiserver_type:.*/loadbalancer_apiserver_type: ${API_LOCAL_LB_TYPE}/" "${yml}" \
                || printf 'loadbalancer_apiserver_type: %s\n' "${API_LOCAL_LB_TYPE}" >> "${yml}"
        fi
    else
        # 反向: 取消注释(只解带我们标记的块, 避免误解其它注释)
        awk '
            /^# \[api-ha\] 本地代理模式/ { next }
            /^# loadbalancer_apiserver:[[:space:]]*$/ { print "loadbalancer_apiserver:"; in_b=1; next }
            in_b && /^# [[:space:]]/ { print substr($0, 3); next }
            in_b { in_b=0 }
            { print }
        ' "${yml}" > "${yml}.tmp" && mv "${yml}.tmp" "${yml}"
        grep -q '^loadbalancer_apiserver_localhost:' "${yml}" \
            && sed -i -E 's/^loadbalancer_apiserver_localhost:.*/loadbalancer_apiserver_localhost: false/' "${yml}" \
            || printf 'loadbalancer_apiserver_localhost: false\n' >> "${yml}"
    fi
}
```

在主流程里：当 `api_local_lb_enabled` 为真时**跳过**原先的 `sed ... address: ${API_ADDR}`（`:93`），改为调用上面的函数；
为假时保持原 `sed` 并同样调用该函数。

- [ ] **Step 4: `supplementary_addresses_in_ssl_keys` 追加入口地址**

在现有 awk（`:99-116`）输出 masters 之后，追加本次入口地址（外部模式必需；vip/node 模式下与 masters 重复也无害，
kubeadm 侧有 `| unique`）：

```awk
            print "  - " domain
            split(masters, arr, " ")
            for (i in arr) print "  - " arr[i]
            if (entry != "" ) print "  - " entry
```

awk 调用处补 `-v entry="${API_ADDR}"`。

- [ ] **Step 5: 接入硬校验**

在脚本顶部（`kube_vip_validate_config || exit 1` 旁）加：

```bash
api_entry_validate_config || exit 1
```

- [ ] **Step 6: 运行测试确认通过**

Run: `bash deployments/scripts/tools/tests/test-sync-api-entry.sh`
Expected: 全部通过，退出码 0

- [ ] **Step 7: 静态校验 + 提交**

```bash
bash -n deployments/scripts/tools/k8s/sync-kubespray-config.sh
bash deployments/scripts/tools/check-modules.sh
git add deployments/scripts/tools/k8s/sync-kubespray-config.sh deployments/scripts/tools/tests/test-sync-api-entry.sh
git commit -- deployments/scripts/tools/k8s/sync-kubespray-config.sh deployments/scripts/tools/tests/test-sync-api-entry.sh \
  -m "feat(api-ha): sync 脚本按入口模式摘除/保留 loadbalancer_apiserver 块"
```

---

## Task 4: 新模块 `10_api_local_lb.sh`

**Files:**
- Create: `deployments/scripts/modules/02_k8s/10_api_local_lb.sh`
- Modify: `deployments/scripts/lib-module.sh:87`（加入 `BASE_MODULES`）
- Test: `bash -n` + `check-modules.sh` + 离线 dry 运行

**Interfaces:**
- Consumes: Task 2 的 `api_local_lb_enabled()` / `api_entry_addr()`；`init_remote_kubectl`（提供 `SSH_KEY` / `FIRST_MASTER`）
- Produces: 节点上 `/etc/kubernetes/manifests/nginx-proxy.yml` 的存在性收敛 + `/etc/hosts` 域名行 = `api_entry_addr()`

- [ ] **Step 1: 写模块文件**

```bash
#!/bin/bash
# ============================================================
# MODULE: api_local_lb
# DESC: API 入口本地代理(节点侧就近出口) — 双向收敛
#       (开关开=断言各 worker 本地代理就位 + 收敛 /etc/hosts; 开关关=清理残留 manifest)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# TOGGLE: API_LOCAL_LB_ENABLED
# REQUIRES: k8s_deploy
# 说明:
#   · **本模块不安装 nginx-proxy 静态 Pod** —— 它由 kubespray 上游按
#     `loadbalancer_apiserver_localhost` + `loadbalancer_apiserver_type` 自动部署
#     (roles/kubernetes/node/tasks/main.yml:27-43)。本模块只做上游不做的两件事:
#       ① **节点 /etc/hosts 的域名行收敛**: 本地代理模式下 all.yml 不再定义 loadbalancer_apiserver,
#          上游 preinstall 的 hosts 写入任务条件为假(0090-etchosts.yml:27-38), 没人再写这一行;
#          而人 SSH 到节点跑 kubectl 时, admin.conf 的 server 仍是域名, 需要它可解析。
#       ② **关闭时的 manifest 清理**: 上游只互相删 nginx/haproxy 的 manifest
#          (nginx-proxy.yml:1-6 只删 haproxy), **不会**在 localhost=false 时删 nginx-proxy.yml。
#   · **DEFAULT: 1 是刻意的**(与 09_kube_vip.sh 同因): 带 TOGGLE 的模块默认只在开关为 true 时进
#     RUN_STEPS, 开关一翻 false 就彻底不被调度 —— 于是没有任何东西去清理残留的静态 Pod。
#     DEFAULT: 1 让它成为常驻项, 由脚本内部按开关分派安装/清理。
#   · **不做**: 不在 master 上装本地代理(master 打自己的 apiserver, 无跨节点依赖; 且上游因
#     kube_apiserver_bind_address='::' 会端口冲突而刻意排除控制面)。
# 数据源: cluster.conf (API_LOCAL_LB_ENABLED / API_LOCAL_LB_TYPE / NODES / SSH_KEY_NAME)
# 用法: sudo ./deploy-cluster.sh --steps api_local_lb
# ============================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
init_remote_kubectl || exit 1

MANIFEST="/etc/kubernetes/manifests/nginx-proxy.yml"
HOSTS_DOMAIN="${API_DOMAIN}"
SSH_USER_NAME="${SSH_USER:-ubuntu}"

_hssh() {  # _hssh <ip> <cmd...>
    local h="$1"; shift
    ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER_NAME}@${h}" "$@"
}

_workers() {  # 输出所有 worker IP(每行一个)
    local line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_ROLE}" = "worker" ] && printf '%s\n' "${NODE_IP}"
    done
}

_all_nodes() {
    local line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        printf '%s\n' "${NODE_IP}"
    done
}

# 收敛一个节点上的 hosts 域名行(先删同域名旧行, 再写一行)
converge_hosts() {  # converge_hosts <ip> <addr>
    local ip="$1" addr="$2"
    _hssh "${ip}" "sudo sed -i '/[[:space:]]${HOSTS_DOMAIN}\$/d' /etc/hosts && \
                   echo '${addr} ${HOSTS_DOMAIN}' | sudo tee -a /etc/hosts >/dev/null" >/dev/null
}

run_enabled() {
    local entry; entry="$(api_entry_addr)" || { err "无法解析 API 入口地址"; return 1; }
    say "本地代理模式: 入口地址 = ${entry}"

    local ip
    for ip in $(_workers); do
        if ! _hssh "${ip}" "test -f ${MANIFEST}" >/dev/null 2>&1; then
            err "worker ${ip} 上缺少 ${MANIFEST} —— 上游未部署本地代理?"
            err "  排查: all.yml 的 loadbalancer_apiserver 块是否已被 sync 脚本摘掉(见 docs/api-ha/02)"
            return 1
        fi
        # kubelet.conf 的 server 应为 localhost:6443
        if ! _hssh "${ip}" "sudo grep -q 'server: https://localhost:6443' /etc/kubernetes/kubelet.conf"; then
            warn "worker ${ip} 的 kubelet.conf 不是 localhost:6443 —— 可能需要重跑 k8s_deploy 让上游改写"
        fi
        ok "worker ${ip}: 本地代理就位"
    done

    for ip in $(_all_nodes); do
        converge_hosts "${ip}" "${entry}" && vlog "  ${ip}: /etc/hosts ${HOSTS_DOMAIN} → ${entry}"
    done
    ok "节点 /etc/hosts 域名行已收敛到 ${entry}"
}

run_disabled() {
    say "本地代理已关闭: 清理残留的 nginx-proxy 静态 Pod(上游不会删)"
    local entry ip
    entry="$(api_entry_addr)" || entry=""
    for ip in $(_all_nodes); do
        if _hssh "${ip}" "test -f ${MANIFEST}" >/dev/null 2>&1; then
            _hssh "${ip}" "sudo rm -f ${MANIFEST}" >/dev/null || { err "删除 ${ip}:${MANIFEST} 失败"; return 1; }
            ok "已删除 ${ip}:${MANIFEST}"
        fi
        [ -n "${entry}" ] && converge_hosts "${ip}" "${entry}" || true
    done
    ok "清理完成"
}

if api_local_lb_enabled; then run_enabled; else run_disabled; fi
```

- [ ] **Step 2: 加入 `BASE_MODULES`**

`deployments/scripts/lib-module.sh:87`：

```bash
BASE_MODULES=(k8s_deploy k8s_scale metallb local_path k8s_registry api_local_lb)
```

（理由见该文件 `:84` 的注释：新增集群底座类模块把 key 加进来。否则它会因带 TOGGLE 被自动归类为 operator，
出现在"未部署组件汇总"里，语义错误。）

- [ ] **Step 3: 语法与静态校验**

Run:
```bash
bash -n deployments/scripts/modules/02_k8s/10_api_local_lb.sh
bash deployments/scripts/tools/check-modules.sh
```
Expected: 均退出码 0

- [ ] **Step 4: 静态确认分派逻辑（不连集群）**

```bash
# 用 bash -x 观察开关分派: 给一个不存在的 conf, 确认走 enabled 分支并因 SSH 不可达而**响亮报错**(非静默通过)
CLUSTER_CONF=/tmp/does-not-exist.conf bash -x deployments/scripts/modules/02_k8s/10_api_local_lb.sh 2>&1 | grep -E 'api_local_lb_enabled|run_enabled|run_disabled' | head
# 再把开关关掉跑一次, 确认走 run_disabled
CLUSTER_CONF=/tmp/does-not-exist.conf API_LOCAL_LB_ENABLED=false bash -x deployments/scripts/modules/02_k8s/10_api_local_lb.sh 2>&1 | grep -E 'run_enabled|run_disabled' | head
```

Expected: 第一次出现 `run_enabled`，第二次出现 `run_disabled`；两者都因无法连集群而在 SSH 处报错退出（退出码非 0）。

> ⚠ **实作更正（2026-09-28；原文保留以便追溯）**：上面的夹具**观察不到分派** ——
> 不存在的 `cluster.conf` 里没有 `NODES`，`init_remote_kubectl` 会在**分派之前**硬失败
> （trace 尾部：`err '未找到 master 节点(cluster.conf NODES 无 role=master)'` → `exit 1`），
> `grep` 于是得到空输出。即"响亮报错、非静默通过"这半成立, 但 `run_enabled` / `run_disabled`
> 在此前提下**不可能出现** —— 要走到分派行，conf 里必须**有 master 节点**。
>
> 实测有效的安全夹具（节点 IP 用 RFC 5737 `192.0.2.0/24` = TEST-NET-1，全局不可路由，
> **不可能碰到任何真实机器**；`KUBE_VIP_ENABLED=false` 让 `api_entry_addr()` 走 `node` 分支,
> 免得在无集群环境里做 VIP 探测拖时间）：
>
> ```bash
> cat > /tmp/api_lb_synth.conf <<'EOF'
> NODES=("master,fake-m1,192.0.2.10,ubuntu,-" "worker,fake-w1,192.0.2.11,ubuntu,-")
> KUBE_VIP_ENABLED="false"
> API_DOMAIN="k8s-api.invalid"
> API_LOCAL_LB_ENABLED="${API_LOCAL_LB_ENABLED:-true}"
> EOF
> CLUSTER_CONF=/tmp/api_lb_synth.conf bash -x deployments/scripts/modules/02_k8s/10_api_local_lb.sh 2>&1 | grep -E 'api_local_lb_enabled|run_enabled|run_disabled' | head
> CLUSTER_CONF=/tmp/api_lb_synth.conf API_LOCAL_LB_ENABLED=false bash -x deployments/scripts/modules/02_k8s/10_api_local_lb.sh 2>&1 | grep -E 'run_enabled|run_disabled' | head
> ```
>
> 实测结果（2026-09-28 用上面这份夹具原样重跑现行模块）：
> 第一次出现 `+ run_enabled` → **退出码 1**，报
> `【错误】worker 192.0.2.11 SSH 不可达 —— 无法断言本地代理是否就位`（+ 排查行）；
> 第二次出现 `+ run_disabled` → **退出码 1**，报
> `【错误】节点 192.0.2.10 SSH 不可达 —— 无法确认 /etc/kubernetes/manifests/nginx-proxy.yml 是否已清理(不计入'已干净')`
> （192.0.2.11 同款各一行，随后是汇总行 `【错误】清理未完成, 以下节点存在问题: 192.0.2.10(不可达) 192.0.2.11(不可达)`）。
>
> ⚠ **两个分支都必须是非 0**：这是 R9 的 fail-closed 语义（节点不可达 ≠ "上游没装" / "已清理干净"，
> 见模块头 `10_api_local_lb.sh:25-32`；回归锚点 `tools/tests/test-api-local-lb.sh:89-96` 的 ③ 项）。
> 因此本步的判据是**分派**（`+ run_enabled` / `+ run_disabled` 两行是否出现），
> **不是**退出码；退出码在本夹具下两个分支都为 1（节点本就不可达）。
> 本注解早先那版写"第二次退出码 0"、并把 enabled 的报错写成"缺少 nginx-proxy.yml"，
> 复述的是 **R9 修复（`b1ddf4d`）之前**的行为（彼时 enabled / disabled 在节点全不可达时都
> `EXIT=0` 且打印 ✅），未经重测；现按其实际输出更正。

> 注意：直接 `source lib-common.sh` 会触发库加载时的 `ensure_skopeo_policy()`（补
> `/etc/containers/policy.json`）。在无 root 的开发机上它会打印权限错误但**不致命中止**
> （库内该步不参与 `set -e` 判定）；若你的环境会因此中断，用 `sudo` 跑本步。

- [ ] **Step 5: 提交**

```bash
git add deployments/scripts/modules/02_k8s/10_api_local_lb.sh deployments/scripts/lib-module.sh
git commit -- deployments/scripts/modules/02_k8s/10_api_local_lb.sh deployments/scripts/lib-module.sh \
  -m "feat(api-ha): 新增 api_local_lb 模块(节点本地代理断言 + hosts 收敛 + 关闭清理)"
```

---

## Task 5: 新模块 `11_verify_api_ha.sh`

**Files:**
- Create: `deployments/scripts/modules/02_k8s/11_verify_api_ha.sh`
- Test: `bash -n` + `check-modules.sh`

**Interfaces:**
- Consumes: `api_local_lb_enabled()` / `api_entry_addr()` / `init_remote_kubectl`
- Produces: 退出码 0/1 的端到端断言（`--steps verify_api_ha` 触发）

- [ ] **Step 1: 写模块文件**

头部元数据与 `08_verify_kube_vip.sh` 同构（**无 TOGGLE**、`DEFAULT: 0`）：

```bash
#!/bin/bash
# ============================================================
# MODULE: verify_api_ha
# DESC: 端到端验证 API 入口高可用(本地代理 + 入口地址):
#       ① 各 worker 上 nginx-proxy 静态 Pod 容器 Running
#       → ② worker kubelet.conf = https://localhost:6443
#       → ③ master kubelet.conf = https://127.0.0.1:6443
#       → ④ 本机代理端到端可用(curl -sk https://localhost:6443/healthz == ok)
#       → ⑤ 各节点 /etc/hosts 的域名行 == 当前入口地址
#       → ⑥ kubernetes Service 的 Endpoints ≥ 2(非单点)
#       → ⑦ apiserver 证书 SAN 含当前入口地址(防止"切到 VIP 后 TLS 校验失败")
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: k8s_deploy
# 说明:
#   · **不设 TOGGLE**: 否则开启开关时会被安装流程自动启用(同 08_verify_kube_vip.sh 的理由)。
#     仅在部署后显式 `--steps verify_api_ha` 执行。
#   · 破坏性演练(黑洞后端/杀代理)见 docs/api-ha/05-operations.md §6, 不进本模块。
# 数据源: cluster.conf (API_LOCAL_LB_ENABLED / NODES / SSH_KEY_NAME)
# 用法: sudo ./deploy-cluster.sh --steps verify_api_ha
# ============================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
init_remote_kubectl || exit 1

SSH_USER_NAME="${SSH_USER:-ubuntu}"
DOMAIN="${API_DOMAIN}"
FAIL=0
MANIFEST="/etc/kubernetes/manifests/nginx-proxy.yml"

# ⚠ 一律传 IP, 不传主机名: 部署容器里通常没有节点名的 /etc/hosts 解析(历史假故障来源)
_hssh() { local h="$1"; shift
    ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER_NAME}@${h}" "$@"; }

_by_role() { local r="$1" line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_ROLE}" = "${r}" ] && printf '%s\n' "${NODE_IP}"
    done; }

ALL_IPS="$(_by_role master; _by_role worker)"
```

主体（逐项断言，任一失败置 `FAIL=1`，结尾 `exit ${FAIL}`）：

```bash
ENTRY="$(api_entry_addr)" || { err "无法解析 API 入口地址"; exit 1; }
say "当前入口地址: ${ENTRY}"

# ① + ④ 每台 worker 的本地代理
for ip in $(_by_role worker); do
    if _hssh "${ip}" "sudo crictl ps --name nginx-proxy -q | grep -q ." >/dev/null 2>&1; then
        ok "① worker ${ip}: nginx-proxy 容器 Running"
    else
        err "① worker ${ip}: nginx-proxy 容器不在运行"; FAIL=1
    fi
    _hssh "${ip}" "test -f ${MANIFEST}" >/dev/null 2>&1 \
        || { err "① worker ${ip}: 缺少 ${MANIFEST}"; FAIL=1; }

    if [ "$(_hssh "${ip}" "curl -sk https://localhost:6443/healthz" 2>/dev/null | tr -d '\n')" = "ok" ]; then
        ok "④ worker ${ip}: localhost:6443 端到端可用"
    else
        err "④ worker ${ip}: localhost:6443 不可用"; FAIL=1
    fi

    if _hssh "${ip}" "sudo grep -q 'server: https://localhost:6443' /etc/kubernetes/kubelet.conf"; then
        ok "② worker ${ip}: kubelet.conf = localhost:6443"
    else
        err "② worker ${ip}: kubelet.conf 不是 localhost:6443(上游未改写?)"; FAIL=1
    fi
done

# ③ 每台 master 的 kubelet 走自己的 apiserver
for ip in $(_by_role master); do
    if _hssh "${ip}" "sudo grep -q 'server: https://127.0.0.1:6443' /etc/kubernetes/kubelet.conf"; then
        ok "③ master ${ip}: kubelet.conf = 127.0.0.1:6443"
    else
        err "③ master ${ip}: kubelet.conf 不是 127.0.0.1:6443"; FAIL=1
    fi
done

# ⑤ 各节点 /etc/hosts 的域名行
for ip in ${ALL_IPS}; do
    got="$(_hssh "${ip}" "getent hosts ${DOMAIN} | awk '{print \$1}' | head -1" 2>/dev/null)"
    if [ "${got}" = "${ENTRY}" ]; then
        ok "⑤ ${ip}: ${DOMAIN} → ${got}"
    else
        err "⑤ ${ip}: ${DOMAIN} 解析为 '${got}', 期望 '${ENTRY}'"; FAIL=1
    fi
done

# ⑥ kubernetes Service 的端点非单点
# ⚠ 用法约定(见 08_verify_kube_vip.sh:149-150): jsonpath 这类含单引号/花括号的载荷必须走
#   ${SSH_CMD}(字符串形式) —— 经 SSH() 函数参数会多一层引号解析而失败
EPS="$(${SSH_CMD} "${K} get endpoints kubernetes -n default -o jsonpath='{.subsets[*].addresses[*].ip}'" 2>/dev/null || true)"
n="$(echo "${EPS}" | wc -w)"
[ "${n}" -ge 2 ] && ok "⑥ kubernetes Service 端点数 = ${n}" \
                 || { err "⑥ kubernetes Service 端点数 = ${n}(单点)"; FAIL=1; }

# ⑦ 证书 SAN 含入口地址
if ${SSH_CMD} "sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -q '${ENTRY}'" ; then
    ok "⑦ apiserver 证书 SAN 含 ${ENTRY}"
else
    err "⑦ apiserver 证书 SAN 不含 ${ENTRY} —— 走该入口会 TLS 校验失败"; FAIL=1
fi

[ "${FAIL}" = "0" ] && ok "API 入口高可用验证全部通过" || err "存在失败项"
exit "${FAIL}"
```

> `${SSH_CMD}` / `${K}` 由 `init_remote_kubectl` 提供（`lib-common.sh:1594-1605`）：
> `SSH` 是**函数**（写成 `SSH "${K} …"`），`SSH_CMD` 是**字符串**（写成 `${SSH_CMD} "…"`）。
> **绝不能写 `${SSH}`** —— 那是变量展开，`set -u` 下直接 unbound 崩溃。

- [ ] **Step 2: 语法与静态校验**

Run:
```bash
bash -n deployments/scripts/modules/02_k8s/11_verify_api_ha.sh
bash deployments/scripts/tools/check-modules.sh
```
Expected: 均退出码 0

- [ ] **Step 3: 提交**

```bash
git add deployments/scripts/modules/02_k8s/11_verify_api_ha.sh
git commit -- deployments/scripts/modules/02_k8s/11_verify_api_ha.sh \
  -m "feat(api-ha): 新增 verify_api_ha 验证模块(七项断言)"
```

> ⚠ **实作更正（2026-09-28）**：本条示例原文写的是"六项断言"，**实际交付是七项** —— 本任务
> Step 1 的代码骨架与交付模块的头部 DESC 都逐条列了 ①–⑦：① 各 worker nginx-proxy 容器 Running /
> ② worker `kubelet.conf` = `localhost:6443` / ③ master `kubelet.conf` = `127.0.0.1:6443` /
> ④ 本机代理端到端 `curl -sk https://localhost:6443/healthz` == ok / ⑤ 各节点 `/etc/hosts`
> 域名行 == 当前入口地址 / ⑥ `kubernetes` Service 端点 ≥2（非单点）/ ⑦ apiserver 证书 SAN
> 含当前入口地址。可见"六项"只是**本条提交信息示例的笔误**，计划本身的断言范围并未缩水；
> 已生成的提交 `8b44eb5` 的 subject 里仍写作"六项"，以模块代码为准。

---

## Task 6: `check-modules.sh` 新增第 ⑫ 项静态校验

**Files:**
- Modify: `deployments/scripts/tools/check-modules.sh`
- Test: 该项在两种配置下分别通过/报错

**Interfaces:**
- Consumes: Task 2 的 `api_local_lb_enabled()`
- Produces: 静态断言 —— **本地代理开 ⇒ `all.yml` 里不得存在未注释的 `loadbalancer_apiserver:`**

- [ ] **Step 1: 写断言**

> ⚠ **预检已确认**：本脚本**不 source lib-common**（`:235` 注明原因：`cluster.conf` 依赖 `REPO_ROOT` 等，
> 在当前 `set -u` 下直接 source 会中断）⇒ **不能调用 `api_local_lb_enabled()`**。
> 必须复用本文件**既有的取值模式**：`:237-249` 的 `KV_SNAPSHOT` 子 shell（`set +u` 求值 cluster.conf →
> `printf | sed -n Np` 回传）。给该 printf 增补两个值后按下标取出。

先扩展现有快照（`:237-249`）：

```bash
KV_SNAPSHOT="$(
    set +u
    REPO_ROOT="${REPO_ROOT}" SCRIPT_DIR="${SCRIPT_DIR}" CONF_EXAMPLE="${CONF_EXAMPLE}"
    # shellcheck disable=SC1090
    . "${KV_CONF}" >/dev/null 2>&1 || true
    printf '%s\n%s\n%s\n%s\n%s\n' \
        "${KUBE_VIP_ENABLED:-true}" "${K8S_API_VIP:-}" "${METALLB_POOL:-}" \
        "${API_LOCAL_LB_ENABLED:-}" "${KUBE_VIP_LOCAL_PROXY:-false}"
)"
KUBE_VIP_ENABLED="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 1p)"
K8S_API_VIP="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 2p)"
METALLB_POOL="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 3p)"
API_LOCAL_LB_ENABLED_RAW="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 4p)"
KUBE_VIP_LOCAL_PROXY_RAW="$(printf '%s' "${KV_SNAPSHOT}" | sed -n 5p)"
unset KV_SNAPSHOT
# 本地代理是否启用(与 lib-common#api_local_lb_enabled 同语义: 显式值优先, 未定义时回退旧开关)
case "${API_LOCAL_LB_ENABLED_RAW}" in
    '')      case "${KUBE_VIP_LOCAL_PROXY_RAW}" in 1|true|yes|on) _LOCAL_LB=1 ;; *) _LOCAL_LB=0 ;; esac ;;
    1|true|yes|on) _LOCAL_LB=1 ;;
    *)       _LOCAL_LB=0 ;;
esac
```

然后在 ⑪ 段之后新增 ⑫ 段（照 `:227-320` 的风格）：

```bash
# ---------- ⑫ API 入口: 本地代理模式与 all.yml 的一致性 ----------
# 本地代理开时, all.yml 的 loadbalancer_apiserver 块必须被注释掉 ——
# 只要它存在, kubespray 的 kube_apiserver_endpoint 就走域名分支, 本地代理装了也没有流量(静默假修复)。
# 反向(开关关)不校验: 那是有意为之的回退形态。
ALL_YML="${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster/group_vars/all/all.yml"
if [ -f "${ALL_YML}" ]; then
    if [ "${_LOCAL_LB}" = "1" ]; then
        if grep -qE '^loadbalancer_apiserver:[[:space:]]*$' "${ALL_YML}"; then
            ck "⑫ 本地代理已开启, 但 all.yml 的 loadbalancer_apiserver 块未注释 → 本地代理会静默失效"
        else
            ok "  ⑫ 本地代理模式: all.yml 未定义 loadbalancer_apiserver(正确)"
        fi
    else
        say "  API_LOCAL_LB_ENABLED 非 true —— 跳过 ⑫(本地代理未启用)"
    fi
fi
```

（`ck` / `ok` / `say` 用该文件既有函数；`ALL_YML` 变量名若与既有冲突则改名 `API_HA_ALL_YML`。
`REPO_ROOT` 由该脚本既有的 `:25` 附近推导，勿重复定义。）

- [ ] **Step 2: 验证两条路径**

```bash
# 路径 A: 本地代理开 + fixture all.yml 未注释 → 期望 ck(失败)
# 路径 B: 本地代理开 + fixture all.yml 已注释 → 期望 ok(通过)
# 用临时目录 + KUBESPRAY_INV_DIR 覆盖的方式跑, 或在有 inventory 的环境直接跑
bash deployments/scripts/tools/check-modules.sh; echo "exit=$?"
```

- [ ] **Step 3: 提交**

```bash
git add deployments/scripts/tools/check-modules.sh
git commit -- deployments/scripts/tools/check-modules.sh \
  -m "feat(api-ha): check-modules 新增第 ⑫ 项(all.yml 与本地代理模式一致性)"
```

---

## Task 7: 消费点跟随（3 处小改）

**Files:**
- Modify: `deployments/scripts/tools/lb/setup-api-expose.sh`（DNAT 白名单）
- Modify: `deployments/kubespray/cubestack-offline.sh`（`update_loadbalancer_all_yml()`）
- Modify: `deployments/scripts/modules/02_k8s/07_k8s_scale.sh`（新节点 hosts 写入口地址）

**Interfaces:**
- Consumes: `api_entry_addr()`
- Produces: 三处消费点与新模式一致

- [ ] **Step 1: `setup-api-expose.sh` 加 DNAT 白名单**

现状 `:85-90`：`API_IP != FIRST_MASTER` 就加 DNAT。当入口是 VIP/外部地址时会**误加**并把流量劫持回首 master。
改为：只有在**入口模式为 `node`** 时才可能加 DNAT（external/vip 一律不加）：

```bash
if [ "$(api_entry_mode)" != "node" ]; then
    say "API 入口为 $(api_entry_mode) 模式(${API_IP}) —— 由入口组件负责转发, 宿主机不加 DNAT(已清理历史规则)"
elif [ "${API_IP}" = "${FIRST_MASTER}" ]; then
    say "API 入口=第一个 master(${API_IP}), 宿主机直连, 无需 DNAT(已清理历史遗留规则)"
else
    dnat_add PREROUTING; dnat_add OUTPUT
fi
```

- [ ] **Step 2: `cubestack-offline.sh` 的 `update_loadbalancer_all_yml()` 跟随**

该函数是 `all.yml` 的**第二个写入者**（`:1309` 起）：它 awk 读 `loadbalancer_apiserver.address`，
读不到就回退首 master 并**写回 all.yml** —— 本地代理模式下这会把我们注释掉的块**重新写成未注释状态**，
本地代理随即静默失效。必须让它在该模式下**完全不碰 all.yml**。

> ⚠ **预检已确认**：`cubestack-offline.sh` **不 source lib-common**（全文件无 `lib-common` 引用）
> ⇒ **不能调用 `api_local_lb_enabled()`**。用最小解析：环境变量优先，否则子 shell 求值 cluster.conf。

在该函数开头（`local inv=...` 之前）加：

```bash
    # 本地代理模式(API_LOCAL_LB_ENABLED=true): all.yml 的 loadbalancer_apiserver 块由
    # sync-kubespray-config.sh 独占维护并保持注释; 本函数若按"读不到就回退首 master 并写回",
    # 会把注释恢复成未注释 → 上游随即走域名分支 → 本地代理静默失效。故直接跳过 all.yml 部分。
    # (本脚本不 source lib-common, 故用最小解析而非 api_local_lb_enabled)
    local _local_lb="${API_LOCAL_LB_ENABLED:-}"
    if [ -z "${_local_lb}" ]; then
        local _conf="${REPO_ROOT:-}/deployments/config/cluster.conf"
        [ -f "${_conf}" ] || _conf="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/deployments/config/cluster.conf"
        if [ -f "${_conf}" ]; then
            _local_lb="$( ( set +u; . "${_conf}" >/dev/null 2>&1 || true
                            printf '%s' "${API_LOCAL_LB_ENABLED:-${KUBE_VIP_LOCAL_PROXY:-false}}" ) )"
        else
            _local_lb="false"
        fi
    fi
    case "${_local_lb}" in
        1|true|yes|on)
            log "本地代理模式: 跳过 all.yml 的 loadbalancer_apiserver 同步(由 sync 脚本独占)"
            return 0 ;;
    esac
```

⚠ 确认 `return 0` 的位置**在任何 all.yml 写入之前**；若该函数还负责 `hosts.yml` 的同步而本地代理模式下仍需它，
则把 `return 0` 改成"只跳过 all.yml 那一段"（实现时读函数体决定，两种都符合意图）。

- [ ] **Step 3: `07_k8s_scale.sh` 新节点 hosts 写入口地址**

把新增节点写 `/etc/hosts` 的值从 `API_IP` 改为 `$(api_entry_addr)`：

```bash
_entry="$(api_entry_addr)" || { err "无法解析 API 入口地址"; exit 1; }
# …把原用的 ${API_IP} 换成 ${_entry}（仅 /etc/hosts 那处；registry 的 NodePort 逻辑不动）
```

- [ ] **Step 4: 语法 + 静态校验**

```bash
bash -n deployments/scripts/tools/lb/setup-api-expose.sh
bash -n deployments/kubespray/cubestack-offline.sh
bash -n deployments/scripts/modules/02_k8s/07_k8s_scale.sh
bash deployments/scripts/tools/check-modules.sh
```

- [ ] **Step 5: 提交**

```bash
git add deployments/scripts/tools/lb/setup-api-expose.sh deployments/kubespray/cubestack-offline.sh \
        deployments/scripts/modules/02_k8s/07_k8s_scale.sh
git commit -- deployments/scripts/tools/lb/setup-api-expose.sh deployments/kubespray/cubestack-offline.sh \
        deployments/scripts/modules/02_k8s/07_k8s_scale.sh \
  -m "feat(api-ha): 消费点跟随入口模式(DNAT 白名单 / offline 写入者 / 扩容 hosts)"
```

---

## Task 8: 文档同步与最终验收

**Files:**
- Modify: `deployments/scripts/README.md`（模块树补两个模块）
- Modify: `docs/kube-vip-api-ha.md`（补交叉引用）
- Modify: `docs/cluster-architecture.md`（补一句"节点侧 API 出口"）
- Modify: `docs/api-ha/README.md`（把"实施状态"从"进行中"改为"已实施"）

- [ ] **Step 1: `deployments/scripts/README.md` 模块树补两行**

在 `:92-93` 的 `09_kube_vip.sh` 之后加：

```
│   │   ├── 10_api_local_lb.sh     # 节点侧 API 本地代理(kubespray nginx-proxy 静态 Pod): 断言就位 +
│   │   │                          #   /etc/hosts 域名行收敛 + 关闭时清理残留; 默认开, 见 docs/api-ha/
│   │   └── 11_verify_api_ha.sh    # 验证 API 入口高可用(七项; --steps verify_api_ha)
```

- [ ] **Step 2: `docs/kube-vip-api-ha.md` 补交叉引用**

在 §2.3（"为什么不用 nginx-proxy 作解法"）末尾加一段：该节当年记为"值得保留的叠加选项"的方案**已落地**，
见 `docs/api-ha/`（节点侧本地代理 + 入口侧 VIP 的组合），并说明两阶段切换的风险面因此缩小到"外部/管理客户端"。

- [ ] **Step 3: `docs/cluster-architecture.md` 补一句**

在网络章节加一句：节点侧 kubelet/kube-proxy 的 API 出口见 `docs/api-ha/02-kubespray-native-lb.md`。

- [ ] **Step 4: 更新 `docs/api-ha/README.md` 的实施状态**

把"⚠ 实施状态：… 代码正在实施"改为"已实施（`API_LOCAL_LB_ENABLED` 默认 true）"，并附本次提交的 commit 短哈希。

- [ ] **Step 5: 最终验收（全绿才收工）**

```bash
bash deployments/scripts/tools/check-modules.sh                                   # 期望 exit 0
bash deployments/scripts/tools/images/check-image-manifest.sh --kubespray          # 期望 exit 0
bash deployments/scripts/tools/tests/test-api-entry-mode.sh                        # 期望 exit 0
bash deployments/scripts/tools/tests/test-sync-api-entry.sh                        # 期望 exit 0
for f in deployments/scripts/modules/02_k8s/1[01]_*.sh; do bash -n "$f" || echo "语法失败: $f"; done
```

- [ ] **Step 6: 提交**

```bash
git add deployments/scripts/README.md docs/kube-vip-api-ha.md docs/cluster-architecture.md docs/api-ha/
git commit -- deployments/scripts/README.md docs/kube-vip-api-ha.md docs/cluster-architecture.md docs/api-ha/ \
  -m "docs(api-ha): 同步模块表与交叉引用, 标注实施完成"
```

> ⚠ **实作更正（2026-09-28）**：本工作区的**主索引**里压着 **471 个与本任务无关的历史已暂存删除项**
> （须原样保留：既不能提交进本次提交，也不能 `git add -A` / 裸 `git commit` 把它们一起带走）。
> 因此上面的 `git add` / `git commit` 实际未照抄，改用**临时索引**隔离：
> `GIT_INDEX_FILE=/tmp/<临时文件> git read-tree HEAD` → 只 `add` 本次改动的文档路径 → commit；
> 提交后复核主索引未被动过 —— `git diff --cached --name-status <基线提交> | awk '{print $1}' |
> sort | uniq -c` 仍是 `471 D`（另有 4 个基线就存在的 `M`）。

---

## 交付后（不在本计划范围）

| 事项 | 说明 |
|---|---|
| 同步到部署容器 | `./deployments/scripts/tools/sync-to-container.sh`（注意：`cluster.conf` 不参与同步，容器内需手工改） |
| **离线镜像 tar 尚未产出** | Task 1 Step 7，需要联网机 + Harbor 凭据：`sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group k8s-base` → 产出落 `deployments/offline-files/kubespray/images/`（文件名形如 `docker.io_library_nginx_1.27.4-alpine.tar`）。⚠ **风险是静默的**：`resolve_preload_image_files()`（`deployments/kubespray/cubestack-offline.sh`）只**过滤已存在的 tar**，模式匹配不到任何 tar 时**不报错**（仅在"一个都没匹配上"时 warn）→ 少同步一个镜像不会被发现；默认开关（`API_LOCAL_LB_ENABLED=true`）下 worker 的 `nginx-proxy` 静态 Pod 会 `ImagePullBackOff` ⇒ **该节点 kubelet 打不到 API（NotReady）**。验收：各节点 `sudo ctr -n k8s.io images ls \| grep nginx`（见 [04 §5 S0](04-decision.md) / 04 §6 A1） |
| **本支的 45 条 deferred minor 未随分支入库** | 当时记录在控制器工作区（**不在本仓库内**，分支与提交里查不到）。需要时逐条落 issue（`gh issue create`），否则会随会话丢失 |
| 实机验证 | 全新集群部署 + [docs/api-ha/05-operations.md](05-operations.md) §6 的 B 组演练 |
| 存量集群迁移 | 明确不做（用户 2026-09-28 决定） |
