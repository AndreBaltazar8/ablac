# Bootstrap and architecture

This describes the existing compatibility bootstrap. The target seed policy
and the staged removal of C, libc, libLLVM, startup assembly, and external
linkers are specified in [full-self-hosting.md](full-self-hosting.md).

## Compiler stages

- **stage 0 (`ablac0`)** — C++20 compatibility compiler retained as a
  bootstrap oracle until a reviewed binary-seed policy replaces it in normal
  clean builds.
- **stage 1 (`ablac1`)** — compiler written in Abla and compiled by stage 0.
- **stage 2 (`ablac2`)** — the same Abla compiler compiled by stage 1.

Bootstrap succeeds only when stage 1 and stage 2:

1. pass the same language conformance suite;
2. produce semantically equivalent output for the compiler and standard
   library;
3. produce byte-identical normalized backend output for deterministic inputs.

The checked-in Abla compiler remains readable source. The current repository
does not commit a trusted stage-0 binary; the freestanding release plan will
publish a reviewed, versioned seed artifact with a reproducible manifest.

## Stage-0 pipeline

```text
UTF-8 source
  -> loss-aware lexer
  -> owned syntax tree with source spans
  -> module graph
  -> name resolution
  -> typed IR
  -> compile-time VM and reflection transactions
  -> lowered IR
  -> bootstrap C or native LLVM backend
  -> object file and native linker
```

Parsing, resolution, typing, compile-time execution, lowering, and emission are
separate passes. AST nodes do not store LLVM/C objects or host-language
closures. This is essential for serialization, reflection, testing, and
self-hosting.

## Compile-time VM

Stage 0 initially interprets typed IR. The VM value model is target-independent
and uses explicit integer widths. It provides:

- deterministic allocation with tracing garbage collection;
- call frames and closures;
- objects, arrays, strings, nullable values, and reflection handles;
- native calls registered by module and signature;
- resource limits and an execution trace for diagnostics.

The same lowered functions feed the VM and generated-C backend. This prevents a
second, subtly different compile-time language.

Compiler transformations use immutable syntax values and transactions:

```text
begin -> read stable snapshot -> build replacement -> type-check -> commit
```

An edit invalidates the smallest affected dependency region. Compile-time code
is rerun only when its inputs or capabilities change.

## Runtime and ABI

Generated C is a portable bootstrap backend, not the public ABI definition.
The production backend is LLVM and emits native objects without C as an
intermediate language; see `docs/llvm-backend.md`.
The runtime owns:

- strings and arrays (`data`, `length`, `capacity`);
- object allocation and type metadata;
- panic and bounds checks;
- optional garbage collection;
- platform hooks.

Host libc adapters live separately from the core runtime. The current
production compiler still uses libLLVM and its hosted dependencies. The
planned baseline machine-code/ELF backend consumes the same lowered IR and ABI
description without them.

## Repository layout

```text
include/abla/    stage-0 public C++ interfaces
src/             stage-0 implementation and CLI
tests/           unit, diagnostic, conformance, and execution tests
stdlib/          standard library written in Abla
bootstrap/       self-hosted compiler written in Abla
docs/            language and architecture contracts
tools/           developer utilities
```

## Milestones

1. Loss-aware lexer, parser, spans, diagnostics, AST snapshots.
2. Symbols, modules, type checking, and typed IR.
3. Typed-IR interpreter and `#` evaluation.
4. Generated-C backend and host runtime.
5. Compatibility suite for all original executable examples.
6. Stable compiler reflection and transactional AST editing.
7. Core, collections, text, I/O, filesystem, math, and concurrency libraries.
8. Abla implementation of lexer through backend.
9. Three-stage bootstrap and reproducibility gate.

Each milestone must add positive, negative, and regression tests. Unsupported
syntax receives a diagnostic; it must never silently miscompile.

### Current stage-0 invariants

- Canonical absolute paths identify modules; repeated imports share one parsed
  module and source import edges remain observable.
- Import cycles and missing files are diagnostics attached to the importing
  expression.
- Every module has an isolated top-level scope. Prototype imports expose names
  transitively, but never merge mutable symbol tables.
- Symbols receive deterministic numeric IDs and AST nodes contain no semantic
  or backend pointers.
- Semantic types are canonical IDs. `int` aliases signed 64-bit `i64`; `null`
  is a distinct type and only assigns to explicitly nullable types.
- Resolution and type checking accumulate independent errors instead of
  throwing after the first invalid construct.
- Lowered IR uses explicit locals, register values, globals, initializer
  functions, basic blocks, and terminators. Its verifier runs before execution
  or backend emission.
- Runtime and compile-time evaluation share the same bounded IR machine.
  Scalar `#expression` results become direct constant instructions. Arrays and
  objects become deterministic, pointer-free frozen constant graphs. Each use
  reconstructs a fresh runtime graph while preserving internal sharing; cycles
  are rejected. No compile-value placeholder may reach a backend.
- Native functions are reached only through an explicit `(library, name)`
  registry. The VM never performs ambient dynamic-library lookup.
- Generated C uses a stable tagged-value runtime ABI rather than leaking C++
  layouts. Its freestanding core depends on allocation, deallocation, and panic
  hooks; the host adapter is the only layer that imports libc.
- Native C declarations accept only explicitly supported ABI types. VM/native
  parity programs are compiled with strict C11 warnings promoted to errors.
