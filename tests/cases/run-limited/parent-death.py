#!/usr/bin/env python3
"""Exercise the Linux limiter's process tree, including its startup race."""
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

runner = pathlib.Path(sys.argv[1]).resolve()
setpriv = shutil.which("setpriv")
bash = shutil.which("bash")
python = sys.executable


def alive(pid):
    try:
        status = pathlib.Path(f"/proc/{pid}/stat").read_text()
        return status[status.rfind(")") + 2] != "Z"
    # A process exiting between open and read raises ESRCH, not ENOENT.
    except (FileNotFoundError, ProcessLookupError):
        return False


def stopped(pid):
    try:
        status = pathlib.Path(f"/proc/{pid}/stat").read_text()
        return status[status.rfind(")") + 2] == "T"
    # A process exiting between open and read raises ESRCH, not ENOENT.
    except (FileNotFoundError, ProcessLookupError):
        return False


def wait_for(predicate, label, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {label}")


def kill(pid, sig=signal.SIGKILL):
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        pass


with tempfile.TemporaryDirectory(prefix="abla-limiter-test-") as tmp:
    root = pathlib.Path(tmp)
    worker = root / "worker.py"
    worker.write_text('''import os, pathlib, signal, subprocess, sys, time\nroot = pathlib.Path(sys.argv[1])\nstubborn = sys.argv[2] == "stubborn"\nif stubborn: signal.signal(signal.SIGTERM, signal.SIG_IGN)\ncode = "import os,pathlib,signal,sys,time; " + ("signal.signal(signal.SIGTERM,signal.SIG_IGN); " if stubborn else "") + "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)"\nchild = subprocess.Popen([sys.executable, "-c", code, str(root / "child")])\nwhile not (root / "child").exists(): time.sleep(0.005)\n(root / "parent").write_text(str(os.getpid()))\ntime.sleep(60)\n''')

    def run_tree(mode, stubborn=False):
        case = root / (mode + ("-stubborn" if stubborn else ""))
        case.mkdir()
        env = dict(os.environ, ABLA_MAX_SECONDS="3" if mode == "timeout" else "30",
                   ABLA_KILL_GRACE_SECONDS="1")
        proc = subprocess.Popen([str(runner), python, str(worker), str(case),
                                 "stubborn" if stubborn else "normal"],
                                env=env, start_new_session=True,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        parent = child = supervisor = 0
        try:
            wait_for(lambda: (case / "parent").exists() and (case / "parent").stat().st_size > 0,
                     "payload startup")
            parent = int((case / "parent").read_text())
            child = int((case / "child").read_text())
            supervisor = os.getpgid(parent)
            assert supervisor != proc.pid, "timeout did not create its own process group"
            if mode == "group":
                os.killpg(proc.pid, signal.SIGKILL)
            elif mode == "term":
                proc.send_signal(signal.SIGTERM)
            status = proc.wait(timeout=8)
            expected = {"group": -signal.SIGKILL, "term": 143, "timeout": 124}[mode]
            assert status == expected, f"{mode}: exit {status}, expected {expected}"
            wait_for(lambda: not alive(parent) and not alive(child) and not alive(supervisor),
                     f"{mode} supervisor and descendants to exit")
        finally:
            for pid in (parent, child, supervisor, proc.pid):
                if pid: kill(pid)
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=5)

    def fallback():
        private_bin = root / "fallback-bin"
        private_bin.mkdir()
        for name in ("bash", "timeout", "prlimit"):
            os.symlink(shutil.which(name), private_bin / name)
        env = dict(os.environ, PATH=str(private_bin), ABLA_MAX_SECONDS="3")
        proc = subprocess.run([str(runner), "/bin/sh", "-c", "exit 42"],
                              env=env, capture_output=True, timeout=8)
        assert proc.returncode == 42, f"missing setpriv fallback: {proc.returncode}: {proc.stderr!r}"
        assert not proc.stderr, f"missing setpriv emitted an error: {proc.stderr!r}"

    def startup_race():
        case = root / "startup"
        case.mkdir()
        private_bin = case / "bin"
        private_bin.mkdir()
        shim = private_bin / "setpriv"
        shim.write_text(f'''#!{bash}\nprintf '%s\\n' "$$" > "$ABLA_TEST_SHIM_READY"\nkill -STOP "$$"\nexec "$ABLA_TEST_REAL_SETPRIV" "$@"\n''')
        shim.chmod(0o755)
        env = dict(os.environ, PATH=f"{private_bin}:{os.environ['PATH']}",
                   ABLA_TEST_SHIM_READY=str(case / "ready"),
                   ABLA_TEST_REAL_SETPRIV=setpriv, ABLA_MAX_SECONDS="30")
        marker = case / "payload-ran"
        proc = subprocess.Popen([str(runner), "/bin/sh", "-c", 'echo ran > "$1"', "_", str(marker)],
                                env=env, start_new_session=True,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shim_pid = 0
        try:
            wait_for(lambda: (case / "ready").exists(), "unarmed setpriv shim")
            shim_pid = int((case / "ready").read_text())
            wait_for(lambda: stopped(shim_pid), "setpriv shim to stop")
            kill(proc.pid)
            proc.wait(timeout=5)
            os.kill(shim_pid, signal.SIGCONT)
            wait_for(lambda: not alive(shim_pid), "reparented trampoline to exit")
            assert not marker.exists(), "payload started after its launcher died"
        finally:
            if shim_pid: kill(shim_pid)
            kill(proc.pid)
            proc.wait(timeout=5)

    fallback()
    if setpriv:
        run_tree("group")
        run_tree("group", stubborn=True)
        run_tree("term")
        run_tree("timeout")
        run_tree("timeout", stubborn=True)
        startup_race()
    else:
        print("setpriv unavailable: verified fallback; parent-death cases skipped")
print("limited runner: parent death, startup race, descendant cleanup and fallback passed")
