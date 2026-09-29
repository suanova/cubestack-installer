# 02 · kubespray 原生方案（每节点本地代理）

> 这是 kubespray **上游默认**的 API 高可用方案，也是被本项目脚本关掉的那一个。
> 本文把它的实现、入口推导链、网络流向、启用路径与代价一次讲清。
>
> 下文用 `$KUBESPRAY` 指代 `deployments/kubespray/kubespray`。

---

## 1. 它是什么

**每台 worker 上跑一个 nginx（或 haproxy）静态 Pod，监听 `127.0.0.1:6443`，
把本机 kubelet/kube-proxy 的 API 连接 TCP 转发到全部 master。**

```
worker 上的 kubelet ──→ https://localhost:6443 ──→ [nginx-proxy 静态 Pod]
                                                        │ least_conn
                                                        ├──→ master01:6443
                                                        ├──→ master02:6443
                                                        └──→ master03:6443
```

特点：

- **零额外机器**：复用现有节点，不占 IP、不需要 VIP、不要求同二层
- **不终止 TLS**：纯 TCP 层转发，证书链不受影响（SAN 不需要加任何东西）
- **故障域极小**：某节点上的代理挂了 → 只影响该节点的 kubelet，且 kubelet 会自动重启它
- **前提**：需要把"入口"从"域名/首台 master"改成"localhost"（见 §5）

---

## 2. 命名坑：它没有独立的 role

按 `roles/nginx-proxy/` 找会扑空。kubespray 近年的重构把这三种 LB 都做成了
`kubernetes/node` role 下的 **task + 模板**：

```
$KUBESPRAY/roles/kubernetes/node/
├── tasks/
│   ├── main.yml                              # 条件分派（决定装哪一个）
│   └── loadbalancer/
│       ├── nginx-proxy.yml                   # ← 本土方案
│       ├── haproxy.yml                       # ← 同一套，换个实现
│       └── kube-vip.yml                      # ← kube-vip（本仓库当前路径）
└── templates/
    ├── manifests/
    │   ├── nginx-proxy.manifest.j2           # 静态 Pod 定义
    │   ├── haproxy.manifest.j2
    │   └── kube-vip.manifest.j2
    └── loadbalancer/
        ├── nginx.conf.j2                     # 代理配置
        └── haproxy.cfg.j2
```

---

## 3. 两种实现（`loadbalancer_apiserver_type`）

| 维度 | `nginx`（默认） | `haproxy` |
|---|---|---|
| 镜像 | `docker.io/library/nginx:1.30.1-alpine`（`download.yml:265`） | `docker.io/library/haproxy:3.2.19-alpine`（`download.yml:267`） |
| 静态 Pod | `/etc/kubernetes/manifests/nginx-proxy.yml` | `/etc/kubernetes/manifests/haproxy.yml` |
| 配置 | `/etc/nginx/nginx.conf`（hostPath → 容器 `/etc/nginx`，只读） | `/etc/haproxy/haproxy.cfg`（hostPath → `/usr/local/etc/haproxy/`） |
| 监听 | `127.0.0.1:6443`（stream 块，`nginx.conf.j2:22`） | `bind 127.0.0.1:6443`（`haproxy.cfg.j2:33`） |
| 后端 | `groups['kube_control_plane']` 全部，`main_access_ip:6443` | 同上 |
| 算法 | `least_conn` | `roundrobin`（默认） |
| **主动健康检查** | ❌ **没有**（只有 `proxy_connect_timeout 1s`，连接失败即重试） | ✅ `option httpchk GET /healthz` + `http-check expect status 200`（`haproxy.cfg.j2:45-46`） |
| 后端失效判定 | 被动：连接失败后 `max_fails`/`fail_timeout` 标记 | 主动：`inter 15s downinter 15s rise 2 fall 2` |
| 长连接超时 | `proxy_timeout 10m` | haproxy 默认 `timeout server` |
| 健康检查端口 | `loadbalancer_apiserver_healthcheck_port`（本仓库 `all.yml:47` = 8081） | 同左，但 bind `0.0.0.0` |
| 探针 | liveness + readiness → `:8081/healthz`（`nginx-proxy.manifest.j2:25-34`） | 同 |

**选择的含义**：`haproxy` 的健康检查是**主动**的（提前把死掉的后端踢出轮询），
`nginx` 是被动的（新连接撞上死后端才失败重试）。当前仓库已有 nginx 版的实测数据（§11），
依赖也最少，建议先用 `nginx`；需要更快剔除死后端时再切 `haproxy`。

> ⚠ 两者**互斥**：`nginx-proxy.yml:2-5` 会删除 `haproxy.yml`，反之亦然（`haproxy.yml:2-5`）。
> 切换 type 不会两个同时跑，但也意味着切换会**重建**另一种的 manifest。

---

## 4. 部署在哪、什么条件下

`$KUBESPRAY/roles/kubernetes/node/tasks/main.yml:27-43`：

```yaml
- name: Install nginx-proxy
  import_tasks: loadbalancer/nginx-proxy.yml
  when:
    - ('kube_control_plane' not in group_names) or (kube_apiserver_bind_address != '::')
    - loadbalancer_apiserver_localhost
    - loadbalancer_apiserver_type == 'nginx'
```

逐条解读：

| 条件 | 含义 |
|---|---|
| `('kube_control_plane' not in group_names) or (kube_apiserver_bind_address != '::')` | **默认（`kube_apiserver_bind_address: '::'`）只有 worker 装**。master 不装 —— 因为 master 自己就监听 `*:6443`，再绑 `127.0.0.1:6443` 会端口冲突；且 master 打自己的 apiserver 本来就没有跨节点依赖 |
| `loadbalancer_apiserver_localhost` | 见 §5，**默认值由"是否定义了 `loadbalancer_apiserver`"派生**（`main.yml:631`） |
| `loadbalancer_apiserver_type == 'nginx'` | 二选一 |

另外 `roles/kubernetes/node` 这个 role 的 play 目标是 `hosts: kube_node`
（`playbooks/cluster.yml` / `scale.yml:70-77`），本仓库的 `kube_node` 组**不含 master**——
两重保险，master 不会装。

> **master 上没有本地代理是正确的设计**，不是缺陷：master 的 kubelet 打自己的 apiserver
> 没有任何跨节点跳数；apiserver 进程挂了由 kubelet 自动重启静态 Pod。

---

## 5. 入口推导链（核心）

### 5.1 源码逐字

`$KUBESPRAY/roles/kubespray_defaults/defaults/main/main.yml:626-652`：

```yaml
631  loadbalancer_apiserver_localhost: "{{ loadbalancer_apiserver is not defined }}"
632  loadbalancer_apiserver_type: "nginx"
635  kube_apiserver_global_endpoint: |-
636    {% if loadbalancer_apiserver is defined -%}
637        https://{{ apiserver_loadbalancer_domain_name }}:{{ loadbalancer_apiserver.port | default(kube_apiserver_port) }}
638    {%- elif loadbalancer_apiserver_localhost and (loadbalancer_apiserver_port is not defined or loadbalancer_apiserver_port == kube_apiserver_port) -%}
639        https://localhost:{{ kube_apiserver_port }}
640    {%- else -%}
641        https://{{ first_kube_control_plane_address | ansible.utils.ipwrap }}:{{ kube_apiserver_port }}
642    {%- endif %}
643  kube_apiserver_endpoint: |-
644    {% if loadbalancer_apiserver is defined -%}
645        https://{{ apiserver_loadbalancer_domain_name }}:{{ loadbalancer_apiserver.port | default(kube_apiserver_port) }}
646    {%- elif ('kube_control_plane' not in group_names) and loadbalancer_apiserver_localhost -%}
647        https://localhost:{{ loadbalancer_apiserver_port | default(kube_apiserver_port) }}
648    {%- elif 'kube_control_plane' in group_names -%}
649    https://{{ kube_apiserver_bind_address | regex_replace('::', '127.0.0.1') | ansible.utils.ipwrap }}:{{ kube_apiserver_port }}
650    {%- else -%}
651        https://{{ first_kube_control_plane_address | ansible.utils.ipwrap }}:{{ kube_apiserver_port }}
652    {%- endif %}
```

**优先级从上到下，第 1 条永远赢。**

### 5.2 四种拓扑下各客户端走哪

| 拓扑 | worker kubelet/kube-proxy | master kubelet | admin.conf | 节点 `/etc/hosts` |
|---|---|---|---|---|
| **① 现状**：定义了 `loadbalancer_apiserver`（本仓库） | `https://<域名>:6443` → 首 master | **同左**（不走自己的 apiserver） | `https://<域名>:6443` | `<address> <域名>` |
| **② 纯本地代理**：摘掉 `loadbalancer_apiserver` | `https://localhost:6443` → 本机代理 | `https://127.0.0.1:6443` → 自己 | kubeadm 默认（`controlPlaneEndpoint`） | **上游不再写**（见 §7） |
| ③ 两者都定义 | `https://<域名>:6443`（分支 1 赢，**本地代理装了没人用**） | 同左 | 域名 | 域名 |
| ④ 都没有 | `https://<首 master>:6443` | 同左 | 首 master | 不写 |

> **③ 就是"假修复"** —— 见 §6。

### 5.3 谁消费 `kube_apiserver_endpoint`

| 消费点 | 作用 |
|---|---|
| `roles/kubernetes/kubeadm/tasks/main.yml:102`、`:114` | **改写 kubelet.conf 的 `server:`**（含控制面节点） |
| `roles/kubernetes/kubeadm/tasks/main.yml:155-160` | 改写 **kube-proxy 的 ConfigMap kubeconfig**（条件含 `loadbalancer_apiserver_localhost`）→ worker 的 kube-proxy 也走本机代理 |
| `roles/kubernetes/node/templates/node-kubeconfig.yaml.j2:8` | 节点侧 kubeconfig |
| `roles/kubernetes/control-plane/tasks/kubeadm-fix-apiserver.yml:19` | apiserver 配置修正 |
| 各类健康探针 handler | 探活 |

### 5.4 join / 扩容时的特例（重要）

`roles/kubernetes/kubeadm/tasks/main.yml:2-12`：

```yaml
kubeadm_discovery_address: >-
  {%- if "127.0.0.1" in kube_apiserver_endpoint or "localhost" in kube_apiserver_endpoint -%}
  {{ first_kube_control_plane_address | ansible.utils.ipwrap }}:{{ kube_apiserver_port }}
  {%- else -%}
  {{ kube_apiserver_endpoint | replace("https://", "") }}
  {%- endif %}
```

**上游原生处理了"先有鸡还是先有蛋"**：新节点加入时本机还没有代理，所以
**join/discovery 用首 master 的 IP**；只有**运行时**才走 localhost。

含义：**"新增节点"这个操作仍然依赖首 master**（一次性动作，不是运行时路径）。
若首 master 恰好在扩容窗口内宕机，join 会失败 —— 这是本方案**唯一**的残留依赖，登记在
[04 文档 §8](04-decision.md#8-残留风险登记)。

---

## 6. 为什么"只改开关是假修复"

`loadbalancer_apiserver_localhost` 这个开关**同时控制两件事**：

1. 装不装本地代理静态 Pod（§4）
2. kubelet 走不走 localhost（§5.1 的分支 2）

只要 `loadbalancer_apiserver` **被定义**，分支 1 就恒赢 → **代理装上了，但没有任何流量经过它**，
白白多一个静态 Pod 和一个 8081 监听。这就是"假修复"。

**本仓库对旧开关 `KUBE_VIP_LOCAL_PROXY` 的当前语义（2026-09-28 起，见 [04-decision.md](04-decision.md) 的 **D8**）**：

- 它已**从"硬失败护栏"改为"兼容别名"** —— 语义被 `API_LOCAL_LB_ENABLED` 吸收
  （`lib-common.sh:1039-1045` 的 `api_local_lb_enabled()`：`API_LOCAL_LB_ENABLED` 未设时回落到它）。
  **单独设 `KUBE_VIP_LOCAL_PROXY=true` 会真正打开节点侧本地代理**，不再被拦下 ——
  因为新实现走 §7 路线 2（摘掉 `loadbalancer_apiserver` 块，kubelet 真会走 localhost），
  "设了也不生效"这个假修复前提随之消失。
- 仍保留的**唯一**硬失败：`KUBE_VIP_LOCAL_PROXY=true` 与**显式**的 `API_LOCAL_LB_ENABLED=false`
  同时给 → `lib-common.sh:831-838`（`kube_vip_validate_config()` 第 ⑤ 条）`err` + `return 1`
  （"两个开关冲突, 请只留一个"）。
- 注释位置（行号已更正）：`deployments/config/cluster.conf:99`（实例，本机生成、不入库）/
  `deployments/config/cluster.conf.example:95`（模板）—— 写明"只设
  `loadbalancer_apiserver_localhost=true` 而保留该块 = 假修复"。

> 本节的"假修复"对**上游** kubespray 的描述仍然成立（`loadbalancer_apiserver` 被定义时分支 1 恒赢）；
> 变的是**本仓库的开关语义** —— 过去设 `KUBE_VIP_LOCAL_PROXY=true` 会被拦下，现在它生效。
> 把它真正落地的机制是 `sync-kubespray-config.sh` 按模式摘/留该块（§7 路线 2）。

---

## 7. 两条真正启用的路线

| | 路线 1：保留外部入口 + 覆写节点侧 | **路线 2：摘掉 `loadbalancer_apiserver`（本方案选定）** |
|---|---|---|
| 做法 | 保留 `loadbalancer_apiserver`（域名/VIP 对外入口不变），在 kubespray 跑完后**手工覆写** kubelet.conf / kube-proxy kubeconfig 为 localhost | 从 `all.yml` 摘掉 `loadbalancer_apiserver` 块，让上游按 §5.2 拓扑② 自然分派 |
| 上游支持 | ❌ 逆着模板优先级走 | ✅ 上游原生路径 |
| 每次重跑/扩容 | **必须重新覆写**，否则静默回退成域名 → 单点（回归风险） | 上游自动写完，无需干预 |
| `controlPlaneEndpoint` | 保持域名 | 回退首 master IP（`kubeadm-config.v1beta4.yaml.j2:126-128`） |
| 域名/VIP 对外入口 | 保持 | **保持**（改用我们自己的模块写节点 `/etc/hosts`，见 §8） |
| 节点 `/etc/hosts` | 上游继续写 | **上游不再写**，由我们的模块负责（§8） |
| 结论 | 改动看似小，但把正确性押在"每次都要记得覆写"上 | **选定**：让上游按设计工作，我们只补它不做的那两件事 |

> `cluster.conf:99` 的注释把路线 1 标为"推荐"，那是**本方案之前**的判断。
> 本方案选择路线 2 的理由：路线 2 同样保留了域名/VIP 对外入口（这正是路线 1 的优点），
> 但把"节点侧走 localhost"变成上游的**原生行为**，而不是每次部署后手工维持的状态。
> 这一分歧已在 [04 文档](04-decision.md) 的决策记录中登记。

### 7.1 路线 2 需要我们自己补的两件事

1. **节点 `/etc/hosts` 的域名行**：摘掉 `loadbalancer_apiserver` 后，
   上游写入任务的条件为假（`0090-etchosts.yml:27-38` 的 `when: loadbalancer_apiserver is defined`；
   ⚠ 2026-09-28 注：该任务在 v2.32 树**已不存在**，hosts 行现由本仓库 `03_k8s_hosts.sh` 写，这里的结论仍成立——本地代理模式下没人写域名行），
   **没人再写**。而人 SSH 到节点上用 kubectl（admin.conf 的 server 是域名）仍然需要它 →
   由我们的模块收敛（域名 → 当前入口地址）。
2. **关闭时的 manifest 清理**：上游**只**互相删 nginx/haproxy 的 manifest，
   **不会**在 `localhost=false` 时删除 `nginx-proxy.yml`（`nginx-proxy.yml:1-6` 只删 haproxy）。
   关掉开关后残留的静态 Pod 必须由我们的模块清理（与 kube-vip 模块的 `DEFAULT: 1` + 清理分支同一模式）。

---

## 8. 目标网络流向（路线 2 落地后）

```
┌─ worker (mxgpu-3-32…36) ───────────────────────────────────────┐
│  kubelet / kube-proxy ──→ https://localhost:6443               │
│                              │                                  │
│                     [nginx-proxy 静态 Pod, hostNetwork]        │
│                              │ least_conn                       │
└──────────────────────────────┼──────────────────────────────────┘
                               │
┌─ master (mxgpu-3-28/29/31) ───┼──────────────────────────────────┐
│  kubelet / kube-proxy ──→ https://127.0.0.1:6443 → 自己的 apiserver
│                               │                                  │
│                          [kube-apiserver :6443] ←───────────────┘
│                               ▲                                  │
│                          [kube-vip] 持 VIP (对外/管理入口)        │
└───────────────────────────────┼──────────────────────────────────┘
                                │
   运维 kubectl / CI / 外部系统 ──→ k8s-api.cubestack.io → VIP
   Pod ──→ kubernetes.default.svc → ipvs → 三台 (现状已满足)
   新节点 join ──→ https://<首 master>:6443  (kubeadm_discovery_address)
```

| 客户端 | 目标 | 依赖 | 故障切换 |
|---|---|---|---|
| worker kubelet/kube-proxy | 本机 `localhost:6443` | 本机代理 | 后端失效重试 **~1s**（实测，见 §11） |
| master kubelet | 本机 `127.0.0.1:6443` | 自己的 apiserver | apiserver 由 kubelet 自动重启 |
| 运维/CI/外部 | 域名 → VIP | kube-vip | VIP 漂移 1–5s |
| Pod | `kubernetes.default.svc` | kube-proxy ipvs | 已有（三端点） |
| 新节点 join | 首 master IP | 首 master | ❌ 无（一次性动作） |

---

## 9. 静态 Pod 形态细节

`templates/manifests/nginx-proxy.manifest.j2`：

```yaml
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  priorityClassName: system-node-critical        # 优先调度，不易被驱逐
  containers:
  - name: nginx-proxy
    image: {{ nginx_image_repo }}:{{ nginx_image_tag }}     # docker.io/library/nginx:1.30.1-alpine
    livenessProbe:  { httpGet: { path: /healthz, port: 8081 } }   # 仅当 healthcheck_port 定义
    readinessProbe: { httpGet: { path: /healthz, port: 8081 } }
    volumeMounts:
    - { mountPath: /etc/nginx, name: etc-nginx, readOnly: true }
  volumes:
  - { name: etc-nginx, hostPath: { path: /etc/nginx } }
```

配置热更新机制：改 `nginx.conf` → `nginx-cfg-checksum` 注解变化 → kubelet 重建 Pod
（`nginx-proxy.yml:22-28` 取了 checksum，manifest 第 10 行放进了注解）。

⚠ `loadbalancer_apiserver_healthcheck_port`（8081）在 nginx 的 **http 块**里监听，**没有绑定到 loopback**
（`nginx.conf.j2:46`）→ 该端口在节点网络上可达。它只返回 200 和 stub_status，不是数据面，
但在严格环境里值得知道。

---

## 10. 离线镜像要求（**当前仓库的硬缺口**）

> ✅ **2026-09-28 更新：nginx 版已补齐**（标题里的"硬缺口"与下表 **只剩 haproxy 行成立**，
> 本轮 `API_LOCAL_LB_TYPE` 默认 `nginx`，不走 haproxy）：`docker.io/library/nginx:${API_LB_NGINX_IMAGE_TAG}`
> （默认 `1.30.1-alpine`）已登记进 `deployments/config/images.manifest`（`k8s-base` 组），
> `PRELOAD_IMAGE_PATTERNS` 已加 `library_nginx`。落地细节与坑见
> [offline-files/kubespray/README.md](../../deployments/offline-files/kubespray/README.md) 的 nginx 一节。

| 需要 | 值 | 现状 |
|---|---|---|
| nginx 版 | `docker.io/library/nginx:1.30.1-alpine` | ✅ **2026-09-28 已补齐**（登记 `images.manifest` + `PRELOAD_IMAGE_PATTERNS` 加 `library_nginx`）。**原缺口**：`PRELOAD_IMAGE_PATTERNS` 不含 nginx；`offline-files/kubespray/images/nginx_1.27.tar` 的 tag 是 `1.27`，**对不上** |
| haproxy 版 | `docker.io/library/haproxy:3.1.3-alpine` | ❌ 同上，完全缺失 |

`offline-files/nginx/nginx.tar` **不能**直接复用：那是 verify 模块的测试后端镜像
（`NGINX_TAG=1.27`，`cluster.conf:671`），且文件名被 `lib-common.sh` 的 `ensure_registry_nginx`
锁死为 `nginx*.tar`（`images.manifest:84`）—— 放错目录或改名都会影响既有链路。

**正确做法**：LB 用的 nginx 镜像登记进 `offline-files/kubespray/` 的 kubespray 镜像集，
并把 `library_nginx` 加进 `PRELOAD_IMAGE_PATTERNS`。不补的后果是**响亮的**
（静态 Pod `ImagePullBackOff`），不是静默失效。

---

## 11. 故障行为与实测数据

仓库已有的实测（2026-09-22，裸金属，3 master，worker 上起同款 nginx 代理，upstream 放黑洞地址）：

| 场景 | 结果 | 数据 |
|---|---|---|
| 后端全健康 | 与直连无差异 | 成功路径 **~4.4ms** |
| **1/3 后端黑洞** | **30/30 成功** | 全部落健康后端 |
| **2/3 后端黑洞** | **20/20 成功** | 19 次 ~4.4ms，1 次 **1.0045s**（= `proxy_connect_timeout 1s`） |

> 机理：nginx **stream** 模块没有 `proxy_next_upstream`，重试发生在 **TCP 连接级**；
> 最坏延迟 = `proxy_connect_timeout` = 1s。**零失败**（只要还有一台健康 master）。

已知边界（**必须知道**）：

| 场景 | 行为 |
|---|---|
| 后端**静默死亡**（已建立的连接） | 最长等 `proxy_timeout 10m` 才断（`nginx.conf.j2:27`）。kubelet 的 watch 长连接会感受到 |
| 后端**进程崩溃**（新连接） | 连接失败即重试，最坏 1s |
| 本机代理进程崩溃 | 仅该节点 kubelet 受影响；static pod + system-node-critical 会自动重启 |
| **全部 master 宕机** | 无解（任何方案都无解） |

---

## 12. 如何查看

```bash
# ── 本地代理是否在位（启用后）──
ssh ubuntu@<worker> "ls -l /etc/kubernetes/manifests/nginx-proxy.yml; cat /etc/nginx/nginx.conf | head -30"
ssh ubuntu@<worker> "sudo crictl ps --name nginx-proxy"
ssh ubuntu@<worker> "sudo ss -lntp | grep -E '127.0.0.1:6443|8081'"

# ── 节点侧入口是否已切到 localhost ──
ssh ubuntu@<worker> "sudo grep -m1 server: /etc/kubernetes/kubelet.conf"   # 期望 https://localhost:6443
ssh ubuntu@<master> "sudo grep -m1 server: /etc/kubernetes/kubelet.conf"   # 期望 https://127.0.0.1:6443

# ── kube-proxy 的 kubeconfig（in-cluster ConfigMap）──
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep server

# ── 代理本身可用性（不经 TLS，纯 TCP 连通）──
ssh ubuntu@<worker> "curl -sk https://localhost:6443/healthz"              # 期望 ok
ssh ubuntu@<worker> "curl -s http://localhost:8081/healthz"                # 期望 200

# ── 后端黑洞演练（不会真的改集群：在 worker 上临时验证）──
# 见 docs/api-ha/05-operations.md §3
```

---

## 13. 一句话总结

> kubespray 原生方案解决的是**"节点不要依赖任何一台具体 master"**，
> 代价是每节点一个静态 Pod、入口语义改成 localhost。
> 它**不解决**"外部/管理入口不稳定"——那是 kube-vip 的职责。两者叠加才是完整答案。
