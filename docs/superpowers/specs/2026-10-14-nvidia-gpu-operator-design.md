# NVIDIA GPU Operator 在线/离线部署设计(2026-10-14)

> 状态: **已实施**(2026-10-14); 实施产物见 `docs/nvidia-gpu-operator.md`。
> 决策过程: 架构级 brainstorming(环境约束→驱动策略→方案选型), 用户逐项确认。

## 决策记录

| 决策点 | 结论 | 依据 |
|---|---|---|
| 目标环境 | **全离线为主**, 在线为开关(对齐 `ONLINE_DEPLOY_*` 范式) | 用户确认 |
| 驱动策略 | **预编译驱动容器**(`usePrecompiled=true`, 分支 595) | NGC 实测覆盖 `595-5.15.0-186-generic-ubuntu22.04`; air-gap 官方推荐路径; 用户确认 |
| 架构方案 | **独立新模块** `08_nvidia_gpu_operator.sh` + `28_verify_nvidia_gpu.sh`(不改沐曦 06 模块) | 仓库隔离原则; 用户确认 |
| Online 语义 | 按 chart 定义(nvcr.io)直拉; `NVIDIA_GPU_OPERATOR_ONLINE_IMAGE_BASE` 可切 Harbor mirrors | 与 cubestack-operator 在线口径对齐 |
| NFD 处置 | 默认 operator 自带(v0.19.0, 与仓库 NFD_VERSION 同版); `NFD_ENABLED=true` 时自动让位 | 避免叠加两套 NFD |
| driver-toolkit(OpenShift DTK) | 不适用(vanilla K8s 无接线); "预编译容器"即 vanilla 世界的等价物 | values 仅 `openshift:false`; 官方文档 |

## 关键机制(实施要点)

1. **镜像集唯一来源** `tools/images/nvidia-chart-images.sh`: 解析渲染产物 —— podspec 完整 ref +
   CR 组件三元组(repository,image,version)组合, 带 `enabled` 状态过滤 + 核心组件完整性绊线;
   模块与备料工具共用(安装与提取同参, 零漂移)。
2. **实际运行驱动镜像** = `driver:<分支>-<内核>-<OS>`(operator 依 NFD 内核标签运行期组合,
   渲染产物只有占位行)→ 模块丢弃占位、按内核白名单补入内核化 ref, 并做节点内核门禁。
3. **推送布局** = `mirrors/<上游全限定 ref>`(与 Harbor mirrors 同名规则);
   幂等 = 版本化 tag 的 registry 存在性检查(不可变 tag, 无需 digest 比对)。
4. **活体 CR 自检+纠偏**(2026-10-13 教训): 在线↔离线切换后校验活体 ClusterPolicy 的
   repository 前缀, 漂移即 merge patch 纠回。
5. **验证边界**: 无卡快路径(组件级)与真卡端到端(cuda-vectoradd)分离; 无卡时醒目提示"未验真卡"。

## 风险与边界(如实标注)

- `usePrecompiled` v26.7.2 标注 tech-preview(仅 ubuntu22.04 x86_64); 不支持 vGPU/GDS; 混 OS 不支持。
- 本仓测试集群无 NVIDIA 卡 → 端到端验证在真卡环境补做(首验清单见用户文档 §7)。
- 内核不在 NGC 覆盖表时走"自制带包驱动镜像"退路(规程已文档化, 工具按需实现)。
- 禁用组件(vGPU/DRA/sandbox 等)未纳入离线支持(镜像保守备料, repository 未覆盖; 启用需按文档补)。

## 实施产物清单

`08_nvidia_gpu_operator.sh` · `28_verify_nvidia_gpu.sh` · `tools/images/nvidia-chart-images.sh` ·
`tools/images/nvidia-save-images.sh` · `cubestack-addon/nvidia-gpu-operator/`(tgz+digest+CUBSTACK.md) ·
`offline-files/nvidia-gpu-operator/README.md` · images.manifest 新组 ·
cluster.conf.example(开关/⓪组/4.7 段) · `docs/nvidia-gpu-operator.md`
