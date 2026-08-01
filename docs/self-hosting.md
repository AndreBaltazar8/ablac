# Self-hosting status

The authoritative remaining route to a compiler that needs neither C nor libc
is [full-self-hosting.md](full-self-hosting.md). This document records the
existing bootstrap implementation and historical milestone evidence.

The bootstrap compiler is being replaced vertically, with every Abla-written
component executable before the next one depends on it. The current pipeline
under `bootstrap/compiler/` contains:

- a byte-oriented lexer with owned tokens and source spans;
- a structural declaration/method parser with lexical scopes, string templates,
  control flow, collections, objects, and precedence expression trees;
- deterministic symbols, nominal field/method resolution, and type inference;
- pointer-free expression IR with explicit labels, branches, short-circuiting,
  scoped storage, native calls, lexical closure environments, shared capture
  cells, and tagged runtime values;
- a bounded compile-time AST evaluator with scalar/string/collection/object
  execution and identity-preserving frozen graph materialization, including
  aliases and cycles;
- an Abla-authored staged subparser registry, token/raw cursor, syntax builders,
  and handler evaluator that can hand control recursively between embedded
  grammars and the base parser;
- a deterministic C emitter;
- a recursive module loader and native driver using Abla `Path`, `FileWatch`,
  `Command`, and `ChildProcess` APIs.

`make bootstrap-stage1` performs a real native bootstrap step:

1. `ablac0` compiles the Abla compiler sources to C;
2. strict C11 compilation produces `build/bootstrap/ablac1`;
3. `ablac1` reads an Abla source file and emits C twice;
4. the two outputs must be byte-identical;
5. strict C11 compiles that output and the program must return 42.

`make bootstrap-selfhost` proves source-level closure:

1. `ablac1` compiles the complete Abla compiler source graph to `ablac2.c`;
2. strict C11 compilation produces the native `ablac2` compiler;
3. `ablac2` recompiles the same graph to `ablac3.c`;
4. `ablac2.c` and `ablac3.c` must be byte-identical;
5. stage 1 and stage 2 must emit byte-identical C for a behavioral fixture;
6. strict C11 compiles that fixture and it must return 42.

This is a genuine fixed point for the bootstrap subset, not a claim that the
subset already accepts the complete stage-0 language. Unknown calls and
malformed input fail without publishing partial C. Stage 0 remains the broader
reference implementation while features are moved into the self-hosted path.

The common stage-1/stage-2 gates now cover block scope, `if`/`when`, short-
circuit logic, `while`/`do while`, arrays and indexed mutation, nullable values,
classes, nominal method dispatch, defaults, extensions, native C calls,
modules/globals, typed local annotations, named function references, trailing
lambdas, escaping/nested/mutable/receiver captures, compile-time functions,
frozen compound graphs with sharing and cycles, custom syntax builders,
imported nested parser stacks, and the unchanged JSON and HTML providers at
both runtime and compile time.

The compiler source graph also contains the Abla-authored LLVM backend.
`make bootstrap-llvm-selfhost` emits LLVM for the complete compiler graph,
verifies and links it with LLVM 21, and requires that LLVM-native compiler to
reproduce identical full-compiler IR. It also gates lexical captures,
identifier shadowing, bounded stack use, native `build`/`run`, rejected-edit
hot reload, typed native `bool`/`cstring`/pointer/`void` ABI calls, and real
versioned HTTP socket exchanges in both AOT and JIT modes.

The final `make ablac` rung additionally links libLLVM only into the compiler,
uses Abla bindings for O2/object emission and persistent ORC sessions, proves
that builds still succeed when `opt` and `llc` are replaced by failing shims,
reclaims 128 REPL generations under a memory ceiling, and drains an in-flight
HTTP request across a validated hot reload. A second final compiler emits
byte-identical full-graph LLVM IR.

The production `orc_main.ab` graph imports only the LLVM backend. The generated
C backend remains in the compatibility `main.ab` compiler for seed bootstrap
and differential testing, without inflating the final compiler. Complete
release self-rebuilds use the public `ablac build` command under a four-GiB
watchdog. A separately guarded phase-split helper remains available as a
lower-peak recovery/bootstrap route, but is not the self-hosting proof.

The LLVM backend now emits its scalar operations, checked boxing/unboxing,
closures and shared capture cells, arrays, objects, division/equality,
integer/bool/null formatting, persistent string ropes, and iterative rope
flattening. A permanent gate rejects generated modules that import the former
C value-runtime symbols. The seed C backend also splits large Abla constants
into runtime rope chunks, so compiler/runtime source growth cannot exceed ISO
C's guaranteed string-literal translation limit.

LLVM-native builds no longer compile or link `runtime/abla_runtime.c`. The
remaining C platform adapter has a private layout-compatible bridge for values
crossing selected portable capabilities, exports no legacy value-runtime
symbols, and is checked with native platform fixtures. The
portable generated-C bootstrap continues to link the legacy runtime solely as
compatibility and differential-testing infrastructure.

Pure programs now select LLVM-emitted allocation/free plus a direct Linux panic
syscall and link no project C symbols. Programs that import host capabilities
retain the shared tracked allocator because C-created strings and arrays may
flow back into generated collection operations. The continuing work is below
that fixed point: the compiler's module loading, cache files, atomic outputs,
and watches use `abla/sys/linux/fs`, while diagnostics, emitted source, and the
REPL use stateful `abla/sys/linux/io`; process arguments are captured directly
and watcher sleeps continue across signals through `abla/sys/linux/process`, all
without project C symbols. The clean seed C
backend implements the same boxed pointer/syscall intrinsic contract, including
kernel-style negative errno results. Allocation generations used by REPL
reclamation are now emitted directly in LLVM, and raw Abla process management
handles compiler subprocesses. The final compiler executable contains no
project-C host capability symbols; a capability library is built and loaded
only when a JIT program selects portable host facilities.

Once `build/ablac.bin` exists, `make self-rebuild` performs the ordinary
development bootstrap without stage 0 or generated C. It forces an uncached
full-graph compilation by the native Abla compiler, audits the resulting
compiler for project-C symbols, requires byte-identical self-emitted LLVM, and
uses that compiler to build and run another native program. Clang/LLD remains
the native linker driver; it does not compile project C/C++ in this workflow.
Clean bootstrapping from an empty build directory still retains the C++/C seed
until a reviewed distributable seed artifact policy exists.

`serve` now retains a pure-Abla module snapshot store across generations.
Unchanged source/import scans are reused, same-length leaf edits invalidate one
snapshot, changed import edges construct the correct new active graph, and
dependency-fingerprinted staged ASTs safely include imported compile-time
subparser providers. One current AST is retained per module path to keep edit
history bounded.
The next incremental rung is serializable typed module interfaces and
independent objects. TCP, listener polling, and graceful `SIGTERM` draining are
now raw Abla Linux code, and both AOT and JIT HTTP gates prove that no project C
capability library is linked or loaded. Remaining work includes typed
kernel-error results, broader native conformance, and making stage 0 optional
for ordinary self-rebuild workflows and eventually clean bootstrap work.
