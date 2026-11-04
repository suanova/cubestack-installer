#!/usr/bin/env python3
"""Validate the public base baseline (versions/base.yaml) and OS check manifest.

The baseline is the public source of truth for base versions: kubespray, the
pre-install OS package check, and the base image set. It is consumed by:
  - cubestack-installer open-source online install (read directly)
  - cubestack-release (read at a pinned installer commit) for commercial packaging

OS packages are a pre-install check only. The installer verifies that the listed
packages exist on the nodes; it does not download or install them.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")

VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
KEY_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*:[a-z0-9][a-z0-9._/-]*$")


def load_yaml(path: Path) -> dict:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"{path}: expected a YAML mapping")
    return data


def defaults_keys(path: Path) -> set[str]:
    keys: set[str] = set()
    if not path.is_file():
        return keys
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^\s*([A-Z][A-Z0-9_]*)=", line)
        if m:
            keys.add(m.group(1))
    return keys


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    ap.add_argument("--baseline", type=Path, default=None)
    ap.add_argument("--defaults", type=Path, default=None)
    ap.add_argument("--mirror-index", type=Path, default=None,
                    help="optional container-image-mirror index.json for catalog checks")
    args = ap.parse_args()
    root = args.root
    baseline_path = args.baseline or root / "versions/base.yaml"
    defaults_path = args.defaults or root / "deployments/config/cluster.defaults.conf"

    errors: list[str] = []
    baseline = load_yaml(baseline_path)
    if baseline.get("schema") != 1:
        errors.append("schema must be 1")

    kubespray = baseline.get("kubespray") or {}
    if not str(kubespray.get("version", "")).strip():
        errors.append("kubespray.version is required")

    mirror = baseline.get("mirror") or {}
    for field in ("repo", "commit", "path"):
        if not str(mirror.get(field, "")).strip():
            errors.append(f"mirror.{field} is required")
    if mirror.get("commit") and not re.match(r"^[0-9a-f]{7,40}$", str(mirror["commit"])):
        errors.append("mirror.commit must be a 7-40 character hex commit")

    env = baseline.get("env") or {}
    if not isinstance(env, dict) or not env:
        errors.append("env must be a non-empty mapping")
        env = {}
    for key, value in env.items():
        if not re.match(r"^[A-Z_][A-Z0-9_]*$", str(key)):
            errors.append(f"env: invalid key {key!r}")
        if not str(value).strip():
            errors.append(f"env: {key} must not be empty")
    known_vars = {str(k) for k in env}

    os_entries = baseline.get("os") or []
    if not os_entries:
        errors.append("os[] must contain at least one entry")
    for idx, entry in enumerate(os_entries):
        where = f"os[{idx}]"
        for field in ("family", "id", "version", "packages_check"):
            if not str(entry.get(field, "")).strip():
                errors.append(f"{where}: {field} is required")
        lock_rel = str(entry.get("packages_check", "")).strip()
        if not lock_rel:
            continue
        lock_path = root / lock_rel
        if not lock_path.is_file():
            errors.append(f"{where}: packages_check not found: {lock_rel}")
            continue
        try:
            lock = load_yaml(lock_path)
        except SystemExit as exc:
            errors.append(f"{where}: {exc}")
            continue
        for field in ("family", "id", "version"):
            if str(lock.get(field, "")) != str(entry.get(field, "")):
                errors.append(f"{lock_rel}: {field}={lock.get(field)!r} != os entry {entry.get(field)!r}")
        packages = lock.get("packages") or {}
        if not isinstance(packages, dict) or not packages:
            errors.append(f"{lock_rel}: packages must be a non-empty mapping")
        else:
            for group, entries in packages.items():
                if not isinstance(entries, dict) or not entries:
                    errors.append(f"{lock_rel}: packages.{group} must be a non-empty mapping")
                    continue
                for pkg, ver in entries.items():
                    if not str(pkg).strip() or not str(ver).strip():
                        errors.append(f"{lock_rel}: packages.{group} has an empty name/version")

    files = baseline.get("files") or []
    file_keys: set[str] = set()
    file_paths: set[str] = set()
    for idx, item in enumerate(files):
        where = f"files[{idx}]"
        key = str(item.get("key", "")).strip()
        path = str(item.get("path", "")).strip()
        source = item.get("source") or {}
        if not key:
            errors.append(f"{where}: key is required")
        elif key in file_keys:
            errors.append(f"{where}: duplicate key {key!r}")
        else:
            file_keys.add(key)
        if not path:
            errors.append(f"{where}: path is required")
        elif path in file_paths:
            errors.append(f"{where}: duplicate path {path!r}")
        else:
            file_paths.add(path)
        kind = str(source.get("type", "")).strip()
        if kind == "git":
            for field in ("repo", "ref"):
                if not str(source.get(field, "")).strip():
                    errors.append(f"{where}: git source requires {field}")
        elif kind == "url":
            if not str(source.get("url", "")).strip():
                errors.append(f"{where}: url source requires url")
        elif kind == "local":
            if not str(source.get("path", "")).strip():
                errors.append(f"{where}: local source requires path")
        else:
            errors.append(f"{where}: source.type must be git|url|local")
        digest = str(item.get("digest", "")).strip()
        if digest and not re.match(r"^sha256:[0-9a-f]{64}$", digest):
            errors.append(f"{where}: invalid digest {digest!r}")
        mode = str(item.get("mode", "0644"))
        if not re.match(r"^[0-7]{4}$", mode):
            errors.append(f"{where}: mode must be 4 octal digits")

    images = baseline.get("images") or []
    if not images:
        errors.append("images[] must contain at least one entry")
    keys: set[str] = set()
    tars: set[str] = set()
    catalog_ids: set[str] = set()
    for idx, img in enumerate(images):
        where = f"images[{idx}]"
        key = str(img.get("key", "")).strip()
        if not key:
            errors.append(f"{where}: key is required")
        elif key in keys:
            errors.append(f"{where}: duplicate key {key!r}")
        else:
            keys.add(key)
        if not KEY_RE.match(key):
            errors.append(f"{where}: key must look like <group>:<source> (got {key!r})")
        catalog_id = str(img.get("catalog_id", "")).strip()
        source_ref = str(img.get("source_ref", "")).strip()
        if bool(catalog_id) == bool(source_ref):
            errors.append(f"{where}: exactly one of catalog_id or source_ref is required")
        if catalog_id:
            catalog_ids.add(catalog_id)
            if not re.match(r"^[a-z0-9-]+/[a-z0-9][a-z0-9._-]*$", catalog_id):
                errors.append(f"{where}: catalog_id must look like <category>/<name> (got {catalog_id!r})")
        if source_ref and not source_ref.startswith("harbor.isuanova.com/"):
            errors.append(f"{where}: source_ref must be a public Harbor ref, got {source_ref!r}")
        version = str(img.get("version", "")).strip()
        if not version:
            errors.append(f"{where}: version is required")
        elif version == "latest":
            errors.append(f"{where}: version 'latest' is not allowed")
        dest = str(img.get("dest", "")).strip()
        if not dest:
            errors.append(f"{where}: dest is required")
        tar = str(img.get("tar", "")).strip()
        if not tar:
            errors.append(f"{where}: tar is required")
        elif tar in tars:
            errors.append(f"{where}: duplicate tar name {tar!r}")
        else:
            tars.add(tar)
        for field in ("version", "dest", "tar"):
            for var in VAR_RE.findall(str(img.get(field, ""))):
                if var not in known_vars:
                    errors.append(f"{where}: unknown variable ${{{var}}} in {field}")

    if args.mirror_index:
        try:
            index = json.loads(args.mirror_index.read_text(encoding="utf-8"))
            available = {i.get("id") for i in index.get("images") or []}
        except Exception as exc:
            errors.append(f"mirror index: {exc}")
        else:
            for cid in sorted(catalog_ids):
                if cid not in available:
                    errors.append(f"catalog_id not found in mirror index: {cid}")

    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        print(f"\n{len(errors)} problem(s) in {baseline_path}", file=sys.stderr)
        return 1
    print(f"OK: {len(images)} images, {len(os_entries)} OS entry(ies) in {baseline_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
