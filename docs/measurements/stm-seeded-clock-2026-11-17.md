# STM: a TVar seeded by one thread, used by four, 2026-11-17

Follows `stm-region-at-first-use-2026-11-15.md`, whose "Not covered" named this case: a thread that first reaches TVars
which other threads then mostly use gives them its clock.

## Measurement

`tests/cases/stm/bench-seed.ab` (a benchmark, not run by the suite). Sixteen TVars, four threads each reading and
writing its own four in a logged transaction per block, 300,000 blocks per thread, pinned to CPUs 0,2,4,6, inside a
fair-flock slot (the machine was loaded). Twelve alternating runs of two sets:

- own: each thread's first logged transaction reached its own four TVars: four regions, four clocks (17, 34, 51, ...);
- seeded: one thread's first logged transaction reached all sixteen: one region, one clock (85 for every TVar).

| | ns per block (mean of 12, range) |
|---|---|
| own, four clocks | 123 (90 to 158) |
| seeded, one clock | 131 (106 to 153) |

The seeded set is about 6% slower on average and the ranges overlap almost entirely. This is the worst case for the
seeded set: every transaction is disjoint from every other, so the only thing the clocks decide is whether four
threads bump one counter. A real structure's transactions share data, where a clock is not the bottleneck
(the shared-TVar row of the 2026-11-15 table is conflict-bound).

## Why nothing changes

- Nothing is wrong, only slower in this one shape: the model (`stm-hybrid-clock-model.mjs lazy`) holds for any
  assignment of regions, and a transaction on TVars of one clock never escalates.
- Taking the region from the first logged commit that *writes* a TVar rather than the first access does not help the
  case: an initialising thread writes what it seeds.
- Moving a region while no transaction holds the TVar needs the protocol's rule (a TVar's clock is fixed from its
  first versioned commit) relaxed, with revalidation like a clock change. That is protocol work in the part of the
  runtime whose correctness rests on a model check, for at most a few percent in a synthetic worst case.

Closed without a change. If a program shows a real slowdown from a seeded structure, the cheap answer is in the
program: let each thread's first logged transaction reach its own TVars, as `own` does.
