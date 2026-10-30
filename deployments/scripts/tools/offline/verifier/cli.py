import argparse
import os
import sys
import tempfile
import time

from .constants import TOOL_VERSION, SCHEMA
from .archive import check_structure
from .context import Ctx, deep_log, warn
from .hashing import check_full
from .layout import collect_files, detect_layout
from .manifest import check_metadata
from .report import emit
from .seal import seal
from .selftest import self_test
from .stamp import stamp_path, stamp_valid, write_stamp

def main():
    ap = argparse.ArgumentParser(
        prog="verify-offline-files.sh",
        description="offline-files 完整性校验器。默认 --level quick(仅结构检查, 会明确提示); "
                    "full 做全量 sha256 + 镜像 depth 校验; quick 下可加 --deep。",
        epilog="退出码: 0=通过 1=完整性失败 2=用法/环境错误",
    )
    default_root = os.path.normpath(os.path.join(
        os.environ.get("CUBESTACK_VERIFY_TOOL_DIR", "."), "../../../offline-files"))
    tool_dir = os.environ.get("CUBESTACK_VERIFY_TOOL_DIR", ".")
    if os.path.basename(os.path.normpath(tool_dir)) == "tools":
        # 发布树副本 <root>/tools/verify-offline-files.sh → 默认树根 = <root>
        default_root = os.path.dirname(os.path.normpath(tool_dir))
    else:
        # 仓库副本 deployments/scripts/tools/offline → deployments/offline-files
        default_root = os.path.normpath(os.path.join(tool_dir, "../../../offline-files"))
    ap.add_argument("--root", default=default_root,
                    help="待校验树根(默认 deployments/offline-files)")
    ap.add_argument("--release", default="", help="release 版本(用于 release.env/CLI tar 校验)")
    ap.add_argument("--cli-tar", default="", help="CLI tar 路径(release 布局可选)")
    ap.add_argument("--layout", default="auto",
                    choices=["auto", "release", "flat", "sealed-dev", "unsealed-dev"],
                    help="布局(默认 auto)")
    ap.add_argument("--level", default=None,
                    choices=["metadata", "quick", "full", "auto"],
                    help="校验级别; 默认 quick(仅结构检查); full=全量 sha256+镜像深度校验; auto 走校验戳")
    ap.add_argument("--deep", action="store_true",
                    help="quick 下也强制深度解压(镜像 layer digest/大 gz CRC); full 已默认 deep")
    ap.add_argument("--deep-log", default="",
                    help="深度校验逐 layer 明细日志(默认: TMPDIR/cubestack-verify-deep-*.log)")
    ap.add_argument("--seal", action="store_true", help="生成/更新 SHA256SUMS + SIZES")
    ap.add_argument("--force", action="store_true", help="seal 覆盖正式树 / 忽略校验戳")
    ap.add_argument("--update-success", action="store_true",
                    help="seal 后同步重写 _SUCCESS(本地修复)")
    ap.add_argument("--json", action="store_true", help="stdout 输出 JSON")
    ap.add_argument("--jobs", type=int, default=4, help="全量哈希并发(默认 4)")
    ap.add_argument("--stamp-file", default="", help="自定义校验戳路径")
    ap.add_argument("--no-stamp", action="store_true", help="不写/不信任校验戳")
    ap.add_argument("--force-full", action="store_true", help="忽略有效校验戳强制 full")
    ap.add_argument("--allow-unsealed", action="store_true", help="无清单时允许仅结构检查")
    ap.add_argument("--skip-missing", dest="skip_missing", action="store_true", default=True,
                    help="清单登记但磁盘缺失的文件仅警告并跳过(默认)")
    ap.add_argument("--fail-missing", dest="skip_missing", action="store_false",
                    help="清单登记但磁盘缺失即失败(部署门禁/fetch 使用)")
    ap.add_argument("--staging", action="store_true", help="允许 _SUCCESS 缺失(staging)")
    ap.add_argument("--require-success", action="store_true", help="要求 _SUCCESS 必须存在")
    ap.add_argument("--require-cli-tar", action="store_true", help="release 布局必须有 CLI tar")
    ap.add_argument("--no-color", action="store_true", help="关闭颜色(当前默认无颜色)")
    ap.add_argument("--version", action="store_true", help="显示版本")
    ap.add_argument("--self-test", action="store_true", help="运行内置自检")
    args = ap.parse_args()
    _level_defaulted = args.level is None
    if _level_defaulted:
        args.level = "quick"
    if args.deep and args.level == "metadata":
        print("❌ --deep 需要 --level quick|full|auto(metadata 不做结构检查)", file=sys.stderr)
        return 2

    if args.version:
        print(f"verify-offline-files {TOOL_VERSION} (schema {SCHEMA})")
        return 0
    if args.self_test:
        return self_test()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print(f"❌ 树根不存在: {root}", file=sys.stderr)
        return 2

    # 便利入口: --root 指向本地桶根时下钻到 <ver>/offline-files
    if args.release:
        candidate = os.path.join(root, args.release, "offline-files")
        if os.path.isdir(candidate):
            root = candidate

    if args.seal:
        return seal(root, args)

    if _level_defaulted:
        print("ℹ 未指定 --level，默认执行 quick 检查(仅结构检查, 不计算全量 sha256); "
              "全量校验请用 --level full[ --deep]", file=sys.stderr)

    ctx = Ctx()
    ctx.root = root
    ctx.layout = detect_layout(root, args.release, args.layout)
    ctx.level = args.level
    ctx.deep = bool(args.deep)
    ctx.level_defaulted = _level_defaulted
    ctx.files = collect_files(ctx, root)
    sums = check_metadata(ctx, root, ctx.layout, args)

    if args.level == "metadata":
        return emit(ctx, args)

    level = args.level
    if level == "auto":
        if ctx.layout == "unsealed-dev":
            level = "quick"
            args.allow_unsealed = True
        else:
            valid, spath, reason = stamp_valid(root, args, sums)
            ctx.stamp_info = {"valid": valid, "path": spath, "reason": reason}
            if valid and not args.force_full and not args.no_stamp:
                ctx.checks["stamp"] = "ok"
                ctx.level = "auto"
                return emit(ctx, args)
            level = "full"
    if level == "full":
        # full 必须能证明镜像可 load: 逐 layer digest + 大 tar.gz 深度检查
        ctx.deep = True
        args.deep = True
    ctx.level = level
    if ctx.deep:
        ctx.deep_log_path = args.deep_log or os.path.join(
            tempfile.gettempdir(),
            f"cubestack-verify-deep-{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}.log")
        deep_log(ctx, f"# {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} root={root} level={level}")
        print(f"ℹ 深度校验明细日志: {ctx.deep_log_path}", file=sys.stderr)
    if level == "quick" and ctx.sizes_missing:
        warn(ctx, "SIZES 缺失: quick 无法检测截断, 建议 --level full")

    if level in ("quick", "full"):
        check_structure(ctx, root, sums)
    if level == "full":
        check_full(ctx, root, sums, args)
        if not ctx.failures and not args.no_stamp and sums and not ctx.missing_skipped:
            try:
                write_stamp(root, args, sums)
                ctx.stamp_info = {"valid": True, "path": stamp_path(root, args), "reason": "written"}
            except OSError as exc:
                warn(ctx, f"写校验戳失败: {exc}")
    return emit(ctx, args)

