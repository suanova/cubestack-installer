# LeaderWorkerSet (LWS) 部署与使用

> LWS 是 Kubernetes 上面向 LLM/AI 推理与训练的工作负载调度控制器, 以 Leader/Worker 组为单位调度 Pod。
> 官方文档: [Installation](https://lws.sigs.k8s.io/docs/installation/) / [Concepts](https://lws.sigs.k8s.io/docs/concepts/leaderworkerset/) / [DisaggregatedSet](https://lws.sigs.k8s.io/docs/concepts/disaggregatedset/)

## 一、部署

### 1.1 启用

`cluster.conf` 中 `LWS_ENABLED=true`(默认 false):

```bash
# 单独立即部署
sudo ./deployments/scripts/deploy-cluster.sh --steps gpu_lws
# 或随全量
sudo ./deployments/scripts/deploy-cluster.sh --with-cubestack
# 或预启用(只写 cluster.conf, 不部署, 下次全量生效)
sudo ./deployments/scripts/deploy-cluster.sh --enable gpu_lws
```

### 1.2 安装方式(`LWS_INSTALL_MODE`, 双模式)

> **默认 bundle(官方推荐)**: 官方 `manifests.yaml` 单文件, `kubectl apply --server-side` 整体下发
> (含 namespace + CRD + RBAC + controller + webhook, 逐资源应用不受 helm Secret 1MiB 上限, 证书=internal)。
> **helm 方式**保留给 cert-manager 模式 / 自定义 values(chart 在 `deployments/cubestack-addon/lws/charts/`)。

| 模式 | 机制 | 适用 |
|---|---|---|
| **bundle**(默认) | `LWS_MANIFEST=.../lws/manifests.yaml`, `kubectl apply --server-side -f` | 离线、internal 证书、求简; 官方推荐 |
| **helm** | `charts/` 本地 chart; `LWS_CHART_SOURCE=dir\|tgz\|oci` | cert-manager 模式 / 自定义 values |

> 设 `LWS_CERT_MODE=cert-manager` 会自动切到 helm(bundle 固定 internal, 无 cert-manager)。

### 1.3 Chart 来源(`LWS_CHART_SOURCE`, 仅 helm 方式, 本地源优先)

> **默认离线安装**: 本地源(`dir`/`tgz`)优先; 仅 `oci` 源需联网。

| 方式 | 配置 | 说明 |
|---|---|---|
| **dir**(默认) | `LWS_CHART_SOURCE=dir` + `LWS_CHART_DIR=deployments/cubestack-addon/lws/charts` | 本地解包目录(仓库已内置官方 v0.10.0 chart), 离线 |
| **tgz** | `LWS_CHART_SOURCE=tgz` + `LWS_CHART_TGZ=.../lws/charts/lws-chart-v0.10.0.tgz` | 本地官方发布包, 离线 |
| **oci** | `LWS_CHART_SOURCE=oci` + `LWS_CHART_OCI=oci://registry.k8s.io/lws/charts/lws` + `LWS_CHART_VERSION` | 官方 OCI registry, **需联网** |

OCI 方式即官方命令:

```bash
CHART_VERSION=v0.10.0
helm install lws oci://registry.k8s.io/lws/charts/lws \
  --version=$CHART_VERSION \
  --namespace lws-system --create-namespace \
  --set enableDisaggregatedSet=true \
  --wait --timeout 300s
```

**离线镜像策略**: 本地源(`dir`/`tgz`)时, controller 镜像**强制走本地**(本地 docker daemon → 离线 tar),
不联网; 缺失则报错并给出指引。仅 `LWS_CHART_SOURCE=oci` 或 `LWS_IMAGE_ONLINE=true` 才允许在线拉取。

### 1.4 证书管理模式(`LWS_CERT_MODE`)

| 模式 | 适用方式 | 说明 |
|---|---|---|
| `internal`(默认) | **bundle / helm 均可** | controller 内置自签证书, 离线友好; **bundle 固定为此模式** |
| `cert-manager` | **仅 helm** | webhook 证书由 cert-manager 签发(Certificate 自动轮换); 集群需已装 cert-manager, 自动切 helm |

```bash
# 集群无 cert-manager 时用 internal(默认, 离线环境推荐)
LWS_CERT_MODE=internal sudo ./deployments/scripts/deploy-cluster.sh --steps gpu_lws
```

### 1.5 离线要求(离线优先)

> 默认按**离线安装**处理: 本地 bundle / chart + 本地镜像, 全程不访问外网。

- **bundle(默认)**: `deployments/cubestack-addon/lws/manifests.yaml`(官方 v0.10.0 单文件, 已 vendoring)
- **helm chart**: `deployments/cubestack-addon/lws/charts/`(官方 v0.10.0 完整 chart + 发布包 tgz, 见该目录 `CUBESTACK.md`)
- **镜像 tar(联网机一键生成)**: `deployments/scripts/tools/images/lws-save-images.sh`
  下载官方 `registry.k8s.io/lws/lws:<tag>` 并保存 tar(文件名与 cubestack-offline.sh 一致,
  如 `registry.k8s.io_lws_lws_v0.10.0.tar`),**默认存到 `deployments/offline-files/lws/`**
  (`LWS_SAVE_DIR` 可覆盖)。源镜像可用 `LWS_IMAGE_SRC` 改为内网镜像站;已存在则跳过(幂等)。
- **镜像(与 gpu_operator 一致)**: 默认把 `lws/manager:<tag>`(默认 `v0.10.0`)镜像文件**推送至集群内置 registry**
  (`PUSH_REGISTRY=${REGISTRY_IP}:${REGISTRY_PORT}/lws/manager`, 推送走 MetalLB VIP 直连, skopeo 3 次重试)。
  推送顺序(本地源 `dir`/`tgz` 时)**仅本地**: 本地 docker daemon 有镜像 → `docker save` 临时 tar + skopeo 推送;
  否则要求离线 tar 已放入 `deployments/offline-files/lws/`(lws-save-images.sh 默认输出; 也兼容 `${LOCAL_REPO_DIR}/images/`)。
  镜像缺失时**直接报错**并给出两条指引(本地 docker pull / 下载离线 tar), 绝不静默联网。
  仅当 `LWS_CHART_SOURCE=oci` 或 `LWS_IMAGE_ONLINE=true` 时才允许 skopeo 在线拉取。
- **拉取**: 部署时 `image.manager.repository=${LWS_IMAGE_REPO}`(默认 `${REGISTRY_DOMAIN}:${REGISTRY_PORT}/lws/manager`,
  与推送仓库路径一致)+ `pullPolicy=IfNotPresent`, K8s 节点从集群内置 registry 按域名拉取镜像。
  registry 已有该 tag 时部署脚本自动跳过推送(幂等, `_reg_has_tag` 优先 skopeo inspect)。

### 1.6 主要配置(cluster.conf)

| 变量 | 默认 | 说明 |
|---|---|---|
| `LWS_ENABLED` | `false` | 总开关 |
| `LWS_INSTALL_MODE` | `bundle` | `bundle`(官方 manifests.yaml, 默认)/ `helm`(chart; cert-manager 自动切 helm) |
| `LWS_MANIFEST` | `${REPO_ROOT}/deployments/cubestack-addon/lws/manifests.yaml` | 官方 bundle(离线 vendoring) |
| `LWS_CHART_SOURCE` | `dir` | `dir` / `tgz` / `oci`(chart 来源, 仅 helm 方式) |
| `LWS_CHART_VERSION` | `v0.10.0` | 对应官方 `CHART_VERSION`(oci 源用) |
| `LWS_CHART_DIR` | `${REPO_ROOT}/deployments/cubestack-addon/lws/charts` | 本地解包目录(内置官方 chart) |
| `LWS_CHART_TGZ` | `${LWS_CHART_DIR}/lws-chart-v0.10.0.tgz` | 本地发布包 |
| `LWS_CHART_OCI` | `oci://registry.k8s.io/lws/charts/lws` | 官方 OCI registry |
| `LWS_CERT_MODE` | `internal` | `internal`(默认; bundle 固定) / `cert-manager`(需 helm) |
| `LWS_IMAGE_REPO` / `LWS_IMAGE_TAG` | `registry.local:5000/lws/manager` / `v0.10.0` | controller 镜像(对应 image.manager.*) |
| `LWS_IMAGE_ONLINE` | `false` | 允许在线拉取镜像的显式开关(默认离线; 仅 `oci` 源或置 `true` 才联网) |
| `LWS_NAMESPACE` / `LWS_RELEASE_NAME` | `lws-system` / `lws` | 命名空间 / release 名 |
| `LWS_DISAGGREGATEDSET_ENABLED` | `true` | 解耦推理支持(bundle 已含; helm 对应 enableDisaggregatedSet) |

## 二、验证

```bash
sudo ./deployments/scripts/deploy-cluster.sh --steps verify_lws
```

验证内容(见 `modules/03_addon/24_verify_lws.sh`, 复用 `tools/k8s/verify-lws.sh`):
① controller pod Ready → ② CRD 注册(leaderworkersets.leaderworkerset.x-k8s.io + disaggregatedsets.disaggregatedset.x-k8s.io)
→ ③ 创建测试 LeaderWorkerSet(leader 1 + worker 2, busybox)→ ④ 全部 Ready
→ ⑤ 校验控制器管理(leaderworkerset.sigs.k8s.io/name 标签 + worker-index=0 为 leader)→ ⑥ DisaggregatedSet 支持

## 三、使用示例

> ⚠ v0.10.0 schema 变更: `leaderWorkerTemplate` 用 `leaderTemplate`/`workerTemplate`(**workerTemplate 必填**),
> `restartPolicy` 枚举为 `Default`/`None`/`RecreateGroup*`(不再用 `Always`/`template`)。

### 3.1 简单 LeaderWorkerSet

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: llm-inference
  namespace: default
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 3                 # 1 leader + 2 worker
    restartPolicy: Default
    workerTemplate:         # v0.10: 分离的 worker pod 模板(必填; leader 缺省复用 workerTemplate)
      spec:
        containers:
          - name: vllm
            image: registry.local:5000/llm/vllm:latest
            ports:
              - containerPort: 8000
```

### 3.2 DisaggregatedSet(解耦推理)

> v0.10.0: DisaggregatedSet 用 `spec.roles[]`(**至少 2 个 role**) + `slices`(整数), 不再用旧 `groups`。

Prefill 与 Decode 阶段拆分为独立 role(每 role 独立副本/镜像/资源):

```yaml
apiVersion: disaggregatedset.x-k8s.io/v1
kind: DisaggregatedSet
metadata:
  name: llm-dset
  namespace: default
spec:
  roles:
    - name: prefill
      spec:
        leaderWorkerTemplate:
          workerTemplate:
            spec:
              containers:
                - name: prefill
                  image: registry.local:5000/llm/prefill:latest
    - name: decode
      spec:
        leaderWorkerTemplate:
          workerTemplate:
            spec:
              containers:
                - name: decode
                  image: registry.local:5000/llm/decode:latest
```

## 四、卸载

```bash
# bundle 方式: 整体删除(命名空间 + CRD 等随 manifest 删; CRD 需单独删)
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf delete -f deployments/cubestack-addon/lws/manifests.yaml
# helm 方式: helm uninstall + 删 CRD
helm uninstall lws -n lws-system
# 两种方式都删 CRD(CRD 不在 release/删除范围)
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf delete crd leaderworkersets.leaderworkerset.x-k8s.io disaggregatedsets.disaggregatedset.x-k8s.io disaggregatedsetrolescalers.disaggregatedset.x-k8s.io
```

## 五、常见问题

- **webhook 证书失败(cert-manager 模式)**: 集群未装 cert-manager → 改用 `LWS_CERT_MODE=internal`。
- **controller CrashLoop(证书目录)**: internal 模式需 chart 挂载 cert 卷并传入 `--webhook-cert-dir`; 检查 pod 日志。
- **测试 LWS 一直 Pending**: 检查 busybox 镜像是否预加载(`PRELOAD_IMAGE_PATTERNS` 含 busybox)与节点资源。
- **webhook 超时(跨节点 fabric)**: 本集群为 Calico + IPIP, 见 `docs/cluster-architecture.md` §2; 确认 webhook 服务经 IPIP 可达(controller 未 pinned 时默认可达)。
