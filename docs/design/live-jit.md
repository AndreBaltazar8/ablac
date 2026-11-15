# `ablac run` as a live JIT: redefining functions while the program runs (design, not built)

Status: design for review (ablac-e8, 2026-11-15). No code yet.

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
- `--watch` (reload when a file changes) can come later, on top of this.
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
