# RFC: Contract imports and implementation-free RPC references

- Status: Draft
- Date: 2026-08-04
- Scope: module imports, module interfaces, typed call resolution, compiler extensions, reachability, capabilities, and generated RPC clients

## Summary

An application should be able to keep mobile and backend code in separate
folders while allowing mobile source to make typed references to backend RPC
functions:

```text
product/
  shared/
  mobile/
  backend/
```

The mobile compilation needs the backend function's public name, annotations,
parameter names/types, result type, and reachable data types. It does not need
the backend function body, initializers, compile-time actions, database/network
imports, host capabilities, or server-only transitive implementation graph.

This RFC proposes a contract import: an interface-only projection of another
Abla module. A contract import exposes declaration contracts without merging
implementations into the importing runtime program.

The first motivating use is generated RPC:

```abla
import contract "../backend/counter.ab" as counterRpc

class CounterState(var count: int)

fun counterView(var state: CounterState): MobileView = $mobile
    <Button
        onTap={counterRpc.incrementRemotely(state.count)}
        bindResult={state.count}
    >
        Increment on server
    </Button>
```

where the backend contains:

```abla
@rpc
fun incrementRemotely(count: int): int = nextCount(count)
```

The call is fully resolved and type-checked, then consumed by the `$mobile`
extension and turned into an RPC descriptor. If a contract-only call survives
into runtime IR, compilation fails because there is no local implementation.

The feature is general compiler infrastructure. `@rpc` and `$mobile` remain
framework policies; the compiler understands contract declarations and
consumed calls, not mobile networking.

## Motivation

### Folder and dependency separation

Without a contract import, mobile code must normally import the backend source
module. Whole-program dead-code elimination may remove an unreachable server
function from the final Android library, as the existing Android RPC proof
demonstrates. That is useful but insufficient as the long-term source model:

- the mobile frontend still parses and checks server implementation bodies;
- server-only imports and compile-time effects enter the mobile build graph;
- an implementation-only edit can invalidate mobile compilation;
- target-specific or unavailable server dependencies can prevent a mobile
  build before dead-code elimination;
- generated client code can accidentally retain an implementation path; and
- the dependency boundary is a convention rather than a checked invariant.

The desired property is stronger than “the linker probably strips it”: the
backend implementation is not a member of the mobile runtime program at all.

### More than type-only classes

A conventional type-only import is not enough. RPC client generation needs a
callable declaration contract so that ordinary resolution can validate:

- the exact function selected by the call;
- parameter order, names, defaults, ownership modes, and types;
- result type;
- `@rpc` annotation;
- generic substitutions when supported; and
- stable declaration/module identity.

No function body is needed, but the function signature itself must be callable
inside a context that consumes the call as metadata.

### General extension use

Abla subparsers already record syntax, inspect the resolved call later, and
replace it with another expression. Contract calls formalize the case where
that replacement is mandatory because the referenced declaration has no local
body.

Other future uses include actor/message proxies, database query clients,
device-service bindings, and generated foreign interfaces.

## Current behavior

The current bootstrap module graph recursively loads imported source and merges
its declarations into one parsed program. It calculates an interface identity
from declaration shapes, but there is no source syntax or semantic mode for
importing only that interface.

Native reachability begins at `main`, global initializers, and explicit exports,
then follows calls and address-taken functions. This can remove an unused
backend body after semantic analysis. It does not prevent the body and its
imports from participating in earlier phases.

The [import-aliases RFC](import-aliases-and-qualified-resolution.md) replaces
the prototype `#import(...)` form with an `import` declaration and gives every
direct edge an optional module alias.

## Goals

The proposal must:

1. expose stable declaration contracts without runtime implementations;
2. allow ordinary typed direct-call resolution against a contract function;
3. require every contract-only call to be consumed by an authorized
   compile-time extension before runtime lowering;
4. include all data types needed to understand an exposed signature;
5. exclude implementation bodies, runtime initializers, and implementation-only
   dependencies from the importer;
6. avoid requesting the backend's ambient compile capabilities merely to build
   a mobile client;
7. give contract and implementation artifacts a shared deterministic identity;
8. make implementation-only edits avoid invalidating the consumer when the
   contract is unchanged;
9. preserve annotations and source provenance for generated adapters and
   diagnostics; and
10. remain independent of RPC, HTTP, Android, and iOS policy.

## Non-goals

- Defining the `@rpc` wire protocol or endpoint naming rules.
- Automatically treating every imported function as remote.
- Allowing a contract function to execute locally without an implementation.
- Hiding an incompatible contract change behind a stale cache.
- Designing general source visibility (`public`/`private`) in this RFC.
- Providing separately compiled binary modules in the first implementation.
- Loading a contract dynamically at runtime.

## Proposed syntax

The source form is:

```abla
import contract "../backend/counter.ab" as counterRpc
import contract github("company/service-contracts") as services
```

`contract` is a modifier on the import edge, not a network provider and not an
argument passed to an `ImportSource` expression. It uses the same canonical
path, package lock, cycle, cache, and vendoring rules as an ordinary import.
The semantic distinction—ordinary implementation import versus contract
projection—remains explicit in source and in cache keys.

## Contract projection

A contract projection contains the source module identity and a normalized
declaration interface.

### Included information

For an eligible top-level function:

- canonical module and declaration identity;
- source-visible name;
- annotations and their source spans;
- parameter names, order, ownership modes, and canonical types;
- result type;
- generic parameter/substitution contract when implemented;
- whether it is compile-only, trusted, external, or no-escape;
- declared default-argument contract, if defaults are supported by the first
  implementation; and
- declaration source span for diagnostics.

For a nominal type reachable from an included signature:

- canonical module and type identity;
- kind (`class`, `resource class`, or `interface`);
- annotations;
- field names, order, mutability, ownership, and types;
- method signatures needed by the public shape; and
- transitive reachable nominal/type-argument contracts.

### Excluded information

- function and method bodies;
- top-level runtime value initializers;
- compile-time action expressions;
- mutable/runtime global storage;
- private implementation types not reachable from an included contract;
- server-only native/host imports;
- generated object code; and
- ambient capability grants and observations belonging only to implementation
  evaluation.

The projection is not generated by rendering placeholder source and forgetting
its origin. It is a structured compiler value or module-interface record with
stable provenance. A temporary source representation may bootstrap the feature,
but semantic analysis must retain the `contract-only` marker and enforce its
rules.

## Selecting declarations

The general contract import exposes ordinary top-level function signatures and
nominal types from the selected module. Consumers still need an application
policy to decide which declarations may be used.

For RPC, a framework selects only functions carrying `@rpc` and the types
reachable from those signatures. An unannotated backend function may be visible
to other contract tooling but is not remotely callable merely because it was
imported.

Because Abla does not yet have public/private visibility, the first
implementation may project all top-level declarations and rely on the consuming
extension's selection policy. The interface record must be designed so a later
visibility system can filter non-public declarations without changing contract
call semantics.

A later selective-import proposal may add an annotation-filtered contract
surface. It is not required for the first rung. Any such filter must still
include the complete reachable type closure of the selected root callables.

## Contract dependency closure

The source module may refer to types declared in other modules:

```abla
import "../shared/account.ab"

@rpc
fun loadAccount(id: string): Account = ...
```

A contract importer must receive the `Account` contract. It must not receive
unrelated bodies from `shared/account.ab`.

The compiler constructs a dependency closure from included signatures and
nominal fields/type arguments. It projects only the declarations required to
resolve that closure. Cycles in nominal type contracts are represented by
canonical identity rather than recursively duplicating source.

If a signature depends on a declaration that cannot be represented without
executing an ambient compile-time generator, the contract import fails with an
actionable diagnostic. It does not silently execute the backend's filesystem,
process, environment, network, clock, or random effects.

Subparser providers required merely to parse the module are compiler/frontend
dependencies, not runtime contract declarations. Their deterministic parser
fingerprints participate in extraction cache identity. Their unrelated runtime
APIs do not enter the consumer.

## Contract calls

A call resolved to a contract-only function is represented distinctly in the
typed syntax/IR precursor:

```text
contract.call(moduleIdentity, declarationIdentity, arguments, resultType)
```

It performs normal checks for:

- direct target resolution;
- arity and defaults;
- argument types and conversions;
- ownership/borrow rules;
- result type; and
- generic substitutions.

It does not imply networking, IPC, or a runtime call.

### Mandatory consumption

A contract call must be recorded by an extension request and consumed when the
extension replaces the originating syntax with a runtime-valid expression.
After all extension finalizers run, semantic validation walks the candidate
program. Any remaining contract call is an error:

```text
error[E_CONTRACT_CALL_NOT_CONSUMED]: contract-only function
`backend/counter.ab::incrementRemotely(int) -> int` has no local
implementation
  = contract calls are valid only in a code-generating context that consumes
    the call, such as a registered RPC event
```

This check happens before IR lowering. The compiler must never emit a trap,
null function, external unresolved symbol, or panic stub as the normal behavior
of an unconsumed contract call.

### Extension inspection

Existing typed-call inspection should work for contract calls:

- `typedExpressionKind` distinguishes or additionally flags `contract.call`;
- `typedCallTarget` returns a stable reflected declaration handle;
- parameter/result type handles use canonical identities across snapshots;
- annotation inspection returns the contract annotations;
- resolved argument/default/conversion bindings remain available; and
- source identity identifies both the call site and contract origin.

Add an explicit query such as `typedCallIsContract(expression)` so extensions
do not infer the property from a missing body.

A generated client adapter may use the signature and arguments to create data.
It may not request or splice the server implementation body.

## Example: mobile and backend

```text
counter-product/
  abla.toml
  abla.lock
  shared/
    counter.ab
  mobile/
    app.ab
  backend/
    counter_rpc.ab
    main.ab
```

`shared/counter.ab`:

```abla
fun nextCount(count: int): int = count + 1
```

`backend/counter_rpc.ab`:

```abla
import "../shared/counter.ab"

@rpc
fun incrementRemotely(count: int): int = nextCount(count)
```

`mobile/app.ab`:

```abla
import "abla-mobile"
import "../shared/counter.ab"
import contract "../backend/counter_rpc.ab" as counterRpc

class CounterState(var count: int)

fun incrementLocally(var state: CounterState): void {
    state.count = nextCount(state.count)
    return
}

@mobile_app
fun counterApplication(
    var state: CounterState = CounterState(0)
): MobileView = $mobile
    <Screen id="counter" title="Counter">
        <Text key="count">Count: {state.count}</Text>
        <Button onTap={incrementLocally(state)}>Local</Button>
        <Button
            onTap={counterRpc.incrementRemotely(state.count)}
            bindResult={state.count}
        >Remote</Button>
    </Screen>
```

`$mobile` resolves both direct calls. It lifts the ordinary local function into
a generated local event adapter and records its transitive write to
`state.count`. It sees `@rpc` plus `contract-only` on the remote target,
validates the typed `bindResult` destination, and emits an RPC descriptor. The
event-call position itself is the explicit allowlist; no local marker
annotation is required.

`backend/main.ab` uses an ordinary implementation import:

```abla
import "counter_rpc.ab"
import "abla/http"

fun main: int {
    val router = generatedRpcRouter()
    serveHttp(router, 18080)
}
```

The server generator reflects the real `@rpc` implementation and generates the
decoder/call/encoder route. Client and server manifests contain the same
contract digest.

## RPC version policy

This RFC deliberately does not require `@v1` or parameterized `@rpc(version)`.
The function marker is simply:

```abla
@rpc
fun incrementRemotely(count: int): int = ...
```

Compatibility is checked from a canonical contract digest containing the
service/method identity and normalized parameter/result schema. A changed
contract changes the digest and is detected by generated clients, servers, and
CI.

Abla's existing HTTP router versioning remains available at the service
composition layer:

```abla
router.version("2026-08-04").post(path, handler)
```

An application that needs concurrently served dated API versions can configure
generated route sets with those existing ordered version keys. That deployment
policy does not need to be repeated as an annotation on every RPC function.
The RPC envelope itself can have an independent protocol schema version.

Parameterized annotations may be proposed separately for general language
ergonomics, but contract imports and RPC generation do not depend on them.

## Contract identity and caching

The contract identity includes:

- canonical package/module identity;
- selected declaration identities;
- annotations relevant to the projection;
- normalized parameter names, ownership modes, and types;
- normalized result types;
- reachable nominal type shapes;
- default argument contracts when present;
- compiler contract-interface schema version; and
- deterministic subparser/provider fingerprints required for extraction.

It excludes function bodies and implementation-only dependencies.

Therefore:

- changing a backend function body without changing its contract does not
  invalidate the mobile semantic/object cache;
- changing an RPC parameter, result, annotation, or reachable data shape does;
- changing an unrelated private implementation type does not; and
- changing a parser provider in a way that can alter extracted declarations
  invalidates extraction.

The current module interface fingerprint is a starting point, but a contract
identity must be module-qualified and declaration-structured. A name alone is
not a sufficient cross-module identity.

Contract snapshots participate in the same bounded persistent frontend cache
as ordinary module snapshots. Malformed or stale records are cache misses, not
trusted contracts.

## Capabilities and effects

Contract extraction is read-only compiler work. It does not execute the
module's runtime code or top-level compile actions.

- Runtime effects reachable only from bodies do not enter the consumer.
- Backend compile-time capability requests do not need authorization from a
  mobile root when their actions are not executed for contract extraction.
- Deterministic parser-provider inputs required to understand source remain
  part of the extraction fingerprint.
- A contract whose declaration shape itself depends on an unevaluated ambient
  effect is rejected until the producer publishes an explicit deterministic
  contract artifact.

This keeps a backend database/process/network toolchain out of an Android or
iOS compile without weakening Abla's compile capability model.

## Ownership and unsupported declarations

Contract projection can describe more types than an RPC framework can encode.
The compiler preserves accurate ownership metadata; the consuming extension
decides eligibility.

For example, an RPC generator should initially reject resources, mutable
borrowed results, callbacks, `any`, and unsupported recursive graphs. It must
diagnose the unsupported contract at the client call site and point to the
backend declaration.

Compile-only functions cannot be called from a runtime event contract. Trusted
or external functions may be projected for tooling but are not remotely
callable unless the framework explicitly and safely permits them.

## Generated artifacts and build coherence

The compiler/build extension should be able to publish a deterministic contract
manifest beside generated artifacts. For RPC this may be `rpc-schema.json`, but
the compiler-owned portion should use a framework-neutral contract-interface
schema.

A build containing both mobile and backend should verify:

1. the mobile contract projection and server implementation refer to the same
   locked module identity;
2. their contract digests match;
3. every generated server route has a real eligible implementation;
4. every generated client call names an exposed contract; and
5. no contract-only declaration reaches the mobile artifact.

The backend and mobile may still be built in separate bounded invocations. The
manifest/digest is the coherence boundary until mixed-target build graphs can
express explicit artifact dependencies.

## Diagnostics

Proposed stable errors include:

- `E_CONTRACT_IMPORT_RESOLUTION`
- `E_CONTRACT_IMPORT_CYCLE`
- `E_CONTRACT_INTERFACE_UNAVAILABLE`
- `E_CONTRACT_EFFECT_REQUIRED`
- `E_CONTRACT_IDENTITY_COLLISION`
- `E_CONTRACT_CALL_NOT_CONSUMED`
- `E_CONTRACT_IMPLEMENTATION_MISSING`
- `E_CONTRACT_IMPLEMENTATION_MISMATCH`
- `E_CONTRACT_STALE_MANIFEST`

Diagnostics include both the import/call source span and the projected
declaration's canonical module identity/span. Generated failures preserve the
extension request provenance described by the generated cross-module
diagnostics RFC.

## Implementation outline

### Stage 1: structured interface projection

1. Extend import scanning to retain import kind (`implementation` or
   `contract`) and canonical origin.
2. Add a structured module contract containing declaration signatures,
   annotations, reachable nominal types, and stable identities.
3. Build and cache the reachable contract dependency closure without merging
   bodies/actions into the consumer.
4. Include contract-import edges and identities in frontend cache keys.

### Stage 2: contract call semantics

1. Resolve calls against projected function declarations.
2. Mark resulting typed calls as contract-only.
3. Expose the marker and stable handles through `abla/compiler` typed-call
   reflection.
4. Track which extension request consumes each contract-call syntax node.
5. Reject every unconsumed contract call before IR construction.

### Stage 3: artifact and incremental behavior

1. Emit a framework-neutral contract manifest/sidecar on request.
2. Verify an ordinary implementation import against a previously projected
   contract.
3. Reuse mobile frontend/object state after implementation-only body edits.
4. Prove that backend-only capabilities and target APIs do not enter the mobile
   graph.

## Testing plan

Add tests for:

1. a scalar `@rpc` contract imported into a mobile-style subparser call;
2. ordinary local and contract RPC calls in the same view;
3. a contract call used as an ordinary runtime expression, producing
   `E_CONTRACT_CALL_NOT_CONSUMED`;
4. cross-module annotations, defaults, ownership modes, and result types;
5. a signature using an imported nominal type and nested array/nullable fields;
6. cyclic nominal contract types;
7. duplicate declaration names in different modules using qualified identity;
8. a backend body edit that preserves the contract and reuses the mobile
   interface/object cache;
9. every signature/annotation/type-shape change invalidating the consumer;
10. server-only Linux/process/network imports absent from the mobile runtime
    program;
11. backend compile actions with ambient capabilities not executed by contract
    extraction;
12. a declaration shape that cannot be extracted without an ambient effect;
13. missing, stale, and mismatched implementation/manifest diagnostics;
14. package, relative, vendor, offline, and cyclic contract imports;
15. generated source diagnostics pointing to both the client call and backend
    contract; and
16. IR/artifact inspection proving no contract stub, unresolved symbol, or
    backend body is emitted.

## Acceptance criteria

This RFC is complete when:

- mobile source can import a backend module contract and type-check a direct
  call to its `@rpc` function;
- a registered extension can consume that call and generate a client adapter;
- the same call outside a consuming context fails before IR lowering;
- backend bodies, initializers, implementation-only imports, and effects are
  absent from the mobile runtime graph;
- a backend implementation-only edit does not invalidate the mobile artifact;
- a contract change deterministically does invalidate it;
- server generation verifies a real implementation against the same contract;
- qualified identities prevent cross-module name collisions; and
- cache, package, capability, and diagnostic tests pass at the clean bootstrap
  and fixed-point stages.

## Alternatives considered

### Put RPC declarations in a manually duplicated mobile file

Rejected because signatures drift and the compiler cannot prove client/server
coherence.

### Put shared RPC interfaces in a third folder and implement them separately

Potentially useful as an application convention, but current Abla has no
complete top-level declaration/implementation conformance model. It also makes
users split a simple backend function into multiple declarations. Contract
projection can later support explicit interface-first modules without requiring
them.

### Import the backend normally and rely on dead-code elimination

Acceptable for the existing proof, but it does not isolate frontend checking,
compile effects, target dependencies, invalidation, or accidental reachability.
It remains a compatibility fallback, not the desired boundary.

### Generate an RPC manifest by running the backend, then generate mobile stubs

Useful as an external tool workflow, but weaker than a language-level contract:
it introduces ordering/staleness problems and loses ordinary source resolution
and provenance. The build may emit manifests, but they should derive from the
same compiler contract representation.

### Make every contract call implicitly perform RPC

Rejected because the compiler must not assign network semantics. A consuming
framework chooses RPC, IPC, a mock, or another adapter. Unconsumed calls remain
errors.

### Add only `import type`

Rejected for this use case because RPC generation needs callable signatures and
annotations in addition to nominal data types.
