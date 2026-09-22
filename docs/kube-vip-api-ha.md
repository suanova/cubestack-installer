# Kubernetes API Server 高可用(kube-vip VIP)设计方案

> 状态: **已实施**(2026-09-22)—— 代码全部落地, `check-modules` 全绿; **实机验证待执行**
> 涉及模块: `02_k8s/06_k8s_deploy.sh`(阶段确认门)· 新增 `02_k8s/08_verify_kube_vip.sh`
> 开关: `KUBE_VIP_ENABLED`(**默认 true**)· 配置项 `K8S_API_VIP` / `KUBE_VIP_INTERFACE`
> 上游资产: kubespray 原生支持(`deployments/kubespray/kubespray/`), 无需自研
>
> **❗ 实施过程中对本文档的 4 处修正**(详见第 14 节, 读下文时以此为准):
> 1. kube_vip_* 变量写入 **`addons.yml`**, 不是 `k8s-cluster.yml`(那里没这个块, `addons.yml` 有 kubespray 自带模板)
> 2. 两阶段**对新建集群同样必需** —— `/etc/hosts` 写在 preinstall 角色, kube-vip 在 etcd 之后, 差约 10 分钟
> 3. `advertise-address` 必须写成 **Jinja 表达式**(按节点取值), 写回具体 IP 会抵消修复
> 4. 切换确认的倒计时放在 **`06_k8s_deploy.sh`**, 不能放 sync 脚本(其 stdout 被重定向到 /dev/null)

---

## 1. 结论摘要

**kubespray 原生支持 kube-vip,且是本仓库 vendored 版本的一等公民。** 不需要引入外部
manifest、不需要 DaemonSet、不需要自研静态 Pod。

但本次分析发现**三件比"引入 kube-vip"本身更重要的事**,它们构成了本方案的真正内容:

| # | 发现 | 影响 |
|---|------|------|
| ① | **kubespray 原生默认本来是 nginx-proxy 真高可用,被本项目脚本的"定义 `loadbalancer_apiserver`"动作翻转关闭了**(提交 `2ee7738`,目标正确但副作用丢了 HA) | 这是本方案要修的真问题,不是优化。且说明损失是**自致的**,非上游缺失 |
| ② | `advertise-address` 被统一写成第一个 master IP,导致集群内 `kubernetes` Service 也单点 | 独立于 kube-vip 的第二处单点,建议一并修 |
| ③ | kubespray 上游对 kube-vip **零 CI 覆盖** + bootstrap 时序链有一处无法靠读代码确认 | 决定了实施顺序:**先证伪,再铺开** |

---

## 2. 现状问题(为什么必须做)

### 2.1 kubespray 原生默认**本来是高可用的** —— 是本项目的脚本把它关掉的

`kubespray_defaults/defaults/main/main.yml:631`:

```yaml
loadbalancer_apiserver_localhost: "{{ loadbalancer_apiserver is not defined }}"
loadbalancer_apiserver_type: "nginx"
```

**不定义** `loadbalancer_apiserver` 时,该派生值为 `true` → 安装 nginx-proxy。
其配置(`roles/kubernetes/node/templates/loadbalancer/nginx.conf.j2`)遍历**全部**
`kube_control_plane` 主机做 `least_conn` 反代,并设 `proxy_connect_timeout 1s`:

```nginx
upstream kube_apiserver {
  least_conn;
  {% for host in groups['kube_control_plane'] %}
  server {{ hostvars[host]['main_access_ip'] }}:6443;
  {% endfor %}
}
server { listen 127.0.0.1:6443; proxy_pass kube_apiserver; proxy_connect_timeout 1s; }
```

即: 每个 worker 上跑一个 nginx 监听 `127.0.0.1:6443`,自动摘除故障 master。
**这是真高可用,且不需要 VIP、不需要外部 LB、不要求同二层网络。**

**但这个默认值被本项目的脚本关掉了**,机理是"派生默认被定义动作翻转":

| 步骤 | 位置 | 动作 |
|---|---|---|
| 1 | `lib-common.sh:474-479` | `APISERVER_ADDRESS` 默认取第一个 master IP |
| 2 | `sync-kubespray-config.sh:45,56` | `API_ADDR="${API_IP}"` → sed 写入 `all.yml` 的 `loadbalancer_apiserver.address` |
| 3 | kubespray `main.yml:631` | `loadbalancer_apiserver is not defined` 变为假 → `loadbalancer_apiserver_localhost` **翻转为 false** → nginx-proxy 不再安装 |
| 4 | `all.yml` 静态行 | 另显式写着 `loadbalancer_apiserver_localhost: false`(双保险) |

引入该行为的提交是 `2ee7738`(2026-08-27),其**目标正确** ——
"API 入口统一 + 消除硬编码 IP + VM/裸金属行为一致";但副作用是顺带丢掉了高可用。
这是本方案的**真实起点**,而不是"kubespray 默认没有高可用"。

### 2.2 于是客户端全部指向第一个 master

实机 `deployments/kubespray/inventory/cubestack-cluster/group_vars/all/all.yml`:

```yaml
loadbalancer_apiserver_localhost: false          # → nginx / haproxy 本地代理均未部署
loadbalancer_apiserver:
  address: 10.244.1.11                            # ← 第一个 master,不是 VIP
apiserver_loadbalancer_domain_name: "k8s-api.cubestack.io"
```

加上 `0090-etchosts.yml:31` 把域名写成 `{{ loadbalancer_apiserver.address }} {{ 域名 }}`
→ **全集群节点的 `/etc/hosts` 都把 `k8s-api.cubestack.io` 解析到 master01**。

所有非 master 节点(以及 `controlPlaneEndpoint`)的 API 入口因此只有一个地址。

**master01 宕机的后果**: 存量 Pod 继续跑,但 kubelet 无法上报状态、新 Pod 无法调度、
PVC / Service / 任何 controller 交互全部中断 —— 集群等于脑死亡。这不是"降级",是"失联"。

### 2.3 为什么不用"把 nginx-proxy 开回来"作为解法

这是本方案最容易被质疑的一点,需明确回答。

nginx-proxy 确实是零成本高可用,但它**不能替代** kube-vip:

1. **只覆盖 worker**。control-plane 节点自身仍走各自的本地 apiserver,它不提供
   "控制平面自身对外的一个稳定入口"。
2. **不给外部客户端稳定入口**。集群外 kubectl、跨集群调用、以及本仓库大量依赖的
   "把域名/IP 给到外部系统"的场景,仍需要一个不随 master 存亡变化的地址。
3. **与 `loadbalancer_apiserver` 互斥**。kubespray 文档明确二者互斥;且
   `kube_apiserver_endpoint` 模板中 `loadbalancer_apiserver` 分支优先,同时配置时
   `loadbalancer_apiserver_localhost` 实际上不生效。

**但它是一个值得保留的叠加选项**: 若未来希望 worker 侧不依赖 VIP holder 也能直连
各 master(第二条独立通路),nginx-proxy 是最廉价的手段。本方案**不采用**,理由是
与本次"统一入口"的目标冲突,且会与 `loadbalancer_apiserver` 的定义互斥。
记录在此以备将来评估。

### 2.4 一个必须承认的退步: worker 侧故障切换会比原来**慢**

kube-vip 与被它取代的 nginx-proxy 解决的是**不同层面**的问题,不能简单说"更好":

| | nginx-proxy(原有,已关) | kube-vip VIP(本方案) |
|---|---|---|
| 覆盖范围 | 仅 worker 的 API 出口 | 全部客户端 + 外部 + `controlPlaneEndpoint` |
| 对**外部**客户端 | ❌ 不提供稳定入口 | ✅ 提供 |
| worker→API 故障切换 | **~1s**(`proxy_connect_timeout 1s` + `least_conn` 自动摘除) | **~5-10s**(租约过期才漂移) |
| 依赖额外机制 | 无(VIP、同二层、外部 LB 都不需要) | 需要 VIP + 同二层 + ARP 可用 |

**kube-vip 覆盖面是超集,但 worker 侧的故障切换慢了约一个数量级。**
之所以仍选 kube-vip: 外部/跨系统的稳定入口是 nginx-proxy 给不了的,而本仓库大量场景
(registry 域名、外部 kubectl、把 API 地址交给其他系统)恰恰需要它;且上游明确二者互斥
(见 2.3),无法兼得。

**处置(不调参,先立基线)**:

- 保持 kubespray 默认租约参数 `leaseduration=5 / renewDeadline=3 / retryPeriod=1`。
  **不建议为了追平 1s 而收紧租约** —— 过短的租约会在网络抖动时误判 leader 失效,
  而旧 leader 若未及时察觉会继续持有 VIP,风险高于多等几秒。
- 在 verify 的漂移演练中**实测并记录**这个时间作为基线(第 9.2 节 ⑥ 应输出耗时数字)。
- 若实测发现"节点存活但 apiserver 进程已死"这一场景恢复过慢,再评估启用
  `kube_vip_cp_detect=true`(kubespray 已暴露该变量,默认 `false`)——
  它按本地 apiserver 健康状态判定,不必等租约到期。**先测后调,不预先启用。**

### 2.5 集群内 `kubernetes` Service 也是单点

`cubestack-offline.sh:1364-1372` 把 `kube_apiserver_extra_args.advertise-address`
**统一写成第一个 master IP**,三个 master 的 apiserver 于是都对外宣告 master01 的地址
→ `kubernetes` Service 的 EndpointSlice 只有一条 → 集群内经 Service 访问 API 同样单点。

这一处**独立于 kube-vip**,即使引入了 VIP 也不会自动被修掉。

---

## 3. 关键认知纠偏:静态 Pod,不是 DaemonSet

参考资料中常见的 `kube-vip manifest daemonset` 用法**不适用于本场景**,原因是启动顺序:

```
playbooks/cluster.yml
├─ Install Kubernetes nodes   →  roles/kubernetes/node
│                                ├─ :19  Install kube-vip   → 写 static pod manifest
│                                └─ :145 import kubelet.yml → 装并 enable kubelet
└─ Install the control plane  →  kubeadm init, controlPlaneEndpoint 指向 VIP
```

kube-vip 的 manifest 在 `kubeadm init` **之前**落盘(`node/tasks/main.yml:19` 早于
`kubeadm.yml` 所在 play),kubelet 随后拉起它。DaemonSet 模式做不到这一点 ——
它需要 API Server 才能被创建,而 API Server 又需要 VIP 才能起来,**是死锁**。

DaemonSet 只适用于"集群已存在,事后补服务 LoadBalancer"的场景;而服务 LB 我们已经有
MetalLB 在做(见第 4 节决策 D1)。

---

## 4. 设计决策(已确认)

| # | 决策 | 取值 | 理由 |
|---|------|------|------|
| D1 | 职责边界 | **只做控制平面 VIP**;`kube_vip_services_enabled: false` | MetalLB 已承载 registry / ingress / EG 的 LoadBalancer VIP 且实机验证充分。两者分工会互相抢 LoadBalancer 分配权 |
| D2 | 启用策略 | **默认开启**;存量集群需**显式重跑**才切换 | 修复 2.1 的伪高可用;不改变存量集群的既有行为直到用户主动重跑 |
| D3 | VIP 来源 | **自动推导 + 可显式覆盖** | 零配置可跑通;多集群共用网段时用 `K8S_API_VIP` 覆盖 |
| D4 | 转发模式 | **纯故障切换**;`kube_vip_lb_enable: false` | apiserver 本身有 leader election,真负载均衡收益有限,却新增转发层故障点;且 `masquerade` 需 privileged 容器 + 多一个 `-iptables` 镜像变体进离线资产 |
| D5 | 新集群路径 | **两阶段**(与存量集群同一套机制) | 用一次额外运行换掉第 7 节风险 R2 整条时序不确定性 |
| D6 | 故障演练 | **verify 默认执行**,带自动恢复 | 漂移能力是这个方案唯一的核心价值,不实测等于没验证 |
| D7 | 文档位置 | `docs/kube-vip-api-ha.md` | 与本仓库既有约定一致 |

---

## 5. 配置面

### 5.1 `deployments/config/cluster.conf` 新增(阶段二 k8s 区块)

```bash
KUBE_VIP_ENABLED="${KUBE_VIP_ENABLED:-true}"      # API Server VIP 高可用(kubespray 原生 kube-vip 静态 Pod)
K8S_API_VIP="${K8S_API_VIP:-}"                    # 留空=自动推导; 显式值优先
KUBE_VIP_INTERFACE="${KUBE_VIP_INTERFACE:-}"      # 留空=kube-vip 自动检测; 多网卡环境显式指定
```

### 5.2 三条硬性校验(运行期 + `check-modules` 静态各做一次)

1. **互斥**: `KUBE_VIP_ENABLED=true` 与 `HAPROXY_ENABLED` / `KEEPALIVED_ENABLED`
   同时为真 → **硬失败**。二者都在争 `loadbalancer_apiserver.address` 的解释权,
   同时开是确定性配置冲突。
2. **地址隔离**: `K8S_API_VIP` 落在 `METALLB_POOL` 内 → **硬失败**。
   MetalLB 可能把 API VIP 分配给某个 Service,直接抢走控制平面入口。
3. **可用性探测**(仅自动推导时): 候选地址需**同时**通过
   - ICMP 探测 —— kube-vip 的 VIP 真实绑在网卡上,ICMP 有效;
     **注意这与 MetalLB 相反**(`tools/lb/deploy-registry.sh:94` 明确记录了 MetalLB L2 VIP 不响应 ping)
   - 6443 端口探测 —— 识别其他集群的 API VIP

   推导起点 `.210`,显式排除节点 IP 与 METALLB_POOL 覆盖区间。

   > ⚠ 探测同样**必须在各 master 上经 SSH 执行**(理由见 7.2)。部署机没有到节点网段的
   > 路由时,从部署机探测只会得到"全部候选都可用"的错误结论 —— 这比不探测更危险。

### 5.3 为什么改动面比想象中小

全链路 kubeconfig 用的都是**域名** `k8s-api.cubestack.io`,不是 IP:

- `kubeadm-setup.yml:92` — `kubeadm_config_api_fqdn` = `apiserver_loadbalancer_domain_name`
  → `controlPlaneEndpoint` 就是该域名
- `0090-etchosts.yml:31` — 域名解析指向 `loadbalancer_apiserver.address`

所以**切换 VIP 不需要改任何 kubeconfig 内容**,只改域名解析指向。证书 SAN 同样免费获得:

- `kubeadm-setup.yml:40` — `sans_lb_ip` 自动把 `loadbalancer_apiserver.address` 并入 SAN
- `kubeadm-setup.yml:48` — `sans_kube_vip_address` 自动把 `kube_vip_address` 并入 SAN

`supplementary_addresses_in_ssl_keys` 中的各 master IP **保持不动**(第 6 节改为按节点
宣告自身 IP 后,这些 IP 仍是必需的)。

---

## 6. 实现落点(逐文件)

### 6.1 `deployments/kubespray/cubestack-offline.sh` — 唯一的核心改动点

`update_loadbalancer_all_yml()`(`:1308`)已经是「按 hosts.yml 同步环境 IP」的唯一入口,
是这次改动的天然落点。

**改动 A — `loadbalancer_apiserver.address`(`:1331-1361` 区块)**

`api_ip` 的取值从"恒为第一个 master IP"改为**按阶段取值**:

```bash
# 阶段一(VIP 就位, 未切入口): api_ip = master_ips[0]      ← 与今天完全一致
# 阶段二(切入口):              api_ip = ${K8S_API_VIP}
```

SAN 区块(`:1350`)逻辑不变,但表达式需包含 VIP —— 实际无需手工加,VIP 会经 `sans_lb_ip`
自动进入 SAN,此处只需确保**不要**把 VIP 从列表中误删。

**改动 B — `advertise-address`(`:1364-1372` 区块)**

从"统一写第一个 master IP"改为**按节点写各自 IP**,使用 kubespray 自己的惯用法:

```yaml
kube_apiserver_extra_args:
  advertise-address: "{{ kube_apiserver_address }}"
```

参考 `kubespray_defaults/defaults/main/main.yml:628`:
`kube_apiserver_address: "{{ hostvars[inventory_hostname]['main_ip'] }}"`

> ⚠ **这是本方案里最容易写错的一处。** 当前实现是 sed 把一个**数值字面量**写进去;
> 改成 Jinja 表达式后,这个值**不再依赖 hosts.yml**,脚本也就不应该再"同步"它 ——
> 正确的做法是把 `:1364-1372` 整块从"每跑一次 sed 改一次 IP"**改为幂等的断言/修复**:
> 检查该行是否等于固定的 Jinja 字面量 `advertise-address: "{{ kube_apiserver_address }}"`,
> 不等于才改写。
>
> 若沿用现有思路(把 VIP 或某个 IP 塞进这个字段),会**直接抵消**本节的修复效果 ——
> 三个 master 又将宣告同一个地址。实施时必须手工确认这一行最终落盘的内容。

### 6.2 inventory 模板(静态文件, 由 6.1 的脚本维护其中的值)

> ⚠ **实施修正**: kube_vip_* 参数写的是 **`addons.yml`**, 不是本文档原先写的 `k8s-cluster.yml`。
> 依据: `addons.yml` 里本来就有 kubespray 自带的 `# Kube VIP` 注释块(第 209 行起), 照它的键名写即可;
> `k8s-cluster.yml` 里没有这个块。实现落在 `lib-common.sh` 的 `update_kube_vip_addons_yml()`,
> 以 `# Kube VIP` 行为锚点整块重写(幂等, 已实测重复运行行数稳定)。

`group_vars/all/all.yml` —— 结构不变,`address` 值由 `sync-kubespray-config.sh` 按阶段写入:

```yaml
# 阶段一(VIP 未绑): address = 第一个 master IP
# 阶段二(VIP 已绑): address = VIP
loadbalancer_apiserver:
  address: 10.244.1.11
  port: 6443
```

`group_vars/k8s_cluster/addons.yml` —— 由脚本重写的块:

```yaml
# Kube VIP
kube_vip_enabled: true
kube_vip_address: "10.244.1.210"          # 恒为 VIP(静态 Pod 的 args.address)
kube_vip_arp_enabled: true
kube_vip_controlplane_enabled: true
kube_vip_services_enabled: false          # D1: 服务 LB 归 MetalLB
kube_vip_lb_enable: false                 # D4: 纯故障切换
kube_vip_interface: ens5                  # 仅当 cluster.conf 显式指定时写入
```

`group_vars/k8s_cluster/k8s-cluster.yml` —— `advertise-address`(**实施修正**: 必须是表达式):

```yaml
kube_apiserver_extra_args:
  advertise-address: "{{ kube_apiserver_address }}"
```

> ⚠ 这一行是整个方案里最容易写错的地方。它引用 kubespray 自带的
> `kube_apiserver_address`(`kubespray-defaults main.yml:628` = 各节点自己的 `main_ip`),
> **不能写回具体 IP** —— 写成 `advertise-address: "10.244.1.11"` 会让三个 apiserver 又宣告同一地址,
> 直接抵消 2.5 节的修复。实现里 `update_advertise_address_yml()` 用 `grep -qF` 断言整行字符串,
> 已是目标值则完全不动。

`kube_proxy_strict_arp: true` **已经是实机 inventory 的值**(`k8s-cluster.yml:124`),
是 kube-vip ARP 模式的硬前置(`roles/kubernetes/node/tasks/loadbalancer/kube-vip.yml:1-7`
有 fail 断言),**无需改动** —— 这是本方案前置成本接近零的主要原因。

---

## 7. 两阶段切换流程

### 7.1 为什么要拆两阶段

`loadbalancer_apiserver.address` 一旦改成 VIP,而 kube-vip 尚未真正绑上 VIP,
"解析指向 VIP"与"控制平面入口消失"就会**同时发生**。对存量集群,这个窗口 =
`preinstall 写 /etc/hosts` 到 `node role 拉起 kube-vip` 之间,期间 **worker 的 kubelet
全部打不通 API**;若部署中途失败,集群会停在失联状态。

拆成两个可独立验证的步骤后,每一步都能停下来确认。

| | **阶段一: VIP 就位** | **阶段二: 切入口** |
|---|---|---|
| `kube_vip_*` | 齐全 | 齐全 |
| `loadbalancer_apiserver.address` | **保持 master01** | **= VIP** |
| 效果 | VIP 已 bound 在某 master,但无人使用 | 全集群经 VIP 访问 API |
| 风险 | **对存量集群零影响,随时可回滚** | 证书 SAN 重签 + 各节点 apiserver 重启 |

### 7.2 阶段判定(幂等, 无需新增状态变量)

**判定输入**: inventory 当前 `loadbalancer_apiserver.address` + **VIP bound 探测结果**。

```
读 inventory 当前 loadbalancer_apiserver.address
  ├─ == K8S_API_VIP
  │    ├─ VIP 已 bound  → 已切换, 常规全量运行
  │    └─ VIP 未 bound  → ⚠ 破损态: 客户端正指向一个不存在的地址, 集群可能已失联
  │                        → 醒目告警 + 本次运行优先把 VIP 拉起来(kube-vip 已装则重启 static pod)
  ├─ == 第一个 master IP 且 VIP 未 bound → 阶段一(VIP 就位)
  └─ == 第一个 master IP 且 VIP 已 bound → 阶段二(切入口, 需确认)
```

> **探测必须在各 master 上经 SSH 执行**,不能从部署机探测 —— installer 容器/部署机
> 不一定有到 VIP 所在网段的路由,从部署机探测会把"路由不通"误判成"VIP 未就绪"。
> 仓库内已有现成的"登录首个 master 做核对"的写法可复用:
> `07_k8s_scale.sh` 的 `_query_cluster_nodes()`。

**关键护栏(硬拦停, 不是提示)**: 阶段二在**探测到 VIP 未 bound** 时**绝不执行**。
切换一个解析不到的地址 = 集群立即失联,这条必须是 fail-closed。
(注: 这与仓库既有的"默认全量运行 = 覆盖安装"语义一致 —— 覆盖安装本身是被允许的,
但"把 API 入口指向一个不存在的地址"不是覆盖安装,是自毁。)

### 7.3 阶段二的显式确认

阶段二只在**同时满足**「VIP 已 bound」+「用户显式确认」时执行。确认方式复用
`02_k8s/06_k8s_deploy.sh` 已有的 **30 秒倒计时**机制(memory 记录: "sleep 30 倒计时供
人工确认/修改"),倒计时期间 Ctrl-C 可中止,走完即视为确认。

这样既满足 D2 的"存量需显式重跑才切",也不会因为一次无关的全量重跑而意外触发切换。

### 7.4 回滚

| 场景 | 操作 |
|---|---|
| 阶段一后想放弃 | `KUBE_VIP_ENABLED=false` 重跑(删 static pod manifest,控制平面零影响) |
| 阶段二后想回退 | `loadbalancer_apiserver.address` 改回 master01 重跑;紧急时直接在任一 master 上把 `/etc/hosts` 的域名指回 master01(立即恢复,后续运行收敛) |

---

## 8. 离线资产

| 项 | 内容 |
|---|---|
| 镜像 | `ghcr.io/kube-vip/kube-vip:v0.8.9`(kubespray `download.yml:284-285`) |
| 登记 | `deployments/config/images.manifest` 新增条目 → CI 同步至 Harbor `mirrors` |
| tar | `deployments/offline-files/kubespray/` |
| **预加载** | ⚠ 必须进 `patch-playbooks/cubestack-preload.yml` 的预加载集,否则首装时 master 拉不到镜像 → kube-vip 起不来 → `kubeadm init` 失败 |

因 D4 选择 `lb_fwdmethod: local`(kubespray 默认),**不需要** `kube-vip-iptables`
变体镜像 —— 只多一个镜像,不是两个。

---

## 9. 校验与验证

### 9.1 `check-modules.sh` 新增第 ⑪ 项(静态)

`KUBE_VIP_ENABLED=true` 时断言:
- inventory 中 `kube_vip_address` == `loadbalancer_apiserver.address`
- `k8s_cluster.yml` 中 `kube_vip_services_enabled` 为 false(D1 边界不被误改)
- `K8S_API_VIP` 不在 `METALLB_POOL` 区间内

### 9.2 新增 `02_k8s/08_verify_kube_vip.sh`

> 放 `02_k8s/` 而非 `03_addon/` —— 它验的是集群基座,不是 addon。
> 模块发现机制(`lib-module.sh:133`)按 `[0-9][0-9]_*/[0-9][0-9]_*.sh` 通配,任意阶段目录均可。

| # | 检查 | 目的 |
|---|---|---|
| ① | 各 master 上 kube-vip static pod 存在且 Running | 基本存活 |
| ② | VIP 绑在**恰好一个**节点上 | 防脑裂(两个 leader 同时持 VIP) |
| ③ | `curl -k https://<VIP>:6443/healthz` | 端到端可达 |
| ④ | VIP 所在网卡 == 承载该节点主 IP 的网卡 | 把"kube-vip 自动检测选错网卡"从**静默问题**变成**可检测问题** |
| ⑤ | `kubectl get endpointslice kubernetes -n default` 非单点 | 验证第 2.5 节修复 |
| ⑥ | **VIP 漂移演练** | 见下 |

**⑥ 漂移演练(D6: 默认执行)**: 在 leader 节点移走 kube-vip manifest → 等租约过期
(默认 `leaseduration: 5` / `renewDeadline: 3` / `retryPeriod: 1`,故约 5-10s)→
断言 VIP 漂移到另一节点且 API 仍可达 → **恢复原 manifest**。

**必须输出实测切换耗时(秒)**,而不只是通过/失败 —— 第 2.4 节的退步幅度只有实测才知道,
这个数字是后续判断"要不要调租约 / 要不要开 `cp_detect`"的唯一依据。

护栏: 要求 ≥3 master;演练前打印醒目提示;**先记录原 manifest 保证自动恢复**
(即使脚本被中断也留可手工恢复的副本);演练失败时的处置写进输出。

---

## 10. 模块关系与已知缺口

### 10.1 与既有 LB 模块的关系

`01_env/05_lb_haproxy.sh` + `06_lb_keepalived.sh` **保留**,定位改为"外部 LB + VIP"
用户的可选路径,与 kube-vip 二选一(由 5.2 第 1 条硬失败规则保证)。

⚠ 顺带指出: `06_lb_keepalived.sh` 目前是**假 HA** —— `state MASTER` 写死、
`virtual_router_id 51` 写死、只配置单实例,本质是"单机 VIP"而非高可用。
**本方案明确不改动其逻辑**(修成真 VRRP 集群是独立议题,不在范围内),但需在配置注释中
标注清楚,避免误用。

### 10.2 已知缺口(不修,记录在案)

`playbooks/scale.yml` 中 `kubernetes/node` role 为 `hosts: kube_node`,而本仓库
`kube_node` 组**不含 master**(见 `inventory.ini`:`[kube_node]` 只有两个 worker)。
因此经 `07_k8s_scale.sh` 扩容**不会**给新 master 装 kube-vip。

**当前无实际影响** —— `07_k8s_scale.sh` 本身就只扩 worker(其自动检测逻辑只 diff
worker 角色),masters 只能通过全量 `k8s_deploy` 加入,而全量运行会覆盖全部 role。

**但这是一个必须先补的洞**: 若将来支持经 scale 增加 master,新 master 不会参与 VIP 选举,
极端情况下(新 master 为最后存活节点)将丢失 API 入口。

---

## 11. 风险登记

| # | 风险 | 严重度 | 处置 |
|---|------|--------|------|
| R1 | kubespray 上游对 kube-vip **零 CI 覆盖**(`grep -rn "kube_vip\|kube-vip" test-infra/ tests/` → 零命中) | 高 | 实机验证不可省略;第 12 节第 0 步先证伪 |
| R2 | **bootstrap 时序链未经证实**: `kube-vip.manifest.j2:126-127` 的 hostPath **没有 `type: FileOrCreate`**(与 kube-vip 官方 bootstrap manifest 的差异),而首控制面节点在 `kubeadm init` 之前 `/etc/kubernetes/super-admin.conf` **不存在**("首个 CP + kubeadm 未运行" 时 kubespray 恰好选中该路径,见 `kube-vip.yml:26-31`)。整条链成立依赖 kube-vip 在拿不到 kubeconfig / 连不上 API 时仍按 bootstrap 逻辑抢到 VIP | 高 | 第 12 节第 0 步优先实机证伪。**失败模式是响亮的**(`kubeadm init` 直接报错),不是静默损坏 |
| R3 | 切换瞬间全节点 apiserver 重启 + 证书重签 | 中 | 两阶段(第 7 节)把风险隔离在阶段二,且有倒计时确认窗口 |
| R4 | kube-vip 自动检测选错网卡(多网卡节点) | 中 | 提供 `KUBE_VIP_INTERFACE` 显式覆盖;verify ④ 把它变成可检测问题 |
| R5 | ARP 模式的网络前提(交换机 ARP/ICMP 策略、DHCP snooping、DHCP 保留段) | 中 | `cluster.conf` 3.1 节已为 MetalLB 写明同类要求,可直接复用;VIP 必须排除在 DHCP 池外 |
| R6 | 云环境免费 ARP 不可用 | 低 | 本方案面向裸金属 / VM 集群。BGP 模式(kubespray 亦支持:`kube_vip_bgp_*`)**预留但不实现** |
| R7 | `lb_fwdmethod` 默认 `local` 下若误开 `lb_enable` | 低 | D4 明确关闭;check-modules 第 ⑪ 项不校验此项(非必要),由 verify ⑤ 间接覆盖 |

---

## 12. 实施清单

> **顺序原则: 先证伪,再铺开。** R1/R2 未澄清前不写生产代码。

```
第 0 步(SPIKE,必须先做)  ─────────────────────────────────────────
  在 VM 集群(非生产)上手动验证 bootstrap 时序链:
    · 手工启用 kube_vip_* + address=VIP, 从零跑一次 kubespray
    · 证伪点: kubeadm init 能否走完? kube-vip pod 是否真的起来并绑上 VIP?
    · 若失败 → 本方案退回"两阶段强制"(阶段一留 address=master01,
      让 VIP 先经全量运行立起来),设计不需推翻,只是第 0 步结论要写进本文档
  产出: 结论 + 失败时的原始报错

第 1 步  配置面      cluster.conf 三个变量 + 三条校验规则(5.1/5.2)
第 2 步  VIP 推导    lib-common.sh 新增推导函数(ICMP + 6443 双探; 与 METALLB_POOL 隔离)
第 3 步  核心改动    cubestack-offline.sh 改动 A(address 按阶段取值)
第 4 步  单点修复    cubestack-offline.sh 改动 B(advertise-address 按节点)⚠ 正则需同步改
第 5 步  两阶段      阶段判定 + fail-closed 护栏 + 30s 倒计时确认(第 7 节)
第 6 步  离线资产    镜像登记 + tar + preload 集(第 8 节)
第 7 步  静态校验    check-modules.sh 第 ⑪ 项
第 8 步  验证模块    02_k8s/08_verify_kube_vip.sh(六项含漂移演练)
第 9 步  文档        README / cluster.conf 注释 / 本文件状态更新
```

---

## 13. 实机验证清单(验收标准)

- [ ] **新建集群**: 两阶段跑通,阶段一后 `curl -k https://<VIP>:6443/healthz` 通,阶段二后全集群正常
- [ ] **存量集群**: 阶段一对现有业务零影响(对照切换前后的 `kubectl get nodes` / 工作负载状态)
- [ ] **漂移演练**: 停 leader 的 kube-vip 后 10s 内 VIP 漂移且 `kubectl` 不中断
- [ ] **单点修复**: `kubectl get endpointslice kubernetes -n default` 显示全部 master,非单条
- [ ] **网卡正确性**: verify ④ 通过(VIP 网卡 == 承载主 IP 的网卡)
- [ ] **幂等**: 连续两次全量运行无意外变更、无重复切换
- [ ] **回滚**: 按 7.4 节回滚到 master01 指向后集群恢复正常
- [ ] **离线**: 断网环境下首装能拉到 kube-vip 镜像(验证 preload 集)
- [ ] **互斥**: 同时开 `KUBE_VIP_ENABLED` + `KEEPALIVED_ENABLED` 时明确报错中止

---

## 14. 实施记录(2026-09-22)

代码已全部落地, `check-modules.sh`(48 模块 / 11 项)与 `check-image-manifest.sh` 全绿。
**尚未实机验证** —— 第 13 节清单仍待执行。

### 14.1 对原设计的 4 处修正

| # | 原设计 | 实际实现 | 依据 |
|---|--------|----------|------|
| 1 | kube_vip_* 写 `k8s-cluster.yml` | 写 **`addons.yml`** | `addons.yml:209` 有 kubespray 自带的 `# Kube VIP` 模板; `k8s-cluster.yml` 里没有 |
| 2 | 两阶段是"存量集群"的事 | **新建集群同样必需** | `0090-etchosts.yml` 在 preinstall 角色里, 而 kube-vip 在 `kubernetes/node`(etcd 之后)—— 差约一个 etcd 安装的时间。原设计假设"同一轮 run 内 VIP 先绑"不成立 |
| 3 | `advertise-address` 改 Jinja 表达式 | 同左, 但加了**整行字符串断言** | 写回具体 IP 会静默抵消修复; 用 `grep -qF` 断言整行, 已是目标值则完全不动 |
| 4 | 倒计时确认放 sync 脚本 | 移到 **`06_k8s_deploy.sh`** | `06_k8s_deploy.sh:70` 把 sync 的 stdout 重定向到 `/dev/null` —— 放 sync 里用户看不见提示, 还会白等 30 秒 |

### 14.2 实施中新发现的问题(原设计未覆盖)

- **两处脚本写同一份配置**: `sync-kubespray-config.sh` 与 `cubestack-offline.sh` 的
  `update_loadbalancer_all_yml()` **都会写** `loadbalancer_apiserver.address`。若只改一处,
  另一处会用不同的值把它顶掉(offline 在 kubespray 启动前还会再跑一次)。
  处置: 阶段判定只在 sync 里做(唯一权威), offline 改为**读取 all.yml 现值**。
- **`sync-kubespray-config.sh` 对 `_prot` 的防线**: 若 all.yml 的入口被手工改成非数值地址
  (域名/Jinja 表达式), 我方的 `sed` 只认 `[0-9.]+`, 不会覆盖它; 但为免意外, 加了 `nonnumeric_entry()`
  校验 —— 值不同则硬失败并要求人工确认。
- **kube-vip 变量落点的依赖方向**: `sync-kubespray-config.sh` 不 source lib-common 无法成立,
  故重写逻辑下沉到 `lib-common.sh` 的 `update_kube_vip_addons_yml()` / `update_advertise_address_yml()`,
  两个脚本共用同一份实现(避免再次出现"两处写同一份配置"的分叉)。
- **`check-modules.sh` 第 ⑪ 项的门禁口径**: 不能只看配置开关 —— `kube_vip_enabled` 是部署流程里
  才写的, 纯 checkout(CI)里它必然还是模板的 `false`, 判失败会让 CI 在干净仓库上必然挂。
  改为按仓库既有惯例"**看实际部署**": `.deploy.state` 有 `k8s_deploy=` 才做等值断言
  (该文件在 `.gitignore` 内, CI 上恒不存在 → 自动跳过)。

### 14.3 落地文件清单

| 文件 | 改动 |
|---|---|
| `deployments/config/cluster.conf` + `.example` | 新增 `KUBE_VIP_ENABLED` / `K8S_API_VIP` / `KUBE_VIP_INTERFACE` / `KUBE_VIP_VERSION`; preload 集合加 `kube-vip` |
| `deployments/scripts/lib-common.sh` | 新增 `metallb_pool_contains` / `all_node_ips` / `master_hosts` / `bool_is_true` / `kube_vip_validate_config` / `kube_vip_derive` / `kube_vip_current_entry` / `kube_vip_is_bound` / `kube_vip_resolve_target` / `nonnumeric_entry` / `update_kube_vip_addons_yml` / `update_advertise_address_yml` |
| `deployments/scripts/tools/k8s/sync-kubespray-config.sh` | 阶段判定入口; `address` 按阶段写; `advertise-address` 改幂等修复; addons.yml kube-vip 块同步 |
| `deployments/scripts/modules/02_k8s/06_k8s_deploy.sh` | 阶段二切换确认门(红底提示 + 30s 倒计时 + `KUBE_VIP_SWITCH_CONFIRMED`); 入口指向 VIP 但探测不到绑定时的失联告警 |
| `deployments/kubespray/cubestack-offline.sh` | 入口地址改为读 all.yml; `advertise-address` 同步改幂等修复; preload 默认集合加 `kube-vip` |
| `deployments/scripts/modules/02_k8s/08_verify_kube_vip.sh` | **新增** verify 模块(六项含漂移演练, 输出实测耗时) |
| `deployments/scripts/tools/check-modules.sh` | 新增第 ⑪ 项静态校验 |
| `deployments/scripts/tools/offline/trim-offline-files.sh` | preload 默认集合加 `kube-vip` |
| `deployments/config/images.manifest` | 登记 `ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}`(group `k8s-base`) |
| `deployments/offline-files/kubespray/README.md` | **新增**(说明 kube-vip 为何必须进预加载集) |

### 14.4 离线镜像:待执行的联网机动作

代码侧已完成登记, **制品尚未生成**:

```bash
# ① 推 GitHub main → GH Actions 自动把 kube-vip 同步到 Harbor mirrors/**(工作流已监听 images.manifest 变化)
# ② 联网机上从 Harbor 拉到离线目录(会自动命名 ghcr.io_kube-vip_kube-vip_v0.8.9.tar):
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group k8s-base
# ③ 校验(应显示 [已有]):
bash ./deployments/scripts/tools/images/harbor-save-images.sh --list --group k8s-base | grep kube-vip
```

> ⚠ 未完成这一步之前, **离线集群首装会失败**: kube-vip 在 `kubeadm init` 之前就要绑上 VIP,
> 拉不到镜像 → 静态 Pod 起不来 → `kubeadm init` 直接报错。失败模式是响亮的,不是静默损坏。

### 14.5 实机验证建议顺序

1. **先在存量集群跑一次**(`--steps k8s_deploy`)—— 观察是否停在**阶段一**(入口仍指 master01, 零影响)
2. 跑 `--steps verify_kube_vip` —— ①~⑤ 应通过; ⑥ 漂移演练会实测切换耗时并输出数字
3. 若 ⑥ 通过, 再跑一次 `--steps k8s_deploy` —— 这次应弹出**阶段二切换确认**(红底 + 30s 倒计时)
4. 切换后再跑 `--steps verify_kube_vip` —— ⑤ 应显示 EndpointSlice 含全部 master
5. 全程关注第 11 节 R1/R2 两个风险项的实际表现
