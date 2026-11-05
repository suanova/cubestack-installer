#!/usr/bin/env python3
"""Bump the mirror catalog pin in versions/base.yaml.

Only opens a change when a catalog entry referenced by the baseline changed
(digest/tag/source/target). Platform-only catalog changes are ignored.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

import yaml


def die(message: str) -> "NoReturn":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def fetch_json(repo: str, commit: str, path: str) -> dict:
    url = f"https://raw.githubusercontent.com/{repo}/{commit}/{path}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.loads(resp.read())


def load_index(path: Path | None, repo: str, commit: str,
               index_path: str) -> dict:
    if path is not None:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    return fetch_json(repo, commit, index_path)


def base_entries(index: dict) -> dict[str, dict]:
    entries = {}
    for entry in index.get("images") or []:
        if entry.get("scope") != "base":
            continue
        image_id = str(entry.get("id", "")).strip()
        if image_id:
            entries[image_id] = entry
    return entries


def normalized(entry: dict) -> dict:
    versions = sorted(
        (str(v.get("tag", "")), str(v.get("digest", "")),
         tuple(sorted(v.get("platforms") or [])))
        for v in entry.get("versions") or []
    )
    return {
        "source": entry.get("source"),
        "target": entry.get("target"),
        "versions": versions,
    }


def changed_ids(old: dict, new: dict, referenced: set[str]) -> list[str]:
    old_base = base_entries(old)
    new_base = base_entries(new)
    changed = []
    for image_id in sorted(referenced):
        if image_id not in old_base or image_id not in new_base:
            die(f"catalog id missing from an index: {image_id}")
        if normalized(old_base[image_id]) != normalized(new_base[image_id]):
            changed.append(image_id)
    return changed


def update_pin_text(path: Path, repo: str, commit: str,
                    index_path: str) -> bool:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    in_mirror = False
    seen = set()
    for i, line in enumerate(lines):
        if re.match(r"^mirror:\s*$", line):
            in_mirror = True
            continue
        if not in_mirror:
            continue
        if line.strip() and not line.startswith((" ", "\t")):
            break
        newline = "\n" if line.endswith("\n") else ""
        content = line.rstrip("\n")
        match = re.match(r"^(\s+)(repo|commit|path):(\s*)([^#\s]+)(.*)$", content)
        if not match:
            continue
        key = match.group(2)
        value = {"repo": repo, "commit": commit, "path": index_path}[key]
        if match.group(4) != value:
            lines[i] = (
                f"{match.group(1)}{key}:{match.group(3)}{value}"
                f"{match.group(5)}{newline}"
            )
        seen.add(key)
    if seen != {"repo", "commit", "path"}:
        die(f"{path}: incomplete mirror block")
    new_text = "".join(lines)
    if new_text == path.read_text(encoding="utf-8"):
        return False
    path.write_text(new_text, encoding="utf-8")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path("."))
    ap.add_argument("--repo", default="suanova/container-image-mirror")
    ap.add_argument("--commit", required=True)
    ap.add_argument("--index-path", default="index.json")
    ap.add_argument("--index", type=Path, help="local new index (tests)")
    ap.add_argument("--old-index", type=Path, help="local old index (tests)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not re.match(r"^[0-9a-f]{7,40}$", args.commit):
        die(f"invalid catalog commit: {args.commit}")

    baseline_path = args.root / "versions/base.yaml"
    baseline = yaml.safe_load(baseline_path.read_text(encoding="utf-8"))
    mirror = baseline.get("mirror") or {}
    old_repo = str(mirror.get("repo", "")).strip()
    old_commit = str(mirror.get("commit", "")).strip()
    old_path = str(mirror.get("path", "")).strip()
    if not old_repo or not old_commit or not old_path:
        die(f"{baseline_path}: mirror pin is incomplete")

    if old_repo == args.repo and old_commit == args.commit:
        print("unchanged (same catalog commit)")
        return 0

    old = load_index(args.old_index, old_repo, old_commit, old_path)
    new = load_index(args.index, args.repo, args.commit, args.index_path)
    referenced = {
        str(image["catalog_id"])
        for image in baseline.get("images") or []
        if image.get("catalog_id")
    }
    changed = changed_ids(old, new, referenced)
    if not changed:
        print("unchanged (no referenced base catalog changes)")
        return 0

    print("changed ids: " + ", ".join(changed))
    if args.dry_run:
        return 0
    update_pin_text(baseline_path, args.repo, args.commit, args.index_path)
    print(f"updated mirror pin -> {args.repo}@{args.commit}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
