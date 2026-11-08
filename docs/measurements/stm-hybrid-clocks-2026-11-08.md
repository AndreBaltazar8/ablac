# STM hybrid clocks, 2026-11-08

Follows `stm-partitioned-clocks-2026-11-08.md`. A logged transaction runs the single-clock protocol (today's
code) on the clock of its first access until it touches a TVar in a second region, and only then keeps a
snapshot for each clock. Sixteen clocks, each in a cache line of its own; a TVar's region is its address
>> 10 (1,024 bytes: a structure's TVars made together share one) and its clock is region & 15. A new transaction's
mode starts at 0 and becomes the region of its first read or first new write entry, whose clock supplies the
one snapshot (descriptor +16); an access in another region moves to the partitioned protocol with the
snapshot it had as that clock's (`__ablaRuntimeStmAccess`). Commit in the single-clock mode is today's: one
compare-and-swap, the reads validated unless that clock was exactly at the snapshot, every TVar released at the
new version. Direct mode is untouched.

## Correctness

`stm-hybrid-clock-model.py` (three TVars, two clocks; transactions that stay on one clock, that move to the
second, and readers; every set of values an attempt has read, also one that aborts, must lie in one committed
state, and the final state is serial). `python3 stm-hybrid-clock-model.py hybrid 200000` (5 specs, 1,000,000
schedules): 0 violations. Negative controls with 40,000 schedules a spec (200,000): `resample` (moving to the
second clock samples the first one again instead of keeping the snapshot) 2,417 violations; `nosample` (no
revalidation at a new clock's first read) 50; `broken` (no revalidation when a snapshot is moved up) 7,072;
`skipfresh` (a commit never validates) 579. Not modelled: GV4's sharing of a version, a transaction that moves
from one clock to the next by a write it did not read first (every modelled writer reads what it writes), two
regions that map to the same clock, `retry` and `orElse`; `test-stm` covers the first three.

`tools/test-stm.sh` (now including `tests/cases/stm/bank-spread.ab`: sixteen accounts 1,200 bytes apart, so every
transfer and audit moves between clocks, and `tests/cases/stm/blind-spread.ab`: four writers set three accounts in
three clocks without reading them, two auditors check they agree), `tools/test-stm-wasm-unwinding.sh` and
`tools/test-gc-stress.sh` pass. Each new test run alone, three runs, against a broken runtime:

| Runtime change | `bank-spread` | `blind-spread` |
|---|---|---|
| no revalidation at a clock's first read | fails: 26 to 49 wrong audits | fails: 61 to 327 wrong audits |
| moving to the second clock samples the first again (`resample`) | fails: totals 1,591 to 1,610 | passes |
| a new write entry does not move the mode | passes | fails: the commit's panic (a transaction with writes and no mode) |

`bank-spread` abandoned between 2,084 and 5,580 attempts in 20 runs (median 2,312), so its "conflicts true" is
reliable. The commit of a transaction with writes and mode 0 (no access recorded) panics instead of reading the
sampled list of an earlier attempt.

## Measurements

Master with the hybrid against master, `perf stat` on CPUs 0,2,4,6 in projects-e8's quiet window (14:19 to
14:22), ten alternating pairs per scenario, median of the pairs. "Own region": each thread's four TVars are
made apart from the others' (768 bytes of spare TVars between them), as a thread's own data usually is;
"consecutive": sixteen TVars made one after the other, a thread's group of four straddling a 1 KB boundary or
sharing a region with its neighbour.

| Scenario | own region: ns | cycles | instructions | consecutive: ns | cycles | instructions |
|---|---:|---:|---:|---:|---:|---:|
| four threads, disjoint | −57.9% | −55.5% | +1.8% | −12.5% | −23.0% | +12.4% |
| four threads, shared | +4.8% (pairs −9 to +27) | +3.1% | +14.7% | −12.5%, within noise (pairs −21 to +82) | −13.4% | +5.2% |
| forced logged, one thread | −1.4% | −1.2% | +7.9% | +0.0% | +0.1% | +7.9% |
| direct, one thread | +0.0% | +0.3% | +0.0% | +0.0% | +1.4% | +0.0% |

Forced-logged one-thread blocks execute 1,339 instructions against 1,241 (the access test and the mode
branches at commit), and their cycles are the baseline's to within 1.5%. Shared is the conflict-bound case (a
commit that loses retries); its pairs spread wider than any difference. A four-thread run on TVars that are
not apart pays the second clock's sampling at each escalation, and still gains in cycles. Most programs make
related TVars one after the other, so the consecutive column is as much the result as the own-region one: a gain
of 12.5% in time and 23% in cycles on disjoint TVars, 12% more instructions, and no gain it can show on shared ones.
The accesses in the partitioned mode no longer call the mode function (`mode >= 0` guards the call); the
instruction columns above are from before that change.
