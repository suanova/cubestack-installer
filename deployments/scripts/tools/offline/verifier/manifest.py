import json
import os
import re

from .constants import SHA_RE, SIZE_RE
from .context import fail, warn
from .fsutil import norm_rel, is_meta, parse_env, parse_success, sha256_file, gnu_unescape

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
                fail(ctx, rel, "manifest_meta", "清单不允许登记元数据/校验戳/临时文件")
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
            m = SIZE_RE.match(line)
            if not m:
                fail(ctx, "SIZES", "manifest_format", f"第 {lineno} 行格式非法")
                continue
            result[norm_rel(gnu_unescape(m.group(2)))] = int(m.group(1))
    return result

def check_metadata(ctx, root, layout, args):
    ctx.checks["metadata"] = "ok"
    ctx.checks["coverage"] = "ok"
    ctx.checks["sizes"] = "ok"
    sums_path = os.path.join(root, "SHA256SUMS")
    success_path = os.path.join(root, "_SUCCESS")
    success = {}
    has_sums = os.path.isfile(sums_path)

    # ---- _SUCCESS ----
    if os.path.isfile(success_path):
        success = parse_success(success_path)
        if success.get("release") and args.release and success["release"] != args.release:
            fail(ctx, "_SUCCESS", "success_binding",
                 f"release={success['release']} != {args.release}")
        want = (success.get("sha256sums") or "").replace("sha256:", "").lower()
        if want:
            actual = sha256_file(sums_path) if has_sums else ""
            if actual != want:
                fail(ctx, "_SUCCESS", "success_binding",
                     "sha256sums 与实际 SHA256SUMS 不符", want, actual)
        want_sizes = (success.get("sizes") or "").replace("sha256:", "").lower()
        sizes_path = os.path.join(root, "SIZES")
        if want_sizes:
            actual = sha256_file(sizes_path) if os.path.isfile(sizes_path) else ""
            if actual != want_sizes:
                fail(ctx, "_SUCCESS", "success_binding",
                     "sizes 与实际 SIZES 不符", want_sizes, actual)
        for key, path in (("files", None), ("bytes", None)):
            if success.get(key):
                try:
                    want_n = int(success[key])
                except ValueError:
                    fail(ctx, "_SUCCESS", "success_binding",
                         f"{key}={success[key]} 不是整数")
                    continue
                if key == "files" and want_n != len(ctx.files):
                    if getattr(args, "skip_missing", False):
                        warn(ctx, f"_SUCCESS.files={want_n} != 当前 {len(ctx.files)}"
                                  "(缺失文件已跳过; 覆盖性检查为准)")
                    else:
                        fail(ctx, "_SUCCESS", "success_binding",
                             f"files={want_n} != 实际 {len(ctx.files)}", want_n, len(ctx.files))
                if key == "bytes" and want_n != ctx.total_bytes:
                    if getattr(args, "skip_missing", False):
                        warn(ctx, f"_SUCCESS.bytes={want_n} != 当前 {ctx.total_bytes}"
                                  "(缺失文件已跳过; 覆盖性检查为准)")
                    else:
                        fail(ctx, "_SUCCESS", "success_binding",
                             f"bytes={want_n} != 实际 {ctx.total_bytes}", want_n, ctx.total_bytes)
    elif layout == "release" and not args.staging:
        fail(ctx, "_SUCCESS", "success_missing", "release 布局缺少 _SUCCESS")
    elif args.require_success:
        fail(ctx, "_SUCCESS", "success_missing", "要求 _SUCCESS 存在")
    elif layout in ("flat", "sealed-dev"):
        warn(ctx, "_SUCCESS 不存在(flat/sealed-dev 兼容)")

    # ---- release.env ----
    env_path = os.path.join(root, "release.env")
    if os.path.isfile(env_path):
        env = parse_env(env_path)
        ver = env.get("RELEASE_VERSION", "")
        if not ver:
            fail(ctx, "release.env", "release_env_version", "缺少 RELEASE_VERSION")
        elif args.release and ver != args.release:
            fail(ctx, "release.env", "release_env_version",
                 f"RELEASE_VERSION={ver} != {args.release}")

    # ---- SHA256SUMS / coverage ----
    if not has_sums:
        if layout == "unsealed-dev" and args.allow_unsealed:
            warn(ctx, "无 SHA256SUMS, 仅做结构检查")
            for rel in ctx.files:
                if os.stat(os.path.join(root, rel)).st_size == 0:
                    fail(ctx, rel, "zero_byte", "0 字节文件")
            ctx.checks["coverage"] = "skipped"
            ctx.checks["metadata"] = "fail" if ctx.failures else "ok"
            return {}
        fail(ctx, "SHA256SUMS", "manifest_missing", "缺少 SHA256SUMS")
        ctx.checks["coverage"] = "fail"
        ctx.checks["metadata"] = "fail"
        return {}

    sums = parse_sha256sums(ctx, sums_path)
    disk = set(ctx.files)
    listed = set(sums)
    for rel in sorted(listed - disk):
        if getattr(args, "skip_missing", False):
            warn(ctx, f"{rel}: 文件不存在或已被删除，已跳过")
            ctx.missing_skipped.append(rel)
            ctx.checks["coverage"] = "warn"
        else:
            fail(ctx, rel, "missing_file", "文件不存在或已被删除(已跳过哈希)")
            ctx.checks["coverage"] = "fail"
    for rel in sorted(disk - listed):
        fail(ctx, rel, "extra_file", "磁盘存在但清单未登记")
        ctx.checks["coverage"] = "fail"
    for rel in sorted(disk & listed):
        st = os.stat(os.path.join(root, rel))
        if st.st_size == 0:
            fail(ctx, rel, "zero_byte", "0 字节文件")
            ctx.checks["coverage"] = "fail"

    # ---- SIZES ----
    sizes_path = os.path.join(root, "SIZES")
    if os.path.isfile(sizes_path):
        sizes = parse_sizes(ctx, sizes_path)
        if set(sizes) != listed:
            fail(ctx, "SIZES", "sizes_set", "SIZES 与 SHA256SUMS 路径集合不一致")
            ctx.checks["sizes"] = "fail"
        for rel in sorted(set(sizes) & disk):
            actual = os.stat(os.path.join(root, rel)).st_size
            if sizes[rel] != actual:
                fail(ctx, rel, "size_mismatch", "文件大小不符", sizes[rel], actual)
                ctx.checks["sizes"] = "fail"
    else:
        ctx.sizes_missing = True

    # ---- release.json ----
    json_path = os.path.join(root, "release.json")
    if os.path.isfile(json_path):
        try:
            data = json.load(open(json_path, encoding="utf-8"))
        except Exception as exc:
            fail(ctx, "release.json", "release_json", f"解析失败: {exc}")
        else:
            if not isinstance(data, dict):
                fail(ctx, "release.json", "release_json", "顶层不是对象")
            else:
                if args.release and data.get("release") and data["release"] != args.release:
                    fail(ctx, "release.json", "release_json",
                         f"release={data['release']} != {args.release}")
                sha = str(data.get("cli_tar_sha256") or "").replace("sha256:", "")
                if sha and not re.fullmatch(r"[0-9a-fA-F]{64}", sha):
                    fail(ctx, "release.json", "release_json", "cli_tar_sha256 格式非法")
                size = data.get("cli_tar_size")
                if size is not None:
                    try:
                        if int(size) <= 0:
                            raise ValueError
                    except (TypeError, ValueError):
                        fail(ctx, "release.json", "release_json", "cli_tar_size 非正整数")

    # ---- permission warnings ----
    for rel in ctx.files:
        st = os.stat(os.path.join(root, rel))
        if not (st.st_mode & 0o444):
            warn(ctx, f"{rel}: 文件无读位(部署用户可能读不到)")

    if any(f["kind"].startswith(("manifest", "missing_file", "extra_file", "zero_byte",
                                  "success_binding", "success_missing", "release_env",
                                  "release_json", "symlink", "temp_file", "not_regular",
                                  "bad_name", "sizes_set", "size_mismatch"))
           for f in ctx.failures):
        ctx.checks["metadata"] = "fail"
    return sums

