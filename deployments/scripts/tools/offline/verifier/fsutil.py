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

def sha256_file(path, progress=None):
    """计算文件 sha256; progress(n) 每读一个 chunk 回调一次(连续字节进度)。

    回调用于全量校验的实时吞吐/剩余时间估计与新心跳: 只按"文件完成"计数的话,
    单个超大文件哈希期间(kernel 实测 134s)既看不到进度, 吞吐也会在完成瞬间跳变。
    """
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
            if progress is not None:
                progress(len(chunk))
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

