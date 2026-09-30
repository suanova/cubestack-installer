# kubespray 按版本部署(使用手册)

> 设计见 [`design.md`](design.md)(决策 D1–D8);实施见 [`plan.md`](plan.md)。
> 一句话:**一个开关选定 kubespray 版本 → 该版本的树、离线资产、版本钉子成套生效;升级仍是独立路线。**

---

## 1. 三个概念

| 概念 | 指什么 | 在哪 |
|---|---|---|
| **版本目录** | 一个版本的**自包含**离线资产(+ 预打补丁的树 tar) | `deployments/offline-files/kubespray/<版本>/`(版本名 = 上游 tag 全名, 如 `v2.32.0`) |
| **版本档案(profile)** | 该版本的成套**版本钉子**(k8s/calico/etcd/coredns/… 与配套 operator 版本) | `deployments/config/profiles/<版本>.profile`(随 git 分发) |
| **物化树** | 由版本目录里的 `tree.tar.gz` 解出的可运行树 | `deployments/kubespray/versions/<版本>/kubespray/`(运行期产物, 不进 git/镜像/MinIO) |

```
KUBESPRAY_VERSION=v2.28.0
  ├─ 资产目录  offline-files/kubespray/v2.28.0/     ← 二进制 + images/ + packages/
  ├─ 档案      config/profiles/v2.28.0.profile      ← 选定后**接管** cluster.conf 的版本面变量
  └─ 树        版本 == 仓库树版本 ? 仓库树 : versions/v2.28.0/kubespray(物化)
```

---

## 2. 三种版本档位

| 档位 | 档案入库 | 资产在 MinIO | 用途 |
|---|---|---|---|
| **在库版本** | ✅ | ✅ | 交付/生产(当前:`v2.32.0`) |
| **本地临时版本** | ❌ | ❌(`LOCAL_ONLY` 标记, 上传工具自动跳过) | 验证/应急调试(当前:`v2.28.0`) |
| **仓库当前树** | ✅(同版本档案) | ✅ | 日常开发 |

---

## 3. 常用操作

```bash
# 看在场版本(档位/树 tar/镜像数)
bash deployments/kubespray/cubestack-version-dir.sh list

# 校验某个版本目录(树 tar 指纹 + 档案副本 + images 非空)
bash deployments/kubespray/cubestack-version-dir.sh verify v2.32.0

# 用指定版本部署(等价: 在 cluster.conf 设 KUBESPRAY_VERSION=<版本>)
sudo ./deployments/scripts/deploy-cluster.sh --profile v2.32.0        # 全量
sudo ./deployments/scripts/deploy-cluster.sh --steps k8s_deploy --profile v2.32.0

# 看路径推导(排障第一招: 资产目录/树/inventory 各指向哪)
bash deployments/kubespray/cubestack-offline.sh paths

# 只下载指定版本的离线件(部署机侧; 不拖别的版本)
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --kubespray-version v2.32.0
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --list      # 看有哪些版本

# 物化(解树到 versions/<版本>/, 幂等)
bash deployments/kubespray/cubestack-version-dir.sh materialize v2.28.0
```

### 版本选择与默认(2026-09-30 口径)

**不指定任何版本参数时, 默认部署"最新版本"** —— 原部署模式不变(默认仍是完整全量流程, 参数语义不变;
实测: 默认与 `--profile v2.32.0` 的模块清单**逐字节一致**)。

选版本的优先级(前两者也算"显式", 会影响"档案缺失是否硬失败"):

| 优先级 | 来源 | 说明 |
|---|---|---|
| 1 | `KUBESPRAY_VERSION`(env / cluster.conf)或 `deploy-cluster.sh --profile <版本>` | 显式指定 ⇒ 该版本档案缺失时**硬失败**(不静默换版本) |
| 2 | 被指向的树(`CUBESTACK_BASE_DIR`/仓库树)的 `galaxy.yml` | 只在未显式指定时生效; "你指哪棵树"比"仓库最新"更接近意图 |
| 3 | **最新版本** = max(仓库树版本, **有入库档案**的版本目录) | 只认有档案的版本:`没有档案 ⇒ 钉子不会被接管`, 拿它做默认会静默错配 |

> ⚠ **本地临时版本(如 v2.28.0)不在默认里** —— 它按 D4 不入库档案, 必须显式 `--profile v2.28.0` /
> `KUBESPRAY_VERSION=v2.28.0` 才用。显式选它时, 档案取自**版本目录自带的 `VERSION.profile` 副本**
> (设计 §3.2 的"自包含副本"; 在库版本两份一致, 由 check-modules ⑱ 逐键断言)。

**档案优先级**:选定档案后, 档案里的版本面变量**接管** `cluster.conf` 的同名值 —— 避免"选了 v2.28
却仍用 v1.35.8 钉子"这种静默错配。要手工钉某一项 → `KUBESPRAY_PROFILE=none`(全部按 cluster.conf,
等价改造前的行为)。

---

## 4. 产出/接入一个新版本(6 步)

```bash
# ① 备好该版本的部署根(含 kubespray/ 与 cubestack-patch-apply.sh; 通常 = 仓库 deployments/kubespray)
#    新版本要先按 docs/kubespray-upgrade.md 的 SOP 换树 + 重放该版本补丁
# ② 造版本目录(预验证补丁在位 → 打包树 → 从树内表机械推导档案骨架)
bash deployments/kubespray/cubestack-version-dir.sh new v2.33.0 \
     --from-root /path/to/deployments/kubespray --k8s-version v1.36.4     # 本地临时版本加 --local
# ③ 备料(镜像走 Harbor 统一源; 二进制/包按该版本树表值取)
sudo bash deployments/scripts/tools/images/harbor-save-images.sh --group k8s-base   # 落点已按版本目录
# ④ 校验
bash deployments/kubespray/cubestack-version-dir.sh verify v2.33.0
bash deployments/scripts/tools/check-modules.sh          # ⑱ 逐版本断言
# ⑤ 档案入库(git)+ 上传 MinIO
git add deployments/config/profiles/v2.33.0.profile && git commit -m "feat(kubespray): v2.33.0 版本档案"
sudo bash deployments/scripts/tools/offline/sync-to-minio.sh
# ⑥ 提 PR(CI 自动跑 18 项静态校验 + 6 个离线套件)
```

> ⚠ `new` 的两条硬闸门:① 该树 `cubestack-patch-apply.sh --check` 必须通过(只打包**已验证**的树);
> ② `--k8s-version` 必须显式给且**在树内 `kubelet_checksums` 表里**(小版本线是人工选择, 树表只是
> "可安装全集")。其余 10 项版本值从树表**机械推导**, 禁手抄。

### 打包格式约定(踩过)

`tree.tar.gz` 的**顶层必须是 `kubespray/` 目录**(与物化目标 `versions/<版本>/kubespray` 同形)。
曾用 `-C 树 .`(内容平铺)⇒ 解出来没有 `kubespray/` 层, 物化幂等判定与 `BASE_DIR/kubespray` 推导全对不上。
打包格式变更后用 `cubestack-version-dir.sh repack <版本> --from-root <部署根>` 重打。

---

## 5. operator 版本目录规范(未来接入用, 设计 D7)

operator **不搞批量搬迁**;凡要"按版本选"的组件,按同一套四条接入:

1. 资产目录 `offline-files/<组件>/<版本>/`(版本名用该组件上游的 tag/版本号全称);
2. 版本开关变量(`<组件>_VERSION`)+ 档案字段(需要与基座成套时写进 `profiles/<基座版本>.profile`);
3. `images.manifest` 落点跟随版本目录(`lib-image-manifest.sh` 的 `image_group_dir`);
4. 本地临时版本打 `LOCAL_ONLY`(上传工具自动跳过), 并让 `tools/offline/trim-offline-files.sh`
   只清理**选定版本**(加 `--version <V>`)。

---

## 6. 升级路线与版本目录的关系(决策 D6)

```
全新部署(选版本) ──► 档案 → 资产目录 → 树 → 安装        ← 两条路线互不依赖
升级(换版本)    ──► cubestack-kubespray-upgrade.sh(原地换仓库树 + 重放补丁, 见 docs/kubespray-upgrade.md)
```

- "v2.28 装的集群要上 v2.32" → 走**升级路线**, 不是"再选一次版本";升级完成后集群处于仓库树版本。
- 版本目录**不参与**升级(升级的风险在在跑的集群与补丁重放, 不在资产获取);升级脚本本次**未改**。

---

## 7. 离线链路(MinIO)与当前兼容期

- 远端结构与本地同构:`offline-files/<组件>/<版本>/…`。
- **只下载指定版本**:`fetch --kubespray-version v2.32.0`(≡ `--sub kubespray/v2.32.0`)。
- 上传:`sync-to-minio.sh` 自动**跳过 `LOCAL_ONLY` 版本**(实测: 干跑与实跑都会点名跳过 v2.28.0);
  `--prune` 存在版本目录时**要求显式 `--force-full-prune`**(全根 `--remove` 会互删各版本)。
- **兼容期(2026-09-30 起, 待测试 + 新 CLI 镜像完成后结束)**:远端同时保留
  ① `kubespray/<版本>/`(新结构)② `kubespray/<扁平旧文件>`(旧 CLI 镜像仍按扁平路径读)
  ③ `kubespray/_superseded-20260930/`(1.32 线旧件的副本)。
  **测试成功、新镜像就绪后再删除 ②③ 并 `--force-full-prune`**(用户口径: 先不 prune)。
- 本地 `/data/offline-files`(容器挂载真身)已与仓库对齐(重排 + 归档, 干跑零差异)。

---

## 8. CLI 镜像契约变更(2026-09-30)

**镜像只含 `deployments/` 代码**(用户口径):不再把 kubectl/helm/skopeo 等离线二进制打进镜像。

- 工具链改由容器**运行期**从挂载的版本目录挂载:镜像内 `/etc/profile.d/50-cubestack-tools.sh`
  (源文件 `deployments/scripts/tools/docker/cli-toolchain-from-offline.sh`)在**登录 shell**启动时
  幂等地把 `<挂载>/kubespray/<版本>/` 下的 kubectl/skopeo/helm 挂到 PATH。
  ⇒ 部署流程用 `bash -lc`(既有文档口径);非登录 shell 需显式 `bash -lc` 或 `source /etc/profile`。
- 构建上下文 `build-cli-context.sh`:无 `bin/`、排除 `kubespray/versions/`(物化树不进镜像),
  实测 218M → **87M(纯代码)**。全量构建得到纯净的 code-only 镜像;增量构建继承基础镜像内容。

---

## 9. 校验与实证(截至 2026-09-30)

- **回归套件** `tools/tests/test-kubespray-version-select.sh`(33 条断言, 离线无 root):变量推导 /
  档案接管与逃生阀 / 版本→物化树映射 / 版本目录工具 / 离线链路(sync 源目录、LOCAL_ONLY 跳过、
  prune 拒绝、trim 版本范围、fetch 参数)。挂在 `check-modules.sh` ⑮ ⇒ **每次 PR 都跑**。
- **check-modules ⑱**:逐版本断言 —— 入库档案 ↔ 该版本树表值、在场版本目录 ↔ 档案一致、
  tree.tar.gz 指纹、关键二进制与 `K8S_VERSION` 匹配、`LOCAL_ONLY` 语义自洽。
- **跨版本表形态容忍**:kubespray 的支持矩阵在版本间漂移(表所在文件 / 字面量 vs Jinja select /
  条件表达式三种形态), 共享库 `lib-kubespray-tables.sh` 都能解析;形态不认识时**报空并让调用方报错**
  (绝不猜错版本)。实测: v2.32 → 3.10.1/1.12.4/3.6.14;v2.28 → 3.10/1.11.3/3.5.16。
- **两版本共存实证**:`v2.32.0`(在库)+ `v2.28.0`(本地临时)同时在场;`--profile`/`paths` 各自
  指向正确的资产与树;MinIO 侧嵌套下载实测只拉指定版本。
- **未做(边界)**:未用 v2.28 真装集群(现集群未触碰);v2.28 的 gateway-api 清单 / skopeo / yq
  二进制**版本与 1.32 线不匹配, 未补齐**(详见该版本目录内 `NOTE-本地临时.md`)。
