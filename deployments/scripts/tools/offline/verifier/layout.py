import os
import stat

from .constants import TEMP_RE
from .context import fail
from .fsutil import norm_rel, is_meta

def detect_layout(root, release, layout):
    if layout != "auto":
        return layout
    has_env = os.path.isfile(os.path.join(root, "release.env"))
    has_sums = os.path.isfile(os.path.join(root, "SHA256SUMS"))
    if has_env and has_sums:
        return "flat"
    if has_sums:
        return "sealed-dev"
    return "unsealed-dev"

def collect_files(ctx, root):
    out = []
    ctx.total_bytes = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for d in list(dirnames):
            full = os.path.join(dirpath, d)
            if os.path.islink(full):
                fail(ctx, norm_rel(os.path.relpath(full, root)), "symlink", "树内不允许符号链接")
                dirnames.remove(d)
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = norm_rel(os.path.relpath(full, root))
            if "\n" in rel or "\r" in rel:
                fail(ctx, rel.replace("\n", "\\n"), "bad_name", "文件名含换行, 无法纳入清单")
                continue
            if is_meta(rel):
                if os.path.islink(full):
                    fail(ctx, rel, "symlink", "树内不允许符号链接")
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
            ctx.total_bytes += st.st_size
    return sorted(out)

