# Abla status

This is the lean handoff for the current tree. Design detail belongs in the
focused documents; the no-C/no-libc proof boundary is in
[full-self-hosting.md](full-self-hosting.md).

## Goal

Ship a reliable, fast, LLVM-native Abla compiler and standard library that can
build their own pure-Abla sources, reach a reproducible fixed point, and remain
the compiler used to evolve the language. Production Abla programs must not
require libc; hosted facilities are optional capabilities.

## Current state

- The self-hosted compiler builds directly through LLVM and reproduces its
  generated LLVM module byte-for-byte at the fixed point.
- The hosted compiler and ordinary Abla programs build and run natively on
  x86-64 Linux plus Intel and Apple Silicon macOS; the macOS gate covers
  Mach-O emission, ORC, console, filesystem, and child-process behavior.
- The final-native conformance manifest covers 73 isolated tests. Focused gates cover
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
- Android and WASM/MVC are extension-owned proofs. Target extensions may pass
  any triple supported by the installed LLVM for object or static-library
  emission; linking remains guarded by an explicit format/linker contract.
  The compiler contains only generic target, artifact, ABI, capability, and
  graph machinery.
- Compile-time import-provider functions resolve Git/GitHub packages through
  immutable commit/tree locks, bounded transactional caches, offline mode, and
  a complete vendor fallback. Root manifests retain dependency capability
  authority.
- A current uncached fast full self-build was measured at 27.162 seconds. The
  dominant phases are semantic analysis and lowering; unchanged whole-graph
  builds use the content cache.
- Networking now includes affine IPv4/IPv6 TCP and UDP, bounded DNS A/AAAA,
  structured timeout/EOF/error results, raw epoll, hosted epoll/kqueue,
  certificate-verified TLS/HTTPS/WSS transports, and secure random on Linux and
  macOS. The bounded event HTTP/WebSocket managers support persistent requests,
  chunked bodies, gzip, SSE framing, partial writes, and output backpressure;
  JSON/RPC routing remains transport-neutral.
- Application-sized ELF modules place generated functions in independent text
  sections, allowing the existing linker garbage collection to discard unused
  imported APIs. The transformation is bounded so large compiler modules keep
  their lower-memory partitioned/global-DCE path; Mach-O and Wasm IR remain
  target-neutral.

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
2. Continue the language safety/type layer: checked generics, interfaces,
   inference, aggregate lifetime cases, and concurrency primitives.
3. Grow host-neutral standard libraries and extension-owned Android/WASM
   packages on top of the generic compiler contracts.
4. Add signed package/registry identities above the immutable provider/lock
   foundation when the ecosystem needs hosted distribution.

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
