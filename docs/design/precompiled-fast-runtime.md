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
  on the program is 26% of fib's, 23% of maps' and 9% of unsafe-boundary's. (The program's own functions in fib are
  2 functions, 39 IR instructions; in maps 1 function, 277.)
- With the link included (`perf stat`): empty 1.316 G, fib 1.405, maps 1.558 (units off, `--no-cache`).
- **How alike the runtime is across programs.** Emitted IR (`--emit-llvm`) of the empty program, fib, maps and
  unsafe-boundary: all 216 runtime functions of the empty program exist in each of the others; the bodies are
  identical for 190 (fib), 177 (maps) and 175 (unsafe-boundary) of them, which is 84%, 80% and 77% of the runtime's IR
  instructions. The remainder differs in the declaration: `byval(%AblaValue)` parameters on a runtime bridge against
  plain `nofree readonly captures(none)` pointers (`abla_string_data`, `abla_add`, `abla_null`, ...). That is not LLVM's
  attribute inference but our own pass, `bootstrapLlvmBridgeValuesByPointer` (`src/backend/llvm/runtime.ab`): after
  `cgscc(function-attrs)` it strips `byval` from a self-hosted runtime bridge, and from every call site, when every value
  parameter is read-only and every use of the bridge is a direct call, so the choice depends on the program (whether
  any use takes the bridge's address, and what function-attrs finds through the bridge's callees).
- **After optimization the module is small and its content depends on demand.** With the same fast passes
  (`opt`, ending in `globaldce`) the emitted modules shrink to 6 functions (empty), 26 (fib), 36 (maps) and 175
  (unsafe-boundary), most of the runtime having been inlined into the program's functions. Between fib and maps 25
  functions have the same name and 23 of them are byte-identical (2,431 of fib's 2,665 instructions, 91%); against
  unsafe-boundary 15 of 21 and 58%. So the optimized runtime code is largely shared, but the *set* of functions and
  what was inlined into the program's own functions differ, and a unit that groups functions by source file changes
  with the set.
- **The existing code generation cache does not share the runtime between programs.** Units are cut after
  optimization and keyed by the unit's bitcode (`src/codegen_units.ab`), by default only for modules over 150,000
  instructions. Forcing units for small programs (`ABLA_CODEGEN_UNITS_MINIMUM=1`) with one cache: fib creates 8
  objects, maps 7 more, the empty program 5 more; maps with a cache warmed by fib costs 1.84 G instructions against
  1.56 G for the default `--no-cache` build, and a cold units build costs 7 to 15% more than the default. The keys miss
  because a unit holds the functions its file contributes to *this* program (the reachable subset, with the bridge
  `byval` choice above), so the same file gives a different unit for each program.
- Standalone `opt` and `llc` runs on the emitted text IR (the same fast passes, FastISel) read opt 128 M and llc 29 M
  instructions for the empty program against 285 M and 94 M for fib, but parsing the text IR dominates them (running
  `globaldce` first changes opt by only -0.7% to -1.4% on the three programs), so I do not use them as the split.

Verdict: the "same in every program" LLVM work is **23 to 26% of a small `--fast` build** (9% of a 92 KB program) (above 30% of the LLVM time
for every program measured, 78% to 96% for fib and maps). That is the ceiling of what linking a precompiled runtime can
remove from LLVM; most of the rest is the compiler's own code (`ablac.bin` 56 to 58%, plus libc's malloc and memcpy,
10 to 12%, which is also the compiler's), the frontend over the same runtime and imports, which is the item
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
   The set of runtime bridges itself depends on the program (`bootstrapLlvmRuntimeBridgeUsed`: for example
   `abla_runtime_thread_entry` exists only if `abla_thread_create` is used), and so do the per-target inline marks
   (`bootstrapLlvmNativeRuntimeInline`), so a unit keyed by file changes with the program. GC roots: the frame
   pushes (`abla_runtime_roots_push` / `pop`) are program-independent only while the runtime treats frames as opaque;
   the invariant to keep, and to check, is that no runtime function reads a per-program type or descriptor table.
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
  `--gc-sections`. Most gain (up to 23 to 26% of a small build), largest change: points 1 and 2 above.
- **B. Make the existing code generation cache hit across programs.** As first written (declarations
  program-independent) this is not enough: the unit contents also follow the reachable subset. It needs both
  (1) the bridges' `byval` choice pinned (never strip, or strip by a rule that does not look at the program: it costs the
  copies the pass saves, measured on the benchmarks) and (2) a unit key per function (or per demand-independent group)
  instead of per file: the object cache then holds each optimized function once, and a build links the ones it needs.
  Codegen only: in-process code generation (instruction selection, register allocation, the object writer) is 10.2% of a fib `--fast` build by the profile below, and B can only save the shared part of it (91% of fib's instructions, so about 9% of the build at most),
  inlining unchanged because the cut stays after optimization. The cost is a per-function object boundary
  (cross-function references become symbols, no cross-function scheduling), which FastISel `-O0` does not use.
- **C. Do nothing about LLVM, take the frontend reuse first**: its estimate is larger (about half of a small build).

Recommendation, after the measurements above: B can remove only the codegen share (at most about 7% of a small build)
and needs the bridge ABI pinned and a per-function key, so it is a smaller prize than the table suggests; the rest of the
program-independent LLVM time is `opt` and module construction over all 216 runtime functions before `globaldce` removes
the ones the program does not reach. The first thing to establish is where the empty program's 0.26 G libLLVM
instructions go (experiment 1), because dropping unreachable runtime functions before they reach LLVM (and before
the ablac side lowers and emits them) would remove it without an object, an ABI change or a cache.

## Experiments before any design is final

1. Where the empty program's 0.26 G libLLVM instructions go: module construction and verification, the fast
   passes over 216 functions, bitcode write and read, code generation of the 6 that survive, target setup (a phase
   counter in the compiler, or `perf` with call graphs on a `-g` compiler; the flat symbol profile gives no answer).
2. Prune the runtime functions the program cannot reach before LLVM sees them (and before lowering), as the local
   `prune-dead-functions` branch did for release builds in 2026-11 (hello world 374 to 91 functions, 6 to 19% less CPU
   on small release builds, but `readInteger` 54% slower from different inlining): measure small `--fast` builds
   (CPU, run instructions on the eight benchmarks).
3. B's premise: skip `bootstrapLlvmBridgeValuesByPointer`, force units for small programs
   (`ABLA_CODEGEN_UNITS_MINIMUM=1`) and count the units that still miss across fib, maps and the empty program.

The raw numbers behind the table are in the session scratch files; the commands are the ones named above
(`perf record`/`perf stat` as quoted, `--emit-llvm` for the function comparison).

## Where the compiler process spends libLLVM time, and a pruning experiment

`perf record` of a fib `--fast --no-cache` build, samples of the compiler process classified by libLLVM symbol (3,181
samples; the process is 86% of the build, clang 8%, ld.lld 3%; libLLVM is 23.6% of the build inside the compiler):
register allocation and other machine passes 5.2%, building the IR (IRBuilder, attributes, containers) 4.8%, instruction
selection 2.7%, bitcode write and read 2.6%, the object writer 2.3%, `opt` passes and analyses 1.7%, the verifier
1.0%, debug info 0.5%, other 2.9%. So the passes are not where the time goes; code generation is 10.2%, and the
construction, serialization and verification of a module in which 96% of the functions are dead
(`globaldce` keeps 6 of 216 in the empty program) is 8.4% plus the optimizer's 1.7% and the compiler's own lowering and
emission of the same functions (about 4 to 5% by the earlier profile). That is the case for pruning before emission:
about 13% of a small build if all dead functions are never built.

Experiment (branch `fast-prune`, `ABLA_FAST_PRUNE=1`, not for merge): treat a runtime implementation as a root only when
its bridge is used, and emit only reachable functions, as closed targets already do. Result: 150 of 157 functions
are still emitted, because the bridges (`abla_void`, `abla_add`, ... the value-runtime group, all non-optional in
`bootstrapLlvmDeclareRuntime`) and the implementations they call are emitted whether or not the program uses them;
only `globaldce` drops them later. (The first stage-1 numbers, 68% of the baseline's instructions, were an aborted
build: the export thunk for an unemitted implementation failed LLVM's verifier. They mean nothing.)

What it would take: bridge bodies are emitted after all function bodies, and the emission model computes
reachability up front (emitted-function flags feed the stack-closure sites, the retained linked data, the inline-assembly
list and the debug declarations before any body exists). Pruning the bridges therefore needs either the reachability to
include the backend's own uses of each bridge (an audit of the 105 bridge names in `functions.ab`, with a loud link error for
a missed one: dormant declarations are left external and hidden), or lazy emission driven by uses of the declarations
(late roots, which conflicts with the analyses that run before emission). The audit route is a bounded change; its
bar is the one set for this item.

### Result of the audit route (landed in v0.2.53: `--fast` prunes on Linux hosts)

The bridge roots are demand-driven: `bootstrapLlvmBridgeSymbolsGatherReachable` (runtime.ab) collects the bridge symbols
the reachable instructions call (plus the `extern` names they mention), the field/object/array and
generator/task/thread families by opcode prefix, and an explicit list of the symbols the backend emits by itself
(`bootstrapLlvmBackendBridgeSymbols`); a fixpoint in `backend.ab` adds the implementations behind those symbols as
reachability roots until nothing changes. Closed-program targets, Wasm, cross targets and release builds keep their
paths; compile-time emission is unpruned; `ABLA_FAST_PRUNE=0` turns it off and the setting is part of the whole-build
cache key. A function left dormant stays an external hidden declaration (a missed edge is a link error), and the unused
ones are erased so an object carries no undefined symbols.

Measured (instructions of the whole `--fast --no-cache` build, pruned over unpruned): hello 90.5%, fib 91.2%,
maps 92.4%, strings 92.9%, trees 92.0%, dispatch 92.3% (7.1 to 9.5% less). The bar was 8% on fib, maps and hello:
maps misses it by 0.4 points; it already drops 19 more functions than it keeps, so narrowing the family tests would
not close that. The run instructions of the eight perf benchmarks are identical (differences under 0.00001%).
Checks: 540 programs build both ways with the same status; 608 programs built, run and compared (exit status and output,
`tools/sweep-fast-prune.sh`) with no real difference; `tools/test-fast-prune.sh` (threads, generators, floats and an
export library, pruned against full, plus a size assertion); the suite, including `test-native-platform-boundary` at
`--fast`, which caught the undefined symbols pruning left in objects.
