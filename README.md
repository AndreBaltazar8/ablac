# ablac

`ablac` is a clean-room implementation of the Abla programming language.
Abla is a statically typed, expression-oriented language with Kotlin-inspired
syntax and first-class compile-time execution. A program should be able to use
the same Abla library in either phase and deliberately inspect or transform the
program being compiled.

This repository contains:

- a C++20 seed compiler (`ablac0`) retained for clean-room bootstrap checking;
- the Abla runtime and standard library;
- compatibility tests derived from the public behavior of `../abla-original`;
- a self-hosted compiler, built in stages once the bootstrap language is rich
  enough.

The design is specified in [docs/language.md](docs/language.md), and the
bootstrap invariants are in [docs/bootstrap.md](docs/bootstrap.md). The
[original implementation audit](docs/original-audit.md) records what is real,
partial, and only planned. We preserve
the useful surface syntax of the prototype, including optional semicolons,
while making incomplete or accidental behavior explicit.

## Development

Enter the reproducible environment and run the checks:

```sh
nix-shell
make check
```

Useful targets:

```sh
make                 # build build/ablac0
make test            # unit and integration tests
make bootstrap-check # check Abla-written compiler components and emitted C
make bootstrap-stage1 # build the current native self-host subset compiler
make bootstrap-selfhost # prove stage-2 behavior and byte-identical fixed point
make bootstrap-llvm-selfhost # prove the complete LLVM-native compiler fixed point
make ablac             # build the optimized guarded build/ablac user compiler
make benchmark-selfhost # measure self-hosted source-to-C and source-to-native time
make compat-original # parse every original example (requires ../abla-original)
make compile SOURCE=program.ab OUTPUT=build/program
make sanitize        # rebuild and test with ASan/UBSan
make clean
```

The stage-0 CLI can tokenize, parse, load imports, resolve names, and type-check
a source file. It can also print verified IR or execute it in the same bounded
machine used for compile-time evaluation:

```sh
build/ablac0 tokens example.ab
build/ablac0 parse example.ab  # syntax only
build/ablac0 check example.ab  # imports and name resolution
build/ablac0 ir example.ab     # verified backend-neutral typed IR
build/ablac0 emit-c example.ab # deterministic portable C
build/ablac0 run example.ab    # execute verified IR in the bounded VM
```

After `make ablac`, the self-hosted user interface is:

```sh
build/ablac build app.ab -o build/app
build/ablac build app.ab -o build/app --fast
build/ablac build app.ab -o build/app --fast --no-cache
build/ablac build app.ab --target x86_64-linux-raw -o build/app.raw
build/ablac run app.ab
build/ablac repl
build/ablac serve app.ab
```

On NixOS these commands lazily enter the pinned `nix-shell` when the LLVM tools
are not already on `PATH`; `--emit-llvm` remains a direct compiler-only command.
`run` executes emitted IR through LLVM ORC inside `ablac`; `build` performs
LLVM O2 optimization and object emission through libLLVM in the same process,
then links the executable. `--fast` skips whole-module optimization and uses
LLVM's low-latency code generator; O2 remains the release default.
`x86_64-linux-raw` links directly with LLD and emits a static ELF with its own
startup, syscall allocator, and memory primitives: no CRT, libc, ELF
interpreter, or dynamic dependency. The target rejects source that selects a
host or LLVM runtime capability instead of silently reintroducing one.
Unchanged builds reuse an exact-source/profile-keyed native object and still
relink against the current selected capabilities. `repl` retains one LLJIT and
reclaims each evaluated generation. `serve` retains per-module source/import
snapshots and dependency-fingerprinted staged ASTs, selects the
fast profile, watches the complete import graph, rejects invalid edits,
and gracefully drains an active HTTP request before a validated native worker
is replaced. TCP, polling, and graceful `SIGTERM` handling are raw Abla Linux
code; the AOT and JIT HTTP gates use no project C capability library.

No generated files are committed. Build products stay under `build/`.

`make test` compares VM execution with independently compiled native programs
and compiles generated C with warnings promoted to errors. The parity suite
covers recursion, loops, growable arrays, byte-indexed strings, lambdas, scalar
and compound compile-time values, compiler reflection, `$json`/`$html`
subparser expressions in both phases (including an Abla-authored JSON parser), classes,
interpolated strings, early `return` in runtime and compile-time code,
standard-library imports, and an explicit C ABI call.

The current bootstrap rung is documented in
[docs/self-hosting.md](docs/self-hosting.md), and the exact remaining route to
a compiler/toolchain requiring neither C nor libc is
[docs/full-self-hosting.md](docs/full-self-hosting.md). The Abla-written compiler now
compiles its complete source graph directly to LLVM, and that native compiler
reproduces byte-identical LLVM IR for itself. Its `build`, `run`, and `serve`
commands are implemented in Abla, and generated LLVM contains the tagged-value,
closure, collection, object, rope-string, and pure-program allocator/panic
runtime. Pure and target-backed `abla/io`, `abla/fs`, and `abla/process`
programs link no project C symbol; explicit host-capability calls select the
ABI-compatible tracked adapter. The compiler itself now performs module,
cache, watch, terminal, argument, and sleep operations through raw Abla Linux
modules, and watched rebuilds refresh only changed module snapshots. The
compiler has no active project-C host capability. It still dynamically links
the C++-implemented `libLLVM` and the hosted system runtime, while the raw
target still uses Clang/LLD to compile startup assembly and link. Those are
explicit remaining dependencies, alongside the clean-bootstrap seed policy.
The current compiler no longer
invokes `opt` or `llc`; `abla/sys/linux` lowers x86-64 syscalls directly. Native
LLVM builds also no longer compile or link the legacy `abla_runtime.c`; it is
retained only for generated-C bootstrap and differential tests.

After the first clean bootstrap, `make self-rebuild` takes the project-C-free
source path: it
forces the native Abla compiler to recompile its complete Abla source graph
without the object cache or project C/C++ compilation, verifies byte-identical LLVM, and
builds a child program with the result. `--no-cache` is also available directly
for reproducibility and profiling. Authorized compile-time filesystem reads,
including reads performed by subparser handlers/finalizers, are journaled into
the native artifact identity and revalidated before frontend or object-cache
reuse; unsupported ambient effects remain uncached.

The standard-library layout and minimal-binary rules are in
[docs/standard-library.md](docs/standard-library.md). A working version-aware
HTTP example is [examples/versioned-http-server.ab](examples/versioned-http-server.ab).
The gated path from the current fixed point to safe memory, hermetic
compile-time execution, production reliability, and clean-bootstrap trust is
specified in [docs/reliability-roadmap.md](docs/reliability-roadmap.md).
Native runtimes enforce a one-GiB default cumulative tracked-heap budget,
including libc-free executables; `abla/memory` can inspect or explicitly change
it. Its tracing collector reclaims unreachable cycles using compiler-emitted,
higher-order-aware roots and precise allocation-layout maps. Calling
`memorySetLimit` opts a program into bounded automatic pressure safe points;
affine native storage is pinned until its deterministic drop or region reset.
