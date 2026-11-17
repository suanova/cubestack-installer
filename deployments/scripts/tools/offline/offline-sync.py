#!/usr/bin/env python3
"""offline-sync.py — 把 cubestack-release 的 CI store 镜像到 MinIO，
并从该布局物化本地离线安装文件（snapshot / release 均可）。

设计见 docs/superpowers/specs/2026-11-17-offline-latest-layout-design.md。

MinIO 布局（单一，与 cubestack-release/base 对齐）:
    s3://cubestack-installer/<target>/
      base/<base-version>/
      artifacts/{images,charts,cli,files,bundles,modules}/sha256/...
      vendor/...
      snapshots/<name>/  或 releases/<version>/
      streams/<line>-snapshot.yaml
      STORE-SOURCE.yaml

本地物化:
    <local-root>/                     # 默认 /data/offline-files
      release.* tree.tsv SHA256SUMS _SUCCESS base/
      kubespray/... <组件>/...

用法:
    offline-sync.py plan  [options]      # 只读计划（默认）
    offline-sync.py apply --yes [options]
    offline-sync.py store [--yes] [options]
                                        # 把 CI store 布局（base/artifacts/
                                        # vendor/snapshots|releases/streams）
                                        # 服务端镜像到 MinIO；默认只读计划

    --store <mc-path>       默认 minio/cubestack-test/validation（store 命令源）
    --store-dst <mc-path>   store 命令目标，默认
                            minio/cubestack-installer/latest
    --with-payloads         store 时同时复制 artifacts/payloads（+10G）
    --skip-vendor           store 时不复制 vendor/
    --stream <name>         默认 2.1-snapshot；可用 2.1-snapshot/2.1-latest/2.1-stable
    --snapshot <target>     直接指定 snapshots/<...>，跳过 stream
    --release <version>     直接指定 releases/<version>，跳过 stream
                            （如 --release 2.1.0）
    --materialize-from <mc-path>
                            plan/apply 读取的 CI store 布局，默认
                            minio/cubestack-installer/latest
    --local-root <dir>      默认 /data/offline-files
    --with-install-tree     同时物化 modules/ 与 cubestack-installer-cli.tar
                            到 dirname(local-root)（release 模式发现用）
    --work-dir <dir>        extract 中转目录（默认 /var/tmp/cubestack-latest）
    --json                  计划输出 JSON
    --force-upload          store 时忽略远端同尺寸对象，强制重传
    --skip-local            apply 只做 MinIO 校验/不写本地
    --verify                本地更新后运行 verify-offline-files.sh（quick）
    --yes                   apply/store 必须显式确认

退出码: 0 成功; 1 执行失败; 2 参数/输入错误。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_STORE = "minio/cubestack-test/validation"
DEFAULT_TARGET = "minio/cubestack-installer/latest"
DEFAULT_LOCAL = "/data/offline-files"
DEFAULT_WORK = "/var/tmp/cubestack-latest"
PROFILE_DIR = REPO_ROOT / "deployments/config/profiles"
VERIFIER = REPO_ROOT / "deployments/scripts/tools/offline/verify-offline-files.sh"


# ---------------------------------------------------------------- helpers

def die(msg: str, code: int = 1) -> None:
    print(f"\033[31m【错误】{msg}\033[0m", file=sys.stderr)
    raise SystemExit(code)


def say(msg: str) -> None:
    print(f"\033[36m→  {msg}\033[0m")


def ok(msg: str) -> None:
    print(f"\033[32m✅ {msg}\033[0m")


def warn(msg: str) -> None:
    print(f"\033[33m⚠  {msg}\033[0m", file=sys.stderr)


def sha_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def mc_run(args: list[str], input_bytes: bytes | None = None,
           check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(["mc", *args], input=input_bytes,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and proc.returncode != 0:
        tail = proc.stderr.decode("utf-8", "replace").strip()[-800:]
        die(f"mc {' '.join(args)} 失败: {tail}")
    return proc


def mc_cat(path: str) -> bytes:
    return mc_run(["cat", path]).stdout


def mc_exists(path: str) -> bool:
    return mc_run(["stat", "--json", path], check=False).returncode == 0


def mc_size(path: str) -> int | None:
    proc = mc_run(["stat", "--json", path], check=False)
    if proc.returncode != 0:
        return None
    try:
        return int(json.loads(proc.stdout.decode().strip().splitlines()[0])["size"])
    except (ValueError, KeyError, IndexError):
        return None


def mc_cp(src: str, dst: str) -> None:
    mc_run(["cp", "--quiet", src, dst])


def bucket_prefix(path: str) -> str:
    """mc 路径 `<alias>/<bucket>/<prefix>` → `<prefix>`；桶根返回空串。"""
    parts = path.split("/", 2)
    return parts[2].strip("/") if len(parts) > 2 else ""


def mc_ls(prefix: str) -> dict[str, int]:
    """返回 {桶内相对 key: size}。

    注意: `mc ls --recursive --json <prefix>` 的 `key` 是**相对 prefix**
    的，不是桶根；这里统一补回 prefix，避免调用方按桶根比较时错位。
    """
    proc = mc_run(["ls", "--recursive", "--json", prefix], check=False)
    rel = bucket_prefix(prefix)
    out: dict[str, int] = {}
    for line in proc.stdout.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if item.get("type") not in ("file", "folder"):
            continue
        key = item.get("key")
        if not key:
            continue
        full = f"{rel}/{key}" if rel else key
        try:
            out[full] = int(item.get("size") or 0)
        except ValueError:
            out[full] = 0
    return out


def mc_rm(path: str) -> None:
    mc_run(["rm", "--quiet", path])


def minio_free_bytes(alias: str = "minio") -> int | None:
    proc = mc_run(["admin", "info", alias], check=False)
    text = proc.stdout.decode("utf-8", "replace")
    for line in text.splitlines():
        if "Free:" in line:
            parts = line.replace("│", " ").split()
            for i, token in enumerate(parts):
                if token == "Free:" and i + 1 < len(parts):
                    return _parse_size(" ".join(parts[i + 1:i + 3]))
    return None


def _parse_size(text: str) -> int | None:
    text = text.strip()
    units = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3, "TiB": 1024**4}
    for unit in sorted(units, key=len, reverse=True):
        if text.endswith(unit):
            try:
                return int(float(text[: -len(unit)].strip()) * units[unit])
            except ValueError:
                return None
    return None


def gib(n: int) -> str:
    return f"{n / 1024**3:.2f} GiB"


# ---------------------------------------------------------------- context

@dataclass
class Row:
    path: str
    artifact: str
    extract: bool
    mode: str
    size: int
    sha: str
    group: str = ""
    package: str = ""


@dataclass
class Entry:
    digest: str
    size: int
    kind: str                  # artifact | staged | bytes
    ref: object = None         # artifact: store path; staged: Path; bytes: bytes
    stage: str = "blob"        # blob | metadata | success
    mode: str = "0644"


@dataclass
class Context:
    store: str
    target: str
    local_root: Path
    work_dir: Path
    snapshot_prefix: str
    source_target: str
    stream_file: str | None
    stream_doc: dict
    release_doc: dict
    release_yaml: bytes
    release_env: bytes
    release_json: bytes | None
    platform_tree: bytes
    base_prefix: str
    base_doc: dict
    base_yaml: bytes
    base_env: bytes
    base_tree: bytes
    metadata_files: dict[str, bytes]
    rows: list[Row] = field(default_factory=list)

    @property
    def release(self) -> str:
        return str(self.release_doc.get("product", ""))

    @property
    def line(self) -> str:
        return str(self.release_doc.get("line", ""))

    @property
    def base_version(self) -> str:
        return str((self.release_doc.get("requires_base") or {}).get("version", ""))

    @property
    def base_digest(self) -> str:
        return str((self.release_doc.get("requires_base") or {}).get("digest", ""))


def parse_tree(data: bytes) -> list[Row]:
    rows: list[Row] = []
    lines = data.decode("utf-8").splitlines()
    if not lines:
        return rows
    for line in lines[1:]:
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) < 6:
            die(f"tree.tsv 行列数不足: {line!r}", 2)
        rows.append(Row(
            path=fields[0],
            artifact=fields[1],
            extract=fields[2].strip().lower() == "true",
            mode=fields[3] or "0644",
            size=int(fields[4] or 0),
            sha=fields[5].removeprefix("sha256:"),
            group=fields[6] if len(fields) > 6 else "",
            package=fields[7] if len(fields) > 7 else "",
        ))
    return rows


def merge_rows(base: list[Row], platform: list[Row]) -> list[Row]:
    merged: dict[str, Row] = {}
    for row in base + platform:
        prev = merged.get(row.path)
        if prev is None:
            merged[row.path] = row
            continue
        if prev.sha != row.sha or prev.extract != row.extract:
            die(f"tree.tsv 路径冲突: {row.path} "
                f"({prev.sha} vs {row.sha})", 2)
    return list(merged.values())


def load_context(args) -> Context:
    store = args.store.rstrip("/")
    target = getattr(args, "store_dst", args.store).rstrip("/")
    local_root = Path(args.local_root)

    stream_doc: dict = {}
    stream_file: str | None = None
    if args.snapshot:
        source_target = args.snapshot.strip("/")
    elif getattr(args, "release", ""):
        source_target = f"releases/{str(args.release).strip('/')}"
    else:
        stream_file = f"{store}/streams/{args.stream}.yaml"
        if not mc_exists(stream_file):
            die(f"stream 不存在: {stream_file}", 2)
        stream_doc = yaml.safe_load(mc_cat(stream_file)) or {}
        source_target = str(stream_doc.get("target", "")).strip("/")
        if not source_target:
            die(f"stream 缺少 target: {stream_file}", 2)

    snap_prefix = f"{store}/{source_target}"
    if not mc_exists(f"{snap_prefix}/_SUCCESS"):
        die(f"目标不完整（缺 _SUCCESS）: {snap_prefix}", 2)

    release_yaml = mc_cat(f"{snap_prefix}/release.yaml")
    release_doc = yaml.safe_load(release_yaml) or {}
    if stream_doc.get("manifest_sha256"):
        want = str(stream_doc["manifest_sha256"]).removeprefix("sha256:")
        if sha_bytes(release_yaml) != want:
            die(f"release.yaml digest 与 stream 指针不符: "
                f"{sha_bytes(release_yaml)} != {want}", 2)

    release_env = mc_cat(f"{snap_prefix}/release.env")
    release_json = (mc_cat(f"{snap_prefix}/release.json")
                    if mc_exists(f"{snap_prefix}/release.json") else None)
    platform_tree = mc_cat(f"{snap_prefix}/tree.tsv")

    base_version = str((release_doc.get("requires_base") or {}).get("version", ""))
    if not base_version:
        die("release.yaml 缺少 requires_base.version", 2)
    base_prefix = f"{store}/base/{base_version}"
    if not mc_exists(f"{base_prefix}/_SUCCESS"):
        die(f"base 包不完整（缺 _SUCCESS）: {base_prefix}", 2)
    base_yaml = mc_cat(f"{base_prefix}/base.yaml")
    base_env = mc_cat(f"{base_prefix}/base.env")
    base_tree = mc_cat(f"{base_prefix}/tree.tsv")

    metadata_files: dict[str, bytes] = {}
    for rel in (release_doc.get("metadata_files") or []):
        rel = str(rel).strip("/")
        src = f"{snap_prefix}/{rel}"
        if not mc_exists(src):
            die(f"metadata_files 缺失: {src}", 2)
        metadata_files[rel] = mc_cat(src)

    rows = merge_rows(parse_tree(base_tree), parse_tree(platform_tree))
    return Context(
        store=store, target=target, local_root=local_root,
        work_dir=Path(args.work_dir), snapshot_prefix=snap_prefix,
        source_target=source_target, stream_file=stream_file,
        stream_doc=stream_doc, release_doc=release_doc,
        release_yaml=release_yaml, release_env=release_env,
        release_json=release_json, platform_tree=platform_tree,
        base_prefix=base_prefix, base_doc=yaml.safe_load(base_yaml) or {},
        base_yaml=base_yaml, base_env=base_env, base_tree=base_tree,
        metadata_files=metadata_files, rows=rows,
    )


# ---------------------------------------------------------------- extract

def _safe_member(name: str) -> bool:
    if name.startswith("/") or ".." in Path(name).parts:
        return False
    return True


def extract_archive(archive: Path, dest: Path) -> list[str]:
    """解包到 dest，返回成员相对路径；拒绝路径穿越与非普通文件。"""
    dest.mkdir(parents=True, exist_ok=True)
    names: list[str] = []
    with tarfile.open(archive, "r:*") as tar:
        for member in tar.getmembers():
            if not _safe_member(member.name):
                die(f"归档成员路径非法: {member.name}", 2)
            if member.isdir():
                continue
            if not member.isfile():
                die(f"归档含非普通文件: {member.name}", 2)
            target = dest / member.name
            target.parent.mkdir(parents=True, exist_ok=True)
            src = tar.extractfile(member)
            if src is None:
                die(f"归档成员不可读: {member.name}", 2)
            target.write_bytes(src.read())
            target.chmod(member.mode & 0o777)
            names.append(member.name)
    return names


def materialize_specials(ctx: Context) -> list[tuple[str, Path]]:
    """下载并展开 extract=true 的归档，返回 [(tree_rel, local_path)]。"""
    specials = [r for r in ctx.rows if r.extract]
    if not specials:
        return []
    ctx.work_dir.mkdir(parents=True, exist_ok=True)
    files: list[tuple[str, Path]] = []
    for idx, row in enumerate(specials):
        base = Path(row.path).name
        slug = f"{idx:02d}-{base}"
        tmpdir = Path(tempfile.mkdtemp(prefix=f"{slug}-", dir=ctx.work_dir))
        archive = tmpdir / "archive"
        say(f"下载 extract 归档 {row.path} ({gib(row.size)})")
        mc_cp(f"{ctx.store}/{row.artifact}", str(archive))
        actual = sha_file(archive)
        if actual != row.sha:
            die(f"归档 digest 不符: {row.path} {actual} != {row.sha}", 1)

        if row.path.endswith("/"):
            # modules/ 之类：解到同目录
            dest = tmpdir / "extract"
            members = extract_archive(archive, dest)
            for name in members:
                files.append((f"{row.path.rstrip('/')}/{name}", dest / name))
        elif base == "binaries.tar.gz":
            # 归档根文件 → 展开到 dirname(path)
            parent = str(Path(row.path).parent)
            dest = tmpdir / "extract"
            members = extract_archive(archive, dest)
            for name in members:
                files.append((f"{parent}/{name}", dest / name))
        elif base == "tree.tar.gz":
            # installer 契约：保留归档 + sha256 边车
            dest = tmpdir / "tree"
            dest.mkdir(parents=True, exist_ok=True)
            tree_copy = dest / "tree.tar.gz"
            shutil.copyfile(archive, tree_copy)
            side = dest / "tree.tar.gz.sha256"
            side.write_text(f"{actual}  tree.tar.gz\n", encoding="utf-8")
            files.append((row.path, tree_copy))
            files.append((f"{row.path}.sha256", side))
        else:
            die(f"不支持的 extract=true 行: {row.path}", 2)
    return files


# ---------------------------------------------------------------- entries

def version_profile(ctx: Context) -> tuple[str, bytes] | None:
    env = {}
    for line in ctx.release_env.decode("utf-8", "replace").splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()
    kver = env.get("KUBESPRAY_VERSION", "")
    if not kver:
        return None
    profile = PROFILE_DIR / f"{kver}.profile"
    if not profile.is_file():
        warn(f"未找到版本档案 {profile}，latest 树将缺少 VERSION.profile")
        return None
    rel = f"offline-files/kubespray/{kver}/VERSION.profile"
    return rel, profile.read_bytes()


def parse_env_bytes(data: bytes) -> dict[str, str]:
    env: dict[str, str] = {}
    for line in data.decode("utf-8", "replace").splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()
    return env


def add_compat_aliases(ctx: Context, entries: dict[str, Entry]) -> list[str]:
    """新 CI 树用中性 chart 名，旧消费端（发布版 CLI 的
    resolve_operator_chart_tgz）只认 <name>-<ver>.tgz；补一个版本化别名。
    只别名 operator 自身 chart：其他组件 chart 由 *.tgz 遍历消费，别名会造成重复。
    """
    version = parse_env_bytes(ctx.release_env).get(
        "CUBESTACK_OPERATOR_CHART_VERSION", "")
    neutral = "offline-files/cubestack-operator/charts/cubestack-operator-chart.tgz"
    if not version or neutral not in entries:
        return []
    alias = ("offline-files/cubestack-operator/charts/"
             f"cubestack-operator-chart-{version}.tgz")
    if alias in entries:
        return []
    src = entries[neutral]
    entries[alias] = Entry(src.digest, src.size, src.kind, src.ref,
                           src.stage, src.mode)
    return [alias]


def build_entries(ctx: Context) -> dict[str, Entry]:
    entries: dict[str, Entry] = {}

    for row in ctx.rows:
        if row.extract:
            continue
        entries[row.path] = Entry(row.sha, row.size, "artifact",
                                  f"{ctx.store}/{row.artifact}",
                                  mode=row.mode)

    for rel, path in materialize_specials(ctx):
        entries[rel] = Entry(sha_file(path), path.stat().st_size, "staged", path)

    metadata: dict[str, bytes] = {
        "offline-files/release.yaml": ctx.release_yaml,
        "offline-files/release.env": ctx.release_env,
        "offline-files/tree.tsv": ctx.platform_tree,
        "offline-files/base/base.yaml": ctx.base_yaml,
        "offline-files/base/base.env": ctx.base_env,
        "offline-files/base/tree.tsv": ctx.base_tree,
    }
    if ctx.release_json is not None:
        metadata["offline-files/release.json"] = ctx.release_json
    metadata.update(ctx.metadata_files)
    for rel, data in metadata.items():
        entries[rel] = Entry(sha_bytes(data), len(data), "bytes", data,
                             stage="metadata")

    profile = version_profile(ctx)
    if profile:
        rel, data = profile
        if f"offline-files/kubespray" in rel:
            entries[rel] = Entry(sha_bytes(data), len(data), "bytes", data,
                                 stage="metadata")

    add_compat_aliases(ctx, entries)
    sums = build_sums(entries)
    entries["offline-files/SHA256SUMS"] = Entry(
        sha_bytes(sums), len(sums), "bytes", sums, stage="metadata")
    success = f"sha256:{sha_bytes(sums)}\n".encode()
    entries["offline-files/_SUCCESS"] = Entry(
        sha_bytes(success), len(success), "bytes", success, stage="success")
    return entries


def build_sums(entries: dict[str, Entry]) -> bytes:
    lines = []
    for rel, entry in entries.items():
        if not rel.startswith("offline-files/"):
            continue
        sub = rel[len("offline-files/"):]
        if sub in ("SHA256SUMS", "_SUCCESS"):
            continue
        lines.append((sub, f"{entry.digest}  {sub}"))
    lines.sort(key=lambda item: item[0])
    return ("\n".join(line for _, line in lines) + "\n").encode()


def source_yaml(ctx: Context) -> bytes:
    data = {
        "schema": 1,
        "line": ctx.line,
        "channel": ctx.stream_doc.get("channel", "snapshot"),
        "source_store": ctx.store,
        "source_stream": ctx.stream_file,
        "source_target": ctx.source_target,
        "manifest_sha256": ctx.stream_doc.get("manifest_sha256")
        or f"sha256:{sha_bytes(ctx.release_yaml)}",
        "base_version": ctx.base_version,
        "base_digest": ctx.base_digest,
        "release": ctx.release,
        "target": ctx.target,
        "published_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    return (yaml.safe_dump(data, sort_keys=False, allow_unicode=True)).encode()


# ---------------------------------------------------------------- plan

def parse_local_sums(root: Path) -> dict[str, str]:
    path = root / "SHA256SUMS"
    result: dict[str, str] = {}
    if not path.is_file():
        return result
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        digest, rel = parts[0].lower(), parts[1].strip()
        rel = rel[2:] if rel.startswith("./") else rel
        result[rel] = digest
    return result


def local_files(root: Path) -> dict[str, int]:
    result: dict[str, int] = {}
    if not root.is_dir():
        return result
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".cubestack-")]
        for name in filenames:
            if name.startswith(".cubestack-"):
                continue
            full = Path(dirpath) / name
            result[str(full.relative_to(root))] = full.stat().st_size
    return result


def local_diff(entries: dict[str, Entry], root: Path) -> dict:
    expected = {
        rel[len("offline-files/"):]: entry
        for rel, entry in entries.items()
        if rel.startswith("offline-files/")
    }
    sums = parse_local_sums(root)
    actual = local_files(root)

    keep = changed = new = 0
    keep_b = changed_b = new_b = 0
    for rel, entry in expected.items():
        if rel in sums and sums[rel] == entry.digest and rel in actual:
            keep += 1
            keep_b += actual[rel]
        elif rel in actual:
            changed += 1
            changed_b += entry.size
        else:
            new += 1
            new_b += entry.size

    stale = [rel for rel in actual if rel not in expected]
    stale_b = sum(actual[rel] for rel in stale)

    free = shutil.disk_usage(root if root.exists() else root.parent).free
    need = changed_b + new_b
    after = free + stale_b
    return {
        "keep": keep, "keep_bytes": keep_b,
        "changed": changed, "changed_bytes": changed_b,
        "new": new, "new_bytes": new_b,
        "stale": len(stale), "stale_bytes": stale_b,
        "need_bytes": need, "free_bytes": free,
        "free_after_prune_bytes": after,
        "fits": need <= after,
        "stale_sample": sorted(stale)[:10],
    }


def target_diff(entries: dict[str, Entry], target: str) -> dict:
    key = bucket_prefix(target)
    listed = mc_ls(target)
    prefix = key.rstrip("/") + "/"
    existing = {
        k[len(prefix):]: size for k, size in listed.items()
        if k.startswith(prefix)
    }
    extra = [rel for rel in existing if rel not in entries and rel != "SOURCE.yaml"]
    missing = [rel for rel in entries if rel not in existing]
    same_size = [rel for rel in entries if rel in existing
                 and existing[rel] == entries[rel].size]
    return {
        "objects": len(existing), "missing": len(missing),
        "same_size": len(same_size), "extra": len(extra),
        "extra_sample": sorted(extra)[:10],
    }


def plan(args) -> dict:
    ctx = load_context(args)
    if not args.json:
        say(f"store: {ctx.store}")
        say(f"snapshot: {ctx.source_target}")
        say(f"base: {ctx.base_prefix.split('/')[-1]}")
        say(f"target: {ctx.target}")
        say(f"local: {ctx.local_root}")

    # 只读计划不下载 extract 归档：用归档大小占位
    entries = {}
    for row in ctx.rows:
        if row.extract:
            continue
        entries[row.path] = Entry(row.sha, row.size, "artifact",
                                  f"{ctx.store}/{row.artifact}",
                                  mode=row.mode)
    metadata: dict[str, bytes] = {
        "offline-files/release.yaml": ctx.release_yaml,
        "offline-files/release.env": ctx.release_env,
        "offline-files/tree.tsv": ctx.platform_tree,
        "offline-files/base/base.yaml": ctx.base_yaml,
        "offline-files/base/base.env": ctx.base_env,
        "offline-files/base/tree.tsv": ctx.base_tree,
    }
    if ctx.release_json is not None:
        metadata["offline-files/release.json"] = ctx.release_json
    metadata.update(ctx.metadata_files)
    for rel, data in metadata.items():
        entries[rel] = Entry(sha_bytes(data), len(data), "bytes", data)

    profile = version_profile(ctx)
    if profile:
        rel, data = profile
        entries[rel] = Entry(sha_bytes(data), len(data), "bytes", data)

    # 计划阶段不展开 extract 归档，因此这里的 SHA256SUMS/_SUCCESS 只是估算；
    # apply 会在展开后按实际落盘文件重算（含 binaries/modules 展开结果）。
    add_compat_aliases(ctx, entries)
    sums = build_sums(entries)
    entries["offline-files/SHA256SUMS"] = Entry(
        sha_bytes(sums), len(sums), "bytes", sums)
    success = f"sha256:{sha_bytes(sums)}\n".encode()
    entries["offline-files/_SUCCESS"] = Entry(
        sha_bytes(success), len(success), "bytes", success)

    specials = [r for r in ctx.rows if r.extract]
    special_bytes = sum(r.size for r in specials)
    total = sum(e.size for e in entries.values()) + special_bytes

    local = (local_diff(entries, ctx.local_root)
             if ctx.local_root.is_dir() else {
                 "keep": 0, "keep_bytes": 0, "changed": 0, "changed_bytes": 0,
                 "new": len(entries), "new_bytes": total,
                 "stale": 0, "stale_bytes": 0, "need_bytes": total,
                 "free_bytes": shutil.disk_usage(ctx.local_root.parent).free,
                 "free_after_prune_bytes": shutil.disk_usage(
                     ctx.local_root.parent).free,
                 "fits": False, "stale_sample": [],
             })

    summary = {
        "store": ctx.store,
        "release": ctx.release,
        "line": ctx.line,
        "source_target": ctx.source_target,
        "base": ctx.base_version,
        "manifest_sha256": ctx.stream_doc.get("manifest_sha256")
        or f"sha256:{sha_bytes(ctx.release_yaml)}",
        "plan_files": len(entries),
        "special_files": len(specials),
        "special_bytes": special_bytes,
        "target_files": len(entries) + len(specials),
        "target_bytes": total,
        "local": local,
        "metadata_files": sorted(metadata),
    }

    if args.json:
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        return summary

    print()
    print(f"  物化源        {ctx.store}")
    print(f"  发布版本      {ctx.release} ({ctx.line})")
    print(f"  目标          {ctx.source_target}")
    print(f"  base          {ctx.base_version} ({ctx.base_digest})")
    print(f"  清单文件      {len(entries)} 个（未含 extract 展开）, "
          f"{gib(sum(e.size for e in entries.values()))}")
    print(f"  extract 归档  {len(specials)} 个, {gib(special_bytes)}")
    print(f"  合计          {len(entries) + len(specials)} 项, {gib(total)}")
    print()
    print("  本地 " + str(ctx.local_root) + ":")
    print(f"    keep {local['keep']} ({gib(local['keep_bytes'])})  "
          f"changed {local['changed']} ({gib(local['changed_bytes'])})  "
          f"new {local['new']} ({gib(local['new_bytes'])})")
    print(f"    stale {local['stale']} ({gib(local['stale_bytes'])})  "
          f"需下载 {gib(local['need_bytes'])}  "
          f"现有可用 {gib(local['free_bytes'])}  "
          f"删 stale 后 {gib(local['free_after_prune_bytes'])}")
    print(f"    空间结论: {'✅ 可行' if local['fits'] else '❌ 不足'}")
    if local["stale_sample"]:
        print(f"    stale 示例: {', '.join(local['stale_sample'][:5])}")
    if specials:
        print("    ⚠ extract 展开文件未纳入本地比对（apply 会展开；勿据此手工删文件）")
    return summary


def _strip_store_prefix(key: str, store: str) -> str:
    """把桶内相对 key 剥成 store 根相对 key。"""
    rel = store.split("/", 2)[-1].strip("/")
    if rel:
        if key == rel:
            return ""
        if key.startswith(rel + "/"):
            return key[len(rel) + 1:]
    return key


def store_objects(args) -> tuple[Context, dict[str, int]]:
    """解析 CI store 需要镜像的对象：{store 相对 key: size}。"""
    ctx = load_context(args)
    src = ctx.store
    objs: dict[str, int] = {}

    def add_prefix(prefix: str) -> None:
        for key, size in mc_ls(f"{src}/{prefix}/").items():
            rel = _strip_store_prefix(key, src)
            if rel:
                objs[rel] = size

    add_prefix(ctx.source_target)
    add_prefix(f"base/{ctx.base_version}")
    if ctx.stream_file:
        size = mc_size(ctx.stream_file)
        if size is not None:
            bucket_rel = ctx.stream_file.split("/", 2)[-1]
            objs[_strip_store_prefix(bucket_rel, src)] = size
    for row in ctx.rows:
        objs[row.artifact] = row.size
    for prefix in ("artifacts/images/by-digest", "artifacts/files/by-digest",
                   "artifacts/cli/by-digest"):
        add_prefix(prefix)
    if not args.skip_vendor:
        # vendor/ 是桶根前缀（与 validation/ 同级），不在 store 根下。
        alias_bucket = "/".join(src.split("/")[:2])
        for key, size in mc_ls(f"{alias_bucket}/vendor/").items():
            if key.startswith("vendor/"):
                objs[key] = size
    if args.with_payloads:
        add_prefix("artifacts/payloads")
    return ctx, objs


def _existing_under(dst: str) -> dict[str, int]:
    listed = mc_ls(dst)
    rel = bucket_prefix(dst)
    if not rel:
        return listed
    return {k[len(rel) + 1:]: v for k, v in listed.items()
            if k.startswith(rel + "/")}


def store_plan(args) -> dict:
    ctx, objs = store_objects(args)
    dst = args.store_dst.rstrip("/")
    existing = _existing_under(dst)
    missing = {rel: size for rel, size in objs.items()
               if existing.get(rel) != size}
    groups: dict[str, list[int]] = {}
    for rel, size in objs.items():
        top = rel.split("/", 1)[0]
        groups.setdefault(top, []).append(size)

    summary = {
        "source": ctx.store,
        "target": dst,
        "source_target": ctx.source_target,
        "base": ctx.base_version,
        "objects": len(objs),
        "bytes": sum(objs.values()),
        "missing": len(missing),
        "missing_bytes": sum(missing.values()),
        "existing_bytes": sum(existing.get(rel, 0) for rel in objs),
        "groups": {k: {"objects": len(v), "bytes": sum(v)}
                   for k, v in sorted(groups.items())},
    }
    if args.json:
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        return summary
    print()
    print(f"  源 store      {ctx.store}")
    print(f"  目标 store    {dst}")
    print(f"  目标          {ctx.source_target}")
    print(f"  base          {ctx.base_version}")
    print(f"  对象          {len(objs)} 个, {gib(summary['bytes'])}")
    print(f"  待复制        {summary['missing']} 个, {gib(summary['missing_bytes'])}")
    for name, info in summary["groups"].items():
        print(f"    {name:<12} {info['objects']:>4} 个  {gib(info['bytes'])}")
    return summary


def store_apply(args) -> None:
    ctx, objs = store_objects(args)
    src = ctx.store
    dst = args.store_dst.rstrip("/")
    existing = _existing_under(dst)

    say(f"镜像 CI store: {src} → {dst}")
    alias_bucket = "/".join(src.split("/")[:2])
    copied = skipped = 0
    for rel in sorted(objs):
        size = objs[rel]
        if not args.force_upload and existing.get(rel) == size:
            skipped += 1
            continue
        print(f"  ⇢ {rel} ({gib(size)})")
        source = f"{alias_bucket}/{rel}" if rel.startswith("vendor/") else f"{src}/{rel}"
        mc_cp(source, f"{dst}/{rel}")
        copied += 1

    pointer = {
        "schema": 1,
        "kind": "store-mirror",
        "source_store": src,
        "target_store": dst,
        "source_target": ctx.source_target,
        "base_version": ctx.base_version,
        "base_digest": ctx.base_digest,
        "manifest_sha256": ctx.stream_doc.get("manifest_sha256")
        or f"sha256:{sha_bytes(ctx.release_yaml)}",
        "published_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "objects": len(objs),
        "bytes": sum(objs.values()),
        "copied": copied,
        "skipped": skipped,
    }
    write_bytes(f"{dst}/STORE-SOURCE.yaml",
                (yaml.safe_dump(pointer, sort_keys=False,
                                allow_unicode=True)).encode(),
                ctx.work_dir)
    ok(f"store 镜像完成: 复制 {copied} 个, 跳过 {skipped} 个")


# ---------------------------------------------------------------- apply

def write_bytes(path: str, data: bytes, work_dir: Path) -> None:
    work_dir.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix="meta-", dir=work_dir)
    os.close(fd)
    tmp = Path(name)
    try:
        tmp.write_bytes(data)
        mc_cp(str(tmp), path)
    finally:
        tmp.unlink(missing_ok=True)


def publish_minio(ctx: Context, entries: dict[str, Entry],
                  force: bool, prune: bool) -> None:
    target = ctx.target
    say(f"发布 MinIO: {target}")

    blobs = [(r, e) for r, e in entries.items() if e.stage == "blob"]
    metadata = [(r, e) for r, e in entries.items() if e.stage == "metadata"]
    success = [(r, e) for r, e in entries.items() if e.stage == "success"]

    # 发布期间先撤掉 _SUCCESS：中断时消费端明确失败，而不是拿到半套树。
    if mc_exists(f"{target}/offline-files/_SUCCESS"):
        mc_rm(f"{target}/offline-files/_SUCCESS")

    def upload(rel: str, entry: Entry) -> None:
        dst = f"{target}/{rel}"
        if not force:
            size = mc_size(dst)
            if size is not None and size == entry.size:
                return
        if entry.kind == "artifact":
            mc_cp(str(entry.ref), dst)
        elif entry.kind == "staged":
            mc_cp(str(entry.ref), dst)
        else:
            write_bytes(dst, entry.ref, ctx.work_dir)

    for rel, entry in blobs:
        print(f"  ↑ {rel} ({gib(entry.size)})")
        upload(rel, entry)
    for rel, entry in metadata:
        print(f"  ↑ {rel}")
        upload(rel, entry)
    # _SUCCESS 最后
    for rel, entry in success:
        print(f"  ↑ {rel} (last)")
        upload(rel, entry)
    write_bytes(f"{target}/SOURCE.yaml", source_yaml(ctx), ctx.work_dir)

    if prune:
        key = bucket_prefix(target)
        prefix = key.rstrip("/") + "/" if key else ""
        listed = mc_ls(target)
        extra = [k for k in listed if k.startswith(prefix)
                 and k[len(prefix):] not in entries
                 and k[len(prefix):] != "SOURCE.yaml"]
        for k in extra:
            print(f"  ✗ 删除多余对象 {k}")
            mc_rm(f"{'/'.join(target.split('/')[:2])}/{k}")
    else:
        key = bucket_prefix(target)
        prefix = key.rstrip("/") + "/" if key else ""
        extra = [k for k in mc_ls(target) if k.startswith(prefix)
                 and k[len(prefix):] not in entries
                 and k[len(prefix):] != "SOURCE.yaml"]
        if extra:
            warn(f"target 有 {len(extra)} 个多余对象未删除（加 --prune 清理）: "
                 + ", ".join(sorted(extra)[:5]))


def _mode_for(rel: str, entry: Entry) -> int:
    # metax 的 .run 需要可执行位；CI tree.tsv 标的是 0644，但模块用 `[ -x ]` 判定。
    if rel.endswith(".run"):
        return 0o755
    try:
        return int(entry.mode, 8)
    except (TypeError, ValueError):
        return 0o644


def sync_install_tree(ctx: Context, entries: dict[str, Entry]) -> None:
    """把 modules/ 与 cubestack-installer-cli.tar 物化到
    `dirname(local_root)`（例如 /data），供 installer 的 release 模式发现：
      <install-root>/modules/                  → dirname(OFFLINE_FILES_ROOT)/modules
      <install-root>/cubestack-installer-cli.tar
    """
    install_root = ctx.local_root.parent
    targets = [(r, e) for r, e in entries.items()
               if r == "cubestack-installer-cli.tar" or r.startswith("modules/")]
    if not targets:
        return
    install_root.mkdir(parents=True, exist_ok=True)
    say(f"物化安装树附属文件 → {install_root}")
    for rel, entry in sorted(targets):
        dst = install_root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.is_file() and dst.stat().st_size == entry.size \
                and sha_file(dst) == entry.digest:
            dst.chmod(_mode_for(rel, entry))
            continue
        tmp = dst.with_name(dst.name + ".cubestack-tmp")
        print(f"  ↓ {rel} ({gib(entry.size)})")
        if entry.kind == "bytes":
            tmp.write_bytes(entry.ref)
        elif entry.kind == "staged":
            shutil.copyfile(entry.ref, tmp)
        else:
            mc_cp(str(entry.ref), str(tmp))
        if sha_file(tmp) != entry.digest:
            tmp.unlink(missing_ok=True)
            die(f"安装树文件校验失败: {rel}", 1)
        tmp.chmod(_mode_for(rel, entry))
        tmp.replace(dst)
    ok(f"安装树附属文件就绪: {install_root}/modules, {install_root}/cubestack-installer-cli.tar")


def sync_local(ctx: Context, entries: dict[str, Entry], prune: bool,
               verify: bool) -> None:
    root = ctx.local_root
    root.mkdir(parents=True, exist_ok=True)
    expected = {
        rel[len("offline-files/"):]: entry
        for rel, entry in entries.items()
        if rel.startswith("offline-files/")
    }

    backup = root / ".cubestack-manifest-backup" / time.strftime("%Y%m%d-%H%M%S")
    backup.mkdir(parents=True, exist_ok=True)
    for name in ("release.yaml", "release.env", "release.json",
                 "tree.tsv", "SHA256SUMS", "_SUCCESS"):
        src = root / name
        if src.is_file():
            shutil.copy2(src, backup / name)
    if (root / "base").is_dir():
        shutil.copytree(root / "base", backup / "base", dirs_exist_ok=True)
    say(f"旧元数据已备份: {backup}")

    actual = local_files(root)
    stale = sorted(rel for rel in actual if rel not in expected)
    if stale:
        say(f"删除 {len(stale)} 个 stale 文件")
        for rel in stale:
            (root / rel).unlink(missing_ok=True)
        for dirpath, dirnames, filenames in os.walk(root, topdown=False):
            if Path(dirpath) == root:
                continue
            if Path(dirpath).name.startswith(".cubestack-"):
                continue
            try:
                Path(dirpath).rmdir()
            except OSError:
                pass

    sums = parse_local_sums(root)
    todo = [(rel, entry) for rel, entry in expected.items()
            if rel != "_SUCCESS"
            and not (rel in sums and sums[rel] == entry.digest
                     and (root / rel).is_file())]

    needed = shutil.disk_usage(root).free
    need = sum(e.size for _, e in todo)
    if need > needed:
        die(f"本地空间不足: 需 {gib(need)}, 可用 {gib(needed)}", 2)

    # 先撤掉旧 _SUCCESS，最后再写新的。
    (root / "_SUCCESS").unlink(missing_ok=True)

    content = [(r, e) for r, e in todo if r != "SHA256SUMS"]
    meta_tail = [(r, e) for r, e in todo if r == "SHA256SUMS"]

    for rel, entry in sorted(content):
        dst = root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        tmp = dst.with_name(dst.name + ".cubestack-tmp")
        print(f"  ↓ {rel} ({gib(entry.size)})")
        if entry.kind == "bytes":
            tmp.write_bytes(entry.ref)
        elif entry.kind == "staged":
            shutil.copyfile(entry.ref, tmp)
        else:
            mc_cp(str(entry.ref), str(tmp))
        digest = sha_file(tmp)
        if digest != entry.digest:
            tmp.unlink(missing_ok=True)
            die(f"下载校验失败: {rel} {digest} != {entry.digest}", 1)
        if tmp.stat().st_size != entry.size:
            tmp.unlink(missing_ok=True)
            die(f"下载大小不符: {rel} {tmp.stat().st_size} != {entry.size}", 1)
        tmp.chmod(_mode_for(rel, entry))
        tmp.replace(dst)

    # 已存在且 digest 相同的文件不会被重下；这里统一修正 mode（历史树是 0644）。
    for rel, entry in expected.items():
        path = root / rel
        if path.is_file():
            want = _mode_for(rel, entry)
            if (path.stat().st_mode & 0o777) != want:
                path.chmod(want)

    for rel, entry in meta_tail:
        print(f"  ↓ {rel}")
        (root / rel).write_bytes(entry.ref)

    success_entry = expected.get("_SUCCESS")
    if success_entry is not None:
        print("  ↓ _SUCCESS (last)")
        (root / "_SUCCESS").write_bytes(success_entry.ref)

    ok(f"本地树已更新: {root} ({len(expected)} 个文件)")

    if verify and VERIFIER.is_file():
        say("运行 offline 结构校验 ...")
        proc = subprocess.run(
            ["bash", str(VERIFIER), "--root", str(root),
             "--layout", "release", "--require-success", "--level", "quick",
             "--no-stamp"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        text = proc.stdout.decode("utf-8", "replace")
        print(text[-3000:])
        if proc.returncode != 0:
            die("offline 结构校验失败", 1)
        ok("offline 结构校验通过")


# ---------------------------------------------------------------- main

def main() -> int:
    parser = argparse.ArgumentParser(
        description="把 cubestack-release 的 CI store 镜像到 MinIO，"
                    "并从该布局物化本地离线安装文件（snapshot/release 均可）")
    parser.add_argument("command", nargs="?", default="plan",
                        choices=["plan", "apply", "store"])
    parser.add_argument("--store", default=DEFAULT_STORE)
    parser.add_argument("--store-dst", default=DEFAULT_TARGET)
    parser.add_argument("--materialize-from", default=DEFAULT_TARGET)
    parser.add_argument("--stream", default="2.1-snapshot")
    parser.add_argument("--snapshot", default="")
    parser.add_argument("--release", default="")
    parser.add_argument("--local-root", default=DEFAULT_LOCAL)
    parser.add_argument("--work-dir", default=DEFAULT_WORK)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--force-upload", action="store_true")
    parser.add_argument("--skip-local", action="store_true")
    parser.add_argument("--skip-vendor", action="store_true")
    parser.add_argument("--with-payloads", action="store_true")
    parser.add_argument("--with-install-tree", action="store_true")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--yes", action="store_true")
    args = parser.parse_args()

    # plan/apply 读取的是 CI store 布局（默认在 latest/ 下）；
    # store 命令的源仍是 --store（cubestack-test/validation）。
    if args.command in ("plan", "apply"):
        args.store = args.materialize_from

    if args.command == "plan":
        plan(args)
        return 0

    if args.command == "store":
        if not args.yes:
            store_plan(args)
            print("\n  （只读计划；确认后加 --yes 执行）")
            return 0
        store_apply(args)
        return 0

    if not args.yes:
        die("apply 需要 --yes（先跑 plan 确认）", 2)

    ctx = load_context(args)
    entries = build_entries(ctx)
    total = sum(e.size for e in entries.values())
    say(f"从 {ctx.store} 物化 {len(entries)} 个文件, {gib(total)}")

    if not args.skip_local:
        summary = local_diff(entries, ctx.local_root)
        if not summary["fits"]:
            die(f"本地空间不足: 需 {gib(summary['need_bytes'])}, "
                f"删 stale 后可用 {gib(summary['free_after_prune_bytes'])}", 2)
        sync_local(ctx, entries, prune=True, verify=args.verify)
        if args.with_install_tree:
            sync_install_tree(ctx, entries)

    shutil.rmtree(ctx.work_dir, ignore_errors=True)
    ok("完成")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        die("已中断", 130)
