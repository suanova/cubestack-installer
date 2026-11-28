# T-Head 真武 PPU Device Plugin 方案分析

> 结论等级说明：  
> **已验证** = 本次实际拆镜像/读源码/跑测试得到；  
> **官方文档** = T-Head/阿里云公开文档或仓库；  
> **推断** = 基于事实的工程设计，需真机验证。

## 0. 结论速览

| 方案 | 可行性 | 适用场景 | 主要风险 |
|---|---|---|---|
| **ACK `ack-ppu-device-plugin` 镜像** | **PoC 可行**（已验证镜像自包含用户态库） | CubeStack 默认优先；整卡优先 | 非 ACK 官方支持；KMD ABI 必须匹配；无公开 DS/RBAC；CDI/topology/切片需实测 |
| **GPUStack Operator 的 PPU 方案** | **K8s 原生最完整**（官方标记 Experimental） | 需要 `.shared/.sliced/.partitioned`、Kueue、NFD | 组件多；M890P 无硬件 MIG；切片是用户态加权 QoS；真机验证以 ZW810E 为主 |
| **LJ-RuntimeKit** | **仅装 KMD 不可用** | 灵骏裸金属、已预装闭源 Runtime 包 | 缺 xdm/xpu-container-runtime/lj-runtime/10255；资源名与 ACK/AIStack 不兼容 |
| **自研 `t-head-ppu-device-plugin`** | **整卡 fallback 可用**（PoC/自维护） | ACK PoC 失败后的兜底；整卡 | 不做切片/MIG/拓扑；依赖 `ppu-smi` 格式；未在真机验收 |

**CubeStack 策略：ACK PoC 优先，native fallback。** 两种插件都上报
`alibabacloud.com/ppu`，同一节点只能装一个。

---

## 1. ACK `ack-ppu-device-plugin` 方案

### 1.1 已核实的镜像事实

镜像：

```text
registry-cn-wulanchabu.ack.aliyuncs.com/acs/ppu-device-plugin:v1.4.0-8a13b6d4-topology-aliyun
```

实际拆解结果：

- `linux/amd64`，Ubuntu 24.04.4 LTS。
- 入口：`/opt/run.sh` → `/usr/bin/ppu-device-plugin`。
- Go module path：`gitlab.alibaba-inc.com/eml/ppu-device-plugin`
  （不是 `github.com/lj-runtimekit/device-plugin`）。
- 镜像自带 PPU 用户态库：
  ```text
  /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1
  /usr/lib/x86_64-linux-gnu/libhgml.so
  /usr/lib/x86_64-linux-gnu/libuki.so
  ```
- 不带 KMD；没有 KMD 时运行报：
  ```text
  Error: failed to initialize NVML: Driver Not Loaded
  ```
- 访问的设备/系统路径：
  ```text
  /dev/alixpu
  /dev/alixpu_ctl
  /dev/alixpu_ppu<N>
  /dev/alixpu-caps/alixpu-cap<minor>
  /dev/alixpu_sep
  /proc/driver/alixpu/capabilities
  ```
- CLI 参数：
  ```text
  --enable-topology
  --imex-channel-ids
  --imex-required
  --enable-cdi
  --cdi-vendor   （默认 alibabacloud.com）
  ```
- 使用 Kubernetes API（client-go）做 Pod/Node/annotation 协调，会写：
  ```text
  gputopology.alibabacloud.com/allocation
  gputopology.alibabacloud.com/reconciled-at
  gputopology.alibabacloud.com/reconciled-from
  gputopology.alibabacloud.com/pre-reconcile-allocation
  alibabacloud.com/hypernode-link
  ```
- 未发现 `/run/amp/eKitC/xdm/sockets` 或 `lj-runtime` 依赖。

> 结论：ACK 镜像是**自带 PPU 用户态库的独立插件**，不是 LJ-RuntimeKit 的
> “薄插件 + xdm 节点代理”。之前报告里“ACK 的开源底座是 LJ-RuntimeKit”这一句，
> 至少对当前镜像不成立。

### 1.2 可行性判断

**技术上可以在 CubeStack 自建集群做 PoC。** 需要补齐的最小集合：

```text
1. 宿主 KMD（与镜像内 libuki/libhgml ABI 匹配）
2. /dev/alixpu* 设备节点
3. /proc/driver/alixpu（MIG 能力树/排障）
4. /sys（PCI/NUMA 拓扑）
5. /var/lib/kubelet/device-plugins
6. Kubernetes RBAC（nodes/pods/events/configmaps）
7. 可选：/var/run/cdi + containerd CDI（仅启用 --enable-cdi 时）
```

不需要：

- RuntimeClass；
- `lj-runtime`；
- xdm；
- kubelet 10255；
- LJ 的 Controller/Scheduler。

### 1.3 潜在问题

1. **KMD ABI 必须匹配**
   - 镜像内 `libuki`/`libhgml` 是 2026-08 构建的；
   - AIStack/T-Head 节点上的 KMD 版本可能不同；
   - 典型症状：`Driver Not Loaded`、ioctl 失败、
     `SEP is not supported, please upgrade kernel mode driver!`；
   - 这是 ACK PoC 的第一风险。

2. **没有官方 DaemonSet/RBAC**
   - ACK 组件由 ACK 组件管理安装，公开文档没有自建清单；
   - CubeStack 里的 `deployments/cubestack-addon/t-head-ppu/ack/`
     是按二进制依赖重建的 PoC 清单，不是官方清单。

3. **CDI 是可选但会影响注入方式**
   - 默认建议不加 `--enable-cdi`，先走传统 DeviceSpec；
   - 若启用，需要 containerd 开 CDI 并挂 `/var/run/cdi`；
   - 不启用时也要保证 `/dev` 可写、`privileged`。

4. **`--enable-topology` 可能依赖 ACK 调度/注解体系**
   - 先关闭，验证整卡；
   - 拓扑/切片可能依赖 `gputopology.alibabacloud.com/*` 注解或 ACK 调度器；
   - CubeStack 默认 kube-scheduler 不一定完整支持。

5. **资源模型与 M890P**
   - ACK 文档资源名：`alibabacloud.com/ppu` + `alibabacloud.com/ppu-<u>u.<g>g<mem>gb`；
   - M890/M890P **没有硬件 MIG**；ACK 的 `ppu-*` 切片是运行时算力/显存切分，
     不是硬件 MIG；
   - 切片能力是否需要 ACK 调度器/运行时，必须实测。

6. **非官方支持/许可**
   - 镜像是 ACK 托管组件，公开可拉取不等于允许在自建集群生产使用；
   - 生产前需要阿里云/平头哥确认许可、支持边界和升级责任。

7. **离线镜像与节点拉取**
   - 镜像可匿名拉取（本次已验证）；
   - 离线时要先 mirror 到内部 registry，再由节点从内置 registry 拉；
   - 不要依赖节点直连阿里云 ACR。

8. **kubelet root-dir / socket 路径**
   - 插件必须挂载 kubelet 实际使用的 device-plugins 目录；
   - 非默认 `--root-dir` 时需要同步调整。

9. **资源名冲突**
   - 如果厂商已装同名 `alibabacloud.com/ppu` 插件，不要重复安装；
   - 两套同时运行会重复/冲突分配。

### 1.4 CubeStack 结论

默认：

```text
T_HEAD_PPU_PLUGIN_SOURCE=ack
```

先做**单节点整卡 PoC**：

1. 安装匹配 KMD，验证 `ppu-smi -L`、`/dev/alixpu*`；
2. 推 ACK 镜像到内置 registry；
3. 应用 `cubestack-addon/t-head-ppu/ack/`；
4. 验证 `alibabacloud.com/ppu` allocatable 和冒烟 Pod；
5. 通过后再评估 CDI/topology/切片；
6. 失败则切 native fallback。

---

## 2. GPUStack 的平头哥 PPU 方案

GPUStack 不是单纯的 device plugin，而是 **server + agent + operator** 的
MaaS/GPU 管理平台。它的 PPU 管理分两层：

### 2.1 探测层：`gpustack-runtime`

代码：

```text
gpustack_runtime/detector/thead.py
gpustack_runtime/detector/pyhgml/
gpustack_runtime/deployer/cdi/thead.py
```

- PCI vendor `0x1ded`。
- 使用 `pyhgml`（HGML Python 绑定）读取：
  - UUID、index、minor number、BDF、NUMA；
  - 显存、ECC、MIG 模式、MIG profiles；
  - 拓扑/ICN 信息。
- 按 `(name, memory)` 分组为 `DevicesGroup`。
- 记录 `Accelerator.Index`（枚举序号）和驱动 minor；
- **设备节点按 card ordinal 命名**：`/dev/alixpu_ppu<index>`；
- 分配时 `stat` 节点，比较字符设备 minor 与 HGML 记录的 minor；
  不一致就拒绝，防止 VFIO 重编号后挂错卡。

### 2.2 K8s 资源模型：GPUStack Operator

代码：

```text
gpustack-operator/pkg/nodefeature/knowns.go
gpustack-operator/pkg/devicemanager/allocator/thead/deviceplugin.go
gpustack-operator/pkg/devicemanager/detector/thead/device.go
gpustack-operator/pkg/deviceplugin/server.go
```

基础资源名：

```text
alibabacloud.com/ppu
```

在基础资源之上按分配模式注册多个 device plugin server：

| 模式 | 资源名 | 说明 |
|---|---|---|
| Exclusive | `alibabacloud.com/ppu` | 整卡独占 |
| Shared | `alibabacloud.com/ppu.shared` | 多 Pod 共享计数 |
| Sliced | `alibabacloud.com/ppu.sliced` | 逻辑切片注入 token |
| Sliced 计数 | `alibabacloud.com/ppu.sliced.units` | Kueue credits/精细计数 |
| Sliced 算力 | `alibabacloud.com/ppu.sliced.cores-percentage` | 节点级算力预算 |
| Sliced 显存 | `alibabacloud.com/ppu.sliced.memory-percentage` / `.memory-mib` | 节点级显存预算 |
| Partitioned | `alibabacloud.com/ppu.partitioned` | 硬件 MIG 注入 token |
| Partitioned 计数 | `alibabacloud.com/ppu.partitioned.units` | 计数/credits |
| MIG profile | `alibabacloud.com/ppu.partitioned.mig-<profile>` | 如 `mig-4g.48gb` |
| Visibility | `device.gpustack.ai/thead.visibility` | SSH sidecar 与主容器共卡 |

### 2.3 设备注入

整卡/共享/切片都返回：

```text
/dev/alixpu
/dev/alixpu_ctl
/dev/alixpu_ppu<index>
```

并校验：

```text
stat(/dev/alixpu_ppu<index>).minor == HGML 记录的 minor
```

逻辑切片额外注入 GPUStack 自带的 C shim：

```text
csrc/thead/ppu-slicing-shim/
  hggc_quota.so
  hgml_dlsym_hook.so
  ppu-monitor
```

容器内：

```text
/etc/ld.so.preload
/usr/local/vppu/hgml_dlsym_hook.so
/usr/local/vppu/hggc_quota.so
/usr/local/vppu/ppu-monitor
/var/run/vppu/ledger

HGGC_DEVICE_MEMORY_LIMIT_<i>=<MiB>
HGGC_DEVICE_SM_LIMIT=<percent>
HGGC_LEDGER_PATH=/var/run/vppu/ledger
LIBHGGC_LOG_LEVEL=1
```

特点：

- `hggc_quota.so` 拦截 `libhggc.so` 的内存分配/释放/查询；
- `hgml_dlsym_hook.so` 拦截 `dlsym`，让 `ppu-smi` 看到切片后的显存；
- 这是**用户态逻辑切片 + 加权 QoS**，不是硬件 MIG；
- 20/80 表示争用时的相对吞吐权重，不是硬 SM 分区；
- 只支持 Docker，不支持 runveil；
- 切片限额不能在线修改，改限额需要重启实例。

硬件 MIG（`.partitioned.mig-*`）：

- 通过 HGML 创建/销毁 GI/CI；
- 仅支持硬件 MIG 的卡型：810/810E/610/610E；
- **M890/M890P 不支持硬件 MIG**，该模式不适用。

### 2.4 K8s 部署

`gpustack-chart`：

```yaml
worker:
  gpuVendors:
    - thead
```

thead worker：

- nodeSelector：`feature.node.kubernetes.io/pci-1ded.present=true`（NFD）；
- hostPath：`/usr/local/PPU_SDK`、`/var/lib/kubelet/device-plugins`、
  `/var/run/cdi`；
- worker 以 `privileged`、`hostNetwork`、`hostIPC` 运行；
- **thead 不设置 runtimeClassName**（只有 nvidia/mthreads 设）；
- 依赖 NFD 生成 PCI 标签；可选 Kueue 做 credits。

### 2.5 优点与代价

**优点：**

- K8s 原生 device plugin/资源模型最完整；
- 支持 `.shared/.sliced/.partitioned` 多种分配；
- 有 HGGC 逻辑切片 shim；
- 有 MIG（仅支持卡型）；
- 有 NFD/Kueue/监控/模型目录集成。

**代价/风险：**

- 组件多（server/worker/operator/NFD/Kueue/CSI 等）；
- PPU 支持标记 Experimental；
- 真机验证以 ZW810E 为主；M890P 有 catalog 规格，但 dGPU/sleep/PD 未明确验证；
- 逻辑切片是用户态加权 QoS，不是硬隔离；
- M890/M890P 无硬件 MIG；
- 引入 GPUStack Operator 意味着另一套控制面，和 CubeStack 的模块模型需要额外适配。

### 2.6 对 CubeStack 的参考价值

CubeStack 当前只吸收 GPUStack 的关键点：

- `alibabacloud.com/ppu` 资源名；
- NFD `feature.node.kubernetes.io/pci-1ded.present` 标签；
- 设备节点 `index` 候选 + `stat` 字符设备 minor 校验；
- 严重 ECC/XID 健康判定。

**没有引入** GPUStack Operator、`.sliced` shim、MIG、Kueue。  
如果 CubeStack 后续需要“一卡多 Pod”，优先评估 GPUStack 的 `libvppu` 方案，
而不是自研 MPS 共享。

---

## 3. LJ-RuntimeKit 为什么不能直接支持

### 3.1 它是什么

`aliyun/LJ-RuntimeKit` 是**灵骏 Runtime Kit 的容器层开源套件**：

- Device Plugin
- Scheduler Framework
- Exporter
- Controller

它通过统一 gRPC 接口对接**闭源的资源层 Runtime 包**。

### 3.2 依赖链

```text
LJ Device Plugin
  → /run/amp/eKitC/xdm/sockets/dp2mgr.sock
  → 闭源 xdm / xpu-container-runtime
  → containerd lj-runtime handler
  → RuntimeClass lj-runtime
  → kubelet 10255
```

### 3.3 缺少的东西

只安装 KMD + SAIL SDK 时，以下全部缺失：

1. **xdm 守护进程/socket**
   ```text
   /run/amp/eKitC/xdm/sockets/dp2mgr.sock
   /run/amp/eKitC/xdm/sockets/config-daemon.sock
   ```
   Device Plugin 的 `wait-xdm-ready` init container 会一直等，DS 不会 Ready。

2. **xpu-container-runtime 二进制**
   ```text
   /usr/local/harp/kitC/xpu-container-runtime
   ```
   用于 containerd 的 `lj-runtime` handler 和设备注入。

3. **containerd `lj-runtime` handler**
   ```toml
   [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.lj-runtime]
     runtime_type = "io.containerd.runc.v2"
     container_annotations = ["xdm.amp.com*"]
   [..options]
     BinaryName = "/usr/local/harp/kitC/xpu-container-runtime"
     SystemdCgroup = true
   ```
   没有 handler，Pod 使用 `runtimeClassName: lj-runtime` 会直接失败。

4. **RuntimeClass**
   ```yaml
   apiVersion: node.k8s.io/v1
   kind: RuntimeClass
   metadata: {name: lj-runtime}
   handler: lj-runtime
   ```
   可以手工创建，但 handler 不存在时没有意义。

5. **kubelet 只读端口 10255**
   Device Plugin 的 checkpoint GC 依赖它；kubespray 默认
   `kube_read_only_port: 0`，需要显式开启。

6. **Controller / Job Agent**
   节点 label 触发的 enable/disable 流程；没有它，xdm 功能开关无法自动管理。

7. **Scheduler / Exporter**
   官方套件的一部分；TDM/拓扑调度和监控需要它们。

8. **闭源 Runtime 包本身**
   闭源、随灵骏裸金属 OS 镜像预装，不在 GitHub 仓库中；
   KMD/SDK 不提供这些组件。

### 3.4 资源模型不兼容

LJ-RuntimeKit 的 Device Plugin 资源：

```text
aliyun.com/gpu
aliyun.com/gpu-core
aliyun.com/gpu-memory
```

ACK/AIStack/GPUStack/官方 `ppu-scheduler-action` 使用：

```text
alibabacloud.com/ppu
```

如果现有工作负载、模型模板、官方 Action 按 `alibabacloud.com/ppu` 写的，
切到 LJ 需要改工作负载；反之亦然。

### 3.5 什么时候才可能用 LJ

只有同时满足：

1. 节点是灵骏裸金属，或能拿到**灵骏 Runtime 包**；
2. Runtime 包已安装并运行（xdm socket 存在）；
3. containerd 已注册 `lj-runtime` handler；
4. 能接受 `aliyun.com/gpu*` 资源名；
5. 需要 TDM/显存算力切分/拓扑调度。

否则 **KMD + SAIL SDK 不等于 LJ 可用**。

> 另外：ACK 镜像不是 LJ-RuntimeKit 的构建产物。ACK 镜像自带
> `libuki/libhgml/libnvidia-ml`，没有 xdm 依赖；不要因为两者都来自阿里就认为
> “装 ACK 就等于装 LJ”。

---

## 4. 自研 Device Plugin 兜底方案

### 4.1 定位

仓库：

```text
/opt/t-head-ppu-device-plugin
```

- 纯 Kubernetes Device Plugin；
- 只做**整卡**；
- 资源名 `alibabacloud.com/ppu`；
- 不依赖 ACK/LJ/GPUStack；
- 作为 ACK PoC 失败后的 fallback。

### 4.2 实现要点

**发现：**

```text
ppu-smi --query-ppu=index,name,architecture,uuid,minor_number,pci.bus_id
  --format=csv,noheader,nounits
```

回退：

```text
ppu-smi -L + ppu-smi -q -i <UUID>
ppu-smi -q
```

**设备身份/节点解析：**

```text
index -> driver minor -> driver minor-1 -> ppu-smi minor -> ppu-smi minor-1
```

每个候选：

1. 读 `/proc/driver/alixpu/ppus/*/information` 得 `Device Minor`；
2. `stat(2)` 设备节点；
3. 比较 `Rdev` minor 与 `Device Minor`；
4. 匹配才使用。

**容器注入：**

```text
/dev/alixpu
/dev/alixpu_ctl
/dev/alixpu_ppu<N>
```

使用 `DeviceSpec`，不需要 CDI/RuntimeClass。

**拓扑/健康：**

- NUMA 从 `/sys/bus/pci/devices/<BDF>/numa_node` 读取，填 `TopologyInfo`；
- CSV 健康列：volatile uncorrected ECC、remapped_rows.failure、XID
  reset/reboot/power-cycle；严重时标记 Unhealthy；
- 历史 aggregate ECC / retired pages 不直接判坏。

**节点选择：**

- NFD `feature.node.kubernetes.io/pci-1ded.present=true`；
- 或 installer fallback `ppu.example.com/device=true`；
- 二者在 DaemonSet `nodeAffinity` 中 OR。

### 4.3 CubeStack 集成

模块：

```text
15_t_head_ppu_runtime.sh   # KMD/SDK 预检/可选安装 + 标签
16_t_head_ppu_device_plugin.sh  # ack|native 切换 + 推镜像 + apply + 校验
24_verify_t_head_ppu.sh    # DS/allocatable/冒烟 Pod
```

开关：

```bash
T_HEAD_PPU_ENABLED=true
T_HEAD_PPU_PLUGIN_SOURCE=ack      # 默认
# T_HEAD_PPU_PLUGIN_SOURCE=native # fallback
```

切换：

```bash
T_HEAD_PPU_PLUGIN_SOURCE=native sudo ./deploy-cluster.sh --steps t_head_ppu --fresh
```

### 4.4 限制

- 不做 `.shared/.sliced/.partitioned`；
- 不做硬件 MIG；
- 不做 HGGC 逻辑切片；
- 不做 ICN/拓扑亲和（只填 NUMA）；
- 不做 CDI；
- 不做自动 reset/reclaim；
- 健康是 best-effort，不是 GPUStack 的完整分级/修复流程；
- 依赖 `ppu-smi` 输出格式和宿主 SAIL SDK；
- 未在 M890P 真机验收，需要单节点先跑通。

---

## 5. 选型建议

| 需求 | 建议 |
|---|---|
| CubeStack 整卡、先快速上线 | **ACK PoC 优先**；失败切 native |
| 需要 `.shared/.sliced` 一卡多 Pod | 评估 **GPUStack Operator + libvppu**；不要用 native 硬撑 |
| 需要硬件 MIG | 仅 810/810E/610/610E；M890/M890P 排除；评估 GPUStack/LJ |
| 需要 TDM/显存算力切分/拓扑 | 只有 LJ-RuntimeKit（前提：有灵骏 Runtime 包） |
| 完全不想引入闭源运行时 | native 整卡插件；接受无切片/无 MIG |
| 需要 K8s 原生 + Kueue/NFD | GPUStack Operator |

**落地顺序：**

1. ACK 单节点整卡 PoC；
2. 通过 → 全量 ACK；需要切片再评估 `--enable-cdi/--enable-topology`；
3. 失败 → native fallback；
4. 需要高级切分 → 评估 GPUStack Operator 或 LJ（仅当 Runtime 包可得）。

---

## 6. 参考

- [ACK ack-ppu-device-plugin](https://help.aliyun.com/zh/ack/product-overview/ack-ppu-device-plugin)
- [ACK ack-ppu-exporter](https://help.aliyun.com/zh/ack/product-overview/ack-ppu-exporter)
- [aliyun/LJ-RuntimeKit](https://github.com/aliyun/LJ-RuntimeKit)
- [灵骏 Runtime Kit 部署与版本指南](https://help.aliyun.com/zh/intelligent-computing-lingjun/deployment-and-release-guide)
- [GPUStack](https://github.com/gpustack/gpustack)
- [GPUStack Operator](https://github.com/gpustack/gpustack-operator)
- [T-Head 容器隔离指南](https://developer.t-head.cn/docs_center/doc_detail/index.html?projectId=33&chapterId=687)
- [T-Head 部署方式](https://developer.t-head.cn/docs_center/doc_guide/index.html?projectId=40&chapterId=750)
- [T-Head PPU-SMI 使用指南](https://developer.t-head.cn/docs_center/doc_detail/index.html?projectId=39&chapterId=1067)
- [t-head/ppu-scheduler-action](https://github.com/t-head/ppu-scheduler-action)

> 本地代码：
> - CubeStack 模块：`deployments/scripts/modules/03_addon/15_t_head_ppu_runtime.sh`、
>   `16_t_head_ppu_device_plugin.sh`、`24_verify_t_head_ppu.sh`
> - native 插件：`/opt/t-head-ppu-device-plugin`
