#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify-rgw-s3.py — RGW/S3 真实数据读写验证(SigV4, 纯标准库, 无 aws cli 依赖)
用法(在 rook-ceph toolbox 容器内):
  AK=<access_key> SK=<secret_key> ENDPOINT=http://rook-ceph-rgw-s3-store.rook-ceph.svc:80 \
    python3 /tmp/verify-rgw-s3.py
流程: PUT bucket → PUT object → GET object(校验内容) → DELETE object/bucket
输出: 成功打印 S3-PUT-GET-OK; 失败抛异常/非 2xx 退出码 1
环境变量: AK/SK(不给则自动建临时用户, 需能连到 rook-ceph-tools) / ENDPOINT(可省 http://) /
          REGION / RGW_UID / RGW_ZONE(默认 s3-store) / ROOK_NAMESPACE
"""
import os
import sys
import hashlib
import hmac
import json
import time
import urllib.request
import urllib.error

AK = os.environ.get("AK", "")
SK = os.environ.get("SK", "")
UID = os.environ.get("RGW_UID", "verify-user")
# RGW 的 zone 名: Rook 按 CephObjectStore 名字建 realm/zonegroup/zone(本平台默认 s3-store);
# ⚠ 集群里通常**同时存在一个 `default` zone**, 而 RGW 服务的是 `s3-store` —— 建临时用户时
# 不指定 zone 会落到 default, 该 key 对 RGW 不可见 ⇒ PUT 报 `InvalidAccessKeyId`
# (2026-09-29 实机取证; 平台的 rgw-get-user-key.sh 一直是显式带 --rgw-zone=s3-store 的)。
RGW_ZONE = os.environ.get("RGW_ZONE", "s3-store")
ENDPOINT = os.environ.get("ENDPOINT", "http://rook-ceph-rgw-s3-store.rook-ceph.svc:80")
if ENDPOINT and not ENDPOINT.startswith(("http://", "https://")):
    # 只给 host[:port] 时补 scheme —— 否则 urlparse().netloc 为空、urllib 也认不出 url 类型,
    # 报的错与"端点不通"无法区分(2026-09-29 实机: 用户写 ENDPOINT=10.66.3.29:80 踩到)
    ENDPOINT = "http://" + ENDPOINT
REGION = os.environ.get("REGION", "us-east-1")
SERVICE = "s3"
HOST = urllib.request.urlparse(ENDPOINT).netloc


def _radosgw_admin(args):
    """跑一次 radosgw-admin 并返回 stdout。

    radosgw-admin **只存在于 rook-ceph-tools 容器里** —— 在宿主机或部署容器里直接调用会
    报 Permission denied / FileNotFoundError(2026-09-29 实机踩到两次)。故:
      本机有该命令(即在 toolbox 内) → 直接跑;
      否则 → 经 kubectl exec 进 toolbox 跑(容器/宿主机都有 kubectl + kubeconfig)。
    """
    import subprocess
    import shutil
    if shutil.which("radosgw-admin"):
        return subprocess.check_output(["radosgw-admin"] + args, stderr=subprocess.DEVNULL)
    ns = os.environ.get("ROOK_NAMESPACE", "rook-ceph")
    return subprocess.check_output(
        ["kubectl", "-n", ns, "exec", "deploy/rook-ceph-tools", "--", "radosgw-admin"] + args,
        stderr=subprocess.DEVNULL)


def ensure_creds():
    """无 AK/SK 时经 radosgw-admin 创建临时用户并取凭据(结束自动清理)"""
    global AK, SK
    if AK and SK:
        return
    out = _radosgw_admin(["user", "create", "--uid", UID, "--display-name", "verify",
                          "--rgw-zone", RGW_ZONE])
    d = json.loads(out)
    AK = d["keys"][0]["access_key"]
    SK = d["keys"][0]["secret_key"]


def cleanup_user():
    if not AK or not SK:
        return
    try:
        _radosgw_admin(["user", "rm", "--uid", UID, "--rgw-zone", RGW_ZONE])
    except Exception:
        pass

BUCKET = "verify-rgw-%d" % int(time.time())
OBJ = "hello.txt"
BODY = "verify-s3-data-%d" % int(time.time())


def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def sig_key(secret, date, region, service):
    k_date = sign(("AWS4" + secret).encode("utf-8"), date)
    k_region = sign(k_date, region)
    k_service = sign(k_region, service)
    return sign(k_service, "aws4_request")


def req(method, path, body=b"", extra_headers=None):
    """执行一次 SigV4 签名的 HTTP 请求, 返回 (status, body_bytes)"""
    amzdate = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    datestamp = amzdate[:8]
    payload_hash = hashlib.sha256(body).hexdigest()
    headers = {
        "host": HOST,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amzdate,
    }
    if extra_headers:
        headers.update(extra_headers)
    # canonical headers (host + x-amz-*, 字典序)
    ckeys = sorted(headers.keys())
    canonical_headers = "".join("%s:%s\n" % (k, headers[k].strip()) for k in ckeys)
    signed_headers = ";".join(ckeys)
    canonical_request = "\n".join([
        method, path, "",
        canonical_headers, signed_headers, payload_hash,
    ])
    sts = "\n".join([
        "AWS4-HMAC-SHA256", amzdate,
        "%s/%s/%s/aws4_request" % (datestamp, REGION, SERVICE),
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ])
    signing_key = sig_key(SK, datestamp, REGION, SERVICE)
    signature = hmac.new(signing_key, sts.encode("utf-8"), hashlib.sha256).hexdigest()
    auth = "AWS4-HMAC-SHA256 Credential=%s/%s/%s/%s/aws4_request, SignedHeaders=%s, Signature=%s" % (
        AK, datestamp, REGION, SERVICE, signed_headers, signature)
    url = ENDPOINT + path
    r = urllib.request.Request(url, data=body, method=method)
    for k, v in headers.items():
        if k != "host":
            r.add_header(k, v)
    r.add_header("Authorization", auth)
    r.add_header("x-amz-date", amzdate)
    r.add_header("x-amz-content-sha256", payload_hash)
    try:
        with urllib.request.urlopen(r, timeout=15) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        err_body = e.read().decode(errors="replace")[:400]
        print("HTTP %s %s %s -> %s" % (method, path, e.code, err_body), file=sys.stderr)
        return e.code, e.read()


def main():
    # 有 AK/SK 直接用; 无则尝试 radosgw-admin 建临时用户(仅 toolbox 内可用)
    if AK and SK:
        _run_verify()
        sys.exit(0)
    ensure_creds()
    if not AK or not SK:
        print("缺少 AK/SK 且无法创建临时用户。三种取凭据的办法:", file=sys.stderr)
        print("  ① 直接用平台预置用户(推荐): kubectl -n rook-ceph get secret \\", file=sys.stderr)
        print("       rook-ceph-object-user-s3-store-rgw-model-admin -o go-template='{{index .data \"AccessKey\"}}' | base64 -d", file=sys.stderr)
        print("  ② 临时用户(本工具会自动建/删): 需能连到 rook-ceph-tools(本机没有 radosgw-admin 时经 kubectl exec)", file=sys.stderr)
        print("  ③ 手工指定: AK=<access_key> SK=<secret_key> ENDPOINT=http://<rgw-host:port> python3 %s" % sys.argv[0], file=sys.stderr)
        sys.exit(1)
    try:
        _run_verify()
    finally:
        cleanup_user()
    sys.exit(0)


def _run_verify():
    # 1. PUT bucket
    st, _ = req("PUT", "/" + BUCKET)
    if st not in (200, 204, 409):  # 409=已存在(幂等)
        print("FAIL PUT bucket %s: %s" % (BUCKET, st), file=sys.stderr)
        sys.exit(1)
    # 2. PUT object
    st, _ = req("PUT", "/%s/%s" % (BUCKET, OBJ), body=BODY.encode(), extra_headers={"content-type": "text/plain"})
    if st not in (200, 204):
        print("FAIL PUT object: %s" % st, file=sys.stderr)
        sys.exit(1)
    # 3. GET object 并校验内容
    st, data = req("GET", "/%s/%s" % (BUCKET, OBJ))
    if st != 200:
        print("FAIL GET object: %s" % st, file=sys.stderr)
        sys.exit(1)
    if data.decode().strip() != BODY:
        print("FAIL 内容不一致: got=%r want=%r" % (data.decode().strip(), BODY), file=sys.stderr)
        sys.exit(1)
    print("S3-PUT-GET-OK bucket=%s object=%s content=%s" % (BUCKET, OBJ, data.decode().strip()))
    # 4. 清理
    req("DELETE", "/%s/%s" % (BUCKET, OBJ))
    req("DELETE", "/" + BUCKET)
    sys.exit(0)


if __name__ == "__main__":
    main()
