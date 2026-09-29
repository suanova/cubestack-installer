# Kubernetes API 入口高可用（API HA）

> 本组文档回答一个问题：**这个集群的 API 入口，怎么从"全压第一台 master"变成真正的高可用**。
>
> 取证时间：2026-09-27（实机）· 适用：kubespray 部署的 CubeStack 集群

---

## 一句话结论

集群现在**不是高可用**：三台 master 上跑着健康的 etcd 和 apiserver，但全集群的客户端
（每台节点的 kubelet、kube-proxy、admin.conf、外部系统）都通过 `/etc/hosts` 的一个静态映射
指向**第一台 master**。第一台宕机 = 全集群失联（不是降级）。

推荐方案 = **上游原生每节点本地代理 + kube-vip 浮动 VIP**：

| 层 | 机制 | 解决什么 |
|---|---|---|
| 节点侧 | kubespray 原生 nginx-proxy 静态 Pod（每 worker `127.0.0.1:6443`） | 节点就近出口，不再依赖任何一台具体 master |
| 管理/外部侧 | kube-vip 持有浮动 VIP，域名指向 VIP | 入口地址稳定，master 宕机时地址不变 |
| 集群内 Pod | kube-proxy ipvs（现状已满足） | 保持 |

---

## 现状 → 目标

```
现状（单点）                                    目标（高可用）
─────────────                                   ─────────────
worker kubelet ─┐                               worker kubelet → localhost:6443 → 本机 nginx ─┐
master kubelet ─┤                               master kubelet → 127.0.0.1:6443 → 自己        │
kube-proxy     ─┼→ k8s-api.cubestack.io                                                  ▼
kubectl / CI   ─┤      ↓ /etc/hosts               kubectl / CI → 域名 → VIP ──────→ [m01 m02 m03]
外部系统        ─┘  10.66.3.28 (master01)        外部系统    → 域名 → VIP ──────→ (least_conn)
                       │
                  [m01]  ← 单点                    Pod → kubernetes.default.svc → ipvs → 三台
                  m02 m03（闲置）
```

---

## 三方案速览

| | ① 每节点本地代理（kubespray 原生） | ② kube-vip VIP | ③ HAProxy + Keepalived |
|---|---|---|---|
| 节点侧自愈 | ✅ 每节点独立，最坏 1s 重试 | ⚠ 依赖 VIP 漂移（真实宕机 ~5s） | ❌ 不覆盖节点侧 |
| 管理/外部入口 | ❌ 只听 `127.0.0.1` | ✅ 浮动 VIP | ✅ VIP |
| 额外机器 | 0（每节点一个静态 Pod） | 0 | **2 台** |
| 健康检查 | nginx 版无主动检查 / haproxy 版有 | 租约 + 可选 cp_detect | haproxy 主动检查 |
| 证书影响 | 无（纯 TCP 转发，不终止 TLS） | **VIP 须进 SAN（要重签）** | 无 |
| 离线镜像 | ✅ 已就绪（nginx 版；2026-09-28 补齐，见 02 文档 §10） | ✅ 已就绪 | 宿主机 apt 包 |
| 仓库成熟度 | 上游原生，零自研 | 清单由**上游渲染**（2026-09-28 收编后零自研）+ 本仓库负责 VIP 推导 / 入口 / 清理 / 验证；已踩过脑裂 | 默认关，且现实现是**假 HA** |

**①+②是互补关系，不是二选一** —— 一个管节点侧，一个管外部侧。详细论证见
[03-comparison.md](03-comparison.md)，决策记录见 [04-decision.md](04-decision.md)。

---

## 配置速查（cluster.conf）

> ✅ **实施状态：已实施**（代码提交范围 `cac86e4..a7509d9`，含 `cac86e4`，共 10 个提交；
> `API_LOCAL_LB_ENABLED` 默认 **true**）。
> 🔁 **2026-09-28 追加：kube-vip 收编** —— 静态 Pod 清单改由 **kubespray 自己**渲染（`addons.yml` 的
> `kube_vip_*` 驱动），自持渲染器与"恒 false 的单一写入者契约"已删除；上表 `09_kube_vip.sh` 相应瘦身。
> 评估全文与本规划逐条的满足性对照见 **[07-kube-vip-upstream-assessment.md](07-kube-vip-upstream-assessment.md)**。
> `API_LOCAL_LB_ENABLED` / `API_LOCAL_LB_TYPE` / `API_EXTERNAL_ADDR` 三个开关已生效，与既有的
> `KUBE_VIP_ENABLED` / `K8S_API_VIP` 并存；改动清单见 [04-decision.md](04-decision.md) §4，
> 逐步任务单与实作更正见 [06-implementation-plan.md](06-implementation-plan.md)。
> ⚠ 落地范围 = 代码 + 文档：`check-modules.sh` 第 1–10 项与第 ⑬ 项全绿（⑬ 自 2026-09-28 起覆盖
> **四份** `PRELOAD_IMAGE_PATTERNS` 副本）、三个单测全绿（第 ⑪ 项是既有的、与本方案无关的红项；
> 第 ⑬ 项因未同步 `all.yml` 而跳过）。
> ✅ **实机状态（2026-09-28 更新）**：kube-vip 已在真集群生效 —— 静态 Pod 清单在场、容器 Running、
> **VIP `10.66.3.240` 已绑到节点网卡**；节点侧本地代理的实机收敛随下一轮部署（见
> [07](07-kube-vip-upstream-assessment.md) §8.1 的验收进度表）。

```bash
# 节点侧（新，默认开）
API_LOCAL_LB_ENABLED="${API_LOCAL_LB_ENABLED:-true}"   # 每节点本地代理
API_LOCAL_LB_TYPE="${API_LOCAL_LB_TYPE:-nginx}"        # nginx | haproxy
# 管理/外部侧（三选一，优先级 external > vip > node，冲突硬失败）
API_EXTERNAL_ADDR="${API_EXTERNAL_ADDR:-}"             # 环境已有 LB/VIP
KUBE_VIP_ENABLED="${KUBE_VIP_ENABLED:-false}"          # ⚠ 2026-09-24 起默认关；要外部入口 HA 需显式置 true
K8S_API_VIP="${K8S_API_VIP:-}"                         # 空=自动推导
```

> ⚠ 上面这段的默认值与 `deployments/config/cluster.conf.example` 现版**逐字对齐**（2026-09-29 核对）。
> 本节曾写作 `KUBE_VIP_ENABLED:-true`（默认开）—— 那是 2026-09-24 翻转前的值，**已作废**。

三种典型场景：

| 场景 | 配置 | 结果 |
|---|---|---|
| 标准（推荐） | 默认值 | **节点侧**（`API_LOCAL_LB_ENABLED=true`）全高可用；外部入口回退首 master + warn 明示 |
| 外部入口也要高可用 | `KUBE_VIP_ENABLED=true`（+ 可选 `K8S_API_VIP`） | 节点侧 + 外部侧全高可用 |
| 环境有现成 LB/VIP | `API_EXTERNAL_ADDR=10.x.x.x` + `KUBE_VIP_ENABLED=false` | 复用现成入口，不装 kube-vip |
| **无 VIP 可用** | `KUBE_VIP_ENABLED=false`，其余默认 | 同"标准"：**节点侧仍高可用**；外部入口 = 首 master |

> ⚠ **同网段跑多套集群时必须各用不同 `K8S_API_VIP` / `METALLB_POOL`** —— 两边 kube-vip 抢同一地址时，
> 客户端到 VIP 的流量会随机落到另一套集群（TLS 报 `x509: certificate signed by unknown authority`，
> 2026-09-29 实机事故）。诊断命令见 [05-operations.md](05-operations.md) §3。

---

## 文档索引

| 文档 | 内容 |
|---|---|
| [01-current-state.md](01-current-state.md) | **现状分析**：实机取证，入口链路逐层证据、证书 SAN、ipvs、南北/东西向、单点清单 |
| [02-kubespray-native-lb.md](02-kubespray-native-lb.md) | **kubespray 原生方案**：nginx/haproxy 静态 Pod 剖析、入口推导链、两条启用路线、离线要求、实测故障数据 |
| [03-comparison.md](03-comparison.md) | **三方案对比**：逐方案单点故障清单、与 kubeadm/RKE2/云厂商最佳实践对照、反模式清单 |
| [04-decision.md](04-decision.md) | **决策与实施**：选型记录、配置模型、代码改动清单、迁移手册、验收标准、残留风险 |
| [05-operations.md](05-operations.md) | **运维手册**：查看配置/进程/链路的命令全集、故障演练步骤、排障决策树 |
| [06-implementation-plan.md](06-implementation-plan.md) | **实施计划**：逐任务单（含实作更正与提交范围 `cac86e4..a7509d9`），供追溯 |
| [07-kube-vip-upstream-assessment.md](07-kube-vip-upstream-assessment.md) | **kube-vip 收编评估**（2026-09-28）：为什么把静态 Pod 写入权交还上游、与本规划的逐条满足性对照、验收进度与两处同日缺陷 |

相关既有文档：

- [../kube-vip-api-ha.md](../kube-vip-api-ha.md) — kube-vip 的**实现细节**（两阶段、脑裂事故、决策 D1-D7、**§19 收编**）。本组文档是入口高可用的**总体方案**，两者互补。
- [../cluster-architecture.md](../cluster-architecture.md) — 集群网络与存储总览
- [../troubleshooting.md](../troubleshooting.md) — 三.10 / 三.11 记录了 kube-vip LB 模式的静默失效
