#!/usr/bin/env python3
"""manifest-plan.py — 按远端 SHA256SUMS 生成"内容寻址增量下载计划"。

用途(被 lib-offline-fetch.sh 调用):
    远端 offline-files/SHA256SUMS + 本地离线树 → 只下载"缺失或内容不符"的文件,
    并列出"远端已不存在"的多余文件; 不再依赖对象存储的 Last-Modified。

为什么需要它:
    `mc mirror --overwrite` 不做内容比对, 且 S3/MinIO 的 Last-Modified 是服务端分配的
    (整树复制出来的新版本目录会让所有对象变"新") ⇒ 每次换版本都会把 100+ GiB 全量重传。
    本工具以 SHA256SUMS 为唯一判据, 与 mtime/ETag 无关。

输出(--out, TSV):
    fetch<TAB><rel>     需要下载
    delete<TAB><rel>    远端清单里没有, 需删除
stdout: 单行 JSON 摘要 {"fetch":N,"fetch_bytes":B,"delete":M,"kept":K,"hashed":H,"cached":C}

退出码:
    0 = 正常(计划已写)
    3 = 清单不可用/格式非法 → 调用方应回退到整树 mirror
    2 = 参数/IO 错误

哈希缓存(可选 --cache):
    记录 {rel: {size, mtime_ns, sha}}; 只有 (size,mtime_ns) 变化才重新读取文件。
    缓存只影响"是否要重下"的判断, 最终仍由 fetch 后的全量 sha256 校验兜底。

--hash-list <file>:
    刷新模式: 对文件里列出的 rel 重新计算 sha 并写回缓存(下载完成后调用), 不生成计划。

⚠ 本文件只做纯计算(不联网), 便于离线单测:
    bash deployments/scripts/tools/tests/test-offline-incremental-plan.sh
"""

import argparse
import hashlib
import json
import os
import sys

CACHE_VERSION = 1
_CACHE_NAME = ".cubestack-hashes.json"


def warn(msg):
    print(f"manifest-plan: {msg}", file=sys.stderr)


def read_manifest(path):
    """返回 (entries{rel:sha}, invalid_count)。路径非法/哈希非法的行计入 invalid。"""
    entries = {}
    invalid = 0
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                invalid += 1
                continue
            sha = parts[0].strip().lower()
            rel = parts[1].strip()
            if rel.startswith("*"):          # sha256sum 的二进制模式前缀
                rel = rel[1:]
            if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
                invalid += 1
                continue
            rel = rel.replace("\\", "/")
            while rel.startswith("./"):
                rel = rel[2:]
            if not rel or rel.startswith("/") or ".." in rel.split("/"):
                invalid += 1
                continue
            entries[rel] = sha
    return entries, invalid


def sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def load_cache(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if data.get("version") != CACHE_VERSION or not isinstance(data.get("files"), dict):
            return {}
        return {k: v for k, v in data["files"].items() if isinstance(v, dict)}
    except (OSError, ValueError):
        return {}


def save_cache(path, files):
    if not path:
        return
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        return
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"version": CACHE_VERSION, "files": files}, f,
                      ensure_ascii=False, separators=(",", ":"))
            f.write("\n")
        os.replace(tmp, path)
    except OSError as exc:
        warn(f"缓存写入失败(忽略): {exc}")
        try:
            os.unlink(tmp)
        except OSError:
            pass


def normalize_prefix(prefix):
    p = (prefix or "").replace("\\", "/").strip()
    while p.startswith("./"):
        p = p[2:]
    p = p.strip("/")
    return f"{p}/" if p else ""


def _is_meta_name(name):
    # 元数据/校验戳不属于清单登记范围(校验器 META_NAMES 同口径); CLI tar 在 release 布局下
    # 位于树根, 不能被 flat 清理误删。
    return (name in ("SHA256SUMS", "SIZES", "_SUCCESS")
            or name.startswith(".cubestack-")
            or name == "cubestack-installer-cli.tar"
            or (name.startswith("cubestack-installer-cli-") and name.endswith(".tar")))


def plan(entries, root, prefix, cache):
    """生成计划; 返回 (plan[(op,rel)], summary dict)。"""
    plan_rows = []
    fetch_bytes = 0
    hashed = cached = 0

    for rel, want in sorted(entries.items()):
        if prefix and not rel.startswith(prefix):
            continue
        local = os.path.join(root, rel)
        if not os.path.isfile(local):
            plan_rows.append(("fetch", rel))
            continue
        try:
            st = os.stat(local)
        except OSError:
            plan_rows.append(("fetch", rel))
            continue
        size, mtime = st.st_size, st.st_mtime_ns
        hit = cache.get(rel)
        if hit and hit.get("size") == size and hit.get("mtime") == mtime and hit.get("sha"):
            got = hit["sha"]
            cached += 1
        else:
            try:
                got = sha256_file(local)
            except OSError:
                plan_rows.append(("fetch", rel))
                continue
            hashed += 1
            cache[rel] = {"size": size, "mtime": mtime, "sha": got}
        if got != want:
            plan_rows.append(("fetch", rel))
            fetch_bytes += size

    # 删除远端已不存在的本地文件(只扫 prefix 范围; .cubestack-* / CLI tar 豁免)
    scan_root = os.path.join(root, prefix) if prefix else root
    if os.path.isdir(scan_root):
        for dirpath, dirnames, filenames in os.walk(scan_root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".cubestack-")]
            base = os.path.relpath(dirpath, root).replace(os.sep, "/")
            if base == ".":
                base = ""
            for name in filenames:
                rel = f"{base}/{name}" if base else name
                if rel in entries or _is_meta_name(name):
                    continue
                plan_rows.append(("delete", rel))

    # 缓存裁剪: 只保留清单里仍存在、且属于本次 prefix 的键
    for key in list(cache):
        if key in entries:
            continue
        if prefix and not key.startswith(prefix):
            continue
        cache.pop(key, None)

    summary = {
        "fetch": sum(1 for op, _ in plan_rows if op == "fetch"),
        "fetch_bytes": fetch_bytes,
        "delete": sum(1 for op, _ in plan_rows if op == "delete"),
        "kept": sum(1 for rel in entries if not prefix or rel.startswith(prefix)) - sum(
            1 for op, _ in plan_rows if op == "fetch"),
        "hashed": hashed,
        "cached": cached,
    }
    return plan_rows, summary


def refresh(entries, root, cache, rels):
    for rel in rels:
        local = os.path.join(root, rel)
        if rel not in entries or not os.path.isfile(local):
            cache.pop(rel, None)
            continue
        try:
            st = os.stat(local)
            cache[rel] = {"size": st.st_size, "mtime": st.st_mtime_ns,
                          "sha": sha256_file(local)}
        except OSError:
            cache.pop(rel, None)


def main(argv=None):
    ap = argparse.ArgumentParser(description="按 SHA256SUMS 生成离线增量下载计划")
    ap.add_argument("--manifest", required=True, help="本地已下载的 SHA256SUMS")
    ap.add_argument("--root", required=True, help="本地离线树根(flat=offline-files 根)")
    ap.add_argument("--prefix", default="", help="只处理该子目录(如 kubespray/)")
    ap.add_argument("--cache", default="", help="哈希缓存 JSON 路径(缺省不缓存)")
    ap.add_argument("--out", required=True, help="计划输出 TSV")
    ap.add_argument("--hash-list", default="", help="刷新模式: 该文件内列出的 rel 重算哈希")
    args = ap.parse_args(argv)

    try:
        entries, invalid = read_manifest(args.manifest)
    except OSError as exc:
        warn(f"读取清单失败: {exc}")
        return 3
    if not entries:
        warn("清单为空或格式非法")
        return 3
    if invalid:
        # 宁可不增量, 也不要漏文件: 由调用方回退整树镜像
        warn(f"清单有 {invalid} 行非法, 放弃增量")
        return 3

    prefix = normalize_prefix(args.prefix)
    root = args.root
    cache = load_cache(args.cache) if args.cache else {}

    if args.hash_list:
        try:
            with open(args.hash_list, "r", encoding="utf-8") as f:
                rels = [ln.strip() for ln in f if ln.strip()]
        except OSError as exc:
            warn(f"读取 --hash-list 失败: {exc}")
            return 2
        refresh(entries, root, cache, rels)
        save_cache(args.cache, cache)
        print(json.dumps({"refreshed": len(rels)}, ensure_ascii=False))
        return 0

    rows, summary = plan(entries, root, prefix, cache)
    try:
        with open(args.out, "w", encoding="utf-8") as f:
            for op, rel in rows:
                f.write(f"{op}\t{rel}\n")
    except OSError as exc:
        warn(f"写入计划失败: {exc}")
        return 2
    save_cache(args.cache, cache)
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
