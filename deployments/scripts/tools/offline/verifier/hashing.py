import concurrent.futures as cf
import json
import os
import sys
import tarfile
import time

from .archive import check_tar
from .constants import HEARTBEAT_SEC
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
        total = len(sums)
        sizes = {}
        for rel in sums:
            try:
                sizes[rel] = os.path.getsize(os.path.join(root, rel))
            except OSError:
                sizes[rel] = 0
        total_bytes = sum(sizes.values())
        # 心跳: 大版本(100+ GiB)全量 sha256 可持续数分钟。没有持续输出时用户容易
        # 误以为进程卡死 → 先给规模/参考耗时, 之后每 10s 打印一次进度(按"时间"
        # 而非文件数, 单个超大文件也能看到进程仍活着)。
        _gib = total_bytes / (1024 ** 3)
        _rate_ref = 400 * 1024 * 1024   # 参考吞吐(SSD/多线程), 仅用于事前估计
        _est = int(total_bytes / _rate_ref) if total_bytes else 0
        _est_txt = f", 预计约 {_est}s(参考)" if _est >= 10 else ""
        _hb_txt = f"{HEARTBEAT_SEC:g}"
        print(f"  ℹ 全量 sha256: {total} 个文件 / {_gib:.1f} GiB{_est_txt}; "
              f"每 {_hb_txt}s 打印进度, 请耐心等待, 不要中断", file=sys.stderr)

        def work(rel):
            try:
                return rel, sha256_file(os.path.join(root, rel)), None
            except Exception as exc:
                return rel, None, exc
        done = 0
        done_bytes = 0
        start = time.time()
        last_tick = start
        with cf.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
            futs = {ex.submit(work, rel): rel for rel in sums}
            for fut in cf.as_completed(futs):
                rel, got, exc = fut.result()
                done += 1
                done_bytes += sizes.get(rel, 0)
                if exc is not None:
                    if rel in _missing:
                        pass  # metadata 已报告/跳过
                    elif isinstance(exc, FileNotFoundError) and getattr(args, "skip_missing", False):
                        warn(ctx, f"{rel}: 文件在校验期间被删除，已跳过")
                    else:
                        fail(ctx, rel, "read_error", f"读取失败: {exc}")
                        ctx.checks["sha256"] = "fail"
                else:
                    want = sums[rel].lower()
                    if got != want:
                        fail(ctx, rel, "sha256_mismatch", "sha256 不符", want, got)
                        ctx.checks["sha256"] = "fail"
                now = time.time()
                if now - last_tick >= HEARTBEAT_SEC or done == total:
                    elapsed = now - start
                    rate = done_bytes / elapsed if elapsed > 0 else 0
                    eta = int((total_bytes - done_bytes) / rate) if rate > 0 else 0
                    print(f"  sha256 {done}/{total} ({elapsed:.0f}s, "
                          f"{rate / (1024 ** 2):.0f} MiB/s, 剩余约 {eta}s)",
                          file=sys.stderr)
                    last_tick = now

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

