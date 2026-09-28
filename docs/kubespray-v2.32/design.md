# kubespray v2.32.0 升级 + 插件集成(设计 / spec)

> **一句话**: 把 vendored kubespray 从 **v2.28.0** 升到 **v2.32.0**(它的默认插件版本正是
> multus 4.2.2 / metallb 0.13.9 / kube-vip 1.0.3 / LVP 2.5.0 / NFD 0.19.0),三个既有插件按
> "能交给上游就交给上游、有硬理由才自持"逐个体检;新增 LVP/NFD 的**接线**(默认关);
> 并把"我们对上游的 11 处改动"从"直接改树"改成**可重放的补丁层**——升级从此 = 换树 + 一条命令 + 自检。

- 状态: 设计已逐条与用户确认(2026-09-28);实施计划见 `plan.md`(writing-plans 产出)
- 分支: `feat/api-ha-local-lb`(本轮工作建议在新分支 `feat/kubespray-v2.32` 上进行)

---

## 0. 决策记录(已确认)

| # | 决策 | 依据 / 代价 |
|---|---|---|
| D0 | 目标 = **kubespray v2.32.0** | 用户给的五个版本全部命中 v2.32.0 默认值(下表);v2.30/v2.31 的 NFD 是 0.16.4 |
| D1 | k8s 钉 **1.35.8** | v2.32 支持 1.34/1.35/1.36;**1.33 实际不可用**(`etcd_supported_versions` 无 1.33 条目、补丁表只剩 1.33.0)。1.35.8 = 生命周期中段、生态兼容面比 1.36 宽。实施前先核 metax operator / rook v1.20 / ceph-csi 对 1.35 的支持声明 |
| D2 | 补丁机制 = **补丁层 + 幂等重放 + 自检**(§3) | 现状是"直接改树",其中 9 处没有任何恢复机制(metallb 那 4 处竞态修复就这么裸着)——升级必静默丢 |
| D3 | multus **保持自持**(thick),只把 tag 钉成 `v4.2.2-thick` | 上游仍是 thin 模式、不建 NAD、不等 CRD Established、资源 100m/90Mi 硬顶(v2.30 与 v2.32 都核过);我们的 thick+NAD+CRD 等待+放宽资源是净收益。版本数与上游 4.2.2 同源,只差变体 |
| D4 | metallb **继续用上游 role 安装**,竞态修复进补丁层 | 分工已正确(我们模块只做就绪校验);上游 v2.32 仍未纳入那 4 处修复(`Established`/`rollout restart`/`retries` 命中数 = 0) |
| D5 | kube-vip **保持自持渲染器 + 单写入者契约**,升到 1.0.3 | 上游静态 Pod 只给控制面、首台 master 用 super-admin.conf → 与我们渲染结果逐字节不一致(每次全量跑被改两次、pod 重启两次);D1/D4(不开 LB)结论不变 |
| D6 | LVP 2.5.0 / NFD 0.19.0 **接入 kubespray 内置 addon**,`cluster.conf` **默认 disable** | 上游开关 `local_volume_provisioner_enabled` / `node_feature_discovery_enabled` 默认即 false;我们只做接线(登记+同步开关+离线口径),**不自研模块** |
| D7 | 镜像一律走 **`images.manifest` → GitHub Actions → Harbor → `harbor-save-images.sh` → `offline-files/*.tar`** | 用户明确:部署机无法访问 docker.io;上游可达性只在 CI 那一段解决(与 `docs/harbor-mirror.md` 的既有设计一致) |
| D8 | 取不到的制品给**人工下载清单** | 用户要求(§7.3) |

---

## 1. 目标与非目标

**目标**
1. vendored 树升到 v2.32.0,且**我们的 11 处改动不丢**(补丁层 + 自检)。
2. k8s 基座升到 1.35.8,连带 calico/etcd/coredns 等按 v2.32 表值对齐。
3. 三个既有插件按 D3/D4/D5 落地;LVP/NFD 按 D6 接线。
4. 离线口径闭环:镜像/二进制/wheel 都能从本机或 Harbor 侧取得,并给出缺口清单。

**非目标**
- 不动单写入者契约、不动 D1/D4(kube-vip 不开 LB)、不动 `KUBE_VIP_CP_DETECT=true` 的既有选择。
- 不做现有集群的 in-place 编排升级(它们由"下次全量部署"自然升级,见 §9 风险)。
- 不给 LVP/NFD 写自研模块或 verify 模块(它们的能力完全来自上游 role)。

---

## 2. 现状与证据

### 2.1 版本对照(vendored v2.28.0 → 目标 v2.32.0)

| 插件 | v2.28.0(现) | **v2.32.0(目标)** | v2.30/v2.31 | 我们的现状 |
|---|---|---|---|---|
| multus | 4.1.0 | **4.2.2** | 4.2.2 | 自持 thick;tag = `snapshot-thick`(**浮动**,要钉) |
| metallb | 0.13.9 | **0.13.9** | 0.13.9 | 上游 role + 我们 4 处补丁 |
| kube-vip | `kube_vip_image_tag: v0.8.9` | **1.0.3** | 1.0.3 | 自持渲染器;`KUBE_VIP_VERSION=v0.8.9` |
| LVP | 2.5.0 | **2.5.0** | 2.5.0 | **未登记** |
| NFD | 0.16.4 | **0.19.0** | 0.16.4 | **未登记** |

k8s 版本面(v2.32 表):支持 1.34/1.35/1.36;**1.33 不可用**;calico 默认 **3.31.7**;etcd(1.35)= **3.6.14**;dnsautoscaler = **1.10.3**;coredns/pause/CNI 等一律**机械抄表**(不手写)。

### 2.2 我们对上游的 11 处改动 + 处置表

> 由 `diff -rq --exclude=.git deployments/kubespray/kubespray /tmp/kubespray-2.28` 得出(11 个文件内容不同 + 3 个我们独有目录;上游独有的是 `.github/.gitlab-ci` 等 dotfile,保持不放)。

| # | 文件 | 我们的改动(实体) | 处置 |
|---|---|---|---|
| 1 | `playbooks/ansible_version.yml` | `maximal_ansible_version` 2.17→2.18 | **作废删除**(v2.32 要求 ≥2.19 <2.20) |
| 2 | `playbooks/cluster.yml` | 插入 4 个 `patch-playbooks/cubestack-*.yml` import | 保留(**机制 A**:`cubestack-offline.sh` 已能内嵌重建,见 §3.2) |
| 3 | `playbooks/scale.yml` | 同上 | 保留(机制 A;dry-run 干净) |
| 4 | `roles/download/tasks/download_container.yml` | +8 行:`download_force_cache` 时先建目标目录 | 保留补丁(离线备料路径) |
| 5 | `roles/kubernetes/client/tasks/main.yml` | kube config 目录权限 `0750 → 0777` | 保留补丁(部署容器内非 root 用户要读 kubeconfig;**必须在补丁里写明理由**) |
| 6 | `roles/kubernetes/control-plane/tasks/kubeadm-fix-apiserver.yml` | +stat 探测 kubeconfig 是否存在(缺文件时不再硬失败) | 保留补丁 |
| 7 | `.../kubeadm-secondary.yml` | VIP/SAN/advertise-address 相关 18 行 | **手工重写**(打 v2.32 时 6 处 hunk 冲突) |
| 8 | `.../kubeadm-setup.yml` | SAN 检查块前加 `apiserver.crt` 存在性守卫(实测净差 +12;**证书 SAN 部分上游 v2.28.0 早就有 `sans_kube_vip_address`(纯净树第 28/48 行),不属本补丁** —— 原表述有误,2026-09-28 按实测修正) | 保留补丁(dry-run 干净) |
| 9 | `roles/kubernetes-apps/meta/main.yml` | `kubernetes-apps/registry` role 的**顺序**调整 | 保留补丁(顺序关键:registry 的 LB VIP 依赖 metallb 先就位) |
| 10 | `roles/kubernetes-apps/metallb/tasks/main.yml` | 4 处竞态修复:CRD `Established` 等待 + controller `rollout restart` + pools/layer2/layer3 apply 重试 | **保留补丁(核心)** |
| 11 | `roles/kubespray_defaults/defaults/main/download.yml` | +2 行:`- k8s_cluster`(镜像下载组) | 复核后保留 |

dry-run 结果(v2.30 树):11 处里 **7 处干净可重放**,4 处需手工 —— 其中 #2 走既有重建机制,#1 直接作废,真正的手工量 = **#7 一处**(+ #11 复核)。

---

## 3. 架构:补丁层(决策 D2)

### 3.1 布局

```
deployments/kubespray/
  kubespray/                      # 树本体 = 纯净上游 v2.32.0(不含 .github/.gitlab-ci 等)
  inventory/cubestack-cluster/    # 我们自持,升级不动
  cubestack-patches/
    README.md                     # 逐条: 改了什么 / 为什么还在 / 上游何时可能吸收 / 失效判据
    01-*.patch … 10-*.patch       # 每处改动一个 patch(标 # 便于对照 §2.2 表)
  cubestack-patch-apply.sh        # 幂等重放入口(--check/--apply/--check-retired, 见 3.2/3.5)
  cubestack-kubespray-upgrade.sh  # 通用升级入口(取树/备份/换树/重放/退休检查, 见 3.4)★ 与版本无关
docs/kubespray-upgrade.md         # 稳定路径: 升级 SOP + 历次升级记录(每次升级第 9 步追加)★ 与版本无关
docs/kubespray-v2.32/             # 版本专属: 本次的设计/计划/人工下载清单
```

> ★ 标"与版本无关"的两处是**为未来同类升级**准备的:下次升级只需读 `docs/kubespray-upgrade.md` 走 SOP、
> 跑 `cubestack-kubespray-upgrade.sh <新 tag>`, 版本专属的具体值改 `cluster.conf` 与 v<tag> 目录下的文档。

### 3.2 脚本接口与幂等

- `cubestack-patch-apply.sh [--check|--apply|--list]`
  - `--apply`:按序打补丁;已打过(反查 `patch -R --dry-run` 成功)则跳过并记 `SKIP`;打不上则**点名冲突文件并退出非 0**(绝不静默、绝不部分成功)。
  - `--check`:只做"是否全部在位"的断言(供部署前 / `check-modules` 调用)。
- **与既有机制的关系**:`patch-playbooks/` 4 件与 `cluster.yml`/`scale.yml` 的 import 行继续由 `cubestack-offline.sh` 的"内嵌内容重建"机制负责(它已经在做,别重复两套);若重建失败或树没打 import,`--check` 同样报错。**其余 7 处**由本补丁层负责。
- 升级流程(写进 README 与 `docs/`):备份旧树 tag → 换树 → `cubestack-patch-apply.sh --apply` → `--check` → `check-modules` → 离线自检。

### 3.3 能下沉就下沉(并入 D2 一起做)

逐条判定"能不能从上游文件里移出来":能移的移到我们自己的脚本/模块(补丁面越小越好)。本次已判定**不能移**的例子:metallb 的竞态修复时序在 role 内部(apply manifest 与 apply pools 之间),移出来就失去意义。判定结论写进 `cubestack-patches/README.md`。

**下沉候选(本次未实施,记为后续收敛项)**:`02-client-kubeconfig-mode.patch`(kube config 目录 0750→0777)可下沉 —— 在我们的模块里于 client role 之后 `chmod`,即可从补丁层删掉这一条。实施它需要先确认"模块的 chmod 时机早于任何消费者"。

### 3.4 可重复的升级流程(SOP,与具体版本无关)

> 目标:**下一次升级(v2.32 → 未来任意 tag)不需要重新发明流程**。机制写在稳定路径 `docs/kubespray-upgrade.md`,
> 版本专属细节留在 `docs/kubespray-v<tag>/`。机械步骤由 `cubestack-kubespray-upgrade.sh <tag>` 执行并**在需要判断处停下**。

| 步 | 动作 | 谁做 |
|---|---|---|
| 0 | 读 `docs/kubespray-upgrade.md` 的历次记录 + `cubestack-patches/README.md` 的"可能已可退休"清单 | 人 |
| 1 | 取目标 tag 的**纯净树**(本机可 `git clone --depth 1 --branch <tag>`;不可达则由联网机取后拷入),核 `galaxy.yml` 版本 + `checksums.yml` 里**有没有我们要钉的 k8s 版本** | 脚本(停下让人确认) |
| 2 | 备份:给旧树打 `kubespray-<旧tag>-cubestack` tag,记录旧树 hash | 脚本 |
| 3 | 换树(保留 `inventory/`;不放 `.github/.gitlab-ci` 等 dotfile) | 脚本 |
| 4 | `cubestack-patch-apply.sh --apply` → 三态:应用 / 跳过(已在位) / **冲突(停下点名)** | 脚本 |
| 5 | 处置冲突:人工重写 → 同步更新对应 `.patch` 与 README | 人 |
| 6 | `--check-retired`:试判"这个补丁是否已被上游吸收" → 输出**建议删除**清单 | 脚本 |
| 7 | 版本面:核对 cluster.conf 的钉子 vs 上游表值(§4.1 的一致性断言直接报差异) | 脚本 |
| 8 | 回归:跑 §8 全清单(静态/补丁/树 diff/渲染器对拍/离线缺口/实机) | 脚本 + 人 |
| 9 | 记录:在 `docs/kubespray-upgrade.md` 追加一条(旧→新 tag、k8s/插件版本变化、冲突与处置、踩的坑、**新增的可上游化补丁**) | 人 |

### 3.5 补丁生命周期管理(让补丁面只减不增)

每个 `.patch` 文件头带元数据(注释块):

```
# patch: 06-metallb-crd-race.patch
# 加入: 2026-09-28(随 v2.28→v2.32 升级迁移)
# 原因: 裸金属新集群首装 metallb 的 CRD 注册竞态(Established 等待 + controller rollout restart + apply 重试)
# 上游吸收判据: roles/kubernetes-apps/metallb/tasks/main.yml 中出现 Established 等待或 apply retries
# 上游化: 建议提 PR(见 docs/kubespray-upgrade.md 的"待上游化"清单)
```

- 每次升级**必经** `--check-retired`;能删就删 —— 这条是"未来同类升级"里最容易省掉、也最该坚持的一步。
- **待上游化清单**:值得进上游的补丁(首批 = metallb 那 4 处竞态修复)提 PR;合入后从我们补丁层删除,记录在升级日志里。
- 补丁计数当作**健康指标**:升级后若补丁数不降反增,要在日志里写清为什么(而不是默默接受漂移)。

---

## 4. 版本面(决策 D1)

### 4.1 cluster.conf §3.3 的 k8s 基座组(整体替换为 v2.32 表值)

| 变量 | 现值 | 新值 | 说明 |
|---|---|---|---|
| `K8S_VERSION` | v1.32.5 | **v1.35.8** | v2.32 的 checksums 里有 |
| `CALICO_VERSION` | v3.29.3 | **v3.31.7** | 表首值 |
| `ETCD_VERSION` | v3.5.16 | **v3.6.14** | 1.35 的查表值 |
| `COREDNS_VERSION` / `PAUSE_VERSION` / `DNS_NODE_CACHE_VERSION` / `METRICS_SERVER_VERSION` / `CPA_VERSION` | … | **机械抄 v2.32 表** | `CPA` 现 v1.8.8 → 表值 1.10.3 |

> 这些变量是**显式钉子**(离线 tar 需要确定 ref),不是"让 kubespray 自己决定";因此每个值都必须与 v2.32 的表逐字一致 —— 建议加一条静态校验(仿 ⑪-C 的"兜底默认一致性"断言)。

### 4.2 ansible 2.19

- v2.32 要求 `ansible-core ≥2.19 <2.20`。
- 落地路径(已查清):`cubestack-offline.sh:161-168` 优先用 **CLI 镜像预装的 ansible**,回退 `.venv_wheels/` 离线装 → 需**重建 CLI 镜像(ansible-core 2.19.x)+ 刷新 wheel 缓存**。
- ⚠ 未决(§11):wheel 从哪台机器取(需能访问 PyPI),是否与 Harbor 同行。

---

## 5. 三个插件的落地改动(决策 D3/D4/D5)

### kube-vip → v1.0.3
- `cluster.conf`:`KUBE_VIP_VERSION` v0.8.9 → **v1.0.3**(该变量注释里的"必须与 kubespray download.yml 一致"重新成立)。
- `images.manifest`:kube-vip tag → v1.0.3(离线 tar 同步刷新)。
- **渲染器 `tools/k8s/render-kube-vip-manifest.py`**:v2.32 模板对 ≥0.9 发 **`vip_subnet`**(不再是 `vip_cidr`),并新增 `bgp_sourceip/sourceif`、metrics 端口、securityContext `drop: ALL` → 渲染器需能求值 `version('0.9.0','>=')` 这类表达式或把变量映射更新;渲染产物必须与 v2.32 模板对拍(**逐台**,沿用既有做法)。
- 不变:`kube_vip_enabled` 恒 false(单一写入者)、`kube_vip_services_enabled=false`(D1)、`kube_vip_lb_enable=false`(D4)、`KUBE_VIP_CP_DETECT` 默认 true、逐台落位 + 脑裂检测。

### multus → 钉 `v4.2.2-thick`
- `MULTUS_IMAGE_TAG` 默认 `snapshot-thick` → **`v4.2.2-thick`**(上游 release workflow 推 `:<版本>-thick` + `stable-thick`,已核)。
- 连带:`images.manifest`、vendored manifest 内两处硬编码 ref、离线 tar、`CUBESTACK.md` 偏离表(写明"与上游 4.2.2 同版本、变体 thick,不用 kubespray role 是有意为之")。
- 自持三件事不动:NAD 示例、CRD `Established` 等待、资源放宽 128Mi/512Mi·500m。

### metallb(0.13.9 不变)
- 安装仍由上游 role 完成;我们的 4 处竞态修复进补丁层(#10)。
- 共用 VIP 注解键名(`metallb.universe.tf/allow-shared-ip`)不变(0.13.x 语义)。

---

## 6. LVP 2.5.0 / NFD 0.19.0 接线(决策 D6,默认 disable)

1. `cluster.conf` + `.example`:
   - `LOCAL_VOLUME_PROVISIONER_ENABLED` / `NFD_ENABLED`,**默认 false**(2026-09-28 定)
   - 版本变量 `LOCAL_VOLUME_PROVISIONER_VERSION=2.5.0` / `NFD_VERSION=0.19.0`(= v2.32 表值)
2. `tools/k8s/sync-addons-config.sh`:新增两行 `set_key local_volume_provisioner_enabled|node_feature_discovery_enabled "(bool …)"`(沿用 metallb 同款写法)。
3. `images.manifest`:登记
   - `registry.k8s.io/sig-storage/local-volume-provisioner:v2.5.0`
   - `registry.k8s.io/nfd/node-feature-discovery:v0.19.0`
   (k8s-base 组 → 离线目录 `offline-files/kubespray/images/`)
4. `PRELOAD_IMAGE_PATTERNS` **四处副本**同步加 token(`local-volume-provisioner`、`node-feature-discovery`)—— 注意 ⑭ 断言四处逐字节一致;`check-image-manifest.sh --kubespray` 会交叉核对。
5. `offline-files/` 对应 README 按仓库规则补。
6. **不加**自研模块/verify;文档(§附录)写清"开关默认关,需要时打开即可,离线 tar 已按清单备好"。

---

## 7. 镜像与离线路径(决策 D7/D8)

### 7.1 固定管道(不可绕)

```
上游(registry.k8s.io / quay.io / ghcr.io / docker.io)
   └─① harbor-sync-images.sh / GitHub Actions(sync-images-to-harbor.yml)
        └─ Harbor: harbor.isuanova.com/mirrors/<注册域>/<路径>
             └─② harbor-save-images.sh(在能连 Harbor 的机器上)
                  └─ deployments/offline-files/<group>/*.tar
                       └─③ 部署模块 skopeo push → 集群内置 registry
```

- **部署机不直连 docker.io/上游**(用户明确)。CI runner 承担"上游可达"这一段——这正是既有设计(`docs/harbor-mirror.md`)的价值所在。
- 两个待定点(§11):① CI 只在 main push 触发 → 合并后自动同步,或先用 `workflow_dispatch` 在本分支手动跑一次;② 浮动 tag(`snapshot-thick` 若无稳定版)由每周定时工作流兜底。

### 7.2 非镜像制品(同样走离线口径)

kubespray 还要下载:`kubelet/kubectl`(dl.k8s.io)、`calicoctl`(GitHub releases)、`etcd` 二进制、CNI 插件、`crictl` 等 —— 这些不进容器镜像清单,但同样需要"联网机取 → 放 `offline-files/kubespray/`"。实施时逐项确认上游可达性。

### 7.3 缺口清单 → 人工下载清单(交付物)

- **产出方式**:manifest/版本改完后,在联网机跑一次
  `harbor-save-images.sh --group <全集>` 并把失败项汇总;必要时加一个只报不拉的 `--list-missing` 小开关(实施时定)。
- **交付物**:`docs/kubespray-v2.32/manual-download-list.md`,逐条给:
  `ref / URL → 目标路径(offline-files/...) → 校验(sha256) → 手动命令示例(docker pull|save / curl)`。
- 同时覆盖 §7.2 的非镜像制品与 §4.2 的 ansible wheel。

---

## 8. 验证计划

| 层 | 做什么 | 判据 |
|---|---|---|
| 静态 | `check-modules.sh`(⑭ 四处一致 / ⑪ 系列)、`check-image-manifest.sh --kubespray` | 全绿(⑪-B 的既有红项除外) |
| 补丁 | `cubestack-patch-apply.sh --check` | 11 处全部在位(含机制 A 的 4 件) |
| 树 | `diff -rq` 我们树 vs 纯净 v2.32.0 | 只剩我们**有意**的补丁(逐条对上 §2.2) |
| 渲染器 | 渲染产物 vs v2.32 模板对拍(逐台,含首台 master) | 逐字节一致 |
| 离线 | tar 齐 + 二进制齐 + wheels 齐 | §7.3 清单为空 |
| 实机 | 全新集群全量部署(k8s 1.35.8);再分别开/关 LVP·NFD 各一次 | 部署成功 + 开关开则装、关则无残留 |

---

## 9. 回退与风险

**回退**:升级前的备份 tag = **`kubespray-2.28.0-cubestack`**(脚本自动打,内容含**树 + 当时的补丁层**);
回退必须**连树带补丁层一起**(`git checkout kubespray-2.28.0-cubestack -- deployments/kubespray`)—— 因为现行补丁层与旧树不兼容(03 已被删、08 打不上旧树)。⚠ `deployments/config/cluster.conf` **不在回退范围且未入 git**,`K8S_VERSION` 钉子要**手工**改回(否则会得到"旧树 + 新钉子"的组合);且 k8s 版本变量不能只改回 1.32 —— v2.32 的表里没有 1.32,必须与树一起退。

**风险**:
1. **现有集群会被升级**:下次全量部署会用 1.35.8(集群 A/B 现在 1.32.5)。若不想动,需在部署前显式改回(不可行,见上)或先只升代码/插件、延后 k8s —— **需在实施前与用户确认升级时机**。
2. **生态兼容**:metax operator / rook v1.20 / ceph-csi 对 k8s 1.35 的支持声明要先核(D1 前置)。
3. `client/tasks/main.yml` 的 0777 放宽要保留理由注释,否则后人会当 bug 改回去。
4. `kubeadm-secondary.yml` 是唯一需要人肉重写的补丁,风险集中于此(v2.32 该文件变化大)。
5. 顺带修正(小):`KUBE_VIP_ENABLED` 在 `cluster.conf` 是 true,而 `.example`/文档写"默认关" —— 本轮一并统一口径。

---

## 10. 子项分解与顺序

| 子项 | 内容 | 依赖 |
|---|---|---|
| ① 升级 + 补丁层 | 换树到 v2.32.0;**通用升级工具链**(`cubestack-kubespray-upgrade.sh <tag>` + `cubestack-patch-apply.sh` + 稳定文档 `docs/kubespray-upgrade.md` 并写入首条记录);补丁层(§3);11 处处置;树 diff 复核 | — |
| ② 插件落地 | kube-vip 1.0.3 + 渲染器;multus 钉 tag;metallb 补丁归位 | ①(补丁层可用) |
| ③ LVP/NFD 接线 | 开关(默认关)+ sync + manifest + PRELOAD 四处 + README | ① |
| ④ 版本面与离线 | k8s 1.35.8 + calico/etcd 等表值;ansible 2.19(CLI 镜像 + wheels);CI→Harbor→tar;缺口清单 | ①②③ 定稿后(清单依赖 manifest) |

每个子项做完即跑 §8 对应层级的验证;④ 的实机验证放最后。

> ★ **子项 ① 的验收里有一条是"未来可复用"**:拿 v2.30.0(或 v2.31.0)当**演练靶子**跑一遍 SOP ——
> 不落地,只验证工具链能从"纯净树 + 补丁层"重建出可工作的树,并**输出正确的冲突清单与退休建议**。
> 下一次升级要是还得靠人肉记忆,这次就算没做完。

---

## 11. 未决项(实施时必须先回答)

> ★ 最终审查(2026-09-28)追加两条**部署前必答**(合并可放行, 但必须进交付说明):
> - **I5 生态兼容**:metax operator / rook v1.20 / ceph-csi × **k8s 1.35** 的支持声明仍未核(D1 自写"实施前先核"却无交付物记录)→ 下次全量部署就会装 1.35.8。
> - **ansible 大版本**:`deployments/kubespray/kubespray/.venv` 实测 **ansible-core 2.16.19**, 而 v2.32 要求 ≥2.19 <2.20 → 裸机路径必须按新 `requirements.txt`(**ansible==12.3.0**)**重建** `.venv`(修复波次已加入口自检 + 文档补充)。
> - **trim 会删 13 个 tar**(Ruling 25 复核确认):新增登记/改钉子后**先读交付说明再跑 trim**, 否则 ceph 组 11 个离线交付 tar + `ubuntu_22.04.tar` + 旧 `nginx_1.27.tar` 会被删。


1. **升级时机**:现有集群 A/B 是否接受"下次全量部署即升到 1.35.8"?若否,本任务拆两步:先在**不换 k8s 版本**的前提下只换树+插件(注:v2.32 的表里没有 1.32,**做不到**——所以真正的折中是"先只做插件与补丁层、k8s 升级另行择期",届时要选定"树停在 v2.28 还是 v2.32 但暂不部署")。
2. **CI 触发方式**:合并到 main 后自动同步,还是先 `workflow_dispatch` 在本分支手动跑一次验证。
3. **ansible wheel 来源**:哪台机器能取 PyPI;是否也放 Harbor。
4. **metax/rook/ceph-csi × k8s 1.35** 的兼容性声明(§9 风险 2)。
5. `snapshot-thick` 是否还有别的消费者(若我们改钉 `v4.2.2-thick`,旧 tar 的清理/替换)。
6. **待上游化补丁是否现在就提 PR**(首批 = metallb 的 4 处竞态修复):提了,下一版就能从我们补丁层删掉一条(§3.5)。
