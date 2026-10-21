# offline-files/cubestack-operator/

CubeStack 平台 Operator **及其平台组件**的离线资产(2026-10-08 起从各兄弟目录收敛于此;
**2026-10-16 起平台组件镜像按组件分子目录分类** —— 更新单个 operator 时可只推它的镜像)。

## 目录结构

| 路径 | 内容 | 平台组件(`CubeStackCluster.spec.components`) |
|---|---|---|
| `<上游ref>.tar`(**顶层**) | **operator 本体**(滚动 tag; `harbor-save-images.sh --group cubestack-operator` 生成) | —(operator 自身) |
| `cubestack-operator-chart-<版本>.tgz`(**顶层**) | **operator helm chart** + `.tgz.digest` 边车; 随离线包分发, 不入 git | —(不是平台组件) |
| `lws/` | LWS 控制器 | `lws` |
| `envoy-gateway/` | envoy 控制面/数据面/envoy-distroless + ratelimit + AI 网关 ×2(共 5; gateway v1.9.2 / envoy distroless-v1.39.1 / ai-gateway v1.2.0 / ratelimit 0482748e) | `envoyGateway`(+`aiGateway`) |
| `controller-manager/` | cubestack-controller-manager | `cubestackControllerManager` |
| `prometheus/` | 监控栈 11 件: prometheus-operator(+config-reloader)/prometheus/alertmanager/node-exporter/kube-state-metrics/kube-rbac-proxy/thanos/grafana/k8s-sidecar(quay)/kube-webhook-certgen | `prometheus` |
| `perses/` | perses + perses-operator + k8s-sidecar(docker.io) | `perses` |
| `cuberouter/` | cuberouter + cnpg(cloudnative-pg + postgresql) | `cuberouter` |
| `bmc/` | bmc-oem-exporter + idrac-exporter(+`.digest` 边车) | `exporters.bmc` |
| `cubepilot/` | cubepilot api/openclaw/operator/web(+`.digest` 边车) | `cubepilot` |
| `portal/` | cubestack-ui + opstree redis 家族(redis/operator/sentinel/exporter) | `cubestackPortal` |
| `observability/` | 非镜像资产: `helm/`(bmc-exporter chart)/ `dashboards/` / `recording-rules/` / `MANIFEST.txt` | `observability` |

映射权威 = chart `values.yaml` 的 `spec.components` + 各组件 legacy README(2026-10-16 对账);
两处为推断(实机复核后可微调): opstree redis → portal、thanos → prometheus。
⚠ 子目录**只放镜像 tar**(`.tar` / `.digest`);非镜像资产继续放 `observability/` 等既有结构。
operator chart 平铺在**顶层**(`.tgz`), 因为模块的顶层 `*.tar` 扫描不会把它当镜像。

## 消费方与行为(2026-10-16 起)

`modules/03_addon/25_cubestack_operator.sh`:

- **在线模式**(`ONLINE_DEPLOY_CUBESTACK_OPERATOR=true`):[4/6]+[4b/6] 全部跳过 —— 镜像按 chart
  定义从 Harbor 直拉;**本目录的 tar 不被消费**(仅作补料来源)。
- **离线模式**(默认):operator 本体(顶层 tar, digest 幂等)与 [4b/6] 组件镜像推入集群内置 registry。
  [4b/6] 扫描范围 = **顶层 + 各组件子目录**的 `*.tar`(顶层 chart 是 `.tgz`, 天然不参与);
  幂等 = digest 比对(同本体机制)。
- **单独推送某个组件**(更新它之后只灌它的镜像, 值=子目录名, 逗号/空格分隔):

  ```bash
  sudo CUBESTACK_OPERATOR_COMPONENTS="cubepilot" ./deploy-cluster.sh --steps cubestack_operator
  sudo CUBESTACK_OPERATOR_COMPONENTS="envoy-gateway,portal" ./deploy-cluster.sh   # 全量部署时限定范围
  ```

  组件名不存在会**报错并列出可用子目录**。

## 更新某个 operator 的镜像(离线通道)

1. 联网机从上游 / Harbor pull → `docker save` / `skopeo copy` 成 `<上游ref>.tar`
   (命名 = ref 的 `/`、`:` 替换为 `_`;消费方**以文件名为权威**, RepoTags 仅作尾部校验);
2. 替换对应 `offline-files/cubestack-operator/<组件>/` 内的旧 tar(滚动 tag 的连 `.digest` 边车一起更新);
3. 目标机执行过滤推送(上节命令);
4. 复核: `--steps verify_cubestack_operator`。

- operator **本体**是另一条路: `harbor-save-images.sh --group cubestack-operator [--force]` → 顶层 tar →
  `--steps cubestack_operator`。
- ⚠ `images.manifest` 里登记的 `docker.io/envoyproxy/ratelimit`(组=cubestack-operator)经 CI 同步后
  由 harbor-save 产出**顶层** tar —— 请归位到 `envoy-gateway/` 再推送(工具加子目录支持前的已知边角)。

## 更新 operator chart(离线通道)

chart 与组件镜像 tar 平铺在本目录顶层, 一起走 MinIO:

```bash
# 内网同步机(能同时访问 Harbor 与 MinIO): 拉取 → 比对 Digest → 上传
bash deployments/scripts/tools/images/cubestack-platform-sync.sh \
  --collection cubestack-operator --no-pull-state

# 部署机: 连带镜像 tar 一起取回
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --sub cubestack-operator
```

- 源: `oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart:1.0.0-latest`;
- 落点: 本目录顶层 `cubestack-operator-chart-1.0.0-latest.tgz` + `.tgz.digest`;
- 自动发布: cubestack-operator 仓库发 `repository_dispatch: operator-chart-updated` →
  `.github/workflows/refresh-operator-chart.yml` 拉取并上传 MinIO(无内网同步机时也适用);
- `.digest` 必须写 helm 输出的 `Digest:` 行(OCI manifest 摘要), **不要** `sha256sum`;
- 模块解析优先级: `CUBESTACK_OPERATOR_CHART_DIR` > 本目录 > 旧 `cubestack-addon/cubestack-operator/`
  (只读 fallback, 保留一个版本)。

## 镜像来源与刷新(2026-10-16 实测基线)

| 类别 | 拉取源 | 说明 |
|---|---|---|
| 自研(滚动 `:latest`) | `harbor.isuanova.com/suanova/<name>` | ⚠ **bmc-oem-exporter / idrac-exporter 已迁至 `suanova-private` 项目**; tar 文件名仍按部署口径 `suanova/…` 命名(目标 `<REG>/suanova/<name>` 不变, RepoTags 保存时同步重打) |
| 第三方(钉版本) | `harbor.isuanova.com/mirrors/<上游ref>` | docker.io 本网络不通, 恒经 mirrors |
| 例外(2026-10-19 校准) | 见右 | `gateway:v1.9.2` / `ai-gateway-controller:v1.2.0` / `ai-gateway-extproc:v1.2.0` / `envoy:distroless-v1.39.1` 均从 Harbor mirrors 拉取;**ratelimit 必须用 gateway-helm v1.9.2 的 chart 默认 tag `0482748e`**(旧 `8fe6ea42` 只在 v1.9.1 时代);`windows-exporter:0.31.8` 只有 `windows/amd64`, Linux 节点不调度, **不进入** Linux 离线集合 |

刷新规程(零层拉取比对, 仅变化才替换):

1. 取远端 amd64 config digest(`docker manifest inspect` 两段法)与本地 tar 的 `manifest.json[].Config` 比对;
2. 有变化 → `docker pull` → `docker tag` 回**文件名约定 ref** → `docker save` 覆盖 tar(旧件先备份到 `.backup-<日期>/`);
3. `.digest` 边车(仅 bmc/cubepilot 有)写 **registry 返回的 manifest digest**(`docker pull` 输出的 `Digest:` 行);
4. 双份同步: 仓库副本 + `/data/offline-files`(容器挂载真身)。

## 保鲜管道: Harbor → 离线 tar → MinIO(定时同步, 2026-10-16)

- **清单(单一事实源)**: 本目录 `image-list.tsv`(37 行; CI/本地/服务器共用)。
- **工具**(`deployments/scripts/tools/images/`):
  - `cubestack-platform-save-images.sh`: 逐镜像 `sha256(skopeo --raw)` digest 比对(== `docker pull`
    的 Digest, 零层拉取)→ 变化才 `skopeo copy`(强制单架构 amd64)重写 tar 与 `.digest` 边车;
    `--only <子串>` 单组件、`--dry-run`、`--list-check`、`--seal-missing`(一次性迁移补边车)。
  - `cubestack-platform-sync.sh`: 编排(拉边车→保鲜→`mc mirror` 上传→数量校验), 供**定时任务**用;
    `--print-systemd` 直接生成 systemd unit+timer 模板(含 `/etc/cubestack-platform-sync.env` 用法)。
- **部署位置(2026-10-16 定案)**: 跑在**同时能访问 Harbor 与 MinIO 的机器**(Harbor 服务器/安装机)。
  ❗不走 GitHub 托管 runner: MinIO 无 TLS, 公网明文不可接受; 内网执行零公网传输。
- MinIO 目标: `<桶>/offline-files/cubestack-operator/`(结构与本目录一致, fetch 侧零改动);
  凭据只进 600 的 env 文件或环境变量, 不进仓库/argv/日志。
- **部署机取回**: `tools/offline/fetch-offline-from-minio.sh --sub cubestack-operator/<组件>`
  (刷新单组件; 下钻列表 `--list --sub cubestack-operator`; `--help` 打印全部可用子目录)。

## 一致性校验(Harbor ↔ tar ↔ MinIO, 2026-10-19 增补)

发版/重新部署前建议两条都跑(任一 gap 非 0 退出):

```bash
# ① tar ↔ Harbor: 逐行比对 .digest 边车 ↔ 远端 manifest digest,
#    并直接读 tar 的 config digest ↔ Harbor amd64 config digest(内容身份, 不受重打包影响)
bash deployments/scripts/tools/images/cubestack-platform-save-images.sh --verify-remote

# ② tar ↔ MinIO: 上传后逐 tar 流式 sha256 比对(会完整读远端对象, 大集合较慢; --only 可限定)
bash deployments/scripts/tools/images/cubestack-platform-sync.sh \
  --state-dir /data --collection cubestack-operator --no-pull-state \
  --verify-minio --conf /etc/cubestack-platform-sync.env
```

⚠ `--verify-remote` 2026-10-19 修复了一个会静默漏刷新的解析 bug: 清单里 `pull_ref` 留空的
行(自研镜像)曾被 bash 的连续 tab 折叠成 `pull=save_ref, save=""`, 导致 `skopeo copy` 目标
退化成 `docker-archive:<path>:` 而永远失败。现在用 `awk -F'\t'` 保留空字段。

## 版本真相 / 目录变量

- 本体: `cluster.conf` 4.6b 的 `CUBESTACK_OPERATOR_IMAGE_TAG` / `CUBESTACK_OPERATOR_CHART_VERSION`;
- 目录变量: `CUBESTACK_OPERATOR_OFFLINE_DIR`(默认指本目录);
  chart 目录覆盖: `CUBESTACK_OPERATOR_CHART_DIR`(留空=本目录顶层);
- 平台组件镜像的**上游 ref** 见 tar 文件名;这些组件当前**不在** `images.manifest` 的 group 清单里
  (原 group 随 09-23 组件模块移除而删), 重新登记与否见 offline-files/os/README.md 的讨论。

## 历史

- **2026-10-08 目录收敛**: 原 `bmc/` `cubepilot/` `envoy/` `kube-state-metrics/` `node-exporter/`
  `observability/` `perses/` `prometheus/` 八个目录为已移除模块的离线残留, 镜像并入本目录
  (重复项按内容 digest 去重: kube-state-metrics 与 prometheus 批 md5 相同、node-exporter/kiwigrid
  的 docker-save 版与 prometheus 批 digest 相同, 各删一份)。历史 README 归档目录已随 MinIO 清理移除。
- **2026-10-16 分类**: 平台组件镜像按 CR `spec.components` 分入子目录(顶层=本体); 模块 [4b/6] 改为
  顶层+子目录递归扫描, 新增 `CUBESTACK_OPERATOR_COMPONENTS` 过滤 —— 更新单个 operator 时可单独推拉。
- **2026-10-16 刷新**: 逐镜像 digest 核对(36 件)后更新 11 件(9 自研滚动 + thanos + redis-exporter),
  旧件存 `.backup-20261016/`; 发现 bmc/idrac 迁移至 `suanova-private`(见"镜像来源与刷新")。
- ⚠ 2026-10-15: 独立的 LWS 部署模块(07_gpu_lws / lws-save-images)整体下线删码; `lws/` 下的 tar 是
  **唯一保留**的 LWS 资产 —— 平台 operator 的 CR 仍可下发 `lws` 组件, 由本模块统一推送。
- **2026-10-19 刷新(chart v1.9.2 配套)**: operator chart 更新到 digest `45cc1b54…`(gateway-helm
  v1.9.2); 补齐 `gateway:v1.9.2` / `envoy:distroless-v1.39.1` / `ai-gateway-controller:v1.2.0` /
  `ai-gateway-extproc:v1.2.0` / `ratelimit:0482748e`(旧 `8fe6ea42` 只适用 v1.9.1); 刷新 7 个
  自研滚动 `latest`(cubepilot ×4 / controller-manager / cuberouter / cubestack-ui), 旧件存
  `.backup-20261019/`。修复保鲜工具 TSV 空字段解析并新增 `--verify-remote` 的 tar↔Harbor
  config digest 校验; 本地 36/36 与 Harbor 一致。MinIO 上传后可用 `--verify-minio` 做逐文件
  sha256 校验(需 `MINIO_*`/`minio.conf`)。`windows-exporter` 仅 `windows/amd64`, 不进入
  Linux 离线集合。
- **2026-10-21 chart 迁移**: operator chart 从 CLI 镜像(`cubestack-addon/cubestack-operator/`)
  移到本目录顶层, 与镜像 tar 同包分发; `.tgz`/`.digest` 不入 git, 由
  `cubestack-platform-sync.sh --collection cubestack-operator` 上传 MinIO。

> ⚠ 本目录下的 `*.tar` / `*.digest` / `*.tgz` / `*.tgz.digest` 已在 `.gitignore` 中忽略(不入库);
> 只有本 README 与 `image-list.tsv` 受版本控制。
