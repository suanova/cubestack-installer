# offline-files 完整性校验

> 目标: 下载/拷贝/存储造成的镜像 tar、二进制、chart 损坏，在**安装开始前**被点名拦下；
> 重复部署走校验戳秒级复查。设计见
> `docs/superpowers/specs/2026-10-28-offline-files-integrity-design.md`。

## 1. 快速开始

```bash
# ① 从 MinIO 取发布版本(下载完成后自动 full 校验 + 写校验戳)
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
    --release 2.0.0 --dest /data/cubestack-installer

# ② 只校验已下载的树(不下载)
#    默认(不指定 --level) = quick 结构检查, 会明确提示; 全量请加 --level full
./deployments/scripts/tools/offline/verify-offline-files.sh \
    --root /data/cubestack-installer/2.0.0/offline-files \
    --release 2.0.0 --level full

#    只做 quick 结构 + 深度解压(不跑全量 sha)
./deployments/scripts/tools/offline/verify-offline-files.sh \
    --root /data/cubestack-installer/2.0.0/offline-files \
    --release 2.0.0 --level quick --deep

# ③ 开发/手工拷贝树: 先生成清单, 再纳入门禁
sudo ./deployments/scripts/tools/offline/verify-offline-files.sh \
    --root deployments/offline-files --seal
sudo ./deployments/scripts/tools/offline/verify-offline-files.sh \
    --root deployments/offline-files --level full

# ④ 部署(默认 quick: 结构/覆盖率; auto = 封存树首次 full, 之后走校验戳)
sudo ./deployments/scripts/deploy-cluster.sh

# 强制全量 / 跳过(逃生口)
sudo ./deployments/scripts/deploy-cluster.sh --verify-offline=full
sudo ./deployments/scripts/deploy-cluster.sh --no-verify-offline
```

不需要 `mc`、网络或 root 即可运行校验器；CLI 镜像内也提供
`cubestack-verify-offline`（同一工具）。

## 2. 布局识别

`--root` 始终指向**待校验的树本身**（包含 `SHA256SUMS` 的目录）。

| 布局 | 判定 | 示例 |
|---|---|---|
| `release` | 显式 `--layout release`（fetch 非 flat 用） | `<桶根>/2.0.0/offline-files` |
| `flat` | 根下有 `release.env` + `SHA256SUMS` | `deployments/offline-files`（release 平铺） |
| `sealed-dev` | 有 `SHA256SUMS`，无 `release.env` | 已 `--seal` 的开发树 |
| `unsealed-dev` | 无 `SHA256SUMS` | 未 seal 的开发树（只做 quick） |

## 3. 校验级别

| 级别 | 做什么 | 典型耗时 |
|---|---|---|
| `metadata` | 清单格式/路径/重复、双向覆盖、0 字节、临时文件、`_SUCCESS.sha256sums` 绑定、`release.env` 版本、`release.json` 格式、权限警告 | 秒级(仅 stat/小文件) |
| `quick` | metadata + `SIZES` 大小 + tar 结束块/tar 头、docker-archive `Config`/`Layers` 存在性、gzip/chart、ELF/deb/qcow2 魔数、`tree.tar.gz.sha256` | 秒级(不读镜像数据块) |
| `full` | quick + 全量 sha256 + **镜像 archive 深度校验**(manifest/config/layer digest) + 大包解压/CRC + CLI tar/`tree.tar.gz` | 容器 c 126G/301 文件实测 **7m36s**（layer 校验单线程）；机械盘更久 |
| `auto` | 校验戳有效 → 秒级复查；否则 full；未 seal 的开发树 → quick | 视情况 |

**默认级别是 `quick`**：不指定 `--level` 时只做结构检查（不计算全量 sha256），
输出会明确写“级别: quick（默认…）”；需要全量请显式 `--level full`。
部署门禁和 fetch 内部仍显式使用 `auto` / `full`，不受此默认影响。

缺失文件默认 `--skip-missing`：只提示“文件不存在或已被删除，已跳过”，继续校验其余
文件；有缺失时**不写校验戳**。需要严格失败时加 `--fail-missing`；部署门禁和 fetch
内部固定使用 `--fail-missing`，不会放过缺失文件。

`full` **默认就是 deep**：除了全量 sha256，还会：
- 解析镜像 archive 的 `manifest.json` / `Config`；
- 校验 `rootfs.diff_ids` 与 `Layers` 数量一致；
- 逐 layer 计算 sha256 并与 `diff_ids` 比对（gzip layer 先解压）；
- 对超大 `.tar.gz`/`.tgz` 完整解压遍历 tar；对普通 `.gz` 做完整 CRC/ISIZE。

这样 `full` 通过就意味着：字节与发布清单一致。**含 `manifest.json` 的镜像 archive**
内部结构/layer digest 自洽（缺少 `rootfs.diff_ids` 时只 warning 并跳过 layer digest 校验）。
**不含 `manifest.json` 的 tar** 只校验 tar 结构与 sha256，
不保证 `skopeo copy`/`ctr import` 可导入。
CLI tar 若可解析为 tar, 也会做同样的 tar/镜像层校验；不可解析时明确 warning 并仅做 sha256。
TTY 下镜像层校验只显示单行进度条（归档、当前 layer、i/n、大小），不再逐层刷屏；
非 TTY 只显示每个归档的开始/结束。逐 layer 的 `expected/actual/OK|FAIL` 明细写入
深度校验日志（默认 `$TMPDIR/cubestack-verify-deep-<时间>-<pid>.log`，可用
`--deep-log PATH` 指定），启动时会打印日志路径，便于验证与排障。

`--deep` 用于 **quick 也强制深度校验**（`--level quick --deep`）；`--level full` 已默认 deep。
`--deep` 较慢，按需使用。

普通 `.gz`（不是 `.tar.gz`/`.tgz`）的支持：

| 文件 | quick | full | `--deep` |
|---|---|---|---|
| `*.tar.gz`/`*.tgz` | ≤256MiB 完整遍历 tar；>256MiB 只查 gzip 魔数/页脚并提示 | 全量 sha256 + 完整解压/镜像 layer 校验 | quick 下也强制完整解压 |
| 普通 `*.gz` | ≤256MiB 做 gzip CRC/ISIZE；>256MiB 只查魔数/页脚并提示 | 全量 sha256 + 完整 CRC | quick 下也强制 CRC |

常用参数：

```bash
--jobs N          # 全量哈希并发(默认 4; 机械盘建议 1-2)
--json            # 机器可读输出(stdout 只有 JSON)
--no-stamp        # 不写校验戳(也不信任已有戳)
--force-full      # 忽略有效校验戳
--stamp-file PATH # 自定义校验戳位置
--allow-unsealed  # 无清单时允许只做结构检查
--staging         # 允许 _SUCCESS 缺失(发布 staging)
--require-cli-tar # release 布局必须有 CLI tar
--deep            # quick 下也强制深度校验(镜像 layer digest/大包解压/CRC); full 已默认
--deep-log PATH   # 逐 layer 明细日志(默认 TMPDIR/cubestack-verify-deep-*.log)
--skip-missing    # 清单登记但磁盘缺失仅警告并跳过(默认)
--fail-missing    # 清单登记但磁盘缺失即失败(部署门禁/fetch 使用)
```

退出码：`0` 通过；`1` 完整性失败；`2` 用法/环境错误（如缺 python3）。

## 4. 校验戳

- 位置：`<树根>/.cubestack-verified.json`（清单/覆盖性自动排除）。
- 只在 `full` 通过后写；内容包含 `SHA256SUMS` 的 sha 和每个文件的
  `(路径, 大小, mtime_ns, inode, dev)` 指纹。
- `auto` 先验戳：清单、文件集合、大小、mtime、inode 任一变化 → 失效 → 自动 full。
- 跨机拷贝/替换文件会失效（inode/dev 变了），从而强制 full。
- **局限**：同大小、同 mtime、同 inode 的位翻转无法由戳发现。生产首次安装、U 盘
  物理搬运后建议显式 `--level full`。

## 5. `--seal`

```bash
# 生成 SHA256SUMS + SIZES(原子写; 旧清单备份到 .cubestack-manifest-backup/<时间>/)
sudo ./deployments/scripts/tools/offline/verify-offline-files.sh \
    --root deployments/offline-files --seal

# 正式发布树(有 _SUCCESS/release.env)默认拒绝重签; 确认后加 --force
# 若表内有 _SUCCESS, 重签后必须同步它, 否则绑定校验会失败:
sudo ./deployments/scripts/tools/offline/verify-offline-files.sh \
    --root deployments/offline-files --seal --force --update-success
```

`seal` 拒绝符号链接、`.part`/`.tmp`/`.corrupt` 残留和不可读文件。
`--update-success` 会用新清单的 sha 重写 `_SUCCESS`（`release.env` 的
`RELEASE_VERSION` 必须存在）；这是**本地修复**，不是重新发布。

## 6. 安装前门禁

`deploy-cluster.sh` 在 `load_config` 之后、任何模块之前调用校验器：

- `release` / `flat` / `sealed-dev`：失败**硬停**，输出坏文件与修复命令。
- `unsealed-dev`：无清单只警告；`quick` 检出明确损坏时按
  `OFFLINE_VERIFY_STRICT_DEV=true`（默认）阻断。
- 跳过：`--list`/`--list-steps`、纯 `--steps verify_*`、仅 `--enable` 写配置。
- `load_config` 在 `source release.env` 之前会校验它在 `SHA256SUMS` 里的 sha 和
  `_SUCCESS.sha256sums` 绑定；不一致直接拒绝（损坏文件不会被 root 执行）。

配置（`cluster.defaults.conf`）：

```bash
OFFLINE_VERIFY_MODE=auto          # auto|off|quick|full
OFFLINE_VERIFY_JOBS=4
OFFLINE_VERIFY_STAMP=true
OFFLINE_VERIFY_STRICT_DEV=true
OFFLINE_VERIFY_ONLINE_INSTALL=auto  # auto|never
OFFLINE_VERIFY_TOOL_URL=...
```

## 7. fetch 校验与修复

`fetch-offline-from-minio.sh --release` 下载后调用同一校验器（`--level full`），
失败会点名文件；加 `--repair` 只重下坏文件（最多 1 轮）：

```bash
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
    --release 2.0.0 --dest /data/cubestack-installer --repair
```

坏文件会先移到 `<本地桶根>/.repair-quarantine/<版本>/<时间戳>/`（保留证据）。

下载命令默认重试 3 次（`--retry N`、`--retry-delay S`；`mc mirror` 同时启用按对象
`--retry`）。下载中断后重跑加 `--resume`：

```bash
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
    --release 2.0.0 --resume --dest /data/cubestack-installer
```

`--resume` 先 full 校验本地树；对“本地大小 < 远端大小”的文件用 `mc cat --offset`
追加剩余字节，并按 `SHA256SUMS` 的 sha256 校验；续传后不符则完整重下，
最后再全量校验。本地已完整则直接退出，不重新下载。

`--release`/`--flat` 下载默认还会**精确清理**：本地 `offline-files` 中 MinIO 不存在的
文件会被删除，使目录与远端一致；执行前有 30 秒倒计时（`--clean-countdown N`，`--yes`
跳过），非交互环境没有 `--yes` 会中止。`--no-clean` 保留本地多余文件（此时完整性
校验会因“磁盘存在但清单未登记”失败，仅建议调试）。`.cubestack-*` 校验戳/清单备份
始终保留；`--sub`/dev 模式需要显式 `--clean`，且只清理本次选中的子目录。
源端也坏时明确报错，不会无限重试。`--no-verify` 仅调试用。

## 8. 工具自举（三种来源）

1. **CLI 镜像内置**：`cubestack-installer-cli` 镜像内含
   `deployments/scripts/tools/offline/verify-offline-files.sh` 和
   `/usr/local/bin/cubestack-verify-offline`。
2. **发布树内置**：新发布树的 `offline-files/tools/verify-offline-files.sh`，由
   `SHA256SUMS` 覆盖；纯宿主机部署可直接使用（执行前先按清单引导校验）。
3. **在线安装兜底**：以上都没有时，按 `OFFLINE_VERIFY_TOOL_URL` 下载单个
   `verify-offline-files.pyz`（wrapper 本地生成），
   **最多 3 次**，必须匹配 `deployments/config/verify-tool.sha256`（或环境变量
   `OFFLINE_VERIFY_TOOL_SHA256`）才执行；哈希不符/无 pin 一律拒绝（fail-closed）。
   3 次失败：release/flat/sealed 硬停并给手动命令；未 seal 开发树警告继续。

air-gapped 环境建议 `OFFLINE_VERIFY_ONLINE_INSTALL=never`，或确保使用 CLI 镜像/
发布树副本。

## 9. 故障排查

| 症状 | 处理 |
|---|---|
| `❌ <file>: sha256 不符` | 重新拷贝该文件；release 树用 `fetch --repair` |
| `❌ <file>: 文件大小不符` | 文件被截断；同上 |
| `❌ <file>: tar 解析失败/引用成员缺失` | 镜像 tar 损坏或空壳；重新 `docker save`/重新下载 |
| `⚠ <file>: 文件不存在或已被删除，已跳过` | 默认只警告并跳过；严格校验加 `--fail-missing`；确认不要了则 `--seal --force --update-success` 重签 |
| `❌ <file>: 磁盘存在但清单未登记` | 树被改过；确认文件可信后 `--seal --force --update-success` 重签 |
| `❌ <chart>: Chart.yaml version=... != ...` | `release.env` 指定的 chart 与树内 tgz 版本不一致；重新取件或重新发布 |
| `⚠ 非 release.env 指定的 chart 版本` | 陈旧 chart 文件；确认不需要后删除并重签 |
| `❌ _SUCCESS: sha256sums 不符` | `SHA256SUMS` 与发布标记不匹配；重新取件/重新发布 |
| `❌ 校验器不可用` | 用 CLI 镜像；或从发布树 `tools/`/仓库拷贝；或检查在线安装 URL/pin |
| `auto` 没有秒过 | 校验戳失效（文件变动/跨机拷贝）；首次会 full，属正常 |
| 部署被门禁挡住但确认文件没问题 | 先 `--level full` 找出具体文件；临时逃生 `--no-verify-offline` |

## 10. 已知边界（P1）

- 发布树 `SIZES` 目前由 `--seal` 生成；正式发布树自动生成在 P1 补齐。旧树
  `quick` 会提示“无法检测截断”，`auto` 首次仍走 full。
- `.digest` 边车是 registry manifest digest，不是 tar 的 sha256，安装侧不作为
  tar 哈希使用；发布侧 provenance（tar ↔ Harbor）在 P1。
- `SHA256SUMS` 无签名；P0 只防损坏/误拷，不防恶意替换（P1 可选 minisign/GPG）。
- `dev-lab`/`model_images` 的“缺包/推送失败只 warn”行为在 P1 处理。

## 11. 实现结构与维护（模块化）

校验器源码已拆分为 Python 包，入口仍是 `verify-offline-files.sh`：

```text
deployments/scripts/tools/offline/
├── verify-offline-files.sh          # 入口: 有 pyz 执行 pyz, 否则 python3 -m verifier
├── verify-offline-files.pyz         # 单制品(zipapp), 在线安装/pin 的对象
├── build-verifier.sh                # 构建/检查 pyz 与源码一致性
├── verifier/
│   ├── cli.py          # argparse / 主流程
│   ├── layout.py       # 布局识别/文件收集
│   ├── manifest.py     # SHA256SUMS/SIZES/_SUCCESS/覆盖性
│   ├── archive.py      # tar/gzip/docker-archive/layer digest
│   ├── hashing.py      # 全量 sha256 / CLI tar
│   ├── stamp.py        # 校验戳
│   ├── seal.py         # seal/update-success
│   ├── report.py       # 人类/JSON 输出
│   ├── selftest.py     # --self-test
│   ├── context.py      # Ctx/fail/warn/deep_log
│   └── fsutil.py       # 路径/哈希/清单小工具
├── lib-offline-verify.sh   # 工具定位/在线安装(pyz + wrapper)
├── lib-offline-fetch.sh    # fetch 的 mc 重试/续传/清理/校验
└── lib-offline-gate.sh     # release.env 预校验 + 部署门禁
```

维护规则：

- 改校验逻辑只改 `verifier/` 对应模块，不直接手改 `.pyz`；
- 提交前运行：
  ```bash
  bash deployments/scripts/tools/offline/build-verifier.sh --update-pin
  PYTHONPATH=deployments/scripts/tools/offline \
    python3 -m unittest deployments/scripts/tools/tests/test_verifier_modules.py -v
  bash deployments/scripts/tools/tests/test-verify-offline-files.sh
  ```
- CI 会执行 `build-verifier.sh --check`，源码与已提交 pyz 不一致即失败；
- `deployments/config/verify-tool.sha256` 固定的是 **pyz**；在线安装只下载一个 `.pyz`，wrapper 本地生成；
- fetch/gate 的公共逻辑分别在 `lib-offline-fetch.sh` / `lib-offline-gate.sh`，改单个功能不需要动 CLI 主流程。
