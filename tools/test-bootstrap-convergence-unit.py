#!/usr/bin/env python3
"""Small negative controls for the convergence gate, without compiler builds."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("convergence", Path(__file__).with_name("test-bootstrap-convergence.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ComparisonTests(unittest.TestCase):
    def test_shell_output_is_not_a_toolchain_closure_root(self):
        env = ("llvm_tools=/nix/store/llvm/bin\nopenssl=/nix/store/ssl/lib\n"
               "ldflags=-rpath /nix/store/not-realized-nix-shell/lib\n"
               "/nix/store/lld/bin/ld.lld\nLLD 23.1.3\n")
        self.assertEqual(gate.toolchain_stores(env), ["/nix/store/lld", "/nix/store/llvm", "/nix/store/ssl"])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dirs = [self.root / "a", self.root / "b"]
        self.manifests = []
        for which, directory in zip(["a", "b"], self.dirs):
            directory.mkdir()
            version, checksum = gate.SEEDS[which]
            names = ["stage2.ll", "stage3.ll", "stage2.bin", "stage3.bin", "stage2.o", "stage3.o", "environment.txt", "closure.txt"]
            for name in names:
                directory.joinpath(name).write_bytes(b"define i64 @main() { ret i64 42 }\n" if name.endswith(".ll") else b"identical\n")
            files = {name: gate.digest(directory / name) for name in names}
            stages = (["historical-1", "historical-2"] if which == "b" else []) + ["stage1", "stage2", "stage3"]
            builds, previous = [], checksum
            for name in stages:
                result = files.get(name + ".bin", name)
                builds.append(dict(name=name, source_revision=gate.HISTORICAL if name.startswith("historical-") else "candidate",
                                   input_sha256=previous, output_sha256=result))
                previous = result
            self.manifests.append(dict(schema=1, route=which, status="passed", probe_exit=42,
                                       candidate=dict(revision="candidate", tree="tree", archive_sha256="archive"),
                                       historical_revision=gate.HISTORICAL, historical_archive_sha256="historical",
                                       canonical_root=gate.CANONICAL_ROOT, entry=gate.ENTRY,
                                       representation="raw --emit-llvm, non-debug, pre-prune", settings={},
                                       seed=dict(version=version, sha256=checksum), builds=builds, files=files,
                                       toolchain=dict(environment_sha256=files["environment.txt"], closure_sha256=files["closure.txt"])))

    def check(self):
        for directory, manifest in zip(self.dirs, self.manifests):
            gate.write_json(directory / "manifest.json", manifest)
        gate.compare(*self.dirs, self.root / "comparison")

    def test_identical_complete_routes(self):
        self.check()
        self.assertTrue(json.loads((self.root / "comparison/comparison.json").read_text())["passed"])

    def test_no_seed_substitution(self):
        self.manifests[1]["seed"] = copy.deepcopy(self.manifests[0]["seed"])
        with self.assertRaisesRegex(ValueError, "wrong seed"):
            self.check()

    def test_missing_historical_stage(self):
        self.manifests[1]["builds"].pop(0)
        with self.assertRaisesRegex(ValueError, "missing bootstrap stage"):
            self.check()

    def test_broken_chain(self):
        self.manifests[1]["builds"][2]["input_sha256"] = "published replacement"
        with self.assertRaisesRegex(ValueError, "broken bootstrap chain"):
            self.check()

    def test_incomplete_route(self):
        self.manifests[1]["status"] = "incomplete"
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.check()

    def test_different_source(self):
        self.manifests[1]["candidate"]["archive_sha256"] = "different"
        with self.assertRaisesRegex(ValueError, "provenance differs: candidate"):
            self.check()

    def test_same_stale_revision_on_both_routes(self):
        for directory, manifest in zip(self.dirs, self.manifests):
            gate.write_json(directory / "manifest.json", manifest)
        with self.assertRaisesRegex(ValueError, "not the dispatched source"):
            gate.compare(*self.dirs, self.root / "comparison", expected_revision="new dispatch")

    def test_changed_ir_even_with_updated_manifest(self):
        for stage in [2, 3]:
            name = f"stage{stage}.ll"
            (self.dirs[1] / name).write_text('; abla.source="/different/root"\n')
            self.manifests[1]["files"][name] = gate.digest(self.dirs[1] / name)
        with self.assertRaisesRegex(ValueError, "differs.*byte"):
            self.check()

    def test_corrupted_artifact(self):
        (self.dirs[1] / "stage2.ll").write_text("truncated")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.check()

    def test_missing_artifact(self):
        (self.dirs[1] / "stage3.o").unlink()
        with self.assertRaises(FileNotFoundError):
            self.check()

    def test_no_fixed_point(self):
        name = "stage3.ll"
        (self.dirs[1] / name).write_text("not a fixed point")
        self.manifests[1]["files"][name] = gate.digest(self.dirs[1] / name)
        with self.assertRaisesRegex(ValueError, "differs.*byte"):
            self.check()


class LineageTests(unittest.TestCase):
    """The pairs of routes the gate knows, selected by --lineage."""

    def tearDown(self):
        gate.configure("v0.2.45")

    def test_default_is_the_first_pair(self):
        self.assertEqual(gate.HISTORICAL, "ca9221b0615cd419284a9e8e9f671bf8429ccd3b")
        self.assertEqual(gate.SEEDS["a"][0], "v0.2.45")
        self.assertEqual(gate.SEEDS["b"][0], "v0.2.44")

    def test_every_lineage_is_a_distinct_pinned_pair(self):
        for name, lineage in gate.LINEAGES.items():
            self.assertRegex(lineage["historical"], r"^[0-9a-f]{40}$", name)
            self.assertEqual(sorted(lineage["seeds"]), ["a", "b"], name)
            self.assertEqual(lineage["seeds"]["a"][0], name, "route A starts from the bridge tag's own release")
            self.assertNotEqual(lineage["seeds"]["a"][0], lineage["seeds"]["b"][0], name)
            for version, checksum in lineage["seeds"].values():
                self.assertRegex(checksum, r"^[0-9a-f]{64}$", version)

    def test_configure_selects_and_refuses(self):
        gate.configure("v0.2.51")
        self.assertEqual(gate.SEEDS["a"][0], "v0.2.51")
        self.assertEqual(gate.SEEDS["b"][0], "v0.2.50")
        self.assertEqual(gate.HISTORICAL, "1758d94e64b0e7f31f22107f8556fd63dc4351c6")
        with self.assertRaisesRegex(ValueError, "unknown lineage"):
            gate.configure("v9.9.9")
        self.assertEqual(gate.SEEDS["a"][0], "v0.2.51", "a refused lineage leaves the selection alone")

    def test_root_defaults_and_is_selectable(self):
        self.assertEqual(gate.CANONICAL_ROOT, "/build/source")
        gate.configure("v0.2.45", "/scratch/build/source")
        self.assertEqual(gate.CANONICAL_ROOT, "/scratch/build/source")
        gate.configure("v0.2.45")
        self.assertEqual(gate.CANONICAL_ROOT, "/build/source", "the next configure without a root restores the default")

    def test_routes_of_two_roots_are_refused(self):
        first = ComparisonTests("test_identical_complete_routes")
        first.setUp()
        try:
            for directory, manifest in zip(first.dirs, first.manifests):
                gate.write_json(directory / "manifest.json", manifest)
            gate.configure("v0.2.45", "/elsewhere/build/source")
            with self.assertRaisesRegex(ValueError, "wrong IR contract"):
                gate.compare(*first.dirs, first.root / "comparison")
        finally:
            first.doCleanups()

    def test_a_route_of_another_lineage_is_refused(self):
        # A manifest built for the first pair must not pass the comparison of the newer one.
        first = ComparisonTests("test_identical_complete_routes")
        first.setUp()
        try:
            for directory, manifest in zip(first.dirs, first.manifests):
                gate.write_json(directory / "manifest.json", manifest)
            gate.configure("v0.2.51")
            with self.assertRaisesRegex(ValueError, "wrong seed"):
                gate.compare(*first.dirs, first.root / "comparison")
        finally:
            first.doCleanups()


if __name__ == "__main__":
    unittest.main()
