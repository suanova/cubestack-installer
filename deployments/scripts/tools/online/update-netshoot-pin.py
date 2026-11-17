#!/usr/bin/env python3
"""Update or insert the netshoot-rdma pin in versions/base.yaml.

The baseline is hand-formatted and contains comments, so this edits the
image block textually instead of round-tripping the whole YAML document.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")
KEY = "netshoot:netshoot-rdma"


def die(message: str) -> "NoReturn":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def entry_lines(image: str, tag: str, digest: str) -> list[str]:
    return [
        f"- key: {KEY}\n",
        f"  source_ref: {image}\n",
        f"  version: {tag}\n",
        f"  digest: {digest}\n",
        "  dest: offline-files/netshoot\n",
        "  tar: netshoot-rdma.tar\n",
        "  optional: true\n",
    ]


def update_env(text: str, tag: str) -> tuple[str, bool]:
    lines = text.splitlines(keepends=True)
    env = next((i for i, line in enumerate(lines) if line.rstrip() == "env:"), None)
    if env is None:
        die("versions/base.yaml has no env: section")
    end = env + 1
    while end < len(lines):
        line = lines[end]
        if line and not line.startswith(" "):
            break
        end += 1
    needle = "  NETSHOOT_RDMA_VERSION:"
    for i in range(env + 1, end):
        if lines[i].startswith(needle):
            newline = f"  NETSHOOT_RDMA_VERSION: {tag}\n"
            if lines[i] == newline:
                return text, False
            lines[i] = newline
            return "".join(lines), True
    lines.insert(end, f"  NETSHOOT_RDMA_VERSION: {tag}\n")
    return "".join(lines), True


def update_text(text: str, new_lines: list[str]) -> tuple[str, bool]:
    lines = text.splitlines(keepends=True)
    start = next(
        (i for i, line in enumerate(lines) if line.rstrip() == f"- key: {KEY}"),
        None,
    )
    if start is not None:
        end = start + 1
        while end < len(lines):
            line = lines[end]
            if line.startswith("- ") or (line and not line.startswith(" ")):
                break
            end += 1
        if lines[start:end] == new_lines:
            return text, False
        return "".join(lines[:start] + new_lines + lines[end:]), True

    images = next(
        (i for i, line in enumerate(lines) if line.rstrip() == "images:"),
        None,
    )
    if images is None:
        die("versions/base.yaml has no images: section")
    end = images + 1
    while end < len(lines):
        line = lines[end]
        if line and not line.startswith((" ", "-")):
            break
        end += 1
    return "".join(lines[:end] + new_lines + lines[end:]), True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path("."))
    ap.add_argument("--image", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--digest", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not args.image.startswith("harbor.isuanova.com/"):
        die(f"image must be a public Harbor ref: {args.image}")
    if not TAG_RE.match(args.tag):
        die(f"invalid image tag: {args.tag}")
    if not DIGEST_RE.match(args.digest):
        die(f"invalid digest: {args.digest}")

    path = args.root / "versions/base.yaml"
    text = path.read_text(encoding="utf-8")
    new_text, image_changed = update_text(
        text, entry_lines(args.image, args.tag, args.digest)
    )
    new_text, env_changed = update_env(new_text, args.tag)
    changed = image_changed or env_changed
    if not changed:
        print("unchanged")
        return 0
    if args.dry_run:
        print("changed")
        return 0

    data = yaml.safe_load(new_text)
    if not any(item.get("key") == KEY for item in data.get("images") or []):
        die("updated YAML does not contain the netshoot entry")
    path.write_text(new_text, encoding="utf-8")
    print("changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
