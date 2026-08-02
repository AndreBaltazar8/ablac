# Abla status

This is the lean handoff for the current tree. Design detail belongs in the
focused documents and RFCs; the no-C/no-libc proof boundary is in
[full-self-hosting.md](full-self-hosting.md).

## Goal

Ship a reliable, fast, LLVM-native Abla compiler and standard library that can
build their own pure-Abla sources, reach a reproducible fixed point, and remain
the compiler used to evolve the language. Production Abla programs must not
require libc; hosted facilities are optional capabilities.

## Current state

- The self-hosted compiler builds directly through LLVM and reproduces its
  generated LLVM module byte-for-byte at the fixed point.
- The final-native conformance suite covers 49 programs. Focused gates cover
  the raw libc-free target, compiler extensions, programmable builds, Android
  cross-builds, and WASM/MVC modules.
- Compile-time code has bounded effect grants and can inspect resolved types,
  generate validated modules/files, register targets, request recursive program
  nodes, and publish outputs transactionally.
- Program graphs produce executables, object files, static/shared libraries,
  and WebAssembly modules. Failed graphs restore prior artifacts and remove new
  generated files.
- Foreign exports have a versioned ABI manifest, value-safe scalar and copied
  byte inputs, owned byte results, call-scoped callbacks, and an opt-in checked
  boundary on supported hosted targets.
- Android and WASM/MVC are extension-owned proofs. The compiler contains only
  generic target, artifact, ABI, capability, and graph machinery.
- A current uncached fast full self-build was measured at 27.162 seconds. The
  dominant phases are semantic analysis and lowering; unchanged whole-graph
  builds use the content cache.

Generated binaries and caches stay under ignored `build/`; Git contains source,
documentation, tests, and build/tool definitions only.

## Programmable foundation boundary

The general programmable compiler foundation is complete for this milestone.
Platform libraries can now own their workflows: an Android extension can define
the toolchain graph around `libabla_app.so`, while a WASM/MVC extension can emit
a module plus a thin host adapter. APK packaging, signing, SDK discovery,
Kotlin/Gradle policy, DOM/canvas rendering, hydration, and application frameworks
remain libraries and extensions, not compiler responsibilities.

The next general-purpose increments are module-granular typed-IR reuse, explicit
artifact dependency edges, independently declared sidecars, richer target
capability negotiation, and external-tool resource accounting. They are
follow-on performance and API work, not blockers for the foundation milestone.

## Next priorities

1. Reduce cold semantic-analysis and lowering cost without weakening fixed-point
   or conformance gates; preserve the warm cache path.
2. Finish deterministic package resolution, lockfiles, vendoring, and offline
   builds.
3. Continue the language safety/type layer: checked generics, interfaces,
   inference, aggregate lifetime cases, and concurrency primitives.
4. Grow host-neutral standard libraries and extension-owned Android/WASM
   packages on top of the generic compiler contracts.
5. Resolve the remaining focused RFCs under `rfc/`, changing their proposed
   designs where a smaller or safer contract is better.

## Required release gates

- Clean seed to native compiler to byte-identical compiler rebuild.
- Bounded compiler processes and deterministic failure under resource limits.
- Final-native conformance and compile-time/runtime differential suites.
- Ownership, borrow, capture, CFG/SSA, IR-verifier, and concurrency gates.
- No stale code after body, signature, module, capability, or observed-input
  changes.
- Transactional cache/output publication, including recursive program graphs.
- End-to-end `build`, `run`, `repl`, and `serve` workflows.
- Deterministic vendored/offline package resolution.
- Raw targets with no libc, ELF interpreter, dynamic dependency, undefined
  project host symbol, or project C runtime dependency.
- Continued compiler and standard-library evolution in pure Abla without
  returning to the bootstrap implementation.
