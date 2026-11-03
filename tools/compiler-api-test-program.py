#!/usr/bin/env python3
"""Prepare the shared compiler-API client; print only its executable path.

The compiler's own source/toolchain cache validates every request. A portable
file lock coalesces concurrent cold builds, with no hand-written stale-input
stamp. Every caller still runs its case in a separate process.
"""
import fcntl
import hashlib
from pathlib import Path
import shutil
import signal
import subprocess
import sys


def stopped(number, frame):
    # subprocess.run tears down its compiler child on BaseException; the
    # bounded launcher then stops its process group. The OS releases flock.
    raise SystemExit(128 + number)


signal.signal(signal.SIGTERM, stopped)
signal.signal(signal.SIGHUP, stopped)
if len(sys.argv) != 2:
    raise SystemExit("usage: compiler-api-test-program.py COMPILER")

root = Path(__file__).resolve().parent.parent
requested = sys.argv[1]
compiler = (Path(requested) if '/' in requested
            else Path(shutil.which(requested) or requested))
if not compiler.is_absolute():
    compiler = Path.cwd() / compiler
payload = Path(str(compiler) + '.bin')
identity = payload if payload.is_file() else compiler
key = hashlib.sha256(identity.read_bytes()).hexdigest()
output = root / 'build' / 'compiler-api-tests' / key
output.mkdir(parents=True, exist_ok=True)
program = output / 'program'
with (output / 'build.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    # No tested state is cached: this is only the executable containing the
    # clients. Their tested inputs/effects run at runtime, so each client
    # still creates its own compiler/IR caches in a fresh process.
    # Let NativeBuild validate sources, compiler identity and native toolchain;
    # a warm request skips frontend analysis and LLVM compilation.
    result = subprocess.run(
        [str(compiler), 'build', str(root / 'tests/cases/compiler-api/main.ab'),
         '-o', str(program), '--fast'], cwd=root, stdout=sys.stderr
    )
    if result.returncode:
        raise SystemExit(result.returncode)
print(program)
