"""A unit's reported cache name may disappear before its parent uses the part."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
# Absolute, not resolved: build/ablac is a symlink to a launcher that finds
# its payload beside the name it was run as.
compiler = os.path.abspath(sys.argv[1])
(root / "build/codegen-cache-race").mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix="run-", dir=root / "build/codegen-cache-race"))
a = root / "tests/cases/codegen-cache/concurrent-a.ab"
b = root / "tests/cases/codegen-cache/concurrent-b.ab"
env = dict(os.environ, ABLA_CODEGEN_UNITS="8", ABLA_CODEGEN_UNITS_MINIMUM="0",
           ABLA_CODEGEN_JOBS="1", ABLA_NATIVE_JOBS="1", ABLA_CODEGEN_UNITS_TRACE="1",
           ABLA_MAX_MEMORY_MB="2048")
for name in ("ABLA_CODEGEN_TEST_BARRIER", "ABLA_CODEGEN_TEST_COPY_HITS",
             "ABLA_CODEGEN_TEST_EVICT_BEFORE_PIN", "ABLA_CODEGEN_CACHE",
             "ABLA_KEEP_LLVM_TEXT", "ABLA_COMPILE_EVAL"):
    env.pop(name, None)
results = {"directory": str(out), "gates": [], "concurrent": []}


def command(source, output, cache):
    return [compiler, "build", str(source), "-o", str(output), "--fast",
            "--no-cache", "--cache-dir", str(cache)]


def build(source, output, cache, label, changes=None):
    configured = dict(env, ABLA_CODEGEN_CACHE_MB="2048")
    configured.update(changes or {})
    with (out / (label + ".log")).open("wb") as log:
        result = subprocess.run(command(source, output, cache), cwd=root,
                                env=configured, stdout=log, stderr=subprocess.STDOUT,
                                timeout=120)
    assert result.returncode == 0, (label, result.returncode, str(out))
    return output.with_name(output.name + ".o").read_bytes()


def execute(path):
    result = subprocess.run([str(path)], capture_output=True, timeout=30)
    assert result.returncode == 42, (path, result.returncode, result.stdout, result.stderr)


def members(path):
    names = subprocess.check_output(["llvm-ar", "t", str(path)], text=True).splitlines()
    assert len(names) > 1 and all(re.fullmatch(r"unit[0-9]+\.o", n) for n in names), names
    return names


def eviction_gate(mode, external_cache=None):
    directory = out / mode
    directory.mkdir()
    cache = external_cache or directory / "cache"
    output = directory / "victim"
    expected = build(a, output, cache, mode + "-cacheless", {"ABLA_CODEGEN_CACHE": "0"})
    expected_members = members(output.with_name(output.name + ".o"))
    execute(output)
    warm = mode != "cold"
    if warm:
        assert build(a, output, cache, mode + "-prime") == expected
        for entry in (cache / "codegen").glob("*.o"):
            os.utime(entry, ns=(1_000_000_000, 1_000_000_000))
    gate = directory / "gate"
    gate.mkdir()
    configured = dict(env, ABLA_CODEGEN_CACHE_MB="2048", ABLA_CODEGEN_TEST_BARRIER=str(gate))
    if mode == "copy":
        configured["ABLA_CODEGEN_TEST_COPY_HITS"] = "1"
        if sys.platform == "darwin":
            # Prove the fallback when cp -c/clonefile is unsupported too.
            shim = directory / "shim"
            shim.mkdir()
            real_cp = shutil.which("cp")
            (shim / "cp").write_text('#!/bin/sh\nif [ "$1" = "-c" ]; then exit 1; fi\nexec "$ABLA_TEST_REAL_CP" "$@"\n')
            (shim / "cp").chmod(0o755)
            configured["ABLA_TEST_REAL_CP"] = real_cp
            configured["PATH"] = str(shim) + os.pathsep + configured["PATH"]
    log_path = out / (mode + "-victim.log")
    with log_path.open("wb") as log:
        victim = subprocess.Popen(command(a, output, cache), cwd=root, env=configured,
                                  stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 60
            while not (gate / "ready").exists():
                assert victim.poll() is None, (mode, "victim stopped before barrier", str(log_path))
                assert time.monotonic() < deadline, (mode, "barrier timeout")
                time.sleep(0.01)
            # The driver emits to a PID-qualified temporary object, and on
            # Darwin also uses a private publication directory.
            reports = sorted(directory.rglob("unit*.o.path"))
            assert reports, (mode, "no child reports")
            protected = []
            for report in reports:
                entry_text, reused = report.read_text().splitlines()
                entry = Path(entry_text)
                part = Path(str(report)[:-5])
                assert part.is_file() and entry.is_file(), (mode, part, entry)
                assert part.read_bytes() == entry.read_bytes(), (mode, "part bytes")
                assert reused == ("1" if warm else "0"), (mode, reused)
                private = (part.stat().st_dev, part.stat().st_ino)
                shared = (entry.stat().st_dev, entry.stat().st_ino)
                if mode in ("copy", "xdev"):
                    assert private != shared, (mode, "must own independent copied bytes")
                else:
                    assert private == shared, (mode, "same-filesystem acquisition/publication should hard-link")
                if warm:
                    assert entry.stat().st_mtime_ns > 1_000_000_000, (mode, "hit did not refresh LRU")
                protected.append((entry, part, part.read_bytes()))
            # A separate real compiler protects only its own entries; zero limit
            # removes at least the victim's distinct data/function entry.
            build(b, directory / "sweeper", cache, mode + "-sweeper",
                  {"ABLA_CODEGEN_CACHE_MB": "0"})
            deleted = [str(entry) for entry, _, _ in protected if not entry.exists()]
            assert deleted, (mode, "real sweep did not evict a victim entry")
            for _, part, content in protected:
                assert part.read_bytes() == content, (mode, "sweep damaged private bytes")
            (gate / "release").touch()
            assert victim.wait(timeout=120) == 0, (mode, "victim failed", str(log_path))
            assert output.with_name(output.name + ".o").read_bytes() == expected, (mode, "archive changed")
            assert members(output.with_name(output.name + ".o")) == expected_members
            execute(output)
            results["gates"].append({"mode": mode, "evicted": deleted, "parts": len(reports)})
        finally:
            (gate / "release").touch()
            if victim.poll() is None:
                victim.terminate()
                victim.wait(timeout=10)
    print("codegen cache race:", mode, "survived a real concurrent sweep", flush=True)


for mode in ("cold", "hit", "copy"):
    eviction_gate(mode)

# Exercise an actual cross-device link failure when a separate temporary
# filesystem is available. Darwin's copy gate also tests clonefile failure.
shm = Path("/dev/shm")
if (shm.is_dir() and shm.stat().st_dev != out.stat().st_dev and
        shutil.disk_usage(shm).free > 16 * 1024 * 1024):
    cache = Path(tempfile.mkdtemp(prefix="abla-codegen-race-", dir=shm))
    try:
        eviction_gate("xdev", cache)
    finally:
        shutil.rmtree(cache)

# A hit that loses its name before link/open must regenerate, not report a
# successful hit or leave a partial destination behind.
cache = out / "vanish-cache"
output = out / "vanish"
expected = build(a, output, cache, "vanish-prime")
assert build(a, output, cache, "vanish-rebuild",
             {"ABLA_CODEGEN_TEST_EVICT_BEFORE_PIN": "1"}) == expected
assert re.search(r", 0 reused$", (out / "vanish-rebuild.log").read_text(), re.M)
execute(output)
results["gates"].append({"mode": "vanished-before-pin", "regenerated": True})

# Publication failures must not turn a completed private part into a failed
# build. Actual permissions (not a hook) refuse both link and copy publication.
readonly = out / "readonly-cache"
readonly.mkdir()
entries = readonly / "codegen"
entries.mkdir()
entries.chmod(0o555)
try:
    assert not os.access(entries, os.W_OK), "read-only regression needs an unprivileged user"
    actual = build(a, out / "readonly", readonly, "readonly")
    assert actual == expected, "read-only cache changed archive"
    assert not list(entries.iterdir()), "read-only cache unexpectedly published"
    execute(out / "readonly")
finally:
    entries.chmod(0o755)
results["gates"].append({"mode": "readonly-publication", "ignored": True})

# An unusable optional cache directory must also retain the generated parts.
blocked = out / "blocked-cache"
blocked.mkdir()
(blocked / "codegen").write_text("not a directory")
assert build(a, out / "blocked", blocked, "blocked") == expected
execute(out / "blocked")
results["gates"].append({"mode": "unavailable-directory", "ignored": True})

# The real application's original shape: four workers, eight builds each,
# one shared zero-limit cache, one unit child per worker (at most four jobs).
cache = out / "concurrent-cache"
reference = {str(source): build(source, out / ("reference-" + source.stem),
                                cache, "reference-" + source.stem,
                                {"ABLA_CODEGEN_CACHE": "0"})
             for source in (a, b)}

def worker(index):
    source = a if index % 2 else b
    for run in range(8):
        output = out / ("worker-%d-%d" % (index, run))
        label = "worker-%d-%d" % (index, run)
        actual = build(source, output, cache, label, {"ABLA_CODEGEN_CACHE_MB": "0"})
        assert actual == reference[str(source)], (label, "archive differs from cacheless build")
        execute(output)
        results["concurrent"].append([index, run, 0])

with ThreadPoolExecutor(max_workers=4) as workers:
    list(workers.map(worker, range(1, 5)))
assert len(results["concurrent"]) == 32
(out / "results.json").write_text(json.dumps(results, indent=2))
print("codegen cache race: 4x8 concurrent zero-limit builds, 0/32 failures;", out, flush=True)
