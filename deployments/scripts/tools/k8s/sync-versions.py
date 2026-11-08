#!/usr/bin/env python3
"""Render installer version files from versions/base.yaml.

Managed versions live only in versions/base.yaml. This tool writes the
generated defaults block, the kubespray profile, and the generated inventory.
Display-only versions are checked against their real vendored source instead of
being propagated.
"""

from __future__ import annotations

import argparse
import difflib
import os
import re
import shlex
import sys
import tempfile
from pathlib import Path

import yaml

BEGIN = "# >>> BEGIN GENERATED VERSIONS (versions/base.yaml; run: make sync-versions) >>>"
END = "# <<< END GENERATED VERSIONS <<<"

PROFILE_KEYS = [
    "KUBESPRAY_VERSION",
    "K8S_VERSION",
    "PAUSE_VERSION",
    "COREDNS_VERSION",
    "DNS_NODE_CACHE_VERSION",
    "ETCD_VERSION",
    "CALICO_VERSION",
    "METALLB_VERSION",
    "KUBE_VIP_VERSION",
    "REGISTRY_IMAGE_TAG",
    "LOCAL_PATH_VERSION",
    "LOCAL_VOLUME_PROVISIONER_VERSION",
    "NFD_VERSION",
    "METRICS_SERVER_VERSION",
    "CPA_VERSION",
    "API_LB_NGINX_IMAGE_TAG",
]

# (kubespray variable, base env key, strip leading v)
INVENTORY = [
    ("kube_version", "K8S_VERSION", True),
    ("pod_infra_version", "PAUSE_VERSION", True),
    ("coredns_version", "COREDNS_VERSION", True),
    ("nodelocaldns_version", "DNS_NODE_CACHE_VERSION", True),
    ("metrics_server_version", "METRICS_SERVER_VERSION", True),
    ("dnsautoscaler_version", "CPA_VERSION", True),
    ("etcd_version", "ETCD_VERSION", True),
    ("calico_version", "CALICO_VERSION", True),
    ("metallb_version", "METALLB_VERSION", True),
    ("kube_vip_version", "KUBE_VIP_VERSION", True),
    ("registry_version", "REGISTRY_IMAGE_TAG", False),
    ("local_path_provisioner_version", "LOCAL_PATH_VERSION", True),
    ("local_volume_provisioner_version",
     "LOCAL_VOLUME_PROVISIONER_VERSION", False),
    ("node_feature_discovery_version", "NFD_VERSION", False),
    ("nginx_image_tag", "API_LB_NGINX_IMAGE_TAG", False),
]

CHECKSUM_VARS = [
    ("etcd_binary_checksum", "etcd", "amd64"),
    ("calicoctl_binary_checksum", "calicoctl", "amd64"),
]

# display key -> (file, regex)
DISPLAY_SOURCES = {
    "CSI_ATTACHER_VERSION": (
        "deployments/kubespray/kubespray/roles/kubespray_defaults/defaults/main/download.yml",
        r"^csi_attacher_image_tag:\s*\"?([^\"\s]+)\"?\s*$"),
    "CSI_PROVISIONER_VERSION": (
        "deployments/kubespray/kubespray/roles/kubespray_defaults/defaults/main/download.yml",
        r"^csi_provisioner_image_tag:\s*\"?([^\"\s]+)\"?\s*$"),
    "CSI_SNAPSHOTTER_VERSION": (
        "deployments/kubespray/kubespray/roles/kubespray_defaults/defaults/main/download.yml",
        r"^csi_snapshotter_image_tag:\s*\"?([^\"\s]+)\"?\s*$"),
    "CSI_RESIZER_VERSION": (
        "deployments/kubespray/kubespray/roles/kubespray_defaults/defaults/main/download.yml",
        r"^csi_resizer_image_tag:\s*\"?([^\"\s]+)\"?\s*$"),
    "CSI_NODE_DRIVER_REGISTRAR_VERSION": (
        "deployments/kubespray/kubespray/roles/kubespray_defaults/defaults/main/download.yml",
        r"^csi_node_driver_registrar_image_tag:\s*\"?([^\"\s]+)\"?\s*$"),
    "CSIADDONS_SIDECAR_VERSION": (
        "deployments/cubestack-addon/rook/operator.yaml",
        r"addons:\s*\"quay\.io/csiaddons/k8s-sidecar:([^\"]+)\""),
    "CEPHCSI_VERSION": (
        "deployments/cubestack-addon/rook/operator.yaml",
        r"quay\.io/cephcsi/cephcsi:([^\s\"]+)"),
    "ROOK_VERSION": (
        "deployments/cubestack-addon/rook/operator.yaml",
        r"image:\s*docker\.io/rook/ceph:([^\s\"]+)"),
    "CEPH_CSI_OPERATOR_VERSION": (
        "deployments/cubestack-addon/rook/csi-operator.yaml",
        r"quay\.io/cephcsi/ceph-csi-operator:([^\s\"]+)"),
}

ERROR = "ERROR: "


def die(message: str) -> "NoReturn":
    print(ERROR + message, file=sys.stderr)
    raise SystemExit(1)


def load_base(root: Path) -> dict:
    path = root / "versions/base.yaml"
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        die(f"cannot read {path}: {exc}")
    if not isinstance(data, dict):
        die(f"{path}: not a YAML mapping")
    return data


def validate_base(root: Path, base: dict) -> None:
    env = base.get("env")
    display = base.get("display_only") or []
    if not isinstance(env, dict) or not env:
        die("versions/base.yaml: env must be a non-empty mapping")
    if not isinstance(display, list):
        die("versions/base.yaml: display_only must be a list")
    unknown = sorted(set(display) - set(env))
    if unknown:
        die("versions/base.yaml: display_only keys missing from env: "
            + ", ".join(unknown))

    kubespray = base.get("kubespray") or {}
    if str(env.get("KUBESPRAY_VERSION", "")) != str(kubespray.get("version", "")):
        die("versions/base.yaml: KUBESPRAY_VERSION must equal kubespray.version")

    checksums = base.get("checksums") or {}
    for _, component, arch in CHECKSUM_VARS:
        value = ((checksums.get(component) or {}).get(arch) or "")
        if not re.match(r"^sha256:[0-9a-f]{64}$", str(value)):
            die(f"versions/base.yaml: checksums.{component}.{arch} is required")
    crds = (checksums.get("calico_crds") or {}).get("no_arch") or ""
    if not re.match(r"^sha256:[0-9a-f]{64}$", str(crds)):
        die("versions/base.yaml: checksums.calico_crds.no_arch is required")

    managed = managed_env(base)
    for _, key, _ in INVENTORY:
        if key not in managed:
            die(f"versions/base.yaml: managed key {key} is missing")
    for key in PROFILE_KEYS:
        if key not in managed:
            die(f"versions/base.yaml: profile key {key} is missing")


def strip_v(value: str) -> str:
    return value[1:] if value.startswith("v") else value


def yaml_scalar(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def shell_value(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace(
        "$", "\\$").replace("`", "\\`")


def managed_env(base: dict) -> dict:
    display = set(base.get("display_only") or [])
    return {k: v for k, v in base["env"].items() if k not in display}


def render_defaults(base: dict) -> str:
    env = managed_env(base)
    lines = [BEGIN]
    for key, value in env.items():
        if key == "KUBESPRAY_VERSION":
            # Left empty so load_config can pick the latest repo profile; the
            # generated profile sets the actual value.
            lines.append(f'{key}="${{{key}:-}}"')
            continue
        lines.append(f'{key}="${{{key}:-{shell_value(str(value))}}}"')
    if "NVIDIA_GPU_DRIVER_PRECOMPILED_KERNEL" in env:
        value = shell_value(str(env["NVIDIA_GPU_DRIVER_PRECOMPILED_KERNEL"]))
        lines.append(
            'NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS='
            f'"${{NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS:-{value}}}"')
    lines.append(END)
    return "\n".join(lines) + "\n"


def render_profile(base: dict) -> str:
    env = managed_env(base)
    lines = [
        "# Generated by deployments/scripts/tools/k8s/sync-versions.py",
        "# from versions/base.yaml: kubespray version profile. Do not edit.",
        "#",
        "# The profile is sourced after cluster.conf/defaults, so these values",
        "# take precedence over the generic defaults.",
    ]
    for key in PROFILE_KEYS:
        lines.append(f"{key}={env[key]}")
    return "\n".join(lines) + "\n"


def render_inventory(base: dict) -> str:
    env = managed_env(base)
    checksums = base["checksums"]
    lines = [
        "# Generated by deployments/scripts/tools/k8s/sync-versions.py",
        "# from versions/base.yaml: kubespray group_vars. Do not edit.",
    ]
    for name, key, strip in INVENTORY:
        value = str(env[key])
        if strip:
            value = strip_v(value)
        lines.append(f"{name}: {yaml_scalar(value)}")
    for name, component, arch in CHECKSUM_VARS:
        lines.append(f"{name}: {yaml_scalar(checksums[component][arch])}")
    return "\n".join(lines) + "\n"


def replace_block(path: Path, block: str) -> str:
    text = path.read_text(encoding="utf-8")
    if BEGIN not in text or END not in text:
        die(f"{path}: generated block markers are missing")
    start = text.index(BEGIN)
    stop = text.index(END, start) + len(END)
    if text[stop:stop + 1] == "\n":
        stop += 1
    return text[:start] + block + text[stop:]


def check_duplicates(root: Path, path: Path, base: dict) -> None:
    text = replace_block(path, render_defaults(base))
    start = text.index(BEGIN)
    stop = text.index(END, start) + len(END)
    outside = text[:start] + text[stop:]
    keys = list(managed_env(base)) + ["NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS"]
    for key in keys:
        if re.search(rf"^(?:export\s+)?{re.escape(key)}=", outside,
                     flags=re.MULTILINE):
            die(f"{path}: {key} is declared outside the generated block; "
                "remove the hand-written line")


def check_display(root: Path, base: dict) -> None:
    env = base["env"]
    k8s_version = str(env.get("K8S_VERSION", ""))
    for key in sorted(base.get("display_only") or []):
        value = env[key]
        if key == "NGINX_TAG":
            continue
        if key == "SNAPSHOT_CONTROLLER_VERSION":
            rel = ("deployments/kubespray/kubespray/roles/"
                   "kubespray_defaults/defaults/main/download.yml")
            major = ".".join(strip_v(k8s_version).split(".")[:2])
            text = (root / rel).read_text(encoding="utf-8")
            table = re.search(
                rf"^\s*'{re.escape(major)}':\s*\"([^\"]+)\"",
                text, flags=re.MULTILINE)
            if not table:
                die(f"{rel}: no snapshot_controller version for {major}")
            actual = table.group(1)
            if str(value) != actual:
                die(f"display_only.{key}={value!r} does not match "
                    f"{rel} ({actual!r}); edit the sourced artifact instead")
            continue
        source = DISPLAY_SOURCES.get(key)
        if source is None:
            die(f"display_only.{key}: no source rule")
        rel, pattern = source
        path = root / rel
        match = re.search(pattern, path.read_text(encoding="utf-8"),
                          flags=re.MULTILINE)
        if not match:
            die(f"{rel}: cannot find the source for display_only.{key}")
        actual = match.group(1)
        if str(value) != actual:
            die(f"display_only.{key}={value!r} does not match "
                f"{rel} ({actual!r}); edit the sourced artifact instead")


def render_all(root: Path, base: dict) -> dict[Path, str]:
    defaults = root / "deployments/config/cluster.defaults.conf"
    return {
        defaults: replace_block(defaults, render_defaults(base)),
        root / "deployments/config/profiles/v2.32.0.profile": render_profile(base),
        root / "deployments/kubespray/inventory/cubestack-cluster/group_vars/all/k8s-versions.yml":
            render_inventory(base),
    }


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--write", action="store_true",
                        help="rewrite generated files (default)")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--write-inventory", type=Path)
    parser.add_argument("--print-env", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    base = load_base(root)
    validate_base(root, base)

    if args.print_env:
        for key, value in managed_env(base).items():
            print(f"{key}={shlex.quote(str(value))}")
        return 0

    if args.write_inventory:
        write_atomic(args.write_inventory, render_inventory(base))
        return 0

    check_display(root, base)
    check_duplicates(root, root / "deployments/config/cluster.defaults.conf",
                     base)
    rendered = render_all(root, base)

    if args.check:
        failed = False
        for path, expected in rendered.items():
            actual = path.read_text(encoding="utf-8") if path.exists() else ""
            if actual == expected:
                continue
            failed = True
            print(f"out of date: {path}", file=sys.stderr)
            diff = difflib.unified_diff(
                actual.splitlines(), expected.splitlines(),
                fromfile=str(path), tofile=f"{path} (generated)", lineterm="")
            print("\n".join(list(diff)[:80]), file=sys.stderr)
        return 1 if failed else 0

    for path, expected in rendered.items():
        write_atomic(path, expected)
    print("updated generated version files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
