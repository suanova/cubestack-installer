# CubeStack Operator — CubeStack 适配说明

本目录为 **CubeStack 平台 Operator 的 helm chart 离线副本**, 供
`modules/03_addon/25_cubestack_operator.sh` 部署使用。

- 上游: `oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart`(**私有项目**, 拉取需凭据)
- 源码仓库: <https://github.com/suanova/cubestack-operator>(私有)
- chart 版本: **`1.0.0-latest`(滚动)** —— `appVersion: latest`, 与滚动镜像 `:latest` 配套

## 目录内容

```
deployments/cubestack-addon/cubestack-operator/
├── cubestack-operator-chart-1.0.0-latest.tgz          # ★ 离线副本(helm pull 产出, 随 git 分发)
├── cubestack-operator-chart-1.0.0-latest.tgz.digest   # Digest 边车(helm pull 报告的 "Digest:" 行)
└── CUBESTACK.md                                       # 本文件
```

⚠ **`.digest` 写的是 helm 报告的 `Digest:` 值 —— 对 OCI chart 它是 manifest 摘要, 不是 tgz 的
sha256**(实测: 本 chart manifest 摘要 `sha256:06f0318d…`, 而 tgz 文件 sha256 是 `sha256:c8e94925…`)。
`helm_chart_ensure` 就是拿这个值和 `helm pull` 输出比对的, 所以**必须**从 pull 输出里取、
不能自己 `sha256sum` 算(算出来的值永远比不相等 → 每次部署都误判"有更新"并覆盖本地副本)。

## chart 渲染出什么(实测, `helm template` 默认 values)

| 对象 | 说明 |
|---|---|
| `Deployment/cubestack-operator` | operator 本体(replicas=1, 默认; leader-elected, 可热备) |
| `ServiceAccount` / `ClusterRole` / `ClusterRoleBinding` | RBAC(ClusterRole 含 `apiGroups:["*"]` 全量动词, 设计文档已接受) |
| `crds/operator.cubestack.io_cubestackclusters.yaml` | CRD `cubestackclusters.operator.cubestack.io`(短名 `csc`) |
| `Service`(metrics, `service.enabled=false` 默认关) | — |
| `CubeStackCluster`(`clusterCR.enabled=false` 默认关) | 平台实例 CR; 打开即下发平台组件, 见下 |

**镜像只有一个**:

```
harbor.isuanova.com/suanova-private/cubestack-operator:{{ .Values.image.tag | default .Chart.AppVersion }}
```

## 关键 values(部署脚本注入, 也可手工 `--set`)

| values 键 | chart 默认 | 部署脚本怎么用 | 为什么 |
|---|---|---|---|
| `image.repository` / `image.tag` | `harbor.isuanova.com/suanova-private/cubestack-operator` / `""`(=appVersion) | 改写成**集群内置 registry** 路径(`registry.cubestack.io:5000/suanova-private/cubestack-operator`) | 需求: 节点只从集群 registry 拉镜像, 不访问 Harbor(离线前提) |
| `image.pullPolicy` | `IfNotPresent` | `Always`(默认; `CUBESTACK_OPERATOR_IMAGE_PULL_POLICY` 可改) | 镜像 tag 恒为滚动 `:latest`, `IfNotPresent` 会让节点缓存**静默冻结**版本 |
| `podAnnotations` | `{}` | 注入 `cubestack.io/image-digest=<digest>` | 滚动 tag 下 Deployment spec 不变就不会滚动 —— 把 digest 写进模板, 变内容才触发滚动 |
| `clusterCR.enabled` | `false` | `CUBESTACK_OPERATOR_CLUSTER_CR_ENABLED` | 打开会一并下发平台组件(lws/envoy-gateway/prometheus/portal…), 不在本模块离线范围内 |
| `ssaForce` | `true` | 不动 | 从 helm/kubectl 迁移过来的对象靠它抢字段 |
| `requeueSeconds` | `30` | 不动 | 未 Ready 组件的轮询间隔 |

> ⚠ 升级注意(README 原文): helm 只在 **CRD 不存在**时才装 `crds/`, 已装过 operator 的集群
> 必须先 `kubectl apply -f <chart>/crds/...` 再升级, 否则旧 CRD 会把新字段剪掉。本模块
> **每次部署都先 SSA apply 一遍 crds/**(见模块 `[5/6]`), 所以这条不用记。

## 刷新到新版本(手工, 或交给模块的在线模式)

```bash
# 1) 登录(私有项目; 2FA 账号用「用户配置 → CLI Secret」当密码)
helm registry login harbor.isuanova.com -u <用户> --password-stdin

# 2) 拉最新(滚动版本号固定是 1.0.0-latest)
helm pull oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart \
    --version 1.0.0-latest -d deployments/cubestack-addon/cubestack-operator

# 3) ★ 更新 Digest 边车(用 pull 输出里那一行, 不要 sha256sum)
helm pull ... 2>&1 | sed -n 's/^Digest:[[:space:]]*//p' > \
    deployments/cubestack-addon/cubestack-operator/cubestack-operator-chart-1.0.0-latest.tgz.digest

# 4) 提交(离线副本必须随 git 分发, 否则部署机拿不到/回退空转)
```

在线部署时 `CUBESTACK_OPERATOR_CHART_SYNC=auto`(默认)**会自动做第 2/3 步**: 远端 digest 与
边车不一致才覆盖本地副本, 并提示 `git add/commit` 固化 —— 仓库不会因"远端没变"被弄脏。

## 离线镜像

镜像 tar 不在本目录(见 `deployments/offline-files/cubestack-operator/README.md`):

```bash
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group cubestack-operator --force
```
