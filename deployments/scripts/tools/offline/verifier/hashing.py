import concurrent.futures as cf
import json
import os
import sys
import tarfile
import time

from .archive import check_tar
from .context import fail, warn
from .fsutil import sha256_file

def find_cli_tar(root, args):
    if args.cli_tar:
        return args.cli_tar if os.path.isfile(args.cli_tar) else None
    json_path = os.path.join(root, "release.json")
    if os.path.isfile(json_path):
        try:
            data = json.load(open(json_path, encoding="utf-8"))
            rel = data.get("cli_tar") if isinstance(data, dict) else None
            if rel and not os.path.isabs(rel):
                cand = os.path.normpath(os.path.join(root, rel))
                if os.path.isfile(cand):
                    return cand
        except Exception:
            pass
    if args.release:
        cand = os.path.join(os.path.dirname(root), f"cubestack-installer-cli-v{args.release}.tar")
        if os.path.isfile(cand):
            return cand
    return None

def check_full(ctx, root, sums, args):
    ctx.checks["sha256"] = "ok"
    if sums:
        _missing = set(sums) - set(ctx.files)
        def work(rel):
            try:
                return rel, sha256_file(os.path.join(root, rel)), None
            except Exception as exc:
                return rel, None, exc
        done = 0
        start = time.time()
        with cf.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
            futs = {ex.submit(work, rel): rel for rel in sums}
            for fut in cf.as_completed(futs):
                rel, got, exc = fut.result()
                done += 1
                if exc is not None:
                    if rel in _missing:
                        continue  # metadata 已报告/跳过
                    if isinstance(exc, FileNotFoundError) and getattr(args, "skip_missing", False):
                        warn(ctx, f"{rel}: 文件在校验期间被删除，已跳过")
                        continue
                    fail(ctx, rel, "read_error", f"读取失败: {exc}")
                    ctx.checks["sha256"] = "fail"
                else:
                    want = sums[rel].lower()
                    if got != want:
                        fail(ctx, rel, "sha256_mismatch", "sha256 不符", want, got)
                        ctx.checks["sha256"] = "fail"
                if done % 100 == 0 or done == len(sums):
                    print(f"  sha256 {done}/{len(sums)} ({time.time()-start:.0f}s)", file=sys.stderr)

    # CLI tar
    ctx.checks["cli_tar"] = "ok"
    cli = find_cli_tar(root, args)
    if cli:
        # CLI tar 也是 docker-archive; 能解析时做结构/层校验, 不能解析至少明确 warning
        if tarfile.is_tarfile(cli):
            if not check_tar(ctx, cli, os.path.basename(cli)):
                ctx.checks["cli_tar"] = "fail"
        else:
            warn(ctx, "CLI tar 不是合法 tar(仅做 sha256 校验)")
        json_path = os.path.join(root, "release.json")
        want_sha = want_size = None
        if os.path.isfile(json_path):
            try:
                data = json.load(open(json_path, encoding="utf-8"))
                if isinstance(data, dict):
                    want_sha = str(data.get("cli_tar_sha256") or "").replace("sha256:", "").lower() or None
                    want_size = data.get("cli_tar_size")
            except Exception:
                pass
        if want_size is not None:
            try:
                want_size = int(want_size)
            except (TypeError, ValueError):
                want_size = None
        if want_size is not None and os.path.getsize(cli) != want_size:
            fail(ctx, os.path.basename(cli), "cli_tar", "CLI tar 大小不符",
                 want_size, os.path.getsize(cli))
            ctx.checks["cli_tar"] = "fail"
        if want_sha:
            got = sha256_file(cli)
            if got != want_sha:
                fail(ctx, os.path.basename(cli), "cli_tar", "CLI tar sha256 不符", want_sha, got)
                ctx.checks["cli_tar"] = "fail"
        elif args.require_cli_tar:
            # 有 --require-cli-tar 时不能只凭 "tar 可解析" 放行: release.json 没给 sha
            # 就无法证明 tar 与发布一致(fail-closed)。
            fail(ctx, os.path.basename(cli), "cli_tar",
                 "release.json 缺少 cli_tar_sha256, 无法校验 CLI tar")
            ctx.checks["cli_tar"] = "fail"
    elif args.require_cli_tar:
        fail(ctx, "cubestack-installer-cli.tar", "cli_tar_missing", "缺少 CLI tar")
        ctx.checks["cli_tar"] = "fail"
    elif args.layout == "release":
        warn(ctx, "CLI tar 不存在(部署不需要, 已跳过)")

    # tree.tar.gz 边车 in full 也已在 structure 做过; 这里只确保 checks 键存在
    ctx.checks.setdefault("tree_tar", "ok")

