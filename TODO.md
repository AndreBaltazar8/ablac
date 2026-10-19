# TODO

Open compiler, package, and performance work. The package audit began at
`1a90db5` (2026-10-08); resolved entries were removed after the v0.2.15 Linux
release checks on 2026-10-11. Platform and package checks still missing are
called out below.

## Compiler and stdlib

- [ ] **`ablac run` becomes a live JIT.** The direction for `run` is a live in-process JIT: a
  running program loads code and redefines its own functions while it runs. Done: the JIT
  module gets the `--o1` IR pipeline (`--fast`: the fast one), which made `run` the in-process
  path again; `run --built` builds through the cache and execs the result. Measured on
  2026-10-13 against build + exec cold/warm: a map exporter 5.98 s (13.94 s without the
  pipeline; built 15.45/6.39 s), a map builder 10.90 s (86.76 s; 10.58/9.52 s), a model
  generator 57.75 s (over 9 min; 62.4/62.0 s). Done since: an object cache (`jit_cache.ab`:
  the object LLJIT generated, captured through its object transform layer, reused while every
  source file and compile-time input is unchanged), so a rerun skips compiling. Next:
  indirection stubs (ORC lazy reexports or an indirect stubs manager) so a function can be
  redefined while the program runs.

- [ ] **An operator in a parameter default is not rewritten.** `fun f(b: N = N(1) + N(2))`
  with `operator fun N.plus` fails with `arithmetic.type`: the probe resolves the default's
  `+`, but `bootstrapOverloadRewriteDeclaration` (`overload.ab`) rewrites only the body,
  not `parameterDefaults` (a method's defaults likewise).

## Packages

Package-side work (not changed from ablac):

- [ ] **abla-mobile's native layer still targets the removed C runtime.**
  `runtime/native/CMakeLists.txt` compiles ablac's `runtime/abla_runtime.c`
  (removed in `93ce196`), and the C platform layer implements that old ABI.
  Compiler-side Android objects now contain the Abla runtime; update the package's
  native layer and verify a complete Gradle/NDK build on both architectures.
- [ ] **Verify abla-embedded's runtime at the ESP-IDF link.** RISC-V objects
  compiled in the original audit; Xtensa builds still needed a matching ESP LLVM.
  The audit also found general-dynamic TLS references (`__tls_get_addr`), which
  ESP-IDF may not supply. Recheck the current TLS lowering with the actual target
  toolchains and complete the ESP-IDF links before closing this item.

## Compile time and memory

- [ ] **Temporaries never share a stack slot.** Every IR value that is not a scalar gets
  its own 24-byte slot, and the backend emits no `llvm.lifetime` markers, so LLVM keeps
  them all apart: a frame grows with its function's size, not with what is live at once.
  `BootstrapEvaluator.evaluate`, a `when` of 25 calls, still holds about 180 slots
  (2.3 KB), of which a few are live at a time. Moving the evaluator's, the analyzer's and
  the lowerer's cases into `@noinline` functions took a nested JSON literal from about
  420 KB of stack per level to 28 KB. Markers for the values defined and last used inside
  one IR block (the GC root plan already finds each value's definition and last use)
  would shrink every frame, programs' too. First, audit the emitter for value reads that
  do not come from an instruction's `left`, `right` or `operands`.

Measured on a 10K-function Wasm application (86 MB of LLVM IR). Its dev build's compiler,
collecting each time its heap grows by 256 MiB, peaks at about 1 GB and takes about 28 CPU
seconds (88 G cycles); never collecting, it takes about 24 (73 G cycles) and peaks at
10 GB. (Plain globals for the root frame until threads are enabled were tried: 5% faster
compiler, 1% slower fixed-step simulation; branch `perf/compile-memory-v2`.) Not yet done:

- [ ] **`opt` and `llc` run one after the other on one module.** In that dev build they are
  22.6 of its 54 wall seconds (opt 11.6, llc 11.0). Emitting the module as N partitions
  during emission and running N opt/llc pairs at once would cut most of that wall time on a
  multi-core machine; the partitions must then link as before (wasm-ld takes several
  objects). Splitting the finished module does not pay: with 4 parts, llvm-split takes
  6.5 s while llc drops 11.0 → 3.5 s, so wall time is unchanged, total cycles grow 16% and
  the dev wasm grows 240 KB of data (constants stop merging across parts).
- [ ] **A release Wasm module is optimized four times** (`opt` O1, clang's O2 pre-link,
  wasm-ld's LTO O3, wasm-opt -O3; for a large game client about 28, 27, 70 and 35 s of a
  165 s build). Dropping a pre-link stage does not pay: its work moves into the later ones.
  Measured on that client (two alternating rounds; runtime from a simulation module's
  ticks, three rounds of nine):

  | Path | Total | Client size | Runtime |
  |---|---|---|---|
  | as built (A) | 169 s | 6,423,340 B | baseline |
  | no clang O2 pre-link (B) | 167 s | +0.15% | same within noise |
  | no `opt` O1 (C) | 169 s | −1.8% | same within noise |

  C is a possible free size win; it would need a native release build's and a client's
  frame-time check before it changes anything.
  With the LTO link in 4 partitions and wasm-opt sorting functions first (2026-10-10), the
  pre-link is the cheapest lever left in that stage. Without it, the link stage (pre-link,
  wasm-ld, wasm-opt) of the same client takes 756 G instructions instead of 925 G
  (−18%) and 73 s instead of 96 s, and the client is still 0.14% smaller than before
  partitions. It is blocked on runtime: the simulation module's fixed step is about 1.7%
  slower (best of five, two rounds: 655/659 µs against 644/646), and a HUD function grows
  1.8%. A pre-link at O1, or one limited to the functions it changes most, might recover it.
  A native server's release LTO link gains little from partitions: its time is the serial O2
  pipeline on the merged module, and code generation is 4-5 of its 36 s (ld.lld, 4
  partitions: 33 s, +4% instructions, +0.14 GB peak). It stays at one partition.
- [ ] **`llc`'s peak on a large Wasm module** (~1.9 GB for that client's 31 MB of bitcode,
  most of the build's peak): loading the module takes 0.5 GB, and the rest is machine code
  for every function held at once, because WebAssembly's code generation runs a module pass
  (`WebAssemblyMCLowerPrePass`) that needs all functions' machine code before any is freed.
  Writing no object (`-filetype=null`) still peaks at 1.93 GB, and without debug
  information at 1.84 GB, so no `llc` option cuts it. Smaller functions (the boxing item
  below) or fewer functions per `llc` (partitions, above) would.
- [ ] **Per-call boxing in the lowering.** 17% of the IR's instructions are
  `alloca %AblaValue` (146K in that program), with as many stores and loads around them
  and 29K `abla_i64` boxing calls. `opt`'s time is mostly the inliner, instcombine and SROA
  undoing it. Passing and returning scalars unboxed would shrink opt and llc time, the Wasm
  and run time together; it is the largest lever left, and a large change.
  Of the slots `opt` keeps in a 6.7K-function client, two thirds are passed to calls (the
  boxed argument ABI: string concatenation, field and array stores lead) and most of the
  rest were pinned by the runtime reading a value through `ablaRuntimeValueAddress`; the
  backend now addresses the slot itself there, which freed 21% of the kept slots.
  Tried and dropped: boxing constants by copying a private constant value (instcombine
  then passes the constant itself to read-only parameters) and copying values with
  `memcpy`. Fewer slots survived, yet the Wasm grew 0.5% to 15%. A string's static value
  holds its address in two 32-bit halves there, which LLVM cannot read back as one
  constant word, so checks on it stop folding, and the module initializer is never
  optimized, so its copies stay copies. Kept slots are a poor proxy; measure the output.
- [ ] **The overload probe is a second semantic analysis.** It types only the bodies that
  may come by a value of a candidate's owner type (647 of a 4,979-body client, 38 of which
  resolve something) and builds no compile-effect summary (nor, without regions, a region
  summary): about 1.2 s, against 3.2 s before. What is left is typing those bodies and
  every global. Typing candidate calls inside the main analysis instead was weighed and
  dropped: the analyzer reads other bodies syntactically (fresh values, borrow sources,
  region retention, no-escape inference), and in one pass those would see `a + b` where
  the rewritten program has `a.plus__N(b)`, with no cheap way to notice.
- [ ] **String helpers carry a root frame.** With automatic pressure, any function with an
  instruction that may allocate collects and roots its values, and so do its callers.
  String inspection counts (`string.get`, `index.get`, `==`/`!=`: a rope may be
  flattened), so a byte-comparing helper like `hasPrefix(text, prefix)` gets a 4-slot
  frame and a pressure check; called on every type normalization it cost the compiler 7 G
  instructions. Excluding `==`/`!=` of two native scalars changes almost nothing (306 of
  4,053 client functions collect either way; 1,745 → 1,737 in a server): what decides is
  the possible rope flattening, a collection-placement policy.
- [ ] **A collection still visits every allocation.** It builds the page bitmaps from the
  whole registry and sweeps it all, garbage and live alike, freeing garbage one block at a
  time. Of that build's active time the marker is about 8%, free() 4% and the page release
  free() triggers (madvise) 3%. A collector whose cost followed what is live (pages with
  mark bits, or generations) would make frequent collections cheap. Tried and dropped:
  size-class free lists inside the runtime (35 G fewer instructions, no fewer cycles, and a
  2.9 GB peak from per-class fragmentation). A capped version of it was weighed and dropped too: on
  a game client's dev build the madvise of emptied nano blocks after the sweep is about 2.7%
  of samples and the page faults that follow stay low (~3.6k), so 2.7% is the most any
  retention could win, while the nano allocator already holds 450-550 MB above the live heap
  (partly used 16 KB blocks; 1.1-1.4 GB peak at ~665 MB live) that retained objects would
  only pin further. Without the nano zone (`MallocNanoZone=0`) that peak is 0.94 GB, but
  the compiler runs 17% more instructions and 15% more cycles. Sampled over a game client's dev build's front
  end, the collector is about 13% of samples, the page directory's build alone about 7%:
  each collection builds it afresh from the whole registry. Keeping it across collections
  (the sweep clears the bits of what it frees; a collection adds only what was registered
  since) would save part of that 7%, against the risk of a directory out of step with the
  heap.
  Measured again at `49e37da` with a collection trace (one line per collection): a game
  client's dev build collects 15 times and its release build 17 (two explicit), live
  before 269-651 MB, kept 13-505 MB. Over the dev build the page directory's builds take
  about 1.2 s (each walks the whole registry, garbage included, up to 7.8 M slots, and
  callocs a 512-byte bitmap per page), the sweeps about 1.3 s (up to 5.6 M `free` calls
  each; the nano allocator's madvise on emptied blocks is under them, not `8a1e627`'s
  pressure relief, which is about 6 ms) and marking and tracing 0.6 s. A larger collection
  step does not help: every garbage object is freed once whatever the step (256 → 512 MiB:
  instructions unchanged, peak +90 MB). Candidates: the directory kept across collections
  (above), and freeing a sweep's garbage in batches (Darwin's `malloc_zone_batch_free`)
  instead of one `free` each.
- [ ] **Name lookups in lowering.** Sampled over a game client's dev build at `d39b14d`,
  `BootstrapFunctionDeclarationIndex.find` and the name hash under it are about 450 ms
  together, about 1% of the compiler's samples (an index lookup each time, but many of
  them), and `bootstrapIrRuntimeOperationDeclaration` about 100 ms: it compares an
  instruction's opcode with some 80 strings, one after another and all of them, for every
  lowered instruction (`bootstrapCollectLoweredInstructionTargets`). The callers of `find`
  are not in the sample: lowering's recursion is deeper than its stacks. Next: count the
  lookups per call site, then remember a callee's declaration where the same name is
  looked up again (`lowerFunctionResultType`, `lowerFunctionType`,
  `lowerGlobalFunctionType` each look it up afresh), and dispatch the opcode table on the
  opcode's first byte. Worth perhaps 0.3-0.6% of a dev build; not measurable on a loaded
  machine.

## Not checked

Linux-only linking and running (abla-graphics, abla-doom, the X11/Wayland
tests), the ESP32 and Android cross builds (their toolchains aren't installed),
and tests that need network services.
