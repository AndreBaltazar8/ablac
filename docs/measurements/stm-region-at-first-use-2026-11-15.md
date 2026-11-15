# STM clock regions at first use, 2026-11-15

Follows `stm-hybrid-clocks-2026-11-08.md`. There, a TVar's region (and its clock, region & 15) was its address
>> 10. A thread's TVars made next to another thread's then shared a region, or a block's four TVars straddled
two regions and sampled two clocks. Now a TVar's region is set once, at the first logged transaction that
reaches it: it is that thread's, `(number << 4) | (number & 15)`, where number is the thread's descriptor number.
So the TVars one thread's transactions use share its clock, however and wherever they were made.

## How

- The TVar's unused word at +8 holds the region. `__ablaRuntimeTVarCreate` stores -2, which never equals a
  transaction's mode (0 before the first access, -1 once escalated, a region otherwise).
- Every logged read and every first logged write already compared the TVar's region with the transaction's mode.
  They now load +8 instead of shifting the address. A TVar without a region always differs from the mode, so it
  reaches the out-of-line `__ablaRuntimeStmAccess`, which sets it by a compare-and-swap from -2 (a losing thread
  takes the winner's) before going on as before.
- A commit's written TVars passed through that path, so their clocks (`__ablaRuntimeStmPartition`, now +8 & 15)
  are set before any version is given.
- Nothing else changed: the protocol, the descriptor, the TVar's size, direct mode, WebAssembly.

## Candidates screened

Per block of four TVars read and written. Each run does one scenario under `perf stat` (user space,
cpu_core counters) on CPUs 0,2,4,6. A run of zero blocks for the same variant is subtracted, and the figure is
the median of three. Variants:
- base: master 6409ecd4;
- A: region = address >> 12, the allocator's page instead of 1 KB;
- B: the region counted at creation, one per sixteen TVars made;
- C: the region of the thread that first uses the TVar.

| Scenario | base | A | B | C |
|---|---:|---:|---:|---:|
| four threads, disjoint, each thread's TVars made apart ("own") | 1,402.5 instr, 918.5 cycles | 1,364.6, 892.7 | 1,395.8, 849.6 | 1,330.0, 840.0 |
| four threads, disjoint, sixteen TVars made one after the other ("adjacent") | 1,537.4, 1,460.1 | 1,445.6, 1,451.1 | 1,442.7, 1,594.0 | 1,330.0, 1,200.7 |
| four threads, shared | 11,852.6, 7,296.0 | 12,239.7, 6,865.4 | 11,350.8, 7,142.3 | 11,571.7, 7,058.8 |
| one thread, forced logged | 1,335.0, 387.7 | 1,335.0, 389.1 | 1,330.0, 389.4 | 1,330.0, 390.4 |

- A and B change where the boundaries fall, not whether they fall inside a structure. B's adjacent case puts all
  sixteen TVars on one clock and gets slower.
- With C, both disjoint cases execute exactly the one-thread logged block's 1,330 instructions: every block stays
  on its thread's single clock.

## C against base, ten alternating pairs

The same runs, base and C alternating (BA on even pairs). Machine load was 3.4 to 4.6, in a fair-flock slot,
not a quiet window. Instruction counts are exact; cycles and wall time are indicative. Median of the ten pairs'
changes, with the pairs' range:

| Scenario | instructions | cycles | wall |
|---|---:|---:|---:|
| four threads, adjacent | −13.6% | −31.1% (−42.1 to −13.6, every pair lower) | −20.1% (−31.1 to −14.6) |
| four threads, own | −5.2% | +2.7% (−19.6 to +38.0) | −0.2% |
| four threads, shared | −4.4% | +6.1% (−71.9 to +22.5) | +6.8% |
| one thread, forced logged | −0.37% (1,335 to 1,330) | +0.5% (−1.6 to +6.7) | +0.7% |

- The adjacent case gains what the 2026-11-08 own-region case gained.
- The own case was already single-clock in most blocks. It loses the escalations its group boundaries still caused
  (instructions −5%), with no cycle change beyond noise.
- Shared is conflict-bound and as noisy as before.
- The forced-logged one-thread block does not grow: the load replaces the shift.

## Correctness

- **Model.** `stm-hybrid-clock-model.mjs lazy`: no TVar has a clock until a transaction first reaches it, then it
  takes that transaction's home clock, once; the transactions of a spec alternate between two homes.
  `node stm-hybrid-clock-model.mjs lazy 200000`: 1,000,000 schedules, 0 violations. Negative control `overwrite`
  (every access stamps the TVar with its own home clock again): 4,990 of 102,105 schedules violate at 40,000 a
  spec. The fixed-mapping modes are unchanged by the edit (`hybrid` 0; `resample` 2,519, `nosample` 55,
  `broken` 7,213, `skipfresh` 477 at 40,000 a spec, the same as the file before it).
- **Spread tests.** `tests/cases/stm/bank-spread.ab` and `blind-spread.ab` gave each account its own clock by
  address (spare TVars between them). That no longer decides a clock, so each now runs `spreadClocks`: one short
  thread per account reads it first in a logged transaction. Against a runtime with no revalidation at a clock's
  first read, both still fail, three runs each: bank-spread with 85 to 223 wrong audits, blind-spread with 2,049
  to 2,876.
- **New `tests/cases/stm/region.ab`** (in `tools/test-stm.sh`). Eight TVars made one after the other have no region
  (-2). Four used by one thread and four by another take two regions on two clocks, and a third thread's
  transaction over all eight changes none. On the base runtime it fails (every +8 stays 0, one clock).

## Not covered

- A thread that first touches TVars other threads mostly use gives them its clock, which can be worse than an
  address mapping. Example: one worker that initialises a structure in logged transactions while others run.
- A thread past the sixteenth shares a clock with an earlier one (number & 15). That costs scaling, not safety, as
  two regions on one clock did before.
- Cycles and time were measured under load, not in a quiet window.
