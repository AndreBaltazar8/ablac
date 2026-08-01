# Abla status

Lean handoff for the next session. Design discussion belongs in the focused
documents and RFCs, not here. The exact no-C/no-libc route and proof boundary
are in [full-self-hosting.md](full-self-hosting.md).

## Goal

Ship a reliable, fast, LLVM-native Abla compiler and standard library that can
build their own pure-Abla sources, reach a reproducible fixed point, and remain
the compiler used to evolve the language. Production Abla programs must not
require libc; hosted facilities are optional capabilities.

## Handoff state

- `build/ablac.bin` is the last promoted self-hosted compiler;
  `build/ablac` is its 4 GiB watchdog wrapper.
- `build/ablac-linkage1` is an unpromoted candidate. Stable-linkage and native
  partition-cache tests passed; a body edit refreshed 1 of 4 object buckets.
- The current source separates stable function linkage from content-keyed
  object reuse and always hashes extracted LLVM before accepting a cache hit.
- The current source is **not green**: building the next compiler produced
  `build/ablac-linkage2.ll`, and LLVM verification reports undefined label
  `%indirect_726` at line 383418. Do not promote this candidate.
- Memory work is not the immediate priority. Resume the backend/self-host path
  first, then move through the non-memory work below.

## Priority queue

### 1. Restore a green incremental native backend

- Fix the missing indirect-dispatch block in `build/ablac-linkage2.ll` and add
  a focused regression for address-taken functions and captured lambdas.
- Rebuild the compiler from the current sources and rerun stable linkage,
  lowered-IR reuse, object-partition reuse, and stale-callee checks.
- Keep linkage identities independent of bodies and GC behavior; keep cache
  identities dependent on the complete extracted LLVM partition.
- Move LLVM splitting from `llvm-extract` into the in-process backend.
- Make partition/object publication fully transactional and interruption-safe.

### 2. Promote a proven fixed-point compiler

- Perform an uncached compiler build under the 4 GiB/240s watchdog.
- Rebuild with that compiler and require byte-identical emitted compiler IR.
- Run final native conformance, compile-time/runtime differential tests,
  ownership/CFG/IR verification, and the raw libc-free audit.
- Promote to `build/ablac.bin` only after every gate passes.

### 3. Finish modules, packages, and the landed RFCs

- Add dependency tables, deterministic lockfiles, vendoring, offline builds,
  capability inheritance, package diagnostics, and reproducible resolution.
- Finish acceptance and documentation for all RFCs in `rfc/`: canonical module
  paths, verified global-array mutation, libc-free Linux, and typed subparser
  metadata/code generation.
- Keep runtime and compile-time imports on one coherent module model.

### 4. Finish the language safety and type layer

- Complete checked generics, coherent interfaces/constraints, inference, and
  exhaustive diagnostics across modules.
- Finish remaining aggregate lifetime relations and closure-capture cases.
- Preserve safe ownership/borrowing as the default; isolate unavoidable raw
  operations behind explicit, capability-checked APIs.
- Add tasks, channels, cancellation, structured concurrency, and race gates.

### 5. Finish unified compile-time/runtime extensibility

- Harden Abla-authored, typed, hygienic, stackable `$name` subparsers.
- Support nested parser handoff such as Abla expressions inside `$html`, rich
  source spans, recovery, deterministic staging, and parser composition.
- Make the same libraries usable at compile time and runtime, with effects
  divided into deterministic/cacheable capabilities and explicit ambient ones.
- Finish compiler reflection, generated modules, and stable compiler APIs.

### 6. Finish the portable standard library

- Stabilize host-neutral bytes/text, console, files, paths, processes, clocks,
  environment, sockets, JSON, HTML, and compiler-facing APIs.
- Add async/streaming I/O, HTTP streaming, and optional concrete TLS packages.
- Finish the Abla HTTP server/router, including typed routes, middleware,
  graceful reload, and header-selected coexisting endpoint versions.
- Add small runnable server examples and ensure unused modules/native methods
  are dead-stripped so basic programs stay tiny.

### 7. Finish targets and execution modes

- Add another supported target and enforce cross-target ABI/capability gates.
- Keep `x86_64-linux-raw` on `_start`, direct syscalls, mmap allocation, no
  interpreter, no dynamic dependency, and no project C runtime symbols.
- Finish direct LLVM object/executable emission, fast JIT `run`, persistent
  `repl`, and `serve` with safe hot reload and state migration.
- Clarify and document the CLI contract: `run` is one-shot execution; `serve`
  is a persistent watched process intended for servers and hot reload.

### 8. Reliability, tooling, and release cleanup

- Improve source-spanned diagnostics, recovery, deterministic failures,
  incremental invalidation explanations, and debugger/profiler integration.
- Remove compatibility-only C/C++ production paths and obsolete runtime code;
  retain only the documented minimal seed needed for a clean bootstrap.
- Publish clean bootstrap, release, cache, package, and contribution workflows.
- Keep `docs/status.md` below 200 lines and remove items as they are completed.

### 9. Performance after correctness

- Persist parsed/typed/lowered summaries across invocations.
- Avoid whole-module LLVM optimization and linking after local edits.
- Profile allocation, hashing, parsing, lowering, optimization, and linking;
  eliminate algorithmic hot spots before micro-optimizing.
- Targets: cold full compiler build under 10s, then as close to 1s as practical;
  warm local edits and `run`/reload near 1s or better.

## Required release gates

- Clean seed -> native Abla compiler -> compiler rebuild -> identical LLVM IR.
- Every compiler process bounded by the 4 GiB watchdog and time limit.
- Final native conformance and compile-time/runtime differential suites pass.
- Ownership, borrows, captures, CFG/SSA, IR verifier, and concurrency gates pass.
- Incremental body/signature/module edits never reuse stale code.
- Cache/output writes remain transactional under failure and interruption.
- `build`, `run`, `repl`, and `serve`/hot reload pass end-to-end workflows.
- Package resolution is deterministic and works vendored/offline.
- Raw binaries have no libc, ELF interpreter, dynamic dependency, undefined
  symbol, project host symbol, or project C runtime dependency.
- Compiler and standard library can continue being modified and rebuilt in
  pure Abla without returning to the bootstrap implementation.
