#!/usr/bin/env python3
"""Kill the caller's group without killing its detached payload group directly."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

if sys.platform != "darwin":
    raise SystemExit("Darwin parent-death regression requires macOS")
runner = os.path.abspath(sys.argv[1])


def alive(pid):
    result = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)],
                            stdout=subprocess.PIPE, text=True, check=False)
    return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.lstrip().startswith("Z")


def wait_for(predicate, label, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("timed out waiting for " + label)


def kill(pid, group=False):
    try:
        (os.killpg if group else os.kill)(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


with tempfile.TemporaryDirectory(prefix="abla-darwin-limit-") as tmp:
    root = Path(tmp)
    worker = root / "worker.py"
    worker.write_text('''import json, os, pathlib, signal, sys, time
path = pathlib.Path(sys.argv[1])
if sys.argv[2] == "stubborn": signal.signal(signal.SIGTERM, signal.SIG_IGN)
r, w = os.pipe()
child = os.fork()
if child == 0:
    os.close(r)
    os.write(w, b"1")
    os.close(w)
    time.sleep(60)
    os._exit(0)
os.close(w)
assert os.read(r, 1) == b"1"
os.close(r)
ready = path.with_suffix(".tmp")
ready.write_text(json.dumps([os.getpid(), child, os.getppid()]))
ready.rename(path)
time.sleep(60)
''')
    for mode in ("normal", "stubborn"):
        marker = root / mode
        env = dict(os.environ, ABLA_MAX_SECONDS="60", ABLA_KILL_GRACE_SECONDS="1")
        proc = subprocess.Popen([runner, sys.executable, str(worker), str(marker), mode],
                                env=env, start_new_session=True,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        payload = child = supervisor = group = 0
        try:
            wait_for(marker.exists, "payload and descendant readiness")
            payload, child, supervisor = json.loads(marker.read_text())
            group = os.getpgid(payload)
            assert group != proc.pid, "payload unexpectedly shares caller's group"
            assert os.getpgid(child) == group, "descendant escaped payload group"
            os.killpg(proc.pid, signal.SIGKILL)
            assert proc.wait(timeout=5) == -signal.SIGKILL
            try:
                wait_for(lambda: not alive(payload) and not alive(child),
                         mode + " payload group cleanup", seconds=5)
            except AssertionError:
                raise AssertionError(f"{mode}: payload survived caller group SIGKILL "
                                     f"(payload={payload}, child={child}, supervisor={supervisor})")
            wait_for(lambda: not alive(supervisor), "supervisor exit", seconds=5)
            print(f"Darwin parent death: {mode} payload and descendant stopped", flush=True)
        finally:
            if group: kill(group, group=True)
            for pid in (payload, child, supervisor):
                if pid: kill(pid)
            kill(proc.pid, group=True)
            proc.wait(timeout=5)
