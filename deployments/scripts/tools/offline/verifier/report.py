import json
import sys

from .constants import GZ_DEEP_MAX, SCHEMA, TOOL_VERSION

def emit(ctx, args):
    ok = not ctx.failures
    data = {
        "schema": SCHEMA,
        "tool_version": TOOL_VERSION,
        "layout": ctx.layout,
        "root": ctx.root,
        "release": args.release,
        "level": ctx.level,
        "ok": ok,
        "summary": {
            "files": len(ctx.files),
            "checked": len(ctx.files),
            "failed": len(ctx.failures),
            "bytes": ctx.total_bytes,
        },
        "checks": ctx.checks,
        "failures": ctx.failures,
        "warnings": ctx.warnings,
        "large_skipped": ctx.large_skipped,
        "stamp": ctx.stamp_info,
    }
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        _level_note = "（默认：仅结构检查；全量请用 --level full）" if getattr(ctx, "level_defaulted", False) else ""
        print(f"布局: {ctx.layout}  树根: {ctx.root}  级别: {ctx.level}{_level_note}")
        print(f"文件: {len(ctx.files)}  字节: {ctx.total_bytes}")
        for f in ctx.failures[:20]:
            line = f"❌ {f['path']}: {f['message']}"
            if "expected" in f:
                line += f" (期望 {f['expected']} 实际 {f.get('actual', '')})"
            print(line)
        if len(ctx.failures) > 20:
            print(f"  ... 其余 {len(ctx.failures) - 20} 条见 --json")
        for w in ctx.warnings:
            print(f"⚠  {w}")
        if ctx.level == "full" and ctx.large_skipped and not getattr(ctx, "deep", False):
            _mib = GZ_DEEP_MAX // (1024 * 1024)
            print(f"⚠  {len(ctx.large_skipped)} 个大压缩包只做了全量 sha256(未深度解压 >{_mib}MiB):")
            for rel in ctx.large_skipped[:20]:
                print(f"     {rel}")
            if len(ctx.large_skipped) > 20:
                print(f"     ... 其余 {len(ctx.large_skipped) - 20} 个")
            print("   如需确认 tar 成员/内部结构, 请改用: --level full --deep")
        if ctx.stamp_info.get("valid"):
            _stamp_label = "已写入" if ctx.stamp_info.get("reason") == "written" else "有效"
            print(f"✅ 校验戳{_stamp_label}: {ctx.stamp_info.get('path')}")
        print("✅ 校验通过" if ok else "❌ 校验失败")
    return 0 if ok else 1

