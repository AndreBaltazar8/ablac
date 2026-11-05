#!/usr/bin/env python3
"""Darwin development runner: supervise a payload group and its caller's lifetime."""
import errno
import os
import select
import signal
import subprocess
import sys
import time


def signal_group(pid, number):
    try:
        os.killpg(pid, number)
    except ProcessLookupError:
        pass


def supervise(parent, seconds, grace, command):
    # Until this succeeds a caller-group kill also kills us, with no payload
    # started. Afterwards the process-exit watch protects that detached group.
    os.setpgrp()
    pending = [None]

    def interrupted(number, frame):
        if pending[0] is None:
            pending[0] = number

    signals = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    for number in signals:
        signal.signal(number, interrupted)
    # Register before spawning, so even an immediately exiting child wakes us.
    signal.signal(signal.SIGCHLD, lambda number, frame: None)
    with select.kqueue() as queue:
        changes = [select.kevent(parent, filter=select.KQ_FILTER_PROC,
                                 flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                 fflags=select.KQ_NOTE_EXIT)]
        changes += [select.kevent(number, filter=select.KQ_FILTER_SIGNAL,
                                  flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR)
                    for number in (*signals, signal.SIGCHLD)]
        try:
            queue.control(changes, 0, 0)
        except OSError as error:
            if error.errno == errno.ESRCH:
                return 125
            raise
        # Close the pre-registration race: do not start after reparenting.
        if os.getppid() != parent:
            return 125
        events = queue.control([], 8, 0)
        if any(event.filter == select.KQ_FILTER_PROC for event in events):
            return 125
        if pending[0] is not None:
            return 128 + pending[0]
        try:
            child = subprocess.Popen(command, start_new_session=True)
        except OSError as error:
            print(f"[abla-limit] cannot start command: {error}", file=sys.stderr)
            return 127
        complete = False
        try:
            deadline = time.monotonic() + seconds
            stopping = None
            kill_at = None
            while True:
                # Check queued parent death before a normal child exit: a
                # concurrently exiting leader can still have live descendants.
                events = queue.control([], 8, 0)
                if stopping is None:
                    if any(event.filter == select.KQ_FILTER_PROC for event in events):
                        stopping = 125
                    elif pending[0] is not None:
                        stopping = 128 + pending[0]
                    elif time.monotonic() >= deadline:
                        stopping = 124
                    if stopping is not None:
                        forwarded = pending[0] if stopping in (129, 130, 143) else signal.SIGTERM
                        signal_group(child.pid, forwarded)
                        kill_at = time.monotonic() + grace
                    else:
                        status = child.poll()
                        if status is not None:
                            complete = True
                            return status if status >= 0 else 128 - status
                if stopping is not None and time.monotonic() >= kill_at:
                    # Do this even when the leader has exited: a descendant may
                    # ignore TERM. Keep the leader unreaped until this point so
                    # its PID cannot be recycled into an unrelated group.
                    signal_group(child.pid, signal.SIGKILL)
                    child.wait()
                    complete = True
                    return stopping
                until = kill_at if stopping is not None else deadline
                # Signal/child/parent events wake the wait; deadlines are
                # monotonic and recomputed rather than restarted by a signal.
                events = queue.control([], 8, max(0, until - time.monotonic()))
                # A one-shot parent event must survive until the next loop.
                if any(event.filter == select.KQ_FILTER_PROC for event in events):
                    if stopping is None:
                        stopping = 125
                        signal_group(child.pid, signal.SIGTERM)
                        kill_at = time.monotonic() + grace
        finally:
            if not complete:
                signal_group(child.pid, signal.SIGKILL)
                child.wait()


def main():
    if sys.platform != "darwin":
        print("[abla-limit] Darwin supervisor requires macOS", file=sys.stderr)
        return 2
    if len(sys.argv) < 5:
        print("usage: run-limited-darwin.py PARENT SECONDS GRACE COMMAND [ARG ...]", file=sys.stderr)
        return 2
    try:
        return supervise(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:])
    except OSError as error:
        print(f"[abla-limit] Darwin supervisor failed: {error}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    raise SystemExit(main())
