# A precompiled runtime for `--fast` builds: measurement and design (2026-11-09)

Question (ablac-45): in a small `--fast` build, how much of the LLVM time goes to runtime and standard-library
functions that are the same in every program, and would a runtime object built once per compiler identity and linked
instead of recompiled pay? Measured first; the design below is a note, no code.

## Measurements

Stage-1 compiler of master `544efc82` (from the v0.2.49 seed), `build --fast --no-cache`, one P-core,
`perf record -e instructions:u -c 400000 --inherit` of `build/ablac.bin` (the native link step failed outside the
nix shell, so these count the compiler and its in-process LLVM, not clang or `ld.lld`), plus `perf stat` runs inside
the shell for whole builds.

| Program | build instructions | `ablac.bin` | libLLVM | libc |
|---|---:|---:|---:|---:|
| empty `main` | 1.00 G | 58.4% | 26.3% | 10.4% |
| `perf/fib.ab` | 1.02 G | 57.3% | 27.0% | 11.2% |
| `perf/maps.ab` | 1.14 G | 55.7% | 29.4% | 10.6% |
| `unsafe-boundary.ab` | 2.98 G | 57.8% | 28.6% | 11.7% |

- **An empty program is 98% of fib's build and 88% of maps'**; unsafe-boundary (a 92 KB program) is 34% fixed. The
  fixed part is the runtime (216 functions in the emitted module of the empty program) plus the imported standard library.
- **libLLVM's fixed share** (empty libLLVM instructions over the program's): fib 0.263 of 0.275 G (96%), maps
  0.263 of 0.335 (78%), unsafe-boundary 0.263 of 0.853 (31%). In whole-build terms the LLVM time that does not depend
  on the program is 25% of fib's, 23% of maps' and 9% of unsafe-boundary's. (The program's own functions in fib are
  2 functions, 39 IR instructions; in maps 1 function, 277.)
- With the link included (`perf stat`): empty 1.316 G, fib 1.405, maps 1.558 (units off, `--no-cache`).
- **How alike the runtime is across programs.** Emitted IR (`--emit-llvm`) of the empty program, fib, maps and
  unsafe-boundary: all 216 runtime functions of the empty program exist in each of the others; the bodies are
  identical for 190 (fib), 177 (maps) and 175 (unsafe-boundary) of them, which is 84%, 80% and 77% of the runtime's IR
  instructions. The rest differ in the declaration only: parameter attributes the program's use led the compiler to infer
  (`byval(%AblaValue)` against `nofree readonly captures(none)` on `abla_string_data`, `abla_add`, `abla_null`),
  an attribute group number, never the body (the ones I diffed: `abla_runtime_roots_push`, `abla_string_data`,
  `abla_add`).
- **The existing code generation cache does not share the runtime between programs.** Units are cut after
  optimization and keyed by the unit's bitcode (`src/codegen_units.ab`), by default only for modules over 150,000
  instructions. Forcing units for small programs (`ABLA_CODEGEN_UNITS_MINIMUM=1`) with one cache: fib creates 8
  objects, maps 7 more, the empty program 5 more; maps with a cache warmed by fib costs 1.84 G instructions against
  1.56 G for the default `--no-cache` build, and a cold units build costs 7 to 15% more than the default. Whole-program
  attribute inference makes the same runtime function's unit differ between programs, so the keys miss.
- Standalone `opt` and `llc` runs on the emitted text IR (the same fast passes, FastISel) read opt 128 M and llc 29 M
  instructions for the empty program against 285 M and 94 M for fib, but parsing the text IR dominates them (running
  `globaldce` first changes opt by only -0.7% to -1.4% on the three programs), so I do not use them as the split.

Verdict: the "same in every program" LLVM work is **20 to 28% of a small `--fast` build** (above 30% of the LLVM time
for every program measured, 78% to 96% for fib and maps). That is the ceiling of what linking a precompiled runtime can
remove from LLVM; the other 58% (`ablac.bin`) is the frontend over the same runtime and imports, which is the item
"Reuse the frontend's work on the standard library between builds" and which a runtime object alone does not touch
(the runtime's source still has to be parsed and analyzed for its declarations, unless a declaration file replaces it).

## What a runtime object has to get right

1. **ABI.** The object's entry points need one calling convention independent of the program. Today the compiler
   chooses per program (byval or plain pointer, `sret`, the "scalar direct" ABI, borrowed parameters). Pinning the
   convention is a design step in itself: the cost is extra copies in programs that gain from the other form.
2. **Inlining.** `--fast` inlines at threshold 100 across the whole module, runtime included (the object allocation fast path
   of 0ece5df5 relies on being inlined). A separate object loses that unless the runtime's small hot functions stay as
   bitcode or IR in the program module (`available_externally`), which brings back part of the opt cost. The run-time cost
   must be measured on the benchmarks (bar from #662: at most +5%).
3. **Demand.** The compiler emits only the reachable runtime today; an object holds all of it. Link-time
   `--gc-sections` removes the unreferenced, but data tables the runtime owns (root frames, type and string
   tables, the GC's configuration `__ablaRuntimeHostGcGrowthConfigured`) must not depend on the program. Anything
   that does (per-program tables) stays generated and is passed in, not compiled into the object.
4. **Policies that change the runtime's code.** Float demand (#695: plain equality against the float-aware variants), the
   stack guard (`bootstrapLlvmStackGuard`, hosted executables only), the initializer chunk, `ABLA_FAST_INLINE_THRESHOLD`,
   debug info, strict imports, hosted against freestanding and every target. Each is either a second object variant (key:
   compiler identity + target + policy set) or must move out of the object.
5. **Identity and `--no-cache`.** The object belongs to the compiler (built at release or on first use, kept beside it,
   keyed by the compiler image hash and LLVM identity). `--no-cache` must keep meaning "do not reuse the build's output",
   not "rebuild the compiler's own parts"; tests that check the cache or the build itself keep building everything.
6. **Reproducibility.** The same program must give the same executable whether the object came from the cache or was built
   now: the object is deterministic from its inputs, as the units are (`codegen_units.ab` already relies on that).

## Options

- **A. Fixed-ABI runtime object per (compiler, target, policy set)**, program modules `declare` it, link with
  `--gc-sections`. Most gain (up to 20 to 28% of a small build), largest change: points 1 and 2 above.
- **B. Post-optimization runtime units that do hit the cache across programs.** Make the runtime's functions
  program-independent *before* the cut (no per-program attribute inference on them: infer attributes on the program's own
  functions only; same body text), so the existing code generation cache keys match. Saves codegen only (the `llc` part,
  the smaller half of LLVM), no ABI change, inlining unchanged because the cut is after optimization. Much smaller step;
  the measurement above shows today's misses are about declarations.
- **C. Do nothing about LLVM, take the frontend reuse first**: its estimate is larger (about half of a small build).

Recommendation: **B first** (it tests the premise cheaply: do the runtime units hit across programs once their
declarations agree, and how much of `llc` does that remove?), then decide A from the measured codegen share. The
precompiled object (A) is worth designing in full only if B leaves most of the opt cost, since opt runs over the whole
module either way.

## Experiments before any design is final

1. For fib/maps/unsafe-boundary: instructions of the in-process `opt` step and of the FastISel step separately (a phase
   counter in the compiler, not text IR), to split the 25% into opt and codegen.
2. B's premise: make `abla_string_data`, `abla_add`, ... declarations program-independent (a flag that stops
   interprocedural attribute inference on runtime functions) and count the units that hit with
   `ABLA_CODEGEN_UNITS_MINIMUM=1` across fib, maps and the empty program.
3. Run-time cost of pinning the ABI (point 1) on the eight `perf` benchmarks.

The raw numbers behind the table are in the session scratch files; the commands are the ones named above
(`perf record`/`perf stat` as quoted, `--emit-llvm` for the function comparison).
