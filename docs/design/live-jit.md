# `ablac run` as a live JIT: redefining functions while the program runs

Status: stages 0 to 3 are built and on master, and `ablac run` is live by default on x86-64 Linux and macOS
(decision #65, `--no-live` opts out); the rest of the design is not built. The text below the status table is the
original design; where it differs from the table, the table is what exists. For using it, see "Live run" in [the toolchain interface](../toolchain.md).

| Stage | What | State |
|---|---|---|
| 0 | Audit of the interprocedural facts a compiled function depends on (section at the end) | done (698cfd8d) |
| 1 | The program's own functions called through one table of code pointers (`abla_live_table`) | built (6e8300fc); live by default since f3b13016 (x86-64 Linux) and 5cd21cd2 (macOS) |
| 2a | `liveReload()`: recompile, keep the functions whose IR hash changed, publish a new table | built (6f6d36f0) |
| 2b | A reload is refused when unchanged code would compile differently, or a signature or class layout changed | built (f9f311f4): `E_LIVE_SIGNATURE`, `E_LIVE_LAYOUT`, `E_LIVE_CALLER`, `E_LIVE_GLOBAL`; a changed signature of a function nothing takes as a value (and not a method) moves to a new entry instead of being refused (see "Changed signatures") |
| 2c | Only data and the table's functions are shared between generations; a live run is object-cached with the compiler's record beside the object (`<object>.live`) | built (f89ff893) |
| 3 | Lambdas: an edited lambda is matched to the running one, so closures made before take its new body; new lambdas reach code that was not redefined through a registry; a change to captures, parameters or result is refused (`E_LIVE_LAMBDA`) | built (8b7e1ee0) |
| - | `--watch`: a reload when one of the program's own source files changes (inotify, kqueue), printed on stderr; a save the running code cannot take restarts the run | built (`src/live_watch.ab`, `tools/test-live-watch.sh`) |
| - | `liveDefine(path)`, `E_LIVE_REMOVED`, `E_LIVE_SUMMARY` | not built; what a removed function does has not been defined |
| - | Platforms | live by default and tested on x86-64 Linux and macOS (arm64, Intel); no ablac is built for AArch64 Linux |

Decision taken for question 1 below: live mode was first **opt-in** (`--live`); decision #65 made it the default where it is tested, and `--no-live` turns it off (no table is built).

## What exists today

- `ablac run` builds the whole program, with the runtime and collector inside it, as one LLVM module.
  It adds that module to a default LLJIT in the compiler process through one resource tracker
  (`stdlib/abla/llvm/orc/entry.ab`: `llvmOrcCreateSession`, `addModule`, `lookup`, `llvmOrcCallMain`).
  Host symbols come from the process search generator. The object cache (`src/jit_cache.ab`)
  captures the object LLJIT produced.
- A direct call is a static `call @<sym>_direct`, with internal linkage. A function value is a 24-byte
  value with tag 5 holding the function's runtime id, not a code pointer. A closure is the same
  value with a capture array. `call.indirect` goes through the module's `abla_llvm_call_indirect`, a
  closed switch over this module's address-taken functions (`dispatch.ab:276`; drops through
  `abla_llvm_drop_closure`).
- The roots are precise: a shadow stack of frames pushed by generated code. Nothing is registered
  when code loads. A heap instance's first word points to its class descriptor, a private constant
  of the module.
- Compile-time evaluation runs in separate LLJIT sessions (`ct_jit.ab`, `ct_native.ab`).
- The LLVM C API can create an indirect stubs manager and lazy re-exports, but it cannot repoint a
  stub. `IndirectStubsManager::updatePointer` and `RedirectableSymbolManager` exist only in C++. So
  ORC's stubs give lazy compilation, not redefinition, through the C API we bind.

## Proposal

### 1. Indirection of our own, in IR, in `run` only

- Every function of the program's own source files (not the stdlib or the runtime) gets an entry in
  one table of code pointers, `abla_live_table`. The table is a global pointer to an immutable array.
- A direct call to such a function becomes: load the table pointer (acquire), load the entry, call it.
- The wrapper (`abla_fn_*`), which the dispatcher's switch case calls, also goes through the table.
  So existing function values, closures, thread/task/generator entries and the
  "statically one function" shortcut in `call.indirect` all reach the newest body. No value in the
  heap holds a code pointer, so nothing needs patching.
- Only the `run` module is built this way. `build`, `run --built` and the object cache key are
  unchanged (live mode is part of the key).
- Cost: two dependent loads per call to a program function, and no inlining across program
  functions. The stdlib and the runtime still inline. Measure on the three TODO workloads (map
  exporter, map builder, model generator) before deciding whether live mode is the default for
  `run` or opt-in.

### 2. Loading: the program asks, the compiler compiles

- New module `abla/live`:
  - `liveReload(): LiveResult` re-reads the program's source files, compiles them, and redefines
    every function whose body changed.
  - `liveDefine(path)` does the same for a changed copy of one file.
  - Outside `ablac run`, both return `LiveResult.unavailable`; they are not errors.
- The program reaches the compiler through `extern:"c"` host functions the compiler exports,
  resolved by the process search generator that already serves `__emutls_get_address`.
  `liveReload` blocks the calling thread while it compiles; other threads keep running the old
  code.
- `--watch` reloads when a file changes, on top of this: `main` on a thread of its own, the compiler's thread waiting for file events and calling the same reload (`src/live_watch.ab`).
  A refusal it gets (or code that does not link) restarts the run: ablac execs itself again with the same arguments and environment, at most once in a row for the same reason ([toolchain](../toolchain.md)).
- The compiler keeps the program as it was loaded:
  - its frontend result;
  - the per-function fingerprints (the `fp1`/`fp2` hashes in the wrapper names);
  - the table index of each function.
- A reload re-runs the frontend on the current sources and compares each function. The new
  generation is a second module that holds only:
  - the changed and the new functions;
  - their lambdas;
  - a dispatcher extension.
  It names everything else (runtime, globals, class descriptors, unchanged functions) by symbol in
  the base module. In live mode the base module therefore exports those with default visibility, and
  run-mode runtime pruning keeps them.
- The new generation goes in through `LLJITAddLLVMIRModuleWithRT` with its own tracker. Then one
  atomic store publishes a new table, a copy of the old one with the changed entries.
- A reload is all or nothing. A thread already in an old body finishes it. Each call made after the
  store sees the new table, so a call never runs a mixture of an old and a new table. Two calls in
  a row can see two tables.
- Old generations are never removed in v1. Freeing one would need proof that no thread is in it
  and that no live value points at it. The memory cost is the code of each reload.

### 3. What a redefinition may change (v1)

- **Allowed:**
  - a function's body;
  - new top-level functions, which can only be called from redefined or new bodies;
  - new lambdas. Their ids are unknown to the base dispatcher's closed switch, so its default
    case looks the id up in a runtime table that each generation extends, before it panics.
    The drop dispatcher does the same.
- **Refused:** the whole reload fails with a diagnostic, the old code keeps running, and
  `LiveResult.refused(diagnostics)` comes back. Refused changes:
  - E_LIVE_SIGNATURE: a changed parameter list, result type, throws/effects, or generic parameters.
  - E_LIVE_LAYOUT: a changed class, field, enum or global (type, or its addition/removal).
    Initialisation order and live instances make these unsafe.
  - E_LIVE_REMOVED: a removed function that the base still references.
  - E_LIVE_SUMMARY: a broken interprocedural fact (below).
- **Interprocedural facts are part of the signature.** The compiler compiles callers using facts
  about their callees. One example: `src/backend/llvm/escape.ab` keeps a closure in the caller's
  frame when the callee's parameter "does not escape". A redefined callee that stores that closure
  would leave a dangling frame pointer.
  - Rule: the base computes these facts once. A redefined body must have the same or stronger
    ones; for escape, every parameter that did not escape still does not.
  - The alternative is computing them in live mode as if every program function could be redefined
    (all parameters escape). That is simpler and safer, but slower.
  - To audit before code: escape.ab's parameter summaries, sema's mutable receiver / copy region /
    alias summaries, the compile effect summary, purity and `@inline`.
  - I'd take the conservative alternative for v1, and the "same or stronger" check later, only where
    it measures.
- Generics: each instantiation is its own function, with its own entry. A redefinition re-instantiates
  the instantiations that exist; a new one is a new function.

### 4. Threads, the collector and compile time

- Threads: publishing is a single release store of the table pointer, and calls load it with
  acquire. No stop-the-world is needed.
- Collector: generated code pushes the root frames, so new bodies take part as they are. New code
  allocates through the base module's runtime, the only runtime in the process. Instances keep
  pointing at the base's descriptors (no layout changes). Old generations are never freed, so
  nothing dangles.
- Compile time: a reload's compile-time code runs in the compiler's compile-time session, as in any
  build, and its results are constants in the new module. The `run` session and the compile-time
  sessions stay separate.

### 5. The test that proves it (tools/test-live-jit.sh, tests/cases/live-jit)

1. Setup: the script copies `main.ab` to `build/live/` and runs it with `ablac run`.
   - Before any reload, `main.ab` takes a function value `f = ::value`, makes a closure
     `c = { value() + 0 }` and starts a thread that calls `value()` in a loop.
   - `value()` returns 1.
2. The program rewrites its own copy (`= 1` → `= 2`) and calls `liveReload()`. Then it checks that
   `value()`, `f()`, `c()` and the spinning thread each see 2. The thread must see it within a
   bound. Exit 42 if all four do.
3. A refusal: the program changes `value`'s result type, gets `refused` with E_LIVE_SIGNATURE, and
   `value()` still returns 2.
4. A new lambda inside the redefined body runs through the dispatcher's extension.
5. Mutation check: with the table indirection off (direct calls), step 2 sees 1 and the test fails.
6. Coverage: Linux x86-64 and AArch64 (qemu) in the suite. On the Mac, it runs as part of
   `test-macos-host.sh`, which matters because thread-locals are emulated TLS there.

## Questions for the lead / André

1. Live mode by default for `ablac run`, or opt-in (`run --live`)? It depends on the measured cost
   in step 1. André dislikes flags, so I'd make it the default if the three workloads lose under
   about 5%.
2. Is the v1 scope right? Bodies and new functions only; no layout, signature or global changes;
   old code never freed.
3. Is the trigger right? A program-driven `abla/live` API first, `--watch` later.

## Stage 0: audit of interprocedural facts (2026-11-15)

Where compiling a function uses facts about the functions it calls:

| Fact | Where | Used for | A changed callee would break |
|---|---|---|---|
| mutating receivers (`bootstrapBuildMutableReceiverSummary`, sema.ab:718) | ir.ab:7338, 7373, 7545, 9095, 9331, 10285; part of the IR hash (ir.ab:1142) | lowering: whether a call mutates its receiver (delegated `getValue`, copies) | an old caller's copy/store decisions |
| managed alias tracking (`managedAliasBegins`, sema `bootstrapSummaryTypeNeedsManagedAliasTracking*`) | IR hash (ir.ab:1157), lowering | alias handling of managed references | an old caller's alias bookkeeping |
| non-escaping parameters (escape.ab, `bootstrapLlvmParameterEscapes`) | backend: frame closures and cells | a closure or cell in the caller's frame | a dangling frame pointer |
| region call retention (`BootstrapRegionCallSummary`, sema.ab:5841) | sema checking only | rejecting unsafe region use | nothing: a reload re-checks the whole program |
| compile effects (`bootstrapBuildCompileEffectSummary`) | sema and eval: compile-time checks | compile-time authorization | nothing at run time |
| module alias summary (module.ab:1493) | import resolution | names | nothing beyond a signature change |

Conclusion: the facts that shape code are the first three. Making sema's facts conservative would make
live mode reject programs that compile, not just compile them more slowly. So, instead of an
open-ended list of conservative modes:

**The general rule: a reload is accepted only if every function the change did not touch
compiles to the same code.** The reload compiles the whole new program anyway. It then compares,
for every unchanged function, a hash of its emitted LLVM function before optimization, with the
table indices and the generation's symbol names normalized. If any of them differs, the change
altered a fact that function's running code relies on, and the reload is refused:

`E_LIVE_CALLER: render (unchanged) would compile differently: it calls drawTile, whose change it depends on`

The changed callees named are the ones it calls directly that changed. This covers the three
facts above, any added later, and signature or layout changes; the specific refusals
(E_LIVE_SIGNATURE, E_LIVE_LAYOUT) are checked first, for clearer messages. It needs the emission to
be deterministic per function (it is: stage2 == stage3). A cheap pre-test in stage 1: compile
the same program twice in live mode and compare the hashes of every function.
Escape stays exact in live mode: no conservative setting is needed, since a frame closure that a
change would break shows up as a changed caller.

## Stage 3: lambdas (2026-11-15, built)

ir.ab names a lambda `<owner>_lambda_<begin>_<end>_<n>`: its span in its owner and its number among the
functions lowered there. An edit inside a lambda, or before it in its owner, renames it, and a renamed lambda is
a new function with a new runtime id, so a closure the running code made would keep the old body. Lambdas are in
the live table like any function (stage 1), so what a reload needs is to recognise the lambda it replaces.

**Matching** (src/backend/llvm/live_lambdas.ab). Before a reload's program reaches the backend, the reload's
lambdas are matched, owner by owner, to the running program's:
1. A lambda with the same source text and shape is the same lambda: it keeps its name, so its code must be the
   same, and E_LIVE_CALLER applies to it as to an unchanged function.
2. The lambdas left on each side, paired in order when there are as many on both sides, are the edited ones.
3. Lambdas left over when the other side has none are new. When both sides have some left, in different
   numbers, the reload is refused: `E_LIVE_LAMBDA: <owner>: its lambdas were edited and some added or removed`.

A matched lambda takes the running program's name in the whole reload's program (its function and every
instruction naming it), so its symbol, its table slot and its runtime id are the running code's. An edited body
is then an ordinary redefinition. A closure made before the reload runs the new body with the captures it was made
with, and the base module's dispatcher and wrapper reach it. A new lambda whose own name happens to be one the
program has gets a name of its own (`_g<generation>`).

**What is refused.** A paired lambda whose shape changed: its parameters, captures first, and their types, and
its result. Example: `E_LIVE_LAMBDA: shaped.lambda #0: its captures, parameters or result changed ((first: unknown)
-> unknown, now (first: unknown, second: unknown) -> unknown): closures the running code made hold the old
captures`. The running code's closures hold the old capture array.

**New lambdas from code that was not redefined.** A new lambda has an id no base dispatcher knows. Since stage 2c
each generation has its own internal dispatchers, so new code calling it works. Code that was not redefined (a
base function that calls what it is given, the collector dropping a closure) goes through the base module's
dispatchers, whose closed switch ends in "invalid function reference" (call) or a plain release (drop).
- In a live run, each dispatcher's default first looks the id up in `abla_live_lambdas` (dispatch.ab). Every live
  module defines that global, null; a reload's module finds it defined and names the first's.
- The registry is an immutable array: the count, then for each id that generation's call and drop dispatchers.
- A reload that adds lambdas names its own dispatchers `abla_llvm_call_indirect_live<g>` and
  `abla_llvm_drop_closure_live<g>`, hidden external. Once it is applied, the compiler publishes a new array, the
  old entries plus the new ids (sign-extended, as the dispatchers compare them), with one release store. The
  dispatchers load it with acquire.

**Runtime ids.** A function value holds its function's runtime id: the hash of its name, parameters and result,
with a collision moved to the next free id, the keeper chosen by symbol order. A reload compiles the whole program,
so a function it adds whose id collides with a running one's, and whose symbol sorts first, would take that id. A
value the running code made would then call the new function from new code, and the running code that makes
such values would compile differently: E_LIVE_CALLER would refuse the reload. So a reload keeps every running
function's id (by symbol, `bootstrapLlvmLiveRuntimeIds`, in the cached record as `rid` lines), and gives a function
it adds one none of them has. Every function a reload adds, named or lambda, is in the registry, because a value of
any of them can reach code that was not redefined.

**State.** The running program's lambdas (name, owner, number, text hash, shape) are kept with the rest of the
compiler's record. They are updated when a reload is applied, and written to the cached record (`abla-live 2`;
a version 1 record is not loaded, so the run compiles).

**Tests** (tests/cases/live-jit/reload.ab):
- a same-length edit of a lambda without captures;
- a length-changing edit of a lambda with a capture: a closure made before the reload runs the new body with
  its captured 5 (105);
- a capture added: refused, and the old lambda keeps running;
- a lambda added in a function that had none, handed to a base function that calls it (`applyIt`, which `main`
  uses before the reload, so the base program has it);
- a function added whose id collides with a running one (two names found by a birthday search over the id hash):
  a function value made before the reload still calls its own function, from new code too, and the new function
  handed to a base function reaches it;
- a new `move` lambda capturing a Token, handed to a base function that owns it and drops it uncalled
  (`discardIt`): the base drop dispatcher finds the new generation's and the Token is dropped. A call would have
  consumed it in the lambda's own code, never reaching the base dispatcher.

The last two need their owners to allocate before the edit too. Otherwise their callers' code depends on them
never collecting (they keep no GC roots across the call), and the unchanged-code rule refuses the reload, as it
should.

Mutation-checked, each turned off failing the test on its own check:
- the matching (a closure made before keeps the old body: 6);
- the shape refusal;
- the call registry lookup (`invalid function reference`);
- the drop registry lookup (the Token is not dropped).
- the id pinning (before it, the collision reload is refused: E_LIVE_CALLER on main);
- the registry's named functions (only lambdas registered: invalid function reference).

## Changed signatures (built, 2026-11-20)

A function whose parameters or result change compiles under another symbol, which gets a new table entry. The
running code calls the old entry and keeps calling it: the old body stays, so an old caller (or a thread inside the
old body) goes on the old way, consistently. New code, the edited callers, calls the new entry. What is not
consistent is something the running code made that new code reaches with the new types: a function value or a
closure of the old function, or a call through a class. So `E_LIVE_SIGNATURE` stays for:

- a function the running program takes as a value anywhere (`function.ref` or `closure.create` in any function of
  any module, a lambda's body included): the compiler records these symbols when the program is loaded and adds a
  reload's once it applies (`bootstrapLlvmLiveTaken`, kept in the object cache's record, version 3);
- a method or an extension (a label `Owner.name`): calls through its class.

Any other changed signature applies. A caller whose source did not change but that compiles differently only
because a callee moved (a renamed parameter: the call names the new symbol) is redefined, not refused as
`E_LIVE_CALLER`: the old caller still calls the old entry, so nothing it relies on changed. A caller that also
calls a callee changed in place is still refused. The new signature reaches the program through the callers a reload redefines, so it shows
once one of them is entered again: a caller that never returns (a `main` loop) keeps running its old body and the
old entry until the program restarts. Under `--watch` an applied reload says so, one line per function that moved:
`live: <name>'s signature changed; callers redefined: <callers> (it applies when they are entered again)`. Tested by `tests/cases/live-jit/reload.ab` (a parameter added
while a thread is inside the old body) and `refuse.ab` (a function taken as a value, and one taken only inside a
lambda of another module).

## Freeing old generations (design, 2026-11-16; measured, not built, not worth it yet)

**Measured (2026-11-19), and the decision.** A program that edits one of its functions and reloads 100 times
(`ablac run --live`, JITLink, x86-64 Linux; the JIT's code as the anonymous executable mappings of
`/proc/self/maps`): an arithmetic edit left 4 kB of code a reload (one page: 96 kB to 496 kB over 100), an edit to a
function that parses and formats JSON (its generation copies the json functions it calls) 76 kB a reload (96 kB to
7.7 MB). Data sections were not counted and are of the same order at most. A day of about 500 reloads leaves 2 to
40 MB, against a process the compiler keeps at 350 to 640 MB resident. So nothing below is built. Instead a live
run counts the objects its reloads add (`lookupMeasuring`, the bytes of each compiled object) and, past 256 MB,
prints once on stderr that the code is never freed and a restart gives it back (`ABLA_LIVE_NOTE_BYTES` sets the
limit; tools/test-live-jit.sh checks the note appears once at one byte and never at the default). The probe below
also ran the JIT tests on RuntimeDyld (live, watch, emutls with native ELF TLS, repl, compile-time JIT, object
cache): all 15 passed, so piece A is open if the numbers change.

Today every applied reload adds a generation (an LLVM module with its own ORC resource tracker) that is never
removed, so a long `ablac run --watch` session grows by the code and constants of each reload. Removing a
generation's tracker frees its code and data at once, so a generation can go only when nothing can reach either.

### What can point into a generation G

1. **The table.** An entry whose newest body is in G. Once every body G brought has been replaced, no entry
   points at G. The reload knows which entries each generation set (`bootstrapLlvmLiveChangedIndices`); keeping
   the generation of each entry beside its hash in the live record is a small addition.
2. **Threads.** A thread executing in G, or a frame with a return address into G (a thread that entered an old
   body finishes it on the old code, and its callers' frames return there).
3. **Code pointers held as values.** G compiles its own copies of the functions it calls that are not the
   program's (since stage 2c: the standard library's and the runtime's, internal to G), so a function value
   made in G's code of such a function (`println` passed as a value), or a thread or generator G's code
   started on one of them, points into G. A lambda G added is reached through the lambda registry, whose entry
   points at G's dispatcher; a closure holding that lambda's id is invisible to an address scan.
4. **Data.** Constants G defines: a string literal or constant array that is new in G (an unchanged one is the
   base's, shared by name). A string value made from such a literal points into G's read-only data for as long
   as the value lives. G defines no variables (`E_LIVE_GLOBAL` refuses new ones) and no class descriptors.

So the condition is: no table entry in G, no lambda added by G, and no word on any stack, in any register of a
stopped thread, or in any live heap object that holds an address inside G's memory.

### The pieces

- **A. G's memory ranges.** LLJIT's default linking layer (JITLink) does not tell the C API where it put an
  object's sections. The C API can instead build LLJIT on RuntimeDyld with an MCJIT-like memory manager whose
  callbacks allocate every code and data section (`LLVMOrcCreateRTDyldObjectLinkingLayerWithMCJITMemoryManagerLikeCallbacks`,
  through `LLVMOrcLLJITBuilderSetObjectLinkingLayerCreator`): the compiler would then record each generation's
  ranges as they are allocated. Risk: the program's thread-locals are native ELF TLS on Linux, and RuntimeDyld's
  ELF TLS support is narrower than JITLink's; the object cache's capture runs through the object transform
  layer, which is above the linking layer and should not change. A probe settles it: the live, run and
  compile-time JIT tests with the RuntimeDyld layer. Without the ranges nothing below is sound (looking up G's
  symbols gives starts, not sizes, and misses its anonymous constants).
- **B. Proof that nothing points in.** At a stop-the-world collection (steps i–iv: every thread parked at a safe
  point or counted as stopped, its registers saved), scan conservatively every thread's stack from its saved
  stack pointer to its base, the saved registers, and the words of every live heap object, for an address in a
  candidate generation's ranges. A word that happens to look like one keeps G alive: that is only memory not yet
  freed, never a fault. The scan runs only while a candidate exists (a generation whose table entries are all
  replaced and which added no lambda), at most once per collection, and one pass checks all candidates.
- **C. Removal.** With the world still stopped, remove G's tracker (`LLVMOrcResourceTrackerRemove`): ORC frees
  its code and data. Its table entries are already elsewhere, so no call goes there again.

### Limits of a first version

- A generation that added a lambda is kept: a closure carries the lambda's id, not an address. Freeing those
  needs the registry to know which ids are still held (a scan for closure objects by id).
- The base module is never freed (it has the runtime, the globals and the class descriptors).
- Measured on x86-64 Linux; macOS (live by default there too) has not been measured.

### Questions for the lead / André

1. Switch `ablac run` (live or not) to the RuntimeDyld layer if the probe passes, or only live runs? One layer
   for both keeps one tested path; the plain run gains nothing from it.
2. Is a conservative scan acceptable? It can keep a dead generation (a false positive), never free a live one.
3. Is a first version that keeps lambda-adding generations worth landing? An edit to a lambda's body replaces
   it in place (stage 3), so only reloads that add lambdas keep their generation.

### Order

Probe A first: if RuntimeDyld cannot run the live, run and compile-time JIT tests, the ranges need another
source (a C++ shim is not an option: the compiler only uses LLVM's C API), and B and C wait.
