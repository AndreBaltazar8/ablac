# STM partitioned clocks, 2026-11-08

Master `205164d7` plus the prototype commit, a master compiler (stages 1 and 2 from v0.2.49), `perf stat`
on CPUs 0,2,4,6 (P-cores, no SMT siblings; four threads), machine load 10 to 40, so ratios are paired
(baseline and candidate alternate, six pairs per scenario, median of the pairs). Harness: one scenario per
process (`STM_SCENARIO`), four TVars read and written per block, 2,000,000 blocks per thread; the same
block and workers as `tests/cases/stm/bench.ab`.

## Where the disjoint time goes

| Scenario (baseline) | instructions / block | cycles / block | ns / block |
|---|---:|---:|---:|
| direct, one thread | 733 | 180 to 205 | 32 to 40 |
| forced logged, one thread | 1,241 | 470 | 90 to 97 |
| four threads, disjoint TVars | 1,340 to 1,375 | 830 to 1,700 | 94 to 102 |

The disjoint run costs 8 to 11% more instructions than a logged one-thread run (1,340 to 1,375 against 1,241)
and 1.8 to 3.6 times the cycles (830 to 1,700 against 470): it is waiting on cache lines, not executing more
code. An earlier sampling of the last-branch records put about 10% on the clock's compare-and-swap, which read
as "the clock is not the first target"; the cost is the transfer of the clock's line, which the neighbouring
instructions wait for, not the instruction itself. Replacing the global clock with a per-thread counter
(wrong semantics, disjoint scenario only, an upper bound) takes disjoint from 99 ns to 57 ns a block
(median of seven pairs, cycles −50%). Spacing the TVars 160 bytes apart changed nothing measurable, so it is
the clock's line, not the TVars'.

## The prototype

Sixteen clocks, each alone in a cache line, picked by a TVar's address `(address >> 4) & 15`. A transaction takes
a partition's snapshot (that clock's value) at its first read there, and revalidates the reads so far at that
moment; a TVar newer than its partition's snapshot moves that snapshot up after revalidating, as before. A
commit locks its TVars, then takes a version from each written partition's clock (TL2's GV4 per clock),
validates unless every partition it read or wrote is exactly where its snapshot left it, writes back and
releases each TVar at its own partition's version. Direct mode, retry, `orElse` and the serial lock are
unchanged. Descriptors grow from 512 to 1,024 bytes.

`stm-partitioned-clock-model.mjs` models first-read sampling and the move of a snapshot (extension) over random
interleavings of 2 to 3 transactions (atomic steps: each load, compare-and-swap and store): every pair of
values any attempt reads is a committed state, and the final state is serial. Its commit always validates and
its clocks add one: the "clocks unmoved since the snapshot, skip the validation" shortcut and GV4's sharing of a
version are not modelled here (the hybrid model has the shortcut; sharing is covered only by `test-stm`).
`node stm-partitioned-clock-model.mjs lazy 300000` (4 specs, 1,200,000 schedules): 0 violations, as for the
single-clock control `old`. Negative controls: `broken 100000` (no revalidation when a snapshot is moved up)
519 of 400,000 schedules violate; `nosample 100000` (no revalidation at a partition's first read) 1,444 of
400,000.

`tools/test-stm.sh` (direct and logged through collections, stressed and Wasm; eight threads moving money
under two auditors; retry wakeups) and `tools/test-stm-wasm-unwinding.sh` pass with the prototype.

## Paired results against the baseline

| Scenario | ns / block | cycles |
|---|---:|---:|
| four threads, disjoint | −26.0% | −29.8% |
| four threads, shared | +4.4% (pairs −13 to +20) | +1.8% |
| forced logged, one thread | +22.5% | +22.3% |
| direct, one thread (code unchanged) | +3.7% (pairs +2 to +19, all six positive) | +3.9% |

The logged one-thread run executes 1,620 instructions a block against 1,241 (+30.5%): the per-read partition lookup
and first-read sampling, and the per-partition compare-and-swap, versions and freshness checks at commit. The
partition shift (6, 7, 8 for 64, 128, 256-byte regions instead of 16) changes disjoint to −4%, −29% and −19%
(non-monotonic: that spread is about the noise of these runs, so −26% for the shipped shift may be partly luck)
and logged stays +17 to +26%.

Against the bar (≥15% disjoint with the others within noise): disjoint passes by a wide margin, shared is within
noise, direct is not touched by the change (its code is identical; a later run with a hybrid binary shows the
same instruction count, 733 a block, so the spread is code alignment and load), and forced logged
fails at +22%. Direct mode, the case of one thread, never pays it; any program with a second thread logs every
transaction, and pays the +22% on a transaction that no other thread conflicts with, against −26% when threads
run disjoint TVars.

## Where the logged overhead is, and the verdict

Instructions per block, forced logged, one thread (`perf stat -e instructions:u`, deterministic):

| Variant | instructions / block | vs baseline |
|---|---:|---:|
| baseline (one clock) | 1,241 | |
| the prototype, 4 partitions touched | 1,620 | +30.5% |
| the same code with every TVar in one partition | 1,408 | +13.5% |

So the machinery costs about 167 instructions a block even when one partition is touched (the clocks pointer
loads, the mask test and sampling on the first read, the sampled list, the per-partition version loop, the
freshness checks and the per-partition release lookup), and about 70 more for each further partition (its
first-read sampling with a revalidation of the reads so far, its list entry, its compare-and-swap and version
slot). A block of four TVars in four partitions pays both. Reaching the ≤ +5% single-thread bar (62
instructions of 1,241) would need the 379 cut by about five sixths, which the structure (a lookup and a test
on every read, a loop over the write set at commit) does not allow; the cheap trims (caching the clocks pointer
in the descriptor, merging the commit loops) were estimated at 30 to 50 instructions, not 300.

Verdict: the disjoint win is real and large (−26% ns, −30% cycles, up to −34% in cycles and −29% in time with
128-byte partitions), shared
and direct are within noise, forced-logged one-thread is +22% in time. It is not shipped. The prototype stays on
branch `stm-clocks`. A design that keeps the one-clock fast path for transactions touching a single partition
(sampling and commit unchanged, partitioned only when a second partition is read or written) would pay the
fixed part only for transactions that need it. That is the hybrid of `stm-hybrid-clocks-2026-11-08.md`.
