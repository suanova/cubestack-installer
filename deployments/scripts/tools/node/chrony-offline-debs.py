#!/usr/bin/env python3
# ============================================================
# chrony-offline-debs.py — chrony 离线 deb 依赖闭包检查/补齐
# ------------------------------------------------------------
# 背景(2026-10-26 实机):
#   master02/worker05-08 的 VM 镜像没有 chrony; setup-ntp.sh 已支持把
#   offline-files/os/packages/chrony/*.deb 推到节点离线安装, 但离线目录
#   只有 chrony 本体 + 部分依赖时, 干净节点仍会因缺依赖失败。
#
# 用法:
#   # 离线机: 只读检查闭包是否完整(不联网)
#   ./chrony-offline-debs.py --check deployments/offline-files/os/packages/chrony
#
#   # 联网的 Ubuntu 22.04 amd64 构建机: 下载缺失依赖并写回目录
#   ./chrony-offline-debs.py --fetch deployments/offline-files/os/packages/chrony
#
#   # 只列出缺失包名
#   ./chrony-offline-debs.py --check --list <dir>
#
# 说明:
#   · 依赖解析覆盖 Depends/Pre-Depends, 支持 | 备选与 Provides 虚拟包;
#   · --fetch 用 apt-get download 取当前仓库版本, 已存在的包名不重复下载;
#     目标节点安装时 install_debs_offline 会跳过已装包(只补缺), 不会无故升级;
#   · 闭包包含 dpkg/tar/perl-base 等基础包; 它们在目标节点通常已装, 只作兜底。
# ============================================================
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile


def die(msg: str, code: int = 1) -> None:
    print(f"【错误】{msg}", file=sys.stderr)
    sys.exit(code)


def need(cmd: str) -> None:
    if not shutil.which(cmd):
        die(f"缺少命令: {cmd}")


def deb_fields(path: str) -> dict:
    try:
        out = subprocess.run(
            ["dpkg-deb", "-f", path, "Package", "Version", "Depends", "Pre-Depends", "Provides"],
            capture_output=True, text=True, check=True,
        ).stdout
    except Exception:
        return {}
    d = {}
    for line in out.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            d[k.strip()] = v.strip()
    return d


def dep_names(s: str):
    """展开 Depends/Pre-Depends/Provides 为候选包名(保留 | 备选顺序)."""
    for alt in s.split(","):
        choices = []
        for choice in alt.split("|"):
            pkg = re.sub(r"\s*\(.*?\)", "", choice).strip()
            pkg = pkg.split(":", 1)[0].strip()
            if pkg and not pkg.startswith("${"):
                choices.append(pkg)
        if choices:
            yield choices


def load_dir(path: str):
    have = {}
    provides = {}
    for p in sorted(glob.glob(os.path.join(path, "*.deb"))):
        f = deb_fields(p)
        name = f.get("Package")
        if not name:
            continue
        have[name] = p
        for choices in dep_names(f.get("Provides", "")):
            for v in choices:
                provides.setdefault(v, name)
    return have, provides


def satisfied(pkg: str, have: dict, provides: dict) -> bool:
    return pkg in have or pkg in provides


def check(path: str, list_only: bool = False) -> int:
    need("dpkg-deb")
    if not os.path.isdir(path):
        die(f"目录不存在: {path}")
    have, provides = load_dir(path)
    if not have:
        die(f"目录里没有 .deb: {path}")
    missing = {}
    for name, deb in have.items():
        f = deb_fields(deb)
        for key in ("Pre-Depends", "Depends"):
            for choices in dep_names(f.get(key, "")):
                if any(satisfied(c, have, provides) for c in choices):
                    continue
                for c in choices:
                    missing.setdefault(c, set()).add(name)
    if not list_only:
        print(f"目录: {path}")
        print(f"deb: {len(glob.glob(os.path.join(path, '*.deb')))}  包: {len(have)}  虚拟 Provides: {len(provides)}")
    if missing:
        if list_only:
            for pkg in sorted(missing):
                print(pkg)
        else:
            print(f"❌ 闭包不完整, 缺失 {len(missing)} 个包:")
            for pkg in sorted(missing):
                print(f"  - {pkg}  (被 {', '.join(sorted(missing[pkg]))} 依赖)")
            print("  联网构建机补齐: ./chrony-offline-debs.py --fetch " + path)
        return 1
    if not list_only:
        print("✅ chrony 离线 deb 依赖闭包完整")
    return 0


def fetch(path: str) -> int:
    need("dpkg-deb")
    need("apt-get")
    os.makedirs(path, exist_ok=True)
    have, provides = load_dir(path)
    if "chrony" not in have:
        # 目录为空时也允许从 chrony 开始
        pass
    todo = []
    for name, deb in have.items():
        f = deb_fields(deb)
        for key in ("Pre-Depends", "Depends"):
            for choices in dep_names(f.get(key, "")):
                if not any(satisfied(c, have, provides) for c in choices):
                    todo.append(choices)
    if not todo and "chrony" not in have:
        todo.append(["chrony"])

    tmp = tempfile.mkdtemp(prefix="chrony-closure-")
    added = []
    seen = set()
    try:
        while todo:
            choices = todo.pop(0)
            key = "|".join(choices)
            if key in seen:
                continue
            seen.add(key)
            if any(satisfied(c, have, provides) for c in choices):
                continue
            ok = False
            for cand in choices:
                r = subprocess.run(["apt-get", "download", cand], cwd=tmp, capture_output=True, text=True)
                if r.returncode != 0:
                    continue
                files = []
                for f in glob.glob(os.path.join(tmp, "*.deb")):
                    ff = deb_fields(f)
                    if ff.get("Package") == cand:
                        files.append(f)
                if not files:
                    continue
                src = max(files, key=os.path.getmtime)
                f = deb_fields(src)
                name = f.get("Package")
                if name in have:
                    ok = True
                    break
                dest = os.path.join(path, os.path.basename(src))
                shutil.copy2(src, dest)
                have[name] = dest
                for ch in dep_names(f.get("Provides", "")):
                    for v in ch:
                        provides.setdefault(v, name)
                added.append(os.path.basename(dest))
                print(f"ADD {os.path.basename(dest)}")
                for k in ("Pre-Depends", "Depends"):
                    for ch in dep_names(f.get(k, "")):
                        if not any(satisfied(c, have, provides) for c in ch):
                            todo.append(ch)
                ok = True
                break
            if not ok:
                print(f"⚠ 无法下载/解析: {' | '.join(choices)}", file=sys.stderr)
        print(f"新增 {len(added)} 个 deb → {path}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return check(path)


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True, description="chrony 离线 deb 依赖闭包检查/补齐")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true", help="只读检查闭包")
    g.add_argument("--fetch", action="store_true", help="联网下载缺失依赖")
    ap.add_argument("--list", action="store_true", help="只输出缺失包名(check 模式)")
    ap.add_argument("dir", help="chrony deb 目录")
    a = ap.parse_args()
    if a.check:
        return check(a.dir, a.list)
    return fetch(a.dir)


if __name__ == "__main__":
    sys.exit(main())
