import hashlib
import json
import os
import time

from .constants import SCHEMA, TOOL_VERSION
from .fsutil import sha256_file

def host_fingerprint():
    for p in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        try:
            v = open(p, encoding="utf-8").read().strip()
            if v:
                return hashlib.sha256(v.encode()).hexdigest()
        except OSError:
            pass
    return hashlib.sha256(os.uname().nodename.encode()).hexdigest()

def fingerprint(root, sums):
    h = hashlib.sha256()
    for rel in sorted(sums):
        st = os.stat(os.path.join(root, rel))
        h.update(f"{rel}\0{st.st_size}\0{st.st_mtime_ns}\0{st.st_ino}\0{st.st_dev}\n".encode())
    return h.hexdigest()

def stamp_path(root, args):
    return args.stamp_file or os.path.join(root, ".cubestack-verified.json")

def stamp_valid(root, args, sums):
    path = stamp_path(root, args)
    if not sums:
        return False, path, "manifest missing"
    if not os.path.isfile(path):
        return False, path, "missing"
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception as exc:
        return False, path, f"parse: {exc}"
    sums_path = os.path.join(root, "SHA256SUMS")
    if not os.path.isfile(sums_path):
        return False, path, "manifest missing"
    if not data.get("deep", False):
        return False, path, "stamp was not deep"
    if data.get("manifest_sha256") != sha256_file(sums_path):
        return False, path, "manifest changed"
    try:
        if data.get("fingerprint") != fingerprint(root, sums):
            return False, path, "fingerprint mismatch"
    except OSError as exc:
        return False, path, f"stat: {exc}"
    return True, path, "ok"

def write_stamp(root, args, sums):
    path = stamp_path(root, args)
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    data = {
        "schema": SCHEMA,
        "tool_version": TOOL_VERSION,
        "level": "full",
        "deep": bool(getattr(args, "deep", False)),
        "layout": args.layout,
        "release": args.release,
        "root": root,
        "manifest": "SHA256SUMS",
        "manifest_sha256": sha256_file(os.path.join(root, "SHA256SUMS")),
        "files": len(sums),
        "bytes": sum(os.path.getsize(os.path.join(root, r)) for r in sums),
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host_fingerprint": host_fingerprint(),
        "fingerprint": fingerprint(root, sums),
    }
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)

