#!/usr/bin/env python3
"""Resolve versions/base.yaml against the mirror catalog.

The resolver is the only place that maps a baseline image entry to a concrete
Harbor reference. It expands ${VAR} from the environment (cluster defaults,
profile, deployment env), looks up the mirror catalog, and emits a deterministic
JSON plan for the materializer.

OS packages are intentionally absent: they are a pre-install check, not a
download/install input.
"""

from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import sys
from pathlib import Path
from typing import NoReturn

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")

VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")


def fail(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_yaml(path: Path) -> dict:
    if not path.is_file():
        fail(f"file not found: {path}")
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        fail(f"{path}: expected a YAML mapping")
    return data


def expand(value: str, env: dict[str, str], where: str) -> str:
    def repl(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in env or env[name] == "":
            fail(f"{where}: undefined variable ${{{name}}}")
        return env[name]

    return VAR_RE.sub(repl, value)


def safe_join(dest: str, name: str, where: str) -> str:
    if dest.startswith("/") or name.startswith("/"):
        fail(f"{where}: dest/tar must be relative paths")
    path = posixpath.normpath(posixpath.join(dest, name))
    if path.startswith("../") or path == "..":
        fail(f"{where}: dest/tar escapes the tree: {path}")
    return path


def load_catalog(path: Path) -> dict[str, dict]:
    index = load_yaml(path)
    images = index.get("images")
    if not isinstance(images, list) or not images:
        fail(f"{path}: images[] is empty")
    catalog: dict[str, dict] = {}
    for entry in images:
        image_id = str(entry.get("id", "")).strip()
        if not image_id:
            fail(f"{path}: image entry without id")
        if image_id in catalog:
            fail(f"{path}: duplicate catalog id: {image_id}")
        catalog[image_id] = entry
    return catalog


def resolve_image(image: dict, catalog: dict[str, dict], env: dict[str, str],
                  index: int) -> dict:
    where = f"images[{index}]"
    key = str(image.get("key", "")).strip()
    if not key:
        fail(f"{where}: key is required")

    catalog_id = str(image.get("catalog_id", "")).strip()
    source_ref = str(image.get("source_ref", "")).strip()
    if bool(catalog_id) == bool(source_ref):
        fail(f"{where} ({key}): exactly one of catalog_id or source_ref is required")

    version = expand(str(image.get("version", "")).strip(), env, f"{where} ({key}) version")
    dest = expand(str(image.get("dest", "")).strip(), env, f"{where} ({key}) dest")
    tar = expand(str(image.get("tar", "")).strip(), env, f"{where} ({key}) tar")
    if not version or not dest or not tar:
        fail(f"{where} ({key}): version/dest/tar must not be empty")

    resolved = {
        "key": key,
        "version": version,
        "dest": dest,
        "tar": tar,
        "path": safe_join(dest, tar, where),
    }

    if catalog_id:
        entry = catalog.get(catalog_id)
        if entry is None:
            fail(f"{where} ({key}): catalog_id not found in index: {catalog_id}")
        scope = str(entry.get("scope", "")).strip()
        if scope != "base":
            fail(f"{where} ({key}): catalog scope must be 'base', got {scope!r}")
        source = str(entry.get("source", "")).strip()
        target = str(entry.get("target", "")).strip()
        if not source or not target:
            fail(f"{where} ({key}): catalog entry lacks source/target")
        match = next(
            (item for item in entry.get("versions") or []
             if str(item.get("tag", "")) == version),
            None,
        )
        if match is None:
            tags = ", ".join(str(v.get("tag", "")) for v in entry.get("versions") or [])
            fail(f"{where} ({key}): version {version!r} not in catalog {catalog_id} "
                 f"(available: {tags or 'none'})")
        digest = str(match.get("digest", "")).strip()
        if not DIGEST_RE.match(digest):
            fail(f"{where} ({key}): invalid digest for {version}: {digest!r}")
        platforms = match.get("platforms") or []
        if platforms and "linux/amd64" not in platforms:
            fail(f"{where} ({key}): {version} has no linux/amd64 platform "
                 f"(available: {', '.join(platforms)})")
        resolved.update({
            "catalog_id": catalog_id,
            "source": source,
            "target": target,
            "digest": digest,
            "ref": f"{target}@{digest}",
            "repo_tag": f"{source}:{version}",
        })
    else:
        if not source_ref.startswith("harbor.isuanova.com/"):
            fail(f"{where} ({key}): source_ref must be a public Harbor ref: {source_ref}")
        resolved.update({
            "source_ref": source_ref,
            "source": source_ref,
            "target": source_ref,
            "digest": None,
            "ref": f"{source_ref}:{version}",
            "repo_tag": f"{source_ref}:{version}",
        })

    return resolved


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--baseline", type=Path, default=Path("versions/base.yaml"))
    ap.add_argument("--index", type=Path, required=True,
                    help="container-image-mirror index.json")
    args = ap.parse_args()

    baseline = load_yaml(args.baseline)
    if baseline.get("schema") != 1:
        fail(f"{args.baseline}: schema must be 1")

    kubespray = baseline.get("kubespray") or {}
    kubespray_version = str(kubespray.get("version", "")).strip()
    if not kubespray_version:
        fail(f"{args.baseline}: kubespray.version is required")

    env = dict(os.environ)
    if not env.get("KUBESPRAY_VERSION"):
        env["KUBESPRAY_VERSION"] = kubespray_version

    catalog = load_catalog(args.index)
    images = baseline.get("images") or []
    if not images:
        fail(f"{args.baseline}: images[] is empty")

    resolved = [resolve_image(image, catalog, env, i)
                for i, image in enumerate(images)]

    plan = {
        "schema": 1,
        "baseline": str(args.baseline),
        "catalog": str(args.index),
        "catalog_commit": (load_yaml(args.index).get("commit")),
        "kubespray": {
            "version": kubespray_version,
            "source": kubespray.get("source") or {},
        },
        "os": baseline.get("os") or [],
        "images": resolved,
    }
    json.dump(plan, sys.stdout, indent=2, sort_keys=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
