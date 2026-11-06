#!/usr/bin/env python3
"""The optional Xtensa companion catalog and published-checksum check (stdlib only)."""
import argparse
import hashlib
import json
import os
import platform
import shutil
import stat
import subprocess
import tarfile
import tempfile
import uuid
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.request

PLATFORMS = {"x86_64-linux", "arm64-macos", "x86_64-macos"}
RELEASES = "https://github.com/AndreBaltazar8/llvm-project/releases/download"
CATALOG = Path(__file__).with_name("xtensa-companions.json")


def sha256_bytes(contents):
    return hashlib.sha256(contents).hexdigest()


def manifest_sha256(value):
    # This is the exact serialization used by the fork's package producer.
    return sha256_bytes((json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def _hex(value, size, label):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{" + str(size) + r"}", value):
        raise ValueError(f"invalid {label}")


def load_catalog(path=CATALOG):
    data = json.loads(Path(path).read_text())
    if not isinstance(data, dict) or data.get("schema") != 1 or not isinstance(data.get("releases"), dict):
        raise ValueError("unsupported companion catalog schema")
    if not data["releases"]:
        raise ValueError("companion catalog has no published revisions")
    for version, release in data["releases"].items():
        if not isinstance(release, dict):
            raise ValueError("companion release must be an object")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*", version):
            raise ValueError("invalid companion revision")
        if release.get("status") != "published":
            raise ValueError(f"companion {version} is pending publication")
        if release.get("llvmVersion") != version.rsplit("-", 1)[0]:
            raise ValueError(f"LLVM version mismatch for {version}")
        _hex(release.get("sourceCommit"), 40, "source commit")
        _hex(release.get("sourceArchiveSha256"), 64, "source archive SHA-256")
        if not isinstance(release.get("platforms"), dict) or set(release["platforms"]) != PLATFORMS:
            raise ValueError(f"companion {version} must pin all three platforms")
        tag = "abla-xtensa-llvm-" + version
        for host, entry in release["platforms"].items():
            if not isinstance(entry, dict):
                raise ValueError("companion platform must be an object")
            expected = f"{RELEASES}/{tag}/{tag}-{host}.tar.gz"
            if entry.get("url") != expected:
                raise ValueError(f"unexpected release URL for {version}/{host}")
            _hex(entry.get("sha256"), 64, "archive SHA-256")
            _hex(entry.get("manifestSha256"), 64, "manifest SHA-256")
    return data


def fetch_metadata(url, limit):
    request = urllib.request.Request(url, headers={"User-Agent": "abla-xtensa-catalog-check"})
    for attempt in range(2):
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                contents = response.read(limit + 1)
            if len(contents) > limit:
                raise ValueError(f"release metadata exceeds its size limit: {url}")
            return contents
        except urllib.error.HTTPError as error:
            if attempt or error.code not in (408, 429, 500, 502, 503, 504):
                raise
        except urllib.error.URLError:
            if attempt:
                raise
        time.sleep(0.5)
    raise AssertionError("unreachable metadata retry")


def check_published(catalog, fetch=fetch_metadata):
    """Only fetch small checksums/indexes; never archives, tools or LLVM sources."""
    checked = []
    for version, release in catalog["releases"].items():
        tag = "abla-xtensa-llvm-" + version
        index_url = f"{RELEASES}/{tag}/manifest.json"
        index = json.loads(fetch(index_url, 1024 * 1024))
        if not isinstance(index, list) or len(index) != len(PLATFORMS):
            raise ValueError(f"unexpected release index: {version}")
        by_host = {row["platform"]: row for row in index}
        if set(by_host) != PLATFORMS:
            raise ValueError(f"release index platform mismatch: {version}")
        for host, entry in release["platforms"].items():
            name = entry["url"].rsplit("/", 1)[1]
            sidecar = fetch(entry["url"] + ".sha256", 4096).decode("ascii").split()
            if sidecar != [entry["sha256"], name]:
                raise ValueError(f"published .sha256 mismatch: {version}/{host}")
            row = by_host[host]
            if row["archive"] != name or row["sha256"] != entry["sha256"]:
                raise ValueError(f"release index archive mismatch: {version}/{host}")
            manifest = row["manifest"]
            expected = {"version": tag, "platform": host, "schema": 1,
                        "llvmVersion": release["llvmVersion"], "sourceCommit": release["sourceCommit"],
                        "sourceArchiveSha256": release["sourceArchiveSha256"]}
            for key, value in expected.items():
                if manifest.get(key) != value:
                    raise ValueError(f"release manifest {key} mismatch: {version}/{host}")
            if manifest_sha256(manifest) != entry["manifestSha256"]:
                raise ValueError(f"published manifest hash mismatch: {version}/{host}")
            checked.append(f"{version}/{host}")
    return checked



HOSTS = {("Linux", "x86_64"): "x86_64-linux", ("Darwin", "arm64"): "arm64-macos",
         ("Darwin", "x86_64"): "x86_64-macos"}
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_UNPACKED_BYTES = 1024 * 1024 * 1024


def host_platform():
    host = HOSTS.get((platform.system(), platform.machine()))
    if host is None:
        raise ValueError("supported companion hosts: x86_64 Linux, arm64 macOS and x86_64 macOS")
    return host


def file_sha256(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def _release(catalog, version, host):
    release = catalog["releases"].get(version)
    if release is None:
        raise ValueError(f"unknown companion revision: {version}")
    return release, release["platforms"][host]


def _toolchain_root(path):
    root = Path(path).resolve()
    if not (root / "libexec/ablac.bin").is_file():
        raise ValueError(f"not an Abla toolchain root (missing libexec/ablac.bin): {root}")
    return root


def _copy_archive(stream, target, expected):
    result, total = hashlib.sha256(), 0
    with target.open("xb") as output:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_ARCHIVE_BYTES:
                raise ValueError("companion archive exceeds 512 MiB")
            result.update(chunk)
            output.write(chunk)
    if result.hexdigest() != expected:
        raise ValueError("companion archive SHA-256 mismatch; nothing was activated")


def _extract_archive(archive, destination, expected_root):
    seen, total = set(), 0
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            name = member.name.rstrip("/")
            parts = name.split("/")
            if (not parts or parts[0] != expected_root or
                    any(part in ("", ".", "..") for part in parts) or name.startswith("/")):
                raise ValueError("unsafe companion archive path")
            if name in seen or len(seen) >= 1024:
                raise ValueError("duplicate or excessive companion archive members")
            if not (member.isdir() or member.isfile()):
                raise ValueError("companion archive links and special files are not allowed")
            seen.add(name)
            total += member.size
            if member.size < 0 or total > MAX_UNPACKED_BYTES:
                raise ValueError("companion archive exceeds 1 GiB unpacked")
            path = destination.joinpath(*parts)
            if member.isdir():
                path.mkdir(mode=0o700, parents=True, exist_ok=True)
            else:
                path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with source.extractfile(member) as content, path.open("xb") as output:
                    shutil.copyfileobj(content, output, length=1024 * 1024)
                path.chmod(0o555 if member.mode & 0o111 else 0o444)
    root = destination / expected_root
    if not root.is_dir():
        raise ValueError("companion archive has no expected root directory")
    return root


def _verify_tree(root, release, entry, version, host):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("installed companion must be a real directory")
    manifest_file = root / "manifest.json"
    if manifest_file.is_symlink() or not manifest_file.is_file():
        raise ValueError("companion manifest is missing or is a link")
    if not 0 < manifest_file.stat().st_size <= 65536:
        raise ValueError("companion manifest exceeds its size limit")
    raw = manifest_file.read_bytes()
    if sha256_bytes(raw) != entry["manifestSha256"]:
        raise ValueError("companion manifest SHA-256 mismatch")
    manifest = json.loads(raw)
    expected = {"schema": 1, "version": "abla-xtensa-llvm-" + version, "platform": host,
                "llvmVersion": release["llvmVersion"], "sourceCommit": release["sourceCommit"],
                "sourceArchiveSha256": release["sourceArchiveSha256"]}
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"companion manifest {key} mismatch")
    files = manifest.get("files")
    if not isinstance(files, dict) or not {"bin/opt", "bin/llc"}.issubset(files):
        raise ValueError("companion manifest is missing its opt/llc file hashes")
    if not any(name.startswith("lib/libLLVM") for name in files):
        raise ValueError("companion manifest is missing its private LLVM library")
    actual = set()
    for path in root.rglob("*"):
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise ValueError("installed companion contains a link or special file")
        if path.is_file():
            actual.add(str(path.relative_to(root)))
    if actual != set(files) | {"manifest.json"}:
        raise ValueError("companion file set differs from its pinned manifest")
    # Deliberately never skip hashing because a size/mtime or receipt is unchanged.
    for name, expected_hash in files.items():
        _hex(expected_hash, 64, "file SHA-256")
        if file_sha256(root / name) != expected_hash:
            raise ValueError(f"companion file SHA-256 mismatch: {name}")
    for name in ("opt", "llc"):
        path = root / "bin" / name
        if not os.access(path, os.X_OK):
            raise ValueError(f"companion helper is not executable: {name}")
    return manifest


def _check_tools(root, llvm_version):
    environment = dict(os.environ)
    if platform.system() == "Darwin":
        environment["DYLD_LIBRARY_PATH"] = str(root / "lib")
    for name in ("opt", "llc"):
        result = subprocess.run([str(root / "bin" / name), "--version"], env=environment,
                                capture_output=True, text=True, timeout=30, check=True)
        if not re.search(r"LLVM version " + re.escape(llvm_version) + r"(?:\s|$)", result.stdout):
            raise ValueError(f"unexpected LLVM version in companion {name}")
        if name == "llc" and "xtensa" not in result.stdout.lower():
            raise ValueError("companion llc has no Xtensa backend")


def _active_version(directory):
    current = directory / "current"
    if not current.is_symlink():
        raise ValueError("no active companion symlink; install an explicit --version")
    selected = current.readlink()
    if selected.is_absolute() or len(selected.parts) != 1 or selected.name in (".", ".."):
        raise ValueError("active companion link does not name a managed revision")
    return selected.name


def _activate(directory, version):
    current = directory / "current"
    if current.exists() and not current.is_symlink():
        raise ValueError("refusing to replace a non-symlink companion selection")
    temporary = directory / (".current-" + uuid.uuid4().hex)
    try:
        temporary.symlink_to(version)
        os.replace(temporary, current)
    finally:
        if temporary.is_symlink():
            temporary.unlink()


def verify_installed(toolchain_root, catalog, version=None):
    host, root = host_platform(), _toolchain_root(toolchain_root)
    directory = root / "lib/abla/xtensa-llvm"
    selected = version if version is not None else _active_version(directory)
    release, entry = _release(catalog, selected, host)
    tree = directory / selected
    _verify_tree(tree, release, entry, selected, host)
    _check_tools(tree, release["llvmVersion"])
    return tree


def install_companion(toolchain_root, catalog, version, archive=None):
    host, root = host_platform(), _toolchain_root(toolchain_root)
    release, entry = _release(catalog, version, host)
    directory = root / "lib/abla/xtensa-llvm"
    current = directory / "current"
    if current.exists() and not current.is_symlink():
        raise ValueError("refusing to replace a non-symlink companion selection")
    final = directory / version
    if final.exists() or final.is_symlink():
        _verify_tree(final, release, entry, version, host)
        _check_tools(final, release["llvmVersion"])
        _activate(directory, version)
        return final
    directory.mkdir(mode=0o755, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".install-" + version + "-", dir=directory) as temp:
        staging = Path(temp)
        downloaded = staging / "companion.tar.gz"
        if archive is not None:
            with Path(archive).open("rb") as content:
                _copy_archive(content, downloaded, entry["sha256"])
        else:
            request = urllib.request.Request(entry["url"], headers={"User-Agent": "abla-install-xtensa"})
            with urllib.request.urlopen(request, timeout=30) as content:
                _copy_archive(content, downloaded, entry["sha256"])
        name = "abla-xtensa-llvm-" + version + "-" + host
        tree = _extract_archive(downloaded, staging, name)
        _verify_tree(tree, release, entry, version, host)
        _check_tools(tree, release["llvmVersion"])
        try:
            tree.rename(final)
        except OSError:
            # A concurrent install may have won the rename. Never overwrite it.
            if not final.exists() or final.is_symlink():
                raise
            _verify_tree(final, release, entry, version, host)
            _check_tools(final, release["llvmVersion"])
        for path in [*sorted(final.rglob("*"), reverse=True), final]:
            if path.is_dir():
                path.chmod(0o555)
        _activate(directory, version)
    return final


def installer_main(default_root=None, default_catalog=CATALOG):
    parser = argparse.ArgumentParser(description="Explicit verified installation of optional Xtensa LLVM tools")
    parser.add_argument("--toolchain-root", type=Path, default=default_root)
    parser.add_argument("--catalog", type=Path, default=default_catalog)
    parser.add_argument("--version", help="companion revision, for example 23.1.3-1")
    parser.add_argument("--archive", type=Path, help="offline copy; still checked against the pinned catalog")
    parser.add_argument("--verify", action="store_true", help="fully hash installed files; never download or activate")
    args = parser.parse_args()
    if args.toolchain_root is None:
        parser.error("source installer needs --toolchain-root")
    if args.verify and args.archive is not None:
        parser.error("--archive cannot be combined with --verify")
    if not args.verify and args.version is None:
        parser.error("installation needs an explicit --version")
    try:
        catalog = load_catalog(args.catalog)
        if args.verify:
            tree = verify_installed(args.toolchain_root, catalog, args.version)
            print(f"Xtensa companion fully verified: {tree}")
        else:
            tree = install_companion(args.toolchain_root, catalog, args.version, args.archive)
            print(f"Xtensa companion installed and selected: {tree}")
    except (ValueError, KeyError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, f"abla-install-xtensa: {error}\n")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--check", action="store_true", help="compare pins with the fork's published metadata")
    args = parser.parse_args()
    try:
        catalog = load_catalog(args.catalog)
        if args.check:
            for checked in check_published(catalog):
                print(f"Xtensa companion catalog: {checked} matches published checksums")
        else:
            print("Xtensa companion catalog: schema and all pinned URLs/hashes valid")
    except (ValueError, KeyError, OSError, urllib.error.URLError) as error:
        parser.exit(1, f"Xtensa companion catalog: {error}\n")


if __name__ == "__main__":
    main()
