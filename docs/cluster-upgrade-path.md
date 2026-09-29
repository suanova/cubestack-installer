# 集群原地升级(upgrade)—— 接口预留 + 设计伪代码(未实现)

> **状态:未实现,仅预留接口与设计。** 2026-09-28 用户定案:"`--fresh` 是覆盖安装;升级作为未来的新 feature,
> 可以预留出接口或者伪代码"。
> 本文是该 feature 的设计草案,实现前不要对外承诺。

## 0. 为什么不能"重跑一遍"就当升级

实测(2026-09-28,容器 a,mxgpu 集群):节点上残留 **k8s 1.32.5 + etcd 3.5.16**,目标是 **1.35.8 + etcd 3.6.14**,
默认全量运行 / `deploy-cluster.sh --fresh` 都会失败 —— 因为 `--fresh` 只清**本仓库的断点状态**,不清节点上的旧集群,
kubespray 于是按【升级】处理,撞两道**上游硬闸**:

| # | 硬闸 | 证据 |
|---|---|---|
| ① | etcd 3.5(**<3.5.26**)不能直跳 3.6 | `roles/etcd/tasks/clean_v2_store.yml:9-13`:"You need to upgrade etcd to 3.5.26 or later before upgrade to 3.6";注释写明否则 3.6 会 `panic: detected disallowed v2 WAL` |
| ② | kubeadm **不允许跨小版本**升级 | kubeadm 自身约束;1.32→1.35 必须逐个小版本 |

⇒ **覆盖安装**(换掉整集群)和**原地升级**(保业务、逐版本爬)是两件事,前者已实现(见下文),
后者就是本 feature。

## 1. 已实现的"覆盖安装"路径(供对照)

```bash
# ① 清掉节点上的旧集群(不可恢复: etcd 数据 / 工作负载全删; 有 10s 可中断倒计时 + 必须 --yes)
cd /opt/cubestack-installer/deployments/kubespray && sudo ./cubestack-offline.sh reset <集群名> --yes
# ② 正常全量部署(etcd 以钉值 v3.6.14 全新安装, 不经过任何"升级"路径)
#    在部署容器里跑 deploy-cluster.sh 即可
```
`06_k8s_deploy.sh` 已加**部署前预检**:读到旧集群小版本 ≠ 目标小版本时 fail-fast 并直接打印上面的命令
(此前要跑 6 分钟才在 etcd 关卡上失败)。

## 2. 预留给未来的接口(名称/语义先定,避免将来返工)

```text
cubestack-offline.sh upgrade <集群名> [--to <k8s 版本>] [--etcd-bridge <版本>] [--check] [--yes]
  --check    只做升级可行性预检(版本阶梯/镜像与离线件是否齐/etcd 现状), 不做任何改动
  --yes      真正执行(默认 dry-run, 列计划)
deploy-cluster.sh --upgrade [--to <版本>]        # 同义包装(与 --fresh 并列)
```
约定:
- **幂等 + 断点续跑**:每一步(一个小版本 / etcd 桥版本)完成后写状态,可中断续跑;
- **每一步都可验收**:升级后跑 `--steps verify_k8s_base`(待建)断言 apiserver/etcd/CNI 健康;
- **默认 dry-run**:不带 `--yes` 只打印计划与风险点(与 `reset` 的显式确认风格一致);
- **不碰数据面业务**:CRD/operator(ceph/rook、metax、lws…)各自有独立升级路径,本 feature 只负责 k8s 基座;
- **离线件**:每一步用到的二进制(逐小版本的 kubelet/kubeadm/kubectl、etcd 桥版本)必须先在
  `deployments/offline-files/kubespray/` 内(命名与 download role 的 dest 一致),缺件即停。

## 3. 设计伪代码(实现时照此展开)

```text
upgrade(cluster, target=cluster.conf 的 K8S_VERSION, bridge_etcd=3.5.33):
    1. 预检 --check
       cur = 首个 master 上 kube-apiserver 静态 Pod 的镜像 tag      # 1.32.5
       阶梯 = [cur..target) 逐小版本                                   # [1.33, 1.34, 1.35]
       断言: 每一级的二进制都在 offline-files/, 缺失 → 停并列出缺件
       断言: 集群健康(apiserver /healthz, nodes Ready, etcd 三成员健康)
    2. etcd 大版本先行(若 cur_etcd < 3.6 且 target 的 etcd ≥ 3.6):
       a. 升到 bridge_etcd(≥3.5.26, 如 3.5.33) —— 走正常 etcd role(它会做 v2 store 清理)
       b. 校验: etcd 三成员健康 + `etcdctl endpoint status` 版本一致
       c. 再升到目标 3.6.x(此时上游 clean_v2_store 的前置已满足)
    3. 逐个小版本升 k8s:
       for v in 阶梯:
           ansible-playbook upgrade-cluster.yml -e kube_version=v ...   # kubespray 的原生升级入口
           验收: kubelet 版本 / nodes Ready / 控制面 Pod / CNI / API /healthz
           失败 → 停在该断点(状态文件), 打印"续跑 / 回滚"两条路
    4. 收尾:
       - 入口与 SAN: 若入口地址集合变化, 按两阶段流程处理(docs/kube-vip-api-ha.md §7)
       - 部署机 kubeconfig: client 证书轮换策略
       - 组件面: 提示 operator(ceph/metax/lws)各自的升级动作(不在本 feature 内)
    5. 回滚(每步前记录):
       - kubeadm 不支持降级 ⇒ 回滚 = 还原该步之前的 etcd 快照 + 节点快照(需先做备份, 见 reset 的替代)
       - 因此 --check 阶段必须显式声明"回滚窗口"与备份点
```

## 4. 前置备料(实现时先补齐)

| 备料 | 现状 |
|---|---|
| 逐小版本的 kubelet/kubeadm/kubectl | ❌ 只有钉值那一套(1.35.8) |
| etcd 桥版本 tar(≥3.5.26, 推荐 3.5.33) | ⚠ 2026-09-28 已下载到 `/tmp/etcd-3.5.33-linux-amd64.tar.gz`(sha256 前缀与树内 checksums 一致),**未入库** —— 实现本 feature 时再放 `offline-files/kubespray/` |
| `upgrade-cluster.yml` 的离线可用性 | ❓ 未验证(它同样吃 download role 缓存) |

## 5. 与"覆盖安装"的取舍

| 场景 | 走哪条 |
|---|---|
| 测试/可重建集群, 或跨 ≥2 个小版本 | **覆盖安装**(`reset --yes` + 全量部署)—— 简单、可预期、无版本阶梯 |
| 生产集群、保业务、跨 1 个小版本 | 未来: 原地升级(本 feature) |
| 只换补丁版本(1.35.8 → 1.35.9) | 未来: 原地升级的最小形态(无阶梯, 风险最低) |
