"""MinIO(S3 兼容)对象存储客户端:列出/下载虚拟机模板镜像。

零第三方依赖:使用标准库实现 AWS SigV4 签名 + XML 解析。
镜像约定:桶 MINIO_BUCKET(cubestack),前缀 MINIO_PREFIX(installer/vm)。

网络说明:管理机(后端所在机器)可能无法直连 MinIO,而宿主机可直连。
因此本模块提供预签名 URL(presigned)能力:后端签名,宿主机用 curl 直接下载/列桶。
"""
import hashlib
import hmac
import os
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

from ...core import config

_SERVICE = "s3"
_XML_NS = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
_IMAGE_SUFFIXES = (".qcow2", ".img", ".raw", ".vmdk")


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(date_stamp: str, region: str) -> bytes:
    k_date = _sign(("AWS4" + config.MINIO_ACCESS_KEY).encode("utf-8"), date_stamp)
    k_region = _sign(k_date, region)
    k_service = _sign(k_region, _SERVICE)
    return _sign(k_service, "aws4_request")


def _scheme() -> str:
    return "https" if config.MINIO_SECURE else "http"


def _credential_scope(date_stamp: str) -> str:
    return f"{date_stamp}/{config.MINIO_REGION}/{_SERVICE}/aws4_request"


def _prefix() -> str:
    return config.MINIO_PREFIX.rstrip("/") + "/"


def _quote_path(key: str) -> str:
    return "/" + config.MINIO_BUCKET + "/" + urllib.parse.quote(key, safe="/")


def _request(method: str, key: str, query: str = "", stream_to: str | None = None) -> bytes | None:
    """发送带 SigV4 签名的请求;stream_to 指定时流式写入文件(用于大镜像下载)。"""
    host = config.MINIO_ENDPOINT
    now = datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(b"").hexdigest()
    canonical_uri = _quote_path(key) if key else "/" + config.MINIO_BUCKET
    canonical_headers = (
        f"host:{host}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amz_date}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = (
        f"{method}\n{canonical_uri}\n{query}\n"
        f"{canonical_headers}\n{signed_headers}\n{payload_hash}"
    )
    credential_scope = _credential_scope(date_stamp)
    string_to_sign = (
        f"AWS4-HMAC-SHA256\n{amz_date}\n{credential_scope}\n"
        + hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
    )
    signature = hmac.new(_signing_key(date_stamp, config.MINIO_REGION),
                         string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    authorization = (
        f"AWS4-HMAC-SHA256 Credential={config.MINIO_ACCESS_KEY}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    url = f"{_scheme()}://{host}/{config.MINIO_BUCKET}/" + (urllib.parse.quote(key, safe="/") if key else "")
    if query:
        url += "?" + query
    req = urllib.request.Request(url, data=None, method=method)
    req.add_header("Host", host)
    req.add_header("X-Amz-Date", amz_date)
    req.add_header("X-Amz-Content-Sha256", payload_hash)
    req.add_header("Authorization", authorization)
    req.add_header("User-Agent", "cubestack-installer/1.0")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            if stream_to:
                with open(stream_to, "wb") as fh:
                    while True:
                        chunk = resp.read(1024 * 1024)
                        if not chunk:
                            break
                        fh.write(chunk)
                return b"OK"
            return resp.read()
    except Exception:
        return None


def parse_list_xml(text: str) -> list[dict]:
    """解析 S3 ListObjectsV2 响应,返回 [{name, size, last_modified}]。"""
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return []
    images: list[dict] = []
    for contents in root.findall("s3:Contents", _XML_NS):
        key_el = contents.find("s3:Key", _XML_NS)
        size_el = contents.find("s3:Size", _XML_NS)
        last_el = contents.find("s3:LastModified", _XML_NS)
        if key_el is None or not key_el.text:
            continue
        name = key_el.text
        fname = name[len(_prefix()):] if name.startswith(_prefix()) else os.path.basename(name)
        if not fname.lower().endswith(_IMAGE_SUFFIXES):
            continue
        images.append({
            "name": fname,
            "size": int(size_el.text) if size_el is not None and size_el.text else 0,
            "last_modified": last_el.text if last_el is not None and last_el.text else "",
        })
    images.sort(key=lambda x: x["name"])
    return images


def list_images() -> list[dict]:
    """从后端所在机器直连 MinIO 列出镜像(管理机可达 MinIO 时使用)。"""
    query = (
        "list-type=2"
        + "&prefix=" + urllib.parse.quote(_prefix(), safe="")
        + "&max-keys=1000"
    )
    body = _request("GET", "", query)
    if not body:
        return []
    return parse_list_xml(body.decode("utf-8", "replace"))


def download_image(name: str, dest: str) -> bool:
    """把镜像对象流式下载到本地 dest(管理机可达 MinIO 时使用)。"""
    key = _prefix() + name
    return _request("GET", key, stream_to=dest) is not None