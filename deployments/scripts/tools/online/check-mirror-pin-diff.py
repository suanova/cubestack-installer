#!/usr/bin/env python3
"""Verify that a mirror pin PR only moves mirror.commit.

pin-automerge runs this on the trusted base copy and the validated head copy;
everything outside the commit value must stay byte-identical.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

COMMIT_RE = re.compile(r"^[0-9a-f]{7,40}$")


def load_mirror(path: Path, label: str) -> dict:
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise SystemExit(f"ERROR: {label} is not valid YAML: {exc}")
    mirror = doc.get("mirror") if isinstance(doc, dict) else None
    if not isinstance(mirror, dict):
        raise SystemExit(f"ERROR: {label} has no mirror pin")
    for field in ("repo", "commit", "path"):
        if not str(mirror.get(field, "")).strip():
            raise SystemExit(f"ERROR: {label} mirror pin is missing {field}")
    return mirror


def mask_commit(text: str) -> str:
    """Replace mirror.commit's value, leaving every other byte untouched."""
    out = []
    in_mirror = False
    for line in text.splitlines(keepends=True):
        if re.match(r"^mirror:\s*$", line):
            in_mirror = True
            out.append(line)
            continue
        if in_mirror and line.strip() and not line.startswith((" ", "\t")):
            in_mirror = False
        if in_mirror:
            line = re.sub(
                r"^(\s+commit:\s*)\S+(\s*(?:#.*)?)$",
                r"\1<MASK>\2", line, count=1)
        out.append(line)
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("base", type=Path)
    ap.add_argument("head", type=Path)
    args = ap.parse_args()

    base_mirror = load_mirror(args.base, "base")
    head_mirror = load_mirror(args.head, "head")

    for field in ("repo", "path"):
        if base_mirror[field] != head_mirror[field]:
            print(f"ERROR: mirror.{field} changed", file=sys.stderr)
            return 1
    commit = str(head_mirror["commit"])
    if not COMMIT_RE.match(commit):
        print("ERROR: mirror.commit is not a hex commit", file=sys.stderr)
        return 1
    if commit == str(base_mirror["commit"]):
        print("ERROR: mirror.commit did not move", file=sys.stderr)
        return 1

    base_text = args.base.read_text(encoding="utf-8")
    head_text = args.head.read_text(encoding="utf-8")
    if mask_commit(base_text) != mask_commit(head_text):
        print("ERROR: versions/base.yaml changes outside mirror.commit",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
