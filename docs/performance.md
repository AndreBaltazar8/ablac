# Compiler performance contract

Correctness and full self-hosted conformance come first. Once the pure-Abla
compiler accepts the complete language surface, optimization proceeds against
reproducible measurements rather than ad-hoc timings.

Run the current end-to-end rebuild benchmark with:

```sh
make benchmark
```

The benchmark reports complete source-to-executable time and output size.
For phase diagnosis, measure `ablac --emit-llvm` separately from the native
build; the former covers parsing, semantic analysis, lowering, and LLVM text
emission, while the latter additionally includes LLVM optimization, parallel
object emission, and linking.

## Pure-Abla runtime rebuild profile (2026-08-17)

Replacing the C runtime exposed a release-builder regression rather than an
intrinsic cost of the Abla frontend. The builder split the 34.36 MB compiler
module before ordinary interprocedural optimization. That reduced backend
latency, but the resulting compiler repeatedly crossed partition boundaries
for hot semantic/runtime operations. A clean full LLVM emission took 309.5
seconds and 1,727,684 KiB peak RSS.

The release path now runs whole-module O1 plus a focused SCCP/GVN cleanup
before splitting into twice the available worker count, then emits O2 machine
code concurrently. The worker count defaults to `nproc`, is capped at 32, and
can be bounded explicitly with `ABLA_NATIVE_JOBS`. A top-level function
declaration hash index also replaces repeated full declaration scans for
parameter metadata in semantic analysis. On the same 32-thread i9-13900K host,
the selected follow-up profile measured a 43.95-second backend and a
17.47-second generated-compiler frontend. This is statistically tied with the
61.34-second lowest-total candidate while retaining its faster frontend.

| Phase | Before | After |
|---|---:|---:|
| Compiler frontend and LLVM text emission | 309.5 s | 17.5 s |
| Optimized parallel backend | n/a | 44.0 s |
| Steady-state cold source-to-executable rebuild | over 5 min | 61.4 s |
| Frontend peak RSS | 1,727,684 KiB | 1,727,108 KiB |
| Backend peak RSS (largest process) | n/a | 621,860 KiB |

The measured reduction is at least 4.9x end to end and 17.7x for frontend
emission.
Peak frontend memory is not materially reduced: the full parsed, typed, and
lowered graph remains live in one process. The safe next memory step is
phase-separated or module-granular retained state, not a lower watchdog that
only hides the retained graph.

### Follow-up saturation search

A further 20-round search kept the same source module and compared partition
counts from 32 through 128, 16 through 32 workers, LLVM machine-code levels
O1 through O3, and focused cleanup combinations using DSE, ADCE, correlated
propagation, reassociation, aggressive instruction combining, loop deletion,
global optimization, and the complete O2 pipeline. No candidate produced a
repeatable end-to-end improvement over the selected O1 plus SCCP/GVN pipeline.

The closest results merely moved time between phases. Eighty partitions saved
about 0.10 seconds of frontend CPU time through code layout but added about
0.10 seconds to splitting and combining. Correlated propagation saved about
0.08 seconds in the frontend while adding about 0.07 seconds to the serial
optimizer. Both are within run-to-run noise, so neither is part of the release
configuration. O3 and full O2 produced smaller or differently laid-out
binaries but regressed total build time. Peak frontend memory remained about
1.73 GiB throughout.

The first release performance gate is a complete compiler build below 10
seconds on the reference development machine. After that, the target is a
sub-second warm/incremental build through cached module interfaces, persistent
compiler state, and minimal invalidation. Cold and clean builds remain reported
separately so caching cannot disguise front-end regressions.

Every optimization must preserve the conformance suite, stage-1/stage-2
behavioral parity, and the byte-identical `ablac2`/`ablac3`
fixed point unless an explicitly versioned deterministic-output change updates
both stages together.

`make ablac` remains timestamp-incremental. A changed compiler graph performs
an uncached optimized rebuild; `make self-rebuild` then compares consecutive
LLVM generations byte-for-byte and executes a native child. The build remains
paired with the four-GiB address-space and bounded-time release watchdogs.

The final native conformance programs remain uncached O2 builds, but independent
fixtures run concurrently under a memory-aware job cap. On the reference
development machine, all 49 builds and runtime assertions completed in 56.5
seconds with eight workers while consuming 283 aggregate CPU-seconds. Set
`ABLA_CONFORMANCE_JOBS` to override the automatically selected concurrency.

## Initial baseline

On the reference development session on 2026-07-31, before performance work:

| Phase | Time |
|---|---:|
| Pure-Abla compiler, source to C | 198,880 ms |
| C compiler, generated C to native executable | 3,853 ms |
| Total | 202,735 ms |

The profile boundary is already clear: over 98% of elapsed time is in the
current pure-Abla implementation. Expected first targets include replacing
repeated declaration/symbol scans with indexes, eliminating quadratic string
assembly in module bundling and C emission, reducing tagged heap allocation,
and caching parsed/type-checked module interfaces.

## Rope-runtime result

The initial profile identified generated-output concatenation as the dominant
failure: immutable concatenation copied the complete prefix and retained every
superseded allocation. A persistent rope with iterative one-time flattening
removed that quadratic copy/allocation path. On the same development session:

| Phase | Time |
|---|---:|
| Pure-Abla compiler, source to C | 685 ms |
| C compiler, generated C to native executable | 6,519 ms |
| Total bootstrap source-to-executable | 7,207 ms |

The pure-Abla compiler is now below one second and the legacy bootstrap path is
below ten seconds. The remaining measured bootstrap cost is external C
compilation; production work therefore targets LLVM object emission rather
than tuning the C intermediate. Full compiler LLVM coverage and an LLVM-native
self-host fixed point are now gated. The next measurements target frontend
indexes, IR reachability, LLVM global DCE, in-process object emission, and JIT
startup rather than the compatibility C path.

An early guarded cold `ablac build src/main.ab` through the
LLVM-native compiler completed in 9.53 seconds, including Nix shell entry,
LLVM O2/global DCE, the then-required platform adapter, and LLD. That adapter
is no longer part of the compiler build; the current final compiler contains
no project-C host/platform symbols. Run current measurements independently
with `make benchmark-native`.

The final compiler now executes ORC in-process. A warm guarded
`build/ablac run tests/cases/bootstrap/block.ab` measured 27 ms on the same
machine, including source loading, frontend work, LLVM IR generation, JIT
materialization, and execution. A persistent REPL stress gate compiled,
executed, unloaded, and allocation-reset 128 generations in 1.5 seconds.

Bootstrap compiler executables are built with `BOOTSTRAP_CFLAGS=-O2` by
default; the setting can be overridden on the Make command line for profiling.
This removes an avoidable unoptimized-host penalty but does not replace the
algorithmic work measured by `benchmark-selfhost`.

Every `ablac1` and `ablac2` launch is guarded, including direct use of the
paths under `build/bootstrap` and `make benchmark-selfhost`. The defaults are a
512 MiB address-space ceiling and 600-second wall/CPU limits, with process-group
termination after a short grace period. They can be adjusted explicitly with
`ABLA_MAX_MEMORY_MB`, `ABLA_MAX_SECONDS`, and `ABLA_MAX_CPU_SECONDS`; disabling
the guard is intentionally not a normal Make option. Whole-compiler fixed-point
LLVM emission has a separate, still-bounded 896 MiB default through
`ABLA_SELFHOST_EMIT_MEMORY_MB`; this avoids coupling ordinary compiler limits to
the temporary address-space requirement of emitting the complete compiler
module.

## In-process AOT and indexed-backend result

The final compiler calls LLVM 21 directly for `default<O2>,globaldce` and
object emission. A negative dependency gate places failing `opt` and `llc`
executables first on `PATH`; `ablac build` must still produce a working native
program. The final link remains an external Clang/LLD handoff.

Immutable scalar module values whose initializer is a literal or a proven
constant expression are emitted as internal LLVM constants. Dependencies on
other constant module values are folded recursively. Mutable module `var`s and
effectful or not-yet-proven `val` initializers retain lazy runtime
initialization. This distinction lets
LLVM fold board IDs, pins, register addresses, and other nominal scalar
constants through normal loads while preserving full module-level mutation.
It also removes the export initialization guard when every module value is
provably static; no source annotation is required.

Fixed-width native integer results remain unboxed after an exact-width C ABI
call. The backend sign- or zero-extends them once into Abla's scalar integer
SSA representation, so status checks and control flow do not allocate dynamic
values or call generic equality. Native integer arguments are truncated back
to their declared width only at the foreign-call boundary.

Profiling the full compiler exposed a quadratic backend scan: for every
function, address-taken discovery rescanned every instruction twice. A single
address-taken pass reduced deterministic LLVM emission from 7.369 s to 3.949 s.
Hash indexes for functions, natives, locals, globals, classes, and fields then
reduced it to 1.808 s without changing fixture LLVM output. On the 2026-07-31
reference session:

| Phase | Time |
|---|---:|
| Complete compiler frontend + LLVM text emission | 1.808 s |
| LLVM O2 optimization and object emission | about 5.6 s |
| Native linker handoff (historical measurement included an adapter) | about 0.27 s |
| Full compiler source to executable | **6.861 s** |

This establishes the requested sub-10-second full self-build with margin. The
sub-second target now requires cached module interfaces, persistent typed IR,
incremental code generation, and avoiding whole-program O2 on unchanged code;
it cannot be reached honestly by timing only a cached linker invocation.

On 2026-08-01, after manifest authorization, typed extension generation,
transactional publication, and the libc-free target landed, a watchdog-bounded
fast full compiler rebuilds completed in roughly **15–26 seconds** in the
current instrumented environment, and parent/child full LLVM emissions took
roughly **13–21 seconds** with byte-identical output. A measured emit peaked at
923,216 KiB RSS and a measured fast rebuild at 1,064,604 KiB RSS; both were
hard-capped at **2048 MiB** address space. These newer end-to-end observations
supersede older development timings for capacity planning; profiling must
recover the regression before the sub-second cold target can be claimed.

## Fast development AOT profile

The frontend/backend split was remeasured after the final-native conformance
gate landed. Emitting the full compiler's 8.0 MB textual LLVM module takes
about 0.5 seconds; external measurements of LLVM O2 plus machine-code emission
take about 7.2 seconds. Optimization, not Abla parsing or lowering, is now the
dominant cold-build cost.

`ablac build ... --fast` therefore skips the whole-module optimization pipeline
and selects LLVM's level-zero code generator. With canonical CFG construction,
dominance verification, definite-assignment analysis, and the affine-move
baseline enabled, gated clean pure-Abla compiler self-builds have taken about
**3.1–5.3 seconds**. Recursive structural-affinity analysis initially raised a
clean build to 5.268 seconds. Computing its class/type fixed point once per
compilation and sharing the summary across semantic analysis and all nested
lowerers reduced the same gated build to 4.358 seconds, while every compiler
continued to reproduce byte-identical LLVM IR. The subsequent authoritative
full affinity-only gate measured the cached-affinity compiler at **3.235
seconds**. After conditional direct-resource destruction and compile-time drop
parity landed, the next full byte-identical gate measured **3.371 seconds**.
Recursive structural drop descriptors, projection-remainder cleanup, and
trusted native-wrapper destructors measured **3.453 seconds** in the following
full byte-identical self-build gate. Typed `FnOnce` capture descriptors,
compile-time closure cleanup, and native environment release measured **3.542
seconds** in the next cold authoritative gate. Field-sensitive CFG place
liveness and delayed projection-remainder destruction measured **4.153
seconds** in the subsequent cold gate; this pass deliberately includes the
new place-state verification rather than timing a weakened frontend. Mutable
place reinitialization, all-path restoration, and exact moved-set convergence
measured **3.736 seconds** in the next byte-identical full self-host gate.
Segment-aware nested place aliasing and conservative dynamic-index restoration
then measured **3.702 seconds** with the same full gate. Place-sensitive
borrow/own call exclusion and inferred mode-bearing function values measured
**3.858 seconds** in the next cold byte-identical self-host gate. The following
source-syntax-only `(own: T) -> R` gate reused the exact compiler object and
therefore is not reported as another cold measurement. Call-scoped exclusive
`var` borrowing initially exposed both a precision and a memory regression:
repeated whole-body receiver-effect scans classified native `load()` operations
as writes and peaked near 929 MiB RSS. Replacing them with one fixed-point
mutable-receiver summary restored read/write precision, reduced the same
guarded whole-compiler LLVM emission to about **636 MiB RSS**, and kept the
existing 768 MiB watchdog unchanged. The subsequent full fixed-point gate
measured the cold fast self-build at **3.958 seconds**, including the affine
mutable-borrow checker and mode-bearing callable contracts.
Further work should persist this
summary in typed module interfaces and avoid rebuilding whole-graph semantic
state after an unrelated edit.

Adding the affine `Shared<T>`/`Weak<T>` implementation increased the
self-hosted compiler graph because its LLVM backend now carries the atomic
control-block generator. The guarded core-compiler emission measured about
746 MiB peak RSS and the larger ORC compiler graph about 775 MiB. The old
768 MiB address-space ceiling consequently became too tight and correctly
aborted one fixed-point build instead of allowing an unbounded process. The
self-host emission ceiling is now calibrated to 896 MiB, leaving bounded
headroom while ordinary compiler invocations retain the 512 MiB default.
Shared/weak LLVM support is feature-selected: programs whose typed IR has no
shared/weak operation receive neither `%AblaShared` nor its atomic runtime, so
the new capability does not inflate small ordinary binaries. The completed
byte-identical gate, including stable nullable-flow refinement, measured a
**4.323-second** cold fast self-build and a
**124 ms** exact-source object-cache hit on the same machine.
`serve` uses this profile automatically. Release `build` remains O2, and the
sub-second target still requires persistent module/typed-IR/object caches rather
than weakening what is included in the measurement.

The scoped-region gate adds fixed-point native-call, receiver, and heap-parameter
retention summaries to that same whole graph. Its first cold fast self-build
measured **4.672 seconds**; the subsequent complete green gate reproduced both
compiler fixed points byte-for-byte and measured a **130 ms** exact-source
object-cache hit. The compiler and REPL remained inside their existing bounded
watchdogs, including 128 region-reclaimed ORC generations.

The exhaustive-control-flow gate initially triggered the 1024 MiB final-
compiler watchdog: an unreachable hook recomputed expression types for every
lowered AST node, and the unoptimized fast self-build amplified that work on
the complete ORC graph. Replacing the hook with precomputed `never`-callee
metadata restored both optimized and fast pure-Abla fixed points under the
unchanged limits. After the owned-parameter contract checks landed, the full
green gate measured a **4.751-second** cold fast self-build and a **124 ms**
exact-source cache hit. This is why memory ceilings remain correctness gates,
not optional benchmark settings.

Stored immutable `Shared.get()` views add backward CFG borrow liveness and a
selective pre-evaluation verification pass for borrow-bearing runtime
functions, compile functions, and methods. The first implementation retained
all compile-function validation IR and pushed the LLVM-linked final compiler
past its 1024 MiB address-space watchdog. Per-function checkpoints, syntactic
candidate selection, and reclaiming temporary value-definition/place-state
verification tables reduced the measured final-compiler peak from about
**933 MiB to 902 MiB RSS** while preserving the then-current 1024 MiB final
ceiling. At that gate, the unoptimized fast self-rebuilt executable needed
1032 MiB of address-space headroom solely for its larger code mapping and
remained separately bounded.
The resulting gate measured a **5.049-second** cold fast self-build before
continuing through the pure self-rebuild and conformance suites.

The chained-view rung adds transitive owner provenance for immutable borrow
copies and stored field/index projections. Compacting that provenance to one
table aligned with function locals kept the complete compiler at about
**905 MiB peak RSS**. Its optimized and unoptimized complete-graph executables
now use separately calibrated **1040 MiB** and **1056 MiB** address-space
watchdogs: the additional virtual headroom covers executable mappings, while
ordinary compiler invocations remain at 512 MiB and the core self-host emission
remains at 896 MiB. The complete chained-view gate measured a
**5.093-second** cold fast self-build and a **130 ms** exact-source object-cache
hit.

The following same-owner lifetime-join rung extends stored borrows through
block-valued `if` and exhaustive `when` expressions while rejecting ambiguous
cross-owner joins. It kept the **1040 MiB** optimized and **1056 MiB** fast
self-host watchdogs unchanged, reproduced both pure-Abla compiler fixed points
byte-for-byte, and measured a **5.159-second** cold fast self-build with a
**127 ms** exact-source object-cache hit.

The source-linked borrow-return rung adds `borrow(source) T` contracts for
functions, compile functions, and methods, plus caller-place substitution and
overlapping call-argument checks. Its first normalizer used a seven-byte
`slice()` for every contract-prefix test; arena accumulation raised a guarded
whole-graph run to roughly **956 MiB RSS**. Direct byte tests and shared
declaration lookup reduced the final path to about **910 MiB RSS**, while the
ordinary 512 MiB and core 896 MiB watchdogs remained unchanged. The larger
complete-graph executables now have calibrated **1064 MiB optimized** and
**1072 MiB fast** virtual-address watchdogs. Both pure-Abla fixed points are
byte-identical; the complete green gate measured a **5.379-second** cold fast
self-build and a **134 ms** exact-source object-cache hit.

The callable-family and synchronized-mutation batch adds `FnMut` capture cells,
indexed borrow lifetimes through indirect/global/returned callbacks,
`Borrow<T>`, and `Mutex<T>`. Prefix recognition remains direct byte matching so
these type forms do not allocate short-lived slices across the whole compiler
graph. The source compiler is bounded at **960 MiB**; the LLVM-linked complete
compiler is bounded at **1120 MiB optimized** and **1128 MiB fast**. Under that
ceiling the optimized compiler emitted the complete compiler twice with
byte-identical LLVM IR, and one combined evaluator/LLVM/generated-C smoke gate
covered the batch. These are watchdog ceilings rather than target steady-state
usage; lowering the graph's retained-memory footprint remains active work.

The following hermetic-effects, canonical-module, typed-global, and extension
generation batch remains byte-identical at the self-hosted fixed point. Compact
effect bitsets avoid retaining per-call objects; generated modules are capped
at 64 per staging unit and 64 KiB each. The complete optimized image now has a
calibrated **1152 MiB** emission watchdog (1144 MiB fails cleanly), with
**1160 MiB** reserved for the fast image's mapping margin. Ordinary invocations
remain bounded independently, and every calibration attempt ran through the
same process-tree memory/time watchdog.

The whole-graph object cache now makes an unchanged fast compiler build take
about **0.11–0.14 seconds** (134 ms in the latest full reliability gate), down
from the multi-second cold fast build. That
interval includes exact bundled-source validation, copying the cached object,
and LLD. A permanent gate proves
that the hit does not regenerate LLVM and that changing the source while
reusing the output path selects a different object. This reaches the warm
sub-second milestone for unchanged graphs; edited builds still need
module-granular interfaces and invalidation rather than whole-graph reuse.

The 2026-08-01 warm-path audit found a regression hidden behind that contract:
a bundled-source substring search for `compilerGrant(` matched the compiler's
own cache implementation and semantic checker, conservatively disabling its
cache. Eligibility now inspects already-parsed top-level `#compilerGrant`
actions instead. Ordinary compiler source is cacheable again. Authorized
`filesystem.read` staging is cacheable with a bounded sidecar containing each
observed path, content size, and dual fingerprint; the entry manifest is part
of the cache identity, and a missing, corrupt, or changed input record is a
miss. Parser handlers and finalizers feed the same input identity and invalidate
their persistent staged-frontend snapshot when an observed file changes. Other
ambient effects remain conservatively uncached.
With the corrected eligibility check and an optimized pure-Abla compiler, the
first fast whole-compiler build completed in about **7.4 seconds** in the
observed run. The immediately repeated exact-source build completed in
**0.89 seconds**, including Nix-shell entry, object copy, transactional LLD
relink, and publication, and peaked at **198,408 KiB RSS** under a 960 MiB
address-space watchdog. Cold results still vary with host load; the cache gate
asserts behavior rather than a fragile timing threshold.

Self-build recipes no longer use a blanket 2048 MiB limit. Canonical full-graph
self-rebuilds use the production release-O2 compiler under a **1536 MiB**
address-space ceiling; that path was observed at 1,278,560 KiB peak RSS.
Complete unoptimized compiler images are intentionally not the fixed-point
gate: their much larger code mapping crossed the watchdog as the compiler grew,
without adding a stronger correctness property. Fast AOT remains gated on
ordinary programs. Whole-IR emission retains its smaller separately calibrated
limit.

The explicit collector is now selected from entry-point reachability. A
work-list walk follows direct calls and conservatively expands indirect calls
to address-taken functions. Programs which cannot reach `memoryCollect()` no
longer carry the pure mark/sweep implementation; collector users retain the
zero-initialized allocation contract and complete shadow-root path. The
optimized compiler remained byte-identical at its next fixed point and emitted
its complete 19.4 MiB LLVM module in **8.855 seconds** in the observed cold run,
under the unchanged **1152 MiB** emission watchdog. This pass is primarily a
program-size and optional-runtime win; it does not yet claim a frontend speed
improvement.

The following allocation pass split tracked allocation into initialized and
fully-written paths. Collector-capable and host-backed programs retain zeroed
storage, because conservative tracing must never inspect indeterminate words.
Pure programs with no reachable collector skip clearing; generated arrays,
objects, closures, and strings initialize every word they expose before use,
which is enforced by the existing definite-assignment and runtime conformance
gates. The complete optimized compiler then emitted the same fixed-point module
in an observed **8.656 seconds** (about 2.2% below the immediately preceding
8.855-second run), still under 1152 MiB. This is deliberately recorded as a
small allocation win, not the sub-second result; typed incremental IR/object
reuse remains the path to the larger cold-build reduction.

The next collector passes added independently checked scan prefixes, precise
layout maps for values, fields, arrays, objects, ropes, strings, cells, and
shared storage, plus a pinned-raw class for deterministically dropped native
resources. Selecting a managed-memory limit enables compiler-published
function-entry pressure safe points; programs with no reachable managed-memory
API still strip the collector. The production graph remains Abla plus LLVM and
does not import the compatibility C backend or project runtime.

The promoted compiler's fixed module is **19,339,832 bytes**, with SHA-256
`eaa7294fe1af763a1858d8eb3679063795d61b780e9b3f262af45e8a42f405c8`.
It rebuilt the complete compiler directly through public `ablac build` in an
observed **25.9 seconds** under the four-GiB watchdog, and its child emitted
byte-identical IR. This safety-first ownership migration is above the cold
sub-10-second target again; incremental typed reuse and retained-summary work
remain the next performance phase. The phase-separated release helper remains
the lower-peak fallback; both paths publish output transactionally.

The first persistent module-state rung is now active in `serve`. Source,
content fingerprints, and scanned import edges are cached per path; a
same-length leaf edit refreshes exactly that leaf, while unchanged parents and
siblings are reused, and an import-edge edit replaces the active dependency
set. Dependency-fingerprinted staged ASTs are cached as well, including the
visible imported subparser-provider environment; only the current AST for a
path is retained. Native regression gates cover reuse, leaf/import-edge
invalidation, nested imported subparsers, and no-project-C linking. This is not
yet typed-IR incremental compilation: semantic analysis, LLVM emission, and
object generation remain whole-graph after an edit.

## Programmable-build foundation profile

On 2026-08-02, after recursive build graphs, foreign ABI manifests, Android and
WASM extension proofs, checked exports, and graph rollback landed, an uncached
fast self-build completed in **27.162 seconds**. A separate full LLVM-emission
run completed in **21.220 seconds**. Instrumentation of that emission attributed
approximately 0.651 seconds to parsing, 10.602 seconds to semantic analysis,
8.204 seconds to lowering, and 0.935 seconds to LLVM text emission. The small
remainder is phase-boundary overhead.

This build remains below the requested 30-second ceiling, but no longer has the
margin of earlier, smaller compiler graphs. The next cold-build work belongs in
semantic-summary reuse and lowering, not output-string micro-optimization. The
existing exact-source cache remains the warm path; these figures deliberately
measure an uncached complete compiler and do not use a cache hit to hide the
regression.

The 6.861 s measurement includes the LLVM-emitted scalar, closure, collection,
object, formatting, equality, and iterative rope runtime. The resulting
`src/main.ab` compiler was 1,608,216 bytes and reproduced the
reference LLVM IR byte-for-byte. Large generated runtime strings also exercise
the new seed-C constant chunking path rather than relying on non-portable C
translation limits.

## Managed HTTP service result

On 2026-08-11, the single-CPU `abla-compare` HTTP/1.1 keep-alive benchmark
improved from **4.7 requests/second** with 12.9-second median latency to a
three-run median of **86,786 requests/second**, **0.484 ms p50**, and **0.971 ms
p99** at 64 concurrent connections. This is 2.09 times the previous managed
baseline of 41,511 requests/second. The response and status are validated
before every run; Go and Rust use the same endpoint, connection count, CPU
isolation, warm-up, and measurement intervals.

The principal memory bug was an ownership transition, not inherent collector
cost. Native socket buffers begin pinned because an integer address is invisible
to tracing, but adopting one as a managed string failed to change its scan
layout. Every read therefore retained the old 65,537-byte buffer forever. The
fix makes adopted storage collectible and covers that transfer with a direct
collection regression. The final two-minute load completed 11,148,227
successful requests at 92,900 requests/second, remained alive with 100% success,
and peaked at 135,080 KiB RSS.

The throughput work also replaces byte-at-a-time Abla HTTP scans with bounded
text intrinsics, retains slices as collector-safe views, parses each framed
request once, maps descriptors directly to connection slots, reads exact-size
4 KiB chunks, consumes packed poll events without a temporary object graph,
and attempts small writes before requesting another poll wake-up. Partial
writes retain the existing offset and backpressure behavior. The full
73-fixture conformance suite, byte-identical self-rebuild, hosted HTTP tests,
and static raw-target server all pass with these paths enabled.

The second optimization pass kept those semantics and changed general compiler
and managed-runtime machinery. Hosted O2 executables now receive whole-program
LTO across generated LLVM and the Abla runtime. Their
ordinary combined relocatable `.o` remains separately compiled for Icy and
cross-libc packaging. The native cache stores the generated LLVM module as well
as the ordinary object, so cache-hit release builds retain LTO; the measured
cached executable was byte-identical to the uncached one.

Managed arrays and compiler-known class fields now use one allocation for their
header and initial storage. Constructors initialize their already-sized field
slots directly, while later reflective or dynamic mutation retains the existing
symbol-based path. The collector uses an exact-pointer hash index instead of
sorting every live allocation, and managed string views retain the allocation
that actually owns their bytes. These changes preserve the boxed value ABI,
reflection, mutation, foreign ABI, and managed lifetime rules.

Hardware counters explain why Rust remains faster. In a pinned ten-second run,
Abla retired approximately **84,115 instructions** and **43,425 cycles** per
request at **1.94 IPC**. Rust retired **14,017 instructions** and **5,427
cycles** per request at **2.58 IPC**. Abla therefore executes about six times
as many instructions and eight times as many cycles per response. Its hottest
sample was managed memory pressure (24.4%), followed by allocator consolidation
and allocation; Rust's hottest named samples were HTTP parsing and writing.
Later passes below implement checked region placement for non-escaping request
graphs and conservative scalar unboxing. Remaining parity work includes broader
typed aggregate specialization, lower-cost collection checks, and collector
improvements. Disabling collection or weakening the language model would hide
rather than solve the measured gap.

### Direct calls and lexical response regions (2026-08-11)

The next measured pass gives compiler-generated direct calls a typed pointer
ABI while retaining the generic `(output, arguments, count)` wrappers required
by closures, exports, reflection, and indirect dispatch. It also limits
function-entry memory-pressure checks to functions that can both reach the
collector and allocate directly. The comparison server contains 433 static
pressure calls after this change, down from 544, without weakening collection
at an allocation boundary.

Abla lexical `region` scopes now use nested, page-backed bump allocation in the
host runtime. Region exit reclaims its pages in bulk and a bounded thread-local
page cache reuses them; manually freed region objects are unlinked safely and
the tracing collector continues to understand live region allocations. A
separate `memoryPromoteString` operation copies a region-owned string into its
parent allocation domain when it must escape. Raw targets retain their previous
no-op region reclamation semantics.

The event HTTP server applies the region only to response construction, after
the user handler has returned, and promotes the completed wire response before
storing it in the connection slot. This deliberately leaves request parsing and
the arbitrary handler outside the region because a handler may retain request
data. In an isolated A/B run at 64 connections, this safe boundary improved the
three-run median from **92,273 to 103,428 requests/second** (**12.1%**), p50 from
0.490 to 0.469 ms, and p99 from 0.969 to 0.932 ms. Retired work fell from about
83,922 to **75,940 instructions/request**, and from 43,214 to **37,851
cycles/request**. Allocator-related samples fell from roughly 19% to 13% of the
profile. The full 73-fixture suite and byte-identical self-rebuild pass with the
optimization enabled.

### Demand-driven writable interest (2026-08-11)

The event HTTP loop previously issued `epoll_ctl(MOD)` after every completed
response even though readable interest had never been disabled. It also did
not enable `EPOLLOUT` when an immediate nonblocking write stopped at kernel
backpressure. Per-connection writable-interest state now changes the poller
only on the transition into or out of a real pending-write state.

On the same pinned single-worker comparison, three ten-second samples improved
from a **103,875 requests/second** median to **107,365 requests/second**
(**3.36%**). Median p50 fell from 0.469 to 0.444 ms and p99 from 0.931 to
0.875 ms. A five-second syscall audit with 64 persistent connections observed
only 132 `epoll_ctl` calls, so poller updates now scale with connection
lifecycle rather than request count. A forced 256 KiB response with a 4 KiB
server send buffer verifies that the partial-write path registers writable
interest and drains the complete response before closing.

### Checked request regions and lazy scalar SSA (2026-08-11)

The checked `FnNoEscape(A) -> R` callable contract lets the event HTTP server
place parsing, static routing, handler execution, and response framing inside
one request region. Only the completed wire response and unread connection tail
are promoted. This moved the canonical single-worker result from 111,030 to
144,573 requests/second without changing the general escaping handler API.

The following compiler pass infers only proven `i64` and `bool` IR values and
locals. Arithmetic, comparisons, bit operations, bounded shifts, branches,
direct scalar calls, and compatible native calls consume LLVM scalar values
directly. Declared local types survive lowering, so a scalar stays native even
when its first assignment is control-flow dependent. A value receives boxed
storage only when a use crosses a dynamic or otherwise unsupported boundary;
locals are eligible only when every assignment proves the same scalar type.
Division, heterogeneous equality, aggregate access, and unproven locals remain
on their established boxed runtime paths.

Against the checked-region binary, a five-sample isolated A/B improved the
median from 143,955 to 152,141 requests/second. A separate counter run reduced
retired instructions from about 49,678 to 46,376 per request and cycles from
23,114 to 20,597. The optimized HTTP executable shrank from 540 KiB to 471 KiB.
The canonical cross-language rerun reached 152,868 requests/second, 95.5% of Go
and 55.2% of Rust on the same pinned setup. All 75 tests and the byte-identical
self-rebuild pass. Native parameter storage was also tested, but its additional
missing/default control flow reduced throughput by 0.73%, so that experiment
was removed.

## Reachability and size result

The LLVM size path marks Abla implementation functions internal, limits
the indirect dispatcher to address-taken functions, runs LLVM O2/global DCE,
and links function-sectioned runtime shims with LLD garbage collection. On the
same 2026-07-31 development session:

| Native program | Before | After | Reduction |
|---|---:|---:|---:|
| identifier-shadowing scalar fixture | 37 KiB | 7.5 KiB | 80% |
| lambda-capture fixture | 47 KiB | 22 KiB | 53% |
| version-aware HTTP server | 126 KiB | 97 KiB | 23% |

The HTTP result intentionally includes the tagged-value runtime and live TCP
transport. Further reductions come from IR-level reachability before textual
emission, a raw-kernel platform profile, specialized/unboxed values, and
splitting optional HTTP features such as server transport from router-only use.

Generated direct scalar implementations use internal linkage. Size-oriented
MCU builds also make their universal-value wrappers internal immediately.
Hosted release LTO preserves the wrappers as hidden during its early O1
specialization, then internalizes them before O2/LTO dead-code elimination.
This ordering retains profitable scalarization across hot indirect ABI calls
while still removing unreachable imported implementations before machine-code
emission; explicit export thunks remain the only public object boundary.

## Compact 24-byte dynamic values (2026-08-12)

The portable dynamic value ABI now uses an explicit 32-bit tag, a 32-bit
auxiliary word, and a 16-byte payload. Function identifiers use the auxiliary
word; a closure keeps its capture count and capture pointer inline. Flat
strings retain their pointer and full `size_t` length without boxing. Rope
length moves into the rope allocation, and slices are allocation-interior
views understood by the tracing collector. This reduces `AblaValue` from 32
to 24 bytes on native and Wasm targets without narrowing string lengths or
adding per-string or per-closure allocations.

In the same one-million-element dynamic-array workload, tracked storage fell
from 33,554,456 to 25,165,848 bytes, exactly 25%. Median process RSS fell from
about 51 MiB to 38 MiB. The isolated five-sample HTTP comparison reached a
235,674 requests/second median, up 6.8% from the prior 220,714 baseline; the
same run measured Go at 164,657 and Rust at 282,480 requests/second.

A 16-byte form was evaluated but not adopted. It cannot retain a pointer plus
full-width length for strings or a capture count plus pointer for closures,
so it requires additional boxed descriptors or packed-length fallbacks.
Sixteen bytes also crosses the x86-64 and AArch64 aggregate return threshold,
requiring a coordinated direct-return rewrite of every runtime, foreign, Wasm,
Android, and bootstrap boundary. Keeping 24 bytes is therefore the smallest
validated portable representation in this pass, not a claim that a separately
benchmarked 16-byte direct-return ABI can never win.

## Segmented large HTTP bodies (2026-08-12)

The 16 KiB echo workload transfers at least 32 KiB per request: one 16 KiB
request body enters the process and the same payload leaves in the response.
Its CPU profile was consequently dominated by byte movement rather than the
dynamic value ABI: `memmove` and `memset` accounted for about 39% of sampled
cycles before this pass.

The hosted readiness-loop reader now receives directly into an uninitialized
managed byte allocation and publishes only the bytes actually returned by the
kernel. Large segmented responses use a bounded 64-entry `sendmsg` scatter
write, preserving `MSG_NOSIGNAL`; the libc-free runtime provides the equivalent
raw syscall. Small responses retain the contiguous writer because its lower
setup cost is faster below 4 KiB. Deep ropes fall back to the established
flattened writer, and partial writes still promote the response before its
request region is reset.

In an adjacent five-sample comparison at 64 connections, the body median rose
from **120,508 to 126,240 requests/second** (**4.76%**). The candidate samples
were tightly grouped from 125,864 to 127,049 requests/second. The final holistic
run measured Abla at 124,580, Go at 102,936, and Rust at 155,144 requests/second;
Abla remained faster than Go in all four workloads. Regression coverage checks
a nonzero write offset, more than 64 rope leaves, the flattening fallback, and
the raw libc-free syscall path. All 75 compiler/runtime fixtures and the
byte-identical self-rebuild pass.
