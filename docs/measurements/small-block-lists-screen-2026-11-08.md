# Native small-block lists: floor, trim and stranded-list screen, 2026-11-08

Master `d134eeb4`, release binaries built by `build/ablac` (v0.2.50) with `ABLA_SYSROOT` set to a worktree whose
`stdlib/abla/runtime/platform/host.ab` carries `small-block-lists-screen-2026-11-08.patch`. One program run
per setting is pinned to CPU 2; peak RSS is the median of three (`ru_maxrss` of the child, MiB), instructions
are `perf stat -e cpu_core/instructions/u` of one run (G); one run per cell is noisy on json-megabyte
(its `strand` row reads -0.6% from the base with nothing in the change that should lower instructions), so
that program's instruction columns cannot show a +1% limit, while the +11% to +49% of trees, strings and maps and
the +3% to +7% of json-readers are well outside it. The patch reads three environment variables:
`ABLA_SB_FLOOR` (MiB, the least the lists keep: 32 by default, as today), `ABLA_SB_TRIM=1` (at each collection,
free blocks largest class first until the lists hold at most the new budget) and `ABLA_SB_STRAND=1` (after a
foreground sweep the head of every list is recorded; at the next collection a list whose head is unchanged,
so nothing was taken from that size, is freed whole). No per-hit bookkeeping in any variant.

| Program | base | floor 16 | floor 8 | floor 4 | strand | strand + floor 16 |
|---|---:|---:|---:|---:|---:|---:|
| trees | 227 / 12.403 | 227 / 14.281 (+15.1%) | 227 / 16.342 (+31.8%) | 227 / 18.494 (+49.1%) | 227 / 12.403 | 227 / 14.281 |
| strings | 159 / 2.068 | 160 / 2.719 (+31.5%) | 161 / 2.906 (+40.5%) | 161 / 3.006 (+45.4%) | 159 / 2.068 | 160 / 2.719 |
| maps | 139 / 2.576 | 140 / 2.854 (+10.8%) | 140 / 2.975 (+15.5%) | 140 / 3.039 (+18.0%) | 139 / 2.576 | 140 / 2.854 |
| json-readers (3000,100) | 168 / 4.337 | 155 (-7.7%) / 4.479 (+3.3%) | 143 (-14.9%) / 4.561 (+5.2%) | 137 (-18.5%) / 4.603 (+6.1%) | 168 / 4.343 (+0.1%) | 155 / 4.478 |
| json-megabyte (30000) | 218 / 22.139 | 305 / 22.823 | 212 / 22.497 | 305 / 23.023 | 298 / 22.009 | 256 / 22.381 |

Each cell is peak RSS in MiB / instructions in G. With `ABLA_SB_TRIM=1` (floors 16, 8, 4) RSS is the
same as without it for trees, strings, maps and json-readers (probably because the lists are already below the budget at
each collection), json-readers' instructions rise a little further (4.532, 4.610, 4.639 G: +4.5%, +6.3%, +7.0%),
and json-megabyte reads 216, 219 and 215 MiB with 22.322, 22.449 and 22.546 G.

## What it says

- The 32 MiB floor is what trees, strings and maps run on: trees +15% to +49% instructions, strings +31% to
  +45%, maps +11% to +18% with a lower one. Probably (a reading of the budget rule, not measured): a budget
  starts at the floor and grows at most by a quarter of what a cycle took from the lists (`kept = 1.25 *
  served`, and `served` cannot exceed what the lists held), so a lower floor is not caught up within the few
  collections these programs have.
- json-readers is the one program that responds in RSS (168 to 143 MiB at floor 8, -14.9%, just under the 15% bar), and
  it pays +5.2% instructions for it, over the +1% bar by itself; trim changes nothing, probably because there is
  nothing above the budget to trim.
- Freeing lists that saw no hit (`strand`) changes json-readers by +0.1% instructions and 0 MiB: probably
  every size class it keeps sees some hit, so the retained bytes are spread across lists that are in use, not
  stranded in a few (the number of lists freed per collection was not counted). On json-megabyte it is worse (218 to 298 MiB), and its other rows swing between 212 and 305 MiB with the
  floor, the same non-monotone behaviour the earlier rounds found (no variant is near -15%).
- No variant passes the bar (json-readers and json-megabyte peak RSS down at least 15%, every benchmark's instructions
  within +1%). Stopped there: no compiler self-build peak, GC-stress or threads run was made for variants that fail
  the first gates.
