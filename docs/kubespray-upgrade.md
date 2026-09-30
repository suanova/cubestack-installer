# kubespray 升级 SOP 与历次记录(稳定路径)

> **一句话**: 本文件是**与版本无关**的 kubespray 升级入口 —— 换树 = 取纯净树 + 换树 + 重放补丁层 + 自检,
> 机械步骤由 `cubestack-kubespray-upgrade.sh <tag>` 执行、**在需要判断处停下**;每次升级完, 第 9 步在本文 §2 追加一条记录。

- **管什么**: `deployments/kubespray/kubespray`(vendored 树)的**整体换树升级**;树内不做手工改动, 我们对上游的改动一律走补丁层。
- **入口脚本**: `deployments/kubespray/cubestack-kubespray-upgrade.sh <tag> [--root DIR] [--tree-src DIR] [--no-fetch]`(取树 / 备份 / 换树 / 退休判定 / 重放, 8 步)
- **补丁层**: `deployments/kubespray/cubestack-patches/*.patch` + 重放器 `deployments/kubespray/cubestack-patch-apply.sh`(`--apply` / `--check` / `--check-retired` / `--list`,退出码 0/1/2)
- **版本专属文档**: `docs/kubespray-v<tag>/`(设计 / 计划 / 人工下载清单)—— 本文件只放**与版本无关**的流程与记录
- **首条记录**: v2.28.0 → v2.32.0(2026-09-28,见 §2)

---

## 1. 升级 SOP(九步 + 实际命令)

### 1.1 入口:一条命令

```bash
cd /home/supperadm/cubestack-installer
K8S_VERSION=v1.35.8 bash deployments/kubespray/cubestack-kubespray-upgrade.sh v2.32.0 --tree-src /tmp/kubespray-2.32
```

- `<tag>` = 目标 kubespray tag(**唯一位置参数**);`--tree-src` = 本机已备好的**纯净树**(离线/演练路径,首选);
  不带 `--tree-src` 且不带 `--no-fetch` 时会联网 `git clone --depth 1 --branch <tag>`(部署机通常不可达 → 用 `--tree-src`)。
- `K8S_VERSION=<ver>` 环境变量 = **人工确认"本次要换到该 k8s 版本"**。不带它时脚本读 `cluster.conf` 的钉子;
  该值必须落在新树的 `kubelet_checksums` 表内,**否则脚本在 [4/8] 停下(rc=2)**。
  ⚠ 环境变量**只是本次声明**:正式钉子要同步改 `cluster.conf` 与 `cluster.conf.example`(见 §1.3 铁律 1)。
- 退出码:**0** = 换树 + 退休判定 + 重放全绿;**1** = 重放有 CONFLICT(停下点名文件);**2** = 参数/环境/前置错误(含版本门、脏工作区、取树失败)。
- ⚠ `--root` 默认 = 脚本所在目录(即**仓库内真树**),一次忘了 `--root` 的调用就是真换树;演练请把根放在仓库**外**(如 `/tmp/up-rehearsal`),此时 tag 备份会安全跳过。

### 1.2 九步(照 design §3.4;括号内为入口脚本对应步)

| 步 | 动作 | 实际命令 | 谁做 |
|---|---|---|---|
| 0 | 读历次记录 + 补丁层的"可能已可退休"清单 | 本文 §2;`deployments/kubespray/cubestack-patches/README.md`(含"已退休(1 处,别再加回来)"小节) | 人 |
| 1 | 取目标 tag 的**纯净树**;核 `galaxy.yml` 版本 + 核 k8s 钉子在不在该树的 `kubelet_checksums` 表里 | 联网机 `git clone --depth 1 --branch <tag> https://github.com/kubernetes-sigs/kubespray.git /tmp/kubespray-<ver>` → 拷入;核验由入口 **[3/8]+[4/8]** 自动执行(版本不符或 k8s 不在表内即 `exit 2`,并打印该 tag 支持的范围) | 脚本(停下让人确认) |
| 2 | 备份:旧树打 tag + 记内容指纹 | 入口 **[2/8]** 自动:`git tag kubespray-<旧版本>-cubestack`(打在"包含 `--root` 的那个仓库"里)+ 打印旧树 git tree 对象与回退命令;查看:`git tag -l 'kubespray-*'` | 脚本 |
| 3 | 换树(保留 `inventory/local` + `patch-playbooks/` + `.venv/`,剔除 `.git`/`.github`/`.gitlab-ci*` 等顶层点文件) | 入口 **[5/8]**;换树后自检 `inventory/sample` 已随新树刷新、`patch-playbooks/` 指纹未变 | 脚本 |
| 4 | 重放补丁层(三态:APPLY / SKIP 已在位 / **CONFLICT 停下点名**) | `bash deployments/kubespray/cubestack-patch-apply.sh --root deployments/kubespray/kubespray --apply`(入口 **[7/8]** 代跑;默认 `--root` 就是那棵树,可省略) | 脚本 |
| 5 | 处置冲突:人工把改动**重做到新树** → 同步更新对应 `.patch` 与 README | 改完 `git add <部署根>` + `git commit`(见铁律 3),再重跑入口脚本 | 人 |
| 6 | 退休判定(试判"这个补丁是否已被上游吸收") | `bash deployments/kubespray/cubestack-patch-apply.sh --root deployments/kubespray/kubespray --check-retired`(入口 **[6/8]**,**必须先于 --apply**,见铁律 2) | 脚本 |
| 7 | 版本面:核 `cluster.conf` 的钉子 vs 上游表值(命令见 §1.4) | 与 `.../roles/kubespray_defaults/defaults/main/download.yml` 等的表值逐字对照;`check-modules.sh` ⑯(版本一致性断言)落地后自动报差异 | 脚本 + 人 |
| 8 | 回归:静态 / 补丁 / 树 diff / ~~渲染器对拍~~(2026-09-28 收编后**废止**,见 §6) / 离线缺口 / 实机 | 见 §6 回归清单 | 脚本 + 人 |
| 9 | 记录:在本文 §2 追加一条(旧→新 tag、k8s/插件版本变化、冲突与处置、踩的坑、**新增的可上游化补丁**) | 照 §2.1 的格式 | 人 |

### 1.3 七条铁律(每条都踩过或差点踩)

1. **`K8S_VERSION` 环境变量优先,且必须在新树的 `kubelet_checksums` 表内**。不带它时脚本读 `cluster.conf`, 而 `cluster.conf` 的钉子常常还没更新 → 直接停在 [4/8] 版本门(rc=2)。它只是**本次声明**, 正式钉子仍要落进 `cluster.conf` 与 `.example`,否则下次部署退回旧钉子。
2. **`--check-retired` 必须在 `--apply` 之前**(顺序是硬要求,重放器头部有同一句)。退休判定的判据是"这棵树已经等于我们打过之后的样子",只有**刚换完的纯净树**上跑才有意义;反过来(打完再跑)恒报 RETIRE,分不清"上游吸收了"与"我们刚打的"。
3. **换树后要重跑入口脚本?先 `git add` + `git commit` 把换树结果落盘**。换树会改写成千上万个**已跟踪**文件,入口 [1/8] 的全仓库工作区门会把你挡下;落盘范围 = **整个部署根**(仓库内 = `deployments/kubespray`),**不只是树** —— 冲突处置改的 `cubestack-patches/*.patch` 在树外,漏了就白改。
4. **树 diff 必须加 `--no-dereference`,并过滤 `patch-playbooks`**。树内 `contrib/terraform/*/group_vars`、`extra_playbooks/inventory` 等是指向 `inventory/` 的**相对符号链接**,默认 diff 会跟着展开、报出几十行假差异;`patch-playbooks/` 是我们自持目录(上游不带),会显成 `Only in <树>:` 行,容易被下次升级的人误判。完整命令见 §1.4。
5. **`--check-retired` 在"目标文件被上游删除"时会误报 KEEP**。反打不上 ≠ 上游未吸收(文件都没了, 自然反打不上)。这类目标必须**人工判去向**(随上游丢弃 / 迁到新机制),不能靠脚本的 RETIRE/KEEP 结论。
6. **换树必须保留 `patch-playbooks/`**(用户明确要求)。它是 `cubestack-offline.sh` 的 `ensure_*_play` 注入的 5 个 play 的载体, 而机制**只在文件缺失时**才从**内置副本**重建 —— 其中 `cubestack-registry.yml` / `cubestack-single-node.yml` 连内置副本都没有;且内置副本是**旧版**(install-packages play 内置 110 行 vs 树内 157 行)→ 丢了 `patch-playbooks/` 会**静默退化**。入口脚本已把它加进保留集,并在换树后按**文件数 + 内容指纹**复核。
   ⚠ 注:那 4 行 `import_playbook: patch-playbooks/...` **不**做成补丁、也不写进仓库树 —— 由机制在部署时按锚点注入(单一来源)。
7. **换了 ansible 大版本,必须依新 `requirements.txt` 重建 `.venv`**。换树**有意保留** `.venv/`(它是裸机路径的 ansible 运行环境),但里面那套 ansible 是**旧门**的产物 —— 实测 v2.28 的 venv 是 `ansible-core 2.16.19`,而 v2.32 的 `playbooks/ansible_version.yml` 断言 `2.19.0 ≤ ansible < 2.20.0`。陈旧 venv 会**顶掉** CLI 镜像里预装的新 ansible(`cubestack-offline.sh` 的 `ensure_venv` 只判目录在不在,不会重建),部署跑**第一个 play** 就硬失败。入口 **[5/8]** 换树后会读新树的 `minimal_ansible_version` 与 `.venv` 实测值比对,**过旧即停住(rc=2)**并打印修法:
   ```bash
   rm -rf deployments/kubespray/kubespray/.venv
   python3.11 -m venv deployments/kubespray/kubespray/.venv        # ⚠ 见下: 必须是 ≥3.11 的解释器
   deployments/kubespray/kubespray/.venv/bin/pip install -r deployments/kubespray/kubespray/requirements.txt
   # 或者:直接 rm -rf .venv/ 走 CLI 镜像里预装的 ansible(容器路径就是这条)
   ```
   ⚠ **8. 换了 ansible 大版本往往同时抬高 Python 下限, 要连镜像一起换**。实测 v2.32:
   `requirements.txt` 钉 `ansible==12.3.0`(= ansible-core **2.19.x**), 而它**在控制端**硬要求
   **Python ≥3.11** —— ubuntu 22.04 自带 `python3` 是 **3.10**, 于是:
   · **CLI 镜像**:`python3 -m pip install -r requirements.txt` 直接失败
     (`Ignored … 12.3.0 Requires-Python >=3.11` / `No matching distribution found`);
     修法是镜像里装 `python3.11`(deadsnakes;jammy universe 那个是 3.11.0~rc1 的 RC 版)并让 ansible 走它,
     见 `Dockerfile-cli-base` 的 "Python 3.11(deadsnakes)" 段(2026-09-30 起 python3.11/ansible 都在 base 层)。
   · **裸机路径**:`ensure_venv` 已改为**优先挑 `python3.12`/`python3.11`**(挑不到才回退 `python3`),
     宿主需先装一个 ≥3.11 的解释器;`.venv_wheels/` 缓存也要用 3.11 重出(cp311 的 cryptography/bcrypt)。
   ⇒ 升级前先跑 `grep -m1 '^ansible==' <新树>/requirements.txt` 并核对它的 `Requires-Python`。

### 1.4 命令备查

```bash
# 树 diff(回归判据):⚠ 过滤器按"你给的路径原样"匹配 —— 必须在 deployments/kubespray 目录内
#   用裸相对路径 kubespray 跑;若用全路径参数,输出是 "Only in deployments/kubespray/kubespray: …",
#   那条 grep 就成了空转(patch-playbooks / .venv 照样留在结果里),等于没过滤。
#   (用子 shell 包住, 不影响本代码块里其余命令的相对路径)
( cd deployments/kubespray && diff -rq --no-dereference --exclude=.git kubespray /tmp/kubespray-<ver> \
    | grep -v '^Only in kubespray: \(inventory/local\|cubestack-patches\|patch-playbooks\|\.venv\)' )
# 若必须从仓库根跑, 过滤器换成路径无关正则:
#   | grep -vE '^Only in .*kubespray: (inventory/local|cubestack-patches|patch-playbooks|\.venv)'
# 预期输出(14 行)= ① 7 行 `Files … differ`(= 全部补丁目标文件)② 1 行
#   `File …/inventory/local/group_vars is a directory while … symbolic link`(已知项:我们保留的真实目录
#   vs 上游符号链接, 不是内容差异 —— 它不以 `Only in` 开头, 过滤器从来不管它)
#   ③ 6 行 `Only in /tmp/kubespray-<ver>: .<点文件>`(被剔除的顶层点文件, 属预期)

# 补丁层自检:全在位则静默、rc=0;缺位打印 MISSING 并 rc=1
bash deployments/kubespray/cubestack-patch-apply.sh --check; echo "rc=$?"
bash deployments/kubespray/cubestack-patch-apply.sh --list        # 只列补丁文件名

# 版本面:把下面的输出与上游表值逐字对照(表值在 vendored 树的 download.yml / vars 里)
grep -nE '^(K8S_VERSION|CALICO_VERSION|ETCD_VERSION|COREDNS_VERSION|PAUSE_VERSION|DNS_NODE_CACHE_VERSION|METRICS_SERVER_VERSION|CPA_VERSION)=' \
  deployments/config/cluster.conf deployments/config/cluster.conf.example

# 静态校验(含 ⑮ 补丁在位 + 两个离线回归套件)
bash deployments/scripts/tools/check-modules.sh

# 树怎么进部署容器(容器 CLI 重跑部署时必看):
#   ⚠ 同步工具(sync-to-container.sh)**不搬 kubespray 树** —— 那条 DIRS 路径是 `rm -rf` + 整拷,
#     会连容器内的 inventory/ 与 .venv/ 一起删掉(有害); 逐文件列整棵树又太大。
#     它只同步 cubestack-patches/ + 两个入口脚本, 并在步骤 5 **核对**容器内 kubespray/galaxy.yml
#     的版本与仓库那份: 不一致 → 醒目告警 + 计入不一致计数(工具不会替你换树)。
#   → 两条正路(二选一):
#     ① 容器内换树(与仓库同一套脚本/补丁层):
#          sudo docker exec -it <容器> bash
#          cd /opt/cubestack-installer/deployments/kubespray
#          K8S_VERSION=v1.35.8 bash cubestack-kubespray-upgrade.sh v2.32.0 --tree-src <容器内纯净树>
#     ② 重建 CLI 镜像(树是 COPY 进镜像的), 再用新镜像起容器。
```

---

## 2. 历次升级记录

> 每完成一次升级, 在这里**追加**一条。模板 = §2.1 的小节结构。

### 2.1 v2.28.0 → v2.32.0(2026-09-28)

| 项 | 值 |
|---|---|
| 旧 → 新 tag | `2.28.0` → **`2.32.0`** |
| 备份 tag | `kubespray-2.28.0-cubestack`(打在仓库内,指向换树前的提交);旧树 git tree 对象 `78c9e24419c7a1cb5ca34e3974ccceeca09673b4` |
| 执行命令 | `K8S_VERSION=v1.35.8 bash cubestack-kubespray-upgrade.sh v2.32.0 --tree-src /tmp/kubespray-2.32` |
| 提交 | `15be89b`(换树 + 补丁 6 重放 / 1 退休 / 1 新增)+ `0947ece`(恢复 `patch-playbooks/` 并加进保留集 + 补丁 08 补第 5 处 gate + 树 diff 过滤加 `patch-playbooks`);⚠ 2026-09-30 分支历史按阶段合并(73→13), 原 4 个 SHA(`d1352de`/`88e8100`/`e45afe0`/`20df940`)折入这两个提交 |
| 结果 | `EXIT=1`,`[7/8]` 停在 CONFLICT **1 处**(补丁 03)→ 人工处置(退休)后 `--check` **rc=0** |
| 树 diff | `diff -rq --no-dereference --exclude=.git kubespray /tmp/kubespray-2.32` = **16 行,全部有意**:7 个补丁目标文件 `differ` + 6 个被剔除的顶层点文件 + `inventory/local/group_vars`(我们的真实目录 vs 上游符号链接)+ `patch-playbooks/`(我们自持,上游不带)+ `.venv/`(ansible 运行环境);无 `inventory/sample/**` 差异(= 已随新树刷新);无 `*.orig`/`*.rej` 残留 |

**版本面变化**

| 组件 | 旧(v2.28.0 树 / 我们的钉子) | 新(v2.32.0 树) | 落地状态 |
|---|---|---|---|
| k8s 钉子 | `1.32.5` | **`v1.35.8`** | 本次以 `K8S_VERSION` 环境变量**声明**;`cluster.conf`/`.example` 的落钉子属"版本面"子项(T11)—— **本记录落笔时 `cluster.conf` 仍是 `v1.32.5`**,下次全量部署前必须落地 |
| multus | 4.1.0 | 4.2.2 | 树默认已到 4.2.2;我们的 `MULTUS_IMAGE_TAG` 仍 `snapshot-thick` → 钉 `v4.2.2-thick` 属插件落地子项 |
| metallb | 0.13.9 | 0.13.9(不变) | 安装仍走上游 role;我们的 4 处竞态修复在补丁层(06) |
| kube-vip | `kube_vip_image_tag: v0.8.9` | **1.0.3** | 树默认已到 1.0.3;我们的 `KUBE_VIP_VERSION` 仍 `v0.8.9` → 属插件落地子项(渲染器需同步) |
| LVP | 未登记 | 2.5.0 | **新登记**:接线(开关默认关)属子项,本次未做 |
| NFD | 未登记(0.16.4) | 0.19.0 | **新登记**:同上 |
| ansible | `maximal_ansible_version` 2.17→2.18(树内改动) | 要求 ansible-core ≥2.19 <2.20 | 旧改动**随树作废**,不迁移(v2.32 的上限已覆盖它) |

> k8s 不支持"跨表回退":`1.32.5` 只在 v2.28.0(1.30.0–1.32.5)与 v2.30.0(1.32.0–1.34.3)的表里;v2.32.0 表是 **1.34.0–1.36.4**。见 §5。

**补丁层结果(三态)**

```
  APPLY   01-download-container-mkdir.patch
  APPLY   02-client-kubeconfig-mode.patch
  CONFLICT 03-kubeadm-fix-apiserver-stat.patch → roles/kubernetes/control-plane/tasks/kubeadm-fix-apiserver.yml
  APPLY   04-kubeadm-setup-san.patch
  APPLY   05-apps-meta-registry-order.patch
  APPLY   06-metallb-crd-race.patch
  APPLY   07-download-yml-k8s-cluster-group.patch
  重放结果: APPLY 6 / SKIP 0 / CONFLICT 1(退出码 1)
  [6/8] 退休判定: RETIRE 0 / KEEP 7      ← 其中 03 是"目标文件被删"造成的误报(见 §1.3 铁律 5)
```

**冲突与处置(1 处)**

- `03-kubeadm-fix-apiserver-stat.patch` → **退休(删除)**。依据不是"上游吸收", 而是**改动对象消失**:目标文件
  `roles/kubernetes/control-plane/tasks/kubeadm-fix-apiserver.yml` 自 **v2.31 起被上游整文件删除**(v2.28/v2.30 还在), 它守卫的 task
  (`Update server field in component kubeconfigs`)在 v2.32 全树 grep 零命中 → 按"随上游丢弃"处置, `.patch` 删除并在补丁层 README 记入
  "已退休(1 处,别再加回来)"。**退休不重排前缀号**(补丁 03 位置留空号, 新增项续编 08),以免与既有记录对不上。
- 其余 6 个 APPLY **全部干净但带行偏移**(01 −1 / 02 0 / 04 +1 / 05 +2 / 06 +1 / 07 −71 行), 因此留下 5 个 `*.orig`
  (脚本自动检测 + 清理,并把清单打给人)。**决策:不做上下文刷新** —— 语义与落点逐处核对无变化,偏移记在此处备考;下次再遇偏移可做一轮刷新。

**新增补丁 08(本次唯一新增)**

`08-kubeadm-secondary-join-stat.patch` —— 原为"树内手工项"(次 master 的 join 幂等性), 本次按 **v2.32 基线**重做并固化。要点:

- 语义:"是否已 join 成功"以 **`admin.conf` 是否存在**为准,不只看 kubeadm 的标记文件(它实为 `/var/lib/kubelet/config.yaml` 的 stat, kubelet 配置早于 join 完成即落盘)。
- 范围:**5 处 gate**(4 处 join 前置任务 + **join 任务自身**)。只改前 4 处会"先 `kubeadm reset` 却不重新 join",比不打补丁更糟 —— 这是固化时补上的(评审裁决;见补丁头的 `# v2.32 备注:` 行)。
- 上游 v2.32 把该文件**重构**过(join 由单 task 改 `block`+`rescue`、新增 `Wait for new control plane nodes to be Ready`、任务顺序重排)→ 重做时**不能照抄行号**,按语义落位。

**补丁计数(健康指标)**:7 → **7**(退休 1 + 新增 1)。新增的 08 不是新漂移,而是"把原先裸奔在树里的手工项收进补丁层";净零要按此读(设计 §3.5:计数不降反增时必须在日志里写清为什么)。

**踩的坑(编号对应 §1.3)**

- 铁律 1 命中:`cluster.conf` 此刻仍是 `v1.32.5`,不带 `K8S_VERSION=v1.35.8` 会直接撞版本门(rc=2)。
- 铁律 5 命中:退休判定对补丁 03 误报 `KEEP`,必须人工判去向。
- 铁律 4 命中:树 diff 不加 `--no-dereference` 会假性爆炸;`patch-playbooks/` 会显成 `Only in` 行,必须一起过滤。
- 铁律 6 命中(差点事故):换树一度把 `patch-playbooks/` 丢掉(机制只在文件缺失时用**旧版**内置副本重建,其中 2 个 play 连内置副本都没有)→ 已恢复并把该目录加进保留集,换树后按文件数 + 指纹复核。
- 另:`patch` 在**带偏移命中**时留下 `*.orig`(本次 5 个),若不清会被 `git add -A` 提交进树;入口脚本已自动清理。

**本次新增的可上游化补丁**:08(建议提 PR, 非首批 —— 见 §3)。
**遗留待办(本次未做)**:`cubestack-offline.sh` 内嵌的 install-packages play 是**旧版 110 行** vs 树内 157 行 → 与铁律 6 是同一风险的两半,待把内嵌副本同步成树内版本。

---

## 3. 待上游化清单

**先做首批**:`06-metallb-crd-race.patch` 的 4 处竞态修复 —— **裸金属新集群首装 metallb 的 CRD 注册竞态是通病**,值得进上游。
4 处 = ①CRD `Established` 等待 + controller `rollout restart`(同一 hunk)②③④ pools / layer2 / layer3 三处 `kubectl apply` 加重试。
合入后**从补丁层删除该条**并在 §2 的当次记录里写明。

**其余(照抄各补丁头的"上游化:"字段)**

| 补丁 | 上游化 | 吸收判据(摘要) |
|---|---|---|
| `01-download-container-mkdir.patch` | 建议提 PR(通用离线备料健壮性;其后候选) | 上传任务前自建目标目录,或上传任务容忍目录缺失 |
| `02-client-kubeconfig-mode.patch` | **不提**(本环境特有:部署容器内非 root 读 kubeconfig;0777 对上游默认场景属安全面倒退) | 上游不再硬编码 0750 |
| `04-kubeadm-setup-san.patch` | 建议提 PR(通用幂等健壮性;其后候选) | SAN 检查块自带 `apiserver.crt` 存在性守卫 |
| `05-apps-meta-registry-order.patch` | **不提**(本环境特有:我们把 registry 以 LoadBalancer 暴露) | 上游 meta/main.yml 中 registry 已排在 metallb 之后 |
| `06-metallb-crd-race.patch` | **★ 首批:建议提 PR** | 上游该文件出现 `Established` 等待或 apply `retries` |
| `07-download-yml-k8s-cluster-group.patch` | **不提**(会改变上游默认下载面:全部节点都下载) | 上游这两个条目 `groups` 含 `k8s_cluster` |
| `08-kubeadm-secondary-join-stat.patch` | 建议提 PR(通用幂等健壮性:次 master 失败重跑;其后候选) | 上游出现 `admin.conf` 存在性守卫,或把"是否已 join"判据换成 admin.conf |
| ~~`03-kubeadm-fix-apiserver-stat.patch`~~ | **已退休**(改动对象被上游删除,非吸收 —— 见 §2.1) | — |

> 提 PR 前后都在本表更新;判据细节以各 `.patch` 文件头的 `# 上游吸收判据:` 行或补丁层 README 为准。

---

## 4. 演练记录(T3:两次靶子,2026-09-28)

两次演练**全部在 `/tmp` 副本上**进行(`--root /tmp/up-rehearsal*`), **演练期间**仓库内真树零写入(真仓库无演练留下的 `kubespray-*` tag、内容指纹与基线逐字节相同)。

| 靶子 | [4/8] 版本核验 | [6/8] 退休判定 | [7/8] 重放 | 退出码 |
|---|---|---|---|---|
| `v2.30.0` | 通过(1.32.5 ∈ 1.32.0–1.34.3) | RETIRE 0 / KEEP 7 | **APPLY 7 / SKIP 0 / CONFLICT 0** | **0** |
| `v2.31.0`(默认跑) | **不通过**(1.32.5 ∉ 1.33.0–1.35.4) | 未执行(门在换树**之前**) | 未执行 | **2** |
| `v2.31.0`(**诊断跑**,越门:声明 1.35.4) | 通过(1.35.4 ∈ 1.33.0–1.35.4) | RETIRE 0 / KEEP 7 | **APPLY 6 / CONFLICT 1**(补丁 03) | **1** |

**各树 k8s 支持范围(实测 `kubelet_checksums` 表)**:v2.28.0 `1.30.0–1.32.5` / v2.30.0 `1.32.0–1.34.3` / v2.31.0 `1.33.0–1.35.4` / v2.32.0 `1.34.0–1.36.4`。

**冲突清单(逐条)**:仅 1 处 —— `03-kubeadm-fix-apiserver-stat.patch` → `roles/kubernetes/control-plane/tasks/kubeadm-fix-apiserver.yml`;
真因已核:**v2.31.0 起该文件被上游整文件删除**(全树 `grep -rn kubeadm-fix-apiserver` 零引用),不是上下文漂移 → 处置是"判去向",不是重做。

> ⚠ **两步演练的数字不可直接对比**:v2.30.0 的 `7 APPLY / 0 CONFLICT / KEEP 7` 是**旧补丁集(不含补丁 08)** 的成绩。
> 补丁 08 按 **v2.32 基线**编写, 对 v2.30.0 靶子 dry-run 会 `Hunk #5 FAILED`(预期 —— v2.30 的 `kubeadm-secondary.yml` 还是旧结构),
> 与 v2.31.0 诊断跑的 `APPLY 6 / CONFLICT 1` 也不能相减出"补丁 08 有问题"。读这两行只取一件事:**工具链在纯净树上能重建出可工作的树, 并输出正确的冲突清单与退休建议**。

**演练的价值(暴露并修掉的真 bug, 已固化成 §1.3 的铁律)**

- **F1**(首轮 rc=2 中止):保留 `inventory/` 与 rsync 的"目录 vs 符号链接"冲突(上游 `inventory/local/group_vars` 是符号链接, 我们树里是真实目录)→ 保留粒度收窄为 `inventory/local`, 上游模板 `inventory/sample` 随新树刷新。
- **F2**:rsync 排除项未锚定到树根 → 连**树内被 git 跟踪**的 `contrib/terraform/aws/.gitignore` 等 4 个文件一起丢 → 排除项一律加前导 `/`。
- **F3**:`patch` 在带偏移命中时留下 `*.orig` → 脚本检测 + 清理 + 把清单打给人(它同时是"该补丁上下文已漂移"的信号)。
- **F4**:`--check-retired` 在"目标文件被上游删除"时误报 KEEP(→ 铁律 5)。
- **F5**:`diff -rq` 默认跟随符号链接 → 回归判据必须 `--no-dereference`(→ 铁律 4)。

**演练也顺带证明**(真树零变化的证据):演练 tag 只出现在 `/tmp` 自建仓库里;真仓库 `git tag -l 'kubespray-*'` 在演练期间为空;真树内容指纹与基线逐字节相同。

---

## 4.5 与"版本目录"的关系(2026-09-30 起)

**两条路线互不依赖**, 不要混用:

| | 全新部署(选版本) | 升级(换版本) |
|---|---|---|
| 入口 | `deploy-cluster.sh --profile <版本>` / `KUBESPRAY_VERSION` | `cubestack-kubespray-upgrade.sh <tag>`(本 SOP) |
| 动什么 | 只读: 档案 → 版本目录(资产) → 树(仓库树或物化树) | **原地换仓库树** + 重放补丁层 |
| 前提 | 该版本的**版本目录**在场(树 tar + 资产 + 档案) | 目标 tag 的纯净树(联网或 `--tree-src`) |

- 已装 v2.28 的集群要上 v2.32 → 走**升级路线**(换仓库树), 不是"再选一次版本"。升级后集群处于
  仓库树版本, 后续部署沿用该版本档案。
- `versions/<版本>/`(物化树)与版本目录**不参与升级**: 升级的风险在在跑的集群与补丁重放,
  不在资产获取 —— 让两者耦合只会叠加失败面。
- 版本目录机制**不改本 SOP 的任何一步**; 换树后若要刷新该版本的 `tree.tar.gz`, 用
  `cubestack-version-dir.sh repack <版本> --from-root <部署根>`(打包格式变更/补丁更新时)。
- 版本目录的产出/选版/下载/校验: 见 [`kubespray-versioning/README.md`](kubespray-versioning/README.md)。

## 5. 回退

按**回退粒度**从小到大,四条边界要分清:

1. **回退到换树前的整体状态(树 + 补丁层)** —— ⚠ **树与补丁层是耦合的,必须成对回退**:备份 tag 恰好同时含"v2.28.0 树 + 当时的补丁层
   (01–07,**含 03、无 08**)",所以回退要连补丁层一起:

   ```bash
   git checkout kubespray-2.28.0-cubestack -- deployments/kubespray   # 树 + cubestack-patches/ 一起回到换树前(tag 现指 1f7d231; 旧 f0342b7 见 2026-09-30 历史合并说明, 内容逐字节相同)
   ```
   只回退 `deployments/kubespray/kubespray`(树)而留着**现行**补丁层会**对不上**:现行层少了 v2.28 树需要的 03,又多了按 v2.32 基线写的 08
   (对旧树的 dry-run 会 `Hunk #5 FAILED`)。回退后还有两步**不在 checkout 范围内**,要手工做:
   ① **`K8S_VERSION` 钉子必须手工改回旧值**。`deployments/config/` 在本 pathspec 之外,且 `cluster.conf` **未入 git**
   (被 .gitignore 忽略, 连整仓库 checkout 也恢复不了),受跟踪的 `cluster.conf.example` 同样不在 `deployments/kubespray/` 里 ——
   **checkout 不会碰这两个文件**。按本文档回退到 v2.28.0,就要把 `cluster.conf` 与 `.example` 的 `K8S_VERSION` 手工改回 `v1.32.5`
   (旧树表 1.30.0–1.32.5);漏了这一步 = v2.28.0 的树配 1.35.8 的钉子(1.35.8 ∉ 旧树表)→ 下次部署/验证会中断。
   ② 自检 `cubestack-patch-apply.sh --check`(rc=0)与 `check-modules.sh`(⑮ 绿)。
   演练/无 git 环境没有 tag 可依,只能靠 §2 记录的**旧树内容指纹** + 源树副本(补丁层同理)。
2. **补丁层整层不应用** —— 换树后跳过 `--apply`(或在 `--apply` 前把 `cubestack-patches/*.patch` 移走)。
   代价:树仍是**能跑的上游 v2.32**,但**缺我们的修复**(metallb 竞态 / registry 顺序 / 离线备料建目录 / SAN 与 join 守卫 …… 共 10 处, 以 `cubestack-patches/README.md` 清单为准)→ 裸金属新集群首装成功率下降。
   ⚠ 此状态下 `cubestack-patch-apply.sh --check` 必然报 `MISSING`(rc=1), `check-modules.sh` ⑮ 会红 —— **这是预期信号,不是故障**;要恢复只需把 `.patch` 放回并 `--apply`。
3. ⚠ **k8s 版本变量不能单独回退到 1.32**。v2.32 的 `kubelet_checksums` 表范围是 **1.34.0–1.36.4**,表里**没有 1.32.x**:
   把 `cluster.conf` / `.example` 的 `K8S_VERSION` 单独改回 `v1.32.5` 会让升级入口停在 [4/8] 版本门(rc=2), 后续部署也会因"表里无此版本"而出问题。
   **回退 k8s 数字必须连同树一起回退**:树按第 1 条回退到旧 tag,钉子则**手工**改回 `v1.32.5`
   (checkout 恢复不了 `cluster.conf` —— 原因见第 1 条 ①),或把钉子定在 1.34/1.35/1.36 区间内。旁证(实测):

   | 树 | kubelet 表范围 | 1.32.5 |
   |---|---|---|
   | v2.28.0 | 1.30.0 – 1.32.5 | 在(且是上限) |
   | v2.30.0 | 1.32.0 – 1.34.3 | 在 |
   | v2.31.0 | 1.33.0 – 1.35.4 | **不在** |
   | v2.32.0 | 1.34.0 – 1.36.4 | **不在** |
4. **已部署集群的回退边界**:已经用 v2.32(1.35.8)部署过的集群**不能靠改 `cluster.conf` 降级** —— kubespray 不支持 k8s 降级。树/补丁层的回退只对**尚未部署**的状态有效;已上线集群只能"重建/另装",不是回退。

---

## 6. 附录:入口脚本 ↔ SOP 映射 + 回归清单

**入口脚本 8 步与 SOP 步号的对应**

| 入口步 | SOP 步 | 说明 |
|---|---|---|
| [1/8] 前置 | 0 | 树/重放器/补丁目录/`rsync`/`patch` 存在性;工作区必须干净(脏则 rc=2) |
| [2/8] 备份 | 2 | 旧树 tag + 内容指纹(演练根不在 git 仓库时跳过) |
| [3/8] 取树 + [4/8] 核验 | 1 | 版本号 == tag;k8s 钉子必须在该树 `kubelet_checksums` 表内 |
| [5/8] 换树 | 3 | 保留 `inventory/local` + `patch-playbooks/` + `.venv/` |
| [6/8] 退休判定 | 6 | **先于** [7/8](理由见铁律 2) |
| [7/8] 重放 | 4 | CONFLICT 停下(rc=1),并区分"上下文漂移"与"目标文件消失" |
| [8/8] 后续人工步骤 | 5 / 7 / 8 / 9 | 脚本只打印,不代劳 |

**回归清单(design §8 的六层)**

| 层 | 命令 / 动作 | 判据 |
|---|---|---|
| 静态 | `bash deployments/scripts/tools/check-modules.sh` | 全绿(⑮ 补丁在位为绿;既有的 KUBE_VIP 红项除外) |
| 补丁 | `bash deployments/kubespray/cubestack-patch-apply.sh --check` | rc=0(全部在位) |
| 树 | 见 §1.4 的 `diff -rq --no-dereference …`(**须在 `deployments/kubespray` 目录内跑**,过滤器才生效) | 14 行 = 7 行 `Files … differ`(= 全部补丁目标文件)+ 1 行 `inventory/local/group_vars`(目录 vs 符号链接,已知项)+ 6 行目标树独有的顶层点文件(剔除项) |
| ~~渲染器~~ | ~~自持 manifest 渲染器 vs 新树模板对拍(如 kube-vip)~~ **已废止(2026-09-28 收编)**: kube-vip 清单由上游自己渲染 ⇒ 无对拍对象;改由实机套件验收 —— `--steps verify_kube_vip`(含漂移演练)+ `verify_api_ha` | kube-vip Pod Running / VIP 唯一绑定 / healthz 通过 |
| 离线 | `images.manifest` 新镜像 / `offline-files/` 备料 | 缺口清单为空 |
| 实机 | 全新集群全量部署 | 部署成功 |

> 注:升级入口 [8/8] 的输出里引用的 `docs/kubespray-upgrade.md §8` 指的就是**本节**(脚本定稿时本文档尚未编号;本文档的章节编号以本文件为准)。
