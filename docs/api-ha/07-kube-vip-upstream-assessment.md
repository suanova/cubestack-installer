# 07 · kube-vip 上游能力评估与收编(2026-09-28)

> 本文回答一个此前**从未被评估过**的问题(见 §5):"**使用 kubespray 自身集成的 kube-vip,是否满足
> [`docs/api-ha/`](./README.md) 最初的规划?**" 结论与随之落地的"收编"改动一并记于此。
> 相关:`../kube-vip-api-ha.md`(kube-vip 本体的设计与决策 D1–D7)、`04-decision.md`(组合方案)。

## 1. 一句话结论

**我们其实早就在用上游那份 kube-vip** —— 镜像(`kube-vip:v1.0.3`,取自 `download.yml:261`)、清单内容
(我们的渲染器**直接读树内 `roles/kubernetes/node/templates/manifests/kube-vip.manifest.j2`**)、
以及"`kube_vip_address` 非空即自动进 apiserver 证书 SAN"(`control-plane/tasks/kubeadm-setup.yml:49`,
**无 when 条件**、与 `kube_vip_enabled` 无关)全都是上游机制。
真正的差异只有一处:**"谁写 `/etc/kubernetes/manifests/kube-vip.yml`"**。
2026-09-28 起改为**上游写**(收编),自持渲染器删除。

## 2. 为什么当初要自持(以及为什么现在可以撤)

`lib-common.sh` 曾在 `addons.yml` 里**恒写 `kube_vip_enabled: false`**("单一写入者契约"),理由写在
当时的函数头注释里:**双写者**并存 —— 上游对**首台** master 把清单的 hostPath 渲染成 `super-admin.conf`、
其余用 `admin.conf`(`roles/kubernetes/node/tasks/loadbalancer/kube-vip.yml:36-45` 的 set_fact),
而我们的渲染器恒用 `admin.conf` ⇒ **同一路径被两方轮流改写 → 每次全量运行清单变两次 → Pod 重启两次**。

关键更正(本次调查得出):**上游那份分叉本身是稳定的** —— 它按 `inventory_hostname ==
kube_control_plane[0]` 判定, 同一节点每次渲染结果相同。抖动来自"两个写入者", 不是来自分叉。
⇒ 把写入权**完整**交给任一方都是稳定的单写者;交给上游可以少维护 ~430 行
(渲染器 128 + 其离线测试 31 + 模块内渲染/分发/断言段 ≈269)。

## 3. 上游能做什么 / 不能做什么(逐条带证据)

| 能力 | 上游 | 证据 |
|---|---|---|
| 指定 VIP 地址、网卡、子网、DNS 模式 | ✅ | `node/defaults/main.yml:64-67`;模板 `kube-vip.manifest.j2:21-35` |
| 控制面 VIP + ARP + 租约选举 + 可调租约 | ✅ | 同上 `:63,68-72,82-86` |
| **只在控制面**(worker 永不参与) | ✅ | `node/tasks/main.yml:19-24` |
| VIP 进 apiserver 证书 SAN | ✅ **自动**(只要 `kube_vip_address` 非空) | `control-plane/tasks/kubeadm-setup.yml:49` |
| 渲染时机 | 在 `Install Kubernetes nodes`(**kubeadm init 之前**) | `playbooks/cluster.yml:25-32` |
| 服务 LB(kube-vip 充当 Service 的 LoadBalancer) | ❌ **半成品**:只往静态 Pod 塞 env,RBAC/SA/cloud-provider 全无,上游文档自称需手工步骤 | `kube-vip.manifest.j2:47-58`;`TREE/docs/ingress/kube-vip.md:38-40` |
| **开关关闭时清理** | ❌ 全树没有删除 `kube-vip.yml` 的任务 | `node/tasks/main.yml:19-24`(只决定 import 与否) |
| 校验 `kube_vip_address` 非空 | ❌ 会照渲染 `address: ""` | 模板 `:103-104` |
| 上游 CI 覆盖 | ❌ 树内 `tests/` 零命中 | — |
| **入口(`/etc/hosts` 域名解析)** | ❌ v2.32 树里**已无写入者**(老 `0090-etchosts.yml` 不存在) | `roles/kubernetes/preinstall/tasks/` 无该文件 |
| VIP 自动推导(探测空闲地址) | ❌ 只收字面量 | — |
| 关闭时的 fail-closed 护栏、两阶段切换 | ❌ | — |

## 4. 收编后的职责边界(谁负责什么)

| 环节 | 收编后归属 |
|---|---|
| 渲染静态 Pod 清单、镜像、租约、SAN | **kubespray**(`kube_vip_enabled` / `kube_vip_address` 等由 `addons.yml` 驱动) |
| 开关语义 ↔ inventory 映射 | 我们(`lib-common.sh#update_kube_vip_addons_yml`,按 `KUBE_VIP_ENABLED` 写真实值) |
| VIP 推导(显式优先 / .210 起探测 / 跨轮复用防漂移) | 我们(`kube_vip_derive`) |
| 入口与 `/etc/hosts`、域名解析 | 我们(`03_k8s_hosts.sh` / `10_api_local_lb.sh`) |
| 关闭时清理 + fail-closed 护栏 | 我们(`09_kube_vip.sh#kube_vip_cleanup`) |
| 收敛核验(清单在场/vip_nodename/唯一性/healthz) | 我们(`09_kube_vip.sh` + `08`/`11` verify) |
| `kube_proxy_strict_arp` 前置 | 我们(`sync-kubespray-config.sh`:kubespray 的 kube-vip 任务在 ipvs 集群上硬要求它) |

## 5. 与最初规划的满足性对照

`docs/api-ha/` 的三案对照(①本地代理 / ②kube-vip / ③HAProxy+Keepalived)**从未把"改用上游内置 kube-vip"
列为候选** —— 02 篇只把 kube-vip 当作与 ① 互补的"外部侧"层,机械引用
(`02-kubespray-native-lb.md:44,260,272,381-383`),不评估其内部实现。因此严格说:文档只能证明
"若干条目**依赖自研实现**",不能证明"上游做不到"。逐条对照如下:

| 规划条目 | 收编后 |
|---|---|
| G3 外部/管理侧稳定入口、G8 用 cluster.conf 指定 VIP + 开关控制 | ✅ 仍满足(kube-vip 组件级能力,与谁写清单无关) |
| G2 节点侧 HA、G5 无 VIP 降级、G6 复用环境已有 LB | ✅ 不受影响(与 VIP 实现正交,走 `API_LOCAL_LB_ENABLED` / `API_EXTERNAL_ADDR`) |
| 7 条硬校验中的 ①④⑤⑥⑦、check-modules ⑬ 断言 | ✅ 保留(不依赖 VIP 实现) |
| 证书 SAN 含入口地址(验收 A6 / `11` 的 ⑦) | ✅ 满足 —— SAN 由上游按 `kube_vip_address` 自动写入(收编前也一样) |
| 两阶段入口切换 | ⚠ **保留**,但风险面已在 D1 落地后缩小:节点侧走本地代理后,只有**外部/管理客户端**依赖 VIP |
| 自持渲染器 / "单一写入者契约" / vip_nodename 逐台渲染断言 | ➖ **撤销**(上游渲染;vip_nodename 由上游按 `inventory_hostname` 保证,我们保留**读回哨兵**) |

## 6. 遗留与验收(本次未做)

- **实机端到端**:集群上 `KUBE_VIP_ENABLED=true` 跑一次 → 三台 master 清单在场、VIP 恰好绑一台、healthz 通过。
  → **2026-09-28 晚已生效一部分**,进度见 §8.1。
- **幂等验收(撤契约的正当性证据)**:连跑**两次**同开关部署 → kube-vip Pod 的 `RESTARTS` 不增长、
  清单 sha256 不变。这正是当年立契约要防的那件事,必须实测。
- **关闭验收**:`KUBE_VIP_ENABLED=false` 重跑 → 清单被删、VIP 从所有 master 网卡释放;入口仍指 VIP 时**必须拦停**。
- **换代一次性抖动**:收编后既有集群的清单会换代一次(首台 master 变 `super-admin.conf`)⇒ Pod 重启一次,属预期。

## 7. 相关改动清单(2026-09-28,同一批)

`deployments/scripts/lib-common.sh`(契约反转)、`modules/02_k8s/09_kube_vip.sh`(瘦身)、
`modules/02_k8s/08_verify_kube_vip.sh`(①b 双写者哨兵)、`tools/k8s/sync-kubespray-config.sh`
(`strict_arp` 前置确保)、`tools/check-modules.sh`(⑪-A 反向 / ⑪-C 去渲染器 / ⑮ 套件清单)、
新增 `tools/tests/test-update-kube-vip-addons.sh`(映射表 + 幂等)、删除
`tools/k8s/render-kube-vip-manifest.py` 与其测试。

---

## 8. 追记(2026-09-28 晚 ~ 09-29):实机状态、两处同日缺陷、一条被重新打开的风险

> 本节只记**增量**:设计细节与逐条论证在 §1–§5,实现细节在 `../kube-vip-api-ha.md` 第 19 节。

### 8.1 §6 的验收进度

| 验收项 | 状态 |
|---|---|
| 实机端到端 | ✅ **已生效**:`/etc/kubernetes/manifests/kube-vip.yml` 在场且由上游渲染、`mxgpu-3-28` 上 kube-vip 容器 Running、**VIP `10.66.3.240` 已实际绑在节点网卡上** |
| 幂等(**撤契约的正当性证据**) | ❌ **仍未验** —— 连跑两次部署、`RESTARTS` 不增长、清单 sha256 不变 |
| 关闭态清理 | ❌ 仍未验(清单删除 + VIP 从所有 master 释放 + 入口仍指 VIP 时拦停) |
| 换代一次性抖动 | ⚠ 未单独观测(与上面同批) |

⚠ 在"幂等"一条实测通过之前,契约是"**已撤,但撤销的正当性尚未实测**"的状态。

### 8.2 收编暴露的两处缺陷(均已修,实机复核)

1. **`kube_vip_is_bound()` 恒判"未绑定"**(主机名 SSH,部署容器解析不了节点名)⇒ `api_entry_ip()`
   永远回落首个 master、VIP 自动推导路径全废。修法=新增 `master_ips()`。
2. **两套集群共用同一个 `K8S_API_VIP`** ⇒ `kubectl` 间歇 `x509: certificate signed by unknown authority`。
   修法=`sync_kubeconfig` 末校验连取 4 次 VIP 证书指纹,不一致即判"被多个 apiserver 共用"并给处置。

两处的完整取证、影响面与验证方式见 [`../kube-vip-api-ha.md` §19.5](../kube-vip-api-ha.md)。

### 8.3 一条被收编重新打开的风险(原 R2)

收编把"没有东西在 `kubeadm init` 之前写 manifest"这个前提又拆了 ⇒ §3 表里"渲染时机=init 之前"
这一行的代价重新出现(首台 master 的 manifest 指向尚不存在的 `super-admin.conf`)。
暴露面受两阶段约束(阶段一入口是 master01,没人需要 VIP),**未实测**;
详见 [`../kube-vip-api-ha.md` §19.6](../kube-vip-api-ha.md)。
