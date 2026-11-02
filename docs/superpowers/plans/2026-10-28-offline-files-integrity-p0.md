# offline-files 完整性校验 P0 实施计划

> 状态: **P0 已完成(2026-10-28)**
>
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付离线文件完整性校验器、工具自举、部署前门禁、fetch 校验/修复、`tree.tar.gz` 校验、测试与文档，使坏镜像/坏二进制在安装前被点名拦截，且重复部署走校验戳秒级通过。

**Architecture:** 新增单文件 `verify-offline-files.sh`(bash 入口 + 内嵌 Python)，作为唯一校验实现；`lib-offline-verify.sh` 负责工具定位与在线安装；`lib-common.sh`/`deploy-cluster.sh` 在 `load_config` 后接入门禁；`fetch-offline-from-minio.sh` 下载后调用同一工具并支持 `--repair`；`cubestack-offline.sh` 解包前校验 `tree.tar.gz`、预检接工具。

**Tech Stack:** Bash 5、Python 3.8+ 标准库(`argparse/hashlib/json/tarfile/concurrent.futures`)、GNU coreutils/tar、现有仓库测试框架(纯 bash)。

**Spec:** `docs/superpowers/specs/2026-10-28-offline-files-integrity-design.md`

## Global Constraints

- 校验器必须**单文件**：`deployments/scripts/tools/offline/verify-offline-files.sh`，无同目录 `.py` 依赖；在线安装只取一个文件、只校验一个 sha256。
- 不依赖 `mc`/网络/root；只依赖 `python3>=3.8`、`sha256sum`、`tar`、`gzip`。
- 退出码固定：`0` 通过、`1` 完整性失败、`2` 用法/环境错误。
- 人类输出中文、精简；`--json` 时 stdout 只能是 JSON，进度/提示走 stderr。
- 默认零参数可用：`./verify-offline-files.sh` 校验仓库 `deployments/offline-files`；`--root` 默认同上。
- 性能：metadata 只读 stat/小文件；quick 不读镜像数据块；full 多线程哈希（默认 4，机械盘可 1-2）。
- 兼容：旧树无 `SIZES`/旧 `_SUCCESS` 缺字段只 warning；`--no-verify-offline`、fetch `--no-verify` 保留逃生口。
- 路径安全：清单/树内禁止绝对路径、`..`、符号链接；含换行文件名直接报错。
- 不改变现有离线目录契约；新增元数据文件 `SIZES`、`.cubestack-verified.json`、`.cubestack-manifest-backup/`。
- 所有新增/修改脚本必须通过 `bash -n`；测试必须加入 `tools/tests/` 并接入 `ci-validate.yml`。

---

### Task 1: 校验器骨架、CLI 与布局识别

**Files:**
- Create: `deployments/scripts/tools/offline/verify-offline-files.sh`
- Create: `deployments/scripts/tools/tests/test-verify-offline-files.sh`
- Modify: `.github/workflows/ci-validate.yml`（本任务先加测试步骤，后续任务复用）

**Interfaces:**
- Produces: CLI `verify-offline-files.sh [--root DIR] [--release VER] [--layout auto|release|flat|sealed-dev|unsealed-dev] [--level metadata|quick|full|auto] [--json] [--version] [--self-test] ...`
- Produces: JSON `{"schema":1,"tool_version":"1.0.0","layout":"...","root":"...","ok":true,...}`

- [ ] **Step 1: 写失败测试**

创建 `test-verify-offline-files.sh`：

```bash
#!/bin/bash
# ============================================================
# test-verify-offline-files.sh — verify-offline-files.sh 离线回归
# 覆盖: 布局识别/清单覆盖/结构/哈希/校验戳/seal/JSON/退出码
# 用法: bash deployments/scripts/tools/tests/test-verify-offline-files.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
run() { "$@" >"${TMP}/out" 2>"${TMP}/err"; echo $?; }

echo "== ⓪ --version =="
chk "退出码" "0" "$(run "${TOOL}" --version)"
chk_contains "版本号" "1.0.0" "$(cat "${TMP}/out")"

echo "== ① 布局识别: release =="
mkdir -p "${TMP}/bucket/2.0.0/offline-files"
printf 'RELEASE_VERSION=2.0.0\nKUBESPRAY_VERSION=v2.32.0\n' > "${TMP}/bucket/2.0.0/offline-files/release.env"
printf '{}' > "${TMP}/bucket/2.0.0/offline-files/release.json"
: > "${TMP}/bucket/2.0.0/cubestack-installer-cli-v2.0.0.tar"
chk "退出码(空树仅 metadata)" "0" "$(run "${TOOL}" --root "${TMP}/bucket/2.0.0/offline-files" --release 2.0.0 --layout release --level metadata --json)"
chk_contains "layout=release" '"layout": "release"' "$(cat "${TMP}/out")"

echo "== ② 布局识别: flat =="
mkdir -p "${TMP}/flat"
printf 'RELEASE_VERSION=2.0.0\n' > "${TMP}/flat/release.env"
chk "退出码(flat)" "0" "$(run "${TOOL}" --root "${TMP}/flat" --level metadata --json)"
chk_contains "layout=flat" '"layout": "flat"' "$(cat "${TMP}/out")"

echo "== ③ 布局识别: sealed-dev / unsealed-dev =="
mkdir -p "${TMP}/dev"
: > "${TMP}/dev/a.txt"
chk "unsealed 无 --allow-unsealed 失败" "1" "$(run "${TOOL}" --root "${TMP}/dev" --level metadata)"
chk "unsealed + --allow-unsealed 通过" "0" "$(run "${TOOL}" --root "${TMP}/dev" --level metadata --allow-unsealed --json)"
printf '%s  ./a.txt\n' "$(sha256sum "${TMP}/dev/a.txt" | awk '{print $1}')" > "${TMP}/dev/SHA256SUMS"
chk "sealed 通过" "0" "$(run "${TOOL}" --root "${TMP}/dev" --level metadata --json)"
chk_contains "layout=sealed-dev" '"layout": "sealed-dev"' "$(cat "${TMP}/out")"

echo "---------------------------------------------"
[ "${fail}" = "0" ] && { echo "✅ verify-offline-files 回归通过"; exit 0; } || { echo "❌ 回归失败"; exit 1; }
```

在 `ci-validate.yml` 的 `test-release-mode.sh` 步骤后追加：

```yaml
      - name: offline-files 完整性校验回归
        run: |
          set -euo pipefail
          bash deployments/scripts/tools/tests/test-verify-offline-files.sh
```

- [ ] **Step 2: 运行确认失败**

Run: `bash deployments/scripts/tools/tests/test-verify-offline-files.sh`
Expected: FAIL（`No such file or directory` / `verify-offline-files.sh` 不存在）

- [ ] **Step 3: 实现骨架**

`verify-offline-files.sh` 开头：

```bash
#!/usr/bin/env bash
# ============================================================
# verify-offline-files.sh — offline-files 完整性校验器(单文件)
# 用法:
#   ./verify-offline-files.sh                     # 校验仓库 deployments/offline-files
#   ./verify-offline-files.sh --root DIR          # 校验任意树
#   ./verify-offline-files.sh --root DIR --seal   # 生成 SHA256SUMS + SIZES
#   ./verify-offline-files.sh --root DIR --level full
#   ./verify-offline-files.sh --json --level auto
# 退出码: 0=通过 1=完整性失败 2=用法/环境错误
# 依赖: python3>=3.8, sha256sum, tar, gzip
# ============================================================
set -euo pipefail
if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ 需要 python3(>=3.8); 请安装 python3 后重试" >&2
    exit 2
fi
export PYTHONIOENCODING=utf-8
exec python3 - "$@" <<'PY'
import argparse, hashlib, json, os, re, stat, sys, tarfile, tempfile, time

TOOL_VERSION = "1.0.0"
SCHEMA = 1
META_NAMES = {"SHA256SUMS", "SIZES", "_SUCCESS"}
TEMP_RE = re.compile(r"(\.part$|\.tmp$|\.corrupt$|\.part\.|\.tmp\.)")

class Ctx:
    def __init__(self):
        self.failures = []
        self.warnings = []
        self.checks = {}
        self.files = []
        self.total_bytes = 0

def fail(ctx, path, kind, msg, expected=None, actual=None):
    ctx.failures.append({"path": path, "kind": kind, "message": msg,
                         "expected": expected, "actual": actual})

def warn(ctx, msg):
    ctx.warnings.append(msg)

def is_meta(rel):
    rel = rel.replace(os.sep, "/")
    return rel in META_NAMES or rel.startswith(".cubestack-")

def norm_rel(p):
    p = p.replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    return p

def detect_layout(root, release, layout):
    if layout != "auto":
        return layout
    has_release_env = os.path.isfile(os.path.join(root, "release.env"))
    has_sums = os.path.isfile(os.path.join(root, "SHA256SUMS"))
    if has_release_env and has_sums:
        return "sealed-dev" if not release else "flat"
    if has_sums:
        return "sealed-dev"
    return "unsealed-dev"

def collect_files(ctx, root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for d in list(dirnames):
            if os.path.islink(os.path.join(dirpath, d)):
                fail(ctx, os.path.relpath(os.path.join(dirpath, d), root), "symlink", "树内不允许符号链接")
                dirnames.remove(d)
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = norm_rel(os.path.relpath(full, root))
            if is_meta(rel):
                continue
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                fail(ctx, rel, "symlink", "树内不允许符号链接")
                continue
            if not stat.S_ISREG(st.st_mode):
                fail(ctx, rel, "not_regular", "不是普通文件")
                continue
            if TEMP_RE.search(rel):
                fail(ctx, rel, "temp_file", "残留临时文件")
            out.append(rel)
    return sorted(out)

def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "offline-files"))
    ap.add_argument("--release", default="")
    ap.add_argument("--cli-tar", default="")
    ap.add_argument("--layout", default="auto")
    ap.add_argument("--level", default="auto")
    ap.add_argument("--seal", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--stamp-file", default="")
    ap.add_argument("--no-stamp", action="store_true")
    ap.add_argument("--force-full", action="store_true")
    ap.add_argument("--allow-unsealed", action="store_true")
    ap.add_argument("--staging", action="store_true")
    ap.add_argument("--require-success", action="store_true")
    ap.add_argument("--require-cli-tar", action="store_true")
    ap.add_argument("--version", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.version:
        print(f"verify-offline-files {TOOL_VERSION} (schema {SCHEMA})")
        return 0
    if args.self_test:
        return self_test()
    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print(f"❌ 树根不存在: {root}", file=sys.stderr)
        return 2
    ctx = Ctx()
    layout = detect_layout(root, args.release, args.layout)
    ctx.layout = layout
    ctx.files = collect_files(ctx, root)
    ctx.total_bytes = sum(os.path.getsize(os.path.join(root, r)) for r in ctx.files if os.path.isfile(os.path.join(root, r)))
    ...
    return emit(ctx, args)

def emit(ctx, args):
    ok = not ctx.failures
    data = {"schema": SCHEMA, "tool_version": TOOL_VERSION, "layout": ctx.layout,
            "root": ctx.root, "release": args.release, "level": args.level, "ok": ok,
            "summary": {"files": len(ctx.files), "checked": len(ctx.files),
                        "failed": len(ctx.failures), "bytes": ctx.total_bytes},
            "checks": ctx.checks, "failures": ctx.failures, "warnings": ctx.warnings,
            "stamp": {"valid": False, "path": "", "reason": "not implemented"}}
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print(f"布局: {ctx.layout}  树根: {ctx.root}")
        for f in ctx.failures:
            print(f"❌ {f['path']}: {f['message']}")
        for w in ctx.warnings:
            print(f"⚠  {w}")
        print("✅ 校验通过" if ok else "❌ 校验失败")
    return 0 if ok else 1

def self_test():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "a.txt"), "w") as f:
            f.write("hello\n")
        ctx = Ctx(); ctx.root = d; ctx.layout = "unsealed-dev"
        ctx.files = collect_files(ctx, d)
        assert ctx.files == ["a.txt"], ctx.files
    print("✅ self-test 通过")
    return 0

if __name__ == "__main__":
    sys.exit(main())
PY
```

注意：`Ctx` 需要 `root`/`layout` 属性；在 `main` 里设置 `ctx.root = root`。

- [ ] **Step 4: 运行测试**

Run: `bash -n deployments/scripts/tools/offline/verify-offline-files.sh && bash deployments/scripts/tools/tests/test-verify-offline-files.sh`
Expected: 全部 `ok`（布局识别/版本/unsealed 行为）。

- [ ] **Step 5: 提交**

```bash
chmod +x deployments/scripts/tools/offline/verify-offline-files.sh
git add deployments/scripts/tools/offline/verify-offline-files.sh \
  deployments/scripts/tools/tests/test-verify-offline-files.sh \
  .github/workflows/ci-validate.yml
git commit -m "feat(offline): add verify-offline-files skeleton and layout detection"
```

---

### Task 2: 清单解析、覆盖性、metadata 检查

**Files:**
- Modify: `deployments/scripts/tools/offline/verify-offline-files.sh`
- Modify: `deployments/scripts/tools/tests/test-verify-offline-files.sh`

**Interfaces:**
- Produces: `parse_sha256sums(path) -> dict[rel,sha]`、`parse_sizes(path) -> dict[rel,int]`、`parse_success(path) -> dict`
- Produces: metadata failures kinds: `manifest_missing`, `manifest_format`, `manifest_path`, `manifest_dup`, `missing_file`, `extra_file`, `zero_byte`, `temp_file`, `success_binding`, `release_env_version`, `release_json`, `symlink`

- [ ] **Step 1: 写失败测试（追加）**

```bash
echo "== ④ 清单覆盖性 =="
mkdir -p "${TMP}/cov"
printf 'x' > "${TMP}/cov/a.txt"
printf 'y' > "${TMP}/cov/b.txt"
printf '%s  ./a.txt\n' "$(sha256sum "${TMP}/cov/a.txt" | awk '{print $1}')" > "${TMP}/cov/SHA256SUMS"
chk "缺 b.txt 失败" "1" "$(run "${TOOL}" --root "${TMP}/cov" --level metadata)"
chk_contains "点名 b.txt" "b.txt" "$(cat "${TMP}/out")"
printf '%s  ./a.txt\n%s  ./b.txt\n%s  ./gone.txt\n' \
  "$(sha256sum "${TMP}/cov/a.txt" | awk '{print $1}')" \
  "$(sha256sum "${TMP}/cov/b.txt" | awk '{print $1}')" \
  "0000000000000000000000000000000000000000000000000000000000000000" > "${TMP}/cov/SHA256SUMS"
chk "清单多出 gone.txt 失败" "1" "$(run "${TOOL}" --root "${TMP}/cov" --level metadata)"
chk_contains "点名 gone.txt" "gone.txt" "$(cat "${TMP}/out")"

echo "== ⑤ 清单截断/路径安全 =="
printf '%s  ./a.txt\n' "$(sha256sum "${TMP}/cov/a.txt" | awk '{print $1}')" > "${TMP}/cov/SHA256SUMS"
printf 'x' > "${TMP}/cov/.hidden.part"
chk "临时文件失败" "1" "$(run "${TOOL}" --root "${TMP}/cov" --level metadata)"
chk_contains "点名 .part" ".part" "$(cat "${TMP}/out")"
rm -f "${TMP}/cov/.hidden.part"
printf '%s  ../escape\n' "$(sha256sum "${TMP}/cov/a.txt" | awk '{print $1}')" > "${TMP}/cov/SHA256SUMS"
chk "路径穿越失败" "1" "$(run "${TOOL}" --root "${TMP}/cov" --level metadata)"

echo "== ⑥ _SUCCESS 绑定 =="
mkdir -p "${TMP}/rel2/offline-files"
printf 'RELEASE_VERSION=2.0.0\nKUBESPRAY_VERSION=v2.32.0\n' > "${TMP}/rel2/offline-files/release.env"
printf 'x' > "${TMP}/rel2/offline-files/a.txt"
(
  cd "${TMP}/rel2/offline-files"
  sha256sum ./a.txt ./release.env > SHA256SUMS
  printf 'release=2.0.0\nsha256sums=%s\n' "$(sha256sum SHA256SUMS | awk '{print $1}')" > _SUCCESS
)
chk "绑定正确通过" "0" "$(run "${TOOL}" --root "${TMP}/rel2/offline-files" --release 2.0.0 --layout release --level metadata --json)"
printf 'release=2.0.0\nsha256sums=%064d\n' 0 > "${TMP}/rel2/offline-files/_SUCCESS"
chk "绑定错误失败" "1" "$(run "${TOOL}" --root "${TMP}/rel2/offline-files" --release 2.0.0 --layout release --level metadata)"
chk_contains "点名绑定" "sha256sums" "$(cat "${TMP}/out")"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash deployments/scripts/tools/tests/test-verify-offline-files.sh`
Expected: FAIL（缺文件/多文件未报）

- [ ] **Step 3: 实现解析与 metadata**

在 Python 中加：

```python
SHA_RE = re.compile(r"^([0-9a-fA-F]{64}) [ *](.+)$")

def gnu_unescape(s):
    if not s.startswith("\\"):
        return s
    s = s[1:]
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            c = s[i + 1]
            out.append({"n": "\n", "\\": "\\"}.get(c, c))
            i += 2
        else:
            out.append(s[i]); i += 1
    return "".join(out)

def parse_sha256sums(ctx, path):
    result = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip():
                continue
            m = SHA_RE.match(line)
            if not m:
                fail(ctx, "SHA256SUMS", "manifest_format", f"第 {lineno} 行格式非法")
                continue
            sha, rel = m.group(1).lower(), norm_rel(gnu_unescape(m.group(2)))
            if rel.startswith("/") or ".." in rel.split("/") or rel in ("", "."):
                fail(ctx, "SHA256SUMS", "manifest_path", f"第 {lineno} 行路径非法: {rel}")
                continue
            if is_meta(rel):
                fail(ctx, rel, "manifest_meta", "清单不允许登记元数据/临时文件")
                continue
            if rel in result:
                fail(ctx, rel, "manifest_dup", "清单重复路径")
                continue
            result[rel] = sha
    return result

def parse_sizes(ctx, path):
    result = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip():
                continue
            m = re.match(r"^(\d+) [ *](.+)$", line)
            if not m:
                fail(ctx, "SIZES", "manifest_format", f"第 {lineno} 行格式非法")
                continue
            result[norm_rel(gnu_unescape(m.group(2)))] = int(m.group(1))
    return result

def parse_success(ctx, path):
    data = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
    return data

def check_metadata(ctx, root, layout, args):
    sums_path = os.path.join(root, "SHA256SUMS")
    ctx.checks["metadata"] = "ok"
    # _SUCCESS
    success_path = os.path.join(root, "_SUCCESS")
    success = {}
    if os.path.isfile(success_path):
        success = parse_success(ctx, success_path)
        if success.get("release") and args.release and success["release"] != args.release:
            fail(ctx, "_SUCCESS", "success_binding", f"release={success['release']} != {args.release}")
        if success.get("sha256sums"):
            actual = sha256_file(sums_path) if os.path.isfile(sums_path) else ""
            if actual != success["sha256sums"].lower():
                fail(ctx, "_SUCCESS", "success_binding",
                     f"sha256sums 与实际 SHA256SUMS 不符", success["sha256sums"], actual)
    elif layout == "release" and not args.staging:
        fail(ctx, "_SUCCESS", "success_missing", "release 布局缺少 _SUCCESS")
    elif args.require_success:
        fail(ctx, "_SUCCESS", "success_missing", "要求 _SUCCESS 存在")
    elif layout in ("flat", "sealed-dev"):
        warn(ctx, "_SUCCESS 不存在(flat/sealed-dev 兼容)")
    # release.env
    env_path = os.path.join(root, "release.env")
    if os.path.isfile(env_path):
        env = parse_env(env_path)
        if not env.get("RELEASE_VERSION"):
            fail(ctx, "release.env", "release_env_version", "缺少 RELEASE_VERSION")
        elif args.release and env["RELEASE_VERSION"] != args.release:
            fail(ctx, "release.env", "release_env_version",
                 f"RELEASE_VERSION={env['RELEASE_VERSION']} != {args.release}")
    # SHA256SUMS
    if not os.path.isfile(sums_path):
        if layout == "unsealed-dev" and args.allow_unsealed:
            warn(ctx, "无 SHA256SUMS, 仅做结构检查")
            return {}
        fail(ctx, "SHA256SUMS", "manifest_missing", "缺少 SHA256SUMS")
        return {}
    sums = parse_sha256sums(ctx, sums_path)
    disk = set(ctx.files)
    listed = set(sums)
    for rel in sorted(listed - disk):
        fail(ctx, rel, "missing_file", "清单登记但磁盘缺失")
    for rel in sorted(disk - listed):
        fail(ctx, rel, "extra_file", "磁盘存在但清单未登记")
    for rel in sorted(disk & listed):
        st = os.stat(os.path.join(root, rel))
        if st.st_size == 0:
            fail(ctx, rel, "zero_byte", "0 字节文件")
        ctx.total_bytes += st.st_size
    # SIZES
    sizes_path = os.path.join(root, "SIZES")
    if os.path.isfile(sizes_path):
        sizes = parse_sizes(ctx, sizes_path)
        if set(sizes) != listed:
            fail(ctx, "SIZES", "sizes_set", "SIZES 与 SHA256SUMS 路径集合不一致")
        for rel in sorted(set(sizes) & disk):
            actual = os.stat(os.path.join(root, rel)).st_size
            if sizes[rel] != actual:
                fail(ctx, rel, "size_mismatch", "文件大小不符", sizes[rel], actual)
    else:
        warn(ctx, "SIZES 缺失: quick 无法检测截断, 建议 --level full")
    # release.json
    json_path = os.path.join(root, "release.json")
    if os.path.isfile(json_path):
        try:
            data = json.load(open(json_path, encoding="utf-8"))
        except Exception as exc:
            fail(ctx, "release.json", "release_json", f"解析失败: {exc}")
        else:
            if args.release and data.get("release") and data["release"] != args.release:
                fail(ctx, "release.json", "release_json", f"release={data['release']} != {args.release}")
            sha = str(data.get("cli_tar_sha256") or "")
            if sha and not re.fullmatch(r"[0-9a-fA-F]{64}", sha):
                fail(ctx, "release.json", "release_json", "cli_tar_sha256 格式非法")
    if any(f["kind"].startswith(("manifest", "missing_file", "extra_file", "zero_byte",
                                  "success_binding", "success_missing", "release_env", "release_json",
                                  "symlink", "temp_file", "not_regular", "sizes_set", "size_mismatch"))
           for f in ctx.failures):
        ctx.checks["metadata"] = "fail"
    return sums
```

辅助函数：

```python
def parse_env(path):
    data = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            data[k.strip()] = v.strip().strip('"').strip("'")
    return data

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()
```

在 `main` 里调用 `sums = check_metadata(ctx, root, layout, args)`；`ctx.root = root`。

- [ ] **Step 4: 运行测试**

Run: `bash deployments/scripts/tools/tests/test-verify-offline-files.sh`
Expected: 全部 `ok`。

- [ ] **Step 5: 提交**

```bash
git add deployments/scripts/tools/offline/verify-offline-files.sh \
  deployments/scripts/tools/tests/test-verify-offline-files.sh
git commit -m "feat(offline): verify manifest coverage and metadata bindings"
```

---

### Task 3: quick 结构检查（tar/tgz/二进制/tree.sha256）

**Files:**
- Modify: `deployments/scripts/tools/offline/verify-offline-files.sh`
- Modify: `deployments/scripts/tools/tests/test-verify-offline-files.sh`

**Interfaces:**
- Produces: `check_structure(ctx, root, files, sums)`，failure kinds `tar_invalid`, `tar_truncated`, `tar_layers`, `gzip_invalid`, `chart_invalid`, `binary_invalid`, `deb_invalid`, `tree_sha_mismatch`
- Produces: `check_sizes`（在 metadata 已实现，quick 复用）

- [ ] **Step 1: 写失败测试（追加）**

```bash
echo "== ⑦ 结构: 截断 tar / 空壳 docker-archive =="
mkdir -p "${TMP}/st"
tar -C "${TMP}/st" -cf "${TMP}/st/good.tar" --files-from /dev/null 2>/dev/null || tar -C "${TMP}/st" -cf "${TMP}/st/good.tar" -T /dev/null
head -c 100 "${TMP}/st/good.tar" > "${TMP}/st/trunc.tar"
mkdir -p "${TMP}/st/src" && printf 'x' > "${TMP}/st/src/x"
tar -C "${TMP}/st/src" -cf "${TMP}/st/trunc.tar" . && head -c 200 "${TMP}/st/trunc.tar" > "${TMP}/st/trunc.tmp" && mv "${TMP}/st/trunc.tmp" "${TMP}/st/trunc.tar"
rm -f "${TMP}/st/good.tar"
printf '{}' > "${TMP}/st/manifest.json"
tar -C "${TMP}/st" -cf "${TMP}/st/shell.tar" manifest.json
(
  cd "${TMP}/st"
  sha256sum ./trunc.tar ./shell.tar > SHA256SUMS
)
chk "截断 tar 失败" "1" "$(run "${TOOL}" --root "${TMP}/st" --level quick)"
chk_contains "点名 trunc.tar" "trunc.tar" "$(cat "${TMP}/out")"
chk_contains "空壳 tar 失败" "shell.tar" "$(cat "${TMP}/out")"

echo "== ⑧ 结构: 二进制/截断(含 SIZES) =="
mkdir -p "${TMP}/bin"
printf '\177ELF\002\001\001' > "${TMP}/bin/run"
chmod +x "${TMP}/bin/run"
printf '%s  ./run\n' "$(sha256sum "${TMP}/bin/run" | awk '{print $1}')" > "${TMP}/bin/SHA256SUMS"
printf '%s  ./run\n' "$(stat -c %s "${TMP}/bin/run")" > "${TMP}/bin/SIZES"
chk "合法 ELF 通过" "0" "$(run "${TOOL}" --root "${TMP}/bin" --level quick)"
printf 'notelf' > "${TMP}/bin/run"
chk "坏 ELF 失败" "1" "$(run "${TOOL}" --root "${TMP}/bin" --level quick)"

echo "== ⑨ tree.tar.gz 边车 =="
mkdir -p "${TMP}/tree"
printf 'tree' > "${TMP}/tree/tree.tar.gz"
printf '%s\n' "$(sha256sum "${TMP}/tree/tree.tar.gz" | awk '{print $1}')" > "${TMP}/tree/tree.tar.gz.sha256"
(
  cd "${TMP}/tree"
  sha256sum ./tree.tar.gz ./tree.tar.gz.sha256 > SHA256SUMS
)
chk "tree 边车一致通过" "0" "$(run "${TOOL}" --root "${TMP}/tree" --level quick)"
printf 'deadbeef\n' > "${TMP}/tree/tree.tar.gz.sha256"
(
  cd "${TMP}/tree"
  sha256sum ./tree.tar.gz ./tree.tar.gz.sha256 > SHA256SUMS
)
chk "tree 边车不符失败" "1" "$(run "${TOOL}" --root "${TMP}/tree" --level quick)"
```

- [ ] **Step 2: 运行确认失败**

Expected: `--level quick` 目前没有结构检查，截断/空壳/坏 ELF 不会失败。

- [ ] **Step 3: 实现结构检查**

```python
def check_structure(ctx, root, sums):
    ctx.checks["structure"] = "ok"
    for rel in ctx.files:
        path = os.path.join(root, rel)
        low = rel.lower()
        if low.endswith(".tar"):
            if not check_tar(ctx, path, rel):
                continue
        elif low.endswith((".tar.gz", ".tgz", ".tar.xz")):
            if not check_compressed(ctx, path, rel):
                continue
        elif low.endswith(".deb"):
            if not check_magic(ctx, path, rel, b"!<arch>\n", "deb_invalid"):
                continue
        elif low.endswith((".run",)) or is_binary_name(rel):
            if not check_elf_or_shebang(ctx, path, rel):
                continue
        if low.endswith("tree.tar.gz"):
            side = path + ".sha256"
            if os.path.isfile(side):
                want = open(side, encoding="utf-8").read().strip().split()[0].lower()
                got = sha256_file(path)
                if want != got:
                    fail(ctx, rel, "tree_sha_mismatch", "tree.tar.gz 与 .sha256 不符", want, got)
            else:
                warn(ctx, f"{rel}: 缺少 tree.tar.gz.sha256")
    if any(f["kind"] in {"tar_invalid", "tar_truncated", "tar_layers", "gzip_invalid",
                          "chart_invalid", "binary_invalid", "deb_invalid", "tree_sha_mismatch"}
           for f in ctx.failures):
        ctx.checks["structure"] = "fail"

def check_tar(ctx, path, rel):
    size = os.path.getsize(path)
    if size == 0:
        fail(ctx, rel, "tar_invalid", "tar 为空")
        return False
    with open(path, "rb") as f:
        if size >= 1024:
            f.seek(-1024, os.SEEK_END)
            tail = f.read(1024)
        else:
            tail = b""
    ok_tail = tail == b"\0" * 1024
    try:
        with tarfile.open(path, "r:") as tf:
            names = set()
            manifest = None
            for m in tf:
                names.add(norm_rel(m.name))
                if norm_rel(m.name) == "manifest.json" and m.isfile():
                    manifest = json.loads(tf.extractfile(m).read().decode("utf-8"))
            if manifest is not None:
                refs = []
                cfg = manifest.get("Config")
                if cfg:
                    refs.append(norm_rel(cfg))
                for layer in manifest.get("Layers") or []:
                    refs.append(norm_rel(layer))
                missing = [r for r in refs if r not in names]
                if missing:
                    fail(ctx, rel, "tar_layers",
                         f"docker-archive 引用成员缺失: {', '.join(missing[:5])}")
                    return False
            return True
    except Exception as exc:
        fail(ctx, rel, "tar_truncated" if not ok_tail else "tar_invalid",
             f"tar 解析失败: {exc}")
        return False

def check_compressed(ctx, path, rel):
    size = os.path.getsize(path)
    if size < 18:
        fail(ctx, rel, "gzip_invalid", "压缩包过小")
        return False
    with open(path, "rb") as f:
        magic = f.read(2)
        f.seek(-8, os.SEEK_END)
        footer = f.read(8)
    if magic != b"\x1f\x8b" or len(footer) != 8:
        fail(ctx, rel, "gzip_invalid", "gzip 魔数/页脚缺失")
        return False
    if size <= 256 * 1024 * 1024:
        try:
            with tarfile.open(path, "r:gz") as tf:
                names = {norm_rel(m.name) for m in tf}
                if rel.endswith(".tgz") or "charts/" in rel:
                    if "Chart.yaml" not in names:
                        fail(ctx, rel, "chart_invalid", "chart 缺少 Chart.yaml")
                        return False
        except Exception as exc:
            fail(ctx, rel, "gzip_invalid", f"gzip/tar 解析失败: {exc}")
            return False
    else:
        warn(ctx, f"{rel}: >256MiB, quick 未深度解压(建议 full)")
    return True

def check_magic(ctx, path, rel, magic, kind):
    with open(path, "rb") as f:
        head = f.read(len(magic))
    if head != magic:
        fail(ctx, rel, kind, "魔数不符")
        return False
    return True

def check_elf_or_shebang(ctx, path, rel):
    with open(path, "rb") as f:
        head = f.read(4)
    if head != b"\x7fELF" and not head.startswith(b"#!"):
        fail(ctx, rel, "binary_invalid", "不是 ELF/shebang 可执行文件")
        return False
    if not (os.stat(path).st_mode & 0o111):
        fail(ctx, rel, "binary_invalid", "缺少可执行位")
        return False
    return True

def is_binary_name(rel):
    base = os.path.basename(rel)
    if base.endswith((".tar", ".tar.gz", ".tgz", ".deb", ".sha256", ".txt", ".md", ".tsv",
                      ".json", ".yaml", ".yml", ".conf", ".env", ".profile", ".gz", ".xz")):
        return False
    return "/kubespray/" in f"/{rel}" and rel.count("/") >= 2
```

在 `main` 中：`if args.level in ("quick", "full", "auto"): check_structure(ctx, root, sums)`（auto 在 unsealed 时也要 quick；见 Task 4 的 level 解析）。

- [ ] **Step 4: 运行测试**

Run: `bash deployments/scripts/tools/tests/test-verify-offline-files.sh`
Expected: 全部 `ok`。

- [ ] **Step 5: 提交**

```bash
git add deployments/scripts/tools/offline/verify-offline-files.sh \
  deployments/scripts/tools/tests/test-verify-offline-files.sh
git commit -m "feat(offline): add quick structural checks for tar/tgz/binaries"
```

---

### Task 4: full 哈希、CLI tar、校验戳

**Files:**
- Modify: `deployments/scripts/tools/offline/verify-offline-files.sh`
- Modify: `deployments/scripts/tools/tests/test-verify-offline-files.sh`

**Interfaces:**
- Produces: `check_full(ctx, root, sums, args)`
- Produces: `stamp_path(root,args)`、`stamp_valid(root,args,sums)`、`write_stamp(...)`
- Produces: `--level auto` 行为（有效戳→复查；否则 full；unsealed→quick）

- [ ] **Step 1: 写失败测试（追加）**

```bash
echo "== ⑩ full: 内容损坏 =="
mkdir -p "${TMP}/full"
printf 'aaaa' > "${TMP}/full/a.bin"
printf '%s  ./a.bin\n' "$(sha256sum "${TMP}/full/a.bin" | awk '{print $1}')" > "${TMP}/full/SHA256SUMS"
chk "full 通过" "0" "$(run "${TOOL}" --root "${TMP}/full" --level full)"
printf 'bbbb' > "${TMP}/full/a.bin"
chk "full 坏字节失败" "1" "$(run "${TOOL}" --root "${TMP}/full" --level full)"
chk_contains "点名 a.bin" "a.bin" "$(cat "${TMP}/out")"

echo "== ⑪ 校验戳 =="
printf 'aaaa' > "${TMP}/full/a.bin"
printf '%s  ./a.bin\n' "$(sha256sum "${TMP}/full/a.bin" | awk '{print $1}')" > "${TMP}/full/SHA256SUMS"
chk "full+写戳" "0" "$(run "${TOOL}" --root "${TMP}/full" --level full)"
[ -f "${TMP}/full/.cubestack-verified.json" ] && echo "  ok  戳已写" || { echo "  FAIL 戳未写"; fail=1; }
chk "auto 走戳通过" "0" "$(run "${TOOL}" --root "${TMP}/full" --level auto)"
touch "${TMP}/full/a.bin"
chk "戳失效后 auto 重跑 full" "0" "$(run "${TOOL}" --root "${TMP}/full" --level auto --json)"
chk_contains "stamp.valid=false 或重算" '"level": "full"' "$(cat "${TMP}/out")"
printf 'cccc' > "${TMP}/full/a.bin"
chk "截断/改动后 auto 失败" "1" "$(run "${TOOL}" --root "${TMP}/full" --level auto)"

echo "== ⑫ CLI tar =="
mkdir -p "${TMP}/rel3/offline-files"
printf 'RELEASE_VERSION=3.0.0\n' > "${TMP}/rel3/offline-files/release.env"
printf 'x' > "${TMP}/rel3/offline-files/a.txt"
printf 'cli' > "${TMP}/rel3/cubestack-installer-cli-v3.0.0.tar"
(
  cd "${TMP}/rel3/offline-files"
  sha256sum ./a.txt ./release.env > SHA256SUMS
  printf 'release=3.0.0\nsha256sums=%s\n' "$(sha256sum SHA256SUMS | awk '{print $1}')" > _SUCCESS
)
printf '{"release":"3.0.0","cli_tar_sha256":"%s","cli_tar_size":3}\n' \
  "$(sha256sum "${TMP}/rel3/cubestack-installer-cli-v3.0.0.tar" | awk '{print $1}')" \
  > "${TMP}/rel3/offline-files/release.json"
chk "CLI tar 正确通过" "0" "$(run "${TOOL}" --root "${TMP}/rel3/offline-files" --release 3.0.0 --layout release --level full)"
printf 'bad' > "${TMP}/rel3/cubestack-installer-cli-v3.0.0.tar"
chk "CLI tar 损坏失败" "1" "$(run "${TOOL}" --root "${TMP}/rel3/offline-files" --release 3.0.0 --layout release --level full)"
```

- [ ] **Step 2: 运行确认失败**

Expected: full 不比对哈希；戳不存在。

- [ ] **Step 3: 实现 full + stamp**

```python
def check_full(ctx, root, sums, args):
    ctx.checks["sha256"] = "ok"
    if not sums:
        return
    def work(rel):
        return rel, sha256_file(os.path.join(root, rel))
    done = 0
    start = time.time()
    import concurrent.futures as cf
    with cf.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
        futs = {ex.submit(work, rel): rel for rel in sums}
        for fut in cf.as_completed(futs):
            rel, got = fut.result()
            done += 1
            want = sums[rel].lower()
            if got != want:
                fail(ctx, rel, "sha256_mismatch", "sha256 不符", want, got)
            if done % 100 == 0 or done == len(sums):
                print(f"  sha256 {done}/{len(sums)} ({time.time()-start:.0f}s)", file=sys.stderr)
    if any(f["kind"] == "sha256_mismatch" for f in ctx.failures):
        ctx.checks["sha256"] = "fail"
    # CLI tar
    cli = find_cli_tar(root, args)
    ctx.checks["cli_tar"] = "ok"
    if cli:
        rel_json = os.path.join(root, "release.json")
        want_sha = want_size = None
        if os.path.isfile(rel_json):
            try:
                data = json.load(open(rel_json, encoding="utf-8"))
                want_sha = str(data.get("cli_tar_sha256") or "").lower() or None
                want_size = data.get("cli_tar_size")
            except Exception:
                pass
        if want_size is not None and os.path.getsize(cli) != int(want_size):
            fail(ctx, os.path.basename(cli), "cli_tar", "CLI tar 大小不符", want_size, os.path.getsize(cli))
            ctx.checks["cli_tar"] = "fail"
        if want_sha:
            got = sha256_file(cli)
            if got != want_sha:
                fail(ctx, os.path.basename(cli), "cli_tar", "CLI tar sha256 不符", want_sha, got)
                ctx.checks["cli_tar"] = "fail"
    elif args.require_cli_tar:
        fail(ctx, "cubestack-installer-cli.tar", "cli_tar_missing", "缺少 CLI tar")
        ctx.checks["cli_tar"] = "fail"
    elif args.layout == "release":
        warn(ctx, "CLI tar 不存在(部署不需要, 已跳过)")

def find_cli_tar(root, args):
    if args.cli_tar:
        return args.cli_tar if os.path.isfile(args.cli_tar) else ("MISSING:" + args.cli_tar)
    rel_json = os.path.join(root, "release.json")
    name = ""
    if os.path.isfile(rel_json):
        try:
            data = json.load(open(rel_json, encoding="utf-8"))
            name = os.path.basename(str(data.get("cli_tar") or ""))
        except Exception:
            pass
    if not name and args.release:
        name = f"cubestack-installer-cli-v{args.release}.tar"
    if not name:
        return None
    cand = os.path.join(os.path.dirname(root), name)
    return cand if os.path.isfile(cand) else ("MISSING:" + cand)
```

注意：`find_cli_tar` 返回 `"MISSING:..."` 时 `check_full` 要区分；简化实现为返回 `(path_or_None, missing_path)`。计划实现时用：

```python
def find_cli_tar(root, args):
    ...
    return cand if os.path.isfile(cand) else None
```

若 `args.require_cli_tar` 且 `None` → 失败；否则 warning。

校验戳：

```python
def fingerprint(root, sums):
    h = hashlib.sha256()
    for rel in sorted(sums):
        st = os.stat(os.path.join(root, rel))
        h.update(f"{rel}\0{st.st_size}\0{st.st_mtime_ns}\0{st.st_ino}\0{st.st_dev}\n".encode())
    return h.hexdigest()

def stamp_path(root, args):
    return args.stamp_file or os.path.join(root, ".cubestack-verified.json")

def write_stamp(root, args, sums, total_bytes):
    path = stamp_path(root, args)
    data = {
        "schema": SCHEMA, "tool_version": TOOL_VERSION, "level": "full",
        "layout": args.layout, "release": args.release, "root": root,
        "manifest": "SHA256SUMS",
        "manifest_sha256": sha256_file(os.path.join(root, "SHA256SUMS")),
        "files": len(sums), "bytes": total_bytes,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host_fingerprint": host_fingerprint(),
        "fingerprint": fingerprint(root, sums),
    }
    tmp = path + f".tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)

def host_fingerprint():
    for p in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        try:
            v = open(p, encoding="utf-8").read().strip()
            if v:
                return hashlib.sha256(v.encode()).hexdigest()
        except OSError:
            pass
    return hashlib.sha256(os.uname().nodename.encode()).hexdigest()

def stamp_valid(root, args, sums):
    path = stamp_path(root, args)
    if not os.path.isfile(path):
        return False, path, "missing"
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception as exc:
        return False, path, f"parse: {exc}"
    sums_path = os.path.join(root, "SHA256SUMS")
    if not os.path.isfile(sums_path):
        return False, path, "manifest missing"
    if data.get("manifest_sha256") != sha256_file(sums_path):
        return False, path, "manifest changed"
    try:
        if data.get("fingerprint") != fingerprint(root, sums):
            return False, path, "fingerprint mismatch"
    except OSError as exc:
        return False, path, f"stat: {exc}"
    return True, path, "ok"
```

在 `main` 解析 level：

```python
level = args.level
if level == "auto":
    if layout == "unsealed-dev":
        level = "quick"; args.allow_unsealed = True
    else:
        valid, spath, reason = stamp_valid(root, args, sums)
        if valid and not args.force_full:
            ctx.checks["stamp"] = "ok"
            emit and return 0
        level = "full"
args.level = level
check_structure(...)
if level == "full":
    check_full(...)
    if not ctx.failures and not args.no_stamp:
        write_stamp(root, args, sums, ctx.total_bytes)
```

`emit` 中填充 stamp 状态。

- [ ] **Step 4: 运行测试**

Run: `bash deployments/scripts/tools/tests/test-verify-offline-files.sh`
Expected: 全部 `ok`。

- [ ] **Step 5: 提交**

```bash
git add deployments/scripts/tools/offline/verify-offline-files.sh \
  deployments/scripts/tools/tests/test-verify-offline-files.sh
git commit -m "feat(offline): add full sha256 verification and verification stamp"
```

---

### Task 5: `--seal`

**Files:**
- Modify: `deployments/scripts/tools/offline/verify-offline-files.sh`
- Modify: `deployments/scripts/tools/tests/test-verify-offline-files.sh`

**Interfaces:**
- Produces: `seal(root, args)`；生成 `SHA256SUMS` + `SIZES`；备份到 `.cubestack-manifest-backup/<ts>/`
- Produces: 退出码 2：发现临时文件/符号链接/不可读文件/正式发布树未 `--force`

- [ ] **Step 1: 写失败测试（追加）**

```bash
echo "== ⑬ seal =="
mkdir -p "${TMP}/seal"
printf 'x' > "${TMP}/seal/a.txt"
chk "seal 通过" "0" "$(run "${TOOL}" --root "${TMP}/seal" --seal)"
chk "生成 SHA256SUMS" "1" "$([ -f "${TMP}/seal/SHA256SUMS" ] && echo 1 || echo 0)"
chk "生成 SIZES" "1" "$([ -f "${TMP}/seal/SIZES" ] && echo 1 || echo 0)"
chk "seal 后 metadata 通过" "0" "$(run "${TOOL}" --root "${TMP}/seal" --level metadata)"
chk "seal 幂等" "0" "$(run "${TOOL}" --root "${TMP}/seal" --seal)"
chk "备份存在" "1" "$(find "${TMP}/seal/.cubestack-manifest-backup" -name SHA256SUMS 2>/dev/null | head -1 | grep -q . && echo 1 || echo 0)"
printf 'x' > "${TMP}/seal/left.part"
chk "临时文件拒绝" "2" "$(run "${TOOL}" --root "${TMP}/seal" --seal)"
rm -f "${TMP}/seal/left.part"
printf 'RELEASE_VERSION=9.9.9\n' > "${TMP}/seal/release.env"
chk "正式树拒绝(无 --force)" "2" "$(run "${TOOL}" --root "${TMP}/seal" --seal)"
chk "--force 允许" "0" "$(run "${TOOL}" --root "${TMP}/seal" --seal --force)"
```

- [ ] **Step 2: 运行确认失败**

Expected: `--seal` 未实现（参数存在但无动作/退出码不符）。

- [ ] **Step 3: 实现 seal**

```python
def seal(root, args):
    files = collect_files(Ctx(), root)
    # 拒绝 symlink/temp 已在 collect_files 记录，这里重新检查并用退出码 2
    problems = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for d in dirnames:
            full = os.path.join(dirpath, d)
            if os.path.islink(full):
                problems.append(f"符号链接: {os.path.relpath(full, root)}")
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = norm_rel(os.path.relpath(full, root))
            if is_meta(rel):
                continue
            if os.path.islink(full):
                problems.append(f"符号链接: {rel}")
            elif TEMP_RE.search(rel):
                problems.append(f"临时文件: {rel}")
            elif not os.access(full, os.R_OK):
                problems.append(f"不可读: {rel}")
    if problems:
        for p in problems:
            print(f"❌ {p}", file=sys.stderr)
        return 2
    if not args.force and (os.path.isfile(os.path.join(root, "_SUCCESS"))
                           or os.path.isfile(os.path.join(root, "release.env"))):
        print("❌ 这是正式发布树; 如确认要重签请加 --force", file=sys.stderr)
        return 2
    sums = {}
    sizes = {}
    for rel in files:
        path = os.path.join(root, rel)
        sums[rel] = sha256_file(path)
        sizes[rel] = os.path.getsize(path)
    backup = os.path.join(root, ".cubestack-manifest-backup", time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(backup, exist_ok=True)
    for name in ("SHA256SUMS", "SIZES"):
        src = os.path.join(root, name)
        if os.path.isfile(src):
            import shutil
            shutil.copy2(src, os.path.join(backup, name))
    write_manifest(root, sums, sizes)
    print(f"✅ 已生成 SHA256SUMS({len(sums)} 项) + SIZES")
    return 0

def write_manifest(root, sums, sizes):
    tmp_s = os.path.join(root, f".cubestack-SHA256SUMS.tmp.{os.getpid()}")
    tmp_z = os.path.join(root, f".cubestack-SIZES.tmp.{os.getpid()}")
    with open(tmp_s, "w", encoding="utf-8") as f:
        for rel in sorted(sums):
            f.write(f"{sums[rel]}  ./{rel}\n")
    with open(tmp_z, "w", encoding="utf-8") as f:
        for rel in sorted(sizes):
            f.write(f"{sizes[rel]}  ./{rel}\n")
    os.replace(tmp_s, os.path.join(root, "SHA256SUMS"))
    os.replace(tmp_z, os.path.join(root, "SIZES"))
```

在 `main` 里：`if args.seal: return seal(root, args)`（在 metadata 前）。

- [ ] **Step 4: 运行测试**

Run: `bash deployments/scripts/tools/tests/test-verify-offline-files.sh`
Expected: 全部 `ok`。

- [ ] **Step 5: 提交**

```bash
git add deployments/scripts/tools/offline/verify-offline-files.sh \
  deployments/scripts/tools/tests/test-verify-offline-files.sh
git commit -m "feat(offline): add --seal for arbitrary offline trees"
```

---

### Task 6: `lib-offline-verify.sh` 工具定位 + 在线安装 3 次

**Files:**
- Create: `deployments/scripts/tools/offline/lib-offline-verify.sh`
- Create: `deployments/config/verify-tool.sha256`
- Create: `deployments/scripts/tools/tests/test-verify-tool-install.sh`

**Interfaces:**
- Produces: `ensure_offline_verify_tool` → stdout 工具路径；失败返回 1
- Consumes: `OFFLINE_FILES_ROOT`、`OFFLINE_VERIFY_ONLINE_INSTALL`、`OFFLINE_VERIFY_TOOL_URL`、`OFFLINE_VERIFY_TOOL_SHA256`

- [ ] **Step 1: 写失败测试**

```bash
#!/bin/bash
# test-verify-tool-install.sh — 工具自举/在线安装回归(假 curl)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/tools/offline/lib-offline-verify.sh"
TOOL="${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

# 假 curl: 前两次失败, 第三次把 $FAKE_TOOL 拷贝到 -o 目标
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/curl" <<'EOF'
#!/bin/bash
n=$(cat "${FAKE_COUNT}" 2>/dev/null || echo 0); n=$((n+1)); echo "${n}" > "${FAKE_COUNT}"
[ "${n}" -lt 3 ] && exit 7
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
cp "${FAKE_TOOL}" "${out}"
EOF
chmod +x "${TMP}/bin/curl"
export FAKE_COUNT="${TMP}/count" FAKE_TOOL="${TOOL}"
export PATH="${TMP}/bin:${PATH}"

echo "== ① 在线安装: 前两次失败第三次成功 =="
out="$(OFFLINE_VERIFY_TOOL_URL="https://example.invalid/tool" \
       OFFLINE_VERIFY_TOOL_SHA256="$(sha256sum "${TOOL}" | awk '{print $1}')" \
       XDG_CACHE_HOME="${TMP}/cache" \
       bash -c 'source "$1"; ensure_offline_verify_tool' _ "${LIB}" 2>/dev/null)"
chk "返回路径存在" "1" "$([ -x "${out}" ] && echo 1 || echo 0)"
chk "3 次尝试" "3" "$(cat "${FAKE_COUNT}")"

echo "== ② 3 次全失败 =="
rm -f "${TMP}/count"
sed -i 's/\[ "${n}" -lt 3 \] && exit 7/[ "${n}" -lt 99 ] \&\& exit 7/' "${TMP}/bin/curl"
rc=0
OFFLINE_VERIFY_TOOL_URL="https://example.invalid/tool" \
OFFLINE_VERIFY_TOOL_SHA256="$(sha256sum "${TOOL}" | awk '{print $1}')" \
XDG_CACHE_HOME="${TMP}/cache2" \
bash -c 'source "$1"; ensure_offline_verify_tool' _ "${LIB}" >/dev/null 2>&1 || rc=$?
chk "失败退出码 1" "1" "${rc}"
chk "共 3 次" "3" "$(cat "${FAKE_COUNT}")"

echo "== ③ sha 不符拒绝 =="
rm -f "${TMP}/count"
sed -i 's/\[ "${n}" -lt 99 \] && exit 7/exit 0/' "${TMP}/bin/curl"
rc=0
OFFLINE_VERIFY_TOOL_URL="https://example.invalid/tool" \
OFFLINE_VERIFY_TOOL_SHA256="$(printf '0%.0s' {1..64})" \
XDG_CACHE_HOME="${TMP}/cache3" \
bash -c 'source "$1"; ensure_offline_verify_tool' _ "${LIB}" >/dev/null 2>&1 || rc=$?
chk "sha 不符失败" "1" "${rc}"
chk "未落位" "0" "$([ -e "${TMP}/cache3/cubestack/verify/verify-offline-files.sh" ] && echo 1 || echo 0)"

echo "== ④ pin 缺失 fail-closed =="
rc=0
OFFLINE_VERIFY_TOOL_URL="https://example.invalid/tool" \
OFFLINE_VERIFY_TOOL_SHA256="" \
XDG_CACHE_HOME="${TMP}/cache4" \
bash -c 'source "$1"; ensure_offline_verify_tool' _ "${LIB}" >/dev/null 2>&1 || rc=$?
chk "pin 缺失失败" "1" "${rc}"

echo "---------------------------------------------"
[ "${fail}" = "0" ] && { echo "✅ 工具自举回归通过"; exit 0; } || { echo "❌ 回归失败"; exit 1; }
```

- [ ] **Step 2: 运行确认失败**

Expected: `lib-offline-verify.sh` 不存在。

- [ ] **Step 3: 实现库**

```bash
#!/bin/bash
# lib-offline-verify.sh — 校验器定位/自举(被 source, 不直接执行)
set -uo pipefail
_OV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_OV_REPO_ROOT="$(cd "${_OV_LIB_DIR}/../../../.." && pwd)"
_OV_TOOL_NAME="verify-offline-files.sh"
_OV_PIN_FILE="${_OV_REPO_ROOT}/deployments/config/verify-tool.sha256"

_ov_log() { echo "$*" >&2; }

_ov_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

_ov_bootstrap_ok() {   # <tree-root> <tool-path>
    local root="$1" tool="$2" rel want got
    [ -f "${root}/SHA256SUMS" ] || return 1
    rel="tools/$(basename "${tool}")"
    want="$(awk -v p="./${rel}" '$2==p {print $1}' "${root}/SHA256SUMS" | head -1)"
    [ -n "${want}" ] || want="$(awk -v p="${rel}" '$2==p {print $1}' "${root}/SHA256SUMS" | head -1)"
    [ -n "${want}" ] || return 1
    got="$(_ov_sha "${tool}")"
    [ -n "${got}" ] && [ "${want}" = "${got}" ]
}

_ov_try_online() {
    local url="${OFFLINE_VERIFY_TOOL_URL:-https://raw.githubusercontent.com/suanova/cubestack-installer/main/deployments/scripts/tools/offline/verify-offline-files.sh}"
    local pin="${OFFLINE_VERIFY_TOOL_SHA256:-}"
    local cache="${XDG_CACHE_HOME:-$HOME/.cache}/cubestack/verify"
    local dst="${cache}/${_OV_TOOL_NAME}" tmp n rc
    if [ -z "${pin}" ] && [ -f "${_OV_PIN_FILE}" ]; then
        pin="$(tr -d '[:space:]' < "${_OV_PIN_FILE}")"
    fi
    if [ -z "${pin}" ]; then
        _ov_log "⚠ 未配置校验器 pin(OFFLINE_VERIFY_TOOL_SHA256 / deployments/config/verify-tool.sha256), 拒绝在线安装"
        return 1
    fi
    mkdir -p "${cache}" || return 1
    tmp="${dst}.part.$$"
    for n in 1 2 3; do
        rm -f "${tmp}"
        if command -v curl >/dev/null 2>&1 \
           && curl -fsSL --connect-timeout 5 --max-time 30 -o "${tmp}" "${url}"; then
            if [ "$(_ov_sha "${tmp}")" = "${pin}" ]; then
                chmod 0755 "${tmp}" && mv -f "${tmp}" "${dst}" || { rm -f "${tmp}"; return 1; }
                _ov_log "✅ 已在线安装校验器: ${dst}"
                printf '%s\n' "${dst}"
                return 0
            fi
            _ov_log "⚠ 第 ${n}/3 次安装: sha256 不符, 丢弃"
        else
            _ov_log "⚠ 第 ${n}/3 次安装失败: ${url}"
        fi
        rm -f "${tmp}"
        [ "${n}" -lt 3 ] && sleep $((n * 3))
    done
    return 1
}

ensure_offline_verify_tool() {
    local tool tree
    # 1. 环境变量
    if [ -n "${CUBESTACK_VERIFY_TOOL:-}" ] && [ -x "${CUBESTACK_VERIFY_TOOL}" ]; then
        printf '%s\n' "${CUBESTACK_VERIFY_TOOL}"; return 0
    fi
    # 2. 仓库副本
    tool="${_OV_LIB_DIR}/${_OV_TOOL_NAME}"
    if [ -x "${tool}" ]; then
        printf '%s\n' "${tool}"; return 0
    fi
    # 3. 发布树副本(先用 SHA256SUMS 引导校验)
    tree="${OFFLINE_FILES_ROOT:-}"
    if [ -n "${tree}" ] && [ -x "${tree}/tools/${_OV_TOOL_NAME}" ]; then
        if _ov_bootstrap_ok "${tree}" "${tree}/tools/${_OV_TOOL_NAME}"; then
            printf '%s\n' "${tree}/tools/${_OV_TOOL_NAME}"; return 0
        fi
        _ov_log "⚠ 发布树校验器引导校验失败, 拒绝执行: ${tree}/tools/${_OV_TOOL_NAME}"
    fi
    # 4. PATH
    if command -v cubestack-verify-offline >/dev/null 2>&1; then
        command -v cubestack-verify-offline; return 0
    fi
    # 5. 在线安装
    case "${OFFLINE_VERIFY_ONLINE_INSTALL:-auto}" in
        never) return 1 ;;
        *) _ov_try_online ;;
    esac
}
```

pin 文件初始内容：在 Task 10 生成（工具最终形态后）。本任务测试用 `OFFLINE_VERIFY_TOOL_SHA256` 环境变量。

- [ ] **Step 4: 运行测试**

Run: `bash deployments/scripts/tools/tests/test-verify-tool-install.sh`
Expected: 全部 `ok`。

- [ ] **Step 5: 提交**

```bash
chmod +x deployments/scripts/tools/offline/lib-offline-verify.sh
git add deployments/scripts/tools/offline/lib-offline-verify.sh \
  deployments/scripts/tools/tests/test-verify-tool-install.sh
git commit -m "feat(offline): add verifier bootstrap with pinned online install"
```

---

### Task 7: 部署门禁 + `load_config` source 前检查

**Files:**
- Modify: `deployments/scripts/lib-common.sh`
- Modify: `deployments/scripts/deploy-cluster.sh`
- Modify: `deployments/config/cluster.defaults.conf`
- Modify: `deployments/config/cluster.conf.example`
- Modify: `deployments/scripts/tools/tests/test-release-mode.sh`

**Interfaces:**
- Produces: `verify_offline_gate` (lib-common) → 0/1
- Produces: `verify_release_env_precheck <release-root>` (lib-common)
- Consumes: `OFFLINE_VERIFY_MODE`, `OFFLINE_VERIFY_JOBS`, `OFFLINE_VERIFY_STRICT_DEV`

- [ ] **Step 1: 写失败测试（追加到 test-release-mode.sh）**

```bash
echo "== ⑦ release.env source 前校验 =="
mkdir -p "${TMP}/precheck/1.2.3/offline-files"
printf 'RELEASE_VERSION=1.2.3\nKUBESPRAY_VERSION=v2.32.0\n' > "${TMP}/precheck/1.2.3/offline-files/release.env"
(
  cd "${TMP}/precheck/1.2.3/offline-files"
  sha256sum ./release.env > SHA256SUMS
  printf 'release=1.2.3\nsha256sums=%s\n' "$(sha256sum SHA256SUMS | awk '{print $1}')" > _SUCCESS
)
out="$(CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE=1.2.3 CUBESTACK_RELEASE_ROOT="${TMP}/precheck" \
    bash -c 'source "$1"; load_config; echo OK' _ "${LIB}" 2>&1)"
chk_contains "一致时加载成功" "OK" "${out}"
printf 'RELEASE_VERSION=1.2.3\nKUBESPRAY_VERSION=v9.9.9\n' > "${TMP}/precheck/1.2.3/offline-files/release.env"
rc=0
CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE=1.2.3 CUBESTACK_RELEASE_ROOT="${TMP}/precheck" \
    bash -c 'source "$1"; load_config' _ "${LIB}" >/dev/null 2>&1 || rc=$?
chk "release.env 损坏被拒绝" "1" "${rc}"

echo "== ⑧ 部署门禁 =="
mkdir -p "${TMP}/gate/offline-files"
printf 'x' > "${TMP}/gate/offline-files/a.txt"
(
  cd "${TMP}/gate/offline-files"
  sha256sum ./a.txt > SHA256SUMS
  "$(command -v sha256sum)" -c SHA256SUMS >/dev/null
)
rc=0
CLUSTER_CONF="${TMP}/cluster.conf" OFFLINE_FILES_ROOT="${TMP}/gate/offline-files" \
    OFFLINE_VERIFY_MODE=full bash -c 'source "$1"; load_config; verify_offline_gate' _ "${LIB}" >/dev/null 2>&1 || rc=$?
chk "sealed-dev full 通过" "0" "${rc}"
printf 'y' > "${TMP}/gate/offline-files/a.txt"
rc=0
CLUSTER_CONF="${TMP}/cluster.conf" OFFLINE_FILES_ROOT="${TMP}/gate/offline-files" \
    OFFLINE_VERIFY_MODE=full bash -c 'source "$1"; load_config; verify_offline_gate' _ "${LIB}" >/dev/null 2>&1 || rc=$?
chk "坏字节门禁失败" "1" "${rc}"
```

- [ ] **Step 2: 运行确认失败**

Expected: `load_config` 不校验 release.env；`verify_offline_gate` 不存在。

- [ ] **Step 3: 实现 `lib-common.sh`**

在文件顶部 source 自举库（`REPO_ROOT` 定义之后）：

```bash
# shellcheck source=tools/offline/lib-offline-verify.sh
source "${REPO_ROOT}/deployments/scripts/tools/offline/lib-offline-verify.sh"
```

注意 `REPO_ROOT` 在 lib-common 中的定义位置；若在 source 之前不可用，改为在 `load_config` 内懒加载或使用绝对路径推导。

新增函数：

```bash
# release.env 被 root source 之前的最小校验(存在 SHA256SUMS 时强制)
verify_release_env_precheck() {
    local root="$1" sums="${1}/SHA256SUMS" envf="${1}/release.env" want got
    [ -f "${envf}" ] || return 0
    if [ ! -f "${sums}" ]; then
        warn "未找到 ${sums}, 跳过 release.env 预校验(建议 seal)"
        return 0
    fi
    want="$(awk -v p="./release.env" '$2==p {print $1}' "${sums}" | head -1)"
    [ -n "${want}" ] || want="$(awk -v p="release.env" '$2==p {print $1}' "${sums}" | head -1)"
    if [ -z "${want}" ]; then
        err "release.env 未登记在 ${sums}; 拒绝 source(发布树不完整或已被修改)"
        return 1
    fi
    got="$(sha256sum "${envf}" | awk '{print $1}')"
    if [ "${want}" != "${got}" ]; then
        err "release.env 校验失败: 期望 ${want} 实际 ${got}; 拒绝 source(文件损坏或被修改)"
        return 1
    fi
    if [ -f "${1}/_SUCCESS" ]; then
        local ssum
        ssum="$(awk -F= '$1=="sha256sums"{print $2}' "${1}/_SUCCESS" | tr -d '[:space:]')"
        if [ -n "${ssum}" ]; then
            local asum
            asum="$(sha256sum "${sums}" | awk '{print $1}')"
            if [ "${ssum}" != "${asum}" ]; then
                err "_SUCCESS.sha256sums 与 SHA256SUMS 不符(期望 ${ssum} 实际 ${asum})"
                return 1
            fi
        fi
    fi
    return 0
}

# 安装前完整性门禁
verify_offline_gate() {
    local mode="${OFFLINE_VERIFY_MODE:-auto}" root="${OFFLINE_FILES_ROOT:-}"
    local tool rc level layout
    case "${mode}" in off) warn "已跳过离线文件完整性校验(OFFLINE_VERIFY_MODE=off)"; return 0 ;; esac
    [ -n "${root}" ] && [ -d "${root}" ] || { err "离线目录不存在: ${root}"; return 1; }
    if ! tool="$(ensure_offline_verify_tool)"; then
        if [ -n "${CUBESTACK_RELEASE:-}" ] || [ -f "${root}/SHA256SUMS" ]; then
            err "校验器不可用(镜像/发布树/在线安装均失败); 请用 cubestack-cli 镜像或手工拷贝 verify-offline-files.sh"
            return 1
        fi
        warn "校验器不可用; 未 seal 的开发树跳过完整性校验"
        return 0
    fi
    level="${mode}"
    [ "${level}" = "auto" ] || true
    local -a args=(--root "${root}" --level "${level}" --jobs "${OFFLINE_VERIFY_JOBS:-4}")
    if [ -n "${CUBESTACK_RELEASE:-}" ]; then
        args+=(--release "${CUBESTACK_RELEASE}")
        if [ "${CUBESTACK_RELEASE_LAYOUT:-}" = "flat" ]; then
            args+=(--layout flat)
        else
            args+=(--layout release)
            if [ -n "${CUBESTACK_RELEASE_ROOT:-}" ]; then
                args+=(--cli-tar "${CUBESTACK_RELEASE_ROOT}/${CUBESTACK_RELEASE}/cubestack-installer-cli-v${CUBESTACK_RELEASE}.tar")
            fi
        fi
    elif [ ! -f "${root}/SHA256SUMS" ]; then
        args+=(--allow-unsealed)
    fi
    [ "${OFFLINE_VERIFY_STAMP:-true}" = "true" ] || args+=(--no-stamp)
    bash "${tool}" "${args[@]}"
    rc=$?
    if [ "${rc}" = "0" ]; then return 0; fi
    if [ "${rc}" = "2" ]; then
        err "校验器环境错误(退出码 2); 详见上方输出"
        return 1
    fi
    if [ ! -f "${root}/SHA256SUMS" ] && [ "${OFFLINE_VERIFY_STRICT_DEV:-true}" != "true" ]; then
        warn "未 seal 的开发树检出损坏, 但 OFFLINE_VERIFY_STRICT_DEV=false → 仅警告"
        return 0
    fi
    return 1
}
```

在 `load_config` 的 `source "${_rel_root}/release.env"` 之前插入：

```bash
        # 损坏的 release.env 不允许被 root 执行(存在 SHA256SUMS 时强制)
        if ! verify_release_env_precheck "${_rel_root}"; then
            exit 1
        fi
```

- [ ] **Step 4: 实现 `deploy-cluster.sh`**

参数解析新增：

```bash
VERIFY_OFFLINE_ARG=""
NO_VERIFY_OFFLINE=0
...
        --verify-offline) VERIFY_OFFLINE_ARG="auto"; shift ;;
        --verify-offline=*) VERIFY_OFFLINE_ARG="${1#*=}"; shift ;;
        --no-verify-offline) NO_VERIFY_OFFLINE=1; shift ;;
```

在 `load_config` 之后、`check_offline_files` 之前：

```bash
# 离线文件完整性门禁(可在 list/verify-only/仅写配置时跳过)
_verify_should_skip() {
    [ "${LIST_STEPS}" = "1" ] || [ "${LIST}" = "1" ] && return 0
    [ "${NO_VERIFY_OFFLINE}" = "1" ] && return 0
    if [ -n "${ENABLE_PERSIST_ARG}" ] && [ -z "${STEPS_ARG}" ] && [ -z "${ENABLE_ARG}" ] \
       && [ -z "${SKIP_ARG}" ] && [ -z "${PHASE_ARG}" ] && [ -z "${ONLY_HOSTS}" ]; then
        return 0
    fi
    local s all_verify=1 all_pre=1
    for s in ${STEPS_ARG//,/ }; do
        [ -z "${s}" ] && continue
        case "${s}" in verify_*) ;; *) all_verify=0 ;; esac
        case " ${PRE_CLUSTER_STEPS} " in *" ${s} "*) ;; *) all_pre=0 ;; esac
    done
    [ -n "${STEPS_ARG}" ] && { [ "${all_verify}" = "1" ] || [ "${all_pre}" = "1" ]; } && return 0
    return 1
}
if ! _verify_should_skip; then
    if [ "${NO_VERIFY_OFFLINE}" = "1" ]; then
        OFFLINE_VERIFY_MODE="off"
    elif [ -n "${VERIFY_OFFLINE_ARG}" ]; then
        OFFLINE_VERIFY_MODE="${VERIFY_OFFLINE_ARG}"
    fi
    if ! verify_offline_gate; then
        err "离线文件完整性校验未通过, 已停止部署(逃生口: --no-verify-offline)"
        exit 1
    fi
fi
```

注意 `PRE_CLUSTER_STEPS` 在 `deploy-cluster.sh:447` 才定义；门禁在 `:261`，需把 `PRE_CLUSTER_STEPS` 定义上移到门禁之前，或把跳过逻辑简化为“全部步骤以 `verify_` 开头”。为避免移动大段代码，P0 先只跳过 `verify_*` 与 `--enable`；pre-cluster 步骤照常校验（更安全）。计划采用简化版：

```bash
    local s all_verify=1
    for s in ${STEPS_ARG//,/ }; do
        [ -z "${s}" ] && continue
        case "${s}" in verify_*) ;; *) all_verify=0 ;; esac
    done
    [ -n "${STEPS_ARG}" ] && [ "${all_verify}" = "1" ] && return 0
```

- [ ] **Step 5: 配置默认值**

`cluster.defaults.conf` 追加：

```bash
# ---------------- 离线文件完整性校验(2026-10-28) ----------------
# auto = release/flat/sealed 首次 full, 之后走校验戳; 未 seal 的开发树只做 quick
# off|quick|full 可强制; CLI: --verify-offline[=...] / --no-verify-offline
OFFLINE_VERIFY_MODE="${OFFLINE_VERIFY_MODE:-auto}"
OFFLINE_VERIFY_JOBS="${OFFLINE_VERIFY_JOBS:-4}"
OFFLINE_VERIFY_STAMP="${OFFLINE_VERIFY_STAMP:-true}"
OFFLINE_VERIFY_STRICT_DEV="${OFFLINE_VERIFY_STRICT_DEV:-true}"
OFFLINE_VERIFY_ONLINE_INSTALL="${OFFLINE_VERIFY_ONLINE_INSTALL:-auto}"
OFFLINE_VERIFY_TOOL_URL="${OFFLINE_VERIFY_TOOL_URL:-https://raw.githubusercontent.com/suanova/cubestack-installer/main/deployments/scripts/tools/offline/verify-offline-files.sh}"
```

`cluster.conf.example` 增加同样注释块（可只保留 `OFFLINE_VERIFY_MODE` 一行）。

- [ ] **Step 6: 运行测试**

Run:
```bash
bash -n deployments/scripts/lib-common.sh
bash -n deployments/scripts/deploy-cluster.sh
bash deployments/scripts/tools/tests/test-release-mode.sh
```
Expected: 全部通过；新增 ⑦/⑧ 通过。

- [ ] **Step 7: 提交**

```bash
git add deployments/scripts/lib-common.sh deployments/scripts/deploy-cluster.sh \
  deployments/config/cluster.defaults.conf deployments/config/cluster.conf.example \
  deployments/scripts/tools/tests/test-release-mode.sh
git commit -m "feat(offline): gate deployments on offline-files integrity"
```

---

### Task 8: fetch 集成 + `--repair`

**Files:**
- Modify: `deployments/scripts/tools/offline/fetch-offline-from-minio.sh`
- Modify: `deployments/scripts/tools/tests/test-release-mode.sh`

**Interfaces:**
- Consumes: `ensure_offline_verify_tool`、`verify-offline-files.sh --json`
- Produces: 退出码 1 的失败列表；`--repair` 只重下坏文件

- [ ] **Step 1: 写失败测试（追加到 test-release-mode.sh）**

```bash
echo "== ⑨ fetch 调用校验器并点名坏文件 =="
# 复用 ③ 的假 release 树; 篡改一个文件后 --verify-only 必须失败并点名
printf 'corrupt' > "${TMP}/local/2.0.0/offline-files/ceph/test.txt"
out="$(bash "${FETCH}" --release 2.0.0 --verify-only --dest "${TMP}/local" 2>&1 || true)"
chk_contains "点名坏文件" "ceph/test.txt" "${out}"
chk_contains "提示 repair" "--repair" "${out}"
```

（如果 ③ 的 fixture 名称不同，按实际 fixture 调整；实现时先读测试前半段。）

- [ ] **Step 2: 运行确认失败**

Expected: 当前 fetch 只报“SHA256SUMS 校验失败”，不点名文件/不提示 repair。

- [ ] **Step 3: 实现**

在 fetch 顶部 source 自举库：

```bash
# shellcheck source=lib-offline-verify.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-offline-verify.sh"
```

参数解析加 `--repair`：

```bash
REPAIR=0
...
        --repair) REPAIR=1; shift ;;
...
[ "${REPAIR}" = "1" ] && [ -z "${RELEASE_ARG}" ] && { err "--repair 需要配合 --release <版本>"; exit 1; }
[ "${REPAIR}" = "1" ] && [ "${NO_VERIFY}" = "1" ] && { err "--repair 与 --no-verify 互斥"; exit 1; }
```

替换 `_verify_release` 为工具调用：

```bash
_verify_release() {
    local root="${DST_ROOT}" base="${DST_ROOT}/offline-files" _vt _json _rc
    [ "${FLAT}" = "1" ] && base="${DST_ROOT}"
    _vt="$(ensure_offline_verify_tool)" || {
        err "校验器不可用; 无法校验发布树"
        return 1
    }
    _json="$(mktemp)"
    local -a args=(--root "${base}" --release "${RELEASE_ARG}" --level full --json)
    if [ "${FLAT}" = "1" ]; then
        args+=(--layout flat)
    else
        args+=(--layout release --cli-tar "${root}/cubestack-installer-cli-v${RELEASE_ARG}.tar" --require-cli-tar)
    fi
    bash "${_vt}" "${args[@]}" > "${_json}" 2>/dev/null
    _rc=$?
    if [ "${_rc}" = "0" ]; then
        rm -f "${_json}"
        ok "发布版本 ${RELEASE_ARG} 校验通过"
        return 0
    fi
    python3 - "${_json}" <<'PY' >&2 || true
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("❌ 校验失败(无法解析校验器输出)", file=sys.stderr); raise SystemExit
fails = d.get("failures") or []
print(f"❌ 校验失败: {len(fails)} 个文件", file=sys.stderr)
for f in fails[:20]:
    print(f"  {f.get('path')}: {f.get('message','')}", file=sys.stderr)
print("修复: 加 --repair 只重下坏文件, 或从发布源重新拷贝", file=sys.stderr)
for f in fails:
    print(f.get("path",""))
PY
    if [ "${REPAIR}" = "1" ]; then
        _repair_from_json "${_json}" || { rm -f "${_json}"; return 1; }
        rm -f "${_json}"
        _verify_release   # 修复后重验一次
        return $?
    fi
    rm -f "${_json}"
    return 1
}
```

`_repair_from_json`：

```bash
_repair_from_json() {
    local json="$1" ts q root="${DST_ROOT}"
    local -a bad=()
    mapfile -t bad < <(python3 - "${json}" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit
for f in d.get("failures") or []:
    p = f.get("path")
    if p and p not in ("SHA256SUMS", "_SUCCESS", "SIZES"):
        print(p)
PY
)
    [ "${#bad[@]}" -gt 0 ] || return 1
    ts="$(date +%Y%m%d-%H%M%S)"
    q="${TARGET}/.repair-quarantine/${RELEASE_ARG}/${ts}"
    mkdir -p "${q}" || q="${TMPDIR:-/var/tmp}/cubestack-repair/${RELEASE_ARG}/${ts}"
    local p rel
    for p in "${bad[@]}"; do
        rel="${p#./}"
        if [ "${FLAT}" = "1" ]; then
            [ -f "${root}/${rel}" ] && mkdir -p "${q}/$(dirname "${rel}")" && mv -f "${root}/${rel}" "${q}/${rel}" || true
            say "重新下载 ${rel} ..."
            mc cp --overwrite "${SRC_ROOT}/${rel}" "${root}/${rel}" || { err "重新下载失败: ${rel}"; return 1; }
        else
            [ -f "${root}/offline-files/${rel}" ] && mkdir -p "${q}/$(dirname "${rel}")" && mv -f "${root}/offline-files/${rel}" "${q}/${rel}" || true
            say "重新下载 ${rel} ..."
            mc cp --overwrite "${SRC_ROOT}/offline-files/${rel}" "${root}/offline-files/${rel}" || { err "重新下载失败: ${rel}"; return 1; }
        fi
    done
    return 0
}
```

- [ ] **Step 4: 更新帮助文本**

`_print_help` 增加 `--repair` 和“失败点名/校验戳”说明。

- [ ] **Step 5: 运行测试**

Run:
```bash
bash -n deployments/scripts/tools/offline/fetch-offline-from-minio.sh
bash deployments/scripts/tools/tests/test-release-mode.sh
```
Expected: 新增 ⑨ 通过；原有测试不回归。

- [ ] **Step 6: 提交**

```bash
git add deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
  deployments/scripts/tools/tests/test-release-mode.sh
git commit -m "feat(offline): verify fetched trees with verifier and add --repair"
```

---

### Task 9: `cubestack-offline.sh` 集成

**Files:**
- Modify: `deployments/kubespray/cubestack-offline.sh`
- Create/Modify: `deployments/scripts/tools/tests/test-offline-tree-check.sh`（新增小回归）

**Interfaces:**
- Consumes: `lib-offline-verify.sh`、`verify-offline-files.sh`
- Produces: `ensure_kubespray` 解包前校验 `tree.tar.gz.sha256`；`cmd_check` 调用工具

- [ ] **Step 1: 写失败测试**

```bash
#!/bin/bash
# test-offline-tree-check.sh — tree.tar.gz 边车校验的最小回归
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
OFFLINE="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

mkdir -p "${TMP}/kubespray/v9.9.9/images"
printf 'x' > "${TMP}/kubespray/v9.9.9/images/a.tar"
tar -C "${TMP}" -czf "${TMP}/kubespray/v9.9.9/tree.tar.gz" kubespray
printf '%s\n' "$(sha256sum "${TMP}/kubespray/v9.9.9/tree.tar.gz" | awk '{print $1}')" \
  > "${TMP}/kubespray/v9.9.9/tree.tar.gz.sha256"

rc=0
OFFLINE_FILES_ROOT="${TMP}" OFFLINE_FILES_DIR="${TMP}/kubespray/v9.9.9" \
  KUBESPRAY_VERSION=v9.9.9 CUBESTACK_LAYOUT=flat \
  bash -c 'source "$1"; verify_tree_tar_sidecar "${OFFLINE_FILES_DIR}"' _ "${OFFLINE}" >/dev/null 2>&1 || rc=$?
chk "边车一致通过" "0" "${rc}"
printf 'deadbeef\n' > "${TMP}/kubespray/v9.9.9/tree.tar.gz.sha256"
rc=0
OFFLINE_FILES_ROOT="${TMP}" OFFLINE_FILES_DIR="${TMP}/kubespray/v9.9.9" \
  KUBESPRAY_VERSION=v9.9.9 CUBESTACK_LAYOUT=flat \
  bash -c 'source "$1"; verify_tree_tar_sidecar "${OFFLINE_FILES_DIR}"' _ "${OFFLINE}" >/dev/null 2>&1 || rc=$?
chk "边车不符失败" "1" "${rc}"

echo "---------------------------------------------"
[ "${fail}" = "0" ] && { echo "✅ tree.tar.gz 边车回归通过"; exit 0; } || { echo "❌ 回归失败"; exit 1; }
```

- [ ] **Step 2: 运行确认失败**

Expected: `verify_tree_tar_sidecar` 不存在。

- [ ] **Step 3: 实现**

在 `ensure_kubespray` 之前新增：

```bash
# tree.tar.gz 解包前校验边车(存在即强制)
verify_tree_tar_sidecar() {
    local dir="$1" tar="${1}/tree.tar.gz" side="${1}/tree.tar.gz.sha256" want got
    [ -f "${tar}" ] || return 0
    if [ ! -f "${side}" ]; then
        warn "缺少 ${side}; 跳过 tree.tar.gz 校验(开发树常见)"
        return 0
    fi
    want="$(tr -d '[:space:]' < "${side}")"
    got="$(sha256sum "${tar}" | awk '{print $1}')"
    if [ "${want}" != "${got}" ]; then
        err "tree.tar.gz 校验失败: 期望 ${want} 实际 ${got}"
        return 1
    fi
    log "✅ tree.tar.gz 校验通过"
    return 0
}
```

在 `ensure_kubespray` 的 `tar -xzf "${_tree_tar}"` 之前加：

```bash
        verify_tree_tar_sidecar "$(dirname "${_tree_tar}")" || return 1
```

`cmd_check` 末尾加：

```bash
    # 离线文件完整性门禁(有清单时 auto: 戳/全量; 无清单 quick)
    local _vt_lib="${SCRIPT_DIR}/../scripts/tools/offline/lib-offline-verify.sh"
    local _vt=""
    if [ -f "${_vt_lib}" ]; then
        # shellcheck disable=SC1090
        source "${_vt_lib}"
        _vt="$(ensure_offline_verify_tool)" || _vt=""
    fi
    if [ -n "${_vt}" ]; then
        if [ -f "${OFFLINE_FILES_ROOT}/SHA256SUMS" ]; then
            bash "${_vt}" --root "${OFFLINE_FILES_ROOT}" --level auto --jobs "${OFFLINE_VERIFY_JOBS:-4}" \
                || { err "离线文件完整性校验失败"; return 1; }
        else
            bash "${_vt}" --root "${OFFLINE_FILES_ROOT}" --level quick --allow-unsealed \
                || { err "离线文件结构检查失败"; return 1; }
        fi
    else
        warn "校验器不可用; 跳过离线文件完整性校验"
    fi
```

注意 `cmd_check` 里 `return 1` 只在函数内；`cmd_install` 调用 `cmd_check` 后是否检查返回值？它目前不检查；`set -e` 下 `cmd_check` 返回 1 会终止脚本（函数调用非条件上下文）。确认 `cmd_install` 里 `cmd_check` 是裸调用，`set -e` 生效。

- [ ] **Step 4: 运行测试**

Run:
```bash
bash -n deployments/kubespray/cubestack-offline.sh
bash deployments/scripts/tools/tests/test-offline-tree-check.sh
```
Expected: 通过。

- [ ] **Step 5: 提交**

```bash
chmod +x deployments/scripts/tools/tests/test-offline-tree-check.sh
git add deployments/kubespray/cubestack-offline.sh \
  deployments/scripts/tools/tests/test-offline-tree-check.sh
git commit -m "feat(kubespray): verify tree.tar.gz and offline tree before install"
```

---

### Task 10: 工具交付（镜像/发布树/pin/CI）

**Files:**
- Modify: `Dockerfile-cli`
- Modify: `deployments/scripts/tools/docker/build-cli-context.sh`
- Modify: `deployments/scripts/tools/check-modules.sh`
- Modify: `deployments/scripts/tools/images/release-publish.sh`
- Create: `deployments/config/verify-tool.sha256`
- Modify: `.github/workflows/ci-validate.yml`

**Interfaces:**
- Produces: CLI 镜像内 `/usr/local/bin/cubestack-verify-offline`
- Produces: 发布树 `offline-files/tools/verify-offline-files.sh`
- Produces: pin 文件与 CI 一致性门禁

- [ ] **Step 1: Dockerfile-cli**

在 `COPY deployments` 后追加：

```dockerfile
# 离线文件完整性校验器(2026-10-28): 必须随镜像分发; 缺失/不可执行直接构建失败
RUN test -x ${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh \
 && ${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh --version \
 && ln -sf ${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh \
           /usr/local/bin/cubestack-verify-offline
```

- [ ] **Step 2: build-cli-context.sh**

在配置模板校验后追加：

```bash
[ -x "${OUT}/deployments/scripts/tools/offline/verify-offline-files.sh" ] \
    || { err "构建上下文缺可执行校验器: deployments/scripts/tools/offline/verify-offline-files.sh"; exit 1; }
ok "  校验器就位: deployments/scripts/tools/offline/verify-offline-files.sh"
```

- [ ] **Step 3: check-modules.sh**

在最终汇总前追加（不计入 19 项编号）：

```bash
# ---------- 校验器存在性/pin 一致性(2026-10-28) ----------
say "校验器 verify-offline-files.sh + pin ..."
_VT="${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh"
_VT_PIN="${REPO_ROOT}/deployments/config/verify-tool.sha256"
if [ ! -x "${_VT}" ]; then
    ck_fail "校验器缺失或不可执行: ${_VT}"; FAIL=$((FAIL+1))
elif [ ! -f "${_VT_PIN}" ]; then
    ck_fail "缺少 pin 文件: ${_VT_PIN}"; FAIL=$((FAIL+1))
else
    _vt_actual="$(sha256sum "${_VT}" | awk '{print $1}')"
    _vt_want="$(tr -d '[:space:]' < "${_VT_PIN}")"
    if [ "${_vt_actual}" != "${_vt_want}" ]; then
        ck_fail "校验器 pin 不一致: 实际 ${_vt_actual} != pin ${_vt_want}(改工具后更新 ${_VT_PIN})"; FAIL=$((FAIL+1))
    else
        ok "  校验器 pin 一致"
    fi
fi
```

注意 `REPO_ROOT`/`ck_fail`/`FAIL` 变量在该脚本中已定义；若未定义，用 `SCRIPT_DIR` 推导。

- [ ] **Step 4: release-publish.sh**

新增函数并调用：

```bash
_copy_verify_tool() {
    local src="${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh"
    [ -x "${src}" ] || { err "缺少校验器: ${src}"; exit 1; }
    mkdir -p "${STAGE_TREE}/tools"
    cp -f "${src}" "${STAGE_TREE}/tools/verify-offline-files.sh"
    chmod 0755 "${STAGE_TREE}/tools/verify-offline-files.sh"
}
```

在 `_stage` 的 `[4/7]` 段末尾调用 `_copy_verify_tool`（确保在 `_write_sha256sums` 之前）。同时把 `_write_sha256sums` 改为：

```bash
_write_sha256sums() {
    say "生成 SHA256SUMS..."
    ( cd "${STAGE_TREE}" && find . -type f \
        ! -name SHA256SUMS ! -name SIZES ! -name _SUCCESS ! -name '.cubestack-*' -print0 \
        | sort -z | xargs -0 sha256sum ) > "${STAGE_TREE}/SHA256SUMS"
}
```

- [ ] **Step 5: pin 文件**

工具最终形态确定后生成：

```bash
sha256sum deployments/scripts/tools/offline/verify-offline-files.sh \
  | awk '{print $1}' > deployments/config/verify-tool.sha256
```

- [ ] **Step 6: CI**

`ci-validate.yml` 增加：

```yaml
      - name: 校验器自举回归
        run: |
          set -euo pipefail
          bash deployments/scripts/tools/tests/test-verify-tool-install.sh
      - name: tree.tar.gz 边车回归
        run: |
          set -euo pipefail
          bash deployments/scripts/tools/tests/test-offline-tree-check.sh
```

- [ ] **Step 7: 运行检查**

Run:
```bash
bash -n deployments/scripts/tools/check-modules.sh
bash -n deployments/scripts/tools/images/release-publish.sh
sha256sum deployments/scripts/tools/offline/verify-offline-files.sh | awk '{print $1}' > deployments/config/verify-tool.sha256
bash deployments/scripts/tools/check-modules.sh
```
Expected: 校验器 pin 一致；全部通过。

- [ ] **Step 8: 提交**

```bash
git add Dockerfile-cli deployments/scripts/tools/docker/build-cli-context.sh \
  deployments/scripts/tools/check-modules.sh deployments/scripts/tools/images/release-publish.sh \
  deployments/config/verify-tool.sha256 .github/workflows/ci-validate.yml
git commit -m "feat(offline): ship verifier in CLI image and release tree with pin"
```

---

### Task 11: 文档 + 全量回归

**Files:**
- Create: `docs/offline-files-integrity.md`
- Modify: `docs/release-management.md`
- Modify: `deployments/scripts/tools/offline/fetch-offline-from-minio.sh`（帮助文本）
- Modify: `deployments/scripts/deploy-cluster.sh`（usage）

**Interfaces:**
- 文档必须覆盖：四布局、quick/full/auto、seal、校验戳局限、门禁/逃生口、fetch/repair、工具自举/在线安装、故障排查。

- [ ] **Step 1: 写文档**

`docs/offline-files-integrity.md` 至少包含：

```markdown
# offline-files 完整性校验

## 快速开始
# 下载后(自动 full + 写戳)
./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --release 2.0.0 --dest /data/cubestack-installer

# 只校验
./deployments/scripts/tools/offline/verify-offline-files.sh \
    --root /data/cubestack-installer/2.0.0/offline-files --release 2.0.0 --level full

# 开发树 seal
sudo ./deployments/scripts/tools/offline/verify-offline-files.sh --root deployments/offline-files --seal

# 部署(默认 auto: 首次 full, 之后走戳)
sudo ./deployments/scripts/deploy-cluster.sh
sudo ./deployments/scripts/deploy-cluster.sh --verify-offline=full   # 强制全量
sudo ./deployments/scripts/deploy-cluster.sh --no-verify-offline     # 逃生口

## 校验级别
| 级别 | 做什么 | 耗时 |
...

## 校验戳
...

## 工具自举
...

## 故障排查
| 症状 | 命令 |
...
```

`docs/release-management.md` 更新 §3.3（`_SUCCESS.sha256sums` 绑定）、§5.3（fetch 使用工具/repair/戳）、§6（发布树自带 `tools/verify-offline-files.sh`）。

- [ ] **Step 2: 更新帮助文本**

`fetch --help` 增加 `--repair`；`deploy-cluster --help` 增加 `--verify-offline[=auto|quick|full]` / `--no-verify-offline`。

- [ ] **Step 3: 全量回归**

Run:
```bash
bash -n $(git ls-files '*.sh' | tr '\n' ' ')   # 或使用仓库现有 CI 步骤
bash deployments/scripts/tools/tests/test-verify-offline-files.sh
bash deployments/scripts/tools/tests/test-verify-tool-install.sh
bash deployments/scripts/tools/tests/test-offline-tree-check.sh
bash deployments/scripts/tools/tests/test-release-mode.sh
bash deployments/scripts/tools/tests/test-release-sync-images.sh
bash deployments/scripts/tools/check-modules.sh
bash deployments/scripts/tools/check-manifests.sh
bash deployments/scripts/tools/images/check-image-manifest.sh --kubespray
```
Expected: 全绿。

- [ ] **Step 4: 提交**

```bash
git add docs/offline-files-integrity.md docs/release-management.md \
  deployments/scripts/tools/offline/fetch-offline-from-minio.sh \
  deployments/scripts/deploy-cluster.sh
git commit -m "docs(offline): document integrity verification and repair workflow"
```

---

## Self-Review

**1. Spec coverage:**
- 独立工具/四布局/quick/full/auto → Task 1-5。
- seal → Task 5。
- 校验戳 → Task 4。
- 工具交付（镜像/发布树/在线 3 次/pin）→ Task 6、10。
- 门禁 + `load_config` 预检查 → Task 7。
- fetch `_SUCCESS` 绑定/覆盖/`--repair`/戳 → Task 8（绑定/覆盖由工具实现）。
- `tree.tar.gz` + `cmd_check` → Task 9。
- 测试/CI/文档 → Task 1、6、9、10、11。
- P1 项（SIZES 发布侧/provenance/sync seal/download 原子化/签名）明确不在本计划。

**2. Placeholder scan:** 无 TBD/TODO；所有任务都有测试命令、代码骨架、提交命令。

**3. Type consistency:**
- `ensure_offline_verify_tool` 在 Task 6 定义，Task 7/8/9 调用一致。
- `verify_offline_gate` 在 Task 7 定义，`deploy-cluster.sh` 调用一致。
- 工具 CLI 参数在 Task 1 定义，后续任务使用一致（`--root/--release/--layout/--level/--json/--seal/--stamp-file/--no-stamp/--force-full/--allow-unsealed/--staging/--require-success/--require-cli-tar/--jobs`）。
- 失败 kind 在 Task 2/3/4 定义，Task 8 的 JSON 解析按 `path/message` 读取，不依赖 kind 枚举。

**已知实现注意点（执行时确认）：**
- `lib-common.sh` 的 `REPO_ROOT` 定义位置若晚于 source 行，需把 source 放到定义之后或在函数内懒加载。
- `find_cli_tar` 的 `MISSING:` 分支在实现时统一为返回 `None` + `--require-cli-tar` 判断，避免字符串路径误判。
- `verify_release_env_precheck` 在 flat 布局 `_rel_root` 可能是仓库内 release 定义（无 SHA256SUMS）→ 走 warning 分支，不阻断。
- `deploy-cluster.sh` 的 `_verify_should_skip` 在 P0 只跳过 `verify_*` 与 `--enable` 单写；pre-cluster 步骤仍校验（更安全）。
- `cubestack-offline.sh` 不 source lib-common；只 source `lib-offline-verify.sh`，避免引入集群依赖。
