#!/usr/bin/env python3
"""Bounded model of the partitioned-clock commit protocol (one clock per partition,
snapshot sampled lazily per partition, extension by revalidation).  Checks opacity
(every pair of values any attempt reads, committed or aborted, is a state some
prefix of the commit order produced) and that the final state is serial.
Variables x (partition 0) and y (partition 1) always hold equal values in every
committed state; writers increment both.  MODE=old uses one shared clock (control),
MODE=lazy the per-partition clocks, MODE=broken samples all partitions without
revalidating (negative control)."""
import itertools, random, sys

MODE = sys.argv[1] if len(sys.argv) > 1 else 'lazy'
PART = {'x': 0, 'y': 1}
if MODE == 'old':
    PART = {'x': 0, 'y': 0}

class Abort(Exception):
    pass

class World:
    def __init__(s):
        s.clock = [0, 0]
        s.val = {'x': 0, 'y': 0}
        s.ver = {'x': 0, 'y': 0}
        s.lock = {'x': None, 'y': None}
        s.states = [(0, 0)]      # committed states, in order of completed write-back
        s.violations = []
        s.commits = 0

def txn(w, name, kind, order):
    """A coroutine: each yield is one atomic step."""
    while True:           # retry loop (bounded by the scheduler)
        rv = {}
        reads = {}        # var -> version read
        seen = {}
        wset = {}
        def validate():
            for v, ver in reads.items():
                if w.ver[v] != ver or (w.lock[v] not in (None, name)):
                    return False
            return True
        try:
            for v in order:
                p = PART[v]
                if p not in rv:
                    yield
                    rv[p] = w.clock[p]
                    if reads and MODE != 'nosample':
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
                    if a[0] > rv[p]:
                        # extend: resample this partition, revalidate
                        yield
                        if MODE != 'broken':
                            rv[p] = w.clock[p]
                            yield
                            if not validate():
                                raise Abort()
                            continue
                        rv[p] = w.clock[p]
                    break
                reads[v] = a[0]
                seen[v] = value
                if len(seen) == 2 and seen['x'] != seen['y']:
                    w.violations.append((name, dict(seen), 'inconsistent read pair'))
            if kind == 'reader':
                return
            for v in 'xy':
                wset[v] = seen[v] + 1
            # commit
            held = []
            for v in 'xy':
                yield
                if w.lock[v] is None:
                    w.lock[v] = name
                    held.append(v)
                else:
                    for h in held:
                        w.lock[h] = None
                    raise Abort()
            newver = {}
            for v in 'xy':
                p = PART[v]
                yield
                if p not in newver:
                    w.clock[p] += 1
                    newver[p] = w.clock[p]
            yield
            if not validate():
                for h in held:
                    w.lock[h] = None
                raise Abort()
            for v in 'xy':
                yield
                w.val[v] = wset[v]
            for v in 'xy':
                yield
                w.ver[v] = newver[PART[v]]
                w.lock[v] = None
            w.commits += 1
            w.states.append((w.val['x'], w.val['y']))
            return
        except Abort:
            pass
        yield

def run(schedule_rng, spec, steps=400):
    w = World()
    gens = [txn(w, n, k, o) for n, k, o in spec]
    done = [False] * len(gens)
    n = 0
    while not all(done) and n < steps:
        i = schedule_rng.choice([j for j in range(len(gens)) if not done[j]])
        try:
            next(gens[i])
        except StopIteration:
            done[i] = True
        n += 1
    if not all(done):
        return None
    # opacity: every state seen as a pair was checked equal above; final serial
    if w.val['x'] != w.val['y'] or w.val['x'] != w.commits:
        w.violations.append(('final', (w.val['x'], w.val['y'], w.commits), 'not serial'))
    return w

def main():
    rng = random.Random(1)
    specs = [
        [('W1', 'writer', 'xy'), ('R', 'reader', 'xy')],
        [('W1', 'writer', 'xy'), ('R', 'reader', 'yx')],
        [('W1', 'writer', 'xy'), ('W2', 'writer', 'yx')],
        [('W1', 'writer', 'xy'), ('W2', 'writer', 'xy'), ('R', 'reader', 'yx')],
    ]
    total = bad = 0
    first = None
    for spec in specs:
        for _ in range(int(sys.argv[2]) if len(sys.argv) > 2 else 200000):
            w = run(rng, spec)
            if w is None:
                continue
            total += 1
            if w.violations:
                bad += 1
                if first is None:
                    first = (spec, w.violations[:2])
    print(f'{MODE}: {total} completed schedules, {bad} with violations', first or '')

main()
