import argparse
import os
import tempfile

from .archive import check_structure
from .context import Ctx
from .hashing import check_full
from .layout import collect_files
from .manifest import check_metadata
from .seal import seal

def self_test():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "a.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("hello\n")
        rc = seal(d, argparse.Namespace(force=False, update_success=False, release="", jobs=2))
        if rc != 0:
            print("❌ self-test: seal 失败", file=sys.stderr)
            return 1
        ctx = Ctx()
        ctx.root = d
        ctx.layout = "sealed-dev"
        ctx.level = "full"
        ctx.files = collect_files(ctx, d)
        sums = check_metadata(ctx, d, ctx.layout, argparse.Namespace(
            release="", allow_unsealed=False, staging=False, require_success=False))
        check_structure(ctx, d, sums)
        check_full(ctx, d, sums, argparse.Namespace(
            release="", cli_tar="", layout=ctx.layout, require_cli_tar=False, jobs=2))
        if ctx.failures:
            print(f"❌ self-test: 合法树失败 {ctx.failures}", file=sys.stderr)
            return 1
        with open(path, "w", encoding="utf-8") as f:
            f.write("corrupt\n")
        ctx2 = Ctx()
        ctx2.root = d
        ctx2.layout = "sealed-dev"
        ctx2.level = "full"
        ctx2.files = collect_files(ctx2, d)
        check_full(ctx2, d, sums, argparse.Namespace(
            release="", cli_tar="", layout=ctx2.layout, require_cli_tar=False, jobs=2))
        if not ctx2.failures:
            print("❌ self-test: 损坏树未被检出", file=sys.stderr)
            return 1
    print("✅ self-test 通过")
    return 0

