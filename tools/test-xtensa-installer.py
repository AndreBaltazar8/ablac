#!/usr/bin/env python3
"""Installer controls use tiny synthetic cohorts; no downloads or LLVM builds."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
import xtensa_companions as companions

TOOLS = Path(__file__).resolve().parent


@unittest.skipUnless((companions.platform.system(), companions.platform.machine()) in companions.HOSTS,
                     "installer supports Linux x86_64 and both Macs")
class Installer(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xtensa installer tests ")
        self.base = Path(self.temp.name)
        self.root = self.base / "tool chain"
        for name in ("libexec/ablac.bin", "bin/clang", "lib/libLLVM-parent"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("original parent " + name).encode())
        self.originals = {p: (p.read_bytes(), p.stat().st_mode) for p in self.root.rglob("*") if p.is_file()}
        self.catalog = {"schema": 1, "releases": {}}
        self.host = companions.host_platform()
        self.archive = self.package("23.1.3-1")

    def tearDown(self):
        # Only owned fixtures are made writable, so readonly version directories
        # can be removed on both Darwin and Linux.
        for path in [self.base, *self.base.rglob("*")]:
            if not path.is_symlink() and path.is_dir():
                path.chmod(0o700)
        self.temp.cleanup()

    def package(self, version):
        tag = "abla-xtensa-llvm-" + version
        prefix = tag + "-" + self.host
        helper = b"#!/bin/sh\nprintf '%s\\n' 'LLVM version 23.1.3' 'Registered Targets: xtensa'\n"
        content = {"bin/opt": helper, "bin/llc": helper, "lib/libLLVM.test": b"private LLVM test data\n"}
        manifest = {"schema": 1, "version": tag, "platform": self.host, "llvmVersion": "23.1.3",
                    "sourceCommit": "a" * 40, "sourceArchiveSha256": "b" * 64,
                    "files": {name: hashlib.sha256(data).hexdigest() for name, data in content.items()}}
        raw = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
        content["manifest.json"] = raw
        archive = self.base / (prefix + ".tar.gz")
        with tarfile.open(archive, "w:gz") as tar:
            for name, data in content.items():
                entry = tarfile.TarInfo(prefix + "/" + name)
                entry.size = len(data)
                entry.mode = 0o755 if name.startswith("bin/") else 0o644
                tar.addfile(entry, io.BytesIO(data))
        release = {"status": "published", "llvmVersion": "23.1.3", "sourceCommit": "a" * 40,
                   "sourceArchiveSha256": "b" * 64, "platforms": {}}
        for host in companions.PLATFORMS:
            release["platforms"][host] = {"url": f"{companions.RELEASES}/{tag}/{tag}-{host}.tar.gz",
                                          "sha256": companions.file_sha256(archive),
                                          "manifestSha256": companions.sha256_bytes(raw)}
        self.catalog["releases"][version] = release
        return archive

    def install(self, version="23.1.3-1", archive=None):
        with mock.patch.object(companions.urllib.request, "urlopen", side_effect=AssertionError("network forbidden")):
            return companions.install_companion(self.root, self.catalog, version, archive or self.archive)

    def assert_parent_unchanged(self):
        for path, (data, mode) in self.originals.items():
            self.assertEqual(path.read_bytes(), data)
            self.assertEqual(path.stat().st_mode, mode)

    def test_offline_install_and_idempotent_selection(self):
        tree = self.install()
        self.assertEqual((tree.parent / "current").readlink(), Path("23.1.3-1"))
        self.assertFalse(tree.stat().st_mode & 0o222)
        self.assertFalse((tree / "bin/llc").stat().st_mode & 0o222)
        self.assertEqual(self.install(), tree)
        with mock.patch.object(companions.urllib.request, "urlopen", side_effect=AssertionError("network forbidden")):
            self.assertEqual(companions.verify_installed(self.root, self.catalog), tree)
        self.assert_parent_unchanged()
        self.assertEqual(list(tree.parent.glob(".install-*")), [])

    def test_size_and_mtime_preserved_tamper_is_rejected(self):
        tree = self.install()
        path = tree / "lib/libLLVM.test"
        info = path.stat()
        data = path.read_bytes()
        path.chmod(0o644)
        path.write_bytes(bytes([data[0] ^ 1]) + data[1:])
        os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
        self.assertEqual(path.stat().st_size, info.st_size)
        self.assertEqual(path.stat().st_mtime_ns, info.st_mtime_ns)
        with self.assertRaisesRegex(ValueError, "file SHA-256 mismatch"):
            companions.verify_installed(self.root, self.catalog)
        with self.assertRaisesRegex(ValueError, "file SHA-256 mismatch"):
            self.install()
        self.assertEqual(path.read_bytes()[0], data[0] ^ 1)
        self.assert_parent_unchanged()

    def test_edited_manifest_cannot_accept_a_corrupt_file(self):
        tree = self.install()
        path = tree / "manifest.json"
        value = json.loads(path.read_text())
        value["files"]["lib/libLLVM.test"] = "0" * 64
        path.chmod(0o644)
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        with self.assertRaisesRegex(ValueError, "manifest SHA-256 mismatch"):
            companions.verify_installed(self.root, self.catalog)

    def test_bad_archive_preserves_old_selection(self):
        tree = self.install()
        archive = self.package("23.1.3-2")
        archive.write_bytes(archive.read_bytes() + b"changed after pinning")
        with self.assertRaisesRegex(ValueError, "archive SHA-256 mismatch"):
            self.install("23.1.3-2", archive)
        self.assertEqual((tree.parent / "current").readlink(), Path("23.1.3-1"))
        self.assertFalse((tree.parent / "23.1.3-2").exists())
        self.assert_parent_unchanged()

    def test_bad_members_preserve_old_selection(self):
        tree = self.install()
        for kind, name in [(tarfile.REGTYPE, "../escape"),
                           (tarfile.SYMTYPE, "root/link"),
                           (tarfile.LNKTYPE, "root/hard"),
                           (tarfile.CHRTYPE, "root/device")]:
            with self.subTest(kind=kind):
                archive = self.package("23.1.3-2")
                prefix = "abla-xtensa-llvm-23.1.3-2-" + self.host
                actual_name = name if name.startswith("..") else name.replace("root/", prefix + "/", 1)
                with tarfile.open(archive, "w:gz") as tar:
                    entry = tarfile.TarInfo(actual_name)
                    entry.type = kind
                    entry.linkname = "../../escape"
                    tar.addfile(entry)
                self.catalog["releases"]["23.1.3-2"]["platforms"][self.host]["sha256"] = companions.file_sha256(archive)
                with self.assertRaisesRegex(ValueError, "unsafe|links and special"):
                    self.install("23.1.3-2", archive)
                self.assertEqual((tree.parent / "current").readlink(), Path("23.1.3-1"))
                self.assertFalse((self.base / "escape").exists())
                self.assertEqual(list(tree.parent.glob(".install-*")), [])

    def test_corrupt_archive_never_executes_helpers(self):
        self.catalog["releases"]["23.1.3-1"]["platforms"][self.host]["sha256"] = "0" * 64
        with mock.patch.object(companions.subprocess, "run", side_effect=AssertionError("must not execute")):
            with self.assertRaisesRegex(ValueError, "archive SHA-256"):
                self.install()
        self.assertFalse((self.root / "lib/abla/xtensa-llvm/current").exists())

    def test_unpack_limit_preserves_old_selection(self):
        tree = self.install()
        archive = self.package("23.1.3-2")
        with mock.patch.object(companions, "MAX_UNPACKED_BYTES", 1):
            with self.assertRaisesRegex(ValueError, "unpacked"):
                self.install("23.1.3-2", archive)
        self.assertEqual((tree.parent / "current").readlink(), Path("23.1.3-1"))
        self.assertEqual(list(tree.parent.glob(".install-*")), [])

    def test_wrong_helper_version_is_not_activated(self):
        result = subprocess.CompletedProcess([], 0, stdout="LLVM version 23.1.30\nxtensa\n", stderr="")
        with mock.patch.object(companions.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(ValueError, "unexpected LLVM version"):
                self.install()
        self.assertFalse((self.root / "lib/abla/xtensa-llvm/current").exists())

    def test_atomic_activation_sees_only_complete_versions(self):
        tree = self.install()
        archive = self.package("23.1.3-2")
        original_replace = companions.os.replace
        observations = []
        def replace(source, destination):
            self.assertEqual(Path(destination).readlink(), Path("23.1.3-1"))
            self.assertEqual(Path(source).readlink(), Path("23.1.3-2"))
            self.assertTrue((tree.parent / "23.1.3-2/manifest.json").is_file())
            observations.append("complete before atomic selection")
            return original_replace(source, destination)
        with mock.patch.object(companions.os, "replace", side_effect=replace):
            self.install("23.1.3-2", archive)
        self.assertEqual(observations, ["complete before atomic selection"])
        self.assertEqual((tree.parent / "current").readlink(), Path("23.1.3-2"))
        self.assertTrue(tree.exists())
        self.assert_parent_unchanged()

    def test_current_regular_file_is_not_overwritten(self):
        directory = self.root / "lib/abla/xtensa-llvm"
        directory.mkdir(parents=True)
        (directory / "current").write_text("unrelated reserved-path file")
        with self.assertRaisesRegex(ValueError, "non-symlink"):
            self.install()
        self.assertEqual((directory / "current").read_text(), "unrelated reserved-path file")

    def test_packaged_entry_point_verify(self):
        module = self.root / "libexec/abla"
        subprocess.run(["bash", str(TOOLS / "package-xtensa-installer.sh"), str(self.root)], check=True)
        entry = self.root / "bin/abla-install-xtensa"
        catalog = self.root / "share/abla/xtensa-companions.json"
        catalog.write_text(json.dumps(self.catalog))
        result = subprocess.run([sys.executable, str(entry), "--version", "23.1.3-1", "--archive", str(self.archive)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run([sys.executable, str(entry), "--verify"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fully verified", result.stdout)
        self.assertFalse((module / "__pycache__").exists())
        self.assert_parent_unchanged()


if __name__ == "__main__":
    unittest.main()
