# 04 · 决策与实施方案

> 状态：**设计已确认，代码与文档实施中**（2026-09-28）· 本轮范围：**只改代码与文档，不动生产集群**
> 依据：[01 现状](01-current-state.md) · [02 原生方案](02-kubespray-native-lb.md) · [03 对比](03-comparison.md)

---

## 1. 决策摘要

| # | 决策 | 理由 |
|---|---|---|
| D1 | **节点侧采用 kubespray 原生每节点本地代理**（`nginx` type） | 上游原生路径；零额外机器/IP；节点侧故障域降为单节点；不动证书 |
| D2 | **外部/管理侧采用 kube-vip VIP** | 唯一能提供稳定对外地址的方案；仓库已有实现与验证 |
| D3 | **两者叠加**，不是二选一 | 覆盖集互补，见 [03 §5](03-comparison.md#5-为什么--是-最佳而不是二选一) |
| D4 | **不采用 HAProxy + Keepalived** | 需 2 台专职机器（现场无）；现实现是单机 VIP 假 HA；功能与 D2 重叠 |
| D5 | **支持无 VIP 场景降级** | 节点侧 HA 无条件生效；外部入口回退首 master 并显式 warn |
| D6 | **支持复用环境已有 LB/VIP**（`API_EXTERNAL_ADDR`） | 现场可能已有外部负载均衡器，不该强迫装 kube-vip |
| D7 | 采用**路线 2**（摘掉 `loadbalancer_apiserver`），不用路线 1（覆写 kubelet.conf） | 路线 2 是上游原生行为，且同样保留域名/VIP 对外入口；路线 1 把正确性押在"每次部署都要记得覆写"上 |
| D8 | `KUBE_VIP_LOCAL_PROXY` **从"硬失败护栏"改为"兼容别名"** | 它的语义已被 `API_LOCAL_LB_ENABLED` 吸收；且新实现下"设了会真生效"，护栏的存在理由（假修复）消失 |
| D9 | 全部行为由 `cluster.conf` 开关驱动，**默认即最优** | 用户要求"默认生产选组合，且可配置" |

**与既有注释的分歧登记**：`deployments/config/cluster.conf:99` 把"路线 1"标为推荐。
本方案选路线 2，理由见 D7。实施时该注释块会一并更新。

---

## 2. 配置模型

### 2.1 开关

```bash
# ── 节点侧：每节点本地代理（新）──
API_LOCAL_LB_ENABLED="${API_LOCAL_LB_ENABLED:-true}"    # 默认开
API_LOCAL_LB_TYPE="${API_LOCAL_LB_TYPE:-nginx}"         # nginx | haproxy

# ── 管理/外部侧：三选一（新 + 既有）──
API_EXTERNAL_ADDR="${API_EXTERNAL_ADDR:-}"              # 环境已有 LB/VIP 地址（新）
KUBE_VIP_ENABLED="${KUBE_VIP_ENABLED:-false}"           # ⚠ 现版默认 **false**（2026-09-24 翻转）；本方案推荐组合要显式置 true
K8S_API_VIP="${K8S_API_VIP:-}"                          # 空=自动推导（既有）

# ── 既有、本方案调整语义 ──
KUBE_VIP_LOCAL_PROXY="${KUBE_VIP_LOCAL_PROXY:-false}"   # 兼容别名 → API_LOCAL_LB_ENABLED
```

> ⚠ **默认值以 `deployments/config/cluster.conf.example` 为准**（2026-09-29 逐字核对过）。
> 本节的取值曾写作 `KUBE_VIP_ENABLED:-true`（= 本方案推荐的"节点侧 + 外部侧全 HA"组合），
> 但该开关 **2026-09-24 已翻转为默认 `false`**（理由见 [../kube-vip-api-ha.md](../kube-vip-api-ha.md) 决策 D2：
> 实际用法长期停在阶段一，默认开只是让每轮部署多跑一遍昂贵且可能硬失败的 VIP 推导）。
> ⇒ 想拿到本方案推荐的全高可用组合，**必须显式置 `KUBE_VIP_ENABLED=true`**（D9 的"默认即最优"
> 自 2026-09-24 起只对节点侧成立）。

### 2.2 模式判定（`api_entry_mode()`）

```
API_EXTERNAL_ADDR 非空 ────────────────→ external
   └ 且 KUBE_VIP_ENABLED=true          → ❌ 硬失败（入口只能有一个来源）
   └ 且 HAPROXY/KEEPALIVED=true        → ❌ 硬失败
否则 KUBE_VIP_ENABLED=true ────────────→ vip（两阶段流程保留）
否则 ─────────────────────────────────→ node（回退首 master，warn：外部入口无 HA）
```

入口地址（`api_entry_addr()`）：

| 模式 | 地址 |
|---|---|
| `external` | `API_EXTERNAL_ADDR` |
| `vip` | `kube_vip_resolve_target()`（既有两阶段：VIP 未绑 → 首 master；已绑 → VIP） |
| `node` | `first_master_ip()` |

**与节点侧正交**：`API_LOCAL_LB_ENABLED` 在三种模式下都可独立开关。

### 2.3 兼容矩阵

| `API_LOCAL_LB_ENABLED` | 入口模式 | 节点侧 | 外部侧 | 评价 |
|---|---|---|---|---|
| `true`（默认） | `vip`（默认） | ✅ | ✅ | **推荐，默认** |
| `true` | `external` | ✅ | ✅ | 复用现成 LB |
| `true` | `node` | ✅ | ⚠ 单点（warn） | **无 VIP 场景**，仍强于现状 |
| `false` | 任意 | ❌ 跨网络依赖 | 取决于模式 | 仅用于排障/回退 |

### 2.4 硬校验（`api_entry_validate_config()`）

| # | 规则 | 来源 |
|---|---|---|
| ① | `KUBE_VIP_ENABLED` ∧ (`HAPROXY_ENABLED` ∨ `KEEPALIVED_ENABLED`) → 失败 | 既有 `lib-common.sh:786-792` |
| ② | `API_EXTERNAL_ADDR` ∧ `KUBE_VIP_ENABLED` → 失败 | **新增** |
| ③ | `API_EXTERNAL_ADDR` ∧ (`HAPROXY_ENABLED` ∨ `KEEPALIVED_ENABLED`) → 失败 | **新增** |
| ④ | VIP 落在 `METALLB_POOL` 内 → 失败 | 既有 `lib-common.sh:797-801` |
| ⑤ | VIP = 任一节点 IP → 失败 | 既有 `lib-common.sh:804-813` |
| ⑥ | `API_LOCAL_LB_ENABLED=true` 时 `all.yml` 不得含 `loadbalancer_apiserver` | **新增**（`check-modules.sh` 静态断言 + sync 脚本保证） |
| ⑦ | `API_EXTERNAL_ADDR` 必须是合法 IPv4 字面量 | **新增**（复用 `emit_ip` 风格的值校验） |

---

## 3. 目标数据流

| 客户端 | 目标地址 | 组件 | 切换 |
|---|---|---|---|
| worker kubelet/kube-proxy | `https://localhost:6443` | 本机 nginx-proxy 静态 Pod | ~1s |
| master kubelet/kube-proxy | `https://127.0.0.1:6443` | 自己的 apiserver | apiserver 自动重启 |
| 运维/CI/外部 | `https://k8s-api.cubestack.io:6443` | VIP（kube-vip）或外部 LB | 1–5s |
| Pod | `kubernetes.default.svc` | kube-proxy ipvs | 已有 |
| 新节点 join | 首 master IP | kubeadm discovery | 无（一次性） |

---

## 4. 代码改动清单

| # | 文件 | 改动 | 关键点 |
|---|---|---|---|
| 1 | `deployments/config/cluster.conf`<br>`cluster.conf.example` | 新增 3 开关；更新 92-104 注释块；`KUBE_VIP_LOCAL_PROXY` 标注为兼容别名 | 唯一配置源；`check-modules.sh` 会校验 example 同步 |
| 2 | `deployments/scripts/lib-common.sh` | 新增 `api_local_lb_enabled()` / `api_entry_mode()` / `api_entry_addr()` / `api_entry_validate_config()`；`kube_vip_validate_config()` ⑤ 由硬失败改为兼容映射；`sync_kubeconfig()` 的 DNAT 白名单 | 值函数遵守 `emit_ip()` 契约（只输出 IPv4 字面量，诊断走 `vlog >&2`） |
| 3 | `deployments/scripts/tools/k8s/sync-kubespray-config.sh` | 入口的**唯一写入者**：按模式写/摘 `loadbalancer_apiserver`；写 `loadbalancer_apiserver_localhost` + `_type`；入口地址进 `supplementary_addresses_in_ssl_keys`；`kube_vip_address` 继续写（喂 SAN） | `API_LOCAL_LB_ENABLED=true` ⇒ **必须删掉** `loadbalancer_apiserver` 块，否则假修复 |
| 4 | `deployments/scripts/modules/02_k8s/10_api_local_lb.sh`（**新**） | `TOGGLE: API_LOCAL_LB_ENABLED`、`DEFAULT: 1`、`REQUIRES: k8s_deploy`。启用态：断言各 worker 静态 Pod + `127.0.0.1:6443` + `kubelet.conf` server，并**收敛节点 `/etc/hosts` 域名行**；关闭态：**清理 `nginx-proxy.yml`**（上游不删）+ 收敛 hosts | `DEFAULT: 1` 与 kube-vip 模块同因：关掉开关时必须有东西去清理 |
| 5 | `deployments/scripts/modules/02_k8s/11_verify_api_ha.sh`（**新**） | 断言 ①–⑦（**七项**：本地代理容器 / kubelet.conf / hosts 域名行 / Service 端点 / 证书 SAN）+ 黑洞演练（演练步骤见 [05-operations.md](05-operations.md) §6） | 无 TOGGLE，仅 `--steps` 显式触发（同 `08_verify_kube_vip.sh` 的理由） |
| 6 | `deployments/config/images.manifest`<br>`cluster.conf` 预加载<br>`deployments/offline-files/kubespray/` | 登记 `docker.io/library/nginx:1.30.1-alpine`；`PRELOAD_IMAGE_PATTERNS` 加 `library_nginx`；tar 放 **kubespray 镜像集**（不要放 `offline-files/nginx/`，那里文件名被 `ensure_registry_nginx` 锁死） | 不补 = 静态 Pod `ImagePullBackOff` |
| 7 | `deployments/scripts/tools/check-modules.sh` | 新增第 ⑬ 项：开关组合合法性 + `all.yml` 收敛状态断言 | 与既有 ⑪ 并列 |
| 8 | `deployments/kubespray/cubestack-offline.sh` | `update_loadbalancer_all_yml()` 跟随新模式（不再无条件写 address） | 它是 `all.yml` 的**第二个写入者**，必须同步 |
| 9 | `deployments/scripts/tools/lb/setup-api-expose.sh` | DNAT 加白名单：入口为 VIP/外部地址时**不得**加 DNAT（当前会误加并劫持到首 master） | 现状 `:85-90` 判据是 `API_IP != FIRST_MASTER`，VIP 会命中等号右边 |
| 10 | `deployments/scripts/modules/02_k8s/07_k8s_scale.sh` | 新节点 `/etc/hosts` 写入口地址（跟随 `api_entry_addr()`） | 与 `01_env` 的 hosts 写入保持一致 |
| 11 | 文档 | 本组 5 篇；`docs/kube-vip-api-ha.md` 增补交叉引用；`deployments/README.md` 模块表补两个模块 | |

### 4.1 不变的部分（明确边界）

- **`09_kube_vip.sh` 瘦身(2026-09-28 收编),两阶段流程保留** —— 静态 Pod 清单改由 kubespray 自己渲染
  (见 [07-kube-vip-upstream-assessment.md](07-kube-vip-upstream-assessment.md)),该模块只留 VIP 推导、
  变量校验、收敛核验与关闭清理；两阶段在 `vip` 模式下照旧工作,受影响面从"全集群"缩小到"外部/管理客户端"
- **`08_verify_kube_vip.sh`** 保留,并加一条"双写者回归"哨兵(清单 hostPath 应为首台 `super-admin.conf`、其余 `admin.conf`)
- **`01_env/05/06`（HAProxy/Keepalived）不动** —— 保留但不推荐，注释里补一句指向本组文档
- **Calico / kube-proxy / MetalLB / Ceph 全部不动**
- **部署机/管理机的 `/etc/hosts` 仍解析到第一台 master —— 本方案未消除，属已知限制/后续项**。
  ⚠ **2026-09-28 细分**：这句说的是**部署宿主机**自己那份 `/etc/hosts`（`deploy` 不碰它；要跟记得手工跑
  `tools/node/sync-hosts.sh`）。**部署脚本运行环境**（部署容器）里那份已随同日修复**跟随入口** ——
  `sync_kubeconfig` 原先写死 `API_IP`（节点 IP 语义）⇒ 容器里域名永远指向首 master，与
  `setup-api-expose.sh` 用的 `api_entry_ip()` 不一致；现改为写 `api_entry_ip()`（VIP 已绑 = VIP，否则首 master）。
  ⚠ 容器与宿主的 `/etc/hosts` 是**两份不同的文件**（`md5sum` 不同），排查时先确认在看哪一份。
  节点侧（模块 10 收敛）与外部侧入口都跟随 `api_entry_addr()`，但**运行部署脚本的这台机器自己**
  的域名解析仍写 `API_IP`（= 默认第一台 master），涉及 6 个写入点：
  `lib-common.sh` 的 `sync_kubeconfig()`（把 kubeconfig 的 server 改写成域名，而域名靠 `/etc/hosts` 解析）、
  `modules/02_k8s/03_k8s_hosts.sh:23`、`tools/node/sync-hosts.sh:33`、`tools/lb/setup-api-expose.sh:44` 等。
  **为什么不改**：`sync_kubeconfig()` 是热路径（每次部署都会跑），要让它写入口地址就得先解析入口，
  而 `kube_vip_derive()` 在未记录 VIP（首装）时会退化成"逐地址 SSH 探测"——代价与风险都不适合在本轮引入；
  且这 6 处属跨面改动，本轮没有实机验证窗口。
  **后果**：`master01` 宕机时，部署机上的 `kubectl`/CI 仍会失联（[01 §8](01-current-state.md#8-单点清单本集群实测) 的对应条目已标注）。
  后续若要修，正确入口是让这几处统一消费 `api_entry_addr()`，并接受首装时的一次探测成本。

---

## 5. 部署流程（全新安装）

> **范围**：本方案**面向全新安装的集群**。存量集群的入口迁移（含证书重签）暂不在范围内。
> 全新安装的关键优势：**证书 SAN 首次生成时就包含入口地址，全程不需要重签、不需要窗口。**

### S0 · 镜像准备（在联网机上做，产物随离线包分发）

```bash
# 目标镜像（LB 本地代理用）
#   docker.io/library/nginx:1.30.1-alpine      （API_LOCAL_LB_TYPE=nginx）
#   docker.io/library/haproxy:3.1.3-alpine     （API_LOCAL_LB_TYPE=haproxy，可选）
#
# 本环境无法直连 docker.io，走既有通道：
#   GitHub Actions 同步镜像 → Harbor(mirrors 项目) → 离线机从 Harbor 拉 → 存 tar 到 offline-files
```
落位：`deployments/offline-files/kubespray/images/`（kubespray 镜像集），
**不要放 `offline-files/nginx/`** —— 那里的 `nginx*.tar` 被 `lib-common.sh` 的 `ensure_registry_nginx`
锁死为 verify 模块的测试后端（`nginx:1.27`，`cluster.conf:671`），混用会破坏既有链路。

**验证**：`gunzip -c <tar> | head` 或 `tar -xOf <tar> manifest.json` 确认 ref 与 tag；
各节点 `sudo ctr -n k8s.io images ls | grep nginx`。

### S1 · 配置

```bash
# cluster.conf（本方案推荐的"节点侧 + 外部侧全 HA"组合；⚠ 见下）
API_LOCAL_LB_ENABLED=true        # 节点侧本地代理（现版默认即 true，可省）
API_LOCAL_LB_TYPE=nginx
KUBE_VIP_ENABLED=true            # 外部/管理侧 VIP（⚠ 现版默认 false，必须**显式**写；无 VIP 环境见下）
API_EXTERNAL_ADDR=               # 环境已有 LB 时填这里，并把 KUBE_VIP_ENABLED 置 false
K8S_API_VIP=                     # 留空=自动推导（各 master 从 .210 起探测空闲地址）
```
**无 VIP 场景**（不需要任何改动即可安装）：
```bash
KUBE_VIP_ENABLED=false           # 不装 kube-vip；节点侧 HA 不受影响
# 可选：若环境另有 LB，填 API_EXTERNAL_ADDR=<LB 地址>
# 否则入口回退首 master，部署时会 warn 明示"外部入口无 HA"
```
校验：`./deployments/scripts/tools/check-modules.sh`

### S2 · 全量部署

```bash
./deploy-cluster.sh --with-k8s          # 或按现场流程全量部署
```
**预期结果**：
- 证书 SAN **首次即含**：域名 + 全部 master IP + VIP/外部地址 + `10.233.0.1` + `127.0.0.1`
- worker 的 `kubelet.conf` = `https://localhost:6443`；master 的 = `https://127.0.0.1:6443`
- 各 worker 上出现 `nginx-proxy` 静态 Pod
- 节点 `/etc/hosts` 的域名行指向当前入口地址（模块收敛）
- （`vip` 模式）两次运行后入口切到 VIP（两阶段确认）

### S3 · 验收

见 §6 的 A 组断言（静态）+ B 组演练（窗口内一次）。

> **不需要**证书重签、**不需要**停机窗口 —— 这是全新安装相对存量迁移的最大优势。

---

## 6. 验收标准

### A 组 · 静态/配置断言（每次部署后）

| # | 断言 | 命令 |
|---|---|---|
| A1 | 各 worker 上 nginx-proxy 静态 Pod 存在且 Running | `ls /etc/kubernetes/manifests/nginx-proxy.yml`；`sudo crictl ps --name nginx-proxy` |
| A2 | worker `kubelet.conf` = `https://localhost:6443` | `grep -m1 server: /etc/kubernetes/kubelet.conf` |
| A3 | master `kubelet.conf` = `https://127.0.0.1:6443` | 同上 |
| A4 | 本机代理连通 | `curl -sk https://localhost:6443/healthz` → `ok` |
| A5 | `all.yml` 无 `loadbalancer_apiserver`、`localhost: true` | `grep -n loadbalancer group_vars/all/all.yml` |
| A6 | 证书 SAN 含入口地址（VIP） | `openssl x509 … \| grep -A3 'Subject Alternative'` |
| A7 | 节点 `/etc/hosts` 域名 → 当前入口地址 | `getent hosts k8s-api.cubestack.io`（各节点） |
| A8 | `kubernetes` Service 三端点 | `kubectl get endpoints kubernetes -n default` |

### B 组 · 故障演练（实施窗口内执行一次）

| # | 演练 | 期望 | 对应验收档 |
|---|---|---|---|
| B1 | 摘掉某 worker 的 nginx-proxy 进程 | 该节点 kubelet 自动重启它；期间该节点 API 短暂不可达 | 节点自愈 |
| B2 | 在 worker 上把 upstream 指向黑洞（2/3 后端） | **20/20 成功**，最坏 ≤1s（复用已有实测方法） | 节点自愈 |
| B3 | 停一台 master 的 apiserver 进程 | 其余节点无感；VIP 若不健康则漂移（`cp_detect`） | 节点自愈 + 运维 |
| B4 | 停 master01（**非 VIP 持有者**） | 全集群无感 | 全档 |
| B5 | 停 VIP 持有者 | 运维 kubectl 在 ≤5s 内恢复 | 运维/CI |
| B6 | 回滚演练 | 每一步的回滚路径可用 | — |

---

## 7. 不做的范围（YAGNI）

| 不做 | 理由 |
|---|---|
| 在 master 上装本地代理 | 上游设计如此；master 打自己的 apiserver 无跨节点依赖，装它需要改 `kube_apiserver_bind_address`（风险大于收益） |
| 把 HAProxy+Keepalived 改造成真 VRRP | 需 2 台机器，现场没有；功能与 kube-vip 重叠 |
| kube-vip BGP 模式 | 面向裸金属 ARP 场景，BGP 无需求 |
| 调 kube-vip 租约参数 | 仓库既有结论：过短会误判 leader 失效，风险高于多等几秒 |
| 改 Calico / kube-proxy / MetalLB | 与本次目标无关，保持稳定 |
| 修 multus NAD 的 `eth0` 坏点 | 另一个议题（见 [01 §7](01-current-state.md#7-顺带发现的问题与入口-ha-无关但建议记一笔)），不混入本次改动 |

---

## 8. 残留风险登记

| # | 风险 | 影响 | 处置 |
|---|---|---|---|
| R1 | 新增节点 join 依赖首 master（`kubeadm_discovery_address`） | 仅扩容窗口内首 master 宕机才会失败 | 接受（上游设计）；文档明示 |
| R2 | master 自身 apiserver 挂了，该 master 的 kubelet 打不到 API | 单节点，且 apiserver 由 kubelet 自动重启 | 接受（上游设计） |
| R3 | nginx 版无主动健康检查，已建立连接遇静默死亡最长 10m | kubelet watch 长连接受影响 | 可切 `API_LOCAL_LB_TYPE=haproxy` 改善；先观察 |
| R4 | 证书 SAN 首次生成即含入口地址，**全新安装无重签风险** | — | 已消除（存量迁移才有此问题，不在本方案范围） |
| R5 | 路线 2 下 `controlPlaneEndpoint` 变首 master IP | 仅影响 kubeadm 相关操作（join/upgrade）的默认目标 | 接受；文档明示 |
| R6 | 上游对 nginx-proxy 无活跃 CI 覆盖（同 kube-vip） | 无回归保护 | 靠 `11_verify_api_ha.sh` + 演练 |
| R7 | 离线镜像漏补 | 静态 Pod `ImagePullBackOff`（**响亮**，非静默） | S0 + `check-modules` 断言 |
| R8 | 上游 `loadbalancer_apiserver_localhost` 与 `loadbalancer_apiserver` 的派生关系依赖"不定义后者" | 若将来有人手工定义了它，本地代理会静默失效 | `check-modules.sh` 第 ⑬ 项静态断言 + verify 模块实测 `kubelet.conf` |

---

## 9. 与既有文档的关系

| 文档 | 关系 |
|---|---|
| `docs/kube-vip-api-ha.md` | kube-vip 的**实现细节**（两阶段、脑裂、D1-D7）。其 §2.3 曾把"开回 nginx-proxy"记为"值得保留的叠加选项"——**本方案就是那个选项的落地**。实施后需在该文档补一段交叉引用 |
| `docs/scripts-development-spec.md` | 新增模块需遵守的脚本规范（`REQUIRES`/`TOGGLE`/值函数契约等） |
| `docs/cluster-architecture.md` | 网络总览；实施后需补一句"节点侧 API 出口" |
