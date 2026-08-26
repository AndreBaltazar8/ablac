# `ablac` toolchain interface

The final tool is one self-hosted native `ablac` executable. C emission remains
an optional bootstrap/debug backend in `src/main.ab`, not part
of the production `orc_main.ab` compiler graph or the normal user workflow.

The public `ablac` launcher resolves compiler-owned standard-library and
runtime sources from its toolchain root, independently of the caller's working
directory. Installed or custom layouts may override that root with
`ABLA_SYSROOT`; `ABLA_STDLIB` remains available as a narrower standard-library
override. Project inputs, outputs, and caches continue to use project or
invocation-relative paths.

```sh
ablac build app.ab -o build/app
ablac build app.ab -o build/app --fast
ablac build app.ab -o build/app --fast --no-cache
ablac run app.ab
ablac repl
ablac serve app.ab
```

Built-in hosted targets are `x86_64-linux`, `x86_64-macos`, and
`arm64-macos`. Cross-linking Mach-O on Linux requires `ABLA_MACOS_SDK`; optional
`ABLA_MACOS_LLVM_LIB` and `ABLA_MACOS_OPENSSL_LIB` select directories holding
target dylibs or `.tbd` stubs. `tools/build-macos-from-linux.sh` prepares the
stubs from the pinned target-library ABIs and builds both Mac architectures.

## Packages

`ablac package update --project <dir>` evaluates typed `ImportSource`
expressions, resolves Git selectors or invokes deferred custom resolvers, and
transactionally publishes an immutable `abla.lock` plus validated cache
entries. Project builds prepare the locked graph before module loading without
invoking custom resolvers; `--offline` forbids Git fetching.
`ablac package vendor --project <dir>` publishes the complete locked source
graph under `vendor/`. The provider and lock contract is specified in
`docs/packages.md`.

## Build

`build` loads the module graph, executes bounded compile-time actions, verifies
typed IR, emits LLVM objects, and links the requested executable or library.
`--emit executable|object|static-library|shared-library` selects the hosted
artifact container; executable remains the default. Libraries without `main`
must explicitly publish at least one supported foreign adapter through the
compiler API; internal Abla symbols remain hidden.
Programmable external targets can additionally request a generic `module`
artifact. The current WebAssembly linker produces a no-entry module, preserves
explicit foreign exports, retains unresolved symbols from explicit foreign
declarations as ordinary `env` function imports, and strips PID-bearing name
metadata for byte-level reproducibility. The embedding runtime must validate
the imported symbol names and signatures before instantiation.

An extension-defined target with linker flavor and emulation `none` may use
any object triple implemented by the installed LLVM and emit an `object` or
`static-library`. LLVM target registration is not architecture-specific.
Executables, shared libraries, and modules require an explicit supported
runtime/linker contract; a target descriptor cannot silently imply a host ABI,
startup sequence, sysroot, or platform linker.
There is currently no built-in freestanding executable target. Defining an
LLVM object triple does not silently imply a host ABI, startup sequence,
allocator, sysroot, or executable-link contract.

Every successful artifact publishes `<output>.abi.json` through the compiler's
staged-output transaction after linking. The versioned manifest is derived
from resolved export requests rather than handwritten platform glue and
includes target/artifact identity plus
ownership, nullability, and failure-containment metadata. It is a member of the
native cache record, so a cache hit restores a missing sidecar instead of
silently publishing an undocumented binary. Schema version 1 exposes value
scalars, copied borrowed-byte inputs, call-scoped non-escaping scalar
callbacks, and owned-byte result handles. Direct exports honestly mark panics
as uncontained. Opt-in checked exports on hosted x86-64 Linux and macOS publish their
status/out-pointer/caller-buffer ABI and abortive-cleanup semantics; unsupported
targets reject them with `E_EXPORT_TARGET_CAPABILITY` rather than silently
downgrading containment.
The current owned-byte result handle is available only when the target provides
the libc allocation contract; libc-free module targets reject it before object
emission.

The default hosted release profile runs the deterministic
`default<O2>,globaldce` pipeline. Release builds for MCU triples use
`default<Oz>,globaldce`; the target still receives LLVM's optimized machine-code
generator, while whole-program optimization prioritizes constrained flash.
Hosted `--fast` skips whole-module optimization and selects LLVM's low-latency
code generator for edit/build cycles. External cross targets run a bounded
`default<O1>,globaldce` pass in fast mode, because target lowering must not
validate unreachable host-only runtime assembly. It still runs the complete
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
libLLVM/host-adapter link decisions, recompiles the Darwin adapter for Mach-O,
and relinks. Local adapter changes are never hidden. The
cache ABI tag in `src/toolchain.ab` must be bumped whenever
object semantics change without a corresponding source-graph change.
`--no-cache` bypasses both lookup and publication while still emitting the
`.ll`/object sidecars. It is the reproducibility and profiling mode used by the
pure self-rebuild gate; options after the source are order-independent.

Compile-time build definitions may register additional program nodes through
the versioned compiler API. After the root succeeds, `build` drains the bounded
graph in declaration order; a requested program may add further nodes. This
mechanism is target- and framework-neutral—the compiler executes program,
artifact, and bounded external-target requests, while libraries own Android,
WASM, MVC, RPC, or packaging policy. The Android arm64 shared-library and
WASM/MVC module proofs plus remaining transaction/ABI work are documented in
`docs/programmable-builds.md`.

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

## Compiler diagnostics

Every failed compilation renders at least one primary `error[E_*]` diagnostic
for every counted error. Parser diagnostics carry the normalized module source
identity and byte range. Extension-generated declarations additionally retain
their generated namespace and originating extension-expression range through
semantic analysis and typed IR lowering.

Failure summaries partition the total into parser, extension, semantic, and IR
counts; those four counts always add to the displayed total. A function-level
IR verification failure names the function and invariant category. Lowering or
emission failures that cannot be associated with a function use the explicit
`E_IR_UNCLASSIFIED` or `E_IR_EMISSION` fallback rather than disappearing into
the aggregate count.

`E_NATIVE_TOOLCHAIN` is reserved for a nonzero result from an external native
compiler, linker, or archiver. Compiler diagnostics, unsupported target or
artifact requests, and filesystem publication failures retain their own error
codes and are not relabelled as native-toolchain failures.

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

The complete compiler rebuild uses
`tools/build-self-hosted-release.sh build/ablac.bin build/ablac-next`. It splits
deterministic LLVM emission, object generation, and linking into separate
bounded processes so the frontend and LLVM object-generation heap peaks do not
coexist. After emission it may reuse an optimized executable only from an exact
content-addressed match over the module, runtime inputs, host, toolchain, and
release profile. `ABLA_RELEASE_SELFHOST_CACHE=0` forces a cold backend. The
release gate still verifies byte-identical IR from the rebuilt compiler.
