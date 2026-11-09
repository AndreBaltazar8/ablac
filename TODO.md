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
- The `worktrees/ablac-*` paths cited below were removed on 2026-11-07. Their text evidence
  is in `~/archive/ablac-cleanup-2026-11-07/evidence/<worktree>.tgz`, uncommitted prototypes
  in `dirty/`, and every branch in `ablac-all-refs.bundle` (see that directory's README).
- Any bug or error seen goes here right away, even if it looks minor or unrelated, with what
  was seen and how to reproduce it. Don't only mention it in a report.
- Keep the measurements on performance items, and what was tried and dropped, so nobody
  repeats the work. Date them: they go stale.

## Bugs seen

- [ ] **A contract import does not carry a class its module reaches only through another module
  (NovaKind report 98, #698).** `import contract "api.ab"` where `api.ab` imports `mid.ab`, `mid.ab`
  imports `lib.ab`, and `lib.ab` declares `class Payload`, with `@server fun remote(): Payload` in `api.ab`:
  the client sees `Payload` as a nominal type (`compilerFindType` answers) but there is no declaration
  (`compilerFindClass` and `compilerTypeDeclaration` answer -1, `compilerTypeModuleIdentity` is `""`), so
  `Payload(42)` in the client fails `call.target:Payload`. Cause: `bootstrapContractImportRequired`
  (src/module.ab) follows a contract module's import only when the module it imports *directly* declares a
  class its shape mentions; `mid.ab` declares none, so `loadContract` stops there and `lib.ab` is never
  loaded. In NovaKind it surfaces in abla-one's `oneRemoteCodec` (`compilerFindClass(head) < 0`) as 3,312
  errors, a hidden value that "can't cross the network"; abla-one now says which import is missing
  (remote-hidden-class). Workaround: import the class's module in `api.ab` itself. A minimal repro is four
  files (`lib.ab`: `class TransitivePayload(val value: int)`; `mid.ab`: imports it, `fun transitiveMid() =
  TransitivePayload(42)`; `api.ab`: imports `mid.ab`, `@rpc fun remote(): TransitivePayload`; `main.ab`:
  `import contract "api.ab" as api` and `TransitivePayload(42).value`): v0.2.51 and master give
  `call.target:TransitivePayload`. **Tried:** following a non-aliased import transitively when a module it
  reaches declares a mentioned class (`contractReaches`, the shapes carried down through `loadContract`).
  The repro builds and returns 42, but NovaKind's client build then fails with 7 `interface.missing-member`
  errors (`OneApp.render`/`receive` on `NovaKindLanding`, `NovaKindRecoveredApp`, `NovaKindRecoveredLanding`,
  `XmlSink.write` on `NovaKindSaftSink`): the walk loads modules as contract copies (classes without their
  methods) before the app's ordinary import loads them in full. A fix has to load only the module that
  declares the class, skip modules the program loads in full anyway, and keep the contract-first and
  ordinary-first registration orders (tests/cases/contract-registration). The patch is not kept.

- [x] **Master's Linux job failed from e031754a to 66d3dfec (2026-11-07), two flakes.** (1)
  `tests/cases/run-limited/parent-death.py`: the worker wrote `parent` once `child` existed, but
  the child creates that file empty before writing its pid, so the test read `''`
  (CI 42422564852, `suite-limited-runner`); fixed in 66d3dfec. (2) `test-jit-host-selection`:
  `modules/filesystem` exited 6, the `watchFile` check (CI 42425955626, `suite/84.log`); it
  passed in 42428033368 and locally. Not a coarse clock: that runner is 7.0.0-1017-azure
  (image ubuntu-24.04 20261101.360.1) and 200 back-to-back stat'd writes gave 200 distinct
  mtimes. Likely cause, unproven: the kernel's multigrain timestamps hand a fine stamp only to a
  file whose mtime was read since its last change, and `writeTextAtomic` renames in a new file
  that nobody has read, so it gets the coarse stamp, which can equal the old file's when both
  land in one tick. `watchFile` compared only the mtime; it now also compares size, inode and
  ctime. If `modules/filesystem` exits 6 or 7 again after that, the cause is not this.

- [ ] Additional `--fast` ELF sections: LLVM's in-process C API ignores
  `--function-sections`/`--data-sections` set through its command-line parser.
  A manual section screen moved relocated constants out of RELRO and is unsafe.
  Paired one-core builds changed fib 128,696 to 98,984 bytes (2.277 to 2.286
  billion instructions), JSON readers 494,952 to 467,536 (7.451 to 7.485
  billion), and NovaKind's tool 2,674,576 to 2,824,680 (31.794 to 32.779
  billion). Revisit only with LLVM-correct relocation and section rules.

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
- [x] macOS published-binary comparison: independent v0.2.47 tag rebuilds from its pinned
      v0.2.46 seed matched both raw assets byte-for-byte on macos-15 arm64 and
      macos-15-intel (2026-11-06, CI 42158176059). The opt-in CI input
      `macos_published_rebuild` retains toolchain provenance and strict Mach-O diagnostics;
      see docs/bootstrap.md. No normalization or signature exception was needed.
- [ ] ARM64 Android tagged pointers: runtime/stdlib address checks are corrected and
      deliberately tagged AArch64 TBI fixtures pass release/fast (CI42169396786;
      docs/design/android-tagged-pointer-audit.md). Collector ordering/extents are
      unsigned and page shifts logical; TLS control pointers use the -1 sentinel;
      RSA public range/alias guards ignore tag bits without changing actual pointers.
      On-device validation and dropping Mobile's `allowNativeHeapPointerTagging="false"`
      remain NovaKind's gate; no MTE or Android TLS interop claim from emulation.
      Compiler-host-only `ctNativeCheckedAddress` would need host-architecture gating
      if an ARM64 tagged-heap host compiler ever ships.


- [ ] **`tools/fuzz-differential` findings** (2026-11-08; branch `fuzz-differential`). The fuzzer builds
  random well-typed programs (integers of every width with wrapping and shift edges, `f64`/`f32`,
  strings and interpolation, arrays, maps, classes, closures, `if`/`when`/loops, `any` erasure and
  equality) and runs them under native `--fast`, native release, the compile-time evaluator
  (`ABLA_COMPILE_EVAL=interp` and `jit`, every check behind `#`) and hostless Wasm (release and
  development modules, node). Found so far: (1) equality through `any` of two NaNs was false in the
  interpreter (IEEE) and true natively, in the JIT and in Wasm (payload bits); NaN sign and payload
  from arithmetic are unspecified, so bit equality was mode-dependent. Resolved by `any-eq-ieee`
  (erased floats of one kind compare as typed `==`); regression
  `tests/cases/fuzz-differential/any-nan-equality.ab` (also checks forms through array, field, `when`,
  f32 versus its bits). (2) In a `compile fun`, `f32(1.5)` fails with `E_EVAL_EXPRESSION` (call `f32`),
  and f32 `0.0 / 0.0` fails with `E_EVAL_DIVISION_BY_ZERO` where f64 gives NaN; both run natively
  (found by ablac-45). Open: whatever later campaigns report is listed here with its minimised
  program under `tests/cases/fuzz-differential/`. Campaign of seeds 13 to 20 (30 checks each, 6 modes):
  every disagreement was this one class, equality through `any` between a float and something else:
  `anyEq(-0.0, 0.0)` (native false, interpreter true), `anyEq(f64FromInt(1), 4607182418800017408)`
  (native true, interpreter false), `anyEq(f64ToF32(0.0), 0)` (native true, interpreter false), NaN with
  itself and with a payload. They are decided (a float never equals an integer, bec6dfcf; same-kind floats compare as typed `==`,
  `any-eq-ieee`) and kept as `tests/cases/fuzz-differential/any-mixed-kinds.ab`.
  After both: seeds 21 to 28 and 29 to 40 (30 checks each, six modes, 600 checks) agree; the generator
  does not yet draw `f32(literal)` conversions or f32 division by zero (the two open evaluator gaps above).
  Grown 2026-11-08 (branch `fuzz-grow`): checks for integer conversions between every width pair and
  float-to-integer saturation, generics (`Box<T>`, `Pair<A, B>`, generic functions over int, f64, string,
  u8, i32), interfaces with a default method and dynamic dispatch, nullable chains (`?.`, `??`, `when` on
  null, `int?`), Unicode strings (slices that cut a sequence, byte reads, ordering, iteration), and one
  panicking program per seed (index, slice, division, remainder, `filledArray`, `truncate`, `panic`: native
  and WebAssembly must print `before`, report `panic` on standard error and end with status 101). The
  language has no exceptions or recover, so a panic is the only failure to compare. Campaigns: seeds
  100 to 125 (older compiler, no `any`), 200 to 225, 300 to 351 and 400 to 451 (24 to 30 checks each, six
  modes plus the panic programs; 156 seeds, 4,368 checks): no disagreement. Seeds 400 to 451 also draw
  `f32(literal)` and f32 division edges (ablac-e5's evaluator fixes, 570b6462).
  Grown again (branch `fuzz-grow2`): arrays (append, index store, truncate, nested rows, `filledArray`,
  string arrays), `Map<string, int>` and `Map<int, int>` (set, get, has, remove, insertion-order `keys` and
  `values`, clear), and lambdas (captured counters, function values in arrays, `applyTwice`). Seeds 500 to
  535 (30 checks, six modes): no disagreement. Finding (evaluator, fixed by ablac-e5 in closure-eval,
  a1a06ad3): a lambda that called another lambda it captured failed under `#` with E_EVAL_EXPRESSION
  ("evaluating `call` `g`"); the evaluator boxes captured bindings and `evaluateCall` did not look through
  the box. Regression: `tests/cases/fuzz-differential/captured-closure-calls.ab`; the closure generator now
  draws `compose` and `{ x -> g(f(x)) + calls }`. Also drawn: sealed interfaces with an exhaustive `when`
  over `is` arms, and `for` over `until` and `..` ranges (empty, reversed, negative bounds).
  Seeds 600 to 620 clean with the sealed and range generators. Grown a third time (branch `fuzz-grow4`):
  `abla/regex` (compile errors, `matches`, `find`, `findAll` spans, `replace`) at run time and under `#`;
  seeds 701 to 720 (10 regex checks among them) agree in all six modes. There are no stepped ranges in the
  language, and class field mutation was already drawn (`Acc.total`).
  Fourth growth (branch `fuzz-grow5`): `abla/text` (search, `split`, `trim*`, `replace`, case, `pad*`,
  `repeat`, code point count, `codePointAt`, `codePointSlice`, `isValidUtf8`) over a pool with multibyte
  text, at run time and under `#`; seeds 901 to 920 agree in all six modes. The `any`, generic, interface
  and nullable generators are ablac-e5's; seeds 800+ are theirs, 900+ mine.
  Fifth growth (branch `fuzz-grow6`): `removeAt`, `removeLast` and `clear` on int and string arrays, and
  string arrays built from `split`; seeds 931 to 950 agree in all six modes with the v0.2.52 compiler. A
  first run with a pre-#703 compiler failed seeds 944 and 950 with the LLVM `fcmp` operand-type error: an
  `any` holding `u8(1)` or `true` compared with a float literal, which is #703, already fixed.
  Sixth growth (branch `fuzz-grow7`): optional values inside collections (`array<int?>`, `array<string?>`,
  `Map<string, int?>` with `??`, `!= null` and `has` against `get`); seeds 961 to 1010 agree in all six
  modes with the v0.2.52 compiler, and that range draws every generator together (ablac-e5's deep generic,
  interface, nullable and `any` ones included).

## Tools (found porting NovaKind's scripts, 2026-10-31)

- [ ] **Abla-native Xtensa companion installer.** The explicit optional installer uses only the Python
  standard library until `abla/compression` can inflate gzip and read tar with bounded, safe extraction.
  Move it to Abla once those archive primitives exist; keep checksum and manifest verification.
- [x] `abla/yaml` provides bounded Core-schema parsing, checked emission and comment/format-preserving path edits;
      see [docs/stdlib/yaml.md](docs/stdlib/yaml.md) and the synthetic provision-mail fixture. NovaKind can adopt it after release.

## Compiler and stdlib

- [x] **abla-pdf signs through the released `abla/crypto/rsa`** (since its 1a2c416, as abla-saft does). Its
  64c36d1 checks signatures against OpenSSL and against the old signer, byte for byte, on ablac 0.2.45.
- [x] **Encrypted RSA key import:** pure PBES2/PBKDF2 SHA256/SHA1 + AES128/256-CBC PKCS#8 and MAC-verified DER PKCS#12 key bags, with owned passwords and bounded work. Legacy PBES1/RC2/DES and broader PFX formats remain unsupported; see [the scope and limits](docs/stdlib/encrypted-keys.md).
- [x] **Native crypto timing measurements.** Opt-in [tools/ct-timing](tools/ct-timing/README.md) runs pinned
  fixed/random TSC experiments with Welch tests, pooled pilot crops and a required early-exit control.
  [Results](tools/ct-timing/RESULTS.md): no leak detected at 40,000 samples on each of 14 available x86-64
  primitives; this is not a constant-time proof. `tools/test-ct.sh` remains the static assembly check.
- [ ] **Crypto timing on ESP32-S3.** Xtensa is still compiled and read only; no hardware timing campaign exists.
- [ ] **`--fast` builds are read on every target; the Xtensa one is partly unplaced.** `tools/test-ct.sh` builds the fixture
  object with `--fast` and the checker follows every call into its callee (`--follow-calls`; recursion, indirect calls
  and callees outside the object still fail), with controls for a leak and for a secret stored through a pointer inside
  a callee. A fast build keeps what release removes, so `tests/cases/ct/fast-known.txt` lists the fixtures that fail on
  x86-64: the type-tag check of every erased scalar conversion (`__ablaRuntimeRequire`, which the checker can't tell
  from payload) and divisions by a secret that aren't strength-reduced. **AArch64** follows `bl` and tail calls (arguments
  per x0 to x7 and v0 to v7, results in x0, x1 and the vector registers, x19 and up kept, a frame address passed makes the
  frame's slots secret after the call), names stack slots by their distance below the entry stack pointer so `sp`- and
  `x29`-relative accesses to one byte agree, and reads the `--fast` object with all 64 fixtures clean
  (`fast-known-aarch64.txt` is empty). **Wasm** follows `call <function index>` (the module's types, imports and
  bodies are read from the binary; arguments off the operand stack with their taint, results back on it; imports and
  `call_indirect` are refused), looks fixtures up by export name when the module has no name section, and reads the
  `--fast` module with all 63 fixtures clean; that module only builds through the compiler's text route
  (`ABLA_KEEP_LLVM_TEXT=1`): the in-process one aborts on the constant-time barrier's inline assembly ("Inline asm not
  supported by this streamer"), a compiler bug to fix after the v0.2.52 freeze. **Xtensa** follows windowed
  `call4/8/12` (the callee is named by the call's relocation, or by the literal a long call loads; the window
  registers come back from a(rotation+2); compiler-rt arithmetic helpers such as `__moddi3` are accepted with public
  operands, a secret shift count is refused (the helpers branch on `count >= 32`), and `__muldi3` relies on the core's
  32-bit multiplier, which the ESP32 and ESP32-S3 have), tracks a frame register (`mov a7, a1` and `addi`/`add` of constants) so an unoptimised frame is addressed
  exactly, reads the AES key functions and bignum routines with calls followed, and reads the `--fast` object: 47 fixtures
  clean, 16 listed in `fast-known-xtensa.txt` as `unplaced` (the unoptimised bignum code indexes frame arrays at
  offsets the checker can't place, and what it loads from there reads as secret; those 16 are blind in the fast build,
  and their release read is the real check). Hand-written controls for all three:
  `follow-a64.s`, `follow-wasm.s`, `follow-xtensa.s`.
- [ ] **Secret residue is checked for stack slots on x86-64 release only.** `--residue` fails an entry that returns with a
  secret in a slot of its frame, or that gave a secret to a callee and didn't wipe the stack below it
  (`abla/ct/scrub`; the checker reads the callees' depth and the size of the wipe). Every fixture's residue entry
  (`@noinline` worker, then the wipe) passes, and `residue-known.txt` has no entries. The AES and RSA private entry
  points (including key reading, export and generation) and the password entries of `abla/crypto/pbe`
  (`cryptoPassword`, `pbeOpenPkcs8`, `pbeOpenPkcs12`) call the wipe and are run against it (the run scan reads an
  encrypted PKCS#8 (SHA-256 and SHA-1 PRF, AES-128 and -256, 3072- and 4096-bit keys) and a PKCS#12 (SHA-256 and SHA-1 MAC), each with the right password, a wrong one, a truncated input and a changed last byte; without the wipes the first three leave 704, 1,024 and 2,784 bytes). A panic inside an entry leaves the process and is not wiped. Not checked: registers (measured once: after `aesCbcEncryptPkcs7` returns, xmm0-15 hold only the constant masks 0x10, 0xff and 0x2f, no key or text bytes; the static checker can't read the real entries' registers, since they branch on secrets by design, and the fixtures return only their result in rax), the GC heap,
  Wasm (no native stack to wipe) and Xtensa, and the `--fast` build. AArch64 is read like x86-64 (a secret left in a slot at `ret`, a callee's frames no wipe covered; the wipe is recognised only as exactly the `ctScrubStack` loop): 64 fixture entries clean and six hand controls in `residue-a64.s`; the real entry points are not run on AArch64.
- [x] **Secret arithmetic around the crypto fixtures:** source-generated AES-128/192/256
  schedule and byte/block I/O, CRT subtract/correction/recombination and wide-reduction glue,
  `bnFromBytes`, `bnToBytes` and `bnResidueSquare` have assembly fixtures and individual
  secret-index negative controls. AES orthogonalization is the actual imported implementation,
  without fixture-only index substitution; excluded scaffolding is guarded against unnoticed edits.
- [ ] **Crypto allocation and object plumbing stays outside `test-ct.sh`.** Read whole now, on every target (x86-64,
  AArch64, Wasm and Xtensa) with the calls between them followed, each with a secret-indexed twin that is found: `bnFromBytes` and `bnResidueSquare`
  with their `bnClear`; and AES's key schedule, bitsliced round keys and hardware decryption keys (`aesExpandSchedule`,
  `aesDecryptionKeys`) and its hardware block loops (`aesHardwareEncryptAt`, `aesHardwareDecryptAt`), which are
  functions of plain integers appended from the production source (the region between BEGIN/END AES KEY EXPANSION);
  the same specs are refused without following. Not read: (1) AES's key allocation, key object and a managed
  string's address (`aesAllocateMemory`, `aesNewKey`, `aesStringAddress`), which are given nothing secret and carry a
  source hash and a no-`declassify` assertion in the generator, so a change there is a reviewed one; (2) `rsaCrt`: its
  `BnModulus` and key objects, `bnAllocate`/release and the order of calls around primitives that are fixtures
  themselves, with the same hash and no-`declassify` assertions (`rsaCrt`, `rsaModulusFromLimbs`, `rsaReduceWide`).
  They are not read because the checker takes every load it cannot place in the frame for a secret, and an object's
  fields, the runtime's counters and a call's result slot are loads like any other. Tried: not following the
  runtime's allocator and collector (a `--opaque` rule for functions given only public arguments); it still fails on
  the collector's pressure check and on reading a call's result slot, neither of which is a secret. What would close it
  is typed or tagged public loads (object fields, a result slot). Until then the type system covers that text (no
  branch, index or division from a secret, `declassify` the only way out), and a branch the compiler itself adds there
  is not read. The checker gained two precisions for this: `cqto` defines `rdx` from `rax` (a stale secret in `rdx`
  was a false "secret division", which also shrinks `fast-known.txt` by its eight division entries), and a call to
  `abla_platform_panic` is not followed (it ends the program) but must be given nothing secret. Neither full loader
  timing nor secret-memory wiping is claimed.
- [x] **Small constant-array `for` loops avoid materializing an array.** Up to16 homogeneous
  native scalar literals (optionally signed) use a bounded scalar selector and one body copy;
  other/larger arrays keep the ordinary path. Order, capture cells and loop exits are preserved.
  `aesOrthogonalize` now uses this path and its actual helper is checked without index
  substitution. Optimized x86/Xtensa retain its three loops; neither fully unrolls it.

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

- [ ] **Transactional memory: clocks beyond the region.** A logged transaction now runs the
  single-clock protocol on the clock of its first 1 KB region (sixteen clocks, region & 15) and keeps
  a snapshot for each clock only once it touches a second region
  (`docs/measurements/stm-hybrid-clocks-2026-11-08.md`). Four threads on disjoint TVars take 58% less
  time per block (cycles −55%) when each thread's TVars were made apart from the others', and 12% less
  (cycles −23%) when sixteen TVars were made one after the other, a thread's group of four straddling a
  region boundary or sharing a region with its neighbour; shared TVars show no gain beyond noise. The costs: a forced-logged
  one-thread block executes 7.9% more instructions (1,241 to 1,339; its cycles are the baseline's to
  within noise) and a transaction that touches a second region pays the partitioned protocol's
  per-clock sampling. Open: a block over TVars made together can still straddle two regions (it then
  samples two clocks, and neighbours that share a region share its clock); a region size that follows
  the allocator's size classes, or counting a TVar's region at creation, would keep a structure's
  TVars on one clock. The partitioned-only prototype that cost a logged block 30% more is on
  branch `stm-clocks`.

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
  Screened again 2026-11-08 for a byte-identical gain. `opt -time-passes` of
  `BOOTSTRAP_COMPILER_RELEASE_PASSES` over the compiler's own IR (22 MB of bitcode) took 24.2 s on one P-core
  under load; shares of that run: SROA 15.0%, the inliner 14.8%, InstCombine 9.4%, bitcode writing 8.6%
  (the one output write), EarlyCSE 7.6%, AlwaysInliner 7.3%, SimplifyCFG 6.1%, IPSCCP 4.4%, LICM 4.4%,
  GlobalOpt 3.4%, MemCpyOpt 3.0%, the verifier 2.3%. Output is byte-identical with `-disable-verify`
  (17,884,212 B both) for this input; that saves at most 2.3% and drops the check that catches a bad pass, so it
  is under the 10% bar and not worth the trade. Separate wall times of that command (30.4 and 33.9 s with the
  verifier, 33.2 and 24.8 s without) are load noise. How much of the inliner's 14.8% is cleanup inside the
  CGSCC was not measured separately; it is at most that, and the compact pipeline above (−12.4% of serial
  instructions) is the only variant that reached 10%, but it changes the bitcode. A byte-identical 10% would need
  the serial passes' work to shrink or to run in parallel, which these measurements don't show. Not pursued.

- [ ] **Drop the clean-up of old build transactions** (`bootstrapRemoveOldBuildTransactions` in `src/toolchain.ab`,
  its call in `src/orc_main.ab`, docs/programmable-builds.md) once no compiler up to 0.2.32, which made
  `build/.abla-build-transaction-<pid>`, is in use.
  Checked 2026-11-08: NovaKind's `gateway/toolchain/ablac-version` is still 0.2.32, so it stays until
  that moves (NovaKind's call). The abla-cli, abla-mjml, abla-qr and abla-saft CI pins moved to 0.2.50
  the same day (their CI steps pass with it); abla-s3's is 0.2.45, NovaKind's main pin 0.2.48.
- [ ] **Released toolchains can't target Xtensa.** CI's Nix shell has the patched LLVM
  ([llvm-xtensa.md](docs/llvm-xtensa.md)), but `abla-toolchain-x86_64-linux` bundles
  stock LLVM and the macOS jobs use Homebrew's, without the private Xtensa patches. The old Nix-built one needs Nix's glibc 2.44; a separate glibc 2.35 companion
  and native companions for both Macs are now published. Target-specific source routing is
  validated; release packaging with that compiler is still pending.
  #575 phases 1–2 (2026-11-06): [optional revision 23.1.3-1 is published](https://github.com/AndreBaltazar8/llvm-project/releases/tag/abla-xtensa-llvm-23.1.3-1)
  for Linux and both Macs; branch `feat-xtensa-companion` implements explicit verified installation.
  Source is `a2549329`; all three builds and clean Ubuntu 22.04 pass the Nix assembly/direct/optimized
  object hashes. Canonical catalog pins the published archive and manifest hashes. The installer
  passed all three hosts on both unpublished and
  [published inputs](https://github.com/AndreBaltazar8/ablac/actions/runs/42269233930), including real
  stat-preserved libLLVM tamper negatives. Phases 1–2 merged as `dffc60aa`. Phase 3 is
  implemented on `feat-xtensa-routing`, with a compiled SDK-density stage, explicit
  opt-out and build manifest, target-local tool/cache identity, static relocation and
  source-level literal alignment. Its 558 firmware bodies, alignments and 2,005
  normalized relocations match the SDK wrapper; package-import passes the 4 GiB cap.
  Final gates pass: stages 1–3 byte-identical, local and Linux CI 329/329, macOS
  host/fixed-point/Simulator green, four NovaKind DB-free programs, and the real
  installed firmware under 4 GiB. Default density is whole-object SDK-exact;
  opt-out matches every relocated field and links to identical bytes (L32R
  placeholder bits may differ). Source routing merged at `4b944cfc`. Phase 4 also
  passes the unmodified full embedded checker with the published portable cohort
  selected (21 fresh manifests; peak 3,152,424 KiB), plus a separate SDK-exact
  package-import build (3,137,848 KiB); both use the 4 GiB launcher and verify the
  cohort before/after. v0.2.48 does not contain routing. See
  [design and evidence](docs/design/xtensa-companion.md).
- [ ] **v0.2.49 release-note draft: Xtensa migration (planned break).** Publish this
  with the release; v0.2.48 does not implement the new routing:

  > Xtensa codegen now requires the optional companion; the former PATH-wrapper route is gone, and a missing cohort gives `E_XTENSA_LLVM_MISSING`.
  > Install explicitly with `<toolchain>/bin/abla-install-xtensa --version 23.1.3-1`; builds never download it automatically.
  > For source/custom setups set `ABLA_XTENSA_LLVM_ROOT=<cohort-root>` containing `manifest.json`, `bin/` and `lib/`; the updated ablac Nix shell already exports its store cohort.
  > Select `ABLA_ESP_CPU=esp32`, `esp32s2` or `esp32s3` (default `esp32`); extra LLVM features use `ABLA_XTENSA_FEATURES=+name,-name` (QEMU: `-mul32high`), not hidden llc wrapper flags.
  > `ABLA_XTENSA_NARROW=0` disables the extra SDK instruction narrowing, keeping literal placement/alignment repair; ESP-IDF and GNU boot/vector assembly/link tools remain separate requirements.

  **Exact abla-embedded setup changes** (checked against `da5a939`; this does not
  edit that repository):
  - Its current Makefile already runs Abla compilation through
    `nix-shell $(ABLA_PROJECT_ROOT)/shell.nix`. Point `ABLA_PROJECT_ROOT` at the
    updated ablac checkout and use its rebuilt compiler. No object recipe or
    new PATH entry is required: that shell's hook supplies
    `ABLA_XTENSA_LLVM_ROOT` unless an explicit value is already exported.
    For a non-default compiler checkout, also set `ABLA_COMPILER_ROOT` to the
    same checkout for `tools/check-source` (which uses that distinct variable).
  - Its own `shell.nix` is an ESP SDK shell, not ablac's compiler shell. A caller
    building there directly must either use a released toolchain with the
    companion installed next to its actual compiler image, or export
    `ABLA_XTENSA_LLVM_ROOT` to the manifested cohort before invoking Abla.
    If a Makefile runs the installer, make it an explicit setup target, never
    an automatic download in a build recipe. A source checkout can run
    `python3 <ablac>/tools/install-xtensa-llvm.py --toolchain-root <prefix> --version 23.1.3-1`
    and export `<prefix>/lib/abla/xtensa-llvm/current` as the cohort root.
  - Preserve the existing per-example `ABLA_ESP_CPU` selection in
    `tools/build-example`; export any feature mask and `ABLA_XTENSA_NARROW`
    through the shell/Make invocation as well. A flag injected only by
    `tools/esp-llvm-bin/llc` no longer affects Abla's Xtensa path. Do not point
    `ABLA_LLVM_TOOLS` at the companion or prepend its private tools globally.
  - Keep `ABLA_ESP_LLVM_ROOT`, ESP-IDF setup, `tools/idf-project` and the SDK
    PATH wrappers for their separate GNU-as/link, RISC-V and direct-tool uses;
    `ABLA_ESP_LLVM_ROOT` is **not** the companion root. The full `make check`
    still uses ablac's development shell: its direct SDK-wrapper self-test
    needs patched `llvm-mc`, which the opt/llc/libLLVM-only companion does not ship.

  NovaKind final gate assertion counts: android-plan **52**, tool-rebuild **23**,
  native-build-roots **2**, operation-log-unit **31**, total **108**. The runner's
  raw result fields 53/24/3/31 include the first three PASS-summary lines;
  those are not extra assertions.
- [ ] **Compiler GC trigger sensitivity at normalize → semantic.** A +0.84 MB parse
  increase in the Xtensa routing source moves normalization across a collection:
  `parse.normalize.end` is about 339 MB before, 168 MB after. High runs already
  retain another 50–60 MB before annotations (253–257 MB versus 196–200 MB),
  continuing to module-end (about 600–609 MB versus 550 MB). Frozen old/new
  compilers produce identical IR on each input; either shows the high mode under
  contention. CI three-round medians for old/new input are 1,496,012/1,548,292 KiB;
  local medians 1,297,016/1,319,716 KiB. Investigate collection placement without
  adding per-node state or trading frontend CPU for an RSS-only win. See
  [paired CI evidence](https://github.com/AndreBaltazar8/ablac/actions/runs/42297453462).
  Mechanism found 2026-11-08 (master `edfce209`, v0.2.50 seed, `--emit-llvm src/orc_main.ab` of the
  `dffc60aa` tree, 8 identical runs with `ABLA_COMPILER_MEMORY_TRACE=1`, per-stage markers added
  temporarily to `bootstrapPreSemanticPipeline`): 3 of 8 runs end at 1.50 GB and 5 at 1.40 GB. They
  are identical until `parse.normalize.end` (the first pressure collection falls inside normalization:
  309.5 MB to 160 MB, every run). The pre-semantic pipeline then runs the generics stage (160 to 344 MB)
  and expected types (to 385 MB) without a collection, and the next pressure collection (threshold the
  kept 160 MB plus the 256 MiB step) falls inside the overloads stage: it keeps 180-188 MB in five runs
  and 236-241 MB in three, so the high mode is a ~55 MB structure the overloads stage builds (live
  or not at the instant the step is crossed), and the heap stays that much larger to module end. The
  stages before it allocate within ±1 MB from run to run, enough to move the crossing across that
  structure, so a new input only changes how often. Tried (not kept; commit `774eb066` on branch
  `gc-pre-overloads`): collecting between expected types and overloads when the heap is at least
  256 MiB and twice what parsing kept: the high mode is gone (old input, six runs each: 1,337-1,447 MB with the
  change, median 1,433, against 1,388-1,505 MB, median 1,403, without it, where four runs were in the
  low mode and two at 1.50 GB; new input: 1,428-1,458 against 1,400-1,522), the emitted IR is identical,
  the self-build is 0.8% fewer instructions (66.78 G vs 67.29 G, five alternating runs), but the median
  peak rises 2.1%, the baseline's low mode being its best case, so the bar (median lower) is not met. Six
  runs an arm is thin: the gap is within the baseline's own 1.40/1.50 GB spread. A better fix would shorten what the overloads stage holds, not move the collection.
- **Peak RSS swings with where a collection falls in the program's phases, not with the trigger (#677,
  recorded as a no-go for a trigger or marking fix).** (2026-11-09, master `0eaf983e`, branch
  `gc-schedule`.) `tests/benchmarks/json-megabyte.ab` at 170000, same binary and input: 912 MB in
  five of six runs and 1,946 MB in the sixth with address randomisation, 911.7 MB in eight of eight
  under `setarch -R`. The collection traces (tracked live bytes before and after each pressure
  collection, plus the bytes each root slot and each block layout marked) show why. The program holds
  one 338 MB parse tree at a time (`jsonParse` four times in a row, each previous tree dead once the
  next result is assigned). A collection at 495 MB tracked live either falls where the previous tree
  is already dead and the next not yet built (kept 157: roots 15 + 13 MB and the 128 MB text) or in the
  middle of the next parse, where that tree is live (kept 495: the `jsonParse` frame's slot holds
  338 MB). Nothing is retained wrongly: every marked byte is reachable from a rooted frame slot. The
  next threshold is live + half of live (742 MB), so the second case lets the following tree start
  over a heap that cannot be collected before 742 MB, and the peak is about 1.9 GB RSS. The ~1 MB of
  allocation that differs between runs (nothing in the benchmark is address dependent in what it keeps;
  the amount allocated before the collection differs slightly, so the collection lands on one side or
  the other) moves the crossing. Peak RSS also runs about 40% above tracked live (free lists, malloc
  fragmentation, the collector's tables). Tried as trigger changes (not kept; `ABLA_GC_RATIO` and
  `ABLA_GC_RETRY` knobs, commits on `gc-schedule`): (1) growth of 25% or 12% of live instead of 50%:
  the spread stays about ±25% across input sizes 140k to 180k (912 to 1,610 MB at 50%, 937 to 1,564 MB
  at 25%) and json-megabyte costs +5.8% (25%) and +9% (12%) instructions (trees, strings and maps do
  not change: small live heaps); (2) a second collection after a step of 12% or 25% of live when a
  collection of a heap of at least 128 MiB freed under 10%: removes the high mode on one build (1,101
  to 1,153 MB in 14 of 14 runs, against 1,900 in 9 of 14) but is +3.2% instructions, turns another
  build's stable 890 MB into 1,101 (12%) or 1,214 to 1,835 (25%), gave 2,149 MB in two of sixteen runs
  elsewhere (the others 1,237 to 1,245 against 1,389 to 1,421), and leaves the compiler's 1.41 to
  1.54 GB bimodality unchanged (8 runs each). A non-moving mark-sweep collector with a proportional
  trigger has this sawtooth by construction; only a trigger that collects after every few percent of
  growth (the instructions above) or knowing the program's phases would flatten it. Judge a runtime
  allocation cut (ablac-e5's to-string cut, +7% peak at 50%) by instructions and by the peak's median
  over many runs, not by one run.
- [ ] **Move Xtensa density legalization into companion 23.1.3-2.** The phase-3
  compiler stage mirrors the SDK's exact narrow encodings because `-mcpu=esp32`
  and explicit `+density` still leave 5,211 bytes across 199 firmware sections.
  Keep its frozen-script text differential until native selection replaces it.
  LLVM's inline-assembly literal creation must also set section alignment to 4
  (L32R requirement); normal compiler literal pools already do. Remove the
  compiler legalization only when all firmware bodies and alignments match.
- [ ] **Xtensa companion workflow publishing needs owner credentials.** In this fork, the manual
  workflow's `GITHUB_TOKEN` with Contents: write receives HTTP 403 creating a release, including after
  the exact source tag already exists. Revision 1 was published from the verified artifacts with the
  owner's token (draft then undraft, `--latest=false`). Wire an explicitly approved owner credential
  or retain that manual step; do not rebuild LLVM or weaken the three-platform gates to republish.
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
  Remeasured on master `8ccd7bb4` (2026-11-08), a stage1 compiler built from the v0.2.49
  seed, cold cache, `taskset -c 0-7`, JOBS=8, on a machine at load 12 to 16 from other work,
  in four chunks so each slot hold stayed under 10 minutes (the cache carries over between
  chunks): 331 commands, all passed, 277 s wall and 1,648 CPU-seconds in all (chunks
  `test-[a-c]` 84 s / 556 CPU-s, `[d-h]` 57 / 310, `[i-o]` 54 / 278, the rest 82 / 504).
  That is less than half the 3,850 above; at the 23.5 CPU-seconds a second this machine does
  with every core, it is about 70 s of wall time, so the 2-minute goal is met on a quiet
  machine and the 8-CPU slot is what takes longer. The longest commands (seconds, under
  contention): test-bignum-secret 71 (two `--no-cache` builds of one program, fast and
  release, plus an AArch64 build), test-ct 42, test-reproducible-elsewhere 42,
  test-json-ascii-spans 40, test-crypto-pure 39, test-compiler-memory-peak 36, test-uint256 34,
  test-crypto 34; the sum of every command's wall time is 1,657 s, so none is a serial
  bottleneck at JOBS=8.
  Critical path of the default `make test`, 2026-11-08. Run A: master `04aa6c7d` plus the step-4 test-driver
  moves, JOBS=30, 308 commands, 326 s wall and 2,050 CPU-seconds (the sum of `results.tsv`'s CPU column)
  at a load average of 30 to 50 from other work, so a command's wall time includes waiting for cores. Its
  longest commands (wall s, CPU-s in parentheses): test-bignum-secret 237 (54), test-ct 218 (43),
  test-json-ascii-spans 189 (114), test-uint256 165 (29), test-compiler-memory-peak 136 (25),
  test-reproducible-elsewhere 133 (82), test-crypto-pure 121 (54). The JOBS=8 figures above (277 s, 1,648
  CPU-seconds, 220 s as 1,750 over 8 CPUs) are the earlier chunked run, a different load. Timed alone in a
  slot (`taskset -c 0-7`, the installed v0.2.50 compiler, cold cache): test-bignum-secret 39.0 s wall for 38.9
  CPU-seconds, a short serial chain, so its 237 s in run A was waiting for cores; running its four independent
  sections side by side took 26.7 s (-31%) for 53.8 CPU-seconds (+38%), which only adds load to a CPU-bound
  suite, so it was not kept. test-self-hosted alone: 63 s wall and 216 CPU-seconds for 118 tests at 8 jobs;
  native-bootstrap-sema, the test with the longest wall time in it (61 s), is one `ablac build` of the sema
  module that takes 19.8 s wall (45.4 CPU-s) release, 24.9 s (25.3) `--o1` and 4.5 s (6.1) `--fast` when it
  has the machine to itself, and its program runs in 0.0 s: the 61 s was it sharing 8 CPUs with 117 other
  builds, and 216 CPU-seconds over 8 jobs is 27 s however the tests are cut. Splitting the driver cannot
  shorten it, and building that one test `--fast` would save 39 CPU-seconds (1.9% of run A) while taking the
  release pipeline off the largest program the driver builds: not changed. The seven suite scripts that wait
  for it (`serial_reason` in `tools/run-tests.sh`: they share build directories with its `suite-*` entries)
  took 45 s of wall time and 10 CPU-seconds in run A, the longest 20 s (test-borrow-lifetimes), and they are not
  duplicates to delete: five of them (borrow-lifetimes, eval-steps, floating-point, local-shadowing,
  nominal-scalars) are in `tools/test-fast-builds.txt`, so the recipe builds them at `--fast` and the driver
  entry builds them for release. On a quiet 32-thread machine the tail is then about 27 s of driver plus 20 s
  of those scripts, against a whole-suite CPU bound of 2,050 / 23.5 (the CPU-seconds a second this machine does
  with every core, above) = 87 s: the suite is CPU-bound there too, so the way to a shorter run is less CPU,
  as above. Not pursued.
  By CPU (2026-11-08, `tools/run-tests.sh` now records each command's user and system seconds
  as the fifth column of `results.tsv`; cold cache, JOBS=8, four chunks, 332 commands, 1,754
  CPU-seconds): test-self-hosted 95, test-reproducible-elsewhere 94, test-ct-bridge 91,
  test-doc-examples 71, test-bignum-secret 54, test-gc-growth 54, test-crypto-pure 51,
  test-math-v8 43, test-transactions 43, the compile-time parity probes 40, test-json-ascii-spans 36,
  test-uint256 31 and test-project-path-symbols 31. The top 15 are 791 CPU-seconds and the top 40
  1,196: a flat tail. Getting to 960 (under 2 minutes at JOBS=8 on CPUs 0-7) needs about 40% less
  CPU, and checking the biggest for duplicated work found little to share: test-bignum-secret's
  builds are two different programs, each in fast and release; test-self-hosted's 89 tests build
  distinct programs, and the seven of its `suite-*` entries that rerun a script also in the recipe
  (borrow-lifetimes, floating-point, nominal-scalars, unsafe-stack-memory, local-shadowing,
  eval-steps, borrow-duplicates) cost about 13 CPU-seconds; test-reproducible-elsewhere builds
  two things to compare them, so both builds are the test. Stripping `--no-cache` from
  test-uint256 gave 22.0 and 14.8 CPU-seconds against 18.5 and 25.0 as written: inside one
  suite run each program and flag set is built once, so the cache shares little. What is left
  is the cost of each compile (LLVM is 45%), a separate item.
  Fast-build screen of the biggest scripts outside `tools/test-fast-builds.txt` (2026-11-08, each run alone in a
  slot with `taskset -c 0-7`, the compiler `make ablac` builds from master `3fce16e3`, CPU-seconds release against
  `ABLA_TEST_FAST_BUILDS=1`, all passing both ways): doc-examples 70.8 / 23.8, generics 18.0 / 12.8, yaml 13.5 /
  10.7, affine-move 18.0 / 16.1, uint256 27.2 / 25.0, json-limits 23.9 / 24.6, crypto-encrypted-rsa 27.5 /
  32.9, math-v8 39.9 / 51.2, transactions 28.4 / 56.1: a program that computes a lot costs more unoptimised.
  Moved onto the list: doc-examples, generics, yaml and affine-move (they check what programs compute and
  what the compiler reports, not release code). In a default suite run their CPU went 69.5 / 19.2 / 21.4 / 18.9
  to 27.2 / 13.9 / 19.9 / 17.9 (129.0 to 78.9, -50.1 CPU-seconds); suite totals between runs differ by more than
  that (master changed in between), so the saving is per script: 50.1 of a cold-cache suite of 1,920 CPU-seconds
  (about 2.6%), under the 5% this lever was meant to reach. The release builds of the four still run in `make test-full` (4 passed). Left out:
  uint256 (explicit modes, 2 CPU-s), json-ascii-spans 114 CPU-s (word scans in optimised code),
  reproducible-elsewhere 82 (builds twice to compare), crypto-pure 54, bignum-secret 54 and ct 43 (release output
  or explicit modes), compiler-memory-peak 25.
  CI runs `make test`, so the release builds of the moved scripts run in the release process's `make test-full`
  gate (run by hand), not on every push, as for the 78 scripts already on the list.
- [x] **Tests run on every push to master and on PRs** ([CI](docs/ci.md)): the Linux suite and an
  arm64 macOS host/fixed-point job. Tests only; releases still start by hand.
- [x] **Parser-derived formatter.** `ablac fmt` preserves comments and verbatim syntax,
  checks full AST/token parity and idempotence before atomic writes, and supports stdin,
  `--check` diffs and one line-width setting. See `docs/formatter.md`.
- [x] **Language server.** `abla-lsp` is the separate compiler-backed language server and
  transactional refactoring engine, using protocol 1 over `ablac analyze --stdio`.
  No native LSP adapter or Node dependency belongs in ablac.
  Duplicate builds across scripts, 2026-11-09 (master `544efc82`, stage1 built from the v0.2.49 seed; every compiler
  call of one full run logged through a wrapper passed as the compiler to `tools/run-tests.sh`: parent script, `ABLA_*`
  environment, arguments with the `-o` value removed, source-file hash; `JOBS=8`, cold cache, calls made by other
  compilers inside `test-self-hosted.sh` not seen): 2,479 `build` calls, 2,334 distinct (source, flags,
  environment) keys, so 145 repeats (5.8%). Only 16 repeats are across different scripts (14 keys): the four
  `--no-cache` hosted builds that `test-build-removed-outputs.sh` and `test-sidecar.sh` share, two invalid-program
  diagnostics shared by `test-diagnostic-hints.sh` and `test-null-operators.sh`, `math-v8/interface.ab`
  (`test-math-fast.sh`, `test-math-v8.sh`), `rsa-keygen/generate.ab` (`test-crypto.sh`, `test-crypto-pure.sh`) and
  six single-source programs the driver builds that a shell script builds again. The other 129 repeats are one script
  building the same thing again on purpose: `test-codegen-cache-race.sh` (30), `test-discovery-cache.sh`,
  `test-build-killed.sh`, `test-compile-effects.sh`, the fuzzer: scripts that test the cache or the build itself.
  1,371 of the 2,479 calls carry `--no-cache` (55%), so a shared cache would not reach them. A suite-wide cache
  for identical (source, flags) builds would save about 0.4% to 0.8% of the builds depending on the key (the key above:
  source hash, arguments without the `-o` value, `ABLA_*` environment; re-derived by ablac-f3 with 2,338 distinct
  keys, and with the `.ab` paths dropped 20 cross-script repeats), not CPU-weighted, but the shared ones are
  small cases: a measured no-go, nothing changed. The suite's CPU is in distinct builds (the
  frontend and LLVM per program), which is the compile-cost work above, not in repeats.
- [ ] **Editor analysis integration.** Grow opt-in graph-aware analysis and indexed positional
  queries from the compiler's own parser/type APIs. Update abla-lsp separately after the compiler
  capabilities are validated; use the same parser-derived `ablac fmt` for formatting.
- [ ] **Clean-bootstrap convergence.** Tiers 4 and 5 of `docs/reliability-roadmap.md`: two
  independent bootstrap routes that reach the same canonical compiler IR on fresh builders.
  Bounded first gate: manual Linux `bootstrap-convergence.yml` compares the pinned
  v0.2.45 route with v0.2.44 through the v0.2.45 source tag, raw pre-prune IR at
  identical logical paths, fixed points, provenance and compiler objects/binaries.
  This is historical-seed convergence within one lineage; an independent translator
  and target-independent maintenance remain open, as do both roadmap tiers.
- [ ] **Language editions and a deprecation policy,** and signed package identities above the
  immutable locks, when the ecosystem needs them (`docs/reliability-roadmap.md` section 8).

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
  Screened 2026-11-08 (`docs/measurements/small-block-lists-screen-2026-11-08.md`, patch beside it): a
  lower floor (16, 8, 4 MiB), trimming the lists to the new budget at each collection, and freeing every list
  that saw no hit since the last sweep (its head unchanged, no per-hit cost). A lower floor costs trees
  +15% to +49% instructions, strings +31% to +45%, maps +11% to +18%, and gets json-readers 168 to 143 MiB
  (-14.9%, floor 8) for +5.2% instructions; trim changes nothing, freeing unhit lists changes json-readers by
  0 MiB and raises json-megabyte 218 to 298 MiB. No variant passes; not pursued. What would still be open is
  a signal that separates json-readers' use of its lists from trees' without a per-hit counter.
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
- [ ] **Non-Linux runtime baselines remain incomplete.** macOS arm64/Intel now have five-run
  v0.2.45→v0.2.47 runtime/RSS/size measurements (2026-11-06, CI42159997472;
  docs/macos-runtime-measurements.md plus checked-in raw data). Median-time geomeans
  +1.42%/−0.59%, all individual timing ranges overlap; JSON peaks broadly flat.
  Shared Darwin adapter growth adds 448–464 B on arm64, 456–4,560 B on Intel (page thresholds).
  This pair already contains the allocator/root-frame work in both arms, so its
  original pre-change baseline remains unmeasured. v0.2.47→v0.2.51 on the same runners
  (2026-11-09, CI42612637080, same page): median geomeans +1.63% arm64 / +0.71% Intel,
  every range overlapping; trees is up on both (+10.8% / +14.9%, as on Wasm below), maps' peak RSS
  +9.4% / +12.3% (Intel maps binary +4,096 B, arm64 https-client +16,512 B), nothing else beyond noise.
  The benchmark job takes the two tags as dispatch inputs. Wasm now has a baseline too:
  [docs/wasm-runtime-measurements.md](docs/wasm-runtime-measurements.md) (v0.2.45 to v0.2.51, eight programs under Node,
  nine to 25 rounds): sizes +1.5% at v0.2.50 and +3.4% at v0.2.51 (geomean), `trees` +10 to 20% in run time at v0.2.51 and
  back to v0.2.50's on master after the native null test, the rest inside the noise; tool in `tools/wasm-bench`.
  The other non-Linux targets still lack comparisons. No optimization
  selected from this noisy measurement. An earlier Darwin size-list try gained no
  cycles and raised peak memory.
- [ ] **Strict-imports rechecks loaded standard-library modules on every build.** On 2026-11-03,
  the entire validation cost 41.46M instructions (2.27% of a fib `--fast` build) and
  104.59M (0.56% of a NovaKind tool build); the library-only saving is smaller. Not pursued.
  Remeasured 2026-11-08 on master `7ec1bdf4` as the most any cache could win: a compiler with a
  switch that returns from `bootstrapValidateStrictImports` before any work (every module of the
  standard library is strict, so the check runs in every build), user instructions of `build --fast
  --no-cache` on one P-core, three alternating pairs, best of each: fib 1,287.7 M against 1,261.1 M
  (-2.06%), maps 1,441.4 against 1,415.7 (-1.78%), string-helpers 1,901.6 against 1,869.3 (-1.70%),
  json-megabyte 5,077.7 against 5,016.1 (-1.21%). Even deleting the whole check stays under the 2%
  bar on three of the four programs, and a cache that must be keyed on the compiler, every module's
  contents, aliases, edges, manifests, target and report mode, and still runs for the program's own
  modules, would win a fraction of that: a measured no-go, nothing changed. (Both columns are the best of
  three, whole-build `instructions:u`, so each drop is the check's work plus its allocation and the collector
  pressure that goes with it; a cache's lookup and key hashing cost something too, so its real ceiling is a
  little below these drops.)
  Narrowing the scan can change diagnostics: it uses all loaded declarations, class members,
  visibility and module order. A safe cache must account for compiler/checker version, all
  ordered module contents, aliases and import/export edges, manifests, target and report mode;
  alternatively cache immutable per-module summaries and recompute against the complete graph.
  Test diagnostics and visibility reports across edits, collisions, alias and target changes.
- [ ] **`abla-compare`'s server builds only a few percent faster than on v0.2.31** (3.9 to 3.8 s,
  2026-11-02): its frontend is about 1.7 s of it and its O2 1.8 s, and neither shrank much.
  On 2026-11-03 its build ran 15% fewer instructions (frontend 6 to 10%, opt and llc 14%).
- [ ] **`abla-compare` headers-32 is slower with one worker** (2026-11-06):
  217,171 requests/s versus Zig's 255,180; Abla leads by 8% with six workers.
  A last-byte case-folded rejection filter before full header-name comparison
  passed differential, native, JIT, GC-stress and Wasm tests but had no clear
  speed win. Three alternating baseline/candidate pairs were 180,330/195,325,
  187,947/178,417 and 177,240/183,638 requests/s (+8.32%, -5.07%, +3.61%);
  ratio of medians +1.83%. Admission load was 11.34 (one-minute load average).
  At that load a three-pair screen cannot resolve effects under about 5%; other
  scenarios were not measured. Rejected patch and raw samples are in
  `worktrees/ablac-headers-32/build/headers-lab/`. No larger header-summary
  rewrite is planned for now.
- [ ] **`abla-compare` one-worker parameter routing trails Zig** (2026-11-06):
  parameters measured 276,924 versus 308,076 requests/s. The locked abla-web
  `webNoEscapeRoute` and stdlib `HttpRouter` both use `httpMatchPath`; the
  direct web routes do not have a precompiled route object. A bounded native
  segment-scan prototype retained the checked matcher for compile time and
  passed matcher/capture/precedence differential, GC-stress and hostless Wasm
  tests. On 2026-11-07, three alternating pairs gave median gains of 1.81%
  (parameters), 2.77% (parameters-16) and 1.54% (route-tail-128). Other
  scenario ratios of medians included context -4.22%, json-int64 -6.04%, and
  body-1k -4.87%; grouped samples may include drift, so those drops are not
  attributed to the change. They exceed the noise gate, so this is a no-go.
  Full samples, baseline/candidate binaries and the uncommitted prototype are
  in `worktrees/ablac-route-match` (`build/route-lab/measurement.json`).
- [ ] **A map lookup waits on a cache miss** (2026-11-03): 83% of `__ablaRuntimeMapEntry`'s cycles in
  maps are the load of its slot from a 4 MB slot array. Slots are now 32-bit (two to an i64
  element: entry + 1 in the mask's bits, the hash's upper bits above them as a mark), halving the
  array. 2026-11-08, wall time on a pinned core: maps 0.220 s to 0.197 s (-10.5%); json-megabyte
  peak RSS +1.5% (the earlier 64-bit-to-two-slot prototype was +7.7%), time unchanged. Cycles and
  instructions still wait for a projects-e8 fair window. Instructions (bench-compare, 3 rounds):
  maps -9.3%, every other case within +-0.1%. maps' peak RSS is +12.2% (127 to 142 MB) though
  nothing is retained: tracked live after a forced collection is lower (6.6 against 8.8 MB at
  150000 entries), and with collections off its peak is 15% lower (177 against 210 MB). The
  program ends within one growth step of its first collection; the new layout allocates fewer
  bytes per entry, so that collection comes later in the run, when more is live. Other
  benchmarks' peaks move -0.5% to +1.6%.
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
  concatenation allocates out of line, maps runs 1.3% more instructions. 2026-11-08: the entry
  arrays already store int keys and values densely (an array takes its first element's kind), so
  only string keys and boxed values pay 24 bytes an entry; a dense string kind would need the
  collector to scan it, so the parts stay generic arrays. Instead a probe reads a key where it
  sits (boxed or dense) without building a value, a set hashes its key once, and the entry
  arrays append and store through inline in-place cases: maps -14.0% instructions and -15.6% cycles
  (best of 9, one P-core) against the packed slots alone; json-megabyte -0.7% / -2.0%; peaks
  within 0.5%. Compile cost: maps +5.7% instructions, json-megabyte +0.9%, stripped size +4.9% / +0.7%.
- [ ] **A call through a function value calls its wrapper directly only for a capture-free lambda kept
  in a `val`** (`bootstrapLlvmKnownFunctionValue`). A parameter that a caller's inlining makes
  constant still goes through `abla_llvm_call_indirect`'s copy and switch.
  Screened 2026-11-08 (v0.2.50's `--emit-llvm`, counting `call` sites of `abla_llvm_call_indirect` that
  `bootstrapLlvmKnownFunctionValue` does not already make direct): the compiler has 5 (3 in
  `bootstrapEmitPartitionedObject`, 2 in `bootstrapNativeBuildWithEmitterStateCache`: a few calls per
  build); the abla-compare server 7 (`webNoEscapeRoute`, `webInvokeScopedMiddleware` twice, the router's
  `dispatch`, `HttpEventServer` slot processing, a bearer-auth lambda), the websocket load server 9
  (`WebSocketServer` tls and release paths); `perf/dispatch.ab` (its `weigh` lambda is a `val`, so already
  direct), the other seven `perf/` benchmarks, `json-megabyte`, `json-readers` and `websocket-codec` have none.
  The server sites take handlers out of tables or fields, which are not provably one function, and a
  profile of the compiler's `--fast` self-build (every 20 M instructions) has no sample in the
  dispatcher at all. Under 1% on every benchmark and the self-build, below the bar, so nothing changed.
  I did not run the servers under load (the websocket harness needs its Bun client); their sites are the
  unprovable kind.
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
  Screened 2026-11-08 (master `3ceffa02`, v0.2.49 seed, stage1 with a temporary switch that lets a
  non-root value touched in several blocks take its markers from its first to its last access in
  instruction order, which is an upper bound: it ignores loops and branches, so real liveness keeps
  slots at least as long): the stripped compiler built with the switch is 7,605,840 bytes against
  7,606,192 (-0.005%), the websocket echo server 93,808 against 93,840 (-0.03%), and the compiler's
  `sub $n,%rsp` frame bytes over its 2,368 functions 757,520 against 764,624 (-0.93%). So block-graph
  liveness for non-root values would free under 1% of frame bytes and almost no code, below the
  bars (1% of size, 5% of peak stack); the switch is not kept and nothing changed. Roots, which hold
  most of the slots across blocks, are the part left, and need their frame entry cleared where they die.

Measured on a 10K-function Wasm application (86 MB of LLVM IR). Its dev build's compiler,
collecting each time its heap grows by 256 MiB, peaks at about 1 GB and takes about 28 CPU
seconds (88 G cycles); never collecting, it takes about 24 (73 G cycles) and peaks at
10 GB. (Plain globals for the root frame until threads are enabled were tried: 5% faster
compiler, 1% slower fixed-step simulation; branch `perf/compile-memory-v2`.) Not yet done:

- [ ] **Where a `--fast` build's CPU goes** (2026-11-08, master `8cbb4a67`, stage1 from the v0.2.49 seed,
  `perf record -e instructions:u -c 400000 --inherit` of `build --fast --no-cache`; a function's
  `abla_fn_` name maps to its source name through the `"abla.source"` attribute of the compiler's own
  `--emit-llvm src/orc_main.ab`). `tests/cases/modules/unsafe-boundary.ab` and
  `examples/websocket-echo-server.ab` (about 3.6 G instructions each) split alike: the compiler's own code
  58 to 59%, in-process LLVM (opt and FastISel code generation together) 27%, libc (malloc, memset) 7 to 8%,
  the separate clang and ld.lld processes under 5%. Inside the compiler's share: runtime helpers 17 to 18%
  (`__ablaRuntimeStringBytesEqual` 4 to 5%, `ArrayAppend` plus `ArrayAppendGrowing` 4.5%,
  `ObjectBlock`/`AllocateOutOfLine` 2.5%, `MapEntry` 1%), module/hash/text utilities 8.5 to 10%
  (`bootstrapTextContains` 1.2 to 2%, the name hash 1.5 to 1.8%, the declaration index's `find` 1 to 1.5%),
  the parser 5%, the lexer 1.4 to 2%, the analyzer 2 to 5%, IR lowering 3 to 4%, the LLVM emission on the
  ablac side 4 to 5%. libLLVM itself is flat: no symbol over 1%. Nothing reaches 5% alone, so a 5% cut on
  `--fast` programs needs several of these together or a structural change (reusing the frontend's work on
  the standard library between builds). Done from it: `bootstrapReadRunningImageIdentity` hashed the 8.3 MB
  compiler image a word at a time with two modulo steps per word (1.3 to 1.6% of a build); two words a step
  gives the same two residues with half the divisions: 3,559.7 M to 3,550.8 M and 3,637.5 M to 3,628.3 M
  instructions (-0.25% each, three alternating runs; the executables are byte-identical).
  Screened 2026-11-08 (`docs/measurements/native-fast-screen-2026-11-08.md`): the in-process passes
  (`mem2reg`, `simplifycfg`) are 0.2% to 2.5% of the LLVM time and dropping them moves code generation by +7%,
  +6.6% and −11% on three programs; FastISel at -O0 is the cheapest code generator (SelectionDAG +34% to +62%,
  -O1 +156% to +190%); the DWARF line tables `--fast` carries by default are 7% to 9% of a build (up to 15% in a first run)
  (`--no-debug`: 9% to 17% smaller executables). Adding `sroa` or `instcombine` to `mem2reg` and `simplifycfg`
  changes the pair's total by +0.2% and -0.4% (`map`), -20.3% and -7.7% (`unsafe-boundary`), -1.4% and -0.8%
  (`string-helpers`). No setting reaches 10% on the small programs; not pursued.
  Call-site screen 2026-11-08 (master `3fce16e3`, a `-g` release compiler, `perf record --call-graph dwarf` at one
  sample per 1 M instructions of a `--fast` build of `unsafe-boundary.ab` (4.0 G) and per 20 M of the compiler's own
  `--fast` self-build (83.7 G); the DWARF inline frames name the source function; the two recordings are kept in
  `~/archive/ablac-callsites-2026-11-09/`): in the small build
  `__ablaRuntimeStringBytesEqual` is 3.6% with no caller above 0.2% (type-name comparisons in sema), `ArrayAppend`
  1.6% + 1.1% growing (the lexer 0.30%, `bootstrapLlvmEmitFunction` 0.18%), and `bootstrapTextContains` 2.2%, of which
  `bootstrapFloatBridgeMustPreload` (a scan of every module's whole source for "compiler", twice, with no stop at
  the first hit) 0.70%, `bootstrapCompileBuiltinEffect` 0.58%, `bootstrapCompileExternalEffect` 0.23%. In the
  self-build the same helpers are 3.0%, 2.3% + 0.9% and 0.6%, the biggest single call site 0.56% (`ArrayAppend` from
  `bootstrapLlvmEmitFunction`), `malloc`/`free` about 9% and the collector (`MemoryCollect`, marking) about 7.6%:
  no single site above 0.56%, so 3% would take about six such sites. Done: `bootstrapTextContains` calls `textFindSequence` (the tuned scan, same result)
  and the preload check scans once and stops at the first hit. Stage-1 compilers of master and of the change,
  `build --fast --no-cache`, user instructions, best of 2 to 3 alternating runs, outputs byte-identical: fib 1.288 G
  to 1.263 G (-1.93%), maps 1.442 to 1.417 (-1.74%), unsafe-boundary 3.656 to 3.557 (-2.70%), the self-build
  83.702 to 83.370 (-0.40%). The bar was 3% of the self-build: not met; the small builds, which the suite is made of, gain
  about 2%. (`bootstrapReadRunningImageIdentity` reads as 4.5% in the `-g` profile only because that image is 24.8 MB;
  the release compiler's is 8.3 MB.) One of two candidate stage-1 builds, run through the v0.2.50 seed, crashed at
  the 4 GiB address-space limit (`[abla-limit] process crashed`) and the rerun passed, the peak sensitivity above.
  Peak RSS of three stage-1 builds each through that seed (`ru_maxrss`, KiB): master at the v0.2.51 pin 1,420,024,
  1,513,132 and 1,412,392, the change 1,517,412, 1,407,812 and 1,417,600: both show the 1.41 and 1.51 GB modes
  of the item above, and the medians are 1,420,024 and 1,417,600 (-0.2%): no sign that the change raises the peak.
  The change's gate (stage 2 == stage 3, `make self-rebuild`, suite 312/312) ran before its rebase onto the pin;
  batch 2's combined gate on master (stage 2 == stage 3, self-rebuild, 317/317) covers the merged tip.
- [ ] **Reuse the frontend's work on the standard library between builds** (parked 2026-11-08). In the profile
  above the compiler's own code is 58 to 59% of a `--fast` build and the standard library's modules are
  most of what a small program imports, so lexing, parsing, analyzing and lowering them again each
  build is the largest block left. My estimate, not a measurement: if a build could load their analyzed
  and lowered form from a cache keyed on the module's sources and the compiler, a small program would drop by
  a quarter to a third of its instructions; the cost is a serialized form of the analyzer's and lowerer's
  state (declarations, indexes, inferred results) that must give byte-identical output.
  Measured (2026-11-08, `build/ablac.bin` of master, `perf stat -e instructions:u` on one P-core, `--fast
  --no-cache`; M instructions). An empty `main` costs 1,157. The same imports with an empty `main` (nothing
  reachable, so nothing lowered or sent to LLVM, but every imported module loaded, parsed, rewritten and
  analyzed): `abla/bits` 1,160; `abla/udp` program 1,606 (full 2,013); event-http-server 1,977 (full 3,649);
  https-client 2,241 (full 3,991); websocket-echo 2,346 (full 3,817); `unsafe-boundary.ab` (a 92 KB program) 2,178
  (full 3,602). So loading and analyzing the imports alone is 0 to 1,190 M over the empty build, 31% of
  websocket-echo. Where the time goes, from `perf script` sample order of the websocket-echo build (a sample is
  400 k instructions): load + lex + discovery/staged parse about 24%, the whole-program rewrite passes
  (receiver names, generics, expected types, overloads) 8%, semantic analysis 20%, IR lowering 20%, LLVM and
  link 28%. The import-only build splits alike up to lowering: parse 33%, rewrites 10%, analysis 28%. So for a
  small program the stdlib's frontend (parse through analysis) is about half of a build, more than the 25 to
  33% estimated above, but only the parse part is a per-module function. The existing discovery cache (parser
  data of unaliased modules, keyed by compiler image and content) is already in play on cached builds and
  gains little: an edited program with a warm discovery cache is 3,608 to 3,736 vs 3,817 M (-2 to -5%).
  What blocks a bigger cache: `BootstrapModuleGraph.parse` rewrites each module's text by the aliases,
  prefixes and shadows of the whole graph (`bootstrapRewriteModuleSource`), the rewrite passes after it run
  "over the whole raw program each round" and are not idempotent (frontend.ab), and sema consumes the merged
  declaration list, so analysis results are not per-module values.
  Built and measured (2026-11-08, branch `frontend-reuse`, stage1 from the same tree vs its seed; records of
  the staged parse in `BootstrapModuleState.acquireParsed` and, under `--no-cache`, discovery records for
  standard-library modules only; both keyed by the compiler image and the exact source; the staged key adds the
  module's own declaration names and the effect grant, not the other modules': a first key that included
  `dependencyFingerprint` missed on every edited program, because that fingerprint contains the program's own
  source). `--fast --no-cache`, records written by a build of a different program: udp-echo-once -8.9%,
  unsafe-boundary -4.8%, https-client -3.9%, websocket-echo -2.2%, event-http-server -1.3%; executables
  byte-identical in all; the build that fills a cold directory costs 2.5% more. Below the 8% bar for small
  builds (mean about 4%), so not merged: the staged parse of 17 of 18 modules is a hit and still saves only
  3.4% (130 M) of websocket-echo, because the parse is a small part of the "24%" above (loading, import
  scans, the rewrite and strict-import passes and lexing stay), and what remains is the whole-program rewrite
  and analysis, which are not per-module values. Next lever would be caching the analysis, not the parse.
  Design of a safe cache (as first designed; the built key above is narrower): immutable per-module records of the staged parse (declarations, bodies,
  handlers) for modules that are unaliased, have no compile-time actions/transforms/subparser registrations and
  no declaration edits, keyed by compiler image identity (size + sampled hashes as the discovery cache has,
  or a full content hash), the module's canonical path identity, the exact rewritten source text, the manifest
  visibility/strict flags and `syntaxOnly`/target; anything else is a miss, a record that fails validation is a
  miss, and `--no-cache` bypasses it. The graph still loads, resolves imports and rewrites every build, so
  diagnostics, strict-imports and visibility reports see the same inputs. Expected gain: parse is at most the
  24% above, minus decode cost and minus what the discovery cache already saves, so a ceiling of about 12 to
  16% and likely under the 15% bar; it reaches the bar only together with caching the rewrite or analysis
  stages, which needs the structural change above.
  Tried first, and not worth keeping (2026-11-08, `--fast` builds of `unsafe-boundary.ab` and
  `websocket-echo-server.ab`, three to four alternating runs): `__ablaRuntimeStringBytesEqual` comparing
  eight-byte words when both strings are 8-byte aligned (the precedent of `bootstrapNameEquals`):
  3,634 M vs 3,638 M and 3,556 M vs 3,556 M instructions, output identical: the compiler's strings are
  mostly unaligned (literals are `align 1`, names are slices of source text) or short, so the word path
  rarely runs, and an unaligned word load needs a new intrinsic the v0.2.49 seed cannot compile.
  `__ablaRuntimeArrayAppend` is already a fast path (room and kind check, one store); its 4.5% is the number
  of calls, not their cost.
- [ ] **A Wasm dev build's `opt` runs whole-module and serial.** In the compiler's driver
  (not a program embedding the toolchain) a development module of 150,000 or more
  instructions is cut into 8 code generation units after `opt` and generated by child
  compilers at once (`bootstrapEmitHeldWasmObject`, `codegen_units.ab`), so only `opt` is
  serial. Splitting the finished module was measured as not paying (llvm-split 6.5 s for an
  llc that goes 11.0 → 3.5 s; total cycles +16%, dev wasm +240 KB of data).
  Screened 2026-11-08 on master `d7aa0009`, `ABLA_KEEP_LLVM_TEXT=1` IR, external `opt` with
  the fast pipeline and `llc -O0` (CPU times; the machine ran at load 15 to 47, so wall
  times are rough):
  - game-glimpse's Wasm client (177 files, 46K lines; dev build 6.1 s, 11.4 MB of IR,
    887 KB of Wasm): `opt` 1.4 to 1.7 s, `llc` 0.7 to 0.8 s, the rest frontend. Even a
    perfect 4-way parallel `opt` (llvm-split before `opt`, 4 at once: 0.25 s wall) saves at
    most about 1.3 s of 6.1 (21%), under the 25% bar, and that client is below the
    units' minimum. Linked sizes of the split parts (1.50 MB) and the whole module (2.25 MB)
    differ for reasons the screen did not isolate (llvm-split promotes and drops
    differently), so the size bar was not judged.
  - A synthetic 6,000-function module (82 MB of IR, 6.6 MB of Wasm; generated by a
    script that writes `fnN(x, s)` functions chained to `fnN-1`, kept in the ablac-e6
    scratchpad, not in the tree): `opt` 24 s, `llc` 11 s serial, so `opt` is about 70% of
    the serial code generation side there. `-time-passes`: inliner 58% of `opt`,
    instcombine 14%, SROA 10%. Its chains make whole-module inlining blow up (parts' objects
    13.1 MB against 19.6 MB whole), so it can't judge partitioned `opt`'s size.
  - Dropping passes from the fast pipeline on the glimpse client: no early-cse `opt` 1.70 s,
    Wasm +4%; no instcombine 1.57 s, Wasm +8%; no inliner 0.87 s (−0.8 s, 13% of the
    build), Wasm −50% at the default inline threshold. Only the last moves the time, and
    it changes what the code generator and the debugger see.
  The 10K-function application behind the older figures was not found on this machine.
  Partitioning before `opt` loses cross-part inlining and needs that application (or one
  past ~50 MB of IR) and a size check (object within +1%) before anyone builds it.
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
  Remeasured 2026-11-08 on a synthetic 6,000-function dev module (82 MB of IR; peak RSS of
  the whole `ablac build`, one run each at load 30 to 40, so load-dependent): one object 1.68 GB, 8 code
  generation units 1.42 GB (−16%); the wall times (38.6 s against 50.4 s) are not comparable at that load. Units cut
  the peak a little and the child compilers each parse the module again, so the 1.9 GB of a
  single release `llc` is untouched: only fewer or smaller functions per `llc` would help.
- [ ] **Where the runtime benchmarks spend their instructions** (2026-11-08, master `e42b1b99`, release
  builds, `perf record -e cpu_core/instructions/u` pinned to one P-core, symbols named through each
  program's `abla.source` attributes). strings (2.07 G): `main` 20% (the inlined slice/indexOf loops),
  `__ablaRuntimeHostPressureCollect` 17.9%, `abla_to_string` 17.0%, `_int_malloc` 12.1%,
  `AllocateOutOfLine` 5.8%, `StringConcat4` 5.6%, memmove 4.4%. trees (12.35 G): the collector 33.4% plus
  `HostMarkPointer` 4.5%, `check` 20.9%, `make` 16.4%, `ObjectBlock` 14.9%, `abla_not_equal` 4.3%.
  dispatch (3.51 G): 99.7% in `main`, IPC 2.9, nothing to win in the runtime. json-readers (22.1 G):
  `readNumber` 15.1%, the collector 13.0%, `jsonParseValue` 7.9%, `HostMarkPointer` 7.1%, `next` 5.0%,
  `array_append` 5.0%, `appendText` 4.7%, malloc 4.6%, `abla_to_string` 3.9%. So the collector is 13 to 33% of
  three of the four (see "A collection still visits every allocation" below), and integer-to-text is 17% of
  strings. Done from it: `x == null` and `x != null` on a nullable value lowered to a boxed `null`
  constant, the generic `abla_not_equal` call (a wrapper that is not inlined), a boxed bool result and an
  `abla_as_bool` re-test, and made the `&&` join a boxed local; they are now one inline tag test
  (`value.is.null` / `value.is.not.null`, tag 1 is null) and a native `i1`. Instructions, baseline
  compiler against the change, same master: trees 12,403 M to 10,514 M (-15.23%), maps -3.03%,
  json-readers -0.33%, json-megabyte -0.12%, strings, dispatch, fib, matrix, nbody, sieve unchanged
  (+-0.00%); peak RSS within +-0.3% on all. `tools/test-null-compare.sh` pins the results (fast and
  release, and under `#`) and that the release IR has the inline test and no generic equality call.
  Left in `check`: each field read of a reference is still a boxed `abla_field_get_reference` call plus
  copies through value slots; `abla_to_string` has not been looked at.
- [ ] **trees: the field reads are not the cost any more** (2026-11-08, master `640898d5`, release build, the
  compiler of the null-compare change; ablac-e5's screen of "lower `tree.left` / `tree.right` to a typed
  load"). In the IR `check()` reads each nullable object field through `abla_field_get_reference` and boxes the
  result, but link-time inlining already collapses that: the machine code of `check` is 33 instructions, the
  two reads are two loads and two null tests (`test`/`setne`), and the rest is the boxed-argument convention
  (three stores to build each child's 24-byte argument, one call). A direct typed load would save a few
  instructions in a function that is 8.4% of the benchmark, so it cannot reach 5%; not built. Where trees'
  10,514 M instructions go (33.8 M objects, 311 a piece): the collector 86 (27.6%), `make` 82 (26.4%: the
  GC root frame push and pop, the safe-point check, and for each child a three-way tag test (null, or the
  declared class) that a child of the declared class cannot fail), the object block allocator 67 (21.7%:
  size-class free-list pop about 13, header, registry append, byte accounting and water marks the rest),
  `check` 26 (8.4%), malloc and free 22, other 27. What would move trees, in order of size: the collector's
  schedule and its visit of every allocation (ablac-39, #677); the allocator fast path (it touches seven
  globals per object); passing an object as a pointer instead of a boxed argument (per-call boxing);
  dropping the constructor's tag test when the argument's static type is the field's class (about 6
  instructions a child, 3% of trees at most).
- [ ] **The object allocator's fast path** (2026-11-08, master `3d2f2154`, release builds, instructions
  against the same compiler with only the runtime text changed; branch `alloc-fast`). Per object it was
  67 instructions (trees: 21.7%): the call into `ObjectBlock` with five callee-saved registers pushed and
  popped around the inlined allocator, the limit check, the size-class pop, three header stores, the
  registry append, an allocation count, the collector's address water marks (about 12 instructions), the
  live-byte counter, and the zeroing ladder. Done: (1) the water marks (`CollectionMinimum` / `Maximum`,
  read only by the marker's quick reject) are computed once a collection, from the page directory that
  the collection builds anyway and from the sorted large list, instead of on every allocation; (2) the
  allocation count is gone (the collections size their worklist by the registry's slots, which bound it);
  (3) an object's allocation (layout 5, a constant where it is inlined) first tries a straight-line path
  with no call: one thread (no heap lock yet), no region, a block waiting on its size's list, room in the
  registry and under the memory limit; anything else is the general allocation out of line. Trees
  10,514 M to 9,854 M instructions (-6.28%), strings -1.52%, maps -0.59%, json-readers -0.06%,
  json-megabyte +0.09%, the others unchanged; peak RSS within 1% everywhere (trees 226M both,
  json-megabyte 1045M to 1044M). Tried and dropped: the same fast attempt for every layout: trees -6.19%
  but strings +0.88% and json-readers +0.46%, because a program that allocates more between collections
  than the lists keep (the 64 MiB growth step against at most 32 MB kept) misses often, and a miss then
  pays the failed checks and a call. The live-byte and small-list counters are untouched (the collection
  trigger reads them).
  What is left of that path, measured on `alloc-fast` (2026-11-09): the guard chain is about 23
  instructions (size normalised to at least 1, the size class and the list head, a registry slot, room
  under the memory limit, no region), the pop with its header words and registry append about 13, then
  the zeroing. Tried: reading the size back from the block's header after the allocation, so that it
  needs no callee-saved register across the general path's call, a tail call for objects over 32 bytes
  and the zeroing as two to four overlapping stores instead of a ladder of compares: the prologue was
  already a single push in the release build, and trees fell by 0.44% (9,854 M to 9,810 M, 1.3
  instructions an object), everything else unchanged; dropped as not worth the dependence on the host
  header layout. The guards can only shrink by caching them in one flag that thread start, region begin
  and end and the limit setters keep in step (no thread, no region, no limit: the limit compare and the
  region test leave the path, about 8 instructions, 2.5% of trees), a stateful change whose failure is a
  region allocation or a missed memory limit; not done.
- **Per-call boxing in the lowering: two alias cuts measured, held; the rest is a no-go** (2026-11-08,
  master `04aa6c7d`). Branch `per-call-boxing` (not merged, kept for reference): a boxed `local.load` or a `parameter.load` (no default) whose value only
  feeds read-only runtime readers (string, field, array reads, `object.is`) and has no label,
  jump, branch, or same-name store between load and last use reads the local's or parameter's
  own slot instead of a copy (`bootstrapLlvmLocalLoadAliases`). `src/orc_main.ab --emit-llvm`:
  `alloca %AblaValue` 193,785 to 188,520 (-2.7%), instructions 1,213,775 to 1,187,445 (-2.2%),
  bytes 80.59 M to 79.24 M (-1.7%); `abla_i64` calls unchanged (16.3 K). Compile instructions:
  the compiler's own build -0.2%, benchmarks +0.1% to +0.3% (websocket-codec +0.7%); run instructions unchanged
  (+-0.1%). Allowing rooted locals added nothing. Tried and dropped: no slot for an unread
  `const.void`/`const.null` (one alloca fewer of 193,782).
  Why not further: of the 193 K slots, 25 K are `abla_string_static` constants (the
  copy-a-private-constant form is already dropped above: the Wasm grew), 22 K `field_get`
  results (`abla_field_get_reference`/`_string`), 9.7 K `abla_string_equal_bool` results,
  16 K `abla_i64`, and what a call receives must be a slot. Cutting them takes strings and
  object references in a non-slot form (a register pair, or a typed argument ABI for the runtime
  readers), which changes the runtime ABI: the large change this item described, not a cut.
  Held, not merged (ablac-45): the IR is smaller but nothing measurable is bought (self-build -0.2%, run
  instructions +-0.1%) and small programs compile +0.1% to +0.7% slower. The remaining boxing needs a
  runtime ABI change.
  Also tried and dropped earlier: boxing constants by copying a private constant value, and copying
  values with `memcpy`: fewer slots survived, yet the Wasm grew 0.5% to 15% (a string static holds its
  address in two 32-bit halves there, which LLVM cannot read back as one constant word). Kept slots are a
  poor proxy; measure the output.
- [ ] **The overload probe is a second semantic analysis.** It types only the bodies that
  may come by a value of a candidate's owner type (647 of a 4,979-body client, 38 of which
  resolve something) and builds no compile-effect summary (nor, without regions, a region
  summary): about 1.2 s, against 3.2 s before. What is left is typing those bodies and
  every global. Typing candidate calls inside the main analysis instead was weighed and
  dropped: the analyzer reads other bodies syntactically (fresh values, borrow sources,
  region retention, no-escape inference), and in one pass those would see `a + b` where
  the rewritten program has `a.plus__N(b)`, with no cheap way to notice.
  Measured on the release compiler (instructions, one P-core; the probe run a second time
  and the difference taken, output identical): on `src/orc_main.ab --emit-llvm` (66.3 G)
  the probe types 52 of its bodies for 67 candidates, and the whole of it is 3.1%: the
  pre-filter (`bootstrapOverloadProbedBodies`) 2.4% and the analysis 0.7%. On
  `tests/cases/modules/overloads.ab` (0.93 G, mostly the prelude) it is 6% (filter 3%,
  analysis 2.3%). So a probe that cost nothing would not reach 3% of a compile of the
  compiler, and the pre-filter already admits only the bodies that name an owner type of a
  candidate. Tried and dropped: collecting a body's names only after a first scan finds it
  needs them (same IR): 0.36% fewer on orc_main, 1% more on overloads.ab, where most
  bodies need the second scan. The filter's cost is its per-declaration sets and the
  fixpoint over the whole program, not the bodies it admits; a per-spelling closure would
  admit fewer bodies but cannot win what the analysis (0.7%) costs.
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
  Measured on Linux (2026-11-08, master `ea19ccb1`, a stage2 compiler with the build marked `@noinline`
  only to see it, `perf record -e instructions:u -c 20000000 --inherit` of `build --fast --no-cache
  src/orc_main.ab`, 14.6 s): `__ablaRuntimeHostCollectionPagesBuild` is 1.10% of the self-build's instructions;
  the rest of the collector is `HostMarkPointer` 2.6%, `PlatformMemoryCollect` (the sweep) 2.2%,
  `HostCollectionNearest` 0.7% and `PlatformFree` 0.5%, with libc's `free` (3.9% in all, not only the sweep's)
  below them. Keeping the directory across collections could win at most that 1.1%, under the 3% bar for the
  change and its risk of a directory out of step with the heap, so nothing changed. The 7% on the game
  client's front end is a much larger heap (up to 7.8 M registry slots per collection); the compiler's own
  build does not collect enough for it to matter.
  Per phase on trees (2026-11-09, master `0eaf983e`, release build, the collector's phases marked `@noinline` only
  to see them, `perf record -e instructions:u -c 2000000`; the collector is 29% of trees): the sweep 10.2%, the page
  directory's build 8.4%, tracing 5.6%, `HostCollectionLocate` 2.5%, `HostMarkPointer` 2.3%, libc `free` and
  `malloc` about 4%. The sweep and the build are per allocation, garbage included (30 and 24 instructions an object
  over 33.8 M objects). Keeping the registry, the lists and their counters in locals for the sweep's walk and the
  build's loop (nothing they call reads them): trees -1.04% instructions (11,742.5 M to 11,619.6 M), strings -0.5%
  (2,036.9 M to 2,026.7 M), maps -0.18%; the bar of 3% for the collector is not met. The bitmap word updated per
  entry could be held across entries of one page (3 instructions of about 24), under 0.5% and bitmaps can move on
  growth, so not tried. What would still cut it is a collector whose cost follows what is live.
  Directory kept across collections (asked for 2026-11-09), analysed and not built: in trees almost every
  allocation is registered, built into the directory once and swept once, so keeping the bits saves nothing
  and the sweep would pay to clear the bit of every garbage block (a page-table probe each, about the
  cost of the build it replaces); only a long-lived heap re-built every collection would gain.
  Done instead (branch `collector-maps`): a collection finds a candidate's allocation from the registry alone when
  the candidate is a payload's start (the word 32 bytes back is its registry slot and that slot names the header),
  and builds the page directory only when a candidate is not (strings' interior pointers, a raw-word block's
  words), under `ABLA_GC_STRESS=1` (which also checks the registry's answer against the directory's) or when
  `/proc/self/maps` is unreadable (non-Linux hosts). The registry's lookup reads the word before the candidate, a
  wild read for a garbage word in a scanned slot, so it reads only memory the process has mapped readable and
  writable (one parse of `/proc/self/maps` a collection, merged ranges, a last-range check before the binary
  search). Without the mapped-memory guard it was -6.4% on trees; a page-set guard built from the registry cost
  about 20 instructions an allocation and kept only -1.9%; the maps guard keeps -8.3%.
  The mapped ranges stay true for the whole marking: a foreground collection runs only with no other Abla
  thread active and outside a region, marking maps and unmaps nothing (the directory fallback only allocates),
  and the sweep, which frees, comes after. A process with 40,000 mappings (20,000 readable and writable ranges
  split by `mprotect`) costs 1.7 K instructions a line in a `--fast` build, so a list over 256 KiB gives up
  and builds the directory; a failed read does the same. `ABLA_GC_LOOKUP=directory|nomaps|untagged` forces each
  fallback and `memoryHeapStat(5)` / `(6)` count the collections that went each way (`tools/test-gc-lookup.sh`).
  Limits accepted (review of ablac-f3-2): the list holds only anonymous ranges (inode 0), so a file mapping read past
  its truncated end cannot fault the lookup; MTE tag mismatches and another thread's `munmap` during the marking
  (a foreign pthread from an FFI library) are not covered; the first collection issues one `openat`, which a
  seccomp profile that kills instead of answering an error would punish; the read buffer is one 260 KiB block
  freed after the marking, so its own range is never stale; after an interior pointer the directory is used for
  16 collections before the lazy lookup is tried again. The AArch64 system call numbers (56, 63, 57) are
  checked by reading only: no AArch64 run reaches the real calls (the libc-free guests answer `syscall` with
  the kernel's, and their tests pass through the lookup unchanged). The raw-word switch and the
  interior-pointer fallback are not told apart by the counters (both count a directory build).
  Release builds, instructions, vs master `98c5c7a2`: trees 11,742.5 M to 10,767.2 M (-8.3%), strings
  2,036.9 M to 1,926.6 M (-5.4%), maps 2,560.8 M to 2,500.1 M (-2.4%), same output.
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
  Tried that candidate (2026-11-07, v0.2.49 seed, stage1 builds of master `3d918b58` with and
  without it; `lowerer.currentOwnerDeclaration` computed where each lowerer is made, used by
  `isField` and the current owner's `lowerFieldType`): the emitted IR is byte-identical on
  `src/orc_main.ab` (80,393,150 bytes), `tests/cases/modules/unsafe-boundary.ab`, `examples/websocket-echo-server.ab`
  (`tests/cases/simd/checks.ab` emits nothing in either compiler), and user instructions of `--emit-llvm` are unchanged
  within noise: 2,569.56M vs 2,568.29M (-0.05%), 2,703.18M vs 2,702.00M (-0.04%), 3,890.71M vs
  3,890.76M (0.0%), and `src/orc_main.ab` 66.08G vs 66.74G (+1.0%: run-to-run spread on that
  input is about 2%). The 66k owner lookups
  are about 0.007% of the instructions of the emit if a lookup costs about 100 (an estimate,
  not a measurement), so the owner cache is invisible; remembering every repeat (49% of 1M)
  would be about 0.07% by the same estimate, well under the 1% bar. The 4% sample share above
  was probably cache misses, which instruction counts do not see. A cache inside `find`
  itself is not possible: any write makes `find` a mutating receiver and 32 callers that
  only borrow the index fail `ownership.mutable-borrow`. Nothing changed.

- **A flattened rope's copy read inline** (2026-11-09, master `0762174d`, release builds, one P-core; not
  kept). `__ablaRuntimeStringData` sends every read of a rope through the noinline
  `__ablaRuntimeStringDataSlow`, even when the rope's flat copy exists (6.1% of json-megabyte's instructions,
  whose 15 MB document is built by concatenation). Reading the copy inline first (`__ablaRuntimeRopeFlat`, +40 and
  its fence once threads run): json-megabyte 81.10 G to 78.75 G (-2.9%), strings -0.3%, websocket-codec -0.2%,
  trees 0.0%, maps +0.1%, json-readers 0.0%, but stripped sizes grow where strings are read a lot:
  json-readers +2.8%, json-megabyte +2.2%, websocket-codec +1.4%, the rest +0.0% to +0.4% (hello and fib
  unchanged). In `__ablaRuntimeStringGetI64` alone (the byte read of a scanner's loop): json-megabyte -2.1%
  (79.39 G), json-readers 0.0%, sizes json-readers +1.8%, json-megabyte +1.4%, websocket-codec +0.9%,
  websocket-server-load +0.6%, the others 0.0%. Both exceed +0.5% on the size bar, so neither is kept. What
  would hold the gain without the size: a flat string value for the scanner (the parse entry points reading
  their `source` once into a flat string, which the rope's copy cannot give because a string value copies
  the rope pointer), or a smaller inline form.

## Tried, not pursued

- **JSON ASCII word scans without a short-string fast path** (2026-11-06/07,
  published v0.2.48/v0.2.49). Scanning JSON strings a word at a time won 66-77%
  on json-strings-4k but cost short strings: an inlined scan lost 5.7% on
  items-128 and 7.7% on roles-64; an outlined one 4.4% on items. Scalar
  prefixes (K=32, K=128) and length gates (`size > 64`, `end - begin > 32`)
  still added +0.17% to +0.27% items-128 instructions, with all three items
  throughput pairs negative (K=32 -0.82%, K=128 -0.74%). What shipped instead:
  the serialize side (128-byte prefix, then the word scan; strings-4k +16.3%)
  and the parse side (a 128-byte prefix whose head tests the common ASCII byte
  first, then the word scan; strings-4k +49.2%). Labs:
  `~/archive/ablac-json-gate-2026-11-07/`.

- **Skipping the erased float formatter's second analysis** (2026-11-07,
  master `1a9db095`): a program that erases a float to `any` and interpolates
  an `any` is analyzed once to find that out, then parsed and analyzed again
  with the formatter bridge loaded. On `json-document.ab` plus a two-line
  `"$value"` of an erased `1.5` (`--fast --no-cache`), a sampled profile
  (every 200,000 user instructions) of the compiler process puts the whole
  increase over the same program erasing an integer at about 57M
  instructions: ~18M in the compiler itself (the second pass plus lowering the
  formatter) and ~39M in LLVM compiling the formatter's code (+35,624 bytes
  of executable). Avoiding the second pass would save at most ~1.7% of that
  compile and only for such programs; programs without the pair build
  byte-identically already. Not worth the risk of loading the bridge early.
  The bridge is preloaded whenever any loaded module mentions `compiler` and
  has compile-time actions, which takes in every `abla/json` program. Counting
  only the program's own imports of `abla/compiler` and its own actions saved
  0.5% of the instructions of a JSON program without erased floats (4.12 to
  4.10 billion) but cost 36% on one with them (4.35 to 5.94 billion): its
  second compilation replays the JSON library's compile-time actions. Kept.

- **STM inline logged-access fast paths** (2026-11-05, #499, base
  `444eebde`): rejected one same-protocol prototype. Inline the stable first
  read and first logged write; keep snapshot extension, retry, direct undo and
  repeated-write handling out of line. Seven alternating baseline/candidate
  pairs per scenario on CPUs 4,8,10,14, release builds without cache, returned
  42 in all 56 runs. Disjoint cycles fell 21.65% by ratio of medians, but the
  median within-pair change was only -9.53%, below the required 10% improvement
  (individual pairs ranged from -30.88% to +19.10% under load). Instructions
  fell 14.91%. Shared and forced-logged single cycles fell 11.86% and 15.93%
  by ratio of medians (median pair: -13.04% and -19.44%). Direct single
  regressed: instructions +14.82% (680.26M to 781.06M per 800,000 blocks),
  cycles +9.84% by ratio of medians, +7.16% median pair. The stripped scenario
  binary grew from 47,120 to 47,504 bytes (+0.815%, above the 0.5% cap).
  Stop: no runtime changes retained, no second variant or clock prototype.
  Raw pairs, binaries and rejected patch remain in worktree `ablac-stm-fast`,
  `build/stm-fast-lab/{screen.json,final-summary.json,rejected-prototype.patch}`.
  These are aggregate worker cycles, not latency; correctness/stress gates
  beyond the scenario counters were not run for the rejected change.

- [ ] **Full contract-shape library loading needs a namespace design, not a
  local import fix** (2026-11-05). Eager full loads broke compile-time provider
  order; preserving ordinary order then leaked implementation helpers and
  aliases into the flat namespace. Canonically hiding shape-only libraries
  required transitive internal bindings, generated-module type names and
  intrinsic/effect classification to change as well. On isolated NovaKind,
  customer-editor-state produced 6,151 semantic errors in the direct-only
  prototype, then 171 after internal transitive qualification, while v0.2.45
  built both source snapshots cleanly. Keep the loading model stable for the
  immediate fix: validate the retained contract surface and avoid projecting
  dependency implementation functions as remote externs. Revisit full library
  bodies only with an explicit design for flat sibling visibility, aliases,
  generated code, compile-time registrations and intrinsics. Worktree
  `ablac-contract-shape-namespace` retains the rejected prototypes and controls;
  they are not approved production changes.

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
