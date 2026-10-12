# 优雅覆盖安装(登记 + 反序卸载)

> 设计: design.md  · 实施计划: plan.md  · 落地: 2026-10-11

## 这是什么

`--fresh`(及一切"K8s 覆盖实际将发生"的运行)不再直接推平: 先读**集群内安装登记**, 按
**首装顺序反序**逐个优雅卸载已装组件(先停消费者 / CR 级联 / helm uninstall), **再**走
ceph 安全序, **最后** K8s 覆盖 —— 取代"暴力卸载 + 覆盖"。

全程**告警不中止**: 单组件卸载失败/超时只告警, 由后续 ceph 安全序(⓪ 泛化消费者扫描)与
kubeadm reset 兜底 —— 与"覆盖安装必成功"口径一致。

## 登记(装了什么、什么顺序、什么状态)

- **载体**: ConfigMap `cubestack-install-record` @ `kube-system`(随集群消亡, 无跨代残留)。
- **字段**: `key` / `seq`(首装序; 重跑不变) / `firstInstalledAt` / `lastSeenAt` / `status`。
  - `seq` = 新组件取"现存 max+1"; 已存在则保留原 `seq`(REPEAT:1 模块重跑不改变首装序);
  - `status` = `done`(安装成功登记) / `uninstalled`(被 cluster-teardown 卸载后回写)。
- **写入**: 各模块在**安装成功点**调用 `record_installed_component "<key>"`
  (`deployments/scripts/lib-common.sh`); **写失败仅告警, 绝不影响部署**(覆盖时自会走探测降级)。
- **登记点(11 处)**: metallb / local_path / ceph / ceph_csi / k8s_registry / gpu_operator /
  gpu_lws / multus / rdma_shared_dev_plugin / cubestack_operator / netshoot。
- **查看**: `bash deployments/scripts/tools/k8s/cluster-teardown.sh --list`

## 反序卸载规则(设计 §3.3)

候选 = 声明 `# UNINSTALL: 1` 的模块(**8 个**: ceph / k8s_registry / gpu_operator / gpu_lws /
multus / rdma_shared_dev_plugin / cubestack_operator / netshoot)∪ 登记中的组件。拆序:

1. **登记 `seq` 降序**(真装过、有首装序的, 最晚装的先卸);
2. **无登记组件**(存量集群降级路径)按**模块文件序反排**, 整组插在主序组之后: 各模块卸载段
   自带存在性检查, 集群里没有即跳过(幂等);
3. **ceph 强制压轴**(安全不变量: 所有消费者先停, 才动 ceph);
4. **metallb / local_path / ceph_csi** 无独立卸载动作(随 K8s 覆盖消亡, 仅登记; 登记里有这类
   组件时, `--uninstall` 运行时会明确列出"登记中无卸载动作的组件")。

逐组件执行: `CUBESTACK_MODULE_ACTION=uninstall bash <模块脚本>`(子进程调用), 每个组件**有界**
(默认 **600s** 超时, 超时终止, `TEARDOWN_COMPONENT_TIMEOUT` 可配); 卸载完成后把登记里该组件
标 `status=uninstalled`(审计 + 中途中断可幂等重跑)。

## 触发时机与两个挂点

- **判定**: 执行计划(RUN_STEPS)含 `k8s_deploy` 且其断点状态非 `done`(= K8s 覆盖实际将发生;
  `--fresh` 清状态后天然成立), 且集群可达(`cluster_exists` 探测通过)。计划不含 `k8s_deploy`
  (如 `--steps <组件>` 精确模式)、断点续跑已完成、`--with-scale` → 不触发。
- **挂点 A**(`deployments/scripts/deploy-cluster.sh`, 计划打印之后、ceph 预检块之前):
  密钥已在(同容器重跑场景)→ 直接执行; 执行后 ceph 预检块自然看到"无 CephCluster"
  (其删除分支空转), 顺序天然正确(`--yes` 透传给引擎)。
- **挂点 B**(`deployments/scripts/lib-module.sh`, 执行 `k8s_deploy` 之前、与覆盖提示同位):
  **新容器场景**(挂点 A 时还没有 SSH 密钥、探测不到集群)兜底 —— 此刻接入引导
  (vm_sshkey/k8s_passwordless)已跑完、密钥就绪。`CUBESTACK_TEARDOWN_DONE` 防与挂点 A 双跑。
- **非交互且无 `--yes`**: 引擎**跳过卸载并醒目警告**(节点旧集群 reset 前置会再次要求
  `--yes`, 闸门一致)。

## 手动使用

```bash
bash deployments/scripts/tools/k8s/cluster-teardown.sh --list        # 只读: 登记表 + 计划拆序(不做任何卸载)
bash deployments/scripts/tools/k8s/cluster-teardown.sh --list --raw  # 同上, TSV 机读(key/来源/脚本; 离线夹具用)
bash deployments/scripts/tools/k8s/cluster-teardown.sh --uninstall   # 执行(交互终端: 30s 倒计时后开始, Ctrl-C 可中止)
bash deployments/scripts/tools/k8s/cluster-teardown.sh --uninstall --yes   # 免倒计时(等效 CUBESTACK_ASSUME_YES=1)
```

- 可调环境变量: `TEARDOWN_CONFIRM_SLEEP`(交互确认倒计时, 默认 **30** 秒)、
  `TEARDOWN_COMPONENT_TIMEOUT`(单组件超时, 默认 **600** 秒)。
- 测试钩子(离线夹具): `CUBESTACK_TEARDOWN_TEST_INVENTORY=<file>` 以本地 JSON 代替读集群
  (文件不存在 = 空登记); 该模式下 `--uninstall` **仅打印计划, 不实际执行**。

## Ceph 的两种卸载深度

ceph 模块的卸载段做**活态判定**(看集群内有无 CephCluster, 不看本次配置的 `CEPH_MODE` —— 防
"旧集群是内部 ceph、新配置切成 external"时漏清理), 实际动作委托 `tools/k8s/ceph-cleanup.sh`:

- `CEPH_PRE_CLEANUP_EXISTING=true`(默认): 完整官方安全序(停消费者 → PVC unmap → 删集群, OSD 数据销毁);
- `CEPH_PRE_CLEANUP_EXISTING=false`(恢复/认领路径): 只停消费者 + unmap, **保留数据**;
- **external 模式**(集群内无 CephCluster): **不动** —— 外部 ceph 数据非本安装器资产, 绝不触碰。

`ceph_csi` 不设卸载段(StorageClass 等对象随 K8s 覆盖消亡), 仅登记(信息用途)。

## 失败语义

单组件失败/超时 → **告警不中止**(后续 ceph 安全序的 ⓪ 泛化消费者扫描与 kubeadm reset 兜底);
登记 `status` 记录进度, 重跑幂等续跑。引擎**运行期退出码**: **0 = 完成**(含个别失败告警, 收尾
汇总"成功 N 个, 失败/跳过 M 个"); 唯一非 0 情形是执行前探测到**集群不可达**(exit 1, 此时一个
组件也不会被卸; 参数用法错误另计)。

## 排障

- **登记为空**(存量集群/旧版本装的): 走**探测降级**(全量 `UNINSTALL` 模块按文件序反排), 属预期;
  覆盖一次后登记自然建立。
- **某组件跳过卸载**: 模块内存在性检查未命中(集群里本来就没有)属正常; 见该组件日志行。
- **手工装过组件但没登记**: 走探测降级时同样会被识别卸载(若其模块声明了 `UNINSTALL`)。
- **没看到优雅覆盖日志**: 依次核对 —— 计划里是否含 `k8s_deploy` / 其状态是否已是 `done` /
  集群是否可达; 只想核对登记: `cluster-teardown.sh --list`(⚠ 读不到时也显示"登记为空" ——
  存量集群与"集群不可达"同貌, 看 ssh 告警区分); 无人值守运行("非交互")若未 `--yes`,
  引擎会**主动跳过**并警告, 请加 `--yes` 或 `CUBESTACK_ASSUME_YES=1`。
- **卸载失败但流程继续了**: 设计如此(告警不中止); 未卸净的余量由 ceph 安全序 ⓪ 与
  kubeadm reset 兜底, 覆盖安装仍会走完全程。
