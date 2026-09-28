# kubespray 补丁层(cubestack-patches)

我们对上游 kubespray 树的源码改动,凡**不能**用配置(inventory/extra-vars)表达的,一律固化成本目录下的 `.patch`
文件 —— 升级(kubespray 换树)时按序重放即可,不再"直接改树、升级必丢"。

- 基线:纯净上游 **v2.28.0**(`git clone --depth 1 --branch v2.28.0`)。
- 每个 patch 是"**纯净树 → 我们的树**"的净差;`patch -p1` 前向打 = 重放,**`-R` 反打干净 = 与当前树一致**。
- 每条改动的"原因 / 上游吸收判据 / 上游化"三项写在 **patch 文件头的注释块**里(本 README 的表格是摘要,
  以 patch 头为准);判据用于升级时跑"这个补丁是否已被上游吸收、可以退休"的检查(设计 §3.5)。

## 补丁清单(7 处)

| 补丁 | 目标文件 | 一句话原因(丢了会怎样) | 上游吸收判据 | 上游化 |
|---|---|---|---|---|
| `01-download-container-mkdir.patch` | `roles/download/tasks/download_container.yml` | `download_force_cache`(离线备料)上传镜像前先建目标目录;丢了则目标父目录不存在时 `synchronize` 上传失败, 离线备料中断 | 上游上传任务前自建目标目录(或上传任务容忍目录缺失) | 建议提 PR(通用离线健壮性; 非 §3.5 首批) |
| `02-client-kubeconfig-mode.patch` | `roles/kubernetes/client/tasks/main.yml` | kube artifacts dir 权限 `0750 → 0777` —— 部署容器内非 root 用户要读 kubeconfig;丢了则非 root 用户读不到, 依赖 kubectl 的步骤权限被拒 | 上游不再硬编码 0750(改成可配置变量或默认放宽) | 不提(本环境特有; 0777 对上游默认场景是安全面倒退) |
| `03-kubeadm-fix-apiserver-stat.patch` | `roles/kubernetes/control-plane/tasks/kubeadm-fix-apiserver.yml` | 改 component kubeconfig 的 server 字段前先 `stat` 探测文件是否存在;丢了则文件缺失时 `lineinfile` 直接报错、play 中断 | 上游该文件出现 kubeconfig 存在性守卫(stat / `is exists`) | 建议提 PR(通用幂等健壮性; 非 §3.5 首批) |
| `04-kubeadm-setup-san.patch` | `roles/kubernetes/control-plane/tasks/kubeadm-setup.yml` | SAN 检查块前先 `stat` 探测 `apiserver.crt`, 只在证书存在时才比对 SAN;丢了则 kubeadm 已运行但证书缺失时读证书硬失败、play 中断 | 上游 SAN 检查块自带 `apiserver.crt` 存在性守卫 | 建议提 PR(通用幂等健壮性; 非 §3.5 首批) |
| `05-apps-meta-registry-order.patch` | `roles/kubernetes-apps/meta/main.yml` | `kubernetes-apps/registry` 由 metallb **之前**挪到**之后** —— registry 的 LB VIP 依赖 metallb 先就位(`registry_service_type=LoadBalancer` 时);丢了则 registry 的 VIP 一直 pending | 上游 `meta/main.yml` 中 registry role 已排在 metallb 之后 | 不提(本环境特有: 我们把 registry 以 LoadBalancer 暴露; 上游默认 ClusterIP) |
| `06-metallb-crd-race.patch` | `roles/kubernetes-apps/metallb/tasks/main.yml` | 裸金属新集群首装 metallb 的 CRD 注册竞态(Established 等待 + controller `rollout restart` + apply 重试);丢了则池子 CR 不被 controller 处理, LB 永远分不到 VIP | 上游该文件出现 `Established` 等待或 apply `retries` | **建议提 PR**(§3.5 首批上游化项; 见 `docs/kubespray-upgrade.md` 的"待上游化"清单) |
| `07-download-yml-k8s-cluster-group.patch` | `roles/kubespray_defaults/defaults/main/download.yml` | `dnsautoscaler` / `metrics_server` 镜像的下载组补 `- k8s_cluster`(原仅 `kube_control_plane`; 闸门见 `roles/download/tasks/main.yml` 的 `group_names \| intersect(download.groups)`);丢了则 worker 不下载这两个镜像, 离线节点上组件起不来 | 上游这两个条目 `groups` 含 `k8s_cluster` | 不提(会改变上游默认下载面: 全部节点都下载; 本环境离线自持所需) |

> 本目录 7 个补丁 = spec §2.2 表的第 4、5、6、8、9、10、11 行(其余 4 行不在本目录,见下节)。

## 不在本目录的 4 处改动(别重复两套)

1. **机制 A(2 处)**:`playbooks/cluster.yml` / `playbooks/scale.yml` 的 4 行
   `import_playbook: patch-playbooks/cubestack-*.yml`,以及 `patch-playbooks/` 目录本身,
   由 `cubestack-offline.sh` 的"**内嵌内容重建**"机制负责(**树里没有就在部署时写进去**);
   本目录**不**含这两个文件,否则会变成两套互相打架的来源。
2. **已作废(1 处)**:`playbooks/ansible_version.yml` 的 `maximal_ansible_version: 2.17 → 2.18`
   —— v2.32.0 要求 ansible ≥2.19、<2.20,我们这处 2.17→2.18 的上限已无意义,**升级时随树丢弃,不迁移**。
3. **手工项(1 处)**:`roles/kubernetes/control-plane/tasks/kubeadm-secondary.yml`
   (VIP / SAN / advertise-address 相关 18 行)—— 打 v2.32 时会有 6 处 hunk 冲突,**不生成 patch**,
   由 Task 5 人工重写后单独固化。

## 如何重放与自检

```bash
cd deployments/kubespray/kubespray                       # 树的根(补丁 -p1 的相对基准)
for p in ../cubestack-patches/*.patch; do                # 反打干净 = 补丁描述的就是"现状 − 纯净树"
  patch -p1 -R --dry-run < "$p" >/dev/null 2>&1 \
    && echo "✅ 可反打: $(basename "$p")" || echo "❌ 对不上: $(basename "$p")"
done
```

换树后前向重放的正确性判据:**纯净 v2.28.0 + 按序前向打分 == 我们的树(逐字节)**。
(本次 7 处均已逐字节验证通过;后续升级脚本 `cubestack-patch-apply.sh` 按同样口径实现 `--check`。)

## §3.3 "能下沉就下沉"判定结论

- **metallb 竞态修复(06)不能下沉**:竞态修复的时序在 role 内部(apply manifest 与 apply pools **之间**),
  移到我们自己的脚本里就失去意义 —— 故保留为补丁(结论出自设计 §3.3)。
- **05 不能下沉**:角色执行顺序写在 `meta/main.yml` 里,只能在树内改。
- **01 / 03 / 04 不能下沉**:守卫/建目录必须发生在 role 任务的执行点(目标主机、循环内),外部脚本无从插入。
- **07 保留为补丁**:形式上是 `defaults` 变量,理论上可从 inventory 覆盖,但覆盖路径深且脆弱,不值得。
- **02 是唯一的"可下沉候选"(未实施,记录备考)**:我们的部署模块可在 client role 之后对
  kubeconfig 目录 `chmod 0777`,从而**删掉这个补丁**;本次任务只做"导出",未改模块,记入后续收敛项。

## 已知的文档偏差(本次导出自审发现,供修订 spec 用)

- spec §2.2 第 8 行把 `kubeadm-setup.yml` 的改动记作"`kube_vip_address` 进证书 SAN 等 **14 行**";
  实际净差**只有** `apiserver.crt` 存在性守卫(**+12 行**):`sans_kube_vip_address` 在 v2.28.0 上游**已有**
  (纯净树 `kubeadm-setup.yml` 第 28/48 行与我们的树逐字相同)——即"进 SAN"那部分早已上游化,勿再当作我们的改动。
- spec §2.2 第 4 行记作"+8 行",实际 +9 行(数值漂移,不影响语义)。
- spec §3.5 的示例头写 `04-metallb-crd-race.patch`;本目录的最终命名以实施计划 Task 1 Step 1 为准为
  `06-metallb-crd-race.patch`(前缀 01–07 是**补丁层的顺序号**,不等于 §2.2 的表行号;对照见上表说明)。
