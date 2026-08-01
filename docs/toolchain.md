# `ablac` toolchain interface

The final tool is one self-hosted native `ablac` executable. C emission remains
an optional bootstrap/debug backend in `bootstrap/compiler/main.ab`, not part
of the production `orc_main.ab` compiler graph or the normal user workflow.

```sh
ablac build app.ab -o build/app
ablac build app.ab -o build/app --fast
ablac build app.ab -o build/app --fast --no-cache
ablac run app.ab
ablac repl
ablac serve app.ab
```

## Build

`build` loads the module graph, executes bounded compile-time actions, verifies
typed IR, emits LLVM objects, and links the requested executable or library.
The default release profile runs the deterministic `default<O2>,globaldce`
pipeline. `--fast` skips whole-module optimization and selects LLVM's
low-latency code generator for edit/build cycles. It still runs the complete
frontend, compile-time evaluator, verifier, object emitter, and linker; it is
not a cached or partial build. The default output is a native executable under
`build/`.

Native objects are cached under `build/.abla-cache`. A hit requires an exact
comparison of the complete bundled source after matching its length, two
independent deterministic fingerprints, target/LLVM ABI version, and
optimization profile. Cache manifests are published only after successful
object emission. The entry manifest is part of the identity. Successful
`filesystem.read` staging records every observed path, content size, and two
content fingerprints; a hit re-reads and validates those inputs before it may
skip the frontend. Corrupt input records are misses. Ambient effects without a
deterministic input contract remain uncached. Subparser handlers and generated-
module finalizers merge their transaction-local read journals into the same
artifact identity. Persistent frontend snapshots revalidate those inputs
before reusing staged syntax. A hit skips
frontend and LLVM work, restores the recorded
libLLVM/host-adapter link decisions, recompiles the C adapter only when the
program imports a host capability, and relinks. Local adapter changes are never hidden. The
cache ABI tag in `bootstrap/compiler/toolchain.ab` must be bumped whenever
object semantics change without a corresponding source-graph change.
`--no-cache` bypasses both lookup and publication while still emitting the
`.ll`/object sidecars. It is the reproducibility and profiling mode used by the
pure self-rebuild gate; options after the source are order-independent.

Long-lived builds additionally retain a module snapshot store in pure Abla.
Each snapshot atomically associates source text, scanned import edges, two
content fingerprints, and the observed file size/revision. On a watched
rebuild, unchanged modules reuse both their source and dependency scan; a
changed module refreshes only its own snapshot, and changed import edges select
the new active graph without accidentally retaining the old dependency. This
state also caches one dependency-fingerprinted staged AST per module path.
Imported compile-time subparser registrations participate in that fingerprint,
so changing a parser provider invalidates every later syntax tree that could
have invoked it. Keeping one AST version per path bounds edit-history growth.
This is deliberately distinct from the whole-graph native object cache. Typed
interfaces and independently emitted module objects are the next granularity
step; an edited graph still goes through whole-program semantic analysis and
code generation today.

## Run and REPL

`run` executes the same verified IR without compiling through C. The current
bootstrap milestone executes textual LLVM IR with the Abla-authored ORC binding
inside the final compiler process, avoiding object emission and native linking.
When that IR selects a portable host capability, `run` builds and permanently
loads a small PIC adapter before creating the ORC generation; host-free runs
skip the adapter entirely.
The bootstrap compiler retains a separate runner until the C bootstrap path is
retired. The current `repl` retains one LLJIT session, compiles integer
expressions transactionally, unloads each generation through an ORC resource
tracker, and closes a compiler-checked lexical `region`. Retaining declarations,
module interfaces, semantic indexes, and compile-time values across inputs is
the next incremental-compilation rung.

The interpreter is not a second language implementation. Compile-time `#`
evaluation, `run`, tests, the REPL, and macro/subparser handlers share the same
instructions, values, limits, native registry, and diagnostics. The JIT is a
different execution backend for that IR and must pass interpreter/JIT parity.

## Serve

`serve` is a persistent run mode intended for HTTP servers, build daemons, and
interactive applications. It content-fingerprints the complete imported module graph and
swaps code only after parsing, typing, compile-time actions, LLVM emission, and
native linking succeed. Watched rebuilds use the fast AOT profile. A failed edit leaves the previous valid generation
running. The supervisor currently uses validated native worker processes. An
Abla HTTP worker handles `SIGTERM` as a drain request: it completes the active
request, stops accepting, closes its listener, and exits. The supervisor waits
up to five seconds before force termination, then starts the next generation.
ORC resource trackers already support in-process code reclamation; moving the
network worker itself into that session remains a later concurrency milestone.
The supervisor retains module snapshots across accepted and rejected
generations, reports refreshed/reused module counts, and updates its watch set
from the newly active import graph.

Thus `run` is a one-shot JIT execution, while `serve` is the watched,
reload-safe long-running supervisor. Both can run an HTTP server; only `serve`
observes source changes and retains the last valid generation.

An ordinary compile-time action remains bounded and terminating. Network,
filesystem mutation, processes, clocks, and other ambient effects require
explicit capabilities and become recorded build inputs where reproducibility
is requested. A long-running server belongs to `run`/`serve`, even when its
startup and reload path evaluates compile-time Abla code.

## Resource safety

Compiler subprocesses and bootstrap generations always run behind the project
resource guard. The guarded `build/ablac` launcher enforces address-space,
wall-clock, CPU, and core-dump limits. REPL evaluations additionally use a
checked lexical allocation region and ORC resource tracker. The same region
checker is available to HTTP libraries, though request-handler adoption still
needs an explicit API policy for promoted response values and long-lived state.

The complete compiler rebuild uses the same public command as every program:
`ablac build bootstrap/compiler/orc_main.ab -o build/ablac-next`. It runs under
a four-GiB address-space and time watchdog, and native output publication is
transactional. `tools/build-self-hosted-release.sh` remains a lower-peak
recovery/bootstrap path that splits deterministic LLVM emission, object
optimization, and linking into guarded processes.
