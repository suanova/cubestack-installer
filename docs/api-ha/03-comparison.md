# 03 · 三方案对比与业界最佳实践

> 对比对象：① kubespray 原生每节点本地代理 ② kube-vip VIP ③ HAProxy + Keepalived
> 评估基准：[01 文档](01-current-state.md) 的现状 + 四档验收标准（节点自愈 / 运维与 CI / 外部系统 / Pod）

---

## 0. 评估维度

| 维度 | 为什么重要 |
|---|---|
| **节点侧覆盖** | kubelet 是最长命的客户端。它的入口断 = 节点失联 = 调度/上报/存储挂载全停 |
| **外部/管理侧覆盖** | 人的 kubectl、CI、外部系统需要一个**稳定不变**的地址 |
| **故障域与切换时间** | 单点在哪、切换多久、有无静默失效 |
| **是否需要额外基础设施** | 额外机器 / 额外 IP / 额外网段要求，直接决定可落地性 |
| **证书影响** | 涉及重签 = 涉及窗口 = 涉及 apiserver 重启 |
| **离线镜像依赖** | 本项目是离线交付，缺镜像是硬阻断 |
| **仓库存量代码与验证成熟度** | 已踩过的坑 vs 未验证的路径 |
| **上行支持度** | 是上游原生路径，还是需要与上游模板"对抗" |

---

## 1. 方案 ①：kubespray 原生每节点本地代理

实现细节见 [02 文档](02-kubespray-native-lb.md)。

**架构**：每 worker 一个 nginx（或 haproxy）静态 Pod，`127.0.0.1:6443` → 全部 master，`least_conn`。

**优点**
- 节点侧**完全去中心化**：不依赖任何一台具体 master，不需要 VIP，不需要同二层网段
- 上游原生路径，扩容/重跑自动维护，无手工覆写
- 纯 TCP 转发，**不动证书 SAN**
- 故障域最小：单节点代理挂掉只影响该节点

**代价**
- 每节点多一个静态 Pod（内存/镜像开销可忽略，但要预加载镜像）
- 入口语义变成 `localhost` → `/etc/hosts` 的域名行与 manifest 清理需要我们自己补（[02 §7.1](02-kubespray-native-lb.md#71-路线-2-需要我们自己补的两件事)）
- nginx 版**无主动健康检查**；已建立连接遇后端静默死亡最长 10 分钟才断

**单点清单**

| # | 故障场景 | 影响 | 是否已缓解 |
|---|---|---|---|
| 1 | 单节点代理进程崩溃 | 仅该节点 kubelet | ✅ static pod + `system-node-critical` 自动重启 |
| 2 | 新连接遇死后端 | 最坏慢 1s，**零失败** | ✅ 连接级重试（实测 30/30、20/20） |
| 3 | 已建立连接遇后端静默死亡 | 最长 10m 不重连 | ❌ 无缓解（nginx）；换 haproxy type 可改善 |
| 4 | **master 自身的 kubelet** | 打自己的 apiserver | ⚠ 上游设计如此：master 不装代理，apiserver 挂了由 kubelet 重启 |
| 5 | 新节点 join / discovery | 依赖首 master | ⚠ 一次性动作，上游 `kubeadm_discovery_address` 有意如此 |
| 6 | 离线镜像缺失 | 静态 Pod 起不来 | ✅ **2026-09-28 已补齐**（nginx 版），见 [02 §10](02-kubespray-native-lb.md#10-离线镜像要求当前仓库的硬缺口) |
| 7 | 8xxx 探针端口暴露 | 节点网络上可达 8081 | ⚠ 只返回 200/stub_status，非数据面 |

---

## 2. 方案 ②：kube-vip（浮动 VIP）

实现细节见 [../kube-vip-api-ha.md](../kube-vip-api-ha.md)（含两阶段流程、脑裂事故、决策 D1-D7）。

**架构**：三台 master 上各跑一个 kube-vip 静态 Pod，通过租约选举出一台持有 VIP（ARP 通告），
VIP 加入 apiserver 证书 SAN，域名解析到 VIP。

**优点**
- **一个稳定地址**：域名/VIP 不随 master 增减变化
- 零额外机器；VIP 跑在 master 上
- 覆盖"人的 kubectl / CI / 外部系统"这一档，且是**唯一**能做到的方案（① 只听 loopback）
- 仓库已有完整实现 + 验证模块 + 踩坑记录（脑裂、`lb_fwdmethod: local` 静默失效等）

**代价**
- 需要证书 SAN 含 VIP → **存量集群要重签证书**（一次性窗口）
- 需要同二层网段 + 空闲 IP + fabric 允许 ARP（云环境受限）
- 真实宕机时切换依赖租约（**~5s**），非秒级

**单点清单**（完整版见 [../kube-vip-api-ha.md §11](../kube-vip-api-ha.md)）

| # | 故障场景 | 影响 | 是否已缓解 |
|---|---|---|---|
| 1 | leader 节点断电 | 全集群入口消失 ~5s（等租约过期） | ⚠ 上游默认租约；仓库明确不调参（改短会误判） |
| 2 | leader 进程正常退出 | 实测漂移 1–2s | ✅ 退出时主动释放租约 |
| 3 | 节点活着但 apiserver 进程死 | 无 `cp_detect` 时 VIP 永不漂移 | ✅ 仓库默认 `KUBE_VIP_CP_DETECT=true` |
| 4 | 脑裂（多台同时持 VIP） | API 行为不确定 | ✅ 渲染后断言 `vip_nodename` 逐台唯一（**实测踩过**） |
| 5 | VIP 落在 MetalLB 池 / 与节点 IP 冲突 | ARP 打架 | ✅ 硬失败护栏 |
| 6 | 多网卡选错 | VIP 绑错网卡（静默） | ✅ `KUBE_VIP_INTERFACE` + verify ④ 可检出 |
| 7 | 扩容 master 不参与选举 | 极端情况丢入口 | ❌ 未修（当前 scale 只扩 worker，无实际影响） |
| 8 | `lb_fwdmethod: local` 误开 | **静默零负载均衡** | ✅ 默认关闭 + 文档定性 |
| 9 | 上游零 CI 覆盖 | 无回归保护 | ❌ 只能靠本仓库的 verify 模块 |

---

## 3. 方案 ③：HAProxy + Keepalived（外部双机 VIP）

现状：本仓库有模块（`modules/01_env/05_lb_haproxy.sh` + `06_lb_keepalived.sh`），**默认关闭**，
且 **keepalived 那半是"假 HA"**：

```bash
# modules/01_env/06_lb_keepalived.sh:52-54
state MASTER              # ← 写死 MASTER，没有第二个节点参与 VRRP
virtual_router_id 51      # ← 写死
priority 100              # ← 写死
```

即"一台机器上有个 VIP"，**不是**高可用。要变成真 VRRP 集群，需要：
- 至少第二台机器，配 `state BACKUP` + 不同 `priority` + 相同 `virtual_router_id`
- VRRP 多播放行、健康检查脚本（check haproxy / check apiserver）、抢占策略

**优点**（做真之后）
- HAProxy 有**主动健康检查**（`option httpchk`），比 nginx 版剔除死后端更快
- 不依赖容器镜像（宿主机 apt 包），离线交付友好
- 是 OpenShift 等发行版采用的传统方案，运维人员熟悉

**代价**
- **需要 2 台专职机器**（本项目现场没有）
- 多一层非 Kubernetes 管理的组件（不在集群自愈范围内）
- 仍然**不覆盖节点侧** —— kubelet 若指向 VIP，master 宕机时它和外部客户端一起受影响；
  要覆盖节点侧就得再叠加方案 ①
- 与 kube-vip 功能重叠，二者必须互斥（仓库已有硬失败护栏）

**单点清单**

| # | 故障场景 | 影响 | 是否已缓解 |
|---|---|---|---|
| 1 | 单机 VIP（现状实现） | 该机宕机 = 入口消失，与现状同类 | ❌ **假 HA，需重写** |
| 2 | haproxy 进程崩溃 | 入口中断直到 systemd 重启 | ⚠ 有 `systemctl enable`，无 watchdog |
| 3 | 后端全挂 | 入口消失 | ✅ 主动健康检查可快速剔除 |
| 4 | 非集群管理 | 无自愈、无 GitOps 可见性 | ❌ 架构性 |
| 5 | 需 2 台机器 | 现场不具备 | ❌ 落地阻断 |

---

## 4. 横向对比

| 维度 | ① 本地代理 | ② kube-vip | ③ HAProxy+Keepalived |
|---|---|---|---|
| 节点侧（kubelet）覆盖 | ✅ 完整 | ⚠ 依赖 VIP 漂移 | ❌ 不覆盖 |
| 外部/管理侧覆盖 | ❌ 只听 loopback | ✅ | ✅ |
| 切换时间（节点侧） | **~1s**（实测最坏 1.0045s） | ~5s（真实宕机） | — |
| 切换时间（外部侧） | — | 1–5s | 亚秒（VRRP）|
| 额外机器 | 0 | 0 | **2 台** |
| 额外 IP | 0 | 1 个 VIP | 1 个 VIP |
| 网络前提 | 无 | 同二层 + ARP | 同二层 + VRRP 多播 |
| 主动健康检查 | nginx ❌ / haproxy ✅ | 租约 + 可选 cp_detect | ✅ |
| 证书影响 | **无**（纯 TCP 转发） | **全新安装无需**（SAN 首次即含 VIP）；存量迁移才需重签 | 无 |
| 离线镜像 | ✅ 已就绪（nginx 版，2026-09-28 补齐） | ✅ 已就绪 | ✅ apt 包 |
| 上游支持 | ✅ 原生 | ⚠ 上游零 CI，但仓库已自研验证 | ❌ 需自行重写 |
| 额外组件数 | 每 worker 1 个静态 Pod | 每 master 1 个静态 Pod | 2 台机器 + 2 进程 |
| **结论** | **必选** | **必选** | **不选**（现场无机器；现实现是假 HA） |

---

## 5. 为什么 ① + ② 是"最佳"，而不是二选一

两者解决的是**不同层**的问题，覆盖集互补：

```
                  节点侧                外部/管理侧
① 本地代理     ✅ 完整覆盖                ❌ 结构上做不到（只监听 loopback）
② kube-vip     ⚠ 只有 VIP 漂移的兜底      ✅ 完整覆盖
```

- **只有 ①**：集群自己活得很好，但人/CI/外部系统仍需要一个地址 → 只能指某台 master（新单点）
- **只有 ②**：外部地址稳定了，但每个节点的 kubelet 仍然跨网络依赖 VIP 所在的那台 →
  真实宕机时**所有节点**一起抖动 5s，且节点侧故障域是"全集群"而不是"单节点"
- **① + ②**：节点侧去中心化（故障域 = 单节点，切换 ~1s），外部侧地址稳定（切换 1–5s）

**关键洞察**：引入 ① 之后，kube-vip 的两阶段切换**风险面大幅缩小** ——
因为切入口时受影响的不再包括每台节点的 kubelet，只剩人类/外部客户端。
这反过来让 ② 更容易安全落地。

---

## 6. 业界最佳实践对照

| 系统 | API HA 的做法 | 与本文的对应 |
|---|---|---|
| **kubeadm 官方 HA 拓扑** | 控制面之前放一个 TCP 透传 LB（6443），所有 kubelet/kubectl 打 LB；LB 必须支持 4 层透传 | ② 的角色 |
| **kubeadm / 社区 "local proxy" 模式** | 在**每个节点**上跑一个代理（文档给出的示例就是 nginx / haproxy 配 keepalived），kubelet 打 `localhost` | ① 的角色 |
| **RKE2** | agent 内置**客户端负载均衡**：kubelet 始终连本机，agent 在多个 server 之间做健康检查与切换 | ① 的思路（且证明"每节点本地代理"是主流做法） |
| **k3s** | agent 侧同样有内建的多 server 负载均衡与健康检查 | 同上 |
| **Talos** | 控制面内建 **VIP**（租约 + ARP 通告），等价于把 kube-vip 做成平台能力 | ② 的思路 |
| **OpenShift** | keepalived(VRRP) + HAProxy 双机，为 API 与 ingress 各提供一个 VIP | ③ 的"做真版"，代价是两台专职机器 |
| **托管 K8s（EKS/GKE/AKS）** | 云 LB / 区域端点，控制面本身托管 | 等价于 ② 但由云厂商承担 |

**共性结论**：

1. **节点侧用"每节点本地代理"是主流**（RKE2/k3s 内建，kubeadm 文档有示例），
   因为它把"能否连上 API"从"网络 + 选举"降级为"本机进程是否活着"。
2. **外部侧用 VIP / LB**（Talos 内建、OpenShift 双机、云厂商托管 LB）。
3. **没有任何一个成熟发行版只用其中一个** —— 这正是本方案选 ①+② 的依据。

---

## 7. 反模式清单（看似高可用，其实不是）

| 反模式 | 为什么不是高可用 |
|---|---|
| 把 `/etc/hosts` 的域名指向"第一台 master" | 就是本项目现状：单点，且宕机后**不降级、直接失联** |
| 只设 `loadbalancer_apiserver_localhost: true` | 分支优先级导致"代理装了没人用"的静默假修复（[02 §6](02-kubespray-native-lb.md#6-为什么只改开关是假修复)） |
| 给 kubelet 配上 3 台 master 的地址列表 | kubelet 只接受**一个** server 地址，没有列表语义 |
| 用 ClusterIP/Service 做 kubelet 的入口 | kubelet 必须先连上 API 才能有 Service，循环依赖 |
| kube-vip 开 `lb_enable` + `lb_fwdmethod: local` | 内核里是 `ip_vs_null_xmit`，**零转发且不报错**，verify 六项照样全绿 |
| 单机 keepalived 配 `state MASTER` | 那是"一个 VIP"，不是高可用；机器挂了 VIP 也没了 |
| 只做 VIP 不做节点侧 | 节点侧故障域仍是"全集群跨网络依赖"，切换 5s 且全体一起抖 |
| 靠 `advertise-address` 修入口 | 那是**集群内 Service 端点**的问题，与节点侧入口是两条独立链路（本项目两条都已修） |

---

## 8. 结论

| 决策 | 内容 |
|---|---|
| **采用** | ① kubespray 原生每节点本地代理（`nginx` type） + ② kube-vip VIP |
| **不采用** | ③ HAProxy + Keepalived（需 2 台专职机器；现实现是假 HA；功能与 ② 重叠） |
| **不采用** | 只做 ② 不做 ①（节点侧故障域仍是全集群） |
| **保留** | ③ 的模块与文档（现场将来真有 2 台 LB 机器时可再评估），但在文档中标明"不推荐 + 当前实现非 HA" |
| **兼容** | 环境已有 LB/VIP → 用 `API_EXTERNAL_ADDR` 复用，不装 kube-vip |
| **降级** | 无 VIP 可用 → 节点侧仍为真 HA，外部入口回退首 master 并 warn 明示 |

落地细节见 [04-decision.md](04-decision.md)。
