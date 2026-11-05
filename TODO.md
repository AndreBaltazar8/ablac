# TODO

## Rules

- All open work on ablac is tracked here: the compiler, runtime, standard library, tooling and
  what packages need from them. Add new tasks as they come up.
- Each big item gets at least one commit of its own, and can take several.
- This file can be committed at any time, along with the work or on its own.
- As soon as a task is completed, take it off this file, in the commit that
  finishes it. Git history is the record of what got done.
- Only list what is really open. A task is done when it is verified where it runs (the tests,
  the fixed point, and the target or package it is for), not just when it compiles.
- Any bug or error seen goes here right away, even if it looks minor or unrelated, with what
  was seen and how to reproduce it. Don't only mention it in a report.
- Keep the measurements on performance items, and what was tried and dropped, so nobody
  repeats the work. Date them: they go stale.

## Bugs seen

- [ ] A local callable shadowing a constructor can be normalized as the
  constructor when their arities differ: `class FloatMaker(val value: int)`
  followed by `val FloatMaker = { -> 1.5 }; FloatMaker()` reports
  `E_NAMED_ARGUMENT_REQUIRED` instead of calling the local function. Seen on
  master 424980cb on 2026-11-04.

- [ ] Additional `--fast` ELF sections: LLVM's in-process C API ignores
  `--function-sections`/`--data-sections` set through its command-line parser.
  A manual section screen moved relocated constants out of RELRO and is unsafe.
  Paired one-core builds changed fib 128,696 to 98,984 bytes (2.277 to 2.286
  billion instructions), JSON readers 494,952 to 467,536 (7.451 to 7.485
  billion), and NovaKind's tool 2,674,576 to 2,824,680 (31.794 to 32.779
  billion). Revisit only with LLVM-correct relocation and section rules.

- [ ] Report a readable unsupported interpolation panic on WebAssembly when
  the module already imports the host write path, without adding imports to
  hostless modules; these currently trap without a message. On 2026-11-03,
  a writer-slot probe set from the generic syscall shim added `abla_host.write`
  to clock-only modules. Setting it from the standard output writer instead
  preserved clock-only and unused-output modules, but added `write` for a
  reachable empty write where baseline has no imports, in both fast and
  release builds. Neither was kept; preserve final import sets when revisiting.

- [ ] Floats erased to `any` interpolate as integer bit patterns: native
  `text(1.5)` through `fun text(value: any): string = "$value"` prints
  `4609434218613702656`; f32 2.25 prints `1074790400`, while compile-time
  evaluation prints `1.5`. Scalar typed-to-`any` boundaries now preserve float
  identity in the auxiliary word; dynamic formatting and collection boundaries
  still need to use it. A complete fix must preserve float identity at every typed-to-any boundary
  (calls, locals, fields, collections, returns and closures), through generic
  storage, on native and Wasm; keep dense typed arrays and integer/GC ABI
  behavior; and check NaN, infinity, negative zero, formatting, bootstrap and
  size/performance. An isolated probe used the auxiliary word as a float tag
  and imported `abla/float/text` into the runtime: it formatted a manually
  tagged value but grew an int-only executable from 14,600 to 40,408 bytes
  (2026-11-03). A later representation-only prototype with auxiliary float
  kinds, dense float arrays and a module-wide demand flag kept an int-only
  release probe byte-identical, but an O1 QR test bundle grew from 543,128 to
  551,512 stripped bytes (+1.54%) and used 209.462 to 210.490 billion
  instructions (+0.49%; one paired run). A module-wide flag makes shared
  integer-array paths float-aware whenever any float exists; it is not enough
  to meet the performance budget. The prototype remains uncommitted on
  `fix-erased-float`. Revisit with type-directed identity added at proven
  erasure boundaries while keeping typed float and array paths unchanged;
  retain conservative behavior at generic, reflective and foreign boundaries.
  Phase (d) now preserves erased float kinds through native CT wire and shared
  lift emission, with explicit interp/JIT and hostless Wasm bit-level tests.
  A demand-driven formatter and its end-to-end native/compile-time/Wasm tests
  remain phase (c)'s work; bit preservation does not make formatting correct.
  Equality and hashing through `any` currently ignore the auxiliary word, so
  a boxed float and an integer with identical payload bits compare equal and
  hash alike through `any`; deciding whether to change that is a separate language issue.

- [ ] **Xtensa `llc` aborts on frames of 128 to 255 bytes that take a stack address.** `LLVM ERROR: Error
  while trying to spill A6 from class AR: Cannot scavenge register without an emergency spill slot!`, seen
  2026-11-01 on `esp32RecoveredZN3nvs7Storage9writeItem...` from abla-embedded's `tools/build-example
  imu-offsets` and `wifi-connect`. `llvm-xtensa-scavenging-slot.patch` reserves the slot past 255 bytes, but
  `LEA_ADD`'s `ADDI` reaches only 127 (`isValidAddrOffsetForOpcode`). `!isInt<8>(MaxSPOffset)` fixes it:
  checked with an Xtensa-only `llc` from the fork plus that one line, and both examples then compile. Branch
  `llvm-xtensa-lea-scavenging` has it, pinned to the published `llvm-23.1.3-xtensa-2` (2026-11-01): both examples build with it
  and its `llc` output matches the patches' source build. It's held back from master with `mcu-gc-inline`, until the PaperMono
  hardware test; merging it is what closes this.
- [ ] **A class's methods are all compiled, used or not** (abla-one, 0.2.29), so what only one method reaches stays in every program
  with the class: `val table = build()` read only by an uncalled method still runs at startup and links `build` (why abla-one's
  `Style.wrap` is an extension). The uncalled method is dropped by LLVM, its global's initializer isn't. Looked at 2026-11-02, not changed:
  `bootstrapSourceReachableDeclarations` walks every method of a reached class, and the lowering loop lowers them all, by declaration.
  It needs method-level demand in both, by called name, with what lowering inserts by itself (operators, iterators, delegates, drops)
  counted. Weigh against what removing dead functions before opt did to inlining ("`make test` under 2 minutes", below).
  Counting-only screen on `cf41f7f3` (2026-11-04): conservative called-name demand would skip 7/716 currently
  source-reachable method bodies in the compiler, 35/134 in abla-one's gallery/web, 3/89 in the frozen NovaKind tool,
  and none in the da5a939 firmware fixture. These are existing bodies absent from a shadow graph, not net savings:
  conservative called-name expansion also reaches extra classes. Their raw-IR shares are only 0.060%, 2.19% and 0.189%.
  Abla-one's three alternating baseline/instrumentation-off build pairs produced identical binaries: baseline median
  36.945G instructions / 3.03 s / 496,760 stripped bytes. Its 2,235/102,018 removable IR lines project about 0.066 s
  of build saving (2.19%), below the agreed 5% threshold; all 35 method symbols are already absent after O2.
  Only abla-one loses globals: `oneMemoScope=""`, `oneMemoBuilds=0`, `oneMemoKeys=[]`, `oneMemoEntries=[]`.
  A scratch IR replay replacing the two empty-array initializations saved 64 bytes (496,744 -> 496,680; 0.013%),
  with exact rendered HTML/stdout, below the 2% size threshold. This is an estimate, not a lowering implementation.
  Firmware's shadow graph conservatively keeps everything after `compiler.findFunction(sourceName)` in the
  compile-time metadata helpers in `abla/build`; that is not evidence of arbitrary runtime method reflection.
  Stopped without compiler changes: these inputs do not justify the reachability/drop/CT correctness risk.
  Raw counting pass, inputs, paired measurements and report: `worktrees/ablac-method-demand/build/method-lab/`.
- [ ] Once during `make test` (2026-11-01), `tools/test-ct.sh` saw `python3: No such file or directory`
      and `suite-package-providers` failed to resolve a local git dependency, with neither recurring
      in the next runs. Suspected: the Nix profile changing mid-run. Not confirmed, but during a `home-manager switch`
      on 2026-11-01, `~/.nix-profile/bin/git` was missing for a moment.
- [ ] macOS: `tools/run-limited.sh` starts its payload in a separate process group; SIGKILL of the caller's group can leave that
      payload running. The Linux runner handles its supervisor's parent death when `setpriv` is available. The macOS case has not
      been tested on a Mac.
- [ ] `E_NAMED_ARGUMENT_HIDDEN` remains when a generic constructor also has a delegated property and an omitted default calls a
      constructor hidden by the caller, with no earlier argument giving the type. For example, with
      `class Tagged<T>(val n: int)`, `class Slot<T>(var value: T) { fun getValue(): T = value }`, and
      `class Box<T>(val n: int, val tag: Tagged<T> = Tagged<T>(2), val saved: int by Slot(1))`, a local function named
      `Tagged` hides the constructor in `Box<string>(n = 1)`. Generic probing precedes delegated-property rewriting, so the
      generated wrapper cannot yet safely pass that delegate. Pass `tag` explicitly; renaming the local alone still gives
      `constructor.argument:Box<string>` for this example.
- [ ] macOS: nobody has compared a local rebuild with the published binary, and
      `tools/test-reproducible-elsewhere.sh` skips it (2026-11-01).
- [ ] ARM64 Android tagged pointers: `adoptNativeString` now tests `address != 0`, not `> 0`, but the fix has not been
      run on the affected device. Other runtime address comparisons need the same check (`__ablaRuntimeHostCollection*`
      tables shift addresses arithmetically). abla-mobile's `allowNativeHeapPointerTagging="false"` masks this for its apps.


## Tools (found porting NovaKind's scripts, 2026-10-31)

- [ ] `abla/crypto/hosted` can use an RSA key but not generate one; `abla/crypto/rsa` provides pure key generation.
- [x] `abla/yaml` provides bounded Core-schema parsing, checked emission and comment/format-preserving path edits;
      see [docs/stdlib/yaml.md](docs/stdlib/yaml.md) and the synthetic provision-mail fixture. NovaKind can adopt it after release.
- [ ] `abla-s3` has no list-objects, create-bucket or head-bucket; a tool goes through `bucketRequest` and `sendOnce`, and parses the XML.

## Compiler and stdlib

- [x] **abla-pdf signs through the released `abla/crypto/rsa`** (since its 1a2c416, as abla-saft does). Its
  64c36d1 checks signatures against OpenSSL and against the old signer, byte for byte, on ablac 0.2.45.
- [x] **Encrypted RSA key import:** pure PBES2/PBKDF2 SHA256/SHA1 + AES128/256-CBC PKCS#8 and MAC-verified DER PKCS#12 key bags, with owned passwords and bounded work. Legacy PBES1/RC2/DES and broader PFX formats remain unsupported; see [the scope and limits](docs/stdlib/encrypted-keys.md).
- [x] **Native crypto timing measurements.** Opt-in [tools/ct-timing](tools/ct-timing/README.md) runs pinned
  fixed/random TSC experiments with Welch tests, pooled pilot crops and a required early-exit control.
  [Results](tools/ct-timing/RESULTS.md): no leak detected at 40,000 samples on each of 14 available x86-64
  primitives; this is not a constant-time proof. `tools/test-ct.sh` remains the static assembly check.
- [ ] **Crypto timing on ESP32-S3.** Xtensa is still compiled and read only; no hardware timing campaign exists.
- [ ] **`--fast` builds aren't read by `tools/test-ct.sh`**: the checker stops at their calls. It could follow
  internal calls.
- [ ] **Secret residue is not checked by `tools/test-ct.sh`.** It checks timing-related branches,
  addresses and divisions, not unwiped copies in GC-registered stack temporaries, ordinary
  register spills or the GC heap. AES's discarded conditional exposed such a stack copy;
  removing unused joins does not make general secret lifetime/wiping guarantees.
- [x] **Secret arithmetic around the crypto fixtures:** source-generated AES-128/192/256
  schedule and byte/block I/O, CRT subtract/correction/recombination and wide-reduction glue,
  `bnFromBytes`, `bnToBytes` and `bnResidueSquare` have assembly fixtures and individual
  secret-index negative controls. AES orthogonalization is the actual imported implementation,
  without fixture-only index substitution; excluded scaffolding is guarded against unnoticed edits.
- [ ] **Crypto allocation/call orchestration remains outside `test-ct.sh` coverage:** AES key
  allocation, managed-string address acquisition, hardware decryption-key conversion and hardware
  block dispatch; `rsaCrt` key/modulus
  construction, allocation/free, wide-reduce/encode/decode/exponentiation/multiply/copy calls
  (only their separately tested primitives/glue are covered); `bnFromBytes` and
  `bnResidueSquare`'s initial `bnClear` call. The checker rejects calls and cannot verify those
  whole routines as structured. Neither full loader timing nor secret-memory wiping is claimed.
- [x] **Small constant-array `for` loops avoid materializing an array.** Up to16 homogeneous
  native scalar literals (optionally signed) use a bounded scalar selector and one body copy;
  other/larger arrays keep the ordinary path. Order, capture cells and loop exits are preserved.
  `aesOrthogonalize` now uses this path and its actual helper is checked without index
  substitution. Optimized x86/Xtensa retain its three loops; neither fully unrolls it.

- [ ] The rest of integers up to 256 bits: `uint256` is in (`abla/uint256`, docs/stdlib/uint256.md), with big-endian
      bytes. Left: signed 256, 128 both ways, and little-endian bytes, when something needs them.
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

- [ ] **Transactional memory: partitioned clocks.** Every writing commit takes a version
  from one global clock, so small transactions on many threads queue on its cache line:
  four threads each reading and writing 4 TVars a block take 88 ns a block (wall over all
  blocks) on disjoint TVars and 151 on shared ones, against 52 under one Mutex
  (tests/cases/stm/bench.ab, with TL2's GV4 already sharing a version between commits
  that race for the clock). Clocks per partition of TVars (or per thread, compared as
  vectors) would let disjoint transactions scale.

- [ ] **The rest of the reserved generic syntax.** `where` clauses, `const` type parameters and
  an interface's `type Item` still give `E_PARSE_NOT_YET_SUPPORTED`. Decide which to build.
- [ ] **Module-scoped globals.** A module seeing only its own and its imports' globals would
  need a language-wide migration: measured on 2026-10-19, 102 errors in the compiler's own
  sources and 2061 in a game client written against today's flat namespace. Today the standard
  library never reads a program's globals (`library.program-global`).

## Toolchain and project

- [ ] **Reduce serial compiler release preparation without slowing its output.** Keep the
  selected loop-MSSA/MemCpyOpt pipeline. On 2026-11-03 (LLVM23, frozen b6cda513 + alias fix),
  compact cleanup saved more build work but exceeded the <=0.3% produced-compiler slowdown
  limit. Importing small internal callees as `available_externally` into their calling
  parts, at thresholds16/32/64/128/256/512/1024 IR instructions, did not recover it:

  | Pipeline/import limit | Serial+plan+max worker G instructions | Readers emit | Fib build | Own emit | Stripped size |
  |---|---:|---:|---:|---:|---:|
  | selected control |220.43|−0.22%|0.00%|0.00%|+0.12%|
  | compact, no imports |193.03|+1.97%|+1.32%|+1.46%|−0.78%|
  | compact,64 |192.56|+1.60%|+1.24%|+1.23%|−0.35%|
  | compact,128 |193.16|+1.44%|+1.18%|+1.41%|+0.005%|
  | compact,1024 |198.65|+1.54%|+1.21%|+1.37%|+0.005%|

  Single sequential screening samples against the same stock stage2, not wall-time or final
  paired-median claims; fib includes matched first-link discovery. Frontend IR and fib ELF
  stayed identical. More imports raised total worker work495.35 ->587.85G (128 ->1024)
  without recovering compiler speed; size stayed within +1%. Moving late cleanup after the
  serial inlining CGSCC cost190.11G versus174.28G selected, with different bitcode; its
  produced compiler was not measured. Imports are dropped, not committed. A new approach
  should test cleanup's effect on serial CGSCC inline costs and decisions. Call-graph
  clustering and other reorderings remain unmeasured after this timebox, rather than disproved.

- [ ] **Drop the clean-up of old build transactions** (`bootstrapRemoveOldBuildTransactions` in `src/toolchain.ab`,
  its call in `src/orc_main.ab`, docs/programmable-builds.md) once no compiler up to 0.2.32, which made
  `build/.abla-build-transaction-<pid>`, is in use.
- [ ] **Released toolchains can't target Xtensa.** CI's Nix shell has the patched LLVM
  ([llvm-xtensa.md](docs/llvm-xtensa.md)), but `abla-toolchain-x86_64-linux` bundles
  apt.llvm.org's LLVM from an Ubuntu 22.04 image and the macOS jobs use Homebrew's, neither
  with Xtensa. The Nix-built one needs Nix's glibc 2.44, so Linux would need a build against an
  old glibc, and macOS one built on a Mac of each architecture.
- [ ] **`make test` under 2 minutes after a compiler change too, and its tooling in Abla.** On 2026-11-01 at
  JOBS=30, starting at load 7.5 from other work: 154 s after a compiler change (about 3,850 CPU-seconds),
  115 to 119 s on a rerun with the same compiler (about 2,900; the suite's builds share the default cache, and
  `tools/run-tests.sh` clears it when the compiler changes). The cold run is the one left: this machine's
  8 fast cores and the rest (30 threads) do about 23.5 CPU-seconds a second however they're scheduled
  (JOBS=40, 48, 60: 158 to 162 s, on a quiet machine), so under 2 minutes needs about 2,800 CPU-seconds:
  less work per build. These measurements predate v0.2.31 and master 753d1d10's faster Linux builds; remeasure the full cold suite before using them as a current baseline. Starting test-self-hosted.sh late so it reuses builds saved 190 CPU-seconds and no wall time. A script that sets a compile-affecting `ABLA_*`
  variable or uses compile grants keeps `--no-cache`: the cache key ignores those variables, so a hit
  would pass without testing that mode. Over a whole run: LLVM 45% (`opt` 18% of all CPU), the frontend
  29%, libc 12%. Tried and dropped: glibc malloc tunables (no change); 
  Release builds' `opt`, `clang -flto` and LTO link stay: they are what those tests exercise. `tools/`
  is still 283 shell scripts; `tools/abla-test-driver` already runs `tests/abla-tests.json`, and
  `tools/run-tests.sh` and the scripts should move onto it.
  A script that changes what a build runs (a shim or wrapper on `PATH`, an empty `PATH`) also keeps
  `--no-cache`: a hit would pass without running it. Building the compiler itself: 67 s to about 54 s wall and
  153 to about 108 CPU-seconds on 2026-11-01, by doing only inlining and globalopt before the split;
  most of the rest is the frontend (about 10 s) and that step, both on one core.
  Whole-module O2 or O3 for the compiler itself instead of O1, split and O2 was tried on 2026-11-01: no faster
  (fib's `--emit-llvm` 3.28 G instructions split, 3.42 G O2, 3.28 G O3), and it takes about 120 s on one core.
  Removing unreachable `abla_fn_` functions before opt (local branch `prune-dead-functions`; hello world
  374 to 91) was tried on 2026-11-01 and not landed: release builds of small and mid-sized programs 6 to 19%
  less CPU, but no gain building the compiler (about 120 CPU-seconds either way; it comes out 7% smaller
  and its frontend 5% faster), and json-readers' readInteger 54% slower (16.6 to 25.6 ns), as LLVM inlines
  differently. Removing them after the inlining step keeps run times and saves nothing.
  By script on 2026-11-01 (CPU-seconds, about 4,000 in all with the crypto and SIMD tests): self-hosted
  480, doc-examples 310, ct-bridge 240, gc-growth 214, parity probes 185. Don't build gc-growth's stress
  run optimized: it runs 23x faster because collections move, so it would prove less. The frontend's
  hot spots are its lexer and string comparison, flat. 100 of 1,579 builds take 40% of build time: test
  programs importing the compiler, each compiled from scratch, which is what reuse between builds saves.
- [x] **Tests run on every push to master and on PRs** ([CI](docs/ci.md)): the Linux suite and an
  arm64 macOS host/fixed-point job. Tests only; releases still start by hand.
- [x] **Parser-derived formatter.** `ablac fmt` preserves comments and verbatim syntax,
  checks full AST/token parity and idempotence before atomic writes, and supports stdin,
  `--check` diffs and one line-width setting. See `docs/formatter.md`.
- [x] **Language server.** `abla-lsp` is the separate compiler-backed language server and
  transactional refactoring engine, using protocol 1 over `ablac analyze --stdio`.
  No native LSP adapter or Node dependency belongs in ablac.
- [ ] **Editor analysis integration.** Grow opt-in graph-aware analysis and indexed positional
  queries from the compiler's own parser/type APIs. Update abla-lsp separately after the compiler
  capabilities are validated; use the same parser-derived `ablac fmt` for formatting.
- [ ] **Clean-bootstrap convergence.** Tiers 4 and 5 of `docs/reliability-roadmap.md`: two
  independent bootstrap routes that reach the same canonical compiler IR on fresh builders.
- [ ] **Language editions and a deprecation policy,** and signed package identities above the
  immutable locks, when the ecosystem needs them (`docs/reliability-roadmap.md` section 8).

## Packages

Package-side work (not changed from ablac):

- [ ] **abla-mobile still carries the removed C runtime's path.**
  `runtime/native/CMakeLists.txt` picks it when ablac has `runtime/abla_runtime.c`, removed in
  `93ce196`, so that branch and the C platform layer behind it can go. Verify a complete
  Gradle/NDK build on both architectures.

## Compile time and memory

- [ ] **Cached small blocks cannot be reused for another size.** The native lists
  (`__ablaRuntimeHostSmallLists`) use an adaptive 32 MiB floor and 128 MiB ceiling;
  the compiler explicitly caps them at 32 MiB. A smaller budget does not evict
  blocks already retained on the wrong size's list. Remeasured on `6c69d56c`
  (2026-11-05), three alternating triplets, release binaries, CPU6; GNU time
  `%M`, median MiB, not a sum over processes:

  | Program | Plain malloc/free | 32 MiB cap | Adaptive default |
  | --- | ---: | ---: | ---: |
  | trees | 227.02 | 227.01 | 227.04 |
  | strings | 160.25 | 160.45 | 159.28 |
  | maps | 124.71 | 123.78 | 124.05 |
  | json-readers (3000,100) | 116.77 | 150.75 | 167.87 |
  | json-megabyte (30000) | 183.69 | 266.59 | 215.10 |
  | sizes rising by 8 B, phase by phase | 70.84 | 111.56 | 111.58 |
  | sizes falling by 8 B, phase by phase | 70.71 | 100.43 | 100.42 |

  Synthetic phases retain 500,000 fresh flat strings at each length 8..56,
  release the phase, then collect. Final list walks confirm 32 MiB stranded in
  the first 48/56 B classes when rising, or the first 96 B class when falling.
  Separate unmanaged counters (not used for RSS) measure exact-class misses
  with a free block in either of the next two 8 B classes. Rates, 32 MiB / adaptive:
  trees 0/0%, strings 3.69/2.19%, maps 6.70/6.79%, json-readers 35.95/34.66%,
  json-megabyte 78.85/80.70%, rising phases 0/0%, falling phases 28.57/28.57%.
  A repeatedly visible free head can count many times: these are opportunities,
  not predictions of useful reuse. Reader counts reproduce exactly in repeats.

  Tried and dropped: (1) exact hit first, then at most two larger classes,
  at most 16 B slack; physical capacity in existing unused header+8 (no header
  growth), physical-class return/accounting, logical GC bounds unchanged;
  (2) age trimming after two collections without a class hit, bounded to 8 MiB /
  131,072 free calls per GC, with a rotating cursor; (3) their combination.
  No variant passes. With the adaptive default, fallback adds 2.18% strings
  instructions, trim adds 1.68% trees, and combined adds 2.52% trees / 2.97%
  strings. Megabyte peak rises 215.10 -> 301.36 / 318.44 / 302.98 MiB
  (fallback / trim / combined); reader only falls 167.86 -> 166.22 / 167.86 /
  166.21. At 32 MiB, combined helps megabyte 266.37 -> 189.59 MiB (trim alone
  also helps, to 206.26), but reader rises 150.75 -> 151.22 and trees instructions
  rise 4.49%. Rising-phase peak only falls 111.55 -> 107.75 with trim/combined;
  fallback cannot borrow smaller old blocks. Falling phases improve to 94.95 MiB
  with fallback/combined. Fib/nbody instructions stay within 0.00001%.
  Trimming opposes the adaptive reuse/exhaustion policy: discarding idle lists
  can leave room for a subsequent larger keep budget, while per-hit age tracking
  adds work. The nonlinear RSS is not attributable solely to cached-byte totals.
  Stopped at the failed runtime/RSS gates: no compiler self-build peak, firmware,
  GC-stress or threads success is claimed for these rejected variants.
  Next possible screen: a smaller adaptive floor/ceiling for cycles with high
  unused bytes and little reuse, using existing GC-cycle counters and hysteresis
  instead of per-hit bookkeeping. Merely lowering the budget cannot evict old
  lists; it would also need bounded cap enforcement. Not implemented.
  Prototypes, exact patches, scripts and raw data remain in
  `worktrees/ablac-small-remeasure/build/cache-lab/` (`report.md`, `summary.json`,
  `rss-runs.json`, `probe-{runs,rechecks}.json`, `screen-{runs,summary}.json`).
  Tried and dropped (2026-11-04): a host-only miss-path pool with4KiB pages and a
  strict1MiB reservation, exact-size lists first and libc fallback,16-byte slot strides
  but unchanged32-byte object headers. Fresh NovaKind icons saves11.81% instructions
  for35 vectors and4.19% for140 (five pairs, exact SVGs). MVC instead rises3.52% health,
  1.34% login,0.82% dashboard,0.80% query32 and0.93% invalid-login (three pairs, exact
  bodies); body16k rises0.22%. Five endpoints fail the0.5% regression bar. Stop at that
  gate: JSON/QR/compiler/firmware peaks and comprehensive threads/GC validation were not
  run; no memory-success claim. The native string smoke and its GC-stress run passed.
  Runtime source restored; prototype and raw data retained under
  worktrees/ablac-small-pool/build/pool-lab/{report.md,prototype.patch,summary.json}.
- [ ] **Run times of non-Linux hosted targets aren't measured with the new allocator and root frames.** macOS keeps
  its LTO link (`wholeProgram` is ELF only) and has not been built or run with these changes; Wasm passes the suite,
  its size and speed not compared. An earlier try at size lists on Darwin gained no cycles and raised peak memory.
- [ ] **Strict-imports rechecks loaded standard-library modules on every build.** On 2026-11-03,
  the entire validation cost 41.46M instructions (2.27% of a fib `--fast` build) and
  104.59M (0.56% of a NovaKind tool build); the library-only saving is smaller. Not pursued.
  Narrowing the scan can change diagnostics: it uses all loaded declarations, class members,
  visibility and module order. A safe cache must account for compiler/checker version, all
  ordered module contents, aliases and import/export edges, manifests, target and report mode;
  alternatively cache immutable per-module summaries and recompute against the complete graph.
  Test diagnostics and visibility reports across edits, collisions, alias and target changes.
- [ ] **`abla-compare`'s server builds only a few percent faster than on v0.2.31** (3.9 to 3.8 s,
  2026-11-02): its frontend is about 1.7 s of it and its O2 1.8 s, and neither shrank much.
  On 2026-11-03 its build ran 15% fewer instructions (frontend 6 to 10%, opt and llc 14%).
- [ ] **A map lookup waits on a cache miss** (2026-11-03): 83% of `__ablaRuntimeMapEntry`'s cycles in
  maps are the load of its slot from a 4 MB slot array; fewer instructions in the probe saved
  0.4%. A denser table (32-bit slots, keys' hashes beside them) would miss less. A prototype
  (two 32-bit slots a word, old tables retired at once; worktree ablac-map-dense, report in
  its build/map-lab/report.json) ran maps 30% fewer cycles, but json-megabyte peaked 7.7%
  higher: a smaller live heap moves its collections later, so the peak grows.
- [ ] **`ablac test --o1` costs short suites build time** (2026-11-03): a bundle's build is about
  65% dearer than `--fast`'s (abla-qr: 28 G instructions against 17 G) for tests that run 10x
  faster; a suite of tests that each run in milliseconds is slower than before. `--fast` keeps
  the old profile; the `--o1` pipeline itself hasn't been trimmed as the release one was.
  Codegen-level screen (2026-11-04, three alternating cold pairs): keep LLVM Less. None
  with the same optimized IR cuts PDF build+run instructions 27.6%, but QR's rise 89.7%
  and its stripped executable grows 82%; NovaKind tool builds drop 53% (help smoke only).
  No single default wins: do not add a program heuristic. Worktree ablac-o1-codegen,
  build/codegen-lab/report.md has the raw build/run/size data.
- [ ] **A map is built on boxed generic arrays.** maps spends 21% in `__ablaRuntimeMapEntry`, 12% in
  `abla_map_set`, 17% appending to and setting its parts' arrays (2026-11-02). Since string
  concatenation allocates out of line, maps runs 1.3% more instructions.
- [ ] **A call through a function value calls its wrapper directly only for a capture-free lambda kept
  in a `val`** (`bootstrapLlvmKnownFunctionValue`). A parameter that a caller's inlining makes
  constant still goes through `abla_llvm_call_indirect`'s copy and switch.
- [ ] **A benchmark's cycles can move 20% with the code unchanged.** `fib` at 2026-11-01 is byte-identical machine
  code at another address and takes 20% more cycles. `tools/bench-compare.py` reports instructions for that reason.
  Reproduced 2026-11-04 with string bulk copies: the new `memcpy` import moves fib's
  unchanged recursive body from 0x1de0 to 0x1e40 (start mod64 32 to 0, loop mod64 0 to32).
  Cycles rise 13.3% in five pairs and 18.6% in seven more, with unchanged instructions.
  A scratch link placing both bodies at 0x10620 restores cycles (five pairs: 2.132G vs
  2.136G, +0.19%). Screen release function/loop alignment separately over all13 programs,
  including the size cost of 64-byte alignment; do not tune the string-copy change to fib.
  Evidence: worktrees/ablac-string-copy/build/copy-lab/{report.md,alignment-runs.json}.
  Tried and dropped (2026-11-04): `--align-all-functions=6` (64 bytes) against
  `=5` (32 bytes), both retaining `--align-loops=32`, on 0d5e56ed + string-copy
  4132cb2a with the same frozen stage2 compiler. All16 release builds pass and their
  LLVM-generated function symbols meet the requested alignment; the ordinary CRT-free direct link
  is preserved. Stripped size rises **2.228% median over13 benchmarks**, or **1.919%
  over all16 programs**, failing the 0.5% median bar. These are two forced policies,
  not a claim that the current default aligns every function to32 bytes.

  | Program | 32-byte functions (B) | 64-byte functions (B) | Change |
  | --- | ---: | ---: | ---: |
  | fib | 12,912 | 13,360 | +3.470% |
  | sieve | 15,632 | 16,176 | +3.480% |
  | nbody | 41,296 | 42,096 | +1.937% |
  | trees | 15,024 | 15,536 | +3.408% |
  | strings | 18,288 | 18,992 | +3.850% |
  | maps | 22,256 | 22,896 | +2.876% |
  | dispatch | 16,816 | 17,392 | +3.425% |
  | matrix | 38,736 | 39,472 | +1.900% |
  | websocket-codec | 33,040 | 33,776 | +2.228% |
  | json-readers | 124,728 | 126,456 | +1.385% |
  | json-megabyte | 196,968 | 199,240 | +1.153% |
  | event-http-server | 138,624 | 140,096 | +1.062% |
  | https-client | 126,168 | 127,800 | +1.294% |
  | mvc | 241,984 | 243,968 | +0.820% |
  | qr | 484,016 | 487,568 | +0.734% |
  | icons | 1,146,768 | 1,155,728 | +0.781% |

  The saved-object relink controls add32/64/96 bytes of live read-only padding before
  text while preserving each policy's alignment. No new runtime sweep was started:
  the size bar already fails, so no cycle/variance advantage for64 bytes is claimed.
  The earlier default-policy fib placement control above has five samples per arm.
  Before/after copying: medians2.085/2.458G cycles, sample CV6.64/0.40%; the two
  fixed-placement controls: medians2.132/2.136G, sample CV4.27/7.67%. These data
  isolate placement only, not forced32-vs64 variance. Full size records,
  link commands/objects/controls and the prior variance calculation are in
  worktrees/ablac-align-screen/build/align-lab/. No production setting changed.

- [ ] **Temporaries spanning IR blocks never share a stack slot.** Every IR value that is
  not a scalar gets its own 24-byte slot. A value used only inside one IR block, defined by
  its first access and never a collection root gets `llvm.lifetime` markers, so LLVM can
  overlap those (a release server 1.5% smaller, the compiler 2.4%). The rest still keep
  their own slots: values that cross blocks (a `when`'s arms, a loop's body) and roots,
  whose slot addresses the root frame holds for the whole call. Liveness over the block
  graph (the borrow analysis computes one) would let markers cover the first; roots need
  their frame entry cleared where they die.

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
  frame-time check before it changes anything. Measured again on 2026-10-19 (after value
  lifetimes and fewer safe points), C no longer pays for Wasm: the release client grows
  0.44% (6,167,821 → 6,194,818 B; build 107 → 102 s) and the simulation module is the
  same (−128 B, ticks equal under node). A native release server shrinks 0.55% and links
  9% faster (74 → 67 s) with the same simulation ticks, but the O1 there is where the
  universal ABI wrappers are specialized before they become internal (`ea5d004`: hot
  indirect calls keep their scalars), which a simulation doesn't exercise; it stays.
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
  instead of one `free` each (a Darwin-only symbol: the host runtime serves Linux too).
  Since then the page directory is built from the registry alone, in one pass: an entry
  says whether its allocation is large, so the build reads no header (about 2% less wall
  time for a compiler emitting a large program; the sweep, `free` and madvise are what
  is left).
- [ ] **Name lookups in lowering.** Over a game server's `--emit-llvm` the method index's
  `find` was 200 of 3,552 samples, the declaration index's 148 and the name hashes 98 and
  76. Done: the method index hashes owner and name in place instead of a key string made
  per lookup, and the slot hash is FNV-1a (an xor and a multiply a byte; a word at a time
  would need the string's bytes flat, a rope's are not): about 4% of that `--emit-llvm`.
  (The runtime operation per opcode is a table, and the borrow liveness resolves successor
  blocks once.) The declaration index's `find`, counted per call site with a temporary
  counting build (2026-10-19): 1,001,428 lookups per server `--emit-llvm`, 49% repeating
  the site's previous name. The largest are runtime-operation marking (164k, 12% repeats),
  the current owner's declaration while lowering a method (66k, 100%), class and scalar
  checks (66k, 54%), field types (58k, 62%), globals (52k, 69%) and function result types
  (42k + 34k, 73%). Remembering the repeats would save about 1.5–2% of that emit (0.1 s),
  within the timing noise, so nothing changed; the one clean candidate, if lowering ever
  needs it, is caching the current owner's declaration while a method lowers. A sample of
  a compiler built without `-g` names functions
  `abla_fn_<a>_<b>`; the compiler's own `--emit-llvm` maps each to its source name
  through the function's `"abla.source"` attribute.

## Tried, not pursued

- **Further user-release O2 trimming** (2026-11-04, LLVM23, master827d288a):
  14 configurations were screened with the actual held-module compiler on NovaKind's
  tool, the MVC server and QR; promising ones then reached the 13 benchmarks.
  Only the two late SROAs passed the strict runtime +0.3% / size +0.5% bars:
  all 16 whole executables are byte-identical. Their removal is implemented;
  O2 work falls 0.652% / 0.457% / 0.391% on NovaKind / MVC / QR, whole-build
  instructions 0.337% / 0.199% / 0.181% in the cold screen. Keep both early SROAs.
  Other screens, with O2 deltas in the same NovaKind / MVC / QR order:

  | Removal | O2 instructions | Result |
  |---|---|---|
  | Final InstCombine | -2.37% / -2.41% / -2.68% | Sampled runtimes pass, but fib 12,696 -> 12,760 bytes (+0.5040958%, 64 bytes) misses the size bar; combining late SROAs does not cure it. |
  | Post-GVN InstCombine | -3.20% / -3.87% / -3.53% | Nbody +2.3748% instructions in three alternating pairs; real-program gates alone had passed. |
  | CGSCC EarlyCSE-MemSSA | -2.25% / -1.93% / -1.00% | QR reader +0.793%, NovaKind icon conversion +5.419% instructions. |
  | Last JumpThreading | -1.12% / -1.07% / -1.14% | QR size +0.540% exceeds the bar. |
  | MemCpyOpt | -1.48% / +1.38% / +0.67% | Removing it creates more downstream work on MVC and QR. |
  | Final SROA alone | -0.24% / -0.15% / -0.20% | Exact executables on all three; included in the combined cleanup. |
  | Late CGSCC SROA alone | -0.39% / -0.28% / -0.20% | Exact executables on all three; included in the combined cleanup. |
  | Last VectorCombine | -0.18% / -0.15% / -0.23% | Small gross saving, changed code; not promoted. |
  | AggressiveInstCombine | -0.47% / -0.54% / -0.25% | Small gross saving, changed code; not promoted. |
  | Post-inline function attributes | -0.44% / +0.39% / -0.48% | Mixed small result; not promoted. |
  | DFAJumpThreading | -0.01% / -0.02% / +0.07% | Exact executables, no useful build gain. |
  | LoopSink | +0.03% / +0.01% / +0.13% | Exact executables, no build gain. |

  Runtime coverage: the 11 standard runnable benchmarks, QR's nine cases,
  six MVC HTTP workloads (including a 16 KiB POST), and NovaKind's help and
  conversion of 35 real Android vector icons without DB/S3. Not every rejected
  candidate reached every runtime gate; no unmeasured parity is claimed.
  Known earlier GVN/indvars/SLP/first-SROA/tail-call losses were not repeated.
  External `opt` replay is only for pass CPU attribution: bitcode use-list order
  and local-name context change some decisions from the held C API. Candidates
  used the actual compiler with a scratch pass override and fresh caches.
  JSON benchmark clock/rate fields must be normalized for output comparisons;
  keep counts, booleans and errors. Shared-load wall/cycles are not a gain claim.
  Raw report: `worktrees/ablac-user-o2-screen/build/o2-lab/report.md`, with
  pipeline files, payload/input provenance, per-case counters and binaries.

- **Interface dispatch after LLVM inlining** (2026-11-04, `fbc4effa`):
  the dispatch benchmark runs 90 M calls in 3.512 G instructions. Its three
  steady paths take 40/37/40 instructions (39 on average); no calls or
  allocations remain in the hot loop. Precise-distribution sampling gives
  `Shape.area` 22.43% self / 45.95% inclusive, matching the assembly counts
  (22.22% / 46.15%). The earlier generic `instructions/upp` attribution of
  40.49% / 62.62% overrepresented branches; use this CPU's
  `inst_retired.prec_dist` for per-instruction attribution. LLVM already shares
  the tag/null checks and descriptor loads across all three `ObjectIs` tests;
  a class-key/switch-only change would not recover those costs again.
  Two candidates remain: preserve exact-constructor provenance for immutable,
  noncaptured, non-affine interface locals (`val s: Shape = Square(n)` still
  dispatches), keeping declared type/borrow/drop metadata separate; or move
  the receiver's four hot box stores into the cold slow-get/no-witness paths,
  preserving GC roots (10.25% whole-benchmark instruction upper bound).
  Concrete and `is`-refined calls already go directly to their witness; a sole
  implementer still retains its guard/fallback, even for a sealed interface.
  Park both ideas: the benchmark is genuinely polymorphic, other benchmark
  sources have no interface methods, and no server gain was established.
  Read-only probes, sampling controls and the proposal:
  `worktrees/ablac-dispatch-report/build/dispatch-lab/report.md`.

- **Remaining QR template bounds/kind checks after scalar array getters**
  (2026-11-03, `8111ac68`): extra post-inline LICM leaves `templateScore`'s
  complete executable byte-identical: no cheap check recovery. Across all
  functions it saves 2.95% reader instructions and 1.85% median cycles but
  adds 2.43% O1 build work; geometry-only saves 2.07%, chiefly arithmetic
  motion. Keep the checks and the current O1 pipeline. Raw scoped controls:
  `worktrees/ablac-test-profile/build/qr-licm-lab/report.md`.

- **Remaining native `--fast` boolean FastISel fallbacks** (2026-11-03,
  after `c7f021de`): a scratch post-fast pass widened all 386 boolean selects
  to i8 and added zeroext to 188 known i1-returning definitions and 1,989
  direct calls, without changing signatures. It removed the intended misses
  (629 to 112 body blocks; 616 argument fallbacks unchanged), but three
  alternating cold NovaKind tool builds used 20.436 to 20.300 G instructions
  (-0.67%, below the 2% bar), peak +0.02%, fast size +0.69%. No production
  legalization or ABI change retained. Raw hook, counters and replay checks:
  `worktrees/ablac-fast-nova-profile/build/fast-bool-lab/`.

- **Telling LLVM a class-typed field holds an object.** A read of a
  field whose type is a class that is neither optional nor affine was followed by
  `llvm.assume(address != 0)`, so what reads the object next could drop its null check
  (branch ct/noalias-params, 657395e). Every producer fills such fields (constructors,
  the compile-time lift, assignment), and only affine fields can be moved out. On a
  game's simulation it made no measurable difference, alone or on top of the
  field-slot alias tags (native 42/42 us a tick with mobs, WebAssembly within 1%). An
  `assume` would turn any producer missed later (extension fields with defaults,
  generics) into undefined behaviour instead of a trap, so it isn't worth carrying.
