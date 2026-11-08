# Native `--fast` pipeline screen, 2026-11-08

Master `68014c02`, a master compiler (`build/ablac`, v0.2.50 labelled), `perf stat -e instructions:u` pinned to
one P-core (deterministic counts, except where noted). A native `--fast` build runs `function(mem2reg,simplifycfg)`
in process and generates code with the target machine at optimisation level 0 (FastISel, the fast register
allocator), PIC, with DWARF line tables (`--fast` carries debug information by default).

Method: `ABLA_KEEP_LLVM_TEXT=1 build --fast --no-cache` keeps the module before the passes (`map.ll` 1.6 MB,
`unsafe-boundary.ll` 2.6 MB, `string-helpers.ll` 1.8 MB, all from `tests/cases/modules`). Each variant runs
`opt -passes=...` then `llc -O0 -filetype=obj -relocation-model=pic -mcpu=generic` over the bitcode of the same
module. The external `llc` also runs the IR verifier and the dynamic loader, which the in-process target
machine does not (about 10% of an `llc` run), so only comparisons between `llc` variants mean anything, not the
absolute figures.

## What the passes and the code generator cost

Millions of instructions. A variant's total is its `opt` above the floor plus its `llc`; today's total is the base row's. "floor" is `opt -passes=''` over the bitcode (read and write only); a pass costs
`base opt - floor`.

| Program | floor | passes (mem2reg+simplifycfg) | `llc` base | `llc` no passes | `llc` SelectionDAG | `llc` -O1 |
|---|---:|---:|---:|---:|---:|---:|
| map | 286.7 | 1.1 | 492.3 | 526.9 (+7.0%) | 799.2 (+62%) | 1,427.5 (+190%) |
| unsafe-boundary | 443.9 | 25.0 | 987.0 | 876.1 (−11.2%) | 1,326.0 (+34%) | 2,521.9 (+156%) |
| string-helpers | 332.1 | 2.0 | 574.8 | 612.8 (+6.6%) | 931.0 (+62%) | 1,654.8 (+188%) |

The two passes cost 0.2% to 2.5% of the pass-plus-`llc` time. Dropping them makes `llc` slower on two of the
three programs (+7.0%, +6.6%: probably because the alloca-heavy IR costs FastISel more than mem2reg saved; not measured) and faster on one
(−11.2%, which with the 25.0 M of the passes is −13.4% in all, on a program whose run segfaults in every variant
when linked with plain `cc`, so its run cost was not compared). No pass choice reaches the bar (at least 10% on
the small programs) consistently. FastISel at -O0 is the cheapest code generator available: SelectionDAG at -O0
costs 34% to 62% more, -O1 156% to 190% more. Adding passes costs about what it saves, except on one program. Each variant's total (its `opt` above the floor plus
its `llc`) against today's total (493.4 M, 1,012.0 M, 576.8 M): `sroa` alone (no mem2reg) 494.3 M, 806.5 M,
568.5 M, which is +0.2%, −20.3%, −1.4%; `function(mem2reg,simplifycfg,instcombine)` 491.2 M, 934.1 M, 572.3 M,
which is −0.4%, −7.7%, −0.8%; on `map` the instcombine variant also makes the program execute 20% more
instructions (22.8 M against 19.0 M, one run). Only `unsafe-boundary`, whose `llc` time is the largest and whose
run segfaults in every variant when linked with plain `cc` (its run cost was not compared), gains 10% or more
from a pass.

## Debug information

The one lever of size: `--fast` builds carry DWARF line tables (`grep -c 'DICompileUnit\|!DILocation\|!dbg' map.ll` counts 19,738 lines).
`build --fast --no-cache` against the same with `--no-debug`, whole-build `instructions:u` including the
frontend, two runs each (the compiler's frontend allocates and collects at load-dependent points, which probably
explains why identical runs differ):

| Program | default (runs) | `--no-debug` (runs) | change, second runs | executable |
|---|---:|---:|---:|---:|
| map | 1,751 M, 1,625 M | 1,480 M, 1,479 M | −9.0% | 142,928 → 118,824 B (−16.9%) |
| unsafe-boundary | 3,882 M, 3,686 M | 3,426 M, 3,425 M | −7.1% | 258,512 → 220,432 B (−14.7%) |
| string-helpers | 1,937 M, 1,938 M | 1,770 M, 1,772 M | −8.7% | 163,456 → 136,560 B (−16.5%) |
| `src/orc_main.ab` | 101.7 G, 80.5 G | 91.9 G, 74.2 G | −7.8% | 13.18 → 11.95 MB (−9.3%) |

The change is smaller than the run-to-run spread on `map`, `unsafe-boundary` and `orc_main` (first runs: −15.5%,
−11.7%, −9.6%). The steadier second runs are below the 10% bar and the noisier first runs straddle it, so it is not decisive; and `--fast` carries
debug information on purpose (a printed stack on a crash, `docs/toolchain.md`), so it is not changed. A suite
recipe that does not read a crash stack can set `ABLA_DEBUG=0` to take it.

## Verdict

No native `--fast` pass or code-generation setting gives 10% less compile CPU on the small programs: the two
passes are 0.2% to 2.5% of the LLVM time, FastISel at -O0 is already the cheapest code generator, and removing the
passes moves `llc` by +7% on two programs and −11% on one. Recorded as a no-go; nothing changed in the compiler.
The remaining LLVM time is instruction selection and object emission over a module of 1,800 or more allocas, and
the debug-information default, worth 7% to 9% in the steadier runs and up to 15% in the first ones, is a policy choice.
