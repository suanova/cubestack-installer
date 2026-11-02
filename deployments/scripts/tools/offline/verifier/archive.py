import gzip
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile

from .constants import GZ_DEEP_MAX, DATA_EXTS, KNOWN_BINS
from .context import fail, warn, deep_log
from .fsutil import norm_rel, parse_env, sha256_file

def tar_member_names(tf):
    names = set()
    members = {}
    manifest = None
    for m in tf:
        rel = norm_rel(m.name)
        names.add(rel)
        members[rel] = m
        if rel == "manifest.json" and m.isfile():
            try:
                manifest = json.loads(tf.extractfile(m).read().decode("utf-8"))
            except Exception:
                manifest = None
    return names, members, manifest

def hash_layer_member(tf, member):
    f = tf.extractfile(member)
    if f is None:
        raise ValueError("不是普通文件")
    head = f.read(2)
    f.seek(0)
    stream = gzip.GzipFile(fileobj=f) if head == b"\x1f\x8b" else f
    h = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        h.update(chunk)
    return h.hexdigest()

def validate_docker_archive(ctx, tf, members, manifest, rel):
    """验证 docker-archive 的 manifest/config/layer 一致性。

    - manifest.json 必须可解析, 每个条目有 Config/Layers, 成员存在;
    - Config JSON 必须可解析; 有 rootfs.diff_ids 时数量必须等于 Layers;
    - --deep(full 默认) 时逐 layer 计算 sha256 并与 diff_ids 比对。
    """
    if manifest is None:
        if "manifest.json" in members:
            fail(ctx, rel, "image_manifest", "manifest.json 无法解析")
            return False
        return True
    entries = manifest if isinstance(manifest, list) else [manifest]
    ok = True
    for idx, e in enumerate(entries):
        if not isinstance(e, dict):
            fail(ctx, rel, "image_manifest", f"manifest.json 条目 {idx} 不是对象")
            ok = False
            continue
        cfg = e.get("Config")
        layers = e.get("Layers")
        if not cfg or not isinstance(layers, list):
            fail(ctx, rel, "image_manifest", f"manifest.json 条目 {idx} 缺少 Config/Layers")
            ok = False
            continue
        cfg_rel = norm_rel(str(cfg))
        layer_rels = [norm_rel(str(x)) for x in layers]
        if cfg_rel not in members:
            fail(ctx, rel, "image_manifest", f"Config 成员缺失: {cfg_rel}")
            ok = False
            continue
        missing = [x for x in layer_rels if x not in members]
        if missing:
            fail(ctx, rel, "tar_layers",
                 f"docker-archive 引用成员缺失: {', '.join(missing[:5])}")
            ok = False
            continue
        try:
            cfg_data = json.loads(tf.extractfile(members[cfg_rel]).read().decode("utf-8"))
        except Exception as exc:
            fail(ctx, rel, "image_config", f"Config 解析失败: {exc}")
            ok = False
            continue
        diff_ids = (cfg_data.get("rootfs") or {}).get("diff_ids") if isinstance(cfg_data, dict) else None
        if diff_ids is None:
            warn(ctx, f"{rel}: config 缺少 rootfs.diff_ids, 跳过 layer digest 校验")
            continue
        if not isinstance(diff_ids, list) or len(diff_ids) != len(layer_rels):
            deep_log(ctx, f"[{rel}] config diff_ids mismatch: {len(diff_ids) if isinstance(diff_ids, list) else '?'} != {len(layer_rels)}")
            fail(ctx, rel, "image_config",
                 f"rootfs.diff_ids 数量与 Layers 不一致({len(diff_ids) if isinstance(diff_ids, list) else '?'} != {len(layer_rels)})")
            ok = False
            continue
        if ctx.deep:
            _n = len(layer_rels)
            _tty = sys.stderr.isatty()
            _cols = shutil.get_terminal_size(fallback=(100, 24)).columns
            def _short(v, width):
                return v if len(v) <= width else "…" + v[-(width - 1):]
            deep_log(ctx, f"[{rel}] archive layers={_n} config={cfg_rel}")
            if not _tty:
                print(f"  deep {rel}: {_n} layers (明细: {ctx.deep_log_path})", file=sys.stderr)
            for i, (layer_rel, did) in enumerate(zip(layer_rels, diff_ids)):
                _mb = members[layer_rel].size / (1024 * 1024)
                if _tty:
                    _barw = 20
                    _filled = int(_barw * (i + 1) / _n) if _n else _barw
                    _bar = "#" * _filled + "-" * (_barw - _filled)
                    _line = (f"  {_short(rel, 48)} [{_bar}] {i + 1}/{_n} "
                             f"{_short(os.path.basename(layer_rel), 22)} ({_mb:.1f} MiB)")
                    print("\r\033[K" + _line[:_cols - 1], end="", file=sys.stderr, flush=True)
                # 无论是否 TTY, 每个 layer 都要做 digest 校验; 明细写日志, 终端不刷 layer 行
                want = str(did).replace("sha256:", "").lower()
                if not re.fullmatch(r"[0-9a-f]{64}", want):
                    fail(ctx, rel, "image_config", f"diff_ids[{i}] 格式非法: {did}")
                    ok = False
                    continue
                try:
                    got = hash_layer_member(tf, members[layer_rel])
                except Exception as exc:
                    fail(ctx, rel, "image_layer", f"layer {layer_rel} 读取失败: {exc}")
                    ok = False
                    continue
                status = "OK" if got == want else "FAIL"
                deep_log(ctx, f"[{rel}] layer {i + 1}/{_n} {layer_rel} size={members[layer_rel].size} "
                                f"expected=sha256:{want} actual=sha256:{got} {status}")
                if got != want:
                    fail(ctx, rel, "image_layer", f"layer {layer_rel} digest 不符", want, got)
                    ok = False
            if _tty:
                print(f"\r\033[K  deep {rel}: {_n}/{_n} layers done", file=sys.stderr)
            else:
                print(f"  deep {rel}: done ({_n}/{_n})", file=sys.stderr)
    return ok

def check_tar(ctx, path, rel):
    size = os.path.getsize(path)
    if size == 0:
        fail(ctx, rel, "tar_invalid", "tar 为空")
        return False
    tail_ok = False
    try:
        with open(path, "rb") as f:
            if size >= 1024:
                f.seek(-1024, os.SEEK_END)
                tail_ok = f.read(1024) == b"\0" * 1024
    except OSError:
        pass
    try:
        with tarfile.open(path, "r:") as tf:
            _names, members, manifest = tar_member_names(tf)
            if not validate_docker_archive(ctx, tf, members, manifest, rel):
                return False
    except Exception as exc:
        fail(ctx, rel, "tar_truncated" if not tail_ok else "tar_invalid",
             f"tar 解析失败: {exc}")
        return False
    return True

def check_compressed(ctx, path, rel):
    size = os.path.getsize(path)
    if size < 18:
        fail(ctx, rel, "gzip_invalid", "压缩包过小")
        return False
    with open(path, "rb") as f:
        magic = f.read(2)
        f.seek(-8, os.SEEK_END)
        footer = f.read(8)
    if magic != b"\x1f\x8b" or len(footer) != 8:
        fail(ctx, rel, "gzip_invalid", "gzip 魔数/页脚缺失")
        return False
    if size <= GZ_DEEP_MAX or ctx.deep:
        try:
            with tarfile.open(path, "r:gz") as tf:
                names, members, manifest = tar_member_names(tf)
                if (manifest is not None or "manifest.json" in members) \
                   and not validate_docker_archive(ctx, tf, members, manifest, rel):
                    return False
            chart_rel = next((n for n in names if os.path.basename(n) == "Chart.yaml"), None)
            base = os.path.basename(rel).lower()
            is_docker = manifest is not None or "manifest.json" in members
            chart_like = not is_docker and ("/charts/" in f"/{rel}" or "/helm/" in f"/{rel}" or "operator" in base)
            if chart_like and not chart_rel:
                fail(ctx, rel, "chart_invalid", "chart 缺少 Chart.yaml")
                return False
            if chart_rel and "/cubestack-operator/charts/" in f"/{rel}" \
               and os.path.isfile(os.path.join(ctx.root, "release.env")):
                env = parse_env(os.path.join(ctx.root, "release.env"))
                want = env.get("CUBESTACK_OPERATOR_CHART_VERSION", "")
                expected = f"cubestack-operator-chart-{want}.tgz" if want else ""
                if want and os.path.basename(rel) != expected:
                    warn(ctx, f"{rel}: 非 release.env 指定的 chart 版本 {want}(陈旧文件, 可删除)")
                elif want:
                    chart = read_chart_yaml(path)
                    if chart.get("version") and chart["version"] != want:
                        fail(ctx, rel, "chart_invalid",
                             f"Chart.yaml version={chart['version']} != {want}")
                        return False
        except Exception as exc:
            fail(ctx, rel, "gzip_invalid", f"gzip/tar 解析失败: {exc}")
            return False
    else:
        ctx.large_skipped.append(rel)
        if ctx.level == "quick":
            _mib = GZ_DEEP_MAX // (1024 * 1024)
            warn(ctx, f"{rel}: >{_mib}MiB, quick 未深度解压(建议 --level full --deep)")
    return True

def check_gzip_only(ctx, path, rel):
    """普通 .gz(不是 tar.gz): gzip 魔数/页脚 + CRC 校验。

    - <= GZ_DEEP_MAX 或 --deep: 完整解压以验证 CRC/ISIZE;
    - quick 且超过阈值: 只查魔数/页脚并提示 --deep;
    - full 且超过阈值: 字节由 sha256 覆盖, 不重复解压。
    """
    size = os.path.getsize(path)
    if size < 18:
        fail(ctx, rel, "gzip_invalid", "gzip 文件过小")
        return False
    with open(path, "rb") as f:
        magic = f.read(2)
    if magic != b"\x1f\x8b":
        fail(ctx, rel, "gzip_invalid", "gzip 魔数缺失")
        return False
    if size > GZ_DEEP_MAX and not ctx.deep:
        ctx.large_skipped.append(rel)
        if ctx.level == "quick":
            _mib = GZ_DEEP_MAX // (1024 * 1024)
            warn(ctx, f"{rel}: >{_mib}MiB, quick 未做 gzip CRC(建议 --deep)")
        return True
    try:
        with gzip.open(path, "rb") as g:
            while g.read(1024 * 1024):
                pass
    except Exception as exc:
        fail(ctx, rel, "gzip_invalid", f"gzip CRC/解压失败: {exc}")
        return False
    return True

def read_chart_yaml(path):
    try:
        with tarfile.open(path, "r:gz") as tf:
            for m in tf:
                if os.path.basename(norm_rel(m.name)) == "Chart.yaml" and m.isfile():
                    text = tf.extractfile(m).read().decode("utf-8", "replace")
                    out = {}
                    for line in text.splitlines():
                        if ":" in line and not line.lstrip().startswith("#"):
                            k, v = line.split(":", 1)
                            out[k.strip()] = v.strip().strip('"').strip("'")
                    return out
    except Exception:
        pass
    return {}

def is_binary_name(path, rel):
    base = os.path.basename(rel)
    if base.endswith(DATA_EXTS) or base.endswith(".sha256"):
        return False
    if base.endswith(".run"):
        return True
    if base in KNOWN_BINS:
        return True
    return os.access(path, os.X_OK) and "." not in base

def check_elf_or_shebang(ctx, path, rel):
    with open(path, "rb") as f:
        head = f.read(4)
    if head != b"\x7fELF" and not head.startswith(b"#!"):
        fail(ctx, rel, "binary_invalid", "不是 ELF/shebang 可执行文件")
        return False
    if not (os.stat(path).st_mode & 0o111):
        if rel.lower().endswith(".run"):
            warn(ctx, f"{rel}: 缺少可执行位(run 模式会跳过, tar 模式不受影响)")
            return True
        fail(ctx, rel, "binary_invalid", "缺少可执行位")
        return False
    return True

def check_operator_chart_presence(ctx, root):
    env_path = os.path.join(root, "release.env")
    if not os.path.isfile(env_path):
        return
    env = parse_env(env_path)
    want = env.get("CUBESTACK_OPERATOR_CHART_VERSION", "")
    if not want:
        return
    # 不能因为 cubestack-operator/charts/ 目录不存在就跳过: release.env 声明了 chart 版本,
    # 部署就必须用到它(module 25 缺 chart 直接 err), 目录整体缺失同样是"缺少该 chart"。
    expected = os.path.join("cubestack-operator", "charts",
                            f"cubestack-operator-chart-{want}.tgz")
    if expected not in ctx.files:
        fail(ctx, expected, "chart_missing",
             f"release.env 要求 CUBESTACK_OPERATOR_CHART_VERSION={want}, 但树内缺少该 chart")
        ctx.checks["structure"] = "fail"

def check_structure(ctx, root, sums):
    ctx.checks["structure"] = "ok"
    check_operator_chart_presence(ctx, root)
    for rel in ctx.files:
        path = os.path.join(root, rel)
        low = rel.lower()
        if not os.path.isfile(path):
            continue
        ok = True
        if low.endswith(".tar"):
            ok = check_tar(ctx, path, rel)
        elif low.endswith((".tar.gz", ".tgz")):
            ok = check_compressed(ctx, path, rel)
        elif low.endswith(".gz"):
            ok = check_gzip_only(ctx, path, rel)
        elif low.endswith(".deb"):
            ok = check_magic(ctx, path, rel, b"!<arch>\n", "deb_invalid")
        elif low.endswith(".qcow2"):
            ok = check_magic(ctx, path, rel, b"QFI\xfb", "qcow2_invalid")
        elif is_binary_name(path, rel):
            ok = check_elf_or_shebang(ctx, path, rel)
        if low.endswith("tree.tar.gz"):
            side = path + ".sha256"
            if os.path.isfile(side):
                want = open(side, encoding="utf-8", errors="replace").read().strip().split()
                want = want[0].lower() if want else ""
                got = sha256_file(path)
                if want and want != got:
                    fail(ctx, rel, "tree_sha_mismatch", "tree.tar.gz 与 .sha256 不符", want, got)
                    ok = False
            else:
                warn(ctx, f"{rel}: 缺少 tree.tar.gz.sha256")
        if not ok:
            ctx.checks["structure"] = "fail"
    if any(f["kind"] in {"tar_invalid", "tar_truncated", "tar_layers", "gzip_invalid",
                          "chart_invalid", "binary_invalid", "deb_invalid",
                          "qcow2_invalid", "tree_sha_mismatch"}
           for f in ctx.failures):
        ctx.checks["structure"] = "fail"

def check_magic(ctx, path, rel, magic, kind):
    with open(path, "rb") as f:
        head = f.read(len(magic))
    if head != magic:
        fail(ctx, rel, kind, "魔数不符")
        return False
    return True

