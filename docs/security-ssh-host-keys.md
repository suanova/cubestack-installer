# SSH 主机密钥信任(安全加固跟进项)

> 记录时间: 2026-10-28。触发: CodeRabbit 对 `node-net-guard.sh` 的 Major/Security 评论。
> **状态: 部分修复(2026-10-28)** —— `node-net-guard` 的节点 SSH 已改为
> `StrictHostKeyChecking=accept-new` + 持久 known_hosts；全仓其余 SSH 调用仍沿用旧模型，
> 作为独立的全仓改进项跟进。

## 现状(证据)

- 全仓仍有 `StrictHostKeyChecking=no` 约 101 处、`UserKnownHostsFile=/dev/null` 约 101 处
  (node-net-guard 已不再计入)；包括基础免密注入 `tools/node/setup-passwordless.sh:44-71`
  (密码注入同样如此)。
- `tools/node/node-net-guard.sh`: 已局部修复(见下)。
- kubespray `deployments/kubespray/kubespray/ansible.cfg:15` 设置 `host_key_checking=False`。
- 仓库没有 known_hosts、SHA256 指纹或全局严格校验开关可复用。

## 已落地(局部, 2026-10-28)

`tools/node/node-net-guard.sh` 的密钥/密码两条 SSH 分支统一改为:

- `StrictHostKeyChecking=accept-new` +
  `UserKnownHostsFile=${NODE_NET_GUARD_SSH_KNOWN_HOSTS:-${SSH_KEY_DIR}/cubestack_known_hosts}`；
- 策略 `NODE_NET_GUARD_SSH_HOST_KEY_CHECKING`(默认 `accept-new`；`yes` 需预置 known_hosts；
  `no` 仅限受信 lab)，非法值硬失败；
- 首次连接仍为 TOFU，但之后换钥会拒绝；VM 同 IP 重建后需删除 stale 条目
  (`ssh-keygen -R <ip> -f <known_hosts>`)再重试；
- 回归：`test-node-net-guard.sh` ⑫(静态校验 + 非法策略非 0)。

## 风险(全仓其余调用)

在 DNS/ARP/IP 被重定向或主机被冒充时:

- 密码回退会泄露 `NODES` 密码；
- privileged 载荷会在错误主机上执行；
- 密钥分支不会泄露私钥，但仍可能把载荷发到冒充主机。

`node-net-guard` 已用 accept-new + 持久 known_hosts 缓解"换钥冒充"；**首次连接仍是 TOFU**，
全仓其它步骤(含基础免密注入、各 addon/verify 工具)仍在旧模型下。

## 为什么其余调用不在本 PR 一并改

- 局部 `accept-new` 首连仍是 TOFU，达不到"已校验"；本次只作为 node-net-guard 的缓解；
- 本安装器经常同 IP 重建 VM/节点，旧 known_hosts 会让相关步骤单独失败 → 需要全仓统一的
  刷新/逃生流程；
- 评审要求的 "established trusted host-key configuration" 当前不存在，需要一次全仓设计。

## 建议方案(独立 PR)

1. **信任来源**: 运维在带外提供节点 host key 的 SHA256 指纹(写入 `cluster.conf`/inventory，
   或由受信管理中生成的 managed known_hosts)，并明确指纹轮换流程。
2. **统一实现**: `lib-common.sh` 增加 `ssh_node` 助手(密钥/密码两分支)，固定
   `StrictHostKeyChecking=yes` + `UserKnownHostsFile=<managed>`；替换全仓约 100 处直接 ssh
   调用(含 setup-passwordless、各 addon/verify 工具；node-net-guard 已完成局部 accept-new)。
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
