# Compiler performance contract

Correctness and full self-hosted conformance come first. Once the pure-Abla
compiler accepts the complete language surface, optimization proceeds against
reproducible measurements rather than ad-hoc timings.

Run the current end-to-end rebuild benchmark with:

```sh
make benchmark
```

The benchmark reports complete source-to-executable time and output size.
For phase diagnosis, measure `ablac --emit-llvm` separately from the native
build; the former covers parsing, semantic analysis, lowering, and LLVM text
emission, while the latter additionally includes LLVM optimization, parallel
object emission, and linking.

Compare two compilers with `tools/bench-compare.py` (compile instructions, stripped size,
run cycles and instructions, on `tests/benchmarks`).

## Faster builds, smaller and faster programs, ten times faster tests (2026-11-03)

Against master `753d1d10` (v0.2.32 plus the previous round), everything below and in the
next two sections measured together, `tools/bench-compare.py` (13 programs, rounds of 5)
on a machine loaded by other builds (load average around 40):

| Metric (geometric mean) | Change |
|---|---:|
| Release build, instructions | -21.0% |
| Release build, cycles (all processes) | -23.3% |
| Release build, wall clock (median of 5, alternating; before the last three runtime changes) | -21.7% (-12% to -31% each) |
| Stripped size | -9.6% (fib -13.5%, json-megabyte -8.9%) |
| Run instructions (11 programs) | -11.3% (trees -37%, websocket-codec -24%, matrix -15%, nbody -13%) |
| Run cycles (same, median of 5) | -5.8% |
| `abla-compare` server, user instructions per request (9 workloads) | -3.4%, every workload lower |
| `abla-compare` server, stripped size | -9.7% (290,000 to 261,760 bytes) |
| `ablac test` of abla-qr (9 files, `--no-cache`) | 316 s to 51 s; 7.06 T to 0.50 T instructions |
| `ablac test` of abla-pdf (8 files, `--no-cache`) | 323 s to 67 s; 7.12 T to 0.83 T instructions |
| abla-embedded's Xtensa `tests/package-import.ab`, compiler peak | 3.15 GB (v0.2.32) to 2.94 GB |

Cycles and times move by up to 20% with where code lands and with the load: fib runs the
same instructions and showed +5 to +9% cycles in these runs; instructions are the measure.

What changed (the frontend, the runtime's string paths and its startup are the next
sections, by the agents who did them):

- **A trimmed O2 pipeline.** A Linux release executable's module goes through LLVM 23's
  `default<O2>,globaldce` as `opt -print-pipeline-passes` writes it, without 21 passes
  (`BOOTSTRAP_HOST_RELEASE_PASSES`): each pass was dropped in turn over the benchmarks'
  kept IR, twice over, then each dropped one put back in turn over the server's. opt and
  llc do 14.4% less work; programs are 0.3% smaller and run 0.4% fewer instructions, the
  server 1.6% fewer a request. Constraint elimination looked free on the benchmarks and
  cost the server's byte loops 13% (body-16k): a pipeline change needs a server beside the
  benchmarks. An LLVM that can't parse the list gets `default<O2>,globaldce`.
- **A large module's code generation runs in parallel.** Past 20,000 instructions after
  O2, the module is cut into four parts (as a development build's units are) and llc runs
  on them at once, then `ld.lld -r` joins them: json-megabyte's llc 2.7 s to 1.6 s, 64
  bytes larger. The count is fixed so the executable is the same on every machine.
- **The link runs ld.lld without clang.** The first link asks clang (`-###`) for its
  command and keeps it in the cache directory under its arguments and the environment
  clang and its Nix wrapper read; later links run ld.lld directly (60 ms of a small
  program's 330 ms was the wrapper's shell script and clang's start). The kept command
  leaves out crti, crtn, crtbegin and crtend, which an Abla program doesn't use: fib went
  from 15,096 to 13,920 bytes. A failing direct link, or `ABLA_LINK_DIRECT=0`, goes
  through clang.
- **An array's slow paths only read memory.** `ArrayGetWordOther` and `ArrayGetOther`
  carry LLVM's `memory(read, …)`: they read and return, or trap or panic and never
  return. LLVM then keeps a loop's invariant loads out of it: nbody 13% fewer
  instructions, matrix 15%, dispatch 7%.
- **The free lists keep what they serve.** They hold up to 128 MB (the compiler 32 MB,
  `memorySetFreeBlockLimit`), but between collections only a quarter more than they served
  in the last cycle, at least 32 MB: trees runs 35% fewer instructions, json-megabyte 6%,
  at the same peak (json-megabyte 206 to 212 MB; a fixed 128 MB took it to 322 MB). Limits
  by block size did worse.
- **Smaller fixed costs.** A root frame's pop that finds another frame on top (an
  export's global roots) is out of line and cold instead of inlined at every return;
  `ByteBuffer.appendByteValue` writes its byte into the stage (websocket-codec 22% fewer
  instructions); the compiler's first collection waits for 128 MB, as
  `memorySetCollectionGrowth` now also moves the first threshold (it had collected at
  32 MB in the middle of a small build); small builds skip the collection after
  emission.
- **`ablac test` builds with `--o1`.** Test programs were `--fast` builds (no inlining,
  O0 code generation), and a suite's time is its tests running: abla-qr's slowest test ran
  2,975 G instructions, 276 G at `--o1`, for 17 G more to build. `--fast` keeps the old
  profile.

Measured and dropped: O3 (no faster, 3% dearer); lower inline thresholds (150 to 200:
programs larger and slower); llc tail-duplication, branch-folding and jump-table flags
(fib 21% slower); no loop alignment (1.3% smaller, kept for speed); `memcmp` for string
equality (freestanding AArch64 programs have no `bcmp`); limits on the free lists by
block size; reading a map's slots directly (0.4%: maps waits on cache misses, not
instructions); "PIC/PIE Level" module flags (0.1% smaller); `minsize` on the C `main`
wrapper as it was: the program's main is inlined into it, and dispatch's loop divided by
7 with `idiv` (10% more cycles), so the wrapper now calls main without inlining it.

## Smaller native startup and collector (2026-11-03)

The size work on top of `compiler-perf-3` (`ec2fca9b`, plus the global-root
initialization fix `0601faee`) reaches the 10% stripped-size target:

| Metric (geometric mean) | Against master `753d1d10` | Against `compiler-perf-3` |
|---|---:|---:|
| Release build instructions, 13 programs | -20.2% | -0.4% |
| Stripped executable size, 13 programs | -11.1% | -4.8% |
| Run instructions, 11 programs | -13.1% | -2.3% |
| Server instructions per request, 9 workloads | -4.12% | — |

These are `tools/bench-compare.py` results with one build and two run rounds.
The incremental control is `/home/andre/perfbase/ablac-c9.bin` with an archived
parent sysroot. All eleven run benchmarks use fewer instructions or remain
unchanged against master. Incrementally, strings uses 0.6% more instructions
and maps 0.5% more; both remain below master (5.7% and 1.8%, respectively).
Dispatch uses 19.6% fewer instructions than the parent. Cycles on the loaded
machine do not establish a timing improvement.

Fib falls from 14,392 to 12,240 stripped bytes, trees from 16,968 to 14,560,
and strings from 20,456 to 17,408. The `abla-compare` server falls from 290,000
to 259,016 bytes (-10.7%). Its request measurement uses 40,000 requests per
round, three rounds per workload, a pinned server and a fresh master control;
all nine workloads use fewer instructions per request (2.8% to 6.1%).

The collector shares `MarkValue`'s tagged-value dispatch between its root and
layout walkers, and shares the heap-sort sift between construction and
extraction. Explicit `@noinline` boundaries remove repeated code without
changing tracing or sorting. The large-range stress fixture retains sixteen
interior views into allocations above 32 KiB, drops their rope parents and
collects after every append. Using libc `qsort` was rejected: it was slightly
smaller but added an unavailable symbol to the freestanding AArch64 fixtures.
An alternative sift that moves children instead of swapping did not improve
size, so the existing algorithm remains.

Internal anonymous TLS in Linux executables uses initial-exec; externally
named TLS and library/object outputs retain general-dynamic. On release
Linux x86-64, fatal runtime writes and process exits reuse libc's existing
`syscall` import. The stack handler likewise uses `prlimit64` and re-raises
on its own thread with `getpid`/`gettid`/`tgkill`. It retains libc `sigaction`
for signal dispositions and its restorer. Debug reporting and other targets
retain their existing wrappers. Fib's libc imports fall from eighteen to ten.

An executable without exports or a reference to a recovery setter has no
recovery frame to enter. Its `HostRecover` becomes a zero result, removing the
unused error-buffer copy and `_longjmp` path. Checked exports, library/object
outputs and explicit recovery calls or address references retain recovery.
Finally, only the generated C entry wrapper and stack-fault handler use
`minsize` as well as `optsize`; the Abla main body keeps its ordinary policy.
This saves fixed startup code without applying minimum-size optimization to
the program's hot functions. Applying `minsize` to pressure collection instead
saved only 64 bytes and increased trees' instructions by 0.4%, so was dropped.

`make test` passes all 256 commands in 190 seconds (16 jobs, restricted to
P-core logical CPUs `0-11,14,15`). This includes `ablac test` and bundled
tests, native/debug/JIT runtime failures, checked exports, TLS faults,
freestanding cross-targets and collection stress. Two compiler stages build
successfully and emit byte-identical json-readers LLVM IR. An earlier
mixed-core suite passed 255 commands but failed the frontend CPU-time ratio
at 4.51/1.45 seconds; the same binary on CPU 8 passed at 2.65/1.16 seconds,
and the final full pinned suite passes that check too. Preserve an 8 MiB soft
stack for the runtime test parent; the compiler launcher raises its own stack.
The separate full compiler-under-GC-stress self-build remains pending with
the global-root fix's author; passing collection tests is not that result.

## A string slice needs no collection safe point (2026-11-02)

`string.slice` returns a view. Like reading a character or comparing strings,
it may first flatten a rope, whose copy remains reachable from the rope. The
runtime does not collect while doing that. It therefore no longer counts as
an allocating operation in `bootstrapLlvmInstructionMayAllocate`: a function
that only slices does not need an entry pressure check or a root frame, and
its callers need not root values solely across that call. Real allocations,
callbacks and explicit collection retain their safe points.

Together with the string-reader changes below, against master `753d1d10`:

| Metric (geometric mean) | Change |
|---|---:|
| Release build, instructions (13 programs) | -2.5% |
| Stripped size (13 programs) | -2.4% |
| Run instructions (11 programs) | -1.2% |
| `abla-compare` server, user instructions per request (9 workloads) | -2.58% |
| Server stripped size | -7.4% (290,000 to 268,608 bytes) |

This screen used one build and two run rounds per benchmark; the compiler was
built with master's compiler and the changed runtime. Every run benchmark and
all nine server workloads improve or remain unchanged in instructions. In
json-readers' unoptimized IR, root pushes fall from 62 to 58, entry pressure
checks from 45 to 37 and loop pressure checks from 23 to 22. The combined
changes still do not reach the requested 10% geomean size reduction.

GC stress, collection modes, collection growth and string retention pass.
The new stress fixture keeps interior slices of flat strings and flattened
ropes after their parents are gone, with explicit collection between appends.
It also indexes and compares rope temporaries with no named owner; this passes
under `ABLA_GC_STRESS=1`. The generator-step fixture now really allocates a decorated word: its former
slice per word was a view, so its assertion that an allocating step roots
would otherwise test the wrong case. With that fixture and checksum corrected,
`make test` passes all 256 commands in a clean run (214 seconds, 16 jobs).
A compiler self-build succeeds, and its json-readers LLVM text is byte-identical
to that emitted by the previous stage of the compiler.

The separate compiler-GC-stress check did not pass at the time: master and the
candidate crashed alike in `__ablaRuntimeArrayGetOther` called by
`bootstrapRewriteModuleSource` (`0x736c61626f`, `SEGV_MAPERR`). It was a
pre-existing bug, since fixed ("Globals are collector roots before their
initializers run"): a module global was registered as a root only after the
initializers, and a collection inside one freed a global's array.

## String readers pass words into shared paths (2026-11-02)

Against master `753d1d10`, using its compiler with the two sysroots,
`tools/bench-compare.py` (13 programs, two builds and three run rounds):

| Metric (geometric mean) | Change |
|---|---:|
| Release build, instructions | -1.1% |
| Stripped size | -2.0% |
| Run instructions (11 programs) | -1.0% |
| `abla-compare` server, user instructions per request (9 workloads) | -0.67% |
| `abla-compare` server, stripped size | -4.1% (290,000 to 278,048 bytes) |

The size improvement alone falls short of the requested 10%. json-readers is
5.7% smaller and json-megabyte 4.3%; their run instructions fall 0.8% and 6.0%.
Every run benchmark is unchanged or improved in instructions. Cycles move with
the loaded machine; they are not the acceptance measure here.

- **A rope's slow data reader takes only its rope pointer.** The inline
  `StringData` used to materialize a 24-byte boxed string for the rare
  `StringDataSlow` call. That callee now reconstructs the string from its rope
  pointer, keeping those copies out of every caller.
- **String equality passes the strings' four words.** `StringBytesEqual` resolves
  their data itself, without two boxed argument copies at every inline equality
  check. Length and empty-string checks stay in the caller.
- **A safe point tests the byte threshold before the thread-local region.**
  `MemoryPressure` avoids resolving the region while below the threshold. The
  collection checks and the GC-stress loop cadence are unchanged.

The server was pinned to P-core 8, with 40,000 requests and three rounds per
workload, checking exact responses. Its parameters workload showed +0.21% in the
nine-workload run; a separate 100,000-request, five-round comparison showed -1.13%.
The other eight workloads improved in the first run. Runtime-only `make test`
used master's payload through the normal launcher: 254 commands passed initially;
self-hosted and killed-build passed on rerun (all 256 commands, including the
self-hosted driver's 89 cases). The test parent needs an 8 MiB **soft** stack for
its 128 MiB-limited threaded programs; the compiler launcher still sets its own
128 MiB stack, with the hard limit retained. Killed-build's short-lived temporary
can be missed under load; its isolated rerun exercised the kill successfully.

Screened and dropped:

- `@noinline` on float bignum helpers: nbody/matrix only 0.9/1.4% smaller,
  nbody 0.3% more run instructions. Formatting the float's digits through one
  ByteBuffer grew them 11/13% and nbody ran 2.7% more instructions.
- Out-of-line `MemoryPressure` and `MemoryPressureLoop`: six programs 1.5%
  smaller, 1.0% more run instructions.
- One unsigned bounds comparison instead of signed lower/upper checks: 0.1%
  smaller over 13, but dispatch ran 4.8% more instructions.
- A shorter `StringLengthValue` expression: a further size saving, but strings
  and maps ran 0.4/0.8% more instructions.
- Global `optsize` only during optimization, stripped before llc (to retain
  loop alignment): four programs 2.6% smaller, nbody/readers/megabyte ran
  2.7/3.7/3.7% more instructions. Targeting float functions also regressed nbody.
- LLVM IR outlining after O2: four programs 1.3% larger, 44.8% more run
  instructions. `global-merge-func,mergefunc` gave no size improvement.

## Builds without text, smaller runtime paths, cold slow paths (2026-11-02)

Against the v0.2.31 compiler (master at `e66208b4`, before this work and before the build
transaction's removal), `tools/bench-compare.py`'s 13 programs and the same programs timed by
wall clock, all changes below measured together:

| Metric (geometric mean) | Change |
|---|---:|
| Release build, wall clock (median of 5, alternating) | -26.3% (-10% to -40% each); -15.6% against 58596b4d, which had removed the build transaction's fsyncs |
| Release build, instructions | -18.4% |
| Release build, cycles | -14.1% |
| Stripped size | -11.4% |
| Run instructions (11 programs) | -16.1% |
| Run cycles (same, median of 7 turns) | -16.0% |
| Run time (same) | -14.3% |
| `abla-compare` server, user instructions per request (9 workloads) | -2.1% |
| `abla-compare` server, user cycles per request (same, median of 3) | -3.0%, json-nested +0.1% |
| `abla-compare` server, stripped size | -1.6% |
| `ablac test` of abla-qr (9 files, `--no-cache`) | -33.5% (226 s to 150 s) |
| `ablac test` of abla-pdf (8 files, `--no-cache`) | -32.4% (248 s to 167 s) |

What changed:

- **A Linux release executable is optimized in the compiler.** The module the backend built is
  internalized, made `nounwind` and run through `default<O2>,globaldce` in process
  (`bootstrapOptimizeHeldWholeProgram`), then written as bitcode for `llc`. Before, it was
  rendered as text, written, and parsed again by `opt`: 7% of `opt`'s instructions and about a
  sixth of a mid-sized build with its startup. The text is still written for the cache, or with
  `ABLA_KEEP_LLVM_TEXT=1`. The object differs from `opt`'s only where the order of a value's
  uses steers code generation (json-readers: 7 of 143,405 bytes of text). `llc` stays a tool:
  its `--align-loops` and section flags are code generation options the C API can't set.
- **A build's own files are written and renamed without `fsync`.** A release build without the
  cache did 19 fsyncs (111 ms of json-readers' 2.1 s, a quarter of an empty program's build);
  now none. The cache's entries keep theirs.
- **A source is lexed once per build.** The discovery parse, the strict-imports check (twice) and
  the staged parse each lexed every module; they now share the tokens (`bootstrapLexShared`),
  from a graph's first load to the end of its parse: 3.5% of a frontend.
- **Lowering drops what nothing reads** (`bootstrapIrWithoutDeadValues`, after verification):
  unused constants and local loads, and the join temporaries of an `if` without `else` used
  as a statement. A fifth of json-readers' value slots were written and never read; LLVM
  removed them again after carrying them through most of its passes.
- **A string template of three parts or more is written once** (`__ablaRuntimeStringConcat4`,
  four parts at a time) where each part allocated and copied the text so far: strings runs 42%
  fewer instructions, json-megabyte 12%. The runtime's own templates (its panic messages) keep
  the old chain, so a program without such a template has no extra kilobyte.
- **The runtime's rare paths stay small.** Rope flattening, string copying, an array's growth and
  boxing, Base64 and joined chunks allocate through one out-of-line allocator
  (`__ablaRuntimeAllocateOutOfLine`) instead of each inlining it (most of a kilobyte each);
  `StringDataSlow` and `CopyString` are `@noinline`; the collector is compiled `optsize`
  (`bootstrapLlvmRuntimeOptimizedForSize`, 2% smaller, trees 0.3% fewer instructions); the
  collector's two environment lookups read the literal's own bytes.
- **An array's slow paths are cold** (`bootstrapLlvmRuntimeColdPath`). A loop's call to one
  ended its fast path, and as an ordinary call it made LLVM keep the loop's values in memory
  for the whole loop: nbody 20.5% fewer instructions, matrix 18%.
- **A call through a value that can only be one function without captures** (a lambda in a
  `val`) calls that function's wrapper, which LLVM inlines, instead of the dispatcher's copy,
  switch and box: dispatch runs 52% fewer instructions and is 20% smaller.
- **A native development build writes a boxed int or bool in place** of calling `abla_i64` and
  `abla_bool`, two calls each in a build that inlines nothing (39% of an integer-heavy test's
  run). A release build keeps the calls: there the stores cost `opt` 3% more for nothing.

Small programs gain most in size (fib 19%, the HTTP servers 2 to 3%): what shrank is mostly the
runtime every program carries. The `abla-compare` server builds only a few percent faster: its
frontend is most of its build. sieve and websocket-codec run the same instructions and showed
+10% time in one run; their cycles move that much with where the code lands (see the TODO item).

Tried and dropped on 2026-11-02:

- Whole-program O2 for the compiler itself: its frontend ran 3% more instructions, no faster.
- Stripping lifetime markers: `opt` 2% cheaper, `llc` 3% dearer, 3.7% larger.
- `llvm.memcpy` for value copies: `opt` 13% cheaper, but dispatch ran 15% more instructions
  and programs grew 0.9%. `llvm.memset` for zeroed slots: no cheaper, larger.
- Local-exec TLS for an executable's root frames: neutral (0.2% smaller, 0.4% fewer
  instructions, cycles within noise).
- `minsize` for the collector: 0.4% smaller than `optsize`, trees 1.2% more instructions.
  `optsize` or `cold` for more runtime paths (allocation, collection, ropes, panics): up to
  2.8% larger, json-megabyte 10% slower with `optsize` rope paths.
- Hashing a new map key once instead of twice: maps 0.1% fewer instructions, 1.7% larger.
- Boxed values written in place in release builds too: `opt` 3% dearer, 0.4% larger.

## One optimization pass for a Linux executable (2026-11-01)

A release Linux executable now goes through one `opt` (`internalize`, `forceattrs`, O2 at
inline threshold 225) and one `llc` (loops aligned to 32 bytes), with no LTO link. Against v0.2.29,
14 programs including the compiler, all changes below measured together:

| Metric (geometric mean) | Change |
|---|---:|
| Release build, instructions | -41.9% |
| Release build, cycles | -34% to -36%, three runs |
| Stripped size | -10.1% |
| Run instructions (11 programs) | -22.2% |
| Run cycles (11 programs, median of 15 turns) | -18.2%, both runs |
| Run time (same) | -16.3% and -16.0% |
| `abla-compare` server, user instructions per request (8 workloads) | -12.0% |
| `abla-compare` server, user cycles per request (same, median of 11) | -11.3% |
| `abla-compare` server, CPU per request, user and kernel (same, median of 7) | -7.5% |
| `abla-compare` server, throughput (same, median of 5) | +1.4% |
| `abla-compare` server, stripped size | -3.0% |
| `abla-compare` server, release build time | -28% (5.3 s to 3.8 s) |

These averages favour small programs: building the compiler itself takes 10.5% fewer instructions
and it comes out 8.0% smaller. Median run time improves on all 11 programs, most in allocation,
strings and calls through function values; nbody, matrix and fib gain 1 to 4%. An HTTP server
gains less, and its throughput barely moves. Most of a small request is its `read` and `sendto` in
the kernel, which no compiled code changes (plaintext 0.4 us of user time beside 1.5 us of kernel;
json-items-128 11.0 and 2.8). The event loop now reads the clock once a pass rather than once a
request: a real syscall and a malloc each time. headers-32's user instructions per request are unchanged (-0.4%). Beside the pipeline: freed blocks
of up to 512 bytes go on lists by size for the next allocation (capped since, below); a function's rooted values share one
array, zeroed once and named by one word of its root table; hot runtime readers are `@inline`; map
slots hold hash bits.

The benchmarks in `tests/benchmarks` didn't show what a low threshold costs a server: `abla-compare`
ran 13% more instructions per request at 100 while they looked better. Keep a server in the
comparison when changing inlining. What moved it, for a program that's smaller as well:

- Native programs inline field stores and object and array creation, with allocation left out of
  line: a call site knows the field's kind and the class, so those checks fold (-9% on the server's
  instructions, server 5.6% smaller). Wasm and MCUs keep the calls.
- `@inline` on the ordering operators and map reads: they fold when the operands' types are known
  (json-items-128 -7%, maps -15% cycles).
- `--align-loops=32`: fib's identical code ran 11% slower at another address. It now gains 4%, for
  2% of size.

Tried and dropped: threshold 300 (size only -8.6%, instructions 2% better); a second O2 round (no
gain); forcing small functions inline (up to 47% bigger, no gain); `@inline` on array set and append
or on stdlib text wrappers (no gain for the size); scanning for a byte by words (HTTP lines are too
short). `-force-attribute=optsize` makes the server 12% smaller and its cycles about 6 points worse,
and as late as code generation about 8 points (loop alignment goes with it). The machine
outliner and `--icf=all` are no smaller. At low thresholds the runtime's `@inline`s matter: at 100
without them, nbody ran 4x slower.

### The free lists, capped (2026-11-02)

Cut from 1 MB chunks and kept for good, the lists held each size's high-water mark through a
compiler's phases. An Xtensa build of abla-embedded's `tests/package-import.ab` peaked at 3.74 GB
against 3.04 GB before, past `build/ablac`'s 4 GB address-space limit, and the compiler's own
`--emit-llvm` at 1.67 GB against 1.25 to 1.40. Blocks on a list serve only their size, so neither
malloc's larger requests nor LLVM can use them. Now each small block is malloc'ed at its own size
(lists 8 bytes apart), and the lists hold at most 32 MB between them. Those builds peak at 3.04 GB
and 1.25 to 1.40 GB, and `tools/test-compiler-memory-peak.sh` holds the second to its record.

| Against the uncapped lists, `tools/bench-compare.py` | Change |
|---|---:|
| Release build, instructions | +3.3% |
| Run instructions (11 programs) | +18.6% |
| Median run time (same) | +10.8% |
| trees, strings | +39%, +39% |
| websocket-codec, json-readers, json-megabyte, maps | +16%, +8%, +7.5%, +7% |

Against no lists at all, the capped ones save 3.7% of build instructions and 3 to 5% of run time on
trees, strings and maps. Tried and dropped, by peak on package-import: 16-byte classes, malloc'ed
(3.42 GB, an extra 8 to 16 bytes on tens of millions of blocks); a 256 MB cap (3.53 to 3.57 GB);
trimming each list at a collection to what its size handed out since the last (3.74 GB, as most
blocks are freed between collections, and none run inside a region); chunks released once
empty, aligned by `aligned_alloc` (4.7 GB) or inside a 2 MB malloc (3.99 GB; 3.44 GB with
`MALLOC_MMAP_THRESHOLD_`): fragmentation keeps nearly every chunk alive. Against v0.2.30 with
all of the above: build instructions -41.6%, stripped size -11.1%, run instructions -7.7%,
median run time -6.7% and -8.1% in two runs.

## Pure-Abla runtime rebuild profile (2026-08-17)

Replacing the C runtime exposed a release-builder regression rather than an
intrinsic cost of the Abla frontend. The builder split the 34.36 MB compiler
module before ordinary interprocedural optimization. That reduced backend
latency, but the resulting compiler repeatedly crossed partition boundaries
for hot semantic/runtime operations. A clean full LLVM emission took 309.5
seconds and 1,727,684 KiB peak RSS.

The release path now runs whole-module O1 plus a focused SCCP/GVN cleanup
before splitting into 8 parts, then emits O2 machine code concurrently. The part
count is fixed because it changes the code: the same sources give the same
executable on any machine (`tools/test-reproducible-elsewhere.sh`). The worker count
only says how many parts run at once: it defaults to `nproc`, is capped at 32,
and can be bounded explicitly with `ABLA_NATIVE_JOBS`. A top-level function
declaration hash index also replaces repeated full declaration scans for
parameter metadata in semantic analysis. On the same 32-thread i9-13900K host,
the selected follow-up profile measured a 43.95-second backend and a
17.47-second generated-compiler frontend. This is statistically tied with the
61.34-second lowest-total candidate while retaining its faster frontend.

| Phase | Before | After |
|---|---:|---:|
| Compiler frontend and LLVM text emission | 309.5 s | 17.5 s |
| Optimized parallel backend | n/a | 44.0 s |
| Steady-state cold source-to-executable rebuild | over 5 min | 61.4 s |
| Frontend peak RSS | 1,727,684 KiB | 1,727,108 KiB |
| Backend peak RSS (largest process) | n/a | 621,860 KiB |

The measured reduction is at least 4.9x end to end and 17.7x for frontend
emission.
Peak frontend memory is not materially reduced: the full parsed, typed, and
lowered graph remains live in one process. The safe next memory step is
phase-separated or module-granular retained state, not a lower watchdog that
only hides the retained graph.

### Follow-up saturation search

A further 20-round search kept the same source module and compared partition
counts from 32 through 128, 16 through 32 workers, LLVM machine-code levels
O1 through O3, and focused cleanup combinations using DSE, ADCE, correlated
propagation, reassociation, aggressive instruction combining, loop deletion,
global optimization, and the complete O2 pipeline. No candidate produced a
repeatable end-to-end improvement over the selected O1 plus SCCP/GVN pipeline.

The closest results merely moved time between phases. Eighty partitions saved
about 0.10 seconds of frontend CPU time through code layout but added about
0.10 seconds to splitting and combining. Correlated propagation saved about
0.08 seconds in the frontend while adding about 0.07 seconds to the serial
optimizer. Both are within run-to-run noise, so neither is part of the release
configuration. O3 and full O2 produced smaller or differently laid-out
binaries but regressed total build time. Peak frontend memory remained about
1.73 GiB throughout.

The first release performance gate is a complete compiler build below 10
seconds on the reference development machine. After that, the target is a
sub-second warm/incremental build through cached module interfaces, persistent
compiler state, and minimal invalidation. Cold and clean builds remain reported
separately so caching cannot disguise front-end regressions.

Every optimization must preserve the conformance suite, stage-1/stage-2
behavioral parity, and the byte-identical `ablac2`/`ablac3`
fixed point unless an explicitly versioned deterministic-output change updates
both stages together.

`make ablac` remains timestamp-incremental. A changed compiler graph performs
an uncached optimized rebuild; `make self-rebuild` then compares consecutive
LLVM generations byte-for-byte and executes a native child. The build remains
paired with the four-GiB address-space and bounded-time release watchdogs.

The final native conformance programs remain uncached O2 builds, but independent
fixtures run concurrently under a memory-aware job cap. On the reference
development machine, all 49 builds and runtime assertions completed in 56.5
seconds with eight workers while consuming 283 aggregate CPU-seconds. Set
`ABLA_CONFORMANCE_JOBS` to override the automatically selected concurrency.

## Initial baseline

On the reference development session on 2026-07-31, before performance work:

| Phase | Time |
|---|---:|
| Pure-Abla compiler, source to C | 198,880 ms |
| C compiler, generated C to native executable | 3,853 ms |
| Total | 202,735 ms |

The profile boundary is already clear: over 98% of elapsed time is in the
current pure-Abla implementation. Expected first targets include replacing
repeated declaration/symbol scans with indexes, eliminating quadratic string
assembly in module bundling and C emission, reducing tagged heap allocation,
and caching parsed/type-checked module interfaces.

## Rope-runtime result

The initial profile identified generated-output concatenation as the dominant
failure: immutable concatenation copied the complete prefix and retained every
superseded allocation. A persistent rope with iterative one-time flattening
removed that quadratic copy/allocation path. On the same development session:

| Phase | Time |
|---|---:|
| Pure-Abla compiler, source to C | 685 ms |
| C compiler, generated C to native executable | 6,519 ms |
| Total bootstrap source-to-executable | 7,207 ms |

The pure-Abla compiler is now below one second and the legacy bootstrap path is
below ten seconds. The remaining measured bootstrap cost is external C
compilation; production work therefore targets LLVM object emission rather
than tuning the C intermediate. Full compiler LLVM coverage and an LLVM-native
self-host fixed point are now gated. The next measurements target frontend
indexes, IR reachability, LLVM global DCE, in-process object emission, and JIT
startup rather than the compatibility C path.

An early guarded cold `ablac build src/main.ab` through the
LLVM-native compiler completed in 9.53 seconds, including Nix shell entry,
LLVM O2/global DCE, the then-required platform adapter, and LLD. That adapter
is no longer part of the compiler build; the current final compiler contains
no project-C host/platform symbols. Run current measurements independently
with `make benchmark-native`.

The final compiler now executes ORC in-process. A warm guarded
`build/ablac run tests/cases/bootstrap/block.ab` (then without IR passes) measured 27 ms on the same
machine, including source loading, frontend work, LLVM IR generation, JIT
materialization, and execution. A persistent REPL stress gate compiled,
executed, unloaded, and allocation-reset 128 generations in 1.5 seconds.

Bootstrap compiler executables are built with `BOOTSTRAP_CFLAGS=-O2` by
default; the setting can be overridden on the Make command line for profiling.
This removes an avoidable unoptimized-host penalty but does not replace the
algorithmic work measured by `benchmark-selfhost`.

Every `ablac1` and `ablac2` launch is guarded, including direct use of the
paths under `build/bootstrap` and `make benchmark-selfhost`. The defaults are a
512 MiB address-space ceiling and 600-second wall/CPU limits, with process-group
termination after a short grace period. They can be adjusted explicitly with
`ABLA_MAX_MEMORY_MB`, `ABLA_MAX_SECONDS`, and `ABLA_MAX_CPU_SECONDS`; disabling
the guard is intentionally not a normal Make option. Whole-compiler fixed-point
LLVM emission has a separate, still-bounded 896 MiB default through
`ABLA_SELFHOST_EMIT_MEMORY_MB`; this avoids coupling ordinary compiler limits to
the temporary address-space requirement of emitting the complete compiler
module.

## In-process AOT and indexed-backend result

The final compiler calls LLVM 23 directly for `default<O2>,globaldce` and
object emission. A negative dependency gate places failing `opt` and `llc`
executables first on `PATH`; `ablac build` must still produce a working native
program. The final link remains an external Clang/LLD handoff.

Immutable scalar module values whose initializer is a literal or a proven
constant expression are emitted as internal LLVM constants. Dependencies on
other constant module values are folded recursively. Mutable module `var`s and
effectful or not-yet-proven `val` initializers retain lazy runtime
initialization. This distinction lets
LLVM fold board IDs, pins, register addresses, and other nominal scalar
constants through normal loads while preserving full module-level mutation.
It also removes the export initialization guard when every module value is
provably static; no source annotation is required.

Fixed-width native integer results remain unboxed after an exact-width C ABI
call. The backend sign- or zero-extends them once into Abla's scalar integer
SSA representation, so status checks and control flow do not allocate dynamic
values or call generic equality. Native integer arguments are truncated back
to their declared width only at the foreign-call boundary.

Profiling the full compiler exposed a quadratic backend scan: for every
function, address-taken discovery rescanned every instruction twice. A single
address-taken pass reduced deterministic LLVM emission from 7.369 s to 3.949 s.
Hash indexes for functions, natives, locals, globals, classes, and fields then
reduced it to 1.808 s without changing fixture LLVM output. On the 2026-07-31
reference session:

| Phase | Time |
|---|---:|
| Complete compiler frontend + LLVM text emission | 1.808 s |
| LLVM O2 optimization and object emission | about 5.6 s |
| Native linker handoff (historical measurement included an adapter) | about 0.27 s |
| Full compiler source to executable | **6.861 s** |

This establishes the requested sub-10-second full self-build with margin. The
sub-second target now requires cached module interfaces, persistent typed IR,
incremental code generation, and avoiding whole-program O2 on unchanged code;
it cannot be reached honestly by timing only a cached linker invocation.

On 2026-08-01, after manifest authorization, typed extension generation,
transactional publication, and the libc-free target landed, a watchdog-bounded
fast full compiler rebuilds completed in roughly **15–26 seconds** in the
current instrumented environment, and parent/child full LLVM emissions took
roughly **13–21 seconds** with byte-identical output. A measured emit peaked at
923,216 KiB RSS and a measured fast rebuild at 1,064,604 KiB RSS; both were
hard-capped at **2048 MiB** address space. These newer end-to-end observations
supersede older development timings for capacity planning; profiling must
recover the regression before the sub-second cold target can be claimed.

## Fast development AOT profile

The frontend/backend split was remeasured after the final-native conformance
gate landed. Emitting the full compiler's 8.0 MB textual LLVM module takes
about 0.5 seconds; external measurements of LLVM O2 plus machine-code emission
take about 7.2 seconds. Optimization, not Abla parsing or lowering, is now the
dominant cold-build cost.

`ablac build ... --fast` therefore skips the whole-module optimization pipeline
and selects LLVM's level-zero code generator. With canonical CFG construction,
dominance verification, definite-assignment analysis, and the affine-move
baseline enabled, gated clean pure-Abla compiler self-builds have taken about
**3.1–5.3 seconds**. Recursive structural-affinity analysis initially raised a
clean build to 5.268 seconds. Computing its class/type fixed point once per
compilation and sharing the summary across semantic analysis and all nested
lowerers reduced the same gated build to 4.358 seconds, while every compiler
continued to reproduce byte-identical LLVM IR. The subsequent authoritative
full affinity-only gate measured the cached-affinity compiler at **3.235
seconds**. After conditional direct-resource destruction and compile-time drop
parity landed, the next full byte-identical gate measured **3.371 seconds**.
Recursive structural drop descriptors, projection-remainder cleanup, and
trusted native-wrapper destructors measured **3.453 seconds** in the following
full byte-identical self-build gate. Typed `FnOnce` capture descriptors,
compile-time closure cleanup, and native environment release measured **3.542
seconds** in the next cold authoritative gate. Field-sensitive CFG place
liveness and delayed projection-remainder destruction measured **4.153
seconds** in the subsequent cold gate; this pass deliberately includes the
new place-state verification rather than timing a weakened frontend. Mutable
place reinitialization, all-path restoration, and exact moved-set convergence
measured **3.736 seconds** in the next byte-identical full self-host gate.
Segment-aware nested place aliasing and conservative dynamic-index restoration
then measured **3.702 seconds** with the same full gate. Place-sensitive
borrow/own call exclusion and inferred mode-bearing function values measured
**3.858 seconds** in the next cold byte-identical self-host gate. The following
source-syntax-only `(own: T) -> R` gate reused the exact compiler object and
therefore is not reported as another cold measurement. Call-scoped exclusive
`var` borrowing initially exposed both a precision and a memory regression:
repeated whole-body receiver-effect scans classified native `load()` operations
as writes and peaked near 929 MiB RSS. Replacing them with one fixed-point
mutable-receiver summary restored read/write precision, reduced the same
guarded whole-compiler LLVM emission to about **636 MiB RSS**, and kept the
existing 768 MiB watchdog unchanged. The subsequent full fixed-point gate
measured the cold fast self-build at **3.958 seconds**, including the affine
mutable-borrow checker and mode-bearing callable contracts.
Further work should persist this
summary in typed module interfaces and avoid rebuilding whole-graph semantic
state after an unrelated edit.

Adding the affine `Shared<T>`/`Weak<T>` implementation increased the
self-hosted compiler graph because its LLVM backend now carries the atomic
control-block generator. The guarded core-compiler emission measured about
746 MiB peak RSS and the larger ORC compiler graph about 775 MiB. The old
768 MiB address-space ceiling consequently became too tight and correctly
aborted one fixed-point build instead of allowing an unbounded process. The
self-host emission ceiling is now calibrated to 896 MiB, leaving bounded
headroom while ordinary compiler invocations retain the 512 MiB default.
Shared/weak LLVM support is feature-selected: programs whose typed IR has no
shared/weak operation receive neither `%AblaShared` nor its atomic runtime, so
the new capability does not inflate small ordinary binaries. The completed
byte-identical gate, including stable nullable-flow refinement, measured a
**4.323-second** cold fast self-build and a
**124 ms** exact-source object-cache hit on the same machine.
`serve` uses this profile automatically. Release `build` remains O2, and the
sub-second target still requires persistent module/typed-IR/object caches rather
than weakening what is included in the measurement.

The scoped-region gate adds fixed-point native-call, receiver, and heap-parameter
retention summaries to that same whole graph. Its first cold fast self-build
measured **4.672 seconds**; the subsequent complete green gate reproduced both
compiler fixed points byte-for-byte and measured a **130 ms** exact-source
object-cache hit. The compiler and REPL remained inside their existing bounded
watchdogs, including 128 region-reclaimed ORC generations.

The exhaustive-control-flow gate initially triggered the 1024 MiB final-
compiler watchdog: an unreachable hook recomputed expression types for every
lowered AST node, and the unoptimized fast self-build amplified that work on
the complete ORC graph. Replacing the hook with precomputed `never`-callee
metadata restored both optimized and fast pure-Abla fixed points under the
unchanged limits. After the owned-parameter contract checks landed, the full
green gate measured a **4.751-second** cold fast self-build and a **124 ms**
exact-source cache hit. This is why memory ceilings remain correctness gates,
not optional benchmark settings.

Stored immutable `Shared.get()` views add backward CFG borrow liveness and a
selective pre-evaluation verification pass for borrow-bearing runtime
functions, compile functions, and methods. The first implementation retained
all compile-function validation IR and pushed the LLVM-linked final compiler
past its 1024 MiB address-space watchdog. Per-function checkpoints, syntactic
candidate selection, and reclaiming temporary value-definition/place-state
verification tables reduced the measured final-compiler peak from about
**933 MiB to 902 MiB RSS** while preserving the then-current 1024 MiB final
ceiling. At that gate, the unoptimized fast self-rebuilt executable needed
1032 MiB of address-space headroom solely for its larger code mapping and
remained separately bounded.
The resulting gate measured a **5.049-second** cold fast self-build before
continuing through the pure self-rebuild and conformance suites.

The chained-view rung adds transitive owner provenance for immutable borrow
copies and stored field/index projections. Compacting that provenance to one
table aligned with function locals kept the complete compiler at about
**905 MiB peak RSS**. Its optimized and unoptimized complete-graph executables
now use separately calibrated **1040 MiB** and **1056 MiB** address-space
watchdogs: the additional virtual headroom covers executable mappings, while
ordinary compiler invocations remain at 512 MiB and the core self-host emission
remains at 896 MiB. The complete chained-view gate measured a
**5.093-second** cold fast self-build and a **130 ms** exact-source object-cache
hit.

The following same-owner lifetime-join rung extends stored borrows through
block-valued `if` and exhaustive `when` expressions while rejecting ambiguous
cross-owner joins. It kept the **1040 MiB** optimized and **1056 MiB** fast
self-host watchdogs unchanged, reproduced both pure-Abla compiler fixed points
byte-for-byte, and measured a **5.159-second** cold fast self-build with a
**127 ms** exact-source object-cache hit.

The source-linked borrow-return rung adds `borrow(source) T` contracts for
functions, compile functions, and methods, plus caller-place substitution and
overlapping call-argument checks. Its first normalizer used a seven-byte
`slice()` for every contract-prefix test; arena accumulation raised a guarded
whole-graph run to roughly **956 MiB RSS**. Direct byte tests and shared
declaration lookup reduced the final path to about **910 MiB RSS**, while the
ordinary 512 MiB and core 896 MiB watchdogs remained unchanged. The larger
complete-graph executables now have calibrated **1064 MiB optimized** and
**1072 MiB fast** virtual-address watchdogs. Both pure-Abla fixed points are
byte-identical; the complete green gate measured a **5.379-second** cold fast
self-build and a **134 ms** exact-source object-cache hit.

The callable-family and synchronized-mutation batch adds `FnMut` capture cells,
indexed borrow lifetimes through indirect/global/returned callbacks,
`Borrow<T>`, and `Mutex<T>`. Prefix recognition remains direct byte matching so
these type forms do not allocate short-lived slices across the whole compiler
graph. The source compiler is bounded at **960 MiB**; the LLVM-linked complete
compiler is bounded at **1120 MiB optimized** and **1128 MiB fast**. Under that
ceiling the optimized compiler emitted the complete compiler twice with
byte-identical LLVM IR, and one combined evaluator/LLVM/generated-C smoke gate
covered the batch. These are watchdog ceilings rather than target steady-state
usage; lowering the graph's retained-memory footprint remains active work.

The following hermetic-effects, canonical-module, typed-global, and extension
generation batch remains byte-identical at the self-hosted fixed point. Compact
effect bitsets avoid retaining per-call objects; generated modules are capped
at 64 per staging unit and 64 KiB each. The complete optimized image now has a
calibrated **1152 MiB** emission watchdog (1144 MiB fails cleanly), with
**1160 MiB** reserved for the fast image's mapping margin. Ordinary invocations
remain bounded independently, and every calibration attempt ran through the
same process-tree memory/time watchdog.

The whole-graph object cache now makes an unchanged fast compiler build take
about **0.11–0.14 seconds** (134 ms in the latest full reliability gate), down
from the multi-second cold fast build. That
interval includes exact bundled-source validation, copying the cached object,
and LLD. A permanent gate proves
that the hit does not regenerate LLVM and that changing the source while
reusing the output path selects a different object. This reaches the warm
sub-second milestone for unchanged graphs; edited builds still need
module-granular interfaces and invalidation rather than whole-graph reuse.

The 2026-08-01 warm-path audit found a regression hidden behind that contract:
a bundled-source substring search for `compilerGrant(` matched the compiler's
own cache implementation and semantic checker, conservatively disabling its
cache. Eligibility now inspects already-parsed top-level `#compilerGrant`
actions instead. Ordinary compiler source is cacheable again. Authorized
`filesystem.read` staging is cacheable with a bounded sidecar containing each
observed path, content size, and dual fingerprint; the entry manifest is part
of the cache identity, and a missing, corrupt, or changed input record is a
miss. Parser handlers and finalizers feed the same input identity and invalidate
their persistent staged-frontend snapshot when an observed file changes. Other
ambient effects remain conservatively uncached.
With the corrected eligibility check and an optimized pure-Abla compiler, the
first fast whole-compiler build completed in about **7.4 seconds** in the
observed run. The immediately repeated exact-source build completed in
**0.89 seconds**, including Nix-shell entry, object copy, transactional LLD
relink, and publication, and peaked at **198,408 KiB RSS** under a 960 MiB
address-space watchdog. Cold results still vary with host load; the cache gate
asserts behavior rather than a fragile timing threshold.

Self-build recipes no longer use a blanket 2048 MiB limit. Canonical full-graph
self-rebuilds use the production release-O2 compiler under a **1536 MiB**
address-space ceiling; that path was observed at 1,278,560 KiB peak RSS.
Complete unoptimized compiler images are intentionally not the fixed-point
gate: their much larger code mapping crossed the watchdog as the compiler grew,
without adding a stronger correctness property. Fast AOT remains gated on
ordinary programs. Whole-IR emission retains its smaller separately calibrated
limit.

The explicit collector is now selected from entry-point reachability. A
work-list walk follows direct calls and conservatively expands indirect calls
to address-taken functions. Programs which cannot reach `memoryCollect()` no
longer carry the pure mark/sweep implementation; collector users retain the
zero-initialized allocation contract and complete shadow-root path. The
optimized compiler remained byte-identical at its next fixed point and emitted
its complete 19.4 MiB LLVM module in **8.855 seconds** in the observed cold run,
under the unchanged **1152 MiB** emission watchdog. This pass is primarily a
program-size and optional-runtime win; it does not yet claim a frontend speed
improvement.

The following allocation pass split tracked allocation into initialized and
fully-written paths. Collector-capable and host-backed programs retain zeroed
storage, because conservative tracing must never inspect indeterminate words.
Pure programs with no reachable collector skip clearing; generated arrays,
objects, closures, and strings initialize every word they expose before use,
which is enforced by the existing definite-assignment and runtime conformance
gates. The complete optimized compiler then emitted the same fixed-point module
in an observed **8.656 seconds** (about 2.2% below the immediately preceding
8.855-second run), still under 1152 MiB. This is deliberately recorded as a
small allocation win, not the sub-second result; typed incremental IR/object
reuse remains the path to the larger cold-build reduction.

The next collector passes added independently checked scan prefixes, precise
layout maps for values, fields, arrays, objects, ropes, strings, cells, and
shared storage, plus a pinned-raw class for deterministically dropped native
resources. Selecting a managed-memory limit enables compiler-published
function-entry pressure safe points; programs with no reachable managed-memory
API still strip the collector. The production graph remains Abla plus LLVM and
does not import the compatibility C backend or project runtime.

The promoted compiler's fixed module is **19,339,832 bytes**, with SHA-256
`eaa7294fe1af763a1858d8eb3679063795d61b780e9b3f262af45e8a42f405c8`.
It rebuilt the complete compiler directly through public `ablac build` in an
observed **25.9 seconds** under the four-GiB watchdog, and its child emitted
byte-identical IR. This safety-first ownership migration is above the cold
sub-10-second target again; incremental typed reuse and retained-summary work
remain the next performance phase. The phase-separated release helper remains
the lower-peak fallback; both paths publish output transactionally.

The first persistent module-state rung is now active in `serve`. Source,
content fingerprints, and scanned import edges are cached per path; a
same-length leaf edit refreshes exactly that leaf, while unchanged parents and
siblings are reused, and an import-edge edit replaces the active dependency
set. Dependency-fingerprinted staged ASTs are cached as well, including the
visible imported subparser-provider environment; only the current AST for a
path is retained. Native regression gates cover reuse, leaf/import-edge
invalidation, nested imported subparsers, and no-project-C linking. This is not
yet typed-IR incremental compilation: semantic analysis, LLVM emission, and
object generation remain whole-graph after an edit.

## Programmable-build foundation profile

On 2026-08-02, after recursive build graphs, foreign ABI manifests, Android and
WASM extension proofs, checked exports, and graph rollback landed, an uncached
fast self-build completed in **27.162 seconds**. A separate full LLVM-emission
run completed in **21.220 seconds**. Instrumentation of that emission attributed
approximately 0.651 seconds to parsing, 10.602 seconds to semantic analysis,
8.204 seconds to lowering, and 0.935 seconds to LLVM text emission. The small
remainder is phase-boundary overhead.

This build remains below the requested 30-second ceiling, but no longer has the
margin of earlier, smaller compiler graphs. The next cold-build work belongs in
semantic-summary reuse and lowering, not output-string micro-optimization. The
existing exact-source cache remains the warm path; these figures deliberately
measure an uncached complete compiler and do not use a cache hit to hide the
regression.

The 6.861 s measurement includes the LLVM-emitted scalar, closure, collection,
object, formatting, equality, and iterative rope runtime. The resulting
`src/main.ab` compiler was 1,608,216 bytes and reproduced the
reference LLVM IR byte-for-byte. Large generated runtime strings also exercise
the new seed-C constant chunking path rather than relying on non-portable C
translation limits.

## Managed HTTP service result

On 2026-08-11, the single-CPU `abla-compare` HTTP/1.1 keep-alive benchmark
improved from **4.7 requests/second** with 12.9-second median latency to a
three-run median of **86,786 requests/second**, **0.484 ms p50**, and **0.971 ms
p99** at 64 concurrent connections. This is 2.09 times the previous managed
baseline of 41,511 requests/second. The response and status are validated
before every run; Go and Rust use the same endpoint, connection count, CPU
isolation, warm-up, and measurement intervals.

The principal memory bug was an ownership transition, not inherent collector
cost. Native socket buffers begin pinned because an integer address is invisible
to tracing, but adopting one as a managed string failed to change its scan
layout. Every read therefore retained the old 65,537-byte buffer forever. The
fix makes adopted storage collectible and covers that transfer with a direct
collection regression. The final two-minute load completed 11,148,227
successful requests at 92,900 requests/second, remained alive with 100% success,
and peaked at 135,080 KiB RSS.

The throughput work also replaces byte-at-a-time Abla HTTP scans with bounded
text intrinsics, retains slices as collector-safe views, parses each framed
request once, maps descriptors directly to connection slots, reads exact-size
4 KiB chunks, consumes packed poll events without a temporary object graph,
and attempts small writes before requesting another poll wake-up. Partial
writes retain the existing offset and backpressure behavior. The full
73-fixture conformance suite, byte-identical self-rebuild, hosted HTTP tests,
and static raw-target server all pass with these paths enabled.

The second optimization pass kept those semantics and changed general compiler
and managed-runtime machinery. Hosted O2 executables now receive whole-program
LTO across generated LLVM and the Abla runtime. Their
ordinary combined relocatable `.o` remains separately compiled for Icy and
cross-libc packaging. The native cache stores the generated LLVM module as well
as the ordinary object, so cache-hit release builds retain LTO; the measured
cached executable was byte-identical to the uncached one.

Managed arrays and compiler-known class fields now use one allocation for their
header and initial storage. Constructors initialize their already-sized field
slots directly, while later reflective or dynamic mutation retains the existing
symbol-based path. The collector uses an exact-pointer hash index instead of
sorting every live allocation, and managed string views retain the allocation
that actually owns their bytes. These changes preserve the boxed value ABI,
reflection, mutation, foreign ABI, and managed lifetime rules.

Hardware counters explain why Rust remains faster. In a pinned ten-second run,
Abla retired approximately **84,115 instructions** and **43,425 cycles** per
request at **1.94 IPC**. Rust retired **14,017 instructions** and **5,427
cycles** per request at **2.58 IPC**. Abla therefore executes about six times
as many instructions and eight times as many cycles per response. Its hottest
sample was managed memory pressure (24.4%), followed by allocator consolidation
and allocation; Rust's hottest named samples were HTTP parsing and writing.
Later passes below implement checked region placement for non-escaping request
graphs and conservative scalar unboxing. Remaining parity work includes broader
typed aggregate specialization, lower-cost collection checks, and collector
improvements. Disabling collection or weakening the language model would hide
rather than solve the measured gap.

### Direct calls and lexical response regions (2026-08-11)

The next measured pass gives compiler-generated direct calls a typed pointer
ABI while retaining the generic `(output, arguments, count)` wrappers required
by closures, exports, reflection, and indirect dispatch. It also limits
function-entry memory-pressure checks to functions that can both reach the
collector and allocate directly. The comparison server contains 433 static
pressure calls after this change, down from 544, without weakening collection
at an allocation boundary.

Abla lexical `region` scopes now use nested, page-backed bump allocation in the
host runtime. Region exit reclaims its pages in bulk and a bounded thread-local
page cache reuses them; manually freed region objects are unlinked safely and
the tracing collector continues to understand live region allocations. A
separate `memoryPromoteString` operation copies a region-owned string into its
parent allocation domain when it must escape. Raw targets retain their previous
no-op region reclamation semantics.

The event HTTP server applies the region only to response construction, after
the user handler has returned, and promotes the completed wire response before
storing it in the connection slot. This deliberately leaves request parsing and
the arbitrary handler outside the region because a handler may retain request
data. In an isolated A/B run at 64 connections, this safe boundary improved the
three-run median from **92,273 to 103,428 requests/second** (**12.1%**), p50 from
0.490 to 0.469 ms, and p99 from 0.969 to 0.932 ms. Retired work fell from about
83,922 to **75,940 instructions/request**, and from 43,214 to **37,851
cycles/request**. Allocator-related samples fell from roughly 19% to 13% of the
profile. The full 73-fixture suite and byte-identical self-rebuild pass with the
optimization enabled.

### Demand-driven writable interest (2026-08-11)

The event HTTP loop previously issued `epoll_ctl(MOD)` after every completed
response even though readable interest had never been disabled. It also did
not enable `EPOLLOUT` when an immediate nonblocking write stopped at kernel
backpressure. Per-connection writable-interest state now changes the poller
only on the transition into or out of a real pending-write state.

On the same pinned single-worker comparison, three ten-second samples improved
from a **103,875 requests/second** median to **107,365 requests/second**
(**3.36%**). Median p50 fell from 0.469 to 0.444 ms and p99 from 0.931 to
0.875 ms. A five-second syscall audit with 64 persistent connections observed
only 132 `epoll_ctl` calls, so poller updates now scale with connection
lifecycle rather than request count. A forced 256 KiB response with a 4 KiB
server send buffer verifies that the partial-write path registers writable
interest and drains the complete response before closing.

### Checked request regions and lazy scalar SSA (2026-08-11)

The checked `FnNoEscape(A) -> R` callable contract lets the event HTTP server
place parsing, static routing, handler execution, and response framing inside
one request region. Only the completed wire response and unread connection tail
are promoted. This moved the canonical single-worker result from 111,030 to
144,573 requests/second without changing the general escaping handler API.

The following compiler pass infers only proven `i64` and `bool` IR values and
locals. Arithmetic, comparisons, bit operations, bounded shifts, branches,
direct scalar calls, and compatible native calls consume LLVM scalar values
directly. Declared local types survive lowering, so a scalar stays native even
when its first assignment is control-flow dependent. A value receives boxed
storage only when a use crosses a dynamic or otherwise unsupported boundary;
locals are eligible only when every assignment proves the same scalar type.
Division, heterogeneous equality, aggregate access, and unproven locals remain
on their established boxed runtime paths.

Against the checked-region binary, a five-sample isolated A/B improved the
median from 143,955 to 152,141 requests/second. A separate counter run reduced
retired instructions from about 49,678 to 46,376 per request and cycles from
23,114 to 20,597. The optimized HTTP executable shrank from 540 KiB to 471 KiB.
The canonical cross-language rerun reached 152,868 requests/second, 95.5% of Go
and 55.2% of Rust on the same pinned setup. All 75 tests and the byte-identical
self-rebuild pass. Native parameter storage was also tested, but its additional
missing/default control flow reduced throughput by 0.73%, so that experiment
was removed.

## Reachability and size result

The LLVM size path marks Abla implementation functions internal, limits
the indirect dispatcher to address-taken functions, runs LLVM O2/global DCE,
and links function-sectioned runtime shims with LLD garbage collection. On the
same 2026-07-31 development session:

| Native program | Before | After | Reduction |
|---|---:|---:|---:|
| identifier-shadowing scalar fixture | 37 KiB | 7.5 KiB | 80% |
| lambda-capture fixture | 47 KiB | 22 KiB | 53% |
| version-aware HTTP server | 126 KiB | 97 KiB | 23% |

The HTTP result intentionally includes the tagged-value runtime and live TCP
transport. Further reductions come from IR-level reachability before textual
emission, a raw-kernel platform profile, specialized/unboxed values, and
splitting optional HTTP features such as server transport from router-only use.

Generated direct scalar implementations use internal linkage. Size-oriented
MCU builds also make their universal-value wrappers internal immediately.
Hosted release LTO preserves the wrappers as hidden during its early O1
specialization, then internalizes them before O2/LTO dead-code elimination.
This ordering retains profitable scalarization across hot indirect ABI calls
while still removing unreachable imported implementations before machine-code
emission; explicit export thunks remain the only public object boundary.

## Compact 24-byte dynamic values (2026-08-12)

The portable dynamic value ABI now uses an explicit 32-bit tag, a 32-bit
auxiliary word, and a 16-byte payload. Function identifiers use the auxiliary
word; a closure keeps its capture count and capture pointer inline. Flat
strings retain their pointer and full `size_t` length without boxing. Rope
length moves into the rope allocation, and slices are allocation-interior
views understood by the tracing collector. This reduces `AblaValue` from 32
to 24 bytes on native and Wasm targets without narrowing string lengths or
adding per-string or per-closure allocations.

In the same one-million-element dynamic-array workload, tracked storage fell
from 33,554,456 to 25,165,848 bytes, exactly 25%. Median process RSS fell from
about 51 MiB to 38 MiB. The isolated five-sample HTTP comparison reached a
235,674 requests/second median, up 6.8% from the prior 220,714 baseline; the
same run measured Go at 164,657 and Rust at 282,480 requests/second.

A 16-byte form was evaluated but not adopted. It cannot retain a pointer plus
full-width length for strings or a capture count plus pointer for closures,
so it requires additional boxed descriptors or packed-length fallbacks.
Sixteen bytes also crosses the x86-64 and AArch64 aggregate return threshold,
requiring a coordinated direct-return rewrite of every runtime, foreign, Wasm,
Android, and bootstrap boundary. Keeping 24 bytes is therefore the smallest
validated portable representation in this pass, not a claim that a separately
benchmarked 16-byte direct-return ABI can never win.

## Segmented large HTTP bodies (2026-08-12)

The 16 KiB echo workload transfers at least 32 KiB per request: one 16 KiB
request body enters the process and the same payload leaves in the response.
Its CPU profile was consequently dominated by byte movement rather than the
dynamic value ABI: `memmove` and `memset` accounted for about 39% of sampled
cycles before this pass.

The hosted readiness-loop reader now receives directly into an uninitialized
managed byte allocation and publishes only the bytes actually returned by the
kernel. Large segmented responses use a bounded 64-entry `sendmsg` scatter
write, preserving `MSG_NOSIGNAL`; the libc-free runtime provides the equivalent
raw syscall. Small responses retain the contiguous writer because its lower
setup cost is faster below 4 KiB. Deep ropes fall back to the established
flattened writer, and partial writes still promote the response before its
request region is reset.

In an adjacent five-sample comparison at 64 connections, the body median rose
from **120,508 to 126,240 requests/second** (**4.76%**). The candidate samples
were tightly grouped from 125,864 to 127,049 requests/second. The final holistic
run measured Abla at 124,580, Go at 102,936, and Rust at 155,144 requests/second;
Abla remained faster than Go in all four workloads. Regression coverage checks
a nonzero write offset, more than 64 rope leaves, the flattening fallback, and
the raw libc-free syscall path. All 75 compiler/runtime fixtures and the
byte-identical self-rebuild pass.

## `--fast` and `--o1` IR pipelines (2026-10-26)

A native `--fast` build runs only `function(mem2reg,simplifycfg)` before
codegen at level 0, so nothing is inlined: a loop over a string's bytes calls
the runtime for every byte. Over 8 million quotes in a 2.5 MB text, it ran in
2220–2270 ms, against 51–101 ms at `--o1`. Three ways to close that gap were
measured and parked. The `--fast` profile stays the cheap compile, because tests
that are dominated by compile time pay for every second its pipeline adds.

| `--fast` IR pipeline (codegen level 0) | self-build cost | byte loop |
|---|---|---|
| `function(mem2reg,simplifycfg)` (kept) | 14.1–15.7 s user CPU | 2270 ms |
| `--o1`'s IR pipeline, inline threshold 100 | +17–31% | 191 ms |
| the same without `instcombine` | +25–45% | 247 ms |
| inline and `sroa` only | +32–48% | 506 ms |
| `always-inline` on small runtime functions | +120–300% (wall) | 624–667 ms |

The leaner pipelines compile *slower* than the full one: `instcombine` shrinks
the inlined code enough that codegen at level 0 does less work, which more than
pays for the pass itself. Inline thresholds of 25, 50 and 100 cost the same.
The cost is in inlining and in compiling the grown code, not in the cleanup
passes. `always-inline` also turns on every existing `@inline` hint, and code at
level 0 keeps all of that growth.

The full pipeline at codegen level 0 is no substitute for `--o1` either. It
compiles the compiler with about 2.7× less CPU (22.8 s against 62.6 s median,
under load), but its byte loop runs at 300–355 ms against `--o1`'s 78–101 ms.
For `ablac run`, the JIT's compile of the program dominates: the determinism
tool cost 9.5–9.7 s of user CPU under either pipeline with the JIT cache off.
The full pipeline also made the `--fast` compile-time parity suite 9% slower
(249 s against 229 s). These are relative measurements under a load
of 15–35, interleaved and taken three times each.

## Lazy root frames (2026-10-26)

A function that may reach the collector pushed its root frame, and ran its
pressure safe point when it allocates, at entry on every call, even on a path
that returns before anything can collect or allocate. The frame's slots are
still written at entry, but the push and the safe point now run at the start of
the first block that may collect (or allocate, for a function with a safe
point). A forward pass over the blocks finds, for each push site and each
return, whether every path into it pushed the frame or none did: a site no path
pushed before pushes, one every path pushed before emits nothing, and a return
pops only when its paths pushed. A function keeps pushing at entry when no
return can be reached without the push, when a site or return could be reached
both ways (a push in a loop: a flag tested at run time cost about 1.2% more
code in an optimized compiler for little time), when its first block needs the
frame, or when its safe point would find an unrooted boxed value live at a
later block.

Against the compiler it was branched from, on the same machine and load:
a scalar fast path with an allocating cold path (`if (x < 100.0) return
x * 0.5 + 1.0`, 1e8 calls) dropped from 0.21–0.22 s to 0.11–0.12 s, the time of
the same function without the cold path; the v8 port's `sin` from 0.29 to
0.27–0.28 s for 2e7 calls; the `--fast` self-build's user time from a median of
14.8 to 14.6 s. JSON parsing and a simulation tick, whose hot functions have no
early-return fast path, were unchanged within noise. The optimized compiler's
code is the size it is without lazy frames (5,885,812 bytes of text built
without them, 5,885,684 with them): the first version, with the flag in every
function with a push in a loop, made it 1.6% larger. The compiler rebuilt by
itself writes byte-identical module text.

## Locals rooted by liveness (2026-10-26)

A function's root frame held every pointer-bearing local from entry to return,
so each assignment to one was also a store into the frame. A local now has a
frame slot only when a collection can see it: when it holds a value across a
call that may collect, an allocation, or a safe point where a lazy frame is
pushed. Uses and assignments are placed in source order, a loop's interval
widened to the whole loop, so a local whose value is dead before every such
site is a plain SSA value. A block that ends the function counts only for the
locals it reads before writing. Collections at every safe point
(`ABLA_GC_STRESS=1`) keep the program's output.

Against the compiler it was branched from, on the same machine and load: the
v8 port's `sin` module stores into its frames at 20 places instead of 84, and
2e7 calls dropped from 0.29–0.32 s to 0.13 s user time. JSON parsing, the
`--fast` self-build (user time median 17.0 to 16.4 s) and a game simulation
tick (2.40 s against 2.39 s user time over 12 interleaved runs each, with 11%
fewer frame stores and 1% less code) were unchanged within noise. The compiler
rebuilt by itself writes byte-identical module text.

## Typed instance layout (2026-10-27)

A class instance held each declared field as a 32-byte slot (the field's
symbol and a boxed 24-byte value) behind a 32-byte header: every field, a bool
included, cost 32 bytes. Instances now store each field by its type's kind
behind a 16-byte header (the class's descriptor and the overflow of extension
fields): an int, f64, f32 or raw pointer is one word, a bool one byte, a
string its two words, an array, map, instance or interface value one word (0
when a nullable one is null), and any other type (`any`, functions, nullable
scalars, the runtime's own values) a boxed value. Words and wider fields come
first, in declaration order, then the bools. A class's descriptor, a constant
the compiler emits, lists each field's symbol, offset and kind (for reads and
writes by name, the compile-time lift and the heap census) and the fields the
collector traces. Typed accesses carry the field's offset, kind and tag; a
string or reference field has its own accessor, so an unoptimized build reads
one without choosing among kinds.

Payload bytes per instance (`memoryCensus`):

| Class | Before | After |
|---|---:|---:|
| `Small(int, f64, bool, string)` | 160 | 56 |
| `Wide(10 × f64)` | 352 | 96 |
| 646 fields (264 f64, 323 bool, 29 string, 19 instance, 5 array) | 20,704 | 3,112 |
| the same with its 24 default instances and arrays | 23,864 | 4,296 |

The allocation header (32 bytes, and on Wasm the allocator's block header and
size-class rounding) is unchanged. A game simulation that keeps its state in
raw columns measured the same in release builds and 5-7% faster per tick in
development builds; its server's instances (8% of its heap under load) shrink
about 3.4 times; a compiled program's class descriptors add about 60 bytes of
constant data per class.

## Share failed-allocation reporting (2026-11-03)

On top of `compiler-perf-3` `1492df3f` (including the correction that prevents
inlining Abla main into the minimum-size C wrapper), `HostOutOfMemory` is
explicitly `@noinline`. Its diagnostic and recursive-failure guard are shared
between the allocator's checks. They execute only after a system allocation
fails. No new `optsize` or `minsize` policy applies to normal execution.

Across all thirteen programs this removes 432 to 672 bytes each: 1.90% smaller
than the parent, and **11.35% smaller than master `753d1d10`**. Fib is 12,016
bytes, matrix 38,488 and json-megabyte 211,816. The full master comparison
(one build, three interleaved run rounds, pinned CPU 8) gives 21.1% fewer build
instructions, 11.3% fewer run instructions, 9.1% fewer minimum run cycles and
5.1% fewer median run cycles. Every run benchmark remains at or below master
in instructions.

A separate seven-round comparison used identical source and sysroot paths.
The normalized hot-function assembly for sieve, nbody, matrix and dispatch is
unchanged. Their minimum-cycle changes are -1.9%, +0.8%, -1.2% and -2.1%;
medians are +1.1%, +0.1%, -0.6% and +2.6%. An earlier matrix cycle penalty did
not repeat. The server shrinks by 960 bytes (259,016 to 258,056). An initial
blocked comparison flagged body-16k +10.6% cycles; alternating the two servers
on CPU 8 instead gives -0.8%. Repeated paired context and route-fanout runs
(100,000 requests, five rounds) give -0.5% and -2.4% cycles, respectively.
Incremental request instructions move by a few tenths of a percent.

A fresh master server built from the same project gives all nine workloads
lower instructions per request: geometric mean -3.47% (20,000 requests,
three rounds), and -7.19% cycles overall. Body-16k's blocked master comparison
is +1.6% cycles; the paired parent comparison above is -0.8%, so that single
cycle delta is not evidence of a changed byte loop. Master strips to 290,000
bytes versus 258,056 for the candidate (-11.0%).

A compiler built from this worktree passes all **257 `make test` commands**
in 334 seconds (16 jobs, P-core affinity, runtime parent soft stack 8 MiB).
This includes `ablac test`, its bundled mode, runtime/debug failures, GC
stress, checked exports, TLS and the new function-identity regressions. The
first cold-worktree run passed 256 commands and hit the existing TODO's
`fs-read 1` fixture: compiling creates `build/` after its directory snapshot.
The focused retry and the complete warm-directory rerun pass unchanged.
