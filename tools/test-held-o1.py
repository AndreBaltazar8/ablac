#!/usr/bin/env python3
"""Held native O1: artifact identity, exact ELF section cutoff and cache modes."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

if sys.platform != "linux":
    print("held O1: Linux ELF path only")
    raise SystemExit(0)
root = Path(__file__).resolve().parent.parent
compiler = Path(sys.argv[1] if len(sys.argv) > 1 else root / "build/ablac").absolute()
work = Path(tempfile.mkdtemp(prefix="held-o1-", dir=root / "build"))
cache = work / "cache"
source = work / "main.ab"
output = work / "program"
env = dict(os.environ, ABLA_SYSROOT=os.environ.get("ABLA_SYSROOT", str(root)),
           ABLA_CACHE_DIR=str(cache), ABLA_COMPILER_MEMORY_TRACE="1")
for key in ("ABLA_KEEP_LLVM_TEXT", "ABLA_LLVM_OUT_OF_PROCESS"):
    env.pop(key, None)


def build(label, flags=(), settings=None):
    process = subprocess.run([str(compiler), "build", str(source), "-o", str(output),
                              "--o1", *flags], cwd=work,
                             env=dict(env, **(settings or {})), capture_output=True)
    (work / (label + ".log")).write_bytes(process.stdout + process.stderr)
    assert process.returncode == 0, (label, process.returncode, process.stderr.decode())
    return process.stderr.decode()


def run(expected):
    assert subprocess.run([str(output)], cwd=work).returncode == expected


def text():
    return Path(str(output) + ".ll")


try:
    # Taking a function's address demands its boxed ELF wrapper and its section.
    source.write_text("fun twice(value: int): int = value * 2\n"
                      "val callback: (int) -> int = twice\n"
                      "fun main: int = callback(21)\n")
    assert "frontend.lowering.begin" in build("cold")
    assert not text().exists()
    run(42)
    cold = output.read_bytes()
    members = list(cache.glob("native-*-inprocess-o1-held-o1-single-v1-*.o"))
    assert len(members) == 1, members
    text().write_text("held-o1-cache-marker\n")
    assert "frontend.lowering.begin" not in build("warm")
    assert text().read_text() == "held-o1-cache-marker\n"
    assert output.read_bytes() == cold
    # A frontend/cache record without its object is a miss, not a stale hit.
    members[0].rename(str(members[0]) + ".missing")
    assert "frontend.lowering.begin" in build("missing-object")
    assert output.read_bytes() == cold
    assert not text().exists()
    source.write_text(source.read_text().replace("callback(21)", "callback(22)"))
    assert "frontend.lowering.begin" in build("edited")
    run(44)
    held = output.read_bytes()
    assert "frontend.lowering.begin" in build("keep-text", settings={"ABLA_KEEP_LLVM_TEXT": "1"})
    assert text().is_file()
    run(44)
    fallback = output.read_bytes()
    assert "frontend.lowering.begin" not in build("held-after-text")
    assert output.read_bytes() == held
    # Both fallback requests use the same textual emitter and its own cache entry.
    build("out-of-process", settings={"ABLA_LLVM_OUT_OF_PROCESS": "1"})
    assert output.read_bytes() == fallback
    # The existing small text-cache path partitions boxed wrappers. Compare
    # bytes without that independent layout choice, then check debug as well.
    build("small-held", flags=("--no-cache",))
    small = output.read_bytes()
    build("small-text", flags=("--no-cache",), settings={"ABLA_KEEP_LLVM_TEXT": "1"})
    assert output.read_bytes() == small
    build("debug-held", flags=("-g", "--no-cache"))
    debug = output.read_bytes()
    build("debug-text", flags=("-g", "--no-cache"), settings={"ABLA_KEEP_LLVM_TEXT": "1"})
    assert output.read_bytes() == debug
    # A large constant defeats instruction-only size estimates: keep the exact
    # old section cutoff even when most printed bytes are in global data.
    source.write_text("val content = \"" + "a" * 4194305 + "\"\n"
                      "fun twice(value: int): int = value * 2\n"
                      "val callback: (int) -> int = twice\n"
                      "fun main: int = if (content.size == 4194305) callback(21) else 1\n")
    build("large-held", flags=("--no-cache",))
    run(42)
    large = output.read_bytes()
    build("large-text", flags=("--no-cache",), settings={"ABLA_KEEP_LLVM_TEXT": "1"})
    assert output.read_bytes() == large
except BaseException:
    print("held O1: artifacts and logs:", work, file=sys.stderr)
    raise
else:
    shutil.rmtree(work)
    print("held O1: exact sections, warm/missing/edited caches, text/debug fallbacks passed")
