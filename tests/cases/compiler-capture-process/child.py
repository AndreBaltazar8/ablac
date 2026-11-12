"""Deterministic child modes for compilerCaptureProcess boundary checks."""
import os
import signal
import sys
import time
from pathlib import Path

mode = sys.argv[1]
if mode == "bytes":
    sys.stdout.buffer.write((b"\0\xffA" * ((int(sys.argv[2]) + 2) // 3))[:int(sys.argv[2])])
elif mode == "exit":
    sys.exit(int(sys.argv[2]))
elif mode == "signal":
    os.kill(os.getpid(), signal.SIGTERM)
elif mode == "stdin":
    assert sys.stdin.buffer.read() == b""
    print("closed", end="")
elif mode == "environment":
    print(os.environ["ABLA_CAPTURE_MARKER"], end="")
elif mode == "mark":
    Path(sys.argv[2]).write_text("spawned")
elif mode == "descendant":
    child = os.fork()
    if child == 0:
        Path(sys.argv[2]).write_text(str(os.getpid()))
        time.sleep(30)
    else:
        # Exit while our descendant still holds the stdout pipe open.
        sys.exit(0)
elif mode == "overflow-descendant":
    child = os.fork()
    if child == 0:
        Path(sys.argv[2]).write_text(str(os.getpid()))
        time.sleep(30)
    else:
        # Ensure the descendant is running before triggering the output cap.
        while not Path(sys.argv[2]).exists():
            time.sleep(0.001)
        sys.stdout.buffer.write(b"x" * 65536)
        sys.stdout.buffer.flush()
        time.sleep(30)
