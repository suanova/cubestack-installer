# SSH 主机密钥信任(安全加固跟进项)

> 记录时间: 2026-10-28。触发: CodeRabbit 对 `node-net-guard.sh` 的 Major/Security 评论。
> **状态: 未修复** —— 当前与仓库既有的基础免密注入/全仓 SSH 调用保持同一模型；
> 作为独立的全仓安全改进项跟进，不在当前 PR 内做局部改动。

## 现状(证据)

- 全仓 `StrictHostKeyChecking=no` 约 102 处、`UserKnownHostsFile=/dev/null` 约 98 处；
  包括基础免密注入 `tools/node/setup-passwordless.sh:44-71`(密码注入同样如此)。
- `tools/node/node-net-guard.sh:322-331`: 密钥优先 + `sshpass` 密码回退，两条分支均不校验
  主机密钥；密码分支会把节点密码发送给应答该地址的主机，并执行 privileged 载荷。
- kubespray `deployments/kubespray/kubespray/ansible.cfg:15` 设置 `host_key_checking=False`。
- 仓库没有 known_hosts、SHA256 指纹或 `SSH_KNOWN_HOSTS`/严格校验开关可复用。

## 风险

在 DNS/ARP/IP 被重定向或主机被冒充时:

- 密码回退会泄露 `NODES` 密码；
- privileged 载荷会在错误主机上执行；
- 密钥分支不会泄露私钥，但仍可能把载荷发到冒充主机。

影响面是全仓所有依赖 SSH 的部署/运维步骤，不只是 node-net-guard。

## 为什么不在本 PR 局部改

- 只改一个模块(`accept-new` + 持久 known_hosts)首连仍是 TOFU，达不到"已校验"；
- 本安装器经常同 IP 重建 VM/节点，旧 known_hosts 会让该模块单独失败，其它模块照常连接
  → 行为不一致、排障更乱；
- 评审要求的 "established trusted host-key configuration" 当前不存在，需要一次全仓设计。

## 建议方案(独立 PR)

1. **信任来源**: 运维在带外提供节点 host key 的 SHA256 指纹(写入 `cluster.conf`/inventory，
   或由受信管理中生成的 managed known_hosts)，并明确指纹轮换流程。
2. **统一实现**: `lib-common.sh` 增加 `ssh_node` 助手(密钥/密码两分支)，固定
   `StrictHostKeyChecking=yes` + `UserKnownHostsFile=<managed>`；替换全仓约 100 处直接 ssh
   调用(含 node-net-guard、setup-passwordless、各 addon/verify 工具)。
3. **kubespray 对齐**: 评估并打开 `ansible.cfg` 的 host_key_checking(或提供 inventory 级开关)，
   与 installer 使用同一 managed known_hosts。
4. **失败处理**: 指纹不匹配 fail-closed，输出清晰指引与"VM 重建后刷新指纹"的命令；
   提供显式、醒目的 lab 逃生口(默认关闭)。
5. **回归**: 假 ssh/known_hosts 夹具覆盖首连记录、换钥拒绝、密码分支不向未校验收发密码。

## 验收标准

- 默认路径下，任一 SSH 连接在使用密码/执行载荷前完成主机密钥校验；
- 换钥/冒充场景硬失败并点名节点；
- VM 重建有明确的指纹刷新流程；
- 全仓不再出现 `StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null`(逃生口除外)。
