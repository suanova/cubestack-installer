import hashlib
import os

from .constants import META_NAMES

def norm_rel(p):
    p = p.replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    return p

def is_meta(rel):
    rel = norm_rel(rel)
    return rel in META_NAMES or rel.startswith(".cubestack-")

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def gnu_unescape(s):
    if not s.startswith("\\"):
        return s
    s = s[1:]
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            c = s[i + 1]
            out.append({"n": "\n", "\\": "\\"}.get(c, c))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)

def parse_env(path):
    data = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.split(" #", 1)[0].strip().strip('"').strip("'")
            data[k.strip()] = v
    return data

def parse_success(path):
    data = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
    return data

