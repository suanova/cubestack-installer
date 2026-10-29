import concurrent.futures as cf
import os
import shutil
import sys
import time

from .constants import TEMP_RE
from .fsutil import norm_rel, is_meta, parse_env, sha256_file

def seal(root, args):
    success_version = args.release
    if args.update_success:
        if not success_version and os.path.isfile(os.path.join(root, "release.env")):
            success_version = parse_env(os.path.join(root, "release.env")).get("RELEASE_VERSION", "")
        if not success_version:
            print("❌ --update-success 需要 --release 或 release.env 的 RELEASE_VERSION", file=sys.stderr)
            return 2
    problems = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for d in dirnames:
            full = os.path.join(dirpath, d)
            if os.path.islink(full):
                problems.append(f"符号链接: {norm_rel(os.path.relpath(full, root))}")
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = norm_rel(os.path.relpath(full, root))
            if is_meta(rel):
                continue
            if "\n" in rel or "\r" in rel:
                problems.append(f"文件名含换行: {rel!r}")
            elif os.path.islink(full):
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
    files = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = norm_rel(os.path.relpath(full, root))
            if not is_meta(rel):
                files.append(rel)
    files.sort()
    sums = {}
    sizes = {}
    def _seal_one(rel):
        path = os.path.join(root, rel)
        return rel, sha256_file(path), os.path.getsize(path)
    done = 0
    start = time.time()
    with cf.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
        for rel, sha, size in ex.map(_seal_one, files):
            sums[rel] = sha
            sizes[rel] = size
            done += 1
            if done % 100 == 0 or done == len(files):
                print(f"  seal {done}/{len(files)} ({time.time()-start:.0f}s)", file=sys.stderr)
    backup = os.path.join(root, ".cubestack-manifest-backup",
                          time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(backup, exist_ok=True)
    for name in ("SHA256SUMS", "SIZES"):
        src = os.path.join(root, name)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(backup, name))
    tmp_s = os.path.join(root, f".cubestack-SHA256SUMS.tmp.{os.getpid()}")
    tmp_z = os.path.join(root, f".cubestack-SIZES.tmp.{os.getpid()}")
    with open(tmp_s, "w", encoding="utf-8") as f:
        for rel in files:
            f.write(f"{sums[rel]}  ./{rel}\n")
    with open(tmp_z, "w", encoding="utf-8") as f:
        for rel in files:
            f.write(f"{sizes[rel]}  ./{rel}\n")
    os.replace(tmp_s, os.path.join(root, "SHA256SUMS"))
    os.replace(tmp_z, os.path.join(root, "SIZES"))
    success_path = os.path.join(root, "_SUCCESS")
    if args.update_success:
        tmp_success = f"{success_path}.tmp.{os.getpid()}"
        with open(tmp_success, "w", encoding="utf-8") as f:
            f.write(f"release={success_version}\n")
            f.write(f"built_at={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
            f.write(f"sha256sums={sha256_file(os.path.join(root, 'SHA256SUMS'))}\n")
            f.write(f"sizes={sha256_file(os.path.join(root, 'SIZES'))}\n")
            f.write(f"files={len(files)}\n")
            f.write(f"bytes={sum(sizes.values())}\n")
        os.replace(tmp_success, success_path)
        print(f"✅ 已更新 _SUCCESS(release={success_version}, files={len(files)})")
    elif os.path.isfile(success_path):
        print("⚠ _SUCCESS 未更新: 校验会因 sha256sums 绑定不符失败; 需要时加 --update-success", file=sys.stderr)
    print(f"✅ 已生成 SHA256SUMS({len(files)} 项) + SIZES")
    return 0

