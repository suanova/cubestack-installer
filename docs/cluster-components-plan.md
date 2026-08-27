# CubeStack 集群组件综合规划(P1+P2+P3 全阶段进度追踪表)

> 统一规范:进度状态统一为【未开始/进行中/阻塞中/已完成】;进度:0%(未启动)、10%-90%(进行中)、100%(验收完成);无阻塞点统一填写"-"。所有阶段表格格式完全统一,全流程成套追踪。
>
> 对应关系:每个组件 = `deployments/scripts/modules/<阶段>/NN_*.sh` 一个模块 + `config/cluster.conf` 中对应 `*_ENABLED` 开关。详细模块开发规范见 `docs/scripts-development-spec.md`。

## 一、P1 阶段(基础刚需·必须全部完成)

说明:P1为集群底层刚需核心组件,不可跳过,是P2/P3所有能力的前置依赖;MetalLB为可选组件,不纳入本表。

| 序号 | P1必做核心组件 | 核心交付目标(极简) | 当前进度 | 当前状态 | 现存问题/阻塞点 | 计划完成时间 | 实际完成时间 | 对应模块/开关 |
|---|---|---|---|---|---|---|---|---|
| 1 | Kubernetes(Kubespray部署) | 基于Kubespray完成集群部署,核心资源(StatefulSet/PVC/Service等)正常创建调度,集群基础环境稳定可用 | 0% | 未开始 | - |  |  | `modules/02_k8s/06_k8s_deploy.sh` / `K8S_ENABLED` |
| 2 | Prometheus + Prometheus Operator | 完成监控底座部署,通过Operator标准化管理监控规则,实现集群基础指标采集、存储、可查询 | 0% | 未开始 | - |  |  | `modules/03_addon/04_prometheus.sh` / `PROMETHEUS_ENABLED` |
| 3 | 全套监控附属组件(P1刚需) | 部署kube-state-metrics、Perses可视化组件,全覆盖采集集群各类指标并可视化展示,具体刚需采集项:1. 节点指标:node-exporter(必须) 2. 容器指标:kubelet/cAdvisor(必须) 3. NVIDIA GPU指标:DCGM Exporter(NVIDIA环境必须) 4. MetaX GPU指标:MetaX官方接口/Exporter(MetaX环境必须) 5. RDMA指标:RDMA Exporter/采集适配(必须) 6. Ceph指标:Ceph Exporter/采集适配(必须) | 0% | 未开始 | - |  |  | `modules/03_addon/04_prometheus.sh` / `PROMETHEUS_ENABLED` |
| 4 | Docker Registry(Harbor) | 搭建可用镜像仓库,实现镜像推送、拉取、目录同步,保障集群业务镜像正常部署 | 0% | 未开始 | - |  |  | `modules/03_addon/05_harbor.sh` / `HARBOR_ENABLED`(集群外私有仓库,唯一方案) |
| 5 | 沐曦MetaX GPU Operator | 完成GPU驱动部署、硬件识别、集群GPU资源调度,配套MetaX指标采集,保障GPU容器正常启动运行 | 100% | ✅ 已完成(2026-08-23) | - |  | 2026-08-23 | `modules/03_addon/04_gpu_operator.sh` / `GPU_OPERATOR_ENABLED`(详见 `docs/metax-gpu-operator.md`) |
| 6 | Ceph 存储集群 | 完成Ceph底层存储集群部署、集群健康自检、存储池初始化,为上层CSI服务提供稳定存储底座 | 0% | 未开始 | - |  |  | `modules/03_addon/06_ceph.sh` / `CEPH_ENABLED` |
| 7 | Ceph CSI(RBD/RGW/CephFS) | 部署CSI驱动,对接Ceph存储集群,实现三类存储卷正常创建、挂载、读写,集群StorageReady状态正常置位 | 0% | 未开始 | - |  |  | `modules/03_addon/07_ceph_csi.sh` / `CEPH_CSI_ENABLED` |
| 8 | LWS | 完成LWS组件部署、集群适配与基础校验,保障集群轻量调度与配套服务正常运行 | 100% | ✅ 已完成(2026-08-23) | - |  | 2026-08-23 | `modules/03_addon/05_gpu_lws.sh` / `LWS_ENABLED`(helm 离线 + cert-manager/internal 双证书 + DisaggregatedSet, 详见 `docs/lws.md`) |
| 9 | Envoy AI 网关(Envoy Gateway + Envoy AI Gateway) | 搭建集群统一流量入口,完成路由配置与转发测试,保障外部业务URL可正常稳定访问(通用网关基座 + AI 扩展层) | 50% | 进行中 | 模块/离线 chart/离线镜像工具已实现; 待联网机跑 envoy-fetch-charts.sh / envoy-save-images.sh 备料后实机验证 |  |  | `modules/03_addon/09_envoy_gateway.sh` + `10_envoy_ai_gateway.sh` / `ENVOY_GATEWAY_ENABLED` + `ENVOY_AI_GATEWAY_ENABLED`(详见 `docs/envoy-gateway.md`) |

**P1附属基础依赖(必过验收·极简核对):**

| 附属依赖 | 说明 | 对应模块 |
|---|---|---|
| NTP时间同步 | 全节点时钟统一,无时间漂移问题 | `modules/02_k8s/05_k8s_ntp.sh` |
| Calico/Multus网络 | Pod基础网络、多网卡通信正常 | kubespray `k8s-net-calico.yml` / k8s_cluster group_vars |
| RDMA驱动协议栈 | 高速网络环境适配就绪,功能可用 | 规划:并入 `04_prometheus.sh` 采集 / 独立模块(待定) |

## 二、P2 阶段(能力增强·进阶刚需)

说明:P2为集群进阶能力补强组件,不阻塞P1基础业务运行,为平台商业化、精细化运维必备能力,阶段内必须完成。

| 序号 | P2必做核心组件 | 核心交付目标(极简) | 当前进度 | 当前状态 | 现存问题/阻塞点 | 计划完成时间 | 实际完成时间 | 对应模块/开关 |
|---|---|---|---|---|---|---|---|---|
| 1 | Keycloak 统一认证 | 部署Keycloak服务,实现集群统一身份认证、用户权限管控,完成Envoy网关对接,支持统一登录鉴权;兼容P1兜底认证方案平滑过渡 | 0% | 未开始 | - |  |  | `modules/03_addon/09_keycloak.sh` / `KEYCLOAK_ENABLED` |
| 2 | Kueue 队列治理(DEV-29) | 部署Kueue组件,配置任务队列规则、资源配额与调度策略,实现集群任务排队、资源抢占管控、算力资源合理分配 | 0% | 未开始 | - |  |  | `modules/03_addon/10_kueue.sh` / `KUEUE_ENABLED` |
| 3 | KubeVirt 虚拟机能力(DEV-35) | 部署KubeVirt虚拟化组件,完善集群虚拟化适配,支持虚拟机创建、启动、启停、管理,补齐集群VM形态业务交付能力 | 0% | 未开始 | - |  |  | `modules/03_addon/11_kubevirt.sh` / `KUBEVIRT_ENABLED` |

**P2阶段特性说明:**

- 无强阻塞依赖:P2组件不影响P1集群基础运行、监控、存储、网关核心能力
- 认证兼容:P1可通过本地凭据、Jupyter Token、SSH密钥兜底,P2完成后切换为网关统一认证
- 能力补强:聚焦资源治理、统一鉴权、虚拟化拓展,提升集群运维与场景适配能力

## 三、P3 阶段(高阶能力·场景补齐)

说明:P3为集群高阶高性能存储能力拓展,面向大规模并行算力场景,依赖P1基础环境就绪,为本项目收尾进阶能力,P3阶段必须完成。

| 序号 | P3必做核心组件 | 核心交付目标(极简) | 当前进度 | 当前状态 | 现存问题/阻塞点 | 计划完成时间 | 实际完成时间 | 对应模块/开关 |
|---|---|---|---|---|---|---|---|---|
| 1 | Lustre CSI(DEV-26) | 部署Lustre CSI驱动,完成与Lustre并行文件系统对接适配,实现并行存储卷创建、挂载、读写,支撑高性能高吞吐算力业务场景 | 0% | 未开始 | - |  |  | `modules/03_addon/12_lustre_csi.sh` / `LUSTRE_CSI_ENABLED` |

**P3阶段特性说明:**

- 前置依赖:需P1集群、网络、基础存储环境就绪
- 场景价值:补齐集群并行文件存储能力,适配超算、AI大规模算力场景
- 无存量影响:部署适配过程不影响P1/P2已上线功能

## 四、全阶段统一进度填写规范

- 进度:0%(未启动)、10%-90%(进行中)、100%(验收完成)
- 状态:未开始 / 进行中 / 阻塞中 / 已完成
- 阻塞点无问题统一填写"-",有问题详细备注原因、影响范围及待解决事项

---

## 五、组件 → 模块映射总览(自动生成依据)

| P阶段 | 组件 | modules 模块 | cluster.conf 开关 | 现状 |
|---|---|---|---|---|
| 前置 | 环境准备(VM/SSH/Harbor/HAProxy/Keepalived) | `01_env/01~06` | `HARBOR_ENABLED` 等 | ✅ 已实现(Harbor 🧩 伪代码) |
| 前置 | kubespray 离线部署(网络/inventory/NTP/部署/扩容) | `02_k8s/01~07` | `K8S_ENABLED` / `K8S_SCALE_ENABLED` | ✅ 已实现 |
| P1-1 | Kubernetes(Kubespray) | `02_k8s/06_k8s_deploy.sh` | `K8S_ENABLED` | ✅ 已实现 |
| P1-2/3 | Prometheus + 监控附属 | `03_addon/04_prometheus.sh` | `PROMETHEUS_ENABLED` | 🧩 伪代码占位 |
| P1-4 | Docker Registry(Harbor) | `01_env/04_harbor.sh`(集群外私有仓库) | `HARBOR_ENABLED` | 🧩 伪代码占位 |
| P1-5 | 沐曦 MetaX GPU Operator | `03_addon/04_gpu_operator.sh` | `GPU_OPERATOR_ENABLED` | ✅ 已完成(helm 原生安装 + 离线 tar 加载, 9 节点 69 GPU; 见 `docs/metax-gpu-operator.md`) |
| P1-6 | Ceph 存储集群 | `03_addon/05_ceph.sh` | `CEPH_ENABLED` | 🧩 伪代码占位 |
| P1-7 | Ceph CSI | `03_addon/06_ceph_csi.sh` | `CEPH_CSI_ENABLED` | 🧩 伪代码占位 |
| P1-8 | LWS | `03_addon/05_gpu_lws.sh` | `LWS_ENABLED` | ✅ 已实现(helm 离线 + 双证书 + DisaggregatedSet) |
| P1-9 | Envoy AI 网关(统一流量入口: Envoy Gateway + Envoy AI Gateway) | `03_addon/09_envoy_gateway.sh` + `10_envoy_ai_gateway.sh` | `ENVOY_GATEWAY_ENABLED` + `ENVOY_AI_GATEWAY_ENABLED` | 🚧 已实现(离线 chart+镜像工具齐, 待备料实机验证; 见 `docs/envoy-gateway.md`) |
| P2-1 | Keycloak 统一认证 | `03_addon/08_keycloak.sh` | `KEYCLOAK_ENABLED` | 🧩 伪代码占位 |
| P2-2 | Kueue 队列治理 | `03_addon/09_kueue.sh` | `KUEUE_ENABLED` | 🧩 伪代码占位 |
| P2-3 | KubeVirt 虚拟机能力 | `03_addon/10_kubevirt.sh` | `KUBEVIRT_ENABLED` | 🧩 伪代码占位 |
| P3-1 | Lustre CSI | `03_addon/11_lustre_csi.sh` | `LUSTRE_CSI_ENABLED` | 🧩 伪代码占位 |
| 自研 | CubeStack 平台自研组件 | `03_addon/20_cubestack_apps.sh`(20 起为自研序号) | `CUBESTACK_APPS_ENABLED` | 🧩 伪代码占位 |

> 镜像仓库双定位:集群外私有仓库 = **Harbor**(唯一方案,替代原本地 docker registry);集群内 registry = kubespray addon(`03_addon/03_k8s_registry.sh`, `REGISTRY_ENABLED=0` **默认不部署**)。

> ✅ 已实现 · 🧩 伪代码占位(已按 addon_stub 框架实现, 待替换真实逻辑) · 📋 规划未实现
>
> 附注:local-path-provisioner 默认**不启动**(`LOCAL_PATH_ENABLED=false`);需本地 PVC 持久化的组件(registry/Harbor 等)需先启用该开关或改用其他 StorageClass。
