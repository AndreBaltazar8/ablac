# Reliability, memory safety, and complete self-hosting roadmap

Abla's defining feature is one coherent language model across ordinary code,
compile-time execution, embedded subparsers, AOT, JIT, REPL, and hot reload.
The implementation must now make that coherence trustworthy. New syntax is
secondary to proving that safe programs cannot trigger undefined behavior,
that builds are reproducible, and that the Abla compiler can maintain itself.

"Reliable" is not an absolute claim. In this project it means that each
release tier below has executable gates, documented limits, and no known way
to bypass its safety contract from safe Abla code.

## Current proven baseline

- The complete Abla compiler graph lowers directly to LLVM.
- A native Abla compiler recompiles itself and emits byte-identical LLVM.
- `make self-rebuild` performs an uncached rebuild using only the Abla compiler
  implementation and uses the result to build a child program.
- The final compiler contains no project-C host/platform bridge symbols.
- A clean build starts from the checksum-pinned Abla release binary. LLVM and
  Clang/LLD remain external toolchain dependencies.
- AOT, persistent ORC `run`, transactional REPL generations, watched `serve`,
  graceful HTTP reload, raw Linux facilities, watchdog limits, and stackable
  compile-time subparsers have bounded regression gates.
- Runtime allocation is tracked, but safe user-visible ownership, borrowing,
  destruction, cycle handling, and concurrency rules are not complete.

This is a functional self-hosting fixed point, not yet a complete bootstrap
trust story or a production memory-safety guarantee.

## Non-negotiable invariants

1. Safe Abla has no use-after-free, double free, invalid aliasing mutation,
   uninitialized read, data race, unchecked bounds access, or null dereference.
2. Unverifiable native operations are confined to function-level `trusted`
   implementations, recorded in module interfaces, and authorized by the
   package manifest; ordinary Abla has no general unsafe-block mode.
3. Compile-time code follows the same type, ownership, and drop rules as
   runtime code.
4. Hermetic compilation is the default. Every external compile-time effect is
   either denied or granted, recorded, and included in invalidation.
5. A subparser cannot forge an unhygienic identifier, escape its cursor,
   retain compiler internals, or consume unbounded resources silently.
6. The VM/evaluator, LLVM AOT, ORC, and generated-C compatibility backend agree
   on observable language behavior.
7. Invalid input produces a bounded diagnostic, never a compiler crash, hang,
   runaway allocation, partial output, or corrupted cache entry.
8. The compiler can rebuild the exact revision that produced it, and bootstrap
   stages are independently reproducible and auditable.

## 1. Reliability floor

Before expanding the type system, make failures measurable and reproducible.

- Assign stable diagnostic codes and precise primary/secondary source spans.
- Add coverage-guided fuzz targets for UTF-8 lexing, parsing, module graphs,
  staged subparsers, semantic analysis, cache decoding, and LLVM emission.
- Differentially execute generated programs in compile-time evaluation, ORC,
  O2 AOT, and fast AOT. Minimize and retain every mismatch.
- Add malformed-module, allocation-failure, interrupted-syscall, short-I/O,
  child-process, cache-corruption, and hot-reload fault injection.
- Run seed code under ASan/UBSan and native Abla gates under LLVM sanitizers
  where the selected runtime profile supports them.
- Make every compiler operation transactional: temporary output, verify,
  atomic publish; cache records need version, target, checksum, and length.
- Keep wall-time, CPU, memory, parser-depth, staged-round, recursion, generated
  code, and diagnostic-count budgets enabled in CI.

Current progress: LLVM source, generated objects/cache sidecars, and final
hosted/raw executables use temporary siblings plus atomic publication. A
failed rebuild is gated to leave the previous executable byte-identical and
remove its abandoned publish temporary.

Exit gate: a fixed fuzz campaign and the complete fault matrix produce no
crash, hang, unbounded growth, stale executable, or VM/backend disagreement.

## 2. Flow-sensitive typed IR

Memory checking needs a control-flow representation with explicit lifetime
events. Complete this before implementing ownership as parser-local rules.

- Finish `break`, `continue`, `for`, and ranges with compile/runtime parity.
- Build explicit basic blocks, predecessors, terminators, phi/block arguments,
  reachability, and a verifier that rejects use-before-definition.
- Retain the implemented definite-assignment, exhaustive-`when`, and
  diverging-`never` gates while adding general unreachable-code diagnostics.
- Separate typed high-level IR from target layout and LLVM emission.
- Preserve stable source provenance on every instruction and synthesized drop.

Exit gate: malformed IR cannot reach a backend, every control-flow construct
has positive/negative/evaluator/AOT/JIT tests, and the compiler builds itself
through the new verified IR.

Current progress: explicit reachable blocks, mandatory terminators, SSA
definition dominance, immediate dominators, local declaration lifetimes, and
all-path definite assignment for typed deferred `var` are implemented and
bounded. `when` now requires a final `else` or complete Boolean coverage,
rejects duplicate/invalid `else` arms, evaluates in the compile-time VM, and
lowers impossible paths to verified unreachable terminators in LLVM and C.
The uninhabited `never` type participates in branch joins, and proven
non-breaking literal-true loops produce `never`. Phi/block arguments,
source-provenance diagnostics, general unreachable-code diagnostics, and
synthesized lifetime-end/drop events remain.

## 3. Safe memory model

Use an ownership model, but design it for Abla instead of copying Rust syntax.

### Core rules

- `resource class` values have one owning binding. Local-to-local ownership
  transfer uses `move(local)`; returning a local transfers implicitly at the
  end of its lifetime. Ordinary parameters borrow by default; `own` parameters
  transfer into a callee and require `move` for an existing affine binding.
- Immutable borrows permit multiple readers; a mutable borrow is exclusive.
  Borrows cannot outlive their owner or cross an invalidating mutation.
- Flow-sensitive non-lexical lifetimes operate on typed CFG liveness, not
  source-block approximations.
- `val` controls binding reassignment; ownership and interior mutability remain
  separate concepts.
- Destruction is deterministic. Typed IR inserts drops on normal exits, early
  returns, loop exits, and partially initialized failure paths.
- `Shared<T>` provides atomic or profile-selected shared ownership;
  `Weak<T>` breaks cycles. Shared mutation requires a checked synchronization
  or interior-mutability abstraction.
- `Region<T>`/arena allocation remains first-class for compiler ASTs and
  request-scoped workloads, but references cannot escape a closed region.
- Arrays, strings, closures, objects, and subparser-produced values receive
  precise ownership/layout descriptors rather than relying on an untyped box.

Freely aliased ordinary classes and primitive arrays now have the first
cycle-safe tracing-heap rung, not implicit reference counting and not a general
`unsafe` mode. The compiler computes a transitive collection effect, emits
liveness-compressed root frames only for functions that can reach a safe point,
and propagates it through address-taken/indirect calls. A separate entry-point
reachability walk omits the mark/sweep implementation entirely when no live
path can invoke collection. Globals and indirect dispatcher buffers are roots
too. Every allocation records a bounded initialized prefix and a precise layout
identifier. Arrays and objects publish entries only after complete writes;
values, fields, closures, ropes, strings, cells, and shared storage trace only
their pointer-bearing slots. Native resource buffers are pinned raw until
deterministic drop or region reset. Selecting a managed-memory limit enables
compiler-published function-entry pressure safe points; collector-free programs
strip the tracer. `resource class`,
`Shared`/`Weak`, and lexical regions keep their deterministic contracts outside
the collector. Every emitted runtime also enforces an
overflow-safe cumulative tracked-heap budget (one GiB by default). The portable
memory API can inspect or explicitly raise/lower the budget, but cannot lower
it below current live usage. This converts runaway allocation into a bounded
Abla panic in hosted and libc-free executables. `memoryCollect()` is the first
explicit safe point and returns the number of bytes reclaimed; it collects
cycles in pure, hosted, and libc-free runtimes and is a staging no-op because
the tree evaluator owns a separate host-managed value graph.

Tracked allocation is collector-conditioned: collector-capable pure programs
and hosted platform adapters return zeroed storage, while pure programs proven
unable to collect may use uninitialized storage internally. This is not exposed
as source-level unsafe memory. Generated container/string/object operations must
initialize their visible layouts before reads, and the compiler's definite-
assignment checks plus bounded native conformance enforce that contract.

Current progress: resource classes, recursive affine arrays, explicit local
moves, implicit return moves, borrowed and owned parameters, borrow-escape
rejection, type-directed consuming calls, and CFG-sensitive use-after-move
checking are implemented across compile-time, LLVM, and C paths. `move { ... }`
closures transfer affine captures, are inferred as affine `FnOnce` values, and
are consumed on invocation; ordinary resource capture, borrow capture, closure
copy, and repeated calls are rejected. Affinity propagates structurally through
stored fields, arrays, and nullable values. `move(owner.field)` and
`move(owner[index])` are consuming projections that invalidate the selected
place across the CFG while preserving proven-disjoint siblings; implicit or
borrowed extraction is rejected in compile-time, LLVM, and C paths. Direct
resource bindings may define a reserved
`drop(): void`; verified IR now inserts conditional, reverse-order drops for
normal scope exit, reassignment, early return, `break`, `continue`, and owned
parameter exit, with runtime storage clearing preventing double drops in LLVM
and native LLVM, and matching compile-time evaluator cleanup. Deterministic
per-type IR helpers now recurse through structural fields, arrays, and nullable
values; affine field/index replacement drops the old value, and consuming
projections clear the extracted slot while field-sensitive CFG facts preserve
unmoved siblings and distinct constant indexes. Whole-owner or moved-place use
is rejected, and the live remainder is destroyed only at owner lifetime end.
Compatible field/index assignment kills the corresponding move fact, with
forward union dataflow requiring restoration on every incoming CFG path before
whole-owner use. Nested place segments distinguish fields and constant indexes;
a dynamic index aliases every index only at its segment, preserves unrelated
fields, and cannot claim restoration through another computed index. The
call checker rejects an owned argument that overlaps another affine borrow or
the method receiver while permitting structurally disjoint argument places.
Inferred function values retain owned parameter modes, and indirect calls apply
the same transfer and overlap rules as direct calls. Source annotations use
`(own: T) -> R`; borrowed and owned callable modes are type-distinct. The first
`own` parameters are restricted to affine callable inputs, and bare `own`
primary-constructor parameters are rejected because only `val`/`var` declare
stored properties. Branch-sensitive implicit returns transfer exactly one
owned input and deterministically drop the unselected inputs. Exclusive call-
scoped mutable views now cover affine owners, ordinary managed classes/
interfaces, and arrays. `var value: T` requires an addressable place or a result
proven fresh through a constructor-returning factory. Ordinary managed
parameters are read-only; overlapping mutable/owned/managed arguments and
receivers are rejected while disjoint projections remain legal. Receiver-type-
specific summaries infer transitive mutation through fields. Inferred and
explicit `(var: T) -> R` callables preserve the mode for indirect calls.
Defaults, foreign declarations, scalar `var` types, and arbitrary returned
references are rejected. Direct immutable aliases of arrays and classes with
mutable fields now retain exact source-place provenance. CFG last-use analysis
rejects overlapping mutation, mutable aliases, mutation through the alias,
storage, capture, and escape while preserving disjoint sibling mutation and
post-last-use mutation at runtime and compile time. Transitive `val`-contained
mutable payloads and non-fresh returned/stored references remain before the
default sharing model is complete. The
first `Shared<T>`/`Weak<T>` rung is now implemented for affine payloads across
compile-time evaluation and LLVM. Both handle kinds are affine,
so reference-count increments require an explicit `clone()`. `Shared.get()`
produces a compiler-only non-escaping borrow. A direct `get()` from a stable
local/parameter-rooted place may initialize an inferred `val` borrow local.
Backward typed-CFG liveness permits owner invalidation after the view's actual
last use, handles conditional uses, and uses segment-aware place overlap so
disjoint fields remain available. It rejects an overlapping move, assignment,
mutable call, or mutating receiver while a later use is reachable.
Borrow-bearing runtime functions, compile functions, and methods are
pre-verified through side-effect-suppressed IR before any global `#` expression
can invoke them. Immutable borrow copies and stored field/index projections
retain the original owner-place provenance, may outlive intermediate views, and
participate independently in the same last-use analysis. `if` and exhaustive
`when` joins retain a borrow only when every value branch proves the same
original owner place; joins of different owner roots remain rejected. Borrow
returns now require `borrow(source) T`, where every return is proven to derive
from one ordinary parameter or `this`; direct calls substitute the exact caller
place, including at compile time, and overlapping `own`/`var` call arguments
are rejected. Function types retain the relation as zero-based
`borrow(index) T`, including local/global aliases, higher-order parameters, and
returned callback values. `Borrow<T>` explicitly annotates immutable view
parameters and locals without manufacturing provenance. Consumed, mutable,
defaulted, cross-owner, and extern sources remain unavailable. Borrow locals cannot be mutable,
captured, returned without a source contract, stored into longer-lived aggregates, reshared, consumed,
mutably borrowed, or used to mutate the payload; heap projections preserve the
borrow taint.
`downgrade()` and atomic `upgrade()` use an implicit weak-count invariant: the
last strong release extracts and destroys the payload once, and the control
block survives until the final explicit weak release. Structural wrappers and
arrays recursively drop strong and weak handles. `Mutex<T>` provides the first
synchronized shared-mutation rung for affine payloads: explicit clones share
one atomic lock/control block, and `with` grants one non-escaping call-scoped
`var` payload view to a named callback. Freely aliased class and primitive-array
payloads remain rejected until immutable/reference semantics can make their
sharing contract sound; general mutable-place refinement is a later rung. Stable nullable locals
and parameters now refine on proven `== null`/`!= null` branch polarity,
including negation and logically guaranteed short-circuit paths, across the
semantic analyzer, typed IR, compile-time evaluator, and LLVM.
The refinement cannot escape its branch and is not granted to mutable locals
or receiver fields. The
trusted native memory wrappers use idempotent inherent destructors, so explicit
`close()` and automatic cleanup compose without double-freeing. Lexical
`region { ... }` now replaces raw checkpoint use in ordinary code. Its
fixed-point effect analysis rejects escaping results/stores, retaining foreign
calls, and direct or transitive mutation of outer receivers/heap parameters;
affine values are destroyed before reset. Moving lambdas now carry verified
companion drop functions;
uninvoked, replaced, nested, and container-held `FnOnce` environments destroy
their remaining captures and release storage, while invocation consumes the
captures and releases storage after the body. Explicit `Fn`, `FnMut`, and
`FnOnce` types are implemented; lambdas that mutate captures infer `FnMut` and
share capture cells across staged and native execution. General mutable
reference types, lifetime-polymorphic/cross-owner joins, and mutable borrows
that outlive one call remain.

### Trusted native boundary

- Raw pointers, direct syscalls, unchecked indexing, layout casts, and foreign
  calls are available only inside manifest-authorized `trusted`
  implementations. Checked wrappers expose safe ownership and error contracts.
- FFI signatures describe ownership (`borrowed`, `owned`, `out`, `nullable`),
  mutability, lifetime relation, calling convention, and error representation.
- Safe wrappers validate kernel negative-error returns and native result
  ownership before values enter safe Abla.
- The runtime allocator is replaceable per binary profile. Pure Linux programs
  may use raw syscalls; portable profiles may use a platform allocator without
  changing language semantics.

Exit gate: compile-fail suites cover moves/borrows/escapes/drops, runtime drop
traces cover every control-flow edge, Miri-like IR interpretation detects
invalid accesses during tests, and safe stress programs pass ASan/TSan with no
leaks other than explicitly process-lifetime allocations.

## 4. Compile-time effects and subparser safety

Do not equate "same language" with "all effects are always allowed."

- Every function has an inferred internal effect set and an explicit stable
  public effect contract: pure, allocation, filesystem read/write, environment,
  clock/random, process, network, compiler reflection, and trusted native.
- Normal compilation grants deterministic pure/allocation effects only.
- Granted file reads record canonical path plus content identity; environment,
  process, network, clock, and randomness make a step non-cacheable unless a
  provider supplies a deterministic declared input.
- A build manifest and lockfile define capabilities. Diagnostics show the full
  call chain that requested a denied effect.
- `run` and `serve` use the same evaluator/runtime but a different explicit
  capability profile. An HTTP server is therefore possible in an interactive
  compile session without silently making ordinary builds non-hermetic.
- Subparsers are pure by default, transactional, budgeted, and return typed
  `Syntax<T>` handles. Scope marks provide hygiene; deliberate capture requires
  an explicit API. Nested cursors form a checked stack and cannot be retained.

Current progress: compact fixed-point effect inference classifies allocation,
compiler reflection, filesystem read/write, environment, process I/O, network,
clock, randomness, and trusted native reachability. Staged ambient effects are
denied by default; `#compilerGrant` is explicit in source and must intersect
the entry package's `abla.toml` authorization. The self-hosted filesystem-read
and named-environment providers are gated by the complete grant mask and
journal bounded provider identities plus content fingerprints for cache
validation. The entry manifest participates in the cache identity; corrupt or
changed records miss safely. Granted clock, randomness, and bounded process
execution providers bypass the object cache by construction. Other ambient
effects remain unavailable until their provider contract is implemented.
Subparser/finalizer journals are merged into the lowered artifact and
revalidated before persistent staged-frontend reuse. Their complete ambient
permission mask is intersected before parser evaluation, closing the
pre-semantic effect window.
Subparsers expose immutable syntax structure/spans and selected-call metadata,
can record deferred requests, and can run Abla finalizers that publish bounded
compiler-owned AST modules. The complete candidate is validated
transactionally. Generated declaration references carry compiler-only hygiene
marks; denied effects reconstruct a bounded staged call chain without retaining
call-edge objects. Complete overload-resolution node maps, inserted conversion
details, generic substitutions, and parser-transaction journal canonicalization
remain.

Exit gate: repeating a hermetic build gives byte-identical interfaces, objects,
and executable; changing one declared input invalidates exactly its consumers;
undeclared I/O and hygiene escapes fail with stable diagnostics.

## 5. Type-system completion

- Nominal interfaces/traits with coherent implementation selection.
- Checked generics, constraints, variance rules, and deterministic
  monomorphization/shared-code policy.
- Exhaustive algebraic data types and pattern matching.
- Full nullability flow refinement without sentinel representations.
- Send/share constraints and structured concurrency only after the ownership
  model is proven single-threaded.
- Reflection exposes immutable typed metadata and transactional syntax/IR
  construction; it never exposes live compiler objects or backend pointers.

Exit gate: separate compilation can type-check consumers from serialized
interfaces alone, coherence/exhaustiveness negative suites pass, and generic
ABI hashes are stable across self-rebuilds.

## 6. Incremental native compiler and performance

- Serialize versioned typed module interfaces containing exports, effects,
  ownership contracts, generic bodies needed by consumers, subparser ABI, and
  dependency fingerprints.
- Cache typed IR and emit one independent object per reachable module or codegen
  unit. Relink only changed units and units whose public interface changed.
- Separate runtime features into link-selected fragments; do IR-level
  reachability before generating LLVM text.
- Extend the implemented conservative `i64`/`bool` SSA unboxing and checked
  request-region placement to aggregate layouts, deeper escape analysis, drop
  elimination, specialization, and optional ThinLTO for release builds.
- Keep fast builds semantically identical to release builds; optimization level
  must never alter compile-time behavior.

Exit gate: an implementation-only one-module edit rebuilds the compiler in
under one second on the reference machine; a cold fast self-build stays under
ten seconds; release and fast compilers emit byte-identical self-source LLVM
before target optimization.

## 7. Complete self-hosting and bootstrap trust

Use explicit terms rather than one overloaded "self-hosted" claim.

1. **Source self-hosted**: compiler frontend/backend/tool driver are Abla.
   This is already true for the final compiler.
2. **Fixed-point self-hosted**: compiler A builds compiler B, which reproduces
   the same canonical compiler representation. This is already gated.
3. **Post-seed independent**: an existing native Abla compiler rebuilds without
   compiling project C/C++. This is already gated by `make self-rebuild`.
4. **Clean-bootstrap reproducible**: an empty machine starts from a reviewed,
   pinned seed artifact or independently implemented minimal seed, builds every
   stage, and two independent paths converge on the same canonical result.
   This remains open.
5. **Target-independent self-maintaining**: the Abla compiler and standard
   library can add a backend/platform by implementing documented Abla-facing
   target interfaces without another compiler implementation.

To close tiers 4 and 5:

- Freeze and document a small canonical bootstrap language/IR plus artifact
  format; keep it much smaller than the production compiler.
- Publish hashes, source revision, LLVM version, target triple, build manifest,
  and reproducibility instructions for seed artifacts.
- Maintain two bootstrap routes: current audited seed and a minimal independent
  interpreter/compiler. Require canonical IR equality before trusting output.
- Make the standard library, module resolver, cache, linker plan, diagnostics,
  and target descriptions Abla modules. External LLVM/LLD are ordinary pinned
  system dependencies, not hidden implementation state.
- Add at least one non-Linux target before calling platform abstraction stable.

Exit gate: two clean bootstrap routes on fresh builders produce the same
canonical compiler IR and equivalent binaries; the resulting compiler passes
the full suite and can compile the next source revision without seed changes.

## 8. Production usability

- Build signed publisher identities, a content-addressed registry, and
  semantic-version policy above the implemented immutable Git provider locks,
  offline/vendor mode, and root-owned capability declarations.
- Derive formatter, documentation, symbol index, and LSP data from the compiler
  parser/type APIs so tooling cannot drift from the language.
- Establish stable/preview/nightly language editions and deprecation policy.
- Test Linux first, then macOS/Windows and another architecture; publish a
  target support matrix rather than implying universal support.
- Provide release crash telemetry only as explicit opt-in and always retain a
  local minimized reproduction path.

## Implementation order

The critical dependency chain is:

```text
reliability floor
  -> verified flow-sensitive IR
  -> ownership + deterministic drops
  -> effect/capability checking
  -> typed module interfaces
  -> incremental objects
  -> clean-bootstrap convergence
  -> concurrency and ecosystem stabilization
```

Subparsers, HTTP, JIT, and hot reload remain permanent conformance consumers
throughout this work. They are not side projects: they prove that the same
typed/effect/memory model survives every execution mode.
