# offline-files 完整性校验设计(2026-10-28)

> 状态: **P0 已实施(2026-10-28)**; 实施产物见 `docs/offline-files-integrity.md`。
> 决策过程: 架构级 brainstorming(现状调研 → 校验强度/覆盖范围选型 → 工具交付策略 → 分期), 用户逐项确认。

## 1. 决策记录

| 决策点 | 结论 | 依据 |
|---|---|---|
| 安装前默认强度 | **首次 full + 校验戳**; 通过后写戳, 后续 auto 秒级复查; 文件变动自动失效 | 用户确认(发布树约 130G, full 在 NVMe 约 5 分钟、机械盘约 15 分钟) |
| 覆盖范围 | **release / flat / sealed-dev / unsealed-dev 全覆盖**; 开发树可用 `--seal` 纳入 | 用户确认("纳入, 可 seal") |
| 未 seal 的 dev 树 | 无清单本身只警告; **quick 检出明确损坏(截断/ELF 头坏/0 字节)仍阻断** | 用户确认("明确损坏就阻断") |
| 工具交付 | ① 默认内置 `cubestack-installer-cli` 镜像 + 发布树; ② 检测不到时在线安装, **最多 3 次** | 用户要求 |
| 实施节奏 | **先 P0, P1 单独 PR** | 用户确认 |
| 工具形态 | 单文件 `verify-offline-files.sh`(bash + 内嵌 Python), 在线安装只需一个文件/一个固定哈希 | 本设计 |

## 2. 背景与目标

### 2.1 现状关键断点(已查证)

- 发布侧有成体系的 `SHA256SUMS` + `release.json` + `_SUCCESS`(最后写), 且 `_SUCCESS` 记录了
  `sha256sums=sha256(SHA256SUMS)`(`release-publish.sh:544-554`)。
- **下载侧只对 `--release` 做校验**, 且:
  - 只判断 `_SUCCESS` 存在, **不校验 `sha256sums=` 绑定**(`fetch-offline-from-minio.sh:643-655`);
  - `sha256sum -c` 输出被 `>/dev/null` 吞掉, 失败不点名文件;
  - 不校验清单是否覆盖全部文件(清单被截断时其余文件全免检);
  - 非 release 的 `--sub/--all` 完全零校验。
- **安装侧没有任何完整性门禁**: `check_offline_files` 只判断目录非空且不阻断
  (`lib-common.sh:2575-2590`); `release.env` 被 root 直接 `source`(`lib-common.sh:842`)
  却不校验; `tree.tar.gz` 解包前不比对 `.sha256`(`cubestack-offline.sh:249-257`)。
- **会固化坏文件的机制**:
  - `cubestack-offline.sh download` 直接写最终文件且"存在即缓存"(`:600-603`、`:618`、`:645-651`);
  - `ceph-save` 只判 `size>=10MB`, `rdma-save`/`metax-save`/`harbor-save` 存在即跳过;
  - `cubestack-version-dir.sh materialize` 把损坏 tar 自身哈希写入 `.tree.sha256`, 下次跳过;
  - `dev_lab`/`model_images` 缺包或推送失败只 warn, 模块仍 `exit 0` 并被记 `done`。
- 全仓无签名/信任根; 所有 sha 校验只能防"损坏", 不能防"源被替换"。

### 2.2 目标

1. **一个校验实现, 多处调用**: 独立工具是唯一事实来源, fetch / 部署门禁 / 发布脚本 /
   `cubestack-offline.sh` 都调用它, 避免多份逻辑漂移。
2. **下载后可验、安装前必验、失败可修**: 坏文件点名到路径, 给出重新下载/拷贝/seal 的具体命令。
3. **成本可控**: 首次 full, 之后校验戳秒级复查; 跨机/拷贝/文件变动自动升级回 full。
4. **工具永远可用**: CLI 镜像内置; 发布树内置; 检测不到时在线安装(3 次, 固定哈希校验, fail-closed)。
5. **不改变现有离线目录契约**: 不移动资产、不改模块读取路径; 只新增元数据文件。

### 2.3 非目标

- 不解决"字节完整但内容错误"(例如 tar 合法但镜像是旧版本/错架构); 这属于发布 provenance,
  由 P1 的 `--verify-remote` + 镜像清单/digest 处理。
- 不引入签名信任根(P1 可选)。
- 不改变 kubespray 自身 `download` role 的 checksum 行为。
- 不重构模块的镜像推送/幂等逻辑(P1 处理 warn-only 行为)。

## 3. 威胁模型与边界

| 威胁 | P0 是否覆盖 | 说明 |
|---|---|---|
| 下载中断/截断 | 是 | 大小 + tar 结束块 + 全量 sha |
| 传输位翻转/存储损坏 | 是(full) | sha256; quick 只能覆盖可结构判断的格式 |
| U 盘/跨机拷贝不完整 | 是 | 跨机 inode/dev 变化导致校验戳失效 → full |
| 文件被替换/删改 | 是 | 清单双向覆盖 + sha + 校验戳 stat 指纹 |
| 同大小、同 mtime、inode 不变的位翻转 | 否 | 校验戳局限; 生产首装建议显式 `--level full` |
| 清单/文件被一起恶意替换 | 否(P1 签名) | P0 的 sha 链只防损坏, 不防篡改 |
| 校验器本身被替换 | 部分 | 镜像/仓库副本优先; 发布树副本先按 `SHA256SUMS` 引导校验; 在线安装用固定 sha |

## 4. 总体架构

```
                      ┌─────────────────────────────────────┐
                      │ verify-offline-files.sh (单文件)     │
                      │  metadata / quick / full / auto      │
                      │  --seal  --json  --stamp             │
                      └───────────────┬─────────────────────┘
                                      │ 被调用
        ┌─────────────────────────────┼──────────────────────────────┐
        │                             │                              │
┌───────▼────────┐          ┌─────────▼─────────┐          ┌─────────▼──────────┐
│ fetch (下载后) │          │ deploy-cluster 门禁│          │ release-publish     │
│ _SUCCESS 绑定  │          │ 首次 full/后续戳   │          │ verify / stage 拷贝 │
│ 覆盖性 + repair│          │ 失败即停           │          │ 工具进发布树        │
└───────┬────────┘          └─────────┬─────────┘          └────────────────────┘
        │                             │
        │                    ┌────────▼─────────┐
        │                    │ cubestack-offline │
        │                    │ check/tree.sha256 │
        │                    └───────────────────┘
        │
┌───────▼────────┐
│ 工具自举       │
│ 镜像/发布树/   │
│ 在线安装 3 次  │
└────────────────┘
```

## 5. 校验器规格

### 5.1 文件与形态

- 路径: `deployments/scripts/tools/offline/verify-offline-files.sh`
- **单制品 zipapp + 源码包**: `verifier/` Python 包(模块化)在构建时打成
  `verify-offline-files.pyz`; `verify-offline-files.sh` 仅做 exec 入口。
  - 在线安装只取一个 `.pyz`、只校验一个固定 sha; wrapper 本地生成。
  - Python 要求 ≥3.8; CLI base 镜像已内置 3.11; Ubuntu 22.04 自带 3.10。
  - 维护: `build-verifier.sh --update-pin`; CI `--check` 防止源码/pyz 漂移。
- 不依赖 `mc`/网络/root; 可在 CLI 容器内外运行。
- 另在 CLI 镜像建 `/usr/local/bin/cubestack-verify-offline` 软链。

### 5.2 CLI

```
verify-offline-files.sh [OPTIONS]

  --root DIR                待校验的 offline-files 树根(默认: 仓库 deployments/offline-files)
  --release VER             release 版本标识(用于 release.env/CLI tar 校验)
  --cli-tar PATH            CLI tar 路径(release 布局; 默认取 <root> 同级的
                            cubestack-installer-cli-v<ver>.tar, 或 release.json.cli_tar)
  --layout auto|release|flat|sealed-dev|unsealed-dev   默认 auto
  --level metadata|quick|full|auto                      **默认 quick**; 未指定时明确提示
  --deep                    quick 下也强制深度校验; full 已默认 deep
  --seal                    生成/更新 SHA256SUMS + SIZES
  --force                   seal 覆盖正式发布树 / 忽略校验戳
  --update-success          seal 后同步重写 _SUCCESS(本地修复)
  --json                    stdout 输出稳定 JSON; 进度走 stderr
  --jobs N                  全量哈希并发数(默认 4)
  --stamp-file PATH         校验戳路径(默认 <root>/.cubestack-verified.json)
  --no-stamp                不写校验戳
  --force-full              忽略有效校验戳, 强制 full
  --allow-unsealed          无清单时允许仅做结构检查(否则报错)
  --skip-missing            清单登记但磁盘缺失仅警告并跳过(默认; 不写戳)
  --fail-missing            清单登记但磁盘缺失即失败(部署门禁/fetch 使用)
  --staging                 允许 _SUCCESS 缺失(发布 staging 用)
  --require-success         要求 _SUCCESS 必须存在(flat 布局默认只 warning)
  --require-cli-tar         release 布局必须有 CLI tar
  --no-color
  --version
  --self-test
  -h, --help
```

- `--level auto`: 校验戳有效 → 秒级复查; 无有效戳且布局为 release/flat/sealed-dev → `full`;
  布局为 unsealed-dev → `quick`(等价自动带 `--allow-unsealed`)。
- `--level quick`: 不写校验戳。
- `--level full`: 通过后写校验戳(除非 `--no-stamp`)。
- `--seal` 与 `--level` 互斥(seal 只生成清单, 不判定完整性)。
- `--version` 输出 `verify-offline-files <版本> (schema 1)`; `--self-test` 用临时 fixture
  跑一遍核心检查(通过/损坏/截断/清单), 供在线安装后冒烟。

### 5.3 布局识别

**`--root` 语义(所有调用方统一)**: `--root` 始终指向**待校验的树**本身(即包含
`SHA256SUMS` 的目录), 不是本地桶根。这样 fetch、deploy、release-publish、`cubestack-offline.sh`
可以传同一个语义的路径, 不需要各自推导。

| 布局 | 判定 | `--root` 示例 | CLI tar |
|---|---|---|---|
| `release` | 显式 `--layout release`, 或给了 `--require-cli-tar`; 根下有 `release.env`+`SHA256SUMS` | `/data/cubestack-installer/2.0.0/offline-files` | 默认 `<root>/../cubestack-installer-cli-v<ver>.tar`; 可 `--cli-tar` 覆盖; `release.json.cli_tar` 相对 root 解析 |
| `flat` | 根下有 `release.env` + `SHA256SUMS`(+`release.json`) | `/data/.../offline-files` | 可选; 同 release 规则 |
| `sealed-dev` | 根下有 `SHA256SUMS`, 无 `release.env` | `deployments/offline-files` | 无 |
| `unsealed-dev` | 根下无 `SHA256SUMS` | `deployments/offline-files` | 无 |

- 显式 `--layout` 优先; 自动探测时按上表从具体到宽泛。
- `release` 与 `flat` 的核心检查相同; 区别只在是否强制 CLI tar。按自动探测把
  “有 `release.env`+`SHA256SUMS`”判为 `flat`, 需要强制 CLI tar 时显式传
  `--layout release --cli-tar ...`(fetch 非 flat 路径就是这样)。
- 便利入口: 若 `--root` 指向**本地桶根**(其下只有 `<ver>/offline-files/`)且给了 `--release`,
  工具自动下钻到 `<root>/<ver>/offline-files`; 调用方也可直接传树根, 行为一致。
- fetch 非 flat: `--root "${DST_ROOT}/offline-files"`; flat: `--root "${DST_ROOT}"`。
- deploy: `--root "${OFFLINE_FILES_ROOT}"`。
- release-publish staging: `--root "${STAGE_TREE}" --cli-tar "${CLI_TAR}" --staging`。

### 5.4 检查级别与检查项

#### metadata(所有级别都执行)

1. **`_SUCCESS` 绑定**:
   - `release` 布局: 必须存在(`--staging` 允许缺失); `flat` 布局: 缺失只 warning
     (旧 flat 树兼容), `--require-success` 可升级为失败;
   - `release=` 存在时与版本一致;
   - `sha256sums=` 存在时必须等于 `sha256(SHA256SUMS)`; 缺失给 warning(兼容旧树);
   - `sizes=` 存在时校验 `sha256(SIZES)`; `files=`/`bytes=` 存在时校验计数。
2. **`release.env`**:
   - 可解析; `RELEASE_VERSION` 非空; 给了 `--release` 时必须与之一致。
3. **`SHA256SUMS`**:
   - 存在(否则 unsealed 需 `--allow-unsealed`);
   - 每行 `<64hex>  <path>`, 拒绝绝对路径、`..`、重复路径、非普通文件;
   - 排除自身/`SIZES`/`_SUCCESS`/校验戳/`.cubestack-*`;
   - **双向覆盖**: 清单路径集合 == 磁盘实际文件集合(少了、多了都报);
   - 0 字节文件直接失败;
   - 残留 `.part`/`.tmp`/`.corrupt` 直接失败并列出。
4. **`release.json`**(release/flat, 若存在):
   - 可解析; `release` 与版本一致; `cli_tar_sha256` 为 64 hex; `cli_tar_size` 为正整数。
5. **符号链接**: 树内出现符号链接一律失败(离线树不应有)。
6. **权限**: 文件无读位(如 root 0600 的 docker save 产物)给 warning。

#### quick(metadata + 低成本内容检查)

1. **`SIZES`**: 存在时逐文件比对期望大小; 路径集合必须与 `SHA256SUMS` 一致。
   缺失时输出明确 warning: `quick 无法检测截断, 建议 --level full 或重新发布带 SIZES 的树`。
2. **`*.tar`**(非 gzip):
   - 尾部 1024 字节全零(tar 结束块)作为**快速截断判定**;
   - 结束块不完整时退回 `tarfile` 完整遍历: 遍历成功则接受(兼容不带结束块的合法 tar),
     抛 `ReadError`/`Unexpected EOF` 才判失败;
   - 遍历时校验 tar 头; 含 `manifest.json` 的 docker-archive 额外校验 `Config` 与 `Layers`
     指向的成员都在档内(防 1.5KB 空壳 tar);
   - 解析失败即失败。
3. **`*.tar.gz` / `*.tgz`**:
   - 大小 ≤ `QUICK_TGZ_MAX`(默认 256 MiB)时完整 `tarfile` 读取;
   - 超过阈值时只校验 gzip 魔数/页脚 + `SIZES` 大小, 并 warning "未深度校验";
   - `--deep` 强制对全部 `.tar.gz`/`.tgz` 完整解压校验(慢, 用于大包结构确认);
   - 普通 `*.gz`(非 tar.gz): ≤阈值或 `--deep` 时用 gzip 解压验证 CRC/ISIZE; quick 超阈值只查魔数/页脚;
   - chart(tgz)无论大小都必须含 `Chart.yaml`; **只严格校验 `release.env` 指定的**
     `cubestack-operator-chart-<CUBESTACK_OPERATOR_CHART_VERSION>.tgz`(必须存在且
     `Chart.yaml.version` 一致); `charts/` 下其他版本只 warning(陈旧文件)。
4. **二进制**:
   - `kubespray/<ver>/` 顶层可执行文件、`*.run`: ELF 魔数或 `#!` shebang + 可执行位;
   - `*.deb`: `!<arch>\n` 魔数;
   - 已知 `.qcow2`: `QFI\xfb` 魔数(若存在)。
5. **`tree.tar.gz`**:
   - 存在 `tree.tar.gz.sha256` 时**在 quick 也计算并比对**(单文件, 代价可接受);
   - 缺失边车给 warning(开发树常见); 全量 sha 仍由 `SHA256SUMS` 覆盖。
6. **镜像 `.digest` 边车**: 存在性检查(P0 只 warning; 不拿它当 tar sha, 因为它是 registry manifest digest,
   本地无法可靠复算)。

#### full(quick + 内容哈希 + 镜像深度校验)

1. 对 `SHA256SUMS` 中每个文件计算 sha256(多线程, `--jobs`), 与清单比对;
   进度每 5 秒输出: 已完成/总数、字节数、速率。
2. **镜像 archive 深度校验**(full 默认, quick 需 `--deep`):
   - 解析 `manifest.json` / `Config`;
   - `rootfs.diff_ids` 数量与 `Layers` 一致;
   - 逐 layer 计算 sha256 并与 `diff_ids` 比对(gzip layer 先解压);
   - 目的: full 通过即保证 archive 可被 skopeo/ctr 解析, 避免"校验通过但 load 报错"。
3. **CLI tar**: 大小 + sha256, 对照 `release.json.cli_tar_size`/`cli_tar_sha256`;
   CLI tar 缺失时: `--require-cli-tar` 失败, 否则 warning(部署本身不需要它)。
4. **`tree.tar.gz`**: sha256 对照 `.sha256`。
5. **`SIZES`**(若存在): 与 `SHA256SUMS` 路径集合一致, 大小一致。
6. 任一不一致 → 失败, 列出 `path / kind / expected / actual`。

### 5.5 清单格式

- `SHA256SUMS`: GNU `sha256sum` 兼容格式:
  ```
  <64hex>  ./<相对路径>
  ```
  - 生成时排除 `SHA256SUMS`、`SIZES`、`_SUCCESS`、`.cubestack-*`。
  - 清单里出现上述 meta 路径 → 解析失败(防止手工拼清单绕过覆盖性检查)。
  - 路径带 `./` 前缀; 解析时归一化。
  - 不支持含换行的文件名(检测到直接报错, 离线资产不应出现)。
- `SIZES`(新增, 可选):
  ```
  <十进制字节数>  ./<相对路径>
  ```
  - 与 `SHA256SUMS` 同集合; 用于 quick 的截断检测。
  - P0 由 `--seal` 生成; 发布树自动生成放到 P1(旧树缺失时 quick 降级并 warning)。

### 5.6 校验戳

- 默认路径: `<root>/.cubestack-verified.json`(排除在清单/覆盖性之外)。
- 只在 `full` 且全部通过后写; 原子写(`.cubestack-verified.tmp.<pid>` → rename)。
- 内容:
  ```json
  {
    "schema": 1,
    "tool_version": "1.0.0",
    "level": "full",
    "deep": true,
    "layout": "release",
    "release": "2.0.0",
    "root": "/data/cubestack-installer/2.0.0/offline-files",
    "manifest": "SHA256SUMS",
    "manifest_sha256": "<64hex>",
    "files": 1234,
    "bytes": 137000000000,
    "created_at": "2026-10-28T12:00:00Z",
    "host_fingerprint": "<machine-id 或 boot-id 或 hostname; 仅审计>",
    "fingerprint": "<sha256(排序后的 path\\0size\\0mtime_ns\\0inode\\0dev\\n)>"
  }
  ```
- **有效性** = `schema` 兼容 + `manifest_sha256` 与当前 `SHA256SUMS` 一致 +
  `fingerprint` 与当前 stat 结果一致(路径集合、大小、mtime_ns、inode、dev 全部一致)
  + 戳必须是 deep(full 默认 deep; 旧的非 deep 戳会自动失效并重跑 full)。
- 任何拷贝/替换/截断都会改变 inode 或大小/mtime → 失效 → 自动回退 `full`。
- **局限**: 同大小、同 mtime、同 inode 的位翻转无法由戳发现; 生产首次安装或物理搬运后
  建议显式 `--level full`。`host_fingerprint` 不参与有效性判定, 只用于审计/排障。
- `--force-full` 忽略有效戳; `--no-stamp` 不写戳; `--stamp-file` 可指定路径(发布 staging 用)。

### 5.7 `--seal`

- 递归收集树内普通文件, 生成 `SHA256SUMS` + `SIZES`。
- 拒绝:
  - 符号链接;
  - `.part`/`.tmp`/`.corrupt` 残留(列出路径);
  - 不可读文件。
- 原子写: 先写 `.cubestack-SHA256SUMS.tmp.<pid>` / `.cubestack-SIZES.tmp.<pid>`, 校验后
  `rename` 到 `SHA256SUMS` / `SIZES`; 旧清单备份到 `<root>/.cubestack-manifest-backup/<ts>/`。
- 正式发布树(`_SUCCESS` 或 `release.json` 存在)默认拒绝 seal, 需 `--force`
  (发布脚本自己调用时显式传 `--force`)。
- `--update-success`: 重签后用新清单 sha 重写 `_SUCCESS`(release.env 提供版本);
  不更新则校验会因 `sha256sums` 绑定不符失败。
- seal 只生成清单, 不写校验戳; 需要时再跑 `--level full`。

### 5.8 JSON 输出 schema

```json
{
  "schema": 1,
  "tool_version": "1.0.0",
  "layout": "release",
  "root": "/data/.../offline-files",
  "release": "2.0.0",
  "level": "full",
  "ok": false,
  "summary": {"files": 1234, "checked": 1234, "failed": 2, "bytes": 137000000000},
  "checks": {
    "metadata": "ok", "coverage": "ok", "sizes": "ok",
    "structure": "fail", "sha256": "fail", "cli_tar": "ok", "tree_tar": "ok"
  },
  "failures": [
    {"path": "kubespray/v2.32.0/images/x.tar", "kind": "sha256_mismatch",
     "expected": "abc...", "actual": "def...", "size": 1234}
  ],
  "warnings": ["SIZES 缺失, quick 无法检测截断"],
  "stamp": {"valid": false, "path": "...", "reason": "fingerprint mismatch"}
}
```

- stdout 只输出 JSON; 进度/彩色日志走 stderr。
- 失败列表默认人类输出最多 20 条; JSON 全量。

### 5.9 退出码

| 码 | 含义 |
|---|---|
| 0 | 通过(含 unsealed+`--allow-unsealed` 的结构检查通过) |
| 1 | 完整性失败(坏文件/清单/绑定/staging 缺失等) |
| 2 | 用法/环境错误(缺 python3、root 不存在、参数非法、`--seal` 遇到临时文件) |

## 6. 工具交付与自举

### 6.1 方案 1: 随 `cubestack-installer-cli` 镜像内置(主路径)

- `Dockerfile-cli` 已 `COPY deployments`, 工具天然进镜像; 新增构建期门禁:
  ```dockerfile
  RUN test -x ${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh \
   && ${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh --version \
   && ln -sf ${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh \
             /usr/local/bin/cubestack-verify-offline
  ```
- `build-cli-context.sh` / `check-modules.sh` 增加存在性、可执行位、`bash -n`、`--version` 自检。
- 同时随发布树分发: `release-publish.sh stage` 把工具拷到
  `offline-files/tools/verify-offline-files.sh`, 由 `SHA256SUMS` 覆盖。
  - 纯宿主机部署(不用 CLI 容器)也有离线副本。
  - 未来发布树天然携带校验器。

### 6.2 方案 2: 检测不到时在线安装(兜底, 最多 3 次)

新增**独立小库** `deployments/scripts/tools/offline/lib-offline-verify.sh`(不依赖 `lib-common.sh`,
只做工具定位/自举), 供三个调用方 source:

- `deployments/scripts/lib-common.sh`(deploy 门禁);
- `deployments/scripts/tools/offline/fetch-offline-from-minio.sh`;
- `deployments/kubespray/cubestack-offline.sh`(该脚本刻意不 source lib-common)。

库导出 `ensure_offline_verify_tool()`, 输出工具路径到 stdout, 日志走 stderr。
库内置配置默认值; 调用方 `load_config` 之后可用 `OFFLINE_VERIFY_*` 覆盖。
pin 解析顺序: 环境变量 `OFFLINE_VERIFY_TOOL_SHA256` > 相对库位置
`../../config/verify-tool.sha256`(即 `deployments/config/verify-tool.sha256`)。

**查找顺序**

| 顺序 | 来源 | 信任方式 |
|---|---|---|
| 1 | `CUBESTACK_VERIFY_TOOL` | 用户显式指定 |
| 2 | 仓库副本 `deployments/scripts/tools/offline/verify-offline-files.sh` | 随安装器代码/镜像 |
| 3 | 发布树副本 `<OFFLINE_FILES_ROOT>/tools/verify-offline-files.sh` | **必须**先在 `SHA256SUMS` 中找到该条目并校验通过才执行; 未登记/哈希不符 → 拒绝使用该副本 |
| 4 | PATH `cubestack-verify-offline` | CLI 镜像内置 |
| 5 | 在线下载 | 固定 sha256 校验通过才执行 |

**在线安装行为**

- 配置:
  - `OFFLINE_VERIFY_ONLINE_INSTALL=auto|never`(默认 `auto`)
  - `OFFLINE_VERIFY_TOOL_URL`(默认 `https://raw.githubusercontent.com/suanova/cubestack-installer/main/deployments/scripts/tools/offline/verify-offline-files.sh`;
    发布环境建议覆盖为对应 tag)
  - `OFFLINE_VERIFY_TOOL_SHA256`(来自 `deployments/config/verify-tool.sha256`, 仓库内置)
- 过程:
  - `curl -fsSL --connect-timeout 5 --max-time 30 -o <tmp> <url>`, **最多 3 次**, 间隔 3s/6s;
  - 下载到 `.part`; `sha256sum` 与固定 pin 比对;
  - 通过后 `chmod 0755`, 原子 `mv` 到 `${XDG_CACHE_HOME:-$HOME/.cache}/cubestack/verify/verify-offline-files.sh`;
  - 失败清理 `.part`, 不落任何半成品。
- 安全:
  - **pin 缺失或哈希不符 → 拒绝执行(fail-closed)**; 不安装来源不明的校验器;
  - 在线安装的脚本先 `--version` 冒烟, 再使用。
- 依赖:
  - `python3`/`sha256sum`/`tar` 缺失时明确报错并给安装指引; **不自动 apt**(离线环境半装风险更高);
  - `mc` 的现有在线安装逻辑不动。
- 3 次失败后的行为:
  - `release`/`flat`/`sealed-dev`: 门禁**硬停**, 打印手动命令(用 CLI 镜像 / 从发布树或仓库拷贝);
  - `unsealed-dev`: 警告后继续(可 `OFFLINE_VERIFY_STRICT_DEV=true` 升级为阻断)。

### 6.3 pin 维护

- `deployments/config/verify-tool.sha256` 保存工具当前 sha256。
- CI(`check-modules.sh` 或专用测试)计算实际 sha 并比对; 不一致即失败, 强制改工具时同步更新 pin。
- 发布打 tag 时 pin 与工具同 commit, 保证在线兜底可取到一致版本。

## 7. 安装前门禁

### 7.1 挂载点

- `deploy-cluster.sh`: `load_config` 之后、`check_offline_files` 之前
  (`deploy-cluster.sh:255-261`)。
- 跳过条件:
  - `--list` / `--list-steps`;
  - `STEPS_ARG` 全部为 `verify_*`;
  - `STEPS_ARG` 全部属于 `PRE_CLUSTER_STEPS`(`node_pkgs k8s_passwordless k8s_workerbm k8s_hosts k8s_inventory k8s_ntp`)。
- `cubestack-offline.sh check`: 调用工具 `quick`; `install`/`scale` 复用 `check`。

### 7.2 配置与 CLI

`cluster.defaults.conf` 新增:

```bash
OFFLINE_VERIFY_MODE="${OFFLINE_VERIFY_MODE:-auto}"          # auto|off|quick|full
OFFLINE_VERIFY_JOBS="${OFFLINE_VERIFY_JOBS:-4}"
OFFLINE_VERIFY_STAMP="${OFFLINE_VERIFY_STAMP:-true}"
OFFLINE_VERIFY_STRICT_DEV="${OFFLINE_VERIFY_STRICT_DEV:-true}"  # 未 seal 树检出损坏即阻断
OFFLINE_VERIFY_ONLINE_INSTALL="${OFFLINE_VERIFY_ONLINE_INSTALL:-auto}"
OFFLINE_VERIFY_TOOL_URL="${OFFLINE_VERIFY_TOOL_URL:-https://raw.githubusercontent.com/suanova/cubestack-installer/main/deployments/scripts/tools/offline/verify-offline-files.pyz}"
```

`deploy-cluster.sh` 新增:

- `--verify-offline[=auto|quick|full]`
- `--no-verify-offline`

CLI 覆盖配置; `--no-verify-offline` 打印醒目横幅“已跳过离线文件完整性校验”。

### 7.3 各布局行为

| 布局 | `auto` 行为 | 失败 |
|---|---|---|
| `release` / `flat` | 有效戳 → 秒级复查; 否则 full | 硬停 |
| `sealed-dev` | 有效戳 → 秒级复查; 否则 full | 硬停 |
| `unsealed-dev` | quick 结构检查 | 无清单只警告; 检出明确损坏时按 `OFFLINE_VERIFY_STRICT_DEV`(默认 true)阻断 |

工具退出码 `2`(用法/环境错误, 如缺 python3)按“工具不可用”处理: release/flat/sealed 硬停,
unsealed-dev 警告继续。

### 7.4 `load_config` 的 `release.env` source 前检查(release / flat 模式)

在 `source "${_rel_root}/release.env"` 之前:

1. 若 `SHA256SUMS` 存在:
   - 从清单中取 `release.env` 的期望 sha; 未登记 → 报错;
   - 计算实际 sha; 不一致 → 报错并拒绝 `source`(损坏的 `release.env` 不被 root 执行);
   - `_SUCCESS` 存在时校验 `sha256sums=` 绑定, 不一致 → 报错。
2. 若 `SHA256SUMS` 不存在:
   - warning “未找到 SHA256SUMS, 跳过 release.env 预校验”; 继续(兼容旧树/测试)。
3. 该检查只读、廉价(两个小文件), 不触发全量校验。

### 7.5 失败输出

```
❌ 离线文件完整性校验失败(2 个文件):
  kubespray/v2.32.0/images/quay.io_ceph_ceph_v20.2.2.tar
    期望 sha256: abc...  实际: def...
  ...
修复:
  release:  ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
              --release 2.0.0 --repair --dest /data/cubestack-installer
  sealed:   重新拷贝上述文件后执行 verify-offline-files.sh --root <dir> --level full
  unsealed: verify-offline-files.sh --root <dir> --seal
```

## 8. fetch 集成

### 8.1 `_verify_release` 改为调用校验器

- `fetch-offline-from-minio.sh` 在同目录解析工具路径(缺失时 source `lib-offline-verify.sh`); 调用:
  ```bash
  # 非 flat: DST_ROOT=<本地桶根>/<ver>, 树根 = ${DST_ROOT}/offline-files
  # flat:    DST_ROOT 本身就是树根
  verify-offline-files.sh --root "<树根>" --release "$RELEASE_ARG" \
      --layout <release|flat> --level full --json [--require-cli-tar]
  ```
- 树根取法: 非 flat 传 `${DST_ROOT}/offline-files`, flat 传 `${DST_ROOT}`;
  CLI tar 用 `--cli-tar "${DST_ROOT}/cubestack-installer-cli-v${RELEASE_ARG}.tar"`(非 flat)。
- 工具负责: `_SUCCESS` 绑定、清单格式/路径/重复、双向覆盖、大小、结构、全量 sha、CLI tar。
- 失败时从 JSON 提取 `failures[]`, 人类输出点名文件; 不再 `>/dev/null`。
- 通过后工具写校验戳 → 部署门禁秒过。
- `--verify-only` 走同一路径; **不需要 mc/MinIO 配置**, 直接校验本地树;
  release/flat 可用; sealed-dev 用独立工具 `verify-offline-files.sh --root <dir> --level full`。
- `--no-verify` 保持逃生口(仅调试, 打印醒目警告)。

### 8.2 `--repair`

- 前置: 已配置 `mc` 与 MinIO 凭据; 与 `--release`/`--flat` 配合。
- 流程:
  1. 工具 `--json` 跑 full;
  2. 把失败文件移到 `<bucket-root>/.repair-quarantine/<ver>/<时间戳>/<相对路径>`
     (保留证据, 不留在树内; `<bucket-root>` 不可写时回退 `${TMPDIR:-/var/tmp}/cubestack-repair/...`);
  3. 逐个 `mc cp --overwrite <remote>/<path> <local>/<path>`, 最多 2 轮;
  4. 重跑工具 full; 仍失败 → 明确报“发布源本身损坏, 请重新发布/换源”, 不再重试。
- CLI tar 失败同样处理。
- 无网络/无 `mc`: 明确报错并给出“从发布源重新拷贝”的指引。

### 8.3 非 release 模式

- `--sub/--all`: 目标根存在 `SHA256SUMS` 时按 `sealed-dev` 校验;
  不存在时打印“本次取件无清单, 建议 seal”提示(不阻断)。
- `--sub` 只取子树, 整树清单不适用; 明确说明“无法按整树清单校验”。

## 9. `cubestack-offline.sh` 集成(P0)

- `ensure_kubespray` 解包前:
  - 若 `tree.tar.gz.sha256` 存在, 计算并比对; 不一致硬失败;
  - 缺失边车 → warning(开发树可能没有)。
- `cmd_check`:
  - 有 `SHA256SUMS` 时调用工具 `--level auto`(有效戳→复查; 否则 full);
  - 无清单时调用 `--allow-unsealed --level quick`;
  - 工具缺失时 source `lib-offline-verify.sh` 走 §6.2 自举; 失败按 `unsealed-dev`/`release` 语义处理。
- `install`/`scale` 复用 `cmd_check` 结果。

## 10. P0 / P1 范围

### 10.1 P0(本次)

1. `verify-offline-files.sh` 单文件实现 + `--seal` + 校验戳 + JSON + 退出码。
2. 工具交付: `Dockerfile-cli` 内置/symlink/构建门禁; `build-cli-context.sh`/`check-modules.sh` 自检;
   `verify-tool.sha256` pin + CI 一致性检查; `release-publish.sh stage` 拷贝进发布树, 且
   `_write_sha256sums` 排除 `.cubestack-*`(避免把 staging 校验戳带进发布)。
3. 工具自举: `lib-offline-verify.sh` + `ensure_offline_verify_tool()` + 在线安装 3 次 + fail-closed。
4. 部署门禁: `deploy-cluster.sh` 参数/配置/调用; `lib-common.sh` gate; `load_config` source 前检查。
5. fetch: 调用工具 + `_SUCCESS` 绑定/覆盖性/详细失败 + `--repair` + 校验戳。
6. `cubestack-offline.sh`: `tree.tar.gz.sha256` 解包前校验 + `cmd_check` 接工具。
7. 测试: `test-verify-offline-files.sh`、`test-verify-tool-install.sh`、扩展 `test-release-mode.sh`、CI。
8. 文档: `docs/offline-files-integrity.md` + `docs/release-management.md` 更新 + 配置注释。

### 10.2 P1(单独 PR)

1. 发布侧 `SIZES` 生成 + `_SUCCESS` 的 `sizes=`/`files=`/`bytes=` 绑定(release-publish/release-sync),
   并让 `release-publish verify` 调用工具 `--staging`。
2. `release-publish stage` 对平台镜像 `--verify-remote`(tar ↔ Harbor digest provenance)。
3. `harbor-save-images.sh` / `cubestack-platform-save-images.sh` 的“存在即跳过”先做 quick 结构校验。
4. `sync-to-minio.sh --seal`: 开发树同步前 seal, 上传 `SHA256SUMS`/`SIZES`。
5. `cubestack-offline.sh download`: `.part` + `mv` + 重试 + 版本目录 seal/full。
6. `dev_lab`/`model_images` 在 release 模式下缺包/推送失败升级为失败。
7. 签名(minisign/GPG)可选信任根。

## 11. 兼容性与回滚

- 旧发布树无 `SIZES`: quick 降级 warning; `auto` 首次 full; 不影响使用。
- 旧 `_SUCCESS` 无 `sha256sums=`/`sizes=` 字段: 对应检查 warning, 不失败。
- 旧 CLI 镜像无工具: 更新后的仓库/镜像副本优先; 发布树副本是第三兜底; 在线安装是最后兜底。
- 无 `SHA256SUMS` 的开发树: 默认 quick + 损坏阻断; `OFFLINE_VERIFY_STRICT_DEV=false` 可降级。
- 逃生口: `--no-verify-offline` / `OFFLINE_VERIFY_MODE=off` / fetch `--no-verify`。
- 回滚: 门禁是新增调用, 移除调用即恢复原行为; 工具/清单是新增文件, 不改变既有读取路径。

## 12. 测试计划

### 12.1 `tools/tests/test-verify-offline-files.sh`

覆盖:

- 四种布局( release/flat/sealed-dev/unsealed-dev )通过;
- 坏字节(full 失败; quick 对同大小二进制通过、对截断失败);
- tar 截断(尾部结束块缺失);
- docker-archive 空壳(manifest.json Layers 指向不存在成员);
- 缺文件/多文件/清单截断/路径穿越/符号链接;
- `_SUCCESS` 绑定错误; `release.env` 版本不符;
- `SIZES` 大小不符; 无 SIZES 的 warning;
- 校验戳: 有效跳过 full、touch/替换/截断后失效、`--force-full`、`--no-stamp`、`--stamp-file`;
- `--seal`: 幂等、备份、临时文件拒绝、拒绝正式发布树(无 `--force`);
- 发布树 `tools/verify-offline-files.sh` 被 `SHA256SUMS` 覆盖, 且引导校验可用;
- JSON schema 键/退出码;
- `--staging` 允许无 `_SUCCESS`; `--require-cli-tar`。

### 12.2 `tools/tests/test-verify-tool-install.sh`

- 用假 `curl`/`file://` 模拟: 前两次失败第三次成功、3 次全失败、sha 不符、pin 缺失;
- `.part` 清理、原子落位、`chmod 0755`;
- 发布树副本的 `SHA256SUMS` 引导校验;
- 无 python3 时的明确报错(可用假 PATH 模拟)。

### 12.3 扩展 `test-release-mode.sh`

- 假 release 树生成 `_SUCCESS` 的 `sha256sums=` 绑定;
- fetch 下载后调用工具并写戳;
- 篡改一个文件 → fetch 失败并点名; `--repair` 用假 `mc` 恢复;
- `--verify-only` 对 release/flat 生效; sealed-dev 用独立工具
  `verify-offline-files.sh --root <dir> --level full`。

### 12.4 CI

- `ci-validate.yml` 增加上述三个测试;
- `check-modules.sh` 增加工具/pin 一致性检查;
- `Dockerfile-cli` 构建门禁(镜像内 `--version`)。

## 13. 文档计划

- 新增 `docs/offline-files-integrity.md`:
  - 威胁模型与边界(损坏 vs 篡改; 校验戳局限);
  - 四布局与命令示例;
  - 校验级别/校验戳/seal;
  - 部署门禁与逃生口;
  - fetch/repair;
  - 工具自举/在线安装/air-gapped 行为;
  - 故障排查表(症状 → 命令)。
- 更新 `docs/release-management.md`:
  - §3.3 说明 `_SUCCESS` 绑定; P1 的 `SIZES` 字段;
  - §5.3 fetch 校验改为工具语义 + `--repair`;
  - §6 发布侧工具拷贝与 P1 provenance。
- `cluster.defaults.conf` / `cluster.conf.example` 增加 `OFFLINE_VERIFY_*` 注释。
- `deployments/scripts/README.md`(若有工具索引)补充新工具。

## 14. 验收标准

1. release 树 fetch 后: full 通过并写戳; 第二次部署门禁 < 2s。
2. 手工篡改 1 个镜像 tar: 部署在模块 1 之前停止, 输出准确路径/期望/实际 + repair 命令。
3. `fetch --repair` 能只重下坏文件并恢复通过(有网络时); 源也坏时明确报错不循环。
4. U 盘跨机拷贝后: 校验戳失效 → 自动 full; 截断文件被检出。
5. `--seal` 的开发树: 首次 full、后续戳; 未 seal 且 tar 截断时按严格模式阻断。
6. 工具缺失场景:
   - CLI 镜像内: 直接可用;
   - 无镜像 + 在线: 3 次内安装成功并校验运行;
   - 无镜像 + 离线: release 硬停并给手动命令; dev 警告继续。
7. `Dockerfile-cli` / CI 在工具缺失或 pin 漂移时失败。
8. CI 全绿; 现有 release-mode/release-sync 测试不回归。

## 15. 风险与缓解

| 风险 | 缓解 |
|---|---|
| full 130G 耗时长 | 首次 full + 校验戳; `--jobs`(机械盘建议 1-2, NVMe 4); 进度可见; 跨机/变动自动重跑 |
| 校验戳被绕过/误信 | 文档标注局限; 生产首装建议 full; P1 签名 |
| Python 依赖缺失 | CLI base 内置 3.11; 宿主机缺失明确报错; 不自动 apt |
| 在线安装供应链风险 | 固定 sha256 + fail-closed + 先 `--version`; 镜像/发布树优先 |
| quick 对超大 `.tar.gz` 降级 | 明确 warning; `auto` 首跑 full; P1 `SIZES` 覆盖 |
| `_SUCCESS` 旧字段缺失 | warning 不失败; 新发布树逐步补齐 |
| 校验器自身损坏 | 镜像/仓库优先; 发布树副本先按 `SHA256SUMS` 引导校验; 在线 pin |
| 误报导致部署被挡 | 逃生口 + 失败列表 + 修复命令; 测试覆盖常见合法格式 |

## 16. 实施产物清单(P0)

- 新增: `deployments/scripts/tools/offline/verify-offline-files.sh`(wrapper)
- 新增: `deployments/scripts/tools/offline/verify-offline-files.pyz`(zipapp)
- 新增: `deployments/scripts/tools/offline/verifier/`(Python 模块包)
- 新增: `deployments/scripts/tools/offline/build-verifier.sh`
- 新增: `deployments/scripts/tools/offline/lib-offline-verify.sh`
- 新增: `deployments/scripts/tools/offline/lib-offline-fetch.sh`
- 新增: `deployments/scripts/tools/offline/lib-offline-gate.sh`
- 新增: `deployments/config/verify-tool.sha256`
- 新增: `deployments/scripts/tools/tests/test-verify-offline-files.sh`
- 新增: `deployments/scripts/tools/tests/test-verify-tool-install.sh`
- 新增: `docs/offline-files-integrity.md`
- 修改: `deployments/scripts/lib-common.sh`(`verify_offline_gate`、`load_config` 预检查; source `lib-offline-verify.sh`)
- 修改: `deployments/scripts/deploy-cluster.sh`(参数/调用/跳过条件)
- 修改: `deployments/scripts/tools/offline/fetch-offline-from-minio.sh`(校验器/repair/戳)
- 修改: `deployments/kubespray/cubestack-offline.sh`(tree.sha256、cmd_check)
- 修改: `deployments/scripts/tools/images/release-publish.sh`(stage 拷贝工具)
- 修改: `Dockerfile-cli`、`deployments/scripts/tools/docker/build-cli-context.sh`、`deployments/scripts/tools/check-modules.sh`
- 修改: `deployments/scripts/tools/tests/test-release-mode.sh`、`.github/workflows/ci-validate.yml`
- 修改: `deployments/config/cluster.defaults.conf`、`cluster.conf.example`、`docs/release-management.md`

## 17. 待确认/后续

- 在线安装默认 URL 使用 `main` 还是发布 tag: P0 默认 `main` + pin; 发布环境文档建议覆盖为 tag。
- P1 签名方案(minisign vs GPG)与公钥分发方式: 待 P1 设计。
