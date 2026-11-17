import os
import re

TOOL_VERSION = "1.0.0"
SCHEMA = 1
META_NAMES = {"SHA256SUMS", "SIZES", "_SUCCESS"}
TEMP_RE = re.compile(r"(\.part$|\.tmp$|\.corrupt$|\.part\.|\.tmp\.)")
SHA_RE = re.compile(r"^([0-9a-fA-F]{64}) [ *](.+)$")
SIZE_RE = re.compile(r"^(\d+) [ *](.+)$")
try:
    GZ_DEEP_MAX = max(0, int(os.environ.get("CUBESTACK_VERIFY_GZ_MAX_MIB", "256"))) * 1024 * 1024
except ValueError:
    GZ_DEEP_MAX = 256 * 1024 * 1024
DATA_EXTS = (".tar", ".tar.gz", ".tgz", ".tar.xz", ".gz", ".xz", ".deb", ".sha256",
             ".txt", ".md", ".tsv", ".json", ".yaml", ".yml", ".conf", ".env",
             ".profile", ".list", ".py", ".sh", ".qcow2")
KNOWN_BINS = {"kubeadm", "kubelet", "kubectl", "crictl", "runc", "calicoctl",
              "etcd", "etcdctl", "helm", "skopeo", "yq", "nerdctl",
              "containerd", "containerd-shim", "ctr"}
