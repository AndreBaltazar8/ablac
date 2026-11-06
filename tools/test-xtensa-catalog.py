#!/usr/bin/env python3
"""Offline catalog negatives; live CI check is xtensa_companions.py --check."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import sys
sys.dont_write_bytecode = True
import xtensa_companions as companions


class Catalog(unittest.TestCase):
    def setUp(self):
        version = "23.1.3-1"
        self.catalog = {"schema": 1, "releases": {version: {
            "status": "published", "llvmVersion": "23.1.3", "sourceCommit": "a" * 40,
            "sourceArchiveSha256": "b" * 64, "platforms": {},
        }}}
        self.responses = {}
        self.index = []
        tag = "abla-xtensa-llvm-" + version
        for host in sorted(companions.PLATFORMS):
            archive = tag + "-" + host + ".tar.gz"
            url = companions.RELEASES + "/" + tag + "/" + archive
            manifest = {"schema": 1, "version": tag, "platform": host,
                        "llvmVersion": "23.1.3", "sourceCommit": "a" * 40,
                        "sourceArchiveSha256": "b" * 64}
            sha = companions.sha256_bytes(host.encode())
            self.catalog["releases"][version]["platforms"][host] = {
                "url": url, "sha256": sha, "manifestSha256": companions.manifest_sha256(manifest)}
            self.index.append({"platform": host, "archive": archive, "sha256": sha, "manifest": manifest})
            self.responses[url + ".sha256"] = (sha + "  " + archive + "\n").encode()
        self.index_url = companions.RELEASES + "/" + tag + "/manifest.json"
        self.responses[self.index_url] = json.dumps(self.index).encode()

    def load(self, catalog=None):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "catalog.json"
            path.write_text(json.dumps(self.catalog if catalog is None else catalog))
            return companions.load_catalog(path)

    def fetch(self, url, limit):
        self.assertNotIn(url.rsplit("/", 1)[1], [row["archive"] for row in self.index])
        value = self.responses[url]
        self.assertLessEqual(len(value), limit)
        return value

    def test_schema_and_published_match(self):
        self.assertEqual(len(companions.check_published(self.load(), self.fetch)), 3)

    def test_changed_published_checksum_fails(self):
        for url, data in list(self.responses.items()):
            if url.endswith(".sha256"):
                self.responses[url] = b"0" * 64 + data[64:]
                with self.assertRaisesRegex(ValueError, "published .sha256 mismatch"):
                    companions.check_published(self.load(), self.fetch)
                self.responses[url] = data

    def test_catalog_pin_mismatch_fails_ci_check(self):
        data = copy.deepcopy(self.catalog)
        entry = next(iter(data["releases"]["23.1.3-1"]["platforms"].values()))
        entry["sha256"] = "f" * 64
        with self.assertRaisesRegex(ValueError, "published .sha256 mismatch"):
            companions.check_published(self.load(data), self.fetch)

    def test_manifest_tamper_fails(self):
        tampered = copy.deepcopy(self.index)
        tampered[0]["manifest"]["unexpected"] = "edited after publication"
        self.responses[self.index_url] = json.dumps(tampered).encode()
        with self.assertRaisesRegex(ValueError, "published manifest hash mismatch"):
            companions.check_published(self.load(), self.fetch)

    def test_pins_cannot_redirect_to_another_asset(self):
        data = copy.deepcopy(self.catalog)
        entry = next(iter(data["releases"]["23.1.3-1"]["platforms"].values()))
        entry["url"] = "https://example.com/other.tar.gz"
        with self.assertRaisesRegex(ValueError, "unexpected release URL"):
            self.load(data)

    def test_malformed_schema_is_a_named_error(self):
        for data in ([], {"schema": 1, "releases": {"23.1.3-1": []}}):
            with self.subTest(data=data), self.assertRaises(ValueError):
                self.load(data)
        for malformed in ([], {"x86_64-linux": []}):
            data = copy.deepcopy(self.catalog)
            data["releases"]["23.1.3-1"]["platforms"] = malformed
            with self.subTest(platforms=malformed), self.assertRaises(ValueError):
                self.load(data)

    def test_unpublished_fixture_is_test_only(self):
        path = Path(__file__).with_name('fixtures') / 'xtensa-companion-unpublished.json'
        fixture = json.loads(path.read_text())
        self.assertEqual(fixture['status'], 'UNPUBLISHED_TEST_FIXTURE')
        self.assertEqual(fixture['sourceRun'], 42214578962)
        self.assertIn('never packaged', fixture['purpose'])
        self.assertEqual(set(self.load(fixture['catalog'])['releases']), {'23.1.3-1'})
        with self.assertRaises(ValueError):
            self.load(fixture)

    def test_pending_is_not_a_valid_pin(self):
        data = copy.deepcopy(self.catalog)
        data["releases"]["23.1.3-1"]["status"] = "pending-publication"
        with self.assertRaisesRegex(ValueError, "pending publication"):
            self.load(data)

    def test_empty_catalog_cannot_bypass_the_check(self):
        with self.assertRaisesRegex(ValueError, "no published revisions"):
            self.load({"schema": 1, "releases": {}})

    def test_missing_platform_is_not_accepted(self):
        self.index.pop()
        self.responses[self.index_url] = json.dumps(self.index).encode()
        with self.assertRaisesRegex(ValueError, "unexpected release index"):
            companions.check_published(self.load(), self.fetch)


if __name__ == "__main__":
    unittest.main()
