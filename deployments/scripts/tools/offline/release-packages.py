#!/usr/bin/env python3
"""Select local release packages from a release tree.

This is public installer code: it only reads the user-provided local release
tree (release.yaml + tree.tsv + payload files). It does not contact the private
release repository, MinIO, or Harbor.

Required packages are always selected. Optional packages are selected with
--with, e.g. --with models,dev-lab or --with all.
"""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")


def die(message: str) -> "NoReturn":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def _safe_tar_listing(path: Path) -> list[str]:
    result = subprocess.run(
        ["tar", "--zstd", "-tf", str(path)], check=True,
        text=True, capture_output=True,
    )
    names = [line for line in result.stdout.splitlines() if line]
    for name in names:
        if name.startswith("/") or ".." in Path(name).parts:
            die(f"{path}: unsafe archive path {name!r}")
    return names


def extract_tar_zst(path: Path, dest: Path) -> None:
    _safe_tar_listing(path)
    dest.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["tar", "--zstd", "-xf", str(path), "-C", str(dest)],
        check=True,
    )


def load_yaml(path: Path) -> dict:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        die(f"{path}: expected a YAML mapping")
    return data


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, required=True,
                    help="local release tree root")
    ap.add_argument("--meta", type=Path,
                    help="meta tar.zst to extract into --meta-dir")
    ap.add_argument("--meta-dir", type=Path,
                    help="meta extraction dir (default: <root>/offline-files)")
    ap.add_argument("--extract", action="store_true",
                    help="extract selected payload packages into --root")
    ap.add_argument("--seal", action="store_true",
                    help="reseal the filtered tree with verify-offline-files.sh")
    ap.add_argument("--with", dest="with_packages", default="",
                    help="optional packages: comma-separated names or 'all'")
    ap.add_argument("--verify-only", action="store_true",
                    help="verify packages but do not write a filtered tree")
    ap.add_argument("--list", action="store_true",
                    help="print selected package names")
    ap.add_argument("--write-tree", type=Path,
                    help="write filtered tree.tsv to this path")
    args = ap.parse_args()

    root = args.root
    meta_dir = args.meta_dir or (root / "offline-files" if args.meta else root)
    if args.meta:
        sidecar = Path(str(args.meta) + ".sha256")
        if sidecar.is_file():
            want = sidecar.read_text(encoding="utf-8").split()[0]
            got = sha256(args.meta).removeprefix("sha256:")
            if want != got:
                die(f"meta sha256 mismatch: expected {want}, got {got}")
        extract_tar_zst(args.meta, meta_dir)
    manifest_path = meta_dir / "release.yaml"
    if not manifest_path.is_file():
        die(f"missing release.yaml: {manifest_path}")
    manifest = load_yaml(manifest_path)
    packages = manifest.get("packages")
    if not packages:
        print("legacy: release.yaml has no packages[]; use the full tree")
        return 0
    if not isinstance(packages, list):
        die("release.yaml: packages must be a list")

    by_name = {}
    required = set()
    optional = set()
    for item in packages:
        name = str(item.get("name", "")).strip()
        if not name:
            die("release.yaml: package has no name")
        if name in by_name:
            die(f"release.yaml: duplicate package {name}")
        by_name[name] = item
        (required if item.get("required") else optional).add(name)

    requested = set()
    raw = str(args.with_packages or "").strip()
    if raw:
        values = [item.strip() for item in raw.split(",") if item.strip()]
        if "all" in values:
            requested |= optional
        else:
            unknown = sorted(set(values) - set(by_name))
            if unknown:
                die(f"unknown package(s): {', '.join(unknown)}")
            requested |= set(values) - required

    selected = required | requested
    for name in sorted(selected):
        item = by_name[name]
        rel = str(item.get("path", "")).strip()
        if not rel:
            die(f"package {name}: path is required")
        path = root / rel
        if not path.is_file():
            die(f"package {name}: missing local payload: {path}")
        want = str(item.get("sha256", "")).strip()
        if not want.startswith("sha256:"):
            die(f"package {name}: invalid sha256")
        got = sha256(path)
        if got != want:
            die(f"package {name}: sha256 mismatch: expected {want}, got {got}")
        size = item.get("size")
        if size not in (None, 0) and path.stat().st_size != int(size):
            die(f"package {name}: size mismatch")

    if args.extract:
        for name in sorted(selected):
            item = by_name[name]
            rel = str(item["path"])
            extract_tar_zst(root / rel, root)
    tree_path = meta_dir / "tree.tsv"
    if tree_path.is_file() and (args.write_tree or not args.verify_only or args.extract):
        lines = tree_path.read_text(encoding="utf-8").splitlines()
        header = lines[0].split("\t") if lines else []
        if "package" not in header:
            die("tree.tsv has no package column")
        package_idx = header.index("package")
        rows = []
        for line in lines[1:]:
            if not line.strip():
                continue
            values = line.split("\t")
            package = values[package_idx]
            if package and package not in by_name:
                die(f"tree.tsv row has unknown package: {package}")
            if package in selected:
                rows.append(values)
        target_tree = args.write_tree or (
            tree_path if args.extract else None
        )
        if target_tree:
            target_tree.parent.mkdir(parents=True, exist_ok=True)
            with target_tree.open("w", encoding="utf-8") as fh:
                fh.write("\t".join(header) + "\n")
                for values in rows:
                    fh.write("\t".join(values) + "\n")
            if args.extract and target_tree == tree_path and args.seal:
                verifier = (
                    Path(__file__).resolve().parents[1]
                    / "offline" / "verify-offline-files.sh"
                )
                subprocess.run(
                    ["bash", str(verifier), "--root", str(meta_dir),
                     "--seal", "--force", "--update-success"],
                    check=True,
                )
            print(f"selected={len(rows)} tree={target_tree}")
        else:
            print(f"selected={len(rows)} packages={','.join(sorted(selected))}")
    elif args.list:
        print("\n".join(sorted(selected)))
    else:
        print(f"selected packages={','.join(sorted(selected))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
