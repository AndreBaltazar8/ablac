#!/usr/bin/env python3
"""Native pty/termios oracle. No printer hardware and no stty subprocess."""
import errno
import fcntl
import os
from pathlib import Path
import pty
import random
import resource
import select
import signal
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty

program = os.path.abspath(sys.argv[1])
checks = 0


def line(proc, prefix):
    ready, _, _ = select.select([proc.stdout], [], [], 10)
    assert ready, f"timeout waiting for {prefix}"
    text = proc.stdout.readline().strip()
    assert text.startswith(prefix + " "), f"expected {prefix}, got {text!r}"
    return text.split()[1:]


class Client:
    def __init__(self, mode, path, payload, timeout=1000, baud=9600, bits=8,
                 parity="none", stop=1, raw=True, flow="none", rw=False):
        self.proc = subprocess.Popen(
            [program, mode, str(path), str(payload), str(timeout), str(baud),
             str(bits), parity, str(stop), str(raw).lower(), flow, "rw" if rw else "w"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, start_new_session=True)
        try:
            self.ready = line(self.proc, "READY")
            if self.ready[0] == "true":
                flags, fdflags = map(int, self.ready[2:4])
                assert flags & os.O_NONBLOCK
                assert flags & os.O_ACCMODE == (os.O_RDWR if rw else os.O_WRONLY)
                assert fdflags & fcntl.FD_CLOEXEC
                assert self.ready[4] == "false", "device open acquired a controlling terminal"
        except BaseException:
            self.clean()
            raise

    def send(self, byte):
        self.proc.stdin.write(byte)
        self.proc.stdin.flush()

    def write(self):
        self.send("G")
        return tuple(map(int, line(self.proc, "RESULT")))

    def close(self):
        self.send("C")
        assert line(self.proc, "CLOSED") == ["true", "true", "false", "6", "0", "9", "-9", "9"]
        assert self.proc.wait(timeout=5) == 0, self.proc.stderr.read()

    def finish_failed_open(self, expected):
        assert self.ready[0] == "false" and int(self.ready[1]) in expected, self.ready
        assert self.proc.wait(timeout=5) == 0

    def clean(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=5)
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            stream.close()


with tempfile.TemporaryDirectory(prefix="abla-device-test-") as directory:
    root = Path(directory)
    empty = root / "empty"
    empty.write_bytes(b"")
    small = root / "small"
    small_bytes = bytes(range(256)) + b"\x1b@receipt\x00\r\n"
    small.write_bytes(small_bytes)
    large = root / "large"
    large_bytes = random.Random(507).randbytes(4 * 1024 * 1024)
    large.write_bytes(large_bytes)

    def rejected(mode, path, codes, **settings):
        global checks
        client = Client(mode, path, empty, **settings)
        try:
            client.finish_failed_open(codes)
            checks += 1
        finally:
            client.clean()

    rejected("device", root / "missing", {errno.ENOENT})
    assert not (root / "missing").exists()
    rejected("device", "", {errno.EINVAL})
    file = root / "regular"
    file.write_bytes(b"unchanged")
    rejected("device", file, {errno.EINVAL})
    assert file.read_bytes() == b"unchanged"
    link = root / "regular-link"
    link.symlink_to(file)
    rejected("device", link, {errno.EINVAL})
    rejected("serial", "/dev/null", {errno.ENOTTY, errno.ENODEV})
    for settings in (dict(baud=0), dict(baud=12345), dict(bits=4), dict(bits=9),
                     dict(parity="mark"), dict(stop=3), dict(flow="xon-xoff")):
        rejected("serial", "/dev/null", {errno.EINVAL}, **settings)

    client = Client("device", "/dev/null", small)
    try:
        assert client.write()[:3] == (1, len(small_bytes), 0)
        client.close()
        checks += 1
    finally:
        client.clean()

    def limited_descriptors():
        resource.setrlimit(resource.RLIMIT_NOFILE, (32, 32))
    leaks = subprocess.run([program, "leaks"], capture_output=True, text=True,
                           preexec_fn=limited_descriptors, timeout=10)
    assert leaks.returncode == 42 and "LEAKS pass" in leaks.stdout, leaks
    checks += 1

    master, slave = pty.openpty()
    client = None
    try:
        tty.setraw(slave)
        before = termios.tcgetattr(slave)
        client = Client("invalid-config", os.ttyname(slave), empty)
        client.send("G")
        assert line(client.proc, "CONFIGURED") == ["22"]
        assert termios.tcgetattr(slave) == before
        assert client.write()[:3] == (1, 0, 0)
        client.close()
        checks += 1
    finally:
        if client: client.clean()
        os.close(master)
        os.close(slave)

    master, slave = pty.openpty()
    client = None
    try:
        tty.setraw(slave)
        client = Client("blocking", os.ttyname(slave), large)
        assert client.write()[:3] == (6, 0, 22)
        assert not select.select([master], [], [], 0)[0]
        client.close()
        checks += 1
    finally:
        if client: client.clean()
        os.close(master)
        os.close(slave)

    for mode in ("min-deadline", "min-timeout", "max-timeout"):
        client = Client(mode, "/dev/null", small)
        try:
            expected = (1, len(small_bytes), 0) if mode == "max-timeout" else (3, 0, 110)
            assert client.write()[:3] == expected
            client.close()
            checks += 1
        finally:
            client.clean()

    # Python's native termios binding is independent of the Abla flag/layout code.
    rates = [50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800,
             9600, 19200, 38400, 57600, 115200, 230400]
    cases = [dict(baud=rate) for rate in rates]
    cases += [dict(bits=bits) for bits in (5, 6, 7)]
    cases += [dict(parity=parity) for parity in ("even", "odd")]
    cases += [dict(stop=2), dict(flow="rts-cts"), dict(raw=False), dict(rw=True)]
    for settings in cases:
        master, slave = pty.openpty()
        client = None
        try:
            before = termios.tcgetattr(slave)
            client = Client("serial", os.ttyname(slave), empty, **settings)
            if client.ready[0] == "false":
                # Pty drivers may reject/coerce framing they cannot represent.
                assert any(key in settings for key in ("bits", "parity")), (settings, client.ready)
                client.finish_failed_open({errno.EINVAL, errno.EIO, 95})
            else:
                actual = termios.tcgetattr(slave)
                baud = settings.get("baud", 9600)
                assert actual[4] == getattr(termios, "B" + str(baud))
                assert actual[5] == getattr(termios, "B" + str(baud))
                assert actual[2] & termios.CSIZE == getattr(termios, "CS" + str(settings.get("bits", 8)))
                assert bool(actual[2] & termios.CSTOPB) == (settings.get("stop", 1) == 2)
                parity = settings.get("parity", "none")
                assert bool(actual[2] & termios.PARENB) == (parity != "none")
                assert bool(actual[2] & termios.PARODD) == (parity == "odd")
                assert bool(actual[2] & termios.CRTSCTS) == (settings.get("flow") == "rts-cts")
                assert actual[2] & termios.CLOCAL and actual[2] & termios.CREAD
                assert not actual[0] & (termios.IXON | termios.IXOFF | termios.IXANY)
                if settings.get("raw", True):
                    assert not actual[1] & termios.OPOST
                    assert not actual[3] & (termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN)
                else:
                    assert actual[3] == before[3] and actual[1] == before[1]
                assert client.write()[:3] == (1, 0, 0)
                client.close()
            checks += 1
        finally:
            if client: client.clean()
            os.close(master)
            os.close(slave)

    # Byte-exact output, including NUL, high bytes, ESC and untranslated CR/LF.
    for mode in ("device", "serial"):
        master, slave = pty.openpty()
        client = None
        try:
            tty.setraw(slave)
            client = Client(mode, os.ttyname(slave), small)
            assert client.write()[:3] == (1, len(small_bytes), 0)
            received = b""
            while len(received) < len(small_bytes):
                assert select.select([master], [], [], 3)[0]
                received += os.read(master, 4096)
            assert received == small_bytes
            client.close()
            checks += 1
        finally:
            if client: client.clean()
            os.close(master)
            os.close(slave)

    master, slave = pty.openpty()
    client = None
    try:
        tty.setraw(slave)
        client = Client("device", os.ttyname(slave), small, timeout=0)
        assert client.write()[:3] == (3, 0, 110)
        assert not select.select([master], [], [], 0)[0]
        client.close()
        checks += 1
    finally:
        if client: client.clean()
        os.close(master)
        os.close(slave)

    # Fill a tty with no reader; retain the accepted prefix, then resume only
    # the unsent tail while the oracle drains. Exact random bytes catch replay.
    master, slave = pty.openpty()
    client = None
    stop_reader = threading.Event()
    chunks = []
    reader = None
    try:
        tty.setraw(slave)
        client = Client("device", os.ttyname(slave), large, timeout=100)
        state, written, error, elapsed = client.write()
        assert (state, error) == (3, 110)
        assert 0 < written < len(large_bytes), (state, written, error)
        assert 50 <= elapsed < 1500, elapsed
        def drain():
            while not stop_reader.is_set():
                if select.select([master], [], [], 0.05)[0]:
                    chunks.append(os.read(master, 16384))
        reader = threading.Thread(target=drain)
        reader.start()
        client.send("R")
        assert tuple(map(int, line(client.proc, "RESUMED"))) == (1, len(large_bytes) - written, 0)
        client.close()
        deadline = time.monotonic() + 3
        while sum(map(len, chunks)) < len(large_bytes) and time.monotonic() < deadline:
            time.sleep(0.01)
        assert b"".join(chunks) == large_bytes
        checks += 1
        print(f"device stalled reader: {written}/{len(large_bytes)} accepted, {elapsed}ms; exact resume", flush=True)
    finally:
        stop_reader.set()
        if reader: reader.join(timeout=3)
        if client: client.clean()
        os.close(master)
        os.close(slave)

    # Interrupt a stalled poll repeatedly. A retry that reuses the old duration
    # instead of recomputing the deadline would run until this two-second
    # signal stream ends, rather than the requested 100ms.
    master, slave = pty.openpty()
    client = None
    stop_signals = threading.Event()
    sender = None
    sent = []
    try:
        tty.setraw(slave)
        client = Client("signals", os.ttyname(slave), large, timeout=100)
        client.send("G")
        line(client.proc, "WRITING")
        client.send("G")
        def interrupt():
            until = time.monotonic() + 2
            while time.monotonic() < until and not stop_signals.wait(0.005):
                os.kill(client.proc.pid, signal.SIGUSR1)
                sent.append(1)
        sender = threading.Thread(target=interrupt)
        sender.start()
        state, written, error, elapsed = map(int, line(client.proc, "RESULT"))
        stop_signals.set()
        sender.join(timeout=3)
        assert (state, error) == (3, 110) and 0 < written < len(large_bytes)
        assert len(sent) >= 5 and elapsed < 1500, (len(sent), elapsed)
        client.close()
        checks += 1
        print(f"device interrupted poll: {len(sent)} signals, {elapsed}ms", flush=True)
    finally:
        stop_signals.set()
        if sender: sender.join(timeout=3)
        if client: client.clean()
        os.close(master)
        os.close(slave)

    # Close the reader after enough progress to require several writes. An
    # error after that progress must retain the accepted byte count too.
    master, slave = pty.openpty()
    client = None
    received = []
    reader = None
    try:
        tty.setraw(slave)
        client = Client("device", os.ttyname(slave), large)
        def disconnect():
            while sum(map(len, received)) < 131072:
                if not select.select([master], [], [], 3)[0]: return
                received.append(os.read(master, 16384))
            os.close(master)
        reader = threading.Thread(target=disconnect)
        reader.start()
        state, written, error, elapsed = client.write()
        reader.join(timeout=4)
        assert state == 6 and error != 0 and 0 < written < len(large_bytes)
        assert b"".join(received) == large_bytes[:sum(map(len, received))]
        client.close()
        checks += 1
        print(f"device disconnect: error {error} after {written} accepted bytes", flush=True)
    finally:
        if client: client.clean()
        if reader: reader.join(timeout=4)
        try: os.close(master)
        except OSError as error:
            if error.errno != errno.EBADF: raise
        os.close(slave)

    # Linux ptys expose the last-readiness boundary without printer hardware.
    # Their effective capacity changes with queue scheduling, so try bounded
    # sizes and verify any fully accepted timeout preserves the full count.
    found_full_timeout = False
    sizes = list(dict.fromkeys([14336, 11776, 13824, 15872] + list(range(4096, 32769, 512))))
    boundary = root / "boundary"
    for size in sizes:
        master, slave = pty.openpty()
        client = None
        try:
            tty.setraw(slave)
            boundary.write_bytes(large_bytes[:size])
            client = Client("device", os.ttyname(slave), boundary, timeout=20)
            state, written, error, elapsed = client.write()
            assert (state == 1 and written == size and error == 0) or (state == 3 and error == 110)
            if state == 3 and written == size:
                found_full_timeout = True
                checks += 1
                print(f"device final readiness: timeout after all {written} bytes accepted", flush=True)
            client.close()
        finally:
            if client: client.clean()
            os.close(master)
            os.close(slave)
        if found_full_timeout: break
    if sys.platform.startswith("linux"):
        assert found_full_timeout, "did not exercise the final POLLOUT wait after a full write"
    elif not found_full_timeout:
        print("pty did not expose a full-write/final-readiness timeout on this platform", flush=True)

print(f"device/serial: {checks} native pty, flags, termios and deadline checks passed")
