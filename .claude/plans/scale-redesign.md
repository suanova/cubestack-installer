# 扩容(worker 节点)流程重构方案

## 目标
1. `--with-scale` 只做扩容,绝不连带执行 operator(gpu_operator/lws/envoy 等)或 k8s_deploy
2. 扩容前先登录首个 master 核对**实际集群节点**,基于实际节点做 diff,集群不可达则中止(绝不盲扩)
3. 修复 kubespray runc role `apt-get remove runc` 失败(apt 状态被 workerbm 的 `dpkg -i` 破坏)
4. 扩容只对新节点上传/安装(workerbm/ntp/registry 配置),不重复触碰已有节点
5. inventory/registry 保持默认: 首个 master 节点 IP(nodeport 模式 REGISTRY_IP=首 master, API 入口=首 master, 已由 load_config 派生, 不改)

## 现状问题(已核实)
- `deploy-cluster.sh:127` `--with-scale` 仅 `ENABLE_ARG+=scale` → resolve_run_steps 默认全量 + scale 一起跑 → 连带 gpu_operator/gpu_lws/envoy_gateway/envoy_ai_gateway(用户日志实锤, 停在 gpu_operator 推镜像)
- `07_k8s_scale.sh:130-134` 内部调子模块(vm_sshkey/passwordless/workerbm/hosts/ntp)时**未传 ONLY_HOSTS** → 对全部节点(含已有 worker)重复装 21 个离线包
- `07_k8s_scale.sh:9` `REQUIRES: k8s_deploy` → `--steps k8s_scale` 时闭包可能拉入 k8s_deploy 重装集群(**覆盖风险**)
- `tools/node/install-worker-packages.sh:71-72` `sudo dpkg -i ... | tail -5 && rm` — 远端 shell 无 pipefail, dpkg 失败退出码被 tail(0) 吞掉 → 半装 curl 25 导致 apt 状态损坏 → 之后 kubespray runc role `apt-get remove runc` 报 `E: Unmet dependencies`
  - 证据: curl_7.81.0-1ubuntu1.25 Depends libcurl4(=1.25) 但系统 libcurl4 是 1.17; 日志已有 "Errors were encountered while processing: curl" 却被打印 ✅
  - 另: 新节点有系统 containerd 包(Depends runc) → kubespray 卸载 runc 时也冲突
- `_auto_detect_new_nodes` 只比对 IP 列($6), 集群不可达时 fallback 为"全部 worker 当新节点"(危险: 会把已有节点当新节点 join)

## 改动方案

### 1. `deployments/scripts/deploy-cluster.sh`
- `--with-scale` 分支: 设 `SCALE_ONLY=1`(保留 ENABLE_ARG+=scale)
- `resolve_run_steps` 之后: 若 `SCALE_ONLY=1` 且无 `--steps` → `RUN_STEPS=(k8s_scale)`(扩容只跑扩容模块, 内部自包含环境准备; 不连带 operator/k8s_deploy/外层重复模块)
- 更新 usage/help 中 --with-scale 描述

### 2. `deployments/scripts/modules/02_k8s/07_k8s_scale.sh`(核心重构)
- **去掉 `REQUIRES: k8s_deploy`**(k8s_scale 自包含校验集群存在, 防止闭包拉入 k8s_deploy 重装集群)
- **集群核对强化**(第一优先级):
  - 登录首个 master(密钥→密码回退), `kubectl get nodes --no-headers -o wide` 取 **name($1) + InternalIP($6) + ExternalIP($7)**
  - 校验: cluster.conf 的 master 必须都在集群节点列表里; 若**没有任何 master 命中** → 中止(说明 cluster.conf 与真实集群脱节)
  - 集群不可达(kubectl 无输出)→ **中止并给出指引**, 不再 fallback 全当新节点
  - diff: worker 的 hostname **或** IP 命中集群节点 → 已有; 否则 → 新节点
  - `--only` 手动模式同样先过集群校验(所选节点已在集群 → warn 跳过)
- **子模块调用带 ONLY_HOSTS=新节点**(`export ONLY_HOSTS="${NEW_NODE_HOSTS}"` 包住调用, 结束 unset):
  - k8s_passwordless / k8s_workerbm / k8s_ntp 只对新节点执行
  - k8s_hosts 不传(宿主机 /etc/hosts 全量收敛, 幂等)
- **step 1.5 增补新节点 registry certs.d**(现有只同步 /etc/hosts 域名; 补 `/etc/containerd/certs.d/${REGISTRY_DOMAIN}:${REGISTRY_PORT}/hosts.toml` → 首 master nodeport, 幂等, 与 deploy-registry.sh 同款)
- 其余步骤(gen-inventory 带 SCALE_NODES / cubestack-offline.sh scale)保持

### 3. `deployments/scripts/tools/node/install-worker-packages.sh`(runc 错误根治)
- **按需复制**: 本地解析每个 deb 的 Package/Version(`dpkg-deb -f`), 远端 `dpkg-query -W` 已装版本, 已装(任何版本)跳过 → 不复制不安装(避免版本漂移破坏依赖, 也满足"不重复上传")
- **依赖预检**: 对待装 deb 解析 Depends, 依赖在(已装 ∪ 待装集)内才装, 缺依赖 → warn 跳过该 deb(宁缺毋滥, 不破坏 apt)
- **修复段(幂等)**: `dpkg --configure -a` → `apt-get install -f -y`; 失败则探测半装包(`dpkg -l` 中 unpacked/half-configured/failed-config)`dpkg --remove --force-remove-reinstreq` 后重试
- **清理系统容器包(新节点, kubelet 未运行时)**: `apt-get purge -y containerd containerd.io runc`(消除 kubespray runc role 的 Depends 冲突; 已有节点 kubelet 运行中绝不 purge)
- **失败不再掩盖**: dpkg 退出码显式捕获, 失败 → err 退出(不再 `| tail && rm` 吞错); 远端命令用 `set -o pipefail`
- 最后 `apt-get install -f -y` 收尾修复

### 4. 验证
- `bash deployments/scripts/tools/check-modules.sh` 全绿
- `bash -n` 各改动脚本
- `sudo ./deployments/scripts/deploy-cluster.sh --list-steps` 正常
- 静态确认 `--with-scale` 的 RUN_STEPS 只含 k8s_scale(可 `--list` 观测)

## 不做的事
- 不改 kubespray vendored 代码(runc role 保持原样, 从源头保证新节点 apt 干净)
- 不改 gen-inventory.sh / cubestack-offline.sh 主流程(已支持 new_node 组 + --limit)
- 不引入 master 扩容(本次只做 worker 扩容)
