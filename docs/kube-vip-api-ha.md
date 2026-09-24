# Kubernetes API Server 高可用(kube-vip VIP)设计方案

> 状态: **已实施 + 已实机验收**(2026-09-22)—— 代码落地、`check-modules` 全绿,
> **裸金属 3 master 集群上 `--steps kube_vip` 与 `--steps verify_kube_vip` 六项全过**(见第 17 节)
> 涉及模块: `02_k8s/09_kube_vip.sh`(部署)· `02_k8s/08_verify_kube_vip.sh`(验证)· `02_k8s/06_k8s_deploy.sh`(阶段确认门)
> 开关: `KUBE_VIP_ENABLED`(**默认 false**, 2026-09-24 由默认开改为默认关)· 配置项 `K8S_API_VIP` / `KUBE_VIP_INTERFACE` / `KUBE_VIP_CP_DETECT`(**默认 false**, 2026-09-24 由默认开改为默认关) / `KUBE_VIP_LOCAL_PROXY`
> 上游资产: kubespray 原生支持(`deployments/kubespray/kubespray/`), 无需自研
>
> **❗ 实施过程中对本文档的 4 处修正**(详见第 14 节, 读下文时以此为准):
> 1. kube_vip_* 变量写入 **`addons.yml`**, 不是 `k8s-cluster.yml`(那里没这个块, `addons.yml` 有 kubespray 自带模板)
> 2. 两阶段**对新建集群同样必需** —— `/etc/hosts` 写在 preinstall 角色, kube-vip 在 etcd 之后, 差约 10 分钟
> 3. `advertise-address` 必须写成 **Jinja 表达式**(按节点取值), 写回具体 IP 会抵消修复
> 4. 切换确认的倒计时放在 **`06_k8s_deploy.sh`**, 不能放 sync 脚本(其 stdout 被重定向到 /dev/null)
>
> **⚠ 实机验收推翻的两处预估**(详见第 17.3 节):
> - 漂移实测 **1–2 秒**,不是预估的 5–10 秒(kube-vip 退出时主动释放租约,不必等租约过期)
> - ② 判定 VIP 持有者**不能用 `ip route get`**(同网段下对所有节点都返回 local),须用 `ip -o addr show`

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
  `kube_vip_cp_detect=true`(kubespray 与本项目的默认都是 `false`,★ 2026-09-24 起)——
  它按本地 apiserver 健康状态判定,不必等租约到期。**先测后调,不预先启用。**

### 2.5 集群内 `kubernetes` Service 也是单点

`cubestack-offline.sh:1364-1372` 把 `kube_apiserver_extra_args.advertise-address`
**统一写成第一个 master IP**,三个 master 的 apiserver 于是都对外宣告 master01 的地址
→ `kubernetes` Service 的 EndpointSlice 只有一条 → 集群内经 Service 访问 API 同样单点。

这一处**独立于 kube-vip**,即使引入了 VIP 也不会自动被修掉。

---

## 3. 关键认知纠偏:静态 Pod,不是 DaemonSet

参考资料中常见的 `kube-vip manifest daemonset` 用法**不适用于本场景**,原因是启动顺序。
但下面这张图里有**两条独立的时序事实**,2026-09-22 的单一写入者改造之后必须分开看:

```
playbooks/cluster.yml
├─ Install Kubernetes nodes   →  roles/kubernetes/node
│                                └─ :145 import kubelet.yml → 装并 enable kubelet
└─ Install the control plane  →  kubeadm init
                                 controlPlaneEndpoint = loadbalancer_apiserver.address
                                 (阶段一 = master01; 阶段二 = VIP —— 见第 7 节)
```

**事实一(已不适用):** kubespray 原方案在 `roles/kubernetes/node`(`node/tasks/main.yml:19`)
里于 `kubeadm init` **之前**就写 kube-vip 的 static pod manifest,即让 VIP 在 init 之前绑上。
**本项目不走这条路径** —— 静态 Pod 现由 `02_k8s/09_kube_vip.sh` 在**集群就绪之后**落位
(单一写入者,见第 18 节),kubespray 侧恒 `kube_vip_enabled: false`。而且两阶段设计里
阶段一的 `controlPlaneEndpoint` 就是 master01,本来也不依赖 VIP 先绑上。
⇒ 第 11 节 **R2 那条"未经证实的 bootstrap 时序链"随之消失**,不再有任何东西在 init 之前依赖 VIP。

**事实二(仍然成立):** DaemonSet 模式不能用 —— 它需要 API Server 才能被创建,而
API Server 又需要 VIP 才能起来,**是死锁**。本模块走的是"静态 Pod 落盘 → kubelet 拉起",
只是落盘时机在集群就绪之后,不改变"必须是静态 Pod"这个结论。

DaemonSet 只适用于"集群已存在,事后补服务 LoadBalancer"的场景;而服务 LB 我们已经有
MetalLB 在做(见第 4 节决策 D1)。

---

## 4. 设计决策(已确认)

| # | 决策 | 取值 | 理由 |
|---|------|------|------|
| D1 | 职责边界 | **只做控制平面 VIP**;`kube_vip_services_enabled: false` | MetalLB 已承载 registry / ingress / EG 的 LoadBalancer VIP 且实机验证充分。两者分工会互相抢 LoadBalancer 分配权 |
| D2 | 启用策略 | **默认关闭**;需要时显式开启(存量集群还需显式重跑才切换) | ~~原为默认开启~~ —— 2026-09-24 改为默认关: 本项目的实际用法停在"阶段一"(VIP 上无流量、入口仍是首个 master), 默认开只是让每次部署多跑一遍昂贵且可能硬失败的 VIP 推导。开/关双向都有护栏与清盘路径, 见第 18 节 |
| D3 | VIP 来源 | **自动推导 + 可显式覆盖** | 零配置可跑通;多集群共用网段时用 `K8S_API_VIP` 覆盖 |
| D4 | 转发模式 | **纯故障切换**;`kube_vip_lb_enable: false` | ① `kube_vip_lb_fwdmethod` 的默认值 `local` 在内核里是 `ip_vs_null_xmit`(**不转发**),配了也没有任何负载均衡 —— 它只是让后端"登记上了";要真 LB 必须用 `masquerade`。② `masquerade` 有四个额外前提: privileged 容器 + `kube-vip-iptables` 镜像变体进离线资产 + kube-proxy `ipvs.excludeCIDRs` 与本项目**自动推导**的 VIP 长期保持一致 + 改宿主机 sysctl。第③条破坏"单一配置源":VIP 漂移后忘了同步排除段即**静默失效**。收益(API 请求三分摊)不足以抵消这些长期维护成本。详见 `docs/troubleshooting.md` 三.11 |
| D5 | 新集群路径 | **两阶段**(与存量集群同一套机制) | 用一次额外运行换掉第 7 节风险 R2 整条时序不确定性 |
| D6 | 故障演练 | **verify 默认执行**,带自动恢复 | 漂移能力是这个方案唯一的核心价值,不实测等于没验证 |
| D7 | 文档位置 | `docs/kube-vip-api-ha.md` | 与本仓库既有约定一致 |

---

## 5. 配置面

### 5.1 `deployments/config/cluster.conf` 新增(阶段二 k8s 区块)

```bash
KUBE_VIP_ENABLED="${KUBE_VIP_ENABLED:-false}"     # API Server VIP 高可用(kubespray 原生 kube-vip 静态 Pod)
                                                  #   ⚠ 默认**关**(2026-09-24 起); 要实现 API 入口高可用需显式置 true
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

> **2026-09-23 补充 —— 部署侧写域名的几个地方也收敛了。** 上面讲的是 kubespray 侧。部署框架
> 自己还有若干处会写 `k8s-api.cubestack.io` 的解析(`03_k8s_hosts`、`07_k8s_scale` 推给新节点、
> `tools/node/sync-hosts.sh`、`tools/node/prepare-workers.sh`、`tools/lb/setup-api-expose.sh`、
> `06_gpu_operator`、`07_gpu_lws`),原先是**一律写第一个 master** —— 与 kubespray 阶段二写入的
> VIP **互相打架**(谁后跑谁生效),典型表现是"kube-vip 装好了,域名却还指着单台 master"。
>
> 现统一收敛到 `lib-common.sh` 的 **`api_entry_ip()`**: **VIP 已绑 → VIP,否则第一个 master**。
>
> ⚠ **判据是"VIP 已绑",不等于阶段二的人工确认。** 也就是说 VIP 一绑上,部署侧写的域名就会切到
> VIP,而 kubespray 侧(`loadbalancer_apiserver.address`)仍要等 `KUBE_VIP_SWITCH_CONFIRMED=1`。
> 在"已绑但未确认"这个窗口里两边**不一致**:此刻 VIP 确实在服务,部署侧先切不影响可用性,但
> 若希望两边严格同步,就别在那个窗口里跑 `03_k8s_hosts`(`UPDATE_ETC_HOSTS=0`,默认即不跑)。
>
> ⚠ **`API_IP` 与 `API_ENTRY_IP` 不可互换。** `API_IP` 是"能通 NodePort 的**节点** IP":
> registry 的 containerd mirror 用 `http://${API_IP}:${REGISTRY_NODEPORT}`、`setup-api-expose`
> 的 DNAT 判定也依赖它。VIP **不代理 NodePort**,改成 VIP 会让扩容的新节点拉不到镜像;
> DNAT 分支还会给 VIP 装一条打回 master01 的规则,把高可用废掉。

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
kube_vip_enabled: false                   # ★ 恒为 false, **与 KUBE_VIP_ENABLED 无关** ——
                                          #   含义是"不要让 kubespray 写这个静态 Pod";
                                          #   静态 Pod 由 02_k8s/09_kube_vip.sh 独占(第 18 节)
kube_vip_address: "10.244.1.210"          # 恒为 VIP(静态 Pod 的 args.address + 证书 SAN);
                                          # 开关关闭时**也保留** → 重新开启不必重签证书
kube_vip_arp_enabled: true
kube_vip_controlplane_enabled: true
kube_vip_cp_detect: false                 # 见第 15 节(★ 2026-09-24 起默认关 = kubespray 行为; 置 true 可启用进程级检测)
kube_vip_services_enabled: false          # D1: 服务 LB 归 MetalLB
kube_vip_lb_enable: false                 # D4: 纯故障切换
kube_vip_interface: ens5                  # 仅当 cluster.conf 显式指定时写入
```

> ⚠ `kube_vip_enabled: false` 下面这一组键在当前状态下**全部不生效**(kubespray 的 kube-vip
> 任务整个被跳过)。保留它们是逃生口: 万一手工把开关翻回 true,kubespray 渲染出来的仍是这套
> 策略(ARP + 控制面 + cp_detect + 不开服务 LB),而不是一份 `vip_arp` 全关的坏 manifest。

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

> ★ **2026-09-24 修复(这道护栏原先根本没生效)**: 阶段是由 `kube_vip_resolve_target()` 判定的,
> 而它总被写成 `addr="$(kube_vip_resolve_target)"` —— **命令替换是子 shell**, 函数里
> `API_ENTRY_PHASE=` 的赋值**回不到调用方**。于是 `sync-kubespray-config.sh` 里
> 「阶段=2 且未确认 → 降级回阶段一」这条 fail-closed 护栏**永不成立**, 阶段二会被直接写进
> `all.yml`(地址是 VIP), 而提示永远打印"阶段一"。
> 现在: 函数每次判定都把阶段落盘(`$API_ENTRY_PHASE_FILE`), 调用方一律
> `phase="$(api_entry_phase)"` 回读; 护栏也移到"判定之后"再跑。回归用例见
> `tools/tests/ceph-disk-tests.sh` H 组(含反证: 换回读旧全局即判红)。

### 7.4 回滚

| 场景 | 操作 |
|---|---|
| 阶段一后想放弃 | `KUBE_VIP_ENABLED=false` 重跑 → `09_kube_vip` 走**关闭态清理**:逐台删 static pod manifest,并校验"无容器 + VIP 已从网卡释放"。控制平面零影响(见第 18 节) |
| 阶段二后想回退 | **两步,顺序不能反**:① 先把 `loadbalancer_apiserver.address` 改回 master01 重跑(入口退回 master01);② 再关开关清理。反了会被护栏拦停 —— 入口还指着 VIP 时删 kube-vip = **全集群 API 立刻失联** |

> ⚠ **"阶段一后想放弃"这条在 2026-09-22 之前是空头承诺。** 当时模块是
> `DEFAULT: 0` + `TOGGLE: KUBE_VIP_ENABLED`,而模块框架的规则是"带 TOGGLE 的模块在开关为
> false 时**不进 RUN_STEPS**" —— 于是开关一关,脚本连启动都没有,manifest 留在原地、
> kube-vip 照跑、VIP 照被持有、还继续参与选举。现改为 `DEFAULT: 1`(常驻全量运行)+ 模块内部
> 按开关分派到"安装/清理",这条承诺才真正成立。详见第 18 节。

---

## 8. 离线资产

| 项 | 内容 |
|---|---|
| 镜像 | `ghcr.io/kube-vip/kube-vip:v0.8.9`(kubespray `download.yml:284-285`) |
| 登记 | `deployments/config/images.manifest` 新增条目 → CI 同步至 Harbor `mirrors` |
| tar | `deployments/offline-files/kubespray/` |
| **预加载** | ⚠ 必须进 `PRELOAD_IMAGE_PATTERNS`(默认集合已含 `kube-vip`),否则预加载会把它裁掉 → `09_kube_vip` 的前置自检以"以下 master 上缺少 kube-vip 镜像"**硬失败**。失败模式是响亮的,不是静默降级 |

因 D4 选择 `lb_fwdmethod: local`(kubespray 默认),**不需要** `kube-vip-iptables`
变体镜像 —— 只多一个镜像,不是两个。

> ⚠ 但这条"省一个镜像"的性质要看清: `local` 省下镜像的代价是**开不出负载均衡**
> (内核里 `local` = `ip_vs_null_xmit`,不转发)。所以本项目实际是"选了不开 LB",
> 而不是"用一个更省的姿势开了 LB"。若将来要开,`kube-vip-iptables:v${KUBE_VIP_VERSION}`
> 必须同时进 `images.manifest` + `PRELOAD_IMAGE_PATTERNS`(见 `docs/troubleshooting.md` 三.11)。

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
| ~~R2~~ | ~~**bootstrap 时序链未经证实**: `kube-vip.manifest.j2:126-127` 的 hostPath **没有 `type: FileOrCreate`**,而首控制面节点在 `kubeadm init` 之前 `/etc/kubernetes/super-admin.conf` **不存在**(kubespray 对首个 CP 恰好选中该路径,见 `kube-vip.yml:26-31`)。整条链依赖 kube-vip 在拿不到 kubeconfig 时仍抢到 VIP~~ **→ 已消除(2026-09-22)** | ~~高~~ 无 | 单一写入者改造关掉了 kubespray 那次写入(见第 18 节): 不再有任何东西在 `kubeadm init` **之前**写 manifest,也就不再有任何东西在 init 之前需要 VIP。原描述保留以便对照 —— hostPath 确实没有 `FileOrCreate`,但该路径已不再被走到 |
| R3 | 切换瞬间全节点 apiserver 重启 + 证书重签 | 中 | 两阶段(第 7 节)把风险隔离在阶段二,且有倒计时确认窗口 |
| R4 | kube-vip 自动检测选错网卡(多网卡节点) | 中 | 提供 `KUBE_VIP_INTERFACE` 显式覆盖;verify ④ 把它变成可检测问题 |
| R5 | ARP 模式的网络前提(交换机 ARP/ICMP 策略、DHCP snooping、DHCP 保留段) | 中 | `cluster.conf` 3.1 节已为 MetalLB 写明同类要求,可直接复用;VIP 必须排除在 DHCP 池外 |
| R6 | 云环境免费 ARP 不可用 | 低 | 本方案面向裸金属 / VM 集群。BGP 模式(kubespray 亦支持:`kube_vip_bgp_*`)**预留但不实现** |
| R7 | `lb_fwdmethod` 默认 `local` 下若误开 `lb_enable` | 低(**静默无效**,非致瘫) | 已定性(2026-09-22): 内核里 `local` = `ip_vs_null_xmit` → **零负载均衡且不报错**,`verify_kube_vip` 六项照样全绿;ipvs 模式集群上还会被 kube-proxy 30s 内删掉。D4 明确关闭,check-modules 第 ⑪ 项不校验此项(非必要)。**若要动 `lb_enable`,先读 `docs/troubleshooting.md` 三.11** |

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

> ⚠ 未完成这一步之前,`--steps kube_vip` 会**硬失败**("以下 master 上缺少 kube-vip 镜像"),
> 于是 VIP 不会就位。**它不会再导致 `kubeadm init` 失败** —— 那句话属于"kubespray 在 init
> 之前写 manifest"的旧路径,该路径已在 2026-09-22 关闭(见第 18 节)。

### 14.5 实机验证建议顺序

1. **先在存量集群跑一次**(`--steps k8s_deploy`)—— 观察是否停在**阶段一**(入口仍指 master01, 零影响)
2. 跑 `--steps verify_kube_vip` —— ①~⑤ 应通过; ⑥ 漂移演练会实测切换耗时并输出数字
3. 若 ⑥ 通过, 再跑一次 `--steps k8s_deploy` —— 这次应弹出**阶段二切换确认**(红底 + 30s 倒计时)
4. 切换后再跑 `--steps verify_kube_vip` —— ⑤ 应显示 EndpointSlice 含全部 master
5. 全程关注第 11 节 R1/R2 两个风险项的实际表现

---

## 15. cp_detect:apiserver 进程级故障检测(2026-09-22 增补)

### 15.1 它解决什么

`kube_vip_cp_detect`(kubespray 默认 **false**;本项目 **2026-09-24 起同样是默认 false**,需要时显式开启)开启后,kube-vip 探测**本机
apiserver 的 `/healthz`**;探失败即把自身健康置为假 → 不再续租 → 约 `leaseduration`(5s)后
VIP 漂走。

**没有它时漏掉的场景**:节点活着、kubelet 正常、网络正常,但 **apiserver 进程死掉/卡死**。
这时租约照常续(续租看的是进程存活,不是 apiserver 健康),VIP 永远不漂 —— 外部客户端会
一直打到一个没有 API 的地址。整机宕机反而没问题(续租自然中断)。

真实运维中"节点活着但 apiserver 死了"比整机宕机更常见(OOM、证书过期、etcd 抖动、盘满),
所以这是**值得开启**的能力;但**默认关闭**(见 15.2),需要时显式开。

### 15.2 代价与调参

- 探针是 **HTTP `/healthz`**,比 TCP 连通更严格 → 短时抖动可能触发一次不必要的 VIP 迁移。
  迁移本身只影响 ARP 通告(约 5s),不会重签证书,所以代价可控。
- **默认就是 kubespray 的行为**(`KUBE_VIP_CP_DETECT=false`,★ 2026-09-24 由默认开改为默认关);
  想启用进程级检测: `KUBE_VIP_CP_DETECT=true`(开启后也仍是"探测置假 → 等租约到期"的串联链路)。
- 与租约参数的关系: 两者**串联** —— 探测置假 → 停续租 → 等 `leaseduration` 到期 → 漂移。
  所以端到端仍是 5s 量级,不会更快;它的价值是**补上"永远不会漂"这个洞**,而不是提速。

### 15.3 落地

- 配置面: `cluster.conf` 的 `KUBE_VIP_CP_DETECT`(**默认 false**,★ 2026-09-24 由默认开改为默认关)
- 写入: `lib-common.sh#update_kube_vip_addons_yml()` → `addons.yml` 的 `kube_vip_cp_detect`
- 上游接线: `roles/kubernetes/node/templates/manifests/kube-vip.manifest.j2:44-45`
  (`{% if kube_vip_controlplane_enabled %}` 块内的 `cp_detect` env)

---

## 16. kubespray 原生本地代理(nginx-proxy):调查结论与实测

### 16.1 结论先行:只改开关是**假修复**

kubespray 的 `kube_apiserver_endpoint`(`kubespray_defaults/defaults/main/main.yml:643`)
是一条**优先级 if 链**:

```jinja
{% if loadbalancer_apiserver is defined %}          ← 最高优先, 外部 LB 永远赢
    https://{{ apiserver_loadbalancer_domain_name }}:{{ port }}
{% elif ('kube_control_plane' not in group_names) and loadbalancer_apiserver_localhost %}
    https://localhost:{{ port }}                     ← kubelet 走本地代理的**唯一**出口
{% elif 'kube_control_plane' in group_names %}
    https://127.0.0.1:{{ kube_apiserver_port }}      ← 控制面走自己的 apiserver
{% else %}
    https://{{ first_kube_control_plane_address }}:{{ port }}
{% endif %}
```

**只要 all.yml 里还定义着 `loadbalancer_apiserver`(本项目为 kube-vip 提供对外入口而必须保留),
第二个分支永远进不去** —— kubelet 始终打 `<域名>:6443`。

而 `loadbalancer_apiserver_localhost` 同时控制**两件事**:

| 它控制 | 位置 |
|---|---|
| 是否安装 nginx-proxy 静态 Pod | `roles/kubernetes/node/tasks/main.yml` 安装条件 |
| kubelet 的 API 端点是否为 localhost | 上面 if 链的第二个分支 |

所以"把 `loadbalancer_apiserver_localhost` 设成 true"会让 **nginx-proxy 装上、但没有任何流量经过它** ——
多了一个静态 Pod 和一个 8081 监听,收益为零。这是最容易踩的坑,已做成**硬失败护栏**
(`lib-common.sh#kube_vip_validate_config()` 第 ⑤ 条),不会静默无效。

**真正启用需要二选一**(都是拓扑变更,不是改开关):

- **路线1(推荐)**:保留 `loadbalancer_apiserver`(域名/VIP 对外入口不动),另外显式把
  kubelet 的端点声明为 localhost。kubespray 的模板没给这个开关 —— 需要改模板或
  post-task 覆盖 `kubelet.conf` 的 `server:` 字段。
- **路线2**:摘掉 all.yml 的 `loadbalancer_apiserver` 块,全集群改用本地代理。
  代价:kube-vip 失去意义(它存在的理由是给外部/跨系统一个稳定入口),对外入口也没了。
  **只有当"不需要对外稳定 API 入口"时才成立** —— 与本方案的目标直接冲突,故不采用。

### 16.2 实测(2026-09-22, bare-metal 集群 mxgpu-1-147/152/154 + worker 165)

**测法**:在 worker 165 上用 kubespray 同款 nginx 配置(`least_conn` + `proxy_connect_timeout 1s`)
起一个本地代理,upstream 里放入**黑洞地址**模拟已死的 apiserver,完全不触碰集群节点。
镜像用的是节点上现成的 `docker.io/library/nginx:1.27.4-alpine`。

| 场景 | 结果 |
|---|---|
| **成功路径**(3 后端全健康, 经本地代理) | 稳定 **~4.4ms**,与直连无差异 |
| **1/3 后端为黑洞** | **30/30 成功**,全部 ~4.4ms,无任何请求失败 |
| **2/3 后端为黑洞**(只有 1 台健康) | **20/20 成功**;**19 次 ~4.4ms,1 次 1.0045s** |

**关键结论**:

1. 一个 TCP 连接只绑一个 upstream —— 失败的连接会在 `proxy_connect_timeout 1s` 到期后
   **换一个 upstream** 重建(stream 模块的连接级重试;注意这不是 HTTP 的
   `proxy_next_upstream`,该指令不适用于 stream 模块)。所以**只要还有一台健康 master,
   客户端零失败**,代价是最坏慢 1s。
2. 最坏单次延迟 = `proxy_connect_timeout` = **1s**(不是失败,是慢 1s)。
   命中死后端的概率 ≈ 死后端占比,所以 3 master 挂 2 台时约 1/3 请求慢 1s。
3. nginx 对刚失败过的后端会**临时标记并优先选健康的**(`max_fails`/`fail_timeout` 机制),
   故实际触发 1s 惩罚的频率低于理论占比。

**已知短板(与 haproxy 的关键差异)**:kubespray 的 nginx-proxy 配置里**没有任何健康检查**
(`proxy_connect_timeout 1s` 是连接超时,不是健康检查;模板里那个
`loadbalancer_apiserver_healthcheck_port: 8081` 是给**上游 LB 探 nginx 自己**用的,
不是 nginx 探 apiserver)。后果:

- **已建立的连接**在后端静默死亡时不会被立刻感知,会等到 `proxy_timeout`(kubespray 配的是 **10m**)。
  对 kubelet 的 watch 长连接意味着最长 10 分钟才重连。
- 对比 haproxy 的 `option tcp-check` + `default-server inter 10s fall 2 rise 3` 是**主动**健康检查,
  能提前把死后端踢出。

### 16.3 为什么本项目仍不启用本地代理

| | 本地代理(kubespray nginx-proxy) | kube-vip VIP |
|---|---|---|
| 覆盖 | **仅**"节点 → API"(集群内) | 集群内 + 外部 + `controlPlaneEndpoint` |
| 故障切换 | 新连接 **~1s**(连接超时后同请求转投) | 租约到期,**约 5s**(与 `cp_detect` 串联) |
| 已建立连接 | 要等 `proxy_timeout`(**10m**) | 同(VIP 漂移不影响已建立连接) |
| 感知 apiserver 进程死 | 新连接能(连接失败);旧连接不能 | 需 `cp_detect`(`KUBE_VIP_CP_DETECT=true`; ★ 2026-09-24 起默认关) |
| 是否需改拓扑 | **是**(见 16.1 的 if 链冲突) | 否(kubespray 原生变量) |
| 外部稳定入口 | ❌ 不提供 | ✅ 提供 |

**两者不互斥,是叠加的两个层面**:kube-vip 给全集群/外部一个稳定入口,本地代理给每个节点
一个快速失败的就近出口。理论上可以都要(路线1)。

**暂不启用的理由**:路线1 需要改 kubespray 模板或 post-task 覆写 kubelet.conf,属于签名外的
改动,且收益(worker 侧从"约 5s 随 VIP 漂移"变成"约 1s 换后端")与新增的故障面相比不划算;
kube-vip 的 `cp_detect` 能把"apiserver 进程死"这个最危险的场景补上(`KUBE_VIP_CP_DETECT=true`
时; ★ 2026-09-24 起默认关,需要时显式开,见第 15 节)。
**若将来实测发现 VIP 漂移的 5s 对 worker 负载影响过大,再按路线1 引入。**

### 16.4 回答"kubelet 默认访问哪个 apiserver"

由上面那条 if 链决定,**本项目当前**(`loadbalancer_apiserver` 已定义)是:

```
kubelet → https://k8s-api.cubestack.io:6443 → /etc/hosts → loadbalancer_apiserver.address
```

阶段一 = **第一个 master**;阶段二(切换后) = **VIP**。

- **worker**:经上面这条链 → 单点(阶段一)或 VIP(阶段二)
- **control plane 自身**:`kubeadm` 生成的 `kubelet.conf` 里 `server:` 也被 kubespray 的
  `kubeadm-fix-apiserver.yml` / `kubeadm/tasks/main.yml:102` 改写成同一个
  `kube_apiserver_endpoint` —— **所以控制面节点也走同一个地址**,而不是自己的本地 apiserver。
  这点与直觉相反,值得注意:master02/03 的 kubelet 也是打 master01(阶段一)。

验证命令(任一节点): `sudo grep -m1 'server:' /etc/kubernetes/kubelet.conf`

### 16.5 本地代理安装位置与镜像

- **位置**:静态 Pod manifest `/etc/kubernetes/manifests/nginx-proxy.yml`,
  配置 `/etc/nginx/nginx.conf`(由 `nginx.conf.j2` 渲染)
- **镜像**:不在 `images.manifest` 里 —— 它是 kubespray 自己的**二进制**资产
  (`roles/kubespray_defaults/defaults/main/download.yml` 的 `nginx_image_repo`),
  随 kubespray 离线包分发,由 `resolve_preload_image_files()` 负责加载。
  **若将来启用本地代理,需确认该镜像已在离线预加载集合内**,否则 nginx-proxy 起不来。
- **客户端证书**:本地代理是纯 TCP 转发(`stream` 模块),**不终止 TLS**,所以证书 SAN 不受影响。

---

## 17. 固化模块与实机验收(2026-09-22 晚)

### 17.1 与 kubespray 的关系:固化,但不重跑 kubespray

新增 `02_k8s/09_kube_vip.sh`(MODULE `kube_vip`, `REPEAT: 1`),把原先的临时脚本固化为标准模块。
**它不声明 `REQUIRES: k8s_deploy`** —— 否则 `--steps kube_vip` 会连带拉起整套 kubespray。
取而代之是**四项前置自检**(集群可达 / 各 master 有镜像 / 模板与渲染器存在 / python3 可用),
任一不满足即明确报错并给出修法。

- **渲染**:不手抄 manifest,直接渲染 kubespray 原版
  `roles/kubernetes/node/templates/manifests/kube-vip.manifest.j2`。
  由 `tools/k8s/render-kube-vip-manifest.py`(python3 + jinja2)完成。
  ⚠ 2026-09-22 用**真正的 ansible `template` 模块**重新核对了这里"逐字节一致"的说法,结论要加限定:
  **非首台 CP 逐字节一致;首台 CP 差一行** —— kubespray 对首台 CP 会把 hostPath 渲染成
  `super-admin.conf`(`loadbalancer/kube-vip.yml:26-31` 的 set_fact),而我们的渲染器恒用
  `admin.conf`。复现方法见第 18.3 节。**这一行之差就是"两个写入者"问题的全部内容。**
- **等幂等**:目标状态 =「各 master 都有正确的 manifest + VIP 恰好绑一台」。
  按 manifest 的 sha256 与节点现状比对,一致则跳过(实测两次连跑全部跳过)。
- **脑裂守卫**:逐台按各自 hostname 渲染,并在渲染后**立即断言** `vip_nodename` 与
  `address` 正确,不符则中止 —— 见 17.2。

### 17.2 ⚠ 脑裂事故与根因(必读)

实测中**真的踩到了脑裂**:三台 master **同时**绑定了同一个 VIP。根因是渲染时
`inventory_hostname` 被统一成了 `localhost`:

```jinja
- name: vip_nodename
  value: {{ inventory_hostname }}     # ← 每台必须不同!它是租约 election 的节点标识
```

三台 kube-vip 的 `vip_nodename` 相同 → 抢同一个 `plndr-cp-lock` 租约 →
"Failed to update lock optimistically ... the object has been modified" 无限刷 →
**三台都认为自己该持有 VIP**。

生产路径(`kubespray` 真部署)不会遇到,因为 `inventory_hostname` 天然是各自节点名;
**但任何"批量渲染再分发"的实现都必须防这一条**。模块已把它做成硬断言。

### 17.3 实机验收结果(裸金属 3 master + 4 worker)

| 项 | 结果 |
|---|---|
| `--steps kube_vip` 首次 | ✅ 渲染/分发/选举/校验一次通过 |
| 再次运行(等幂等) | ✅ 三台全部"manifest 已是最新, 跳过" |
| `--steps verify_kube_vip` | ✅ **六项全过** |
| ② VIP 唯一绑定 | ✅ 唯一持有者(无脑裂) |
| ④ 网卡正确性 | ✅ VIP 网卡 = 节点主 IP 网卡(`manage0`) |
| ⑤ EndpointSlice | ✅ 3 个地址(非单点) |
| ⑥ **漂移实测** | ✅ **1s / 2s**(两次演练),API 全程可达 |

**漂移实测 1–2 秒,远快于设计文档预估的 5–10 秒。** 原因:演练是"摘除 manifest 让容器退出",
kube-vip 退出时会**主动释放租约**(而非等租约自然过期),故切换接近即时。
只有"进程被 SIGKILL / 节点瞬间断电"这种来不及释放的场景才需要等满 `leaseduration`。
→ 第 2.4 节"退步到 5-10s"的担忧可以下调:常见故障下 worker 侧感知延迟与 nginx 方案同级。
(注:此结论来自"进程主动退出"这一演练形态;真实宕机是否等同,需按第 11 节 R1 继续观察。)

> ⚠ **验收边界(2026-09-22 复核补记)**: 上表全部通过的都是**阶段一(VIP 就位)**。
> 集群至今**仍停在阶段一** —— 实测:`all.yml` 的 `loadbalancer_apiserver.address` 仍是
> `10.66.1.147`(master01),四台节点(3 master + 1 worker)`/etc/hosts` 里
> `k8s-api.cubestack.io` 都指向 `10.66.1.147`,`ss` 里对外连接也全部落在 `10.66.1.147:6443`。
> kube-vip 在 `.154` 上正常持有 VIP `10.66.1.139` 并能漂移,但**没有任何客户端使用它**。
> 也就是说:**"API 入口"目前仍是 master01 单点,高可用尚未实际生效**。
> 要生效需按第 7 节**显式**跑一次全量 `k8s_deploy`(探测到 VIP 已 bound → 阶段二 + 30s 倒计时确认)
> ——那一步会触发证书 SAN 重签与各节点 apiserver 重启,应在维护窗口做。
> **在此之前讨论"要不要开控制面负载均衡"没有意义** —— VIP 上都还没有流量。

### 17.4 本轮修复的既有 bug(与 kube-vip 无关,但都会静默致瘫)

| # | 位置 | 问题 |
|---|------|------|
| 1 | `lib-common.sh#node_parse` | 纯解析函数在 `if` 分支未命中时返回 1;`set -e` 下 `X=$(...)` 会**静默中止调用方**(09_kube_vip 遍历到 worker 时无报错直接死掉) |
| 2 | `lib-common.sh#master_hosts`/`all_node_ips` | 同上:`A && B && printf` 在条件不成立时整条返回 1,命令替换下会中止调用方。已改显式 `if` + `return 0` |
| 3 | `08_verify_kube_vip.sh` | VIP 持有判定误用 `ip route get` —— 同网段下它对**所有**节点都返回 `local`,会误报 N 个持有者。改用 `ip -4 -o addr show`(09_kube_vip 同) |
| 4 | 两个 kube-vip 模块 | 用**主机名**做 SSH —— 部署容器里没有节点名的 `/etc/hosts` 解析,静默连不上(表现为"镜像缺失"/"VIP 未绑定"这类假故障)。已统一改用 IP |

### 17.5 新增配置项

| 变量 | 默认 | 说明 |
|---|---|---|
| `KUBE_VIP_CP_DETECT` | `false` | apiserver 进程级故障检测(见第 15 节;★ 2026-09-24 由默认开改为默认关) |
| `KUBE_VIP_LOCAL_PROXY` | `false` | kubespray 原生本地代理;置 true 会因 16.1 的优先级冲突而**硬失败**,防假修复 |

---

## 18. 单一写入者与双向收敛(2026-09-22)

这一节的起点是三个各自独立、但根因相邻的问题。它们都属于同一类:**"看起来收敛了,其实没有"**。

### 18.1 契约:静态 Pod 归 `09_kube_vip` 独占

`addons.yml` 里写的 `kube_vip_enabled` **恒为 false,且不跟随 `KUBE_VIP_ENABLED`**。

这不是"kube-vip 没启用",而是**"不要让 kubespray 写这个静态 Pod"** —— 即 kubespray 的
kube-vip 功能是关的,而 cubestack 的 kube-vip 功能是开的。写这个值的是
`lib-common.sh#update_kube_vip_addons_yml`(所以无论开关怎么翻都在正确的状态)。

关掉之后 kubespray 对本集群 kube-vip 的**唯一**贡献是: 把 `kube_vip_address` 写进
apiserver 证书 SAN(`control-plane/tasks/kubeadm-setup.yml:48` 的 `sans_kube_vip_address`,
**只看该变量是否定义,不看这个开关**)。所以 `kube_vip_address` 在开关关闭时**也保留** ——
关掉 kube-vip 之后再开回来,不必重签证书(而重签正是阶段二切换的主要代价之一)。

**代价核对(逐项确认过没有损失):**

| 影响面 | 结论 |
|---|---|
| kubespray 的 `kube_proxy_strict_arp` fail-fast 检查(随 import 一起被跳过) | 无损失 —— 本仓库 `k8s-cluster.yml:124` 已显式 `kube_proxy_strict_arp: true`,该检查对我们从不触发 |
| kube-vip 从 `download.yml:855` 的下载清单消失 | 无损失 —— 走本仓库自己的 `PRELOAD_IMAGE_PATTERNS`;模块另有 `ctr -n k8s.io i ls` 硬校验 |
| 证书 SAN | 无损失 —— 见上 |
| 首装时序 | **收益** —— 见 18.3 末尾(顺带消除 R2) |

`addons.yml` 里其余 `kube_vip_*` 键(arp/controlplane/cp_detect/services_enabled/lb_enable/interface)
在当前开关下**全部不生效**,保留它们纯粹是逃生口: 万一手工把开关翻回 true,kubespray 渲染出来的
仍是这套策略,而不是一份 `vip_arp` 全关的坏 manifest。

### 18.2 双向收敛:开关开=安装/修复,开关关=清理

模块腾挪到位需要**三处**配合,缺任何一处这条链就断:

| # | 位置 | 改动 |
|---|------|------|
| 1 | `09_kube_vip.sh` | `DEFAULT: 0` → **`1`** —— 让它成为全量运行的常驻项。带 TOGGLE 的模块默认只在开关为 true 时进 RUN_STEPS,开关一关就**彻底不被调度**,这正是下面 18.4 的根因 |
| 2 | `deploy-cluster.sh` TOGGLE 导出循环 | 加 `! module_default_on` 前置条件。原逻辑对 **RUN_STEPS 中的任何** TOGGLE 模块无条件 `export <TOGGLE>=true` —— 有了第 1 条之后,它会把用户在 cluster.conf 里写的 `false` 冲成 `true`,清理分支永远不可达。对**现有全部模块是 no-op**(默认启用的模块其 TOGGLE 本就已是 true;而已核当前没有任何模块同时是 `DEFAULT: 1` + 带 TOGGLE)。显式 `--enable kube_vip` 不受影响 —— 那条路径会把开关**持久化写回 cluster.conf** |
| 3 | `check-modules.sh` ⑪ | 拆成 ⑪-A(单一写入者契约,`kube_vip_enabled` 必须为 false,**与开关无关、恒校验**;CI 干净检出下该键本就是 false,不会误报)与 ⑪-B(开关开启时才校验 `kube_vip_address` 非空等) |

关闭态的处理逻辑(`kube_vip_cleanup`):

```
① 逐台探活 + 探"有没有 manifest"(一次 SSH 同时拿两件事)
     任一 master 不可达 → 中止, 不做任何删除(半清理比不清理更难排查)
② 各台都没有 manifest → 已经是目标状态, 直接收敛并 exit 0
     ⚠ 这一步不是省事, 是必需的: 否则"入口指向别的 LB(如 HAProxy)"的集群会被下面
       的护栏误拦 —— 而它根本没有 kube-vip 可清, 拦停等于把好好的部署打断
③ 阶段护栏(**只有确实有东西要删时才生效, 且 fail-closed**)
     放行条件: 入口为空(从未部署) 或 入口 = 某个节点 IP(阶段一, 客户端直连 master)
     其余一律拒绝 —— 既包括"入口 = 记录的 VIP", 也包括"**记录读不到**"
④ 逐台 rm -f /etc/kubernetes/manifests/kube-vip.yml
     必须**全删** —— 只删当时持有 VIP 的那台, 下次选举另一台又会把 VIP 绑回去
⑤ 等 15s 后校验: 无 kube-vip 容器 + VIP 不在任何 master 网卡上
     任一不满足 → err(只删了文件不等于地址释放了; kube-vip 收到 SIGTERM 会主动 DeleteIP)
```

**为什么护栏必须是 fail-closed,而不是"等于记录的 VIP 才拦":** 记录的 VIP 可能**读不到** ——
`addons.yml` 的 `kube_vip_address` 被**旧版** sync 删过键(旧实现里开关关闭时只写
`kube_vip_enabled: false`,会把 `kube_vip_address` 一并丢掉),而 `K8S_API_VIP` 又留空。
这种情况下"入口地址 ≠ 记录值"**根本不能证明安全**,按等值拦会把它漏过去 —— 那正是自毁窗口。
改成"只有能证明入口不是 VIP 才放行"之后,记录缺失会被**拦停**(已实测,见 18.7 的场景 D2)。

**护栏为什么不是冗余:** 正常全量路径下,`kube_vip_resolve_target()` 在开关关闭时本来就返回
第一个 master,入口已经退回,护栏只是兜底。但本模块可以脱离全量流程单跑(`--steps kube_vip`),
那时 `all.yml` 可能还停在 VIP 上 —— **护栏是那条路径上唯一的保险**。命中时给出走法:
先跑一次全量(或 `--steps k8s_deploy`)把入口退回 master01,再回来清理。

### 18.3 问题一:两个写入者(manifest 每次全量运行被改写两次)

`kube_vip_enabled: true` 时,kubespray 自己也会写 `/etc/kubernetes/manifests/kube-vip.yml`
(`node/tasks/main.yml:19`,条件是 `kube_control_plane in group_names and kube_vip_enabled`)。

**复现(实测,2026-09-22):** 用真正的 ansible `template` 模块复刻 kubespray 的变量解析
(role defaults 当底、addons 那组值用 `-e` 覆盖、`kube_vip_admin_conf` 按 `kube-vip.yml:24-31`
的 set_fact 判定),再与我们的渲染器逐台对拍:

```
✅ cubestack-k8s-master02: 逐字节一致
✅ cubestack-k8s-master03: 逐字节一致
❌ cubestack-k8s-master01: 不一致 ——
     -      path: /etc/kubernetes/super-admin.conf
     +      path: /etc/kubernetes/admin.conf
```

**后果不是"内容错", 而是"每轮白重启两次":** 全量运行时 kubespray 先把 master01 的 manifest
改成 `super-admin.conf`,静态 Pod 被 kubelet 重启一次;随后本模块按 hash 比对发现不一致,
又写回 `admin.conf`,再重启一次。如果 master01 正好是 VIP 持有者,这一轮里 VIP 会抖动两次。
master02/03 不受影响(其余变量我们与上游完全一致,已由上面的逐字节对拍确认)。

> ⚠ **变量默认值本身没有分叉** —— `roles/kubernetes/node/defaults/main.yml:60-84` 的
> `kube_vip_cidr: 32` / `dns_mode: first` / `leasename: plndr-cp-lock` / `svc_leasename` /
> `leaseduration: 5` / `renewdeadline: 3` / `retryperiod: 1` / `leader_election_enabled: "{{ kube_vip_arp_enabled }}"`
> 等,与渲染器里硬编码的那组值逐条一致。**唯一的分歧点就是 `kube_vip_admin_conf`** ——
> 而它是**节点状态相关**的启发式(首台 CP + `super-admin.conf` 存在或 kubeadm 没跑过),
> 要在这边"猜对"就得复刻那套状态机,与本模块"不依赖 inventory 状态机"的立身之本冲突。
> 所以选择了关掉 kubespray 那侧,而不是对齐渲染器。

**顺带消除 R2:** 关掉之后不再有任何东西在 `kubeadm init` 之前写 manifest,也就不再有任何东西
在 init 之前需要 VIP —— 第 11 节那条"未经证实的 bootstrap 时序链"风险随之消失。

### 18.4 问题二:关掉开关不清理(一条空头承诺)

`docs` §7.4 从设计之初就写着"`KUBE_VIP_ENABLED=false` 重跑(删 static pod manifest,
控制平面零影响)",但**代码里从来没有这段逻辑**,而且模块根本不会被调度
(`DEFAULT: 0` + TOGGLE 为 false → 不进 RUN_STEPS → 脚本连启动都没有)。

实际状态与"幂等"正好相反:**目标状态是"没有 kube-vip",实际状态是"还在跑"** —— manifest 还在,
VIP 继续被持有、继续参与选举。已由 18.2 的第 1、2 条修复。

### 18.5 问题三:模块原先排在 `k8s_deploy` **之前**(会让全新集群的部署在装集群前中断)

这是本次顺带查出来的**既有**问题(HEAD 上同样存在,不是本次改动引入)。

模块文件序号 `09` > `06` **不足以定序** —— `resolve_run_steps` 会按 REQUIRES 做拓扑排序,
而原模块**故意不声明 REQUIRES**,于是实际顺序是 `k8s_ntp → kube_vip → k8s_deploy`。

后果:全新集群上 `kube_vip` 的前置自检 `is_cluster_live` 必然失败(集群还不存在),
模块 `exit 1`,而 `deploy-cluster.sh:611` 是:

```bash
run_module "${key}" || { FAILED=1; break; }
```

—— **一失败即整体中止,整个部署会在 `k8s_deploy` 之前停下**。而 `KUBE_VIP_ENABLED` 默认就是 true。

**修法: 补 `REQUIRES: k8s_deploy`。** 原注释里"不声明 REQUIRES"的顾虑是"`--steps kube_vip`
会把整套 kubespray 拉进来",该顾虑**已不成立**(实测三条):

| 命令 | 结果 |
|---|---|
| 默认全量 | `... k8s_ntp → k8s_deploy → kube_vip → metallb ...` ✅ 顺序已修正 |
| `--steps kube_vip` | `本次执行模块: kube_vip` ✅ 仍然只跑本模块 |
| `--steps verify_kube_vip` | 不受影响 ✅ |

两条规则共同保证第二条: ① `--steps` 精确模式下,依赖已完成(`REPEAT≠1` 且 `state=done`)时不拉入执行;
② 基座模块(`k8s_deploy` 在 `BASE_MODULES` 内)未被显式命名时会被剔除。

### 18.6 落地文件

| 文件 | 改动 |
|---|---|
| `modules/02_k8s/09_kube_vip.sh` | `DEFAULT: 1`;`REQUIRES: k8s_deploy`;新增关闭态分支 `kube_vip_cleanup`(18.2 的四步);订正头注释里"首装 kubeadm init 依赖 kube-vip"的过时表述 |
| `lib-common.sh` | `update_kube_vip_addons_yml`: `kube_vip_enabled` 恒 false + 契约注释;`kube_vip_address` 关闭时也保留;新增 `kube_vip_recorded_address()` |
| `deploy-cluster.sh` | TOGGLE 导出循环加 `! module_default_on` |
| `tools/check-modules.sh` | ⑪ 拆 ⑪-A / ⑪-B |
| `config/cluster.conf` | `KUBE_VIP_VERSION` 注释里"否则首装 kubeadm init 失败"的过时表述 |

### 18.7 验证边界(哪些验过、哪些没验)

**已验(本地,2026-09-22):**

- `bash -n` 全部改动文件;`check-modules.sh` 在**干净检出**(无 `.deploy.state`)下全绿
- 渲染对拍:非首台 CP **逐字节一致**,首台 CP 差一行(18.3)
- 关闭态控制流 —— 用**假 `ssh`**(只按远端命令串返回预设结果)驱动**真实模块脚本**跑完整流程:

  | # | 场景 | 期望 | 结果 |
  |---|------|------|------|
  | A | 入口=VIP + 有 manifest | 拒绝, 且不删任何文件 | ✅ 拦停, manifest 仍在 |
  | B | 入口=VIP + **无** manifest | 不得误拦(HAProxy 类集群) | ✅ 收敛为"已是干净状态" |
  | C | 入口=master01 + 有 manifest | 正常清理三台 | ✅ 三台删除 + 校验通过 |
  | D | 入口=未知非节点地址 + **记录读不到** | fail-closed 拒绝 | ✅ 拦停, manifest 仍在 |
  | E | 入口=master01 + 记录读不到 | 放行(不能因记录缺失就一律拦) | ✅ 正常清理 |

  另有一条用**不可达地址**(TEST-NET-1)驱动的用例: 任一 master 连不上 → 中止且
  **未做任何删除**(半清理比不清理更难排查)
- 模块调度顺序三条(18.5 的表)

**未验(需要实机,部署容器 + 至少 3 台 master):**

- 关闭态在**真实集群**上跑通:三台 manifest 消失、无容器、VIP 从网卡释放
- 静态 Pod 被删后 kube-vip 确实在 SIGTERM 中释放 VIP(代码上成立,`clusterLeaderElection.go`
  的 `DeleteIP`,但未实测)
- 再次开启后 VIP 回来、且**不触发证书重签**(依赖 SAN 保留的判断)
- 全量运行后 master01 的 manifest hash **全程不变** —— 这是"两个写入者已消除"的直接断言,
  需要先按 18.3 复现出"改前会变两次",再验改后不变
