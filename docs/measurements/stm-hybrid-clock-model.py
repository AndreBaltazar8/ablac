#!/usr/bin/env python3
"""Bounded model of the hybrid STM clock protocol: a transaction runs the single-clock
protocol on the clock of its first region until it touches a second region, then
escalates to a snapshot per clock taken at the first read there.  TVars: x and z in
region/clock 0, y in region/clock 1.  Transactions: 'local' writers (increment x and z),
'wide' writers (increment x, y and z), readers.  Opacity: every set of values an attempt
has read (also an attempt that aborts) is part of some committed state; and the final
state is the serial one.  Modes: hybrid (the protocol), resample (negative control: at
escalation the first clock is sampled again instead of keeping the fast snapshot, no
revalidation), nosample (no revalidation at a new clock's first read), broken (no
revalidation when a snapshot is extended), skipfresh (commit never validates)."""
import random, sys

MODE = sys.argv[1] if len(sys.argv) > 1 else 'hybrid'
PART = {'x': 0, 'z': 0, 'y': 1}

class Abort(Exception):
    pass

class World:
    def __init__(s):
        s.clock = [0, 0]
        s.val = {'x': 0, 'y': 0, 'z': 0}
        s.ver = {'x': 0, 'y': 0, 'z': 0}
        s.lock = {'x': None, 'y': None, 'z': None}
        s.states = [dict(s.val)]
        s.violations = []
        s.commits = {'local': 0, 'wide': 0}

def txn(w, name, kind, order):
    while True:
        prim = None           # None: no access yet; 0/1: fast on that clock; 'wide': escalated
        snap = {}             # clock -> snapshot (fast: one entry)
        reads = {}            # var -> version read
        seen = {}
        wset = {}
        def validate():
            for v, ver in reads.items():
                if w.ver[v] != ver or (w.lock[v] not in (None, name)):
                    return False
            return True
        def check():
            for st in w.states:
                if all(st[v] == seen[v] for v in seen):
                    return
            w.violations.append((name, dict(seen), 'not a committed state'))
        def access(p):
            """Returns the generator steps needed to move the mode for an access in clock p."""
            nonlocal prim
            if prim is None:
                yield
                snap[p] = w.clock[p]
                prim = p
            elif prim != 'wide' and prim != p:
                # escalate: the fast snapshot becomes clock prim's snapshot
                if MODE == 'resample':
                    yield
                    snap[prim] = w.clock[prim]
                prim = 'wide'
        try:
            for v in order:
                p = PART[v]
                yield from access(p)
                if prim == 'wide' and p not in snap:
                    yield
                    snap[p] = w.clock[p]
                    if reads and MODE not in ('nosample', 'resample'):
                        yield
                        if not validate():
                            raise Abort()
                while True:
                    yield
                    a = (w.ver[v], w.lock[v])
                    yield
                    value = w.val[v]
                    yield
                    b = (w.ver[v], w.lock[v])
                    if a != b or a[1] is not None:
                        raise Abort()
                    if a[0] > snap[p]:
                        yield
                        now = w.clock[p]
                        if MODE != 'broken':
                            yield
                            if not validate():
                                raise Abort()
                        snap[p] = now
                        continue
                    break
                reads[v] = a[0]
                seen[v] = value
                check()
            if kind == 'reader':
                return
            targets = 'xz' if kind == 'local' else 'xyz'
            for v in targets:
                if v not in seen:
                    yield from access(PART[v])
                    yield
                    # a blind read-modify-write is not modelled: writers read what they write
                wset[v] = seen[v] + 1
            held = []
            for v in targets:
                yield
                if w.lock[v] is None:
                    w.lock[v] = name
                    held.append(v)
                else:
                    for h in held:
                        w.lock[h] = None
                    raise Abort()
            fresh = True
            newver = {}
            if prim != 'wide':
                yield
                c = w.clock[prim]
                w.clock[prim] = c + 1
                newver[prim] = c + 1
                fresh = (c == snap[prim])
            else:
                for q in sorted({PART[v] for v in targets}):
                    yield
                    c = w.clock[q]
                    w.clock[q] = c + 1
                    newver[q] = c + 1
                    if q in snap and c != snap[q]:
                        fresh = False
                for q in snap:
                    if q not in newver:
                        yield
                        if w.clock[q] != snap[q]:
                            fresh = False
            if MODE == 'skipfresh':
                fresh = True
            if not fresh:
                yield
                if not validate():
                    for h in held:
                        w.lock[h] = None
                    raise Abort()
            latest = dict(w.states[-1])
            latest.update(wset)
            w.states.append(latest)
            for v in targets:
                yield
                w.val[v] = wset[v]
            for v in targets:
                yield
                w.ver[v] = newver[PART[v]]
                w.lock[v] = None
            w.commits[kind] += 1
            return
        except Abort:
            pass
        yield

def run(rng, spec, steps=600):
    w = World()
    gens = [txn(w, n, k, o) for n, k, o in spec]
    done = [False] * len(gens)
    n = 0
    while not all(done) and n < steps:
        i = rng.choice([j for j in range(len(gens)) if not done[j]])
        try:
            next(gens[i])
        except StopIteration:
            done[i] = True
        n += 1
    if not all(done):
        return None
    total = w.commits['local'] + w.commits['wide']
    if w.val['x'] != total or w.val['z'] != total or w.val['y'] != w.commits['wide']:
        w.violations.append(('final', dict(w.val), 'not serial'))
    return w

def main():
    rng = random.Random(7)
    specs = [
        [('L', 'local', 'xz'), ('R', 'reader', 'yxz')],
        [('W', 'wide', 'xyz'), ('R', 'reader', 'zyx')],
        [('L', 'local', 'xz'), ('W', 'wide', 'zyx'), ('R', 'reader', 'xzy')],
        [('W1', 'wide', 'xyz'), ('W2', 'wide', 'yzx')],
        [('L', 'local', 'xz'), ('W', 'wide', 'xyz'), ('L2', 'local', 'zx')],
    ]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 100000
    total = bad = 0
    first = None
    for spec in specs:
        for _ in range(n):
            w = run(rng, spec)
            if w is None:
                continue
            total += 1
            if w.violations:
                bad += 1
                first = first or (spec, w.violations[:1])
    print(f'{MODE}: {total} completed schedules, {bad} with violations', first or '')

main()
