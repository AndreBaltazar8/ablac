# RFC: Typed dependency and mutation reflection for reactive extensions

- Status: Draft
- Date: 2026-08-04
- Scope: semantic access paths, transitive read/write summaries, compiler extension APIs, generated expression adapters, and incremental invalidation

## Summary

Abla extensions can currently parse an embedded expression, defer work until
semantic analysis, inspect a resolved direct call, and generate validated code.
They cannot inspect the state dependencies of an arbitrary typed expression or
the state mutations performed by a handler.

This RFC proposes structured, compiler-owned access-path summaries for reads
and writes. A reactive framework can use them to compile:

```abla
<Text>Count: {state.count}</Text>
<Button onTap={increment(state)}>Increment</Button>
```

into a dependency edge from `state.count` to the text binding and a mutation
edge from `increment(state)` back to `state.count`. When the handler runs, the
generated native event wrapper refreshes only the affected typed binding getter
or structural selector.

The compiler feature is framework-neutral. It does not define UI state,
signals, rendering, Android, SwiftUI, or an RPC model. It exposes semantic facts
that can also support spreadsheets, incremental templates, query systems, build
graphs, and other reactive libraries.

## Motivation

Re-running or replacing an entire view after every event is correct but loses
the main benefit of declarative native UI systems. Compose and SwiftUI both
derive updates from state dependencies. An Abla UI framework should be able to
do the same rather than imitate server-rendered HTML actions.

A source-text scan is not sufficient. These expressions may have the same
dependency despite looking different:

```abla
state.count
formatCount(state)
present(state.counter.value)
```

Aliases, member calls, helper functions, conditionals, indexes, and inserted
conversions require resolved types and interprocedural analysis. Likewise, a
handler may mutate state transitively:

```abla
fun increment(var state: CounterState): void = updateCounter(state)
```

The compiler already performs ownership, alias, region, and mutation analysis.
Extensions need a bounded, stable projection of those results rather than a
second approximate analyzer implemented in a UI package.

## Current behavior

`abla/compiler/parser` exposes structural syntax inspection and a first typed
expression rung centered on direct calls:

- `typedExpressionType` and `typedExpressionKind`;
- `typedCallTarget` and argument/result types;
- argument-to-parameter/default/conversion bindings; and
- ownership, phase, and trust metadata.

The language compiler already infers transitive effects including heap/global
mutation for ownership and region checking. Those summaries are not exposed as
field-sensitive read/write paths to extensions.

Generated module builders can consume syntax expressions as function bodies,
but there is no explicit API for lifting an expression that refers to enclosing
parameters/locals into a generated function with hygienic capture remapping.

## Goals

The proposal must:

1. describe typed reads and writes relative to stable roots;
2. preserve field and constant-index precision where semantic analysis knows
   it;
3. represent dynamic/unknown projections conservatively;
4. propagate summaries through ordinary direct/member calls;
5. substitute callee parameter paths with the caller's resolved argument
   paths;
6. account for aliases, mutable parameters, `Cell.get`/`Cell.set`, and nested
   calls;
7. expose summaries through opaque compiler-owned handles;
8. let an extension hygienically lift a recorded expression into a generated
   binding evaluator or event handler;
9. remain deterministic, bounded, cacheable, and snapshot-safe; and
10. prefer conservative invalidation over unsoundly missing a dependency.

## Non-goals

- Adding a `reactive`, `signal`, or UI keyword to the Abla language.
- Persisting application state in compiler/runtime globals.
- Retaining callbacks across a foreign ABI call.
- Automatically scheduling threads or tasks.
- Proving that arbitrary I/O is referentially transparent.
- Choosing a view diff protocol.
- Making every ordinary variable observable at runtime.

## Access-path model

An access path has one root and zero or more projections:

```text
root.parameter(state) .field(counter) .field(value)
root.local(model)     .field(name)
root.global(settings) .field(theme)
root.parameter(items) .index.constant(4)
root.parameter(items) .index.dynamic
root.parameter(state) .wildcard
```

Root identity is semantic and module-qualified; it is not only source text.
Projection kinds begin with:

- immutable or mutable field;
- constant array index;
- dynamic array index;
- `Cell<T>` payload;
- dereference/managed payload where safe to expose; and
- wildcard remainder.

The summary also records access kind:

- `read`;
- `write`;
- `read-write`; and
- `consume`.

A write to `state.counter` invalidates a dependency on
`state.counter.value`. A write to `state.counter.value` need not invalidate a
dependency on the disjoint `state.profile.name`. A wildcard write rooted at
`state` invalidates every dependency below that root.

The compiler may internally use place/provenance IDs. The public API presents
opaque handles and structured queries so its representation can evolve.

## Direct expression summaries

For every resolved expression, the compiler can produce:

- paths whose values are read;
- paths that may be written;
- paths whose ownership is consumed;
- whether unknown external/global state is read;
- whether unknown external/global state is written; and
- ordinary inferred effects such as allocation, filesystem, network, clock,
  randomness, process, or trusted native access.

Literal and pure constructor expressions have no state dependency beyond their
arguments. A field read records its resolved root/path. Assignment records a
write and reads from the right-hand side. A compound update records both.

`Cell<T>` is explicit interior mutability:

```abla
state.count.get()       // read state.count.<cell-value>
state.count.set(value)  // write state.count.<cell-value>, read value
```

This is distinct from treating all method calls as unknown mutation.

## Transitive function summaries

Functions receive summaries relative to their parameters, receiver, and
globals. Analysis reaches a call-graph fixed point, as existing mutation/region
effects already do.

Given:

```abla
fun formatCount(state: CounterState): string = "${state.count}"

fun increment(var state: CounterState): void {
    state.count = state.count + 1
}
```

the summaries are conceptually:

```text
formatCount: read parameter[0].count
increment:   read-write parameter[0].count
```

At `formatCount(appState)`, the compiler substitutes the resolved path of
`appState` for parameter zero. If alias analysis cannot preserve a projection,
it returns a wildcard at the narrowest sound root.

Indirect calls use the callable's declared/inferred effect summary. If a
callable lacks a field-sensitive contract, the result is conservative. Native
and external calls report their declared effects and wildcard mutation for any
mutable argument they may retain or modify.

Recursive summaries converge under bounded widening: precise paths are kept up
to a configured count/depth, after which the affected root becomes wildcard.

## Proposed compiler extension API

Add an opaque compile-only handle:

```abla
compile abstract class TypedAccessPath
```

Expression queries:

```abla
compile extern:"compiler" fun typedExpressionReadCount(
    expression: SyntaxExpression
): int

compile extern:"compiler" fun typedExpressionRead(
    expression: SyntaxExpression,
    index: int
): TypedAccessPath

compile extern:"compiler" fun typedExpressionWriteCount(
    expression: SyntaxExpression
): int

compile extern:"compiler" fun typedExpressionWrite(
    expression: SyntaxExpression,
    index: int
): TypedAccessPath

compile extern:"compiler" fun typedExpressionReadsUnknown(
    expression: SyntaxExpression
): bool

compile extern:"compiler" fun typedExpressionWritesUnknown(
    expression: SyntaxExpression
): bool
```

Path queries:

```abla
compile extern:"compiler" fun typedAccessRootKind(path: TypedAccessPath): string
compile extern:"compiler" fun typedAccessRootIdentity(path: TypedAccessPath): string
compile extern:"compiler" fun typedAccessRootParameter(path: TypedAccessPath): int
compile extern:"compiler" fun typedAccessSegmentCount(path: TypedAccessPath): int
compile extern:"compiler" fun typedAccessSegmentKind(path: TypedAccessPath, index: int): string
compile extern:"compiler" fun typedAccessSegmentName(path: TypedAccessPath, index: int): string
compile extern:"compiler" fun typedAccessSegmentIndex(path: TypedAccessPath, index: int): int
```

Function-level reflection exposes the declaration summary with equivalent
queries rooted at its parameters/receiver/globals. The exact method naming may
be grouped behind the `compiler` service; opaque path semantics are normative.

Every handle is compilation-scoped and validated against its originating typed
snapshot. Cross-module generated requests store canonical path/root identities,
not raw integer handles alone.

## Hygienic expression lifting

A reactive extension records interpolation and handler expressions while its
subparser owns their syntax. After typing, it needs generated functions such as:

```text
binding_7(state) -> string
handler_3(var state, eventPayload) -> void
```

Add a compiler-owned builder operation that consumes a recorded expression and
an ordered capture map. Each capture maps a resolved enclosing parameter/local
place to a generated function parameter. References are rewritten by semantic
identity, not source-name replacement.

Conceptually:

```abla
compilerGeneratedLiftedFunction(
    module,
    name,
    captures,
    explicitParameters,
    resultType,
    expression
)
```

The operation rejects:

- an unlisted free variable;
- a capture whose ownership cannot cross the lifted boundary;
- escaping borrows or affine values;
- an incompatible mutable capture;
- a compile-only/runtime phase mismatch; and
- a contract-only call not explicitly consumed by the owning extension.

The generated function passes ordinary parsing, semantic, ownership, effect,
IR, and target verification. This API does not create retained foreign
callbacks.

## Reactive invalidation semantics

This RFC exposes facts; a framework chooses invalidation behavior. The intended
sound rule is:

```text
invalidate(binding) when
    changed-write-path intersects binding-read-path
```

Intersection is prefix-aware and treats wildcards conservatively. If a binding
reads unknown/global state, the framework may re-evaluate it after every event
or reject it in a strictly reactive view. If a handler writes unknown state, it
invalidates every binding in the selected application boundary.

Static summaries identify possible writes. A generator can map each event to
the intersecting binding getters at build time. Calling those getters after the
handler returns is sound even when a branch did not actually write: assigning
an equal result to a Compose/SwiftUI observable slot is suppressed by the native
observation layer. A runtime may later narrow the set with write
instrumentation, but that is an optimization rather than part of this API.

One handler invocation is a boundary for UI observation. Multiple writes inside
it cause one generated refresh block after normal return; the native UI does not
observe intermediate values. Panic behavior follows the surrounding
checked-export/runtime contract. If a retained application instance may have
been partially mutated, its handle must be poisoned rather than refreshed; this
RFC does not claim state rollback.

## Dynamic structure

Not every dependency is a scalar property. Extensions label evaluation
boundaries:

- scalar text/property binding;
- conditional subtree;
- keyed repeated subtree;
- complete component property set; or
- root fallback.

A changed dependency re-evaluates the smallest recorded boundary. Repeated
children use application-supplied stable keys. The compiler provides access
paths, not list-diff policy.

## Effects and purity

A view binding should normally be effect-free apart from allocation. The
extension can reject bindings that perform writes, I/O, clock, randomness,
process, network, or trusted native access. This makes re-evaluation safe.

Handlers may write declared application state and request framework effects.
The extension decides which additional effects are legal. The compiler exposes
the facts and diagnoses calls that violate ordinary capability policy.

## Caching and determinism

Read/write summaries are part of the typed module interface for declarations
whose consumers observe them. A body edit that changes a public function's
dependency/mutation summary invalidates reactive consumers even when its source
signature is unchanged.

Cache identity includes:

- compiler summary-schema version;
- canonical root/type/declaration identities;
- normalized paths and wildcard widening;
- transitive callee summaries; and
- the ordinary typed interface/effect fingerprints.

Ordering is deterministic by root identity and projection sequence, not hash
table iteration or source traversal accidents.

## Diagnostics

Proposed stable errors include:

- `E_REACTIVE_DEPENDENCY_UNAVAILABLE`
- `E_REACTIVE_BINDING_WRITES_STATE`
- `E_REACTIVE_BINDING_EFFECT`
- `E_REACTIVE_HANDLER_CAPTURE`
- `E_REACTIVE_HANDLER_STATE_ROOT`
- `E_REACTIVE_LIFT_FREE_VARIABLE`
- `E_REACTIVE_LIFT_OWNERSHIP`
- `E_REACTIVE_SUMMARY_LIMIT`

Diagnostics point to the view interpolation/handler expression and include the
transitive function/call that introduced an unknown or forbidden access.

## Implementation outline

1. Extend existing place/provenance and function-effect analysis with bounded
   parameter/receiver/global access paths.
2. Compute transitive summaries with argument-path substitution and wildcard
   widening.
3. Persist summaries in typed module interfaces and cache fingerprints.
4. Expose opaque expression/function/path queries through
   `abla/compiler/parser` and `abla/compiler`.
5. Add hygienic recorded-expression lifting to `GeneratedModuleBuilder`.
6. Reject stale/snapshot-mismatched handles transactionally.
7. Add one non-UI proof extension that records a binding and handler, emits
   adapters, and verifies their dependency intersection.

## Testing plan

Add tests for:

1. direct parameter field reads and writes;
2. nested fields, constant indexes, dynamic indexes, and wildcards;
3. local/global aliases and disjoint sibling fields;
4. mutable parameters and receiver methods;
5. `Cell.get` and `Cell.set`;
6. direct, member, indirect, recursive, and mutually recursive calls;
7. argument-path substitution through multiple call layers;
8. unknown external/native effects;
9. read-only bindings rejecting transitive writes/I/O;
10. hygienic lifting of enclosing state and event payload parameters;
11. invalid free, borrowed, affine, and mutable captures;
12. cross-module and contract-imported calls;
13. deterministic summaries across repeated builds;
14. cache invalidation when a function's summary changes but signature does
    not;
15. wildcard widening at path/count/depth bounds; and
16. generated diagnostics preserving source and extension provenance.

## Acceptance criteria

This RFC is complete when:

- an extension can ask for the precise state reads of an arbitrary typed
  interpolation expression;
- it can ask for transitive writes of a typed handler expression/call;
- aliases, helper calls, and `Cell` operations remain sound;
- uncertain analysis returns a conservative wildcard rather than no access;
- recorded expressions can be lifted into hygienic generated functions with
  explicit captures;
- summaries survive cross-module snapshots and invalidate caches correctly;
- all generated code passes the ordinary ownership/effect/IR pipeline; and
- clean bootstrap and fixed-point tests cover the public API.

## Alternatives considered

### Re-render the complete view after every event

Correct as a temporary fallback, but it does not meet the intended reactive
boundary model and can discard native component state or perform excessive
work.

### Detect dependencies from source text in the UI subparser

Rejected because aliases, overloads, helper calls, conversions, and transitive
mutation require semantic information.

### Make `Cell<T>` itself notify the platform host

Rejected as the general boundary. It would require retained callbacks or
runtime-global subscription state across JNI/C, has thread/lifecycle concerns,
and supports only copy scalar payloads today. A framework may recognize Cell
paths, but generated event wrappers still refresh affected binding getters at
the application call boundary.

### Include foreign application ownership in dependency reflection

Rejected as a coupling of two compiler concerns. A native framework can retain
application state with a typed, rooted handle as proposed by the
[foreign-owned-instance-handles RFC](foreign-owned-instance-handles.md), while
using this RFC to generate the getters and event-to-binding refresh map.
Dependency summaries remain useful to frameworks with other state ownership
models.
