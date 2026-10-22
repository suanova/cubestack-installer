# NVIDIA GPU Operator 部署指南(在线 / 离线)

> 模块: `modules/03_addon/08_nvidia_gpu_operator.sh` + `28_verify_nvidia_gpu.sh`(2026-10-14 新增)
> 版本基线: GPU Operator **v26.7.2**(chart vendored:`deployments/cubestack-addon/nvidia-gpu-operator/`)、
> 驱动分支 **595**、内核 **5.15.0-186-generic**(与金标镜像一致)。
> 支持面: **Ubuntu 22.04 x86_64**(预编译驱动限制; 其它 OS 会被告警拦截, 见"驱动策略")。

---

## 1. 它是什么

英伟达官方 GPU Operator,统一管理全部 GPU 组件(一个 ClusterPolicy CR 描述,operator 在运行期投递):

| 组件 | 作用 | 本仓默认 |
|---|---|---|
| driver(预编译容器) | NVIDIA 内核驱动(镜像内已带内核模块,**运行期零下载**) | ✅ |
| container-toolkit | 容器运行时 GPU 注入(CDI 默认开) | ✅ |
| device-plugin (+GFD) | `nvidia.com/gpu` 扩展资源注册(v26 起 GFD 并入该镜像) | ✅ |
| dcgm-exporter | GPU 指标导出(Prometheus 格式) | ✅ |
| mig-manager | MIG 几何管理(仅 MIG 能力卡上运行) | ✅ |
| vfio-manager / driver-manager | 驱动根文件系统与设备准备 | ✅ |
| NFD | 节点特征发现(预编译驱动**按内核选镜像**依赖它的标签) | ✅(集群已有 NFD 时让位) |
| vGPU / DRA / sandbox / GDS | 未纳入离线支持(默认关) | ❌ |

与其他 GPU 模块的关系:**沐曦(06)与英伟达(08)相互独立**,同集群可各自开关,互不影响。

## 2. 前置条件

- 集群由本仓库部署完成(k8s_deploy + k8s_registry 可达); 节点 **Ubuntu 22.04 x86_64**;
- GPU 节点内核必须在 `NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS` 白名单内(模块自动门禁, 不覆盖即报错);
- 离线部署需先备料镜像(见 §3.1); 在线部署需节点可达 nvcr.io(或经 Harbor 镜像)。

## 3. 离线安装(默认, full air-gap)

```bash
# ① 镜像同步到 Harbor(GitHub Action, 2026-10-14 用户口径: Harbor 为唯一镜像源):
#    push 本变更后, .github/workflows/sync-images-to-harbor.yml 自动全量同步(清单驱动, 新组随车);
#    也可手动触发(workflow_dispatch) groups=nvidia-gpu-operator 定向同步。
#    目标: harbor.isuanova.com/mirrors/nvcr.io/** 与 mirrors/registry.k8s.io/nfd/**(NFD)。
# ② 从 Harbor save 离线 tar(联网机; **Harbor 优先、上游回退**; skopeo 直拉, 免 root/docker):
sudo ./deployments/scripts/tools/images/nvidia-save-images.sh
#    → deployments/offline-files/nvidia-gpu-operator/*.tar(约 3.4GB, 驱动占大头; 含内核覆盖预检)
#    等价通用通道: tools/images/harbor-save-images.sh --group nvidia-gpu-operator(纯 Harbor; 不含 NFD)

# ③ 离线环境: 开启开关并部署
sudo ./deploy-cluster.sh --enable nvidia_gpu_operator    # 写入 cluster.conf(下次全量生效)
sudo ./deploy-cluster.sh --steps nvidia_gpu_operator     # 或立即单跑

# ④ 端到端验证
sudo ./deploy-cluster.sh --steps verify_nvidia_gpu
```

部署链(模块内部): 渲染提取镜像集(与安装同参)→ tar 推入集群内置 registry 的
`mirrors/nvcr.io/**` → 各组件 repository 覆盖为集群 registry(节点不访问外网)→ helm 安装
→ 活体 CR 自检/纠偏 → GPU 探测与 `nvidia.com/gpu` 可调度性检查。

## 4. 在线安装

```bash
# cluster.conf: ONLINE_DEPLOY_NVIDIA_GPU_OPERATOR=true
#   镜像按 chart 定义从 nvcr.io 直拉(不推集群 registry);
#   若集群只可达 Harbor 镜像(CI 已同步 mirrors/nvcr.io/**):
#     NVIDIA_GPU_OPERATOR_ONLINE_IMAGE_BASE="harbor.isuanova.com/mirrors"
sudo ./deploy-cluster.sh --steps nvidia_gpu_operator
```

chart 刷新: `NVIDIA_GPU_OPERATOR_CHART_SYNC=auto`(默认)探测 nvcr.io 可达 → 比对 digest 刷新
vendored 副本; 离线机自动纯本地。升级手册见 chart 目录 `CUBESTACK.md`。

## 5. 驱动策略(核心)

**预编译驱动容器**(`usePrecompiled=true`, 分支 595): 驱动镜像 = `driver:595-<内核>-ubuntu22.04`,
内核模块已随镜像发布 → **驱动容器运行期不下载任何 OS 包、不需要本地包源** —— air-gap 官方推荐路径。

> **宿主驱动优先(2026-10-22)**: 有卡节点若已装**可用宿主驱动**(`nvidia-smi -L` 成功), operator 会打
> `nvidia.com/gpu.deploy.driver=pre-installed` 并跳过 driver DaemonSet。安装器据此**跳过预编译内核门禁**,
> 也不再准备该内核的驱动镜像。只有**没有可用宿主驱动**的节点才需要预编译驱动容器, 才检查内核覆盖。

三条纪律:

1. **内核覆盖预检(仅无宿主驱动的节点)**: 这些节点的内核必须恰在 NGC 预编译列表(NGC 随 Ubuntu 内核更新陆续构建)。
   备料侧: `nvidia-save-images.sh` 内置存在性预检(不存在即报错并给出查询命令);
   部署侧: 模块对**需要容器驱动**的有卡节点 `uname -r` 做白名单门禁(fail-fast + 补拉指令)。
   速查: `skopeo list-tags docker://nvcr.io/nvidia/driver | grep '"595-'`。
2. **内核升级 = 一次变更**: 升级节点内核前, 先确认新内核有对应预编译镜像 → 补拉 tar → 更新
   `NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS` → 重跑模块。**不允许**"先升内核、再碰运气"。
3. **边界(如实标注)**: v26.7.2 将该特性标注为 **tech-preview(仅 ubuntu22.04)**; 不支持 vGPU/GDS;
   混 OS 集群不支持(driver 容器要求同 OS)。

> **实测(2026-10-22)**: Ubuntu 22.04 的 `5.15.0-198-generic` 在 NGC `595` 分支**尚无**预编译镜像
> (`skopeo list-tags docker://nvcr.io/nvidia/driver | grep '"595-'` 最新覆盖到 `5.15.0-187-generic`)。
> 但本次节点已有**可用宿主驱动 `580.178.04`**, operator 走 `pre-installed`, 因此 198 的覆盖缺失不影响它
> (安装器现在也会跳过该节点的预编译门禁)。若节点**没有**宿主驱动且内核 198, 则只有两条路:
> ① 节点安装并启动到已覆盖内核(如 `5.15.0-186-generic`, 与金标镜像/离线驱动 tar 一致);
> ② 按下方"退路"自制带包驱动镜像。
> **不要**把 `5.15.0-198-generic` 直接写进白名单 —— 镜像不存在, operator 会 `ImagePullBackOff`。

**退路(内核不在覆盖表/需定制时)**: 自制"带包驱动镜像" —— 在联网机把该内核的
`linux-headers/-image/-modules` deb 闭包烤入官方 driver 镜像(同名 tag, 容器内配 file:// 本地源),
对本模块完全透明(仍走 tar→registry→覆盖 repository)。规程与脚本未随本版落地(按需实现)。

## 6. cluster.conf 变量表

| 变量 | 默认 | 说明 |
|---|---|---|
| `NVIDIA_GPU_OPERATOR_ENABLED` | false | 总开关(--enable / --steps / true) |
| `ONLINE_DEPLOY_NVIDIA_GPU_OPERATOR` | false | 在线/离线部署模式(2026-10-16 起在 cluster.conf 主文件"附加组件开关"区) |
| `NVIDIA_GPU_OPERATOR_VERSION` | v26.7.2 | chart 版本(★ 升级只改这里) |
| `NVIDIA_GPU_DRIVER_BRANCH` | 595 | 驱动**分支号**(预编译模式) |
| `NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS` | 5.15.0-186-generic | 有卡节点内核白名单(逗号分隔) |
| `NVIDIA_GPU_DRIVER_PRECOMPILED_KERNEL` | (白名单首项) | 镜像清单登记用单内核 |
| `NVIDIA_GPU_OPERATOR_NAMESPACE` | gpu-operator | 命名空间 |
| `NVIDIA_GPU_OPERATOR_CHART_SYNC` | auto | chart 刷新 auto/online/offline |
| `NVIDIA_GPU_OPERATOR_ONLINE_IMAGE_BASE` | 空 | 仅在线: 镜像前缀(如 Harbor mirrors) |
| `NVIDIA_GPU_OPERATOR_OFFLINE_DIR` | offline-files/nvidia-gpu-operator | 离线 tar 目录 |

## 7. 验证与边界

`--steps verify_nvidia_gpu` 四步: ①全部 Pod Running/Completed ②ClusterPolicy ready
③PCI 探测有卡判据(0x10de, sysfs, 不依赖 nvidia-smi) ④**有卡**: allocatable + `cuda-vectoradd`
跑通(`Test PASSED`); **无 NVIDIA 卡**: 组件级通过 + 醒目"未验真卡"边界提示。

> **“纯 CPU”判定(2026-10-22)**: 无 NVIDIA 卡时还会探测沐曦(`mx-smi`); 只要检测到沐曦 GPU 就不称纯 CPU;
> `mx-smi` 不可用时同样**不判定**纯 CPU(NVIDIA PCI 0x10de 与沐曦都明确为 0 才算纯 CPU)。

⚠ 本仓库测试集群无 NVIDIA 硬件 → 端到端验证须在真卡环境执行; 真卡首验清单:
`kubectl -n gpu-operator get pods` 全绿 → `nvidia-smi` 在 driver pod 内可用 →
`nvidia.com/gpu` 可调度 → cuda-vectoradd PASSED。

## 8. 卸载与残留

`cluster-teardown` 反序优雅卸载,或手工卸载分支(模块内): helm uninstall → 5 个 CRD →
命名空间清理。**节点侧残留**(不在模块清理范围, 按需人工处理): 已加载的内核模块(重启清除)、
`/run/nvidia` 驱动根、containerd 的 `99-nvidia.toml` 注入配置(重装会被 operator 重管)。

## 9. 故障排查

| 症状 | 首查 | 常见根因 |
|---|---|---|
| Pod ImagePullBackOff(离线) | 镜像是否推入 registry:`curl <registry>/v2/.../tags/list` | 离线 tar 缺料(看模块推送日志"未就绪") |
| driver DS 不落地 | `kubectl get nodes -L feature.node.kubernetes.io/pci-10de.present` | NFD 未就绪(标签未生成) |
| driver pod CrashLoop | `kubectl -n gpu-operator logs ds/nvidia-driver-daemonset` | 内核不在预编译覆盖(镜像拉不到) / tech-preview 特性异常 |
| allocatable 为空 | 设备插件 pod 日志 / validator job | 驱动未加载、CDI 注入失败 |
| ClusterPolicy not ready | `kubectl describe clusterpolicy` 的 conditions | 组件缺失/镜像前缀漂移(模块自检会纠偏) |
| 升级 chart 后推送集异常 | `bash tools/images/nvidia-chart-images.sh <tgz>` | 提取绊线报错 = chart 形态漂移, 核对提取逻辑 |

## 10. 升级流程(运维)

1. `CUBSTACK.md` 拉新 chart + 更新 digest 边车 + 改 `NVIDIA_GPU_OPERATOR_VERSION`;
2. `nvidia-save-images.sh` 重备镜像; 核对新 chart 的组件 tag 变更(images.manifest 同步);
3. `--steps nvidia_gpu_operator` 重跑(REPEAT:0 → 先 `--fresh` 或删 `nvidia_gpu_operator` 状态);
4. `--steps verify_nvidia_gpu` 复核。
