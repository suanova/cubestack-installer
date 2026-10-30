#!/usr/bin/env python3
"""verifier 模块级单测(纯标准库; CI 用).

运行:
  PYTHONPATH=deployments/scripts/tools/offline \
    python3 -m unittest deployments/scripts/tools/tests/test_verifier_modules.py -v
"""
import io
import json
import os
import sys
import tarfile
import tempfile
import unittest
from argparse import Namespace
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "deployments", "scripts", "tools", "offline"))

from verifier import archive, fsutil, manifest, seal, selftest, stamp  # noqa: E402
from verifier.context import Ctx  # noqa: E402
from verifier.layout import detect_layout  # noqa: E402
from verifier.report import emit  # noqa: E402


def _sha(path):
    return fsutil.sha256_file(path)


class FsutilTests(unittest.TestCase):
    def test_norm_and_meta(self):
        self.assertEqual(fsutil.norm_rel("./a/b"), "a/b")
        self.assertTrue(fsutil.is_meta("SHA256SUMS"))
        self.assertTrue(fsutil.is_meta(".cubestack-verified.json"))
        self.assertFalse(fsutil.is_meta("a.tar"))

    def test_parse_env_success(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "release.env")
            with open(p, "w", encoding="utf-8") as f:
                f.write("RELEASE_VERSION=2.0.0 # c\nKUBESPRAY_VERSION='v2.32.0'\n")
            env = fsutil.parse_env(p)
            self.assertEqual(env["RELEASE_VERSION"], "2.0.0")
            self.assertEqual(env["KUBESPRAY_VERSION"], "v2.32.0")
            s = os.path.join(d, "_SUCCESS")
            with open(s, "w", encoding="utf-8") as f:
                f.write("release=2.0.0\nsha256sums=abc\n")
            self.assertEqual(fsutil.parse_success(s)["sha256sums"], "abc")


class ManifestTests(unittest.TestCase):
    def test_parse_sums_and_sizes(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "SHA256SUMS")
            with open(p, "w", encoding="utf-8") as f:
                f.write(f"{'a' * 64}  ./a.txt\n")
                f.write(f"{'b' * 64}  ./b c.txt\n")
            ctx = Ctx()
            sums = manifest.parse_sha256sums(ctx, p)
            self.assertEqual(sums["a.txt"], "a" * 64)
            self.assertEqual(sums["b c.txt"], "b" * 64)
            self.assertEqual(ctx.failures, [])
            z = os.path.join(d, "SIZES")
            with open(z, "w", encoding="utf-8") as f:
                f.write("3  ./a.txt\n")
            self.assertEqual(manifest.parse_sizes(ctx, z)["a.txt"], 3)

    def test_layout(self):
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, "SHA256SUMS"), "w").close()
            self.assertEqual(detect_layout(d, "", "auto"), "sealed-dev")
            open(os.path.join(d, "release.env"), "w").close()
            self.assertEqual(detect_layout(d, "2.0.0", "auto"), "flat")
            os.remove(os.path.join(d, "SHA256SUMS"))
            self.assertEqual(detect_layout(d, "", "auto"), "unsealed-dev")


class ArchiveTests(unittest.TestCase):
    def _make_image(self, root, corrupt=False):
        b = os.path.join(root, "build")
        os.makedirs(b, exist_ok=True)
        layer = os.path.join(b, "layer.tar")
        with tarfile.open(layer, "w") as tf:
            data = b"layerdata"
            info = tarfile.TarInfo("f")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        did = _sha(layer)
        if corrupt:
            with open(layer, "ab") as f:
                f.write(b"corrupt")
        cfg = {"rootfs": {"diff_ids": ["sha256:" + did]}}
        with open(os.path.join(b, "config.json"), "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        with open(os.path.join(b, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump([{"Config": "config.json", "Layers": ["layer.tar"]}], f)
        out = os.path.join(root, "img.tar")
        with tarfile.open(out, "w") as tf:
            for n in ("layer.tar", "config.json", "manifest.json"):
                tf.add(os.path.join(b, n), arcname=n)
        return out

    def test_valid_image_deep(self):
        with tempfile.TemporaryDirectory() as d:
            img = self._make_image(d)
            ctx = Ctx()
            ctx.root = d
            ctx.deep = True
            self.assertTrue(archive.check_tar(ctx, img, "img.tar"))
            self.assertEqual(ctx.failures, [])

    def test_corrupt_layer_deep(self):
        with tempfile.TemporaryDirectory() as d:
            img = self._make_image(d, corrupt=True)
            ctx = Ctx()
            ctx.root = d
            ctx.deep = True
            self.assertFalse(archive.check_tar(ctx, img, "img.tar"))
            self.assertTrue(any(f["kind"] == "image_layer" for f in ctx.failures))


class StampSealTests(unittest.TestCase):
    def test_stamp_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "a")
            with open(p, "w") as f:
                f.write("x")
            sums = {"a": _sha(p)}
            with open(os.path.join(d, "SHA256SUMS"), "w", encoding="utf-8") as f:
                f.write(f"{sums['a']}  ./a\n")
            args = Namespace(stamp_file="", deep=True, layout="sealed-dev", release="")
            stamp.write_stamp(d, args, sums)
            valid, _, reason = stamp.stamp_valid(d, args, sums)
            self.assertTrue(valid, reason)
            with open(p, "a") as f:
                f.write("y")
            valid, _, _ = stamp.stamp_valid(d, args, sums)
            self.assertFalse(valid)

    def test_seal(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "a"), "w") as f:
                f.write("x")
            args = Namespace(force=True, update_success=True, release="9.9.9", jobs=2)
            self.assertEqual(seal.seal(d, args), 0)
            self.assertTrue(os.path.isfile(os.path.join(d, "SHA256SUMS")))
            self.assertTrue(os.path.isfile(os.path.join(d, "SIZES")))
            self.assertTrue(os.path.isfile(os.path.join(d, "_SUCCESS")))


class ReportTests(unittest.TestCase):
    def test_emit_json(self):
        ctx = Ctx()
        ctx.root = "/tmp/x"
        ctx.layout = "sealed-dev"
        ctx.level = "quick"
        args = Namespace(json=True, release="")
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = emit(ctx, args)
        self.assertEqual(rc, 0)
        data = json.loads(buf.getvalue())
        self.assertEqual(data["schema"], 1)
        self.assertTrue(data["ok"])


class SelftestTests(unittest.TestCase):
    def test_seal_failure_prints_and_returns_1(self):
        # 失败分支必须能打印(selftest.py 曾漏 import sys → NameError 被入口吞成内部错误)
        err = io.StringIO()
        with mock.patch.object(selftest, "seal", return_value=1), redirect_stderr(err):
            rc = selftest.self_test()
        self.assertEqual(rc, 1)
        self.assertIn("self-test: seal 失败", err.getvalue())


if __name__ == "__main__":
    unittest.main()
