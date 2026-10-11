# TODO

Known failures found by compiling every `abla-*` package against ablac `1a90db5`
(2026-10-08). Every item below fails with the previous compiler (`f49012f`) too: none
is a regression of `1a90db5`.

## Compiler and stdlib

- [ ] **`utcIso8601Parse` fails IR verification.** `stdlib/abla/date/entry.ab`
  `utcIso8601Parse` (line ~173) breaks an LLVM function check
  (`E_IR_FUNCTION_VERIFICATION`). Any program that imports `abla/date` and reaches it
  fails to build. Seen in most abla-graphics targets and in abla-doom's `src/main.ab`;
  both pass the semantic pass first.
  Not reproducible at `baccfbd` on macOS: abla-doom `src/main.ab`, abla-graphics
  `examples/buffer-pool/main.ab` and a program calling `utcIso8601Parse` directly
  pass the IR pass (with and without `--fast`) and stop only at the link (`-lvulkan`
  isn't installed). The failing logs probably came from another compiler build or
  stdlib tree; recheck on Linux before closing.
- [x] **`ablaRuntimePointerFromAddress` is missing for the Android and embedded
  targets.** Fixed in `314c080`: a non-hosted target that links a C library
  (`libcFree` false: Android, ESP-IDF) gets the runtime and the libc platform again
  (`bootstrapNativeBuildWithEmitterStateCache`); since `ca65e9a` only hosted and Wasm
  targets got them. Libc-free targets stay runtime-neutral.
  - abla-mobile's Android drivers and abla-food's `android_build.ab` now build both
    objects (arm64, x86_64) and the packaging files; they stop at Gradle/the NDK (not
    installed here). Package-side: abla-mobile's `runtime/native/CMakeLists.txt` still
    compiles ablac's `runtime/abla_runtime.c` (removed in `93ce196`) and its C platform
    layer implements that old C runtime ABI. The objects now carry the Abla runtime
    (it calls `malloc`/`free`/`pthread_*`/`write`/`abort`; emulated TLS on Android),
    so that native layer needs updating.
  - abla-embedded: the ESP32-C6 (RISC-V) drivers build their objects; the Xtensa
    drivers pass the compiler and stop at `llc` (no ESP LLVM with the Xtensa target
    here). Untested at the ESP-IDF link: the runtime's thread-local is general-dynamic
    TLS (`0dcbd67`), so an object that reaches the runtime references
    `__tls_get_addr`, which ESP-IDF may not provide; a static-only target could use
    local-exec.
- [x] **Packages of packages don't resolve.** Fixed in `4e5fa1a`
  (`bootstrapResolvePackageImport`): in a dependency's own copy (prepared
  `.abla/packages/<dep>/source` or vendored `vendor/<dep>`), the dependency's own
  `abla.lock` no longer ends the search; it continues to the enclosing project.
  abla-compare's `servers/abla/main.ab`, `diagnostics/http_pipeline_memory.ab` and
  `--project .` build offline.
- [x] **xtensa intrinsics on the host target.** The crash is fixed in `d32ab95`: after a
  lowering error the backend skips the passes, verifier and printer over the partial
  module, so `dispatcher.ab` and `interrupt.ab` report
  `E_LLVM_INSTRUCTION_UNSUPPORTED` and exit 1 instead of 139. Building them still needs
  an Xtensa target, and `radio-mac-registers/build.ab` an `llc` with it.
- [x] **`val x = #exportFunction(...)` exported nothing.** Found with the Android
  objects: since `9ba9ab9` such a value wasn't a reachability root, so neither the
  export nor the function reached LLVM (`exportCheckedFunction` was unaffected).
  abla-mobile's apps and `tools/test-android-extension.sh` use this form. Fixed in
  `087b3b6` (`bootstrapSourceInitializerWritesGlobal`).
- [ ] **`abla/platform/host`'s `extern:"host"` functions have no native
  implementation.** They lived in the C host runtime removed in `93ce196`; only the
  compile-time evaluator implements a few. A native program that calls one fails at
  the link with an undefined `ablaHost*` symbol. Either implement them on the public
  modules or reject such calls in a native build with a diagnostic naming the public
  replacement (`abla/fs`, `abla/io`, `abla/process/*`).
- [ ] **`tools/test-wasm-mvc-extension.sh` checks a stale symbol.** It greps
  `llvm-readobj --symbols` for `abla_mvc_revision`, but a linked module's symbol table
  lists name-section names (`app.revision`); the export itself is present. Check the
  export section instead. (Before `087b3b6` the build failed earlier.)
- [ ] **An operator in a parameter default is not rewritten.** `fun f(b: N = N(1) + N(2))`
  with `operator fun N.plus` fails with `arithmetic.type`: the probe resolves the default's
  `+`, but `bootstrapOverloadRewriteDeclaration` (`overload.ab`) rewrites only the body,
  not `parameterDefaults` (a method's defaults likewise).
- [ ] **`tools/test-affine-move.sh` is stale.** It is in neither the Makefile nor
  `abla-tests.json`, and fails on master before its fixtures: one of its native builds
  stops at the link (`_abla_array_get` undefined). Its CFG-ownership fixtures still expect
  `ir.verification:`; borrow conflicts are reported as `E_BORROW_CONFLICT` now (including
  the three `invalid-compile-*-active-mutation` ones, named since a compile fun's validation
  failures are). Update it as `test-borrow-lifetimes.sh` was, then run it in the suite.

## Packages

Package-side work (not changed from ablac):

- [ ] **abla-testrunner: `ablaHostIsMacOS` is ambiguous.** The package and the
  stdlib both define it, so `tests/parser_test.ab` and `tests/integration_test.ab`
  fail with `E_IMPORT_UNQUALIFIED_AMBIGUOUS` and `symbol.duplicate`. The two
  declarations are identical. Fix in `src/testrunner.ab`: replace
  `noescape extern:"intrinsic" fun ablaHostIsMacOS(): bool` with
  `import "abla/platform/host"`.
- [ ] **abla-testrunner: `tests/fixture.ab` fails to link** (`_ablaHostArgument`,
  `_ablaHostSleep`, `_ablaHostWriteStdout` undefined). Cause: the `abla/platform/host`
  item above; the package moved `src/` to the public APIs in `54f3fac` but not
  `tests/`, and `parser_test.ab`/`integration_test.ab` fail the same way once the
  ambiguity is fixed. Fix: in the three test files import the public modules instead
  of `abla/platform/host` and use `processArgument(i)` (`abla/process/arguments`),
  `sleep(ms)` and `monotonicMilliseconds()` (`abla/process/time`), `print(text)`
  (`abla/io`), `currentDirectory().text` and `path(p).readText()` (`abla/fs`).
  Checked on a scratch copy: with this and the item above, `make check` passes.

## Compile time and memory

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
  Release (LTO) and native builds still pass LLVM text between their steps.
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
- [ ] **LLVM 23 (evaluated 2026-10-11, not adopted).** LLVM 23.1.3 (macOS arm64 release) against 21,
  with `a223373` built against each. Instructions retired by the compiler and every LLVM tool and
  wasm-opt, on a game's builds (one round; walls were inflated by external load):

  | Build | LLVM 21 | LLVM 23 | Peak (tree RSS) |
  |---|---|---|---|
  | release Wasm client | 1,260 G | 1,000 G (−21%) | 1.77 → 1.64 GB |
  | development Wasm client | 269 G | 228 G (−15%) | 2.06 → 2.11 GB (compiler) |
  | release native server | 345 G | 248 G (−28%) | 0.99 → 0.96 GB |
  | release simulation module | 93 G | 77 G (−18%) | 0.52 → 0.53 GB |

  Per tool on the release client: opt −29%, clang's O2 pre-link −32%, wasm-ld −40%, wasm-opt
  −4%. Sizes: client −1.67% after wasm-opt, simulation module +0.31%, server −0.48%,
  development client +0.05%. Runtime unchanged: the simulation's hashes match, natively and in
  Wasm, and its instructions per run are within 0.2% (native and under node). The initializer
  chunks and 4 LTO partitions still pay under 23 (wasm-ld −26% instructions; 4 partitions −32%
  wall, lower peak). Under 23 the compiler is a fixed point (`.ll` and binary).

  Before a switch:
  - opt and llc no longer take `--threads=1` (`src/toolchain.ab` 316, 325, 497, 533, 704, 727).
    The linkers still take it.
  - `default<Oz>` is gone ("use O2 with the minsize attribute"): the microcontroller pipeline,
    `src/toolchain.ab:513`. `test-scalar-default-unboxing` fails on it.
  - The compiler and the tools must move together. The compiler reads opt's bitcode back in
    process (`LLVMParseIRInContext`, `src/toolchain.ab` 453, 778), so a libLLVM 21 compiler cannot
    read 23's bitcode, and 23's text (`target_mem`) does not parse in 21's opt.
  - These hardcode `llvm@21`: `tools/test-self-hosted.sh`, `tools/run-limited-compiler.sh`,
    `tools/macos-clang.sh`, `tools/test-pure-self-rebuild.sh`, `tools/prepare-macos-link-stubs.sh`.

  Installing it: Homebrew had no `llvm@23` yet (its `llvm` was 22.1.8). The release tarball has
  no shared libLLVM, only static archives of LTO bitcode; a `libLLVM.dylib` linked from them
  (with Polly and libedit, `-all_load`) took 6.4 minutes. So the options are Homebrew's `llvm@23`
  once it ships, or a self-built libLLVM at a fixed path. A Linux image would take apt.llvm.org's
  `llvm-23` and `lld-23` (with `libLLVM.so`).
  Not measured: walls and frame times on a quiet machine, a game's HUD frame timing, the full
  suite with scripts that know 23, and a Linux image build.

## Not checked

Linux-only linking and running (abla-graphics, abla-doom, the X11/Wayland
tests), the ESP32 and Android cross builds (their toolchains aren't installed),
and tests that need network services.
