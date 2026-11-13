// Bounded model of the hybrid STM clock protocol: a transaction runs the single-clock
// protocol on the clock of its first region until it touches a second region, then
// escalates to a snapshot per clock taken at the first read there.  TVars: x and z in
// region/clock 0, y in region/clock 1.  Transactions: 'local' writers (increment x and z),
// 'wide' writers (increment x, y and z), readers.  Opacity: every set of values an attempt
// has read (also an attempt that aborts) is part of some committed state; and the final
// state is the serial one.  Modes: hybrid (the protocol), resample (negative control: at
// escalation the first clock is sampled again instead of keeping the fast snapshot, no
// revalidation), nosample (no revalidation at a new clock's first read), broken (no
// revalidation when a snapshot is extended), skipfresh (commit never validates).
//
//   node stm-hybrid-clock-model.mjs [MODE] [SCHEDULES_PER_SPEC]
const MODE = process.argv[2] ?? 'hybrid';
const PART = { x: 0, z: 0, y: 1 };

class Abort extends Error {}

// A seeded stream (mulberry32): the schedules are the same on every run.
function generator(seed) {
    let a = seed >>> 0;
    const next = () => {
        a = (a + 0x6D2B79F5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
    return { choice: (list) => list[Math.floor(next() * list.length)] };
}

function newWorld() {
    const w = { clock: [0, 0], val: { x: 0, y: 0, z: 0 }, ver: { x: 0, y: 0, z: 0 }, lock: { x: null, y: null, z: null }, violations: [], commits: { local: 0, wide: 0 } };
    w.states = [{ ...w.val }];
    return w;
}

function* txn(w, name, kind, order) {
    for (;;) {
        let prim = null;          // null: no access yet; 0/1: fast on that clock; 'wide': escalated
        const snap = new Map();   // clock -> snapshot (fast: one entry)
        const reads = {};         // var -> version read
        const seen = {};
        const wset = {};
        const validate = () => Object.entries(reads).every(([v, ver]) => w.ver[v] === ver && (w.lock[v] === null || w.lock[v] === name));
        const check = () => {
            for (const st of w.states) if (Object.keys(seen).every((v) => st[v] === seen[v])) return;
            w.violations.push([name, { ...seen }, 'not a committed state']);
        };
        // The generator steps needed to move the mode for an access in clock p.
        const access = function* (p) {
            if (prim === null) {
                yield;
                snap.set(p, w.clock[p]);
                prim = p;
            } else if (prim !== 'wide' && prim !== p) {
                // escalate: the fast snapshot becomes clock prim's snapshot
                if (MODE === 'resample') {
                    yield;
                    snap.set(prim, w.clock[prim]);
                }
                prim = 'wide';
            }
        };
        try {
            for (const v of order) {
                const p = PART[v];
                yield* access(p);
                if (prim === 'wide' && !snap.has(p)) {
                    yield;
                    snap.set(p, w.clock[p]);
                    if (Object.keys(reads).length && MODE !== 'nosample' && MODE !== 'resample') {
                        yield;
                        if (!validate()) throw new Abort();
                    }
                }
                let a;
                for (;;) {
                    yield;
                    a = [w.ver[v], w.lock[v]];
                    yield;
                    var value = w.val[v];
                    yield;
                    const b = [w.ver[v], w.lock[v]];
                    if (a[0] !== b[0] || a[1] !== b[1] || a[1] !== null) throw new Abort();
                    if (a[0] > snap.get(p)) {
                        yield;
                        const now = w.clock[p];
                        if (MODE !== 'broken') {
                            yield;
                            if (!validate()) throw new Abort();
                        }
                        snap.set(p, now);
                        continue;
                    }
                    break;
                }
                reads[v] = a[0];
                seen[v] = value;
                check();
            }
            if (kind === 'reader') return;
            const targets = kind === 'local' ? 'xz' : 'xyz';
            for (const v of targets) {
                if (!(v in seen)) {
                    yield* access(PART[v]);
                    yield;
                    // a blind read-modify-write is not modelled: writers read what they write
                }
                wset[v] = seen[v] + 1;
            }
            const held = [];
            for (const v of targets) {
                yield;
                if (w.lock[v] === null) {
                    w.lock[v] = name;
                    held.push(v);
                } else {
                    for (const h of held) w.lock[h] = null;
                    throw new Abort();
                }
            }
            let fresh = true;
            const newver = new Map();
            if (prim !== 'wide') {
                yield;
                const c = w.clock[prim];
                w.clock[prim] = c + 1;
                newver.set(prim, c + 1);
                fresh = c === snap.get(prim);
            } else {
                for (const q of [...new Set([...targets].map((v) => PART[v]))].sort((x, y) => x - y)) {
                    yield;
                    const c = w.clock[q];
                    w.clock[q] = c + 1;
                    newver.set(q, c + 1);
                    if (snap.has(q) && c !== snap.get(q)) fresh = false;
                }
                for (const q of snap.keys()) {
                    if (!newver.has(q)) {
                        yield;
                        if (w.clock[q] !== snap.get(q)) fresh = false;
                    }
                }
            }
            if (MODE === 'skipfresh') fresh = true;
            if (!fresh) {
                yield;
                if (!validate()) {
                    for (const h of held) w.lock[h] = null;
                    throw new Abort();
                }
            }
            const latest = { ...w.states[w.states.length - 1], ...wset };
            w.states.push(latest);
            for (const v of targets) {
                yield;
                w.val[v] = wset[v];
            }
            for (const v of targets) {
                yield;
                w.ver[v] = newver.get(PART[v]);
                w.lock[v] = null;
            }
            w.commits[kind] += 1;
            return;
        } catch (error) {
            if (!(error instanceof Abort)) throw error;
        }
        yield;
    }
}

function run(rng, spec, steps = 600) {
    const w = newWorld();
    const gens = spec.map(([n, k, o]) => txn(w, n, k, o));
    const done = gens.map(() => false);
    let n = 0;
    while (!done.every(Boolean) && n < steps) {
        const i = rng.choice(gens.map((_, j) => j).filter((j) => !done[j]));
        if (gens[i].next().done) done[i] = true;
        n += 1;
    }
    if (!done.every(Boolean)) return null;
    const total = w.commits.local + w.commits.wide;
    if (w.val.x !== total || w.val.z !== total || w.val.y !== w.commits.wide) w.violations.push(['final', { ...w.val }, 'not serial']);
    return w;
}

const rng = generator(7);
const specs = [
    [['L', 'local', 'xz'], ['R', 'reader', 'yxz']],
    [['W', 'wide', 'xyz'], ['R', 'reader', 'zyx']],
    [['L', 'local', 'xz'], ['W', 'wide', 'zyx'], ['R', 'reader', 'xzy']],
    [['W1', 'wide', 'xyz'], ['W2', 'wide', 'yzx']],
    [['L', 'local', 'xz'], ['W', 'wide', 'xyz'], ['L2', 'local', 'zx']],
];
const n = Number(process.argv[3] ?? 100000);
let total = 0, bad = 0, first = null;
for (const spec of specs) {
    for (let i = 0; i < n; i++) {
        const w = run(rng, spec);
        if (w === null) continue;
        total += 1;
        if (w.violations.length) {
            bad += 1;
            first ??= [spec, w.violations.slice(0, 1)];
        }
    }
}
console.log(`${MODE}: ${total} completed schedules, ${bad} with violations`, first ? JSON.stringify(first) : '');
