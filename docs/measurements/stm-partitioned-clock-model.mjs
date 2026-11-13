// Bounded model of the partitioned-clock commit protocol (one clock per partition,
// snapshot sampled lazily per partition, extension by revalidation).  Checks opacity
// (every pair of values any attempt reads, committed or aborted, is a state some
// prefix of the commit order produced) and that the final state is serial.
// Variables x (partition 0) and y (partition 1) always hold equal values in every
// committed state; writers increment both.  MODE=old uses one shared clock (control),
// MODE=lazy the per-partition clocks, MODE=broken samples all partitions without
// revalidating (negative control), MODE=nosample skips the revalidation at a new
// partition's first read.
//
//   node stm-partitioned-clock-model.mjs [MODE] [SCHEDULES_PER_SPEC]
const MODE = process.argv[2] ?? 'lazy';
const PART = MODE === 'old' ? { x: 0, y: 0 } : { x: 0, y: 1 };

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
    return { clock: [0, 0], val: { x: 0, y: 0 }, ver: { x: 0, y: 0 }, lock: { x: null, y: null }, states: [[0, 0]], violations: [], commits: 0 };
}

// A coroutine: each yield is one atomic step.
function* txn(w, name, kind, order) {
    for (;;) { // retry loop (bounded by the scheduler)
        const rv = new Map();
        const reads = {}; // var -> version read
        const seen = {};
        const wset = {};
        const validate = () => Object.entries(reads).every(([v, ver]) => w.ver[v] === ver && (w.lock[v] === null || w.lock[v] === name));
        try {
            for (const v of order) {
                const p = PART[v];
                if (!rv.has(p)) {
                    yield;
                    rv.set(p, w.clock[p]);
                    if (Object.keys(reads).length && MODE !== 'nosample') {
                        yield;
                        if (!validate()) throw new Abort();
                    }
                }
                let a, value;
                for (;;) {
                    yield;
                    a = [w.ver[v], w.lock[v]];
                    yield;
                    value = w.val[v];
                    yield;
                    const b = [w.ver[v], w.lock[v]];
                    if (a[0] !== b[0] || a[1] !== b[1] || a[1] !== null) throw new Abort();
                    if (a[0] > rv.get(p)) {
                        // extend: resample this partition, revalidate
                        yield;
                        if (MODE !== 'broken') {
                            rv.set(p, w.clock[p]);
                            yield;
                            if (!validate()) throw new Abort();
                            continue;
                        }
                        rv.set(p, w.clock[p]);
                    }
                    break;
                }
                reads[v] = a[0];
                seen[v] = value;
                if (Object.keys(seen).length === 2 && seen.x !== seen.y) w.violations.push([name, { ...seen }, 'inconsistent read pair']);
            }
            if (kind === 'reader') return;
            for (const v of 'xy') wset[v] = seen[v] + 1;
            // commit
            const held = [];
            for (const v of 'xy') {
                yield;
                if (w.lock[v] === null) {
                    w.lock[v] = name;
                    held.push(v);
                } else {
                    for (const h of held) w.lock[h] = null;
                    throw new Abort();
                }
            }
            const newver = new Map();
            for (const v of 'xy') {
                const p = PART[v];
                yield;
                if (!newver.has(p)) {
                    w.clock[p] += 1;
                    newver.set(p, w.clock[p]);
                }
            }
            yield;
            if (!validate()) {
                for (const h of held) w.lock[h] = null;
                throw new Abort();
            }
            for (const v of 'xy') {
                yield;
                w.val[v] = wset[v];
            }
            for (const v of 'xy') {
                yield;
                w.ver[v] = newver.get(PART[v]);
                w.lock[v] = null;
            }
            w.commits += 1;
            w.states.push([w.val.x, w.val.y]);
            return;
        } catch (error) {
            if (!(error instanceof Abort)) throw error;
        }
        yield;
    }
}

function run(rng, spec, steps = 400) {
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
    // opacity: every state seen as a pair was checked equal above; final serial
    if (w.val.x !== w.val.y || w.val.x !== w.commits) w.violations.push(['final', [w.val.x, w.val.y, w.commits], 'not serial']);
    return w;
}

const rng = generator(1);
const specs = [
    [['W1', 'writer', 'xy'], ['R', 'reader', 'xy']],
    [['W1', 'writer', 'xy'], ['R', 'reader', 'yx']],
    [['W1', 'writer', 'xy'], ['W2', 'writer', 'yx']],
    [['W1', 'writer', 'xy'], ['W2', 'writer', 'xy'], ['R', 'reader', 'yx']],
];
const n = Number(process.argv[3] ?? 200000);
let total = 0, bad = 0, first = null;
for (const spec of specs) {
    for (let i = 0; i < n; i++) {
        const w = run(rng, spec);
        if (w === null) continue;
        total += 1;
        if (w.violations.length) {
            bad += 1;
            first ??= [spec, w.violations.slice(0, 2)];
        }
    }
}
console.log(`${MODE}: ${total} completed schedules, ${bad} with violations`, first ? JSON.stringify(first) : '');
