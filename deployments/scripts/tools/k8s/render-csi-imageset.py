#!/usr/bin/env python3
"""Point the ceph-csi-operator ImageSet ConfigMap at mirrored (preloaded) images.

Rook's operator manifest ships an ``ImageSet`` ConfigMap whose values are empty,
meaning the ceph-csi-operator uses its built-in upstream images
(quay.io/cephcsi/*, registry.k8s.io/sig-storage/*, quay.io/csiaddons/*).  An
offline cluster cannot reach those, so this tool fills the keys with the
mirror-prefixed, version-pinned references that the release tree preloads.

Usage:
    render-csi-imageset.py <operator.yaml> <mirror-base> KEY=REPO=VERSION ...

Keys whose VERSION is empty are left untouched (operator default).  Missing keys
are appended to the ConfigMap, so an operator whose manifest predates a key
(e.g. snapshot-metadata) still gets it.  The YAML is rewritten in place; only
the ImageSet ConfigMap document is modified.

The output is fed to ``kubectl apply`` as plain YAML, which is why this is a
text rewrite rather than a YAML round-trip (a round-trip would reformat the
whole vendored manifest).
"""

from __future__ import annotations

import re
import sys

CM_NAME = "rook-csi-operator-image-set-configmap"


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    path, base, specs = argv[1], argv[2], argv[3:]

    desired: dict[str, str] = {}
    for spec in specs:
        key, repo, version = spec.split("=", 2)
        if version:
            desired[key] = f"{base}/{repo}:{version}"
    if not desired:
        return 0

    text = open(path, encoding="utf-8").read()
    docs = text.split("\n---\n")
    for index, doc in enumerate(docs):
        if CM_NAME not in doc:
            continue
        lines = doc.split("\n")
        try:
            start = next(
                n for n, line in enumerate(lines) if re.match(r"^data:\s*$", line)
            )
        except StopIteration:
            continue
        end = start + 1
        while end < len(lines) and (
            lines[end].startswith((" ", "\t")) or not lines[end].strip()
        ):
            end += 1
        block: list[str] = []
        seen: set[str] = set()
        for line in lines[start + 1:end]:
            match = re.match(r"^(\s+)([A-Za-z0-9._-]+):\s*(.*)$", line)
            if match and match.group(2) in desired:
                block.append(f'{match.group(1)}{match.group(2)}: "{desired[match.group(2)]}"')
                seen.add(match.group(2))
            elif line.strip():
                block.append(line)
        for key, value in desired.items():
            if key not in seen:
                block.append(f'  {key}: "{value}"')
        docs[index] = "\n".join(lines[: start + 1] + block + lines[end:])
        open(path, "w", encoding="utf-8").write("\n---\n".join(docs))
        return 0

    print(f"{path}: {CM_NAME} ConfigMap not found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
