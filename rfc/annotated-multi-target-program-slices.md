# RFC: annotated multi-target program slices

- Status: Accepted; initial bounded rung implemented
- Target: programmable compiler/build API
- Authors: Abla MVC exploration

## Summary

Implementation note (2026-08-02): marker annotations, reflection, the
compile-time `compiler` service, validated body transforms, aggregated resolved
artifact roots, independent target lowering, explicit exports, Wasm scalar
execution, deterministic rebuilding, and graph rollback are implemented. The
bounded rung rejects ambiguous overloaded source names when reconstructing a
generated child entry; retaining exact overload identity across that child
snapshot remains the next handle-serialization increment. Framework-specific
selection, loaders, manifests, and UI policy remain library work as intended.

Allow an extension to select resolved declarations from one logical Abla
program as roots of more than one target artifact.

The motivating experience is an MVC application where ordinary view syntax can
refer to either a server action or an explicitly client-eligible action:

```abla
@client
fun incrementCounter(current: int, amount: int): int =
    current + amount

fun persistCounter(amount: int): MvcAction = ...

fun counterView(model: CounterModel): MvcHtml = $mvcview
    <main>
        <button onclick={incrementCounter(model.value, 1)}>
            Increment locally
        </button>
        <button onclick={persistCounter(1)}>
            Save on the server
        </button>
    </main>
```

The MVC extension should resolve each call normally. A target carrying
`@client` becomes a root of a browser WebAssembly artifact; an unannotated
target remains a server action and uses the existing generated RPC adapter.
Only client functions actually referenced by the view DSL are exposed.

The same declaration may remain callable by native server code and also be
included in the browser artifact. Shared helpers may appear in several
artifacts when they are reachable from roots in those artifacts. The compiler
must validate and lower each resulting target independently.

This RFC describes the desired behavior rather than prescribing whether the
compiler implements it through typed-IR slicing, repeated target lowering,
generated entry modules, artifact-root sets, child compilations, or another
transactional mechanism.

## Motivation

Abla now has most of the individual pieces:

- deferred typed subparser requests;
- stable declaration and type reflection;
- transactional generated declarations;
- programmable build graphs;
- extension-defined targets;
- explicit foreign exports and ABI manifests; and
- an extension-owned `wasm32-unknown-unknown` module plus browser-loader proof.

What is missing is a general way for an extension to connect these pieces and
say:

> This resolved declaration, selected while compiling the server program,
> should also become an export root of this other artifact in the same build.

Today, a framework can maintain a separate client entry file and explicit
export list. That proves the target and ABI but duplicates information already
present in the view. It also prevents the desired experience where the
annotation declares eligibility and the actual view reference selects what is
distributed.

Literal source copying is not the goal. The compiler may reuse or reconstruct
whatever representation is appropriate. The observable goal is that selected
typed declarations and their required dependencies can participate in several
target compilations without users maintaining parallel implementations or
manual export tables.

## Desired user model

### Explicit distribution boundary

Client distribution must be opt-in:

```abla
@client
fun calculatePreview(value: int): int = value * 2
```

Server execution remains the default. The compiler must not infer that a
function is safe to distribute merely because it happens to compile for Wasm.
Annotations are visible security and deployment policy, not optimization hints.

`client` itself should remain framework-owned metadata. The compiler needs a
general annotation model and reflection surface; it should not contain MVC,
browser, DOM, or RPC policy.

### Selection by ordinary typed references

An annotation makes a declaration eligible for a domain. It does not need to
export every annotated declaration automatically. A framework DSL selects a
root by resolving an ordinary typed reference:

```abla
onclick={calculatePreview(1)}
```

This preserves overload, method, generic, visibility, ownership, and effect
resolution. Textual name lookup is not an adequate substitute for the selected
declaration identity.

### One logical build, several artifacts

A project should be able to produce, transactionally:

- the native server;
- one browser Wasm module containing all selected client roots;
- a generated browser loader and action manifest; and
- ordinary static assets.

A declaration may be reachable in zero, one, or several artifacts. Each
artifact has its own roots, target capabilities, ABI, reachability closure and
diagnostics.

## Goals

- Parse, retain and expose declaration annotations through stable reflection.
- Let an extension classify a resolved call target using those annotations.
- Let repeated extension requests contribute declaration roots to a named
  artifact without producing one artifact per request.
- Build multiple target artifacts from declarations in a shared logical source
  graph.
- Include the transitive code/data dependencies required by each root.
- Permit shared portable functions to be included in both native and Wasm
  outputs.
- Validate target compatibility over the selected reachable closure.
- Export only deliberately selected roots under deterministic, collision-safe
  symbols.
- Preserve source provenance for diagnostics across the selecting DSL,
  declaration, dependency path and target artifact.
- Publish the complete multi-artifact result transactionally and cache it
  deterministically.
- Keep execution-domain, browser, UI, serialization and transport policy in
  extensions and libraries.

## Non-goals

- Making every Abla program automatically browser-compatible.
- Inferring that arbitrary functions are safe to distribute.
- Copying secrets, credentials, server configuration or privileged effects to
  client artifacts.
- Giving WebAssembly unrestricted DOM access from the compiler.
- Defining a universal client/server state synchronization protocol.
- Requiring one internal compiler representation or extraction algorithm.
- Silently falling back to server execution when an explicitly client-selected
  function cannot be built for the client target.
- Exposing all annotated declarations when only a subset is referenced.

## Required observable capabilities

### Declaration annotations

The language should accept marker annotations such as:

```abla
@client
fun calculate(value: int): int = value + 1
```

The annotation model may later support arguments, repeatability and annotation
declarations. This RFC initially requires only that annotations:

- survive parsing, imports, module snapshots and semantic analysis;
- remain associated with the stable resolved declaration identity;
- are available to compile-time reflection and deferred finalizers;
- participate in source/cache fingerprints; and
- have useful source spans for diagnostics.

Exact API names and compile-time value representations are deliberately left
open.

### Artifact root contribution

An extension processing one view expression must be able to contribute its
resolved target to a named logical artifact. Contributions from many modules
and finalizer requests must be aggregated before that artifact is built.

The contribution needs enough identity to preserve the selected overload or
method. It must not degrade into a source name that is looked up again in a
different declaration snapshot.

The compiler may expose a direct root-contribution service, extend programmable
build nodes, generate a target-specific entry, or use another mechanism. The
contract should support at least:

- artifact identity;
- target and artifact kind;
- resolved declaration root;
- requested foreign/export identity;
- source provenance for the request; and
- extension-owned deterministic metadata used to generate a host manifest.

### Reachable target slice

For each artifact, the compiler must discover or validate the declarations,
globals, types and runtime facilities reachable from its roots. Unreachable
server-only facilities must not make an otherwise portable client slice fail.

Conversely, a reachable incompatible dependency must produce an error. For
example, a `@client` function that reaches Linux filesystem I/O must not be
silently stubbed, omitted, or redirected to the server.

Diagnostics should identify:

- the client/server selection site;
- the selected declaration;
- the dependency path that introduces the incompatible operation or value;
- the destination target; and
- the target capability that is missing.

### Multi-target identity and lowering

Sharing a logical declaration between artifacts does not imply sharing target
machine code. Pointer widths, ABIs, runtimes, layouts and capability sets may
differ. Each artifact must receive target-correct lowering and verification.

The compiler is free to share parsing, semantic summaries, typed IR or
reachability information when valid. It must not reuse target-specific state
across incompatible outputs merely because their source declaration is the
same.

### Extension-owned host integration

The compiler should expose enough generic result metadata for an MVC library to
generate:

- a deterministic mapping from opaque view action IDs to Wasm exports;
- an ABI-aware JavaScript loader;
- static asset paths or artifact dependencies; and
- server metadata for actions that remain RPC-backed.

The compiler does not need to understand HTML events, DOM updates, hydration,
or RPC. Those remain MVC policy.

## Illustrative lifecycle

The following is an example lifecycle, not a mandated implementation:

1. Parse declarations and retain `@client` as declaration metadata.
2. Parse `$mvcview` and record each event expression for deferred resolution.
3. Resolve and type-check the complete ordinary program.
4. The MVC finalizer receives the exact selected call target.
5. If the target is unannotated, generate the existing native RPC adapter.
6. If the target has `@client`, validate the framework-supported boundary and
   contribute it to the browser artifact.
7. Aggregate contributions from every view and imported module.
8. Compute and validate the browser artifact's reachable target slice.
9. Lower and link one Wasm module with only the selected public exports.
10. Generate the client manifest/loader and native server artifact.
11. Commit every artifact together, or restore the previous complete build on
    any failure.

## Initial bounded rung

The first implementation can remain deliberately small:

- top-level direct functions only;
- explicit `@client` marker;
- client roots selected only through typed MVC event expressions;
- `bool` and `int` value parameters/results;
- one browser Wasm artifact per application;
- no reachable mutable/runtime-initialized globals;
- no browser host imports;
- no owned string/HTML result ABI;
- uncontained Wasm panic behavior recorded honestly in the ABI manifest; and
- JavaScript-owned DOM updates and temporary client state.

This already enables useful local calculations and interactions. Richer value
transport, allocator contracts, checked panic containment, client state and
host capabilities can be added without changing the selection model.

## Correctness and safety requirements

- An annotation never bypasses ordinary typing, visibility, ownership, effect,
  trust or capability checks.
- Only selected annotated roots become externally callable.
- Export names are generated or validated deterministically and do not expose
  accidental internal symbols.
- The dependency closure cannot accidentally retain unrelated server entry
  points or privileged globals.
- Client code is treated as public/distributable; diagnostics and documentation
  must not suggest it can enforce authorization or protect secrets.
- A client-target failure is a build failure, not an implicit execution-domain
  change.
- Repeated and cached builds produce byte-identical artifacts and manifests for
  identical inputs.
- A failed secondary artifact leaves no new server binary, Wasm module, loader,
  manifest or generated source visible.

## Acceptance scenarios

### Mixed actions

One view references an unannotated `MvcAction` handler and one `@client` scalar
handler. The native server contains the generated RPC registration. The Wasm
module exports only the client handler. The browser manifest maps each opaque
action ID to the correct execution domain.

### Shared declaration

One pure helper is called by both a server handler and a selected client
handler. Both artifacts compile and execute correctly from the same source
declaration, with independent target lowering.

### Aggregation

Client handlers referenced by views in several imported modules contribute to
one deterministic Wasm artifact. Reordering unrelated imports does not change
the selected declaration identities or public mapping.

### No accidental exposure

An annotated but unreferenced helper is not exported. Unannotated functions and
server routes are not present as public Wasm symbols.

### Incompatible dependency

A selected client handler reaches a server-only filesystem operation. The
build fails with a diagnostic connecting the view reference, handler,
dependency path and unsupported Wasm capability. No partial artifacts are
published.

### Overload correctness

Two declarations share a source name. The view's typed call selects one
overload, and the client artifact exports that exact declaration rather than a
later textual lookup.

### Multi-artifact rollback

The native server succeeds but Wasm verification or linking fails. The previous
complete deployment artifacts remain intact and no mixture of old and new
outputs is published.

## Broader applications

Although browser MVC motivates this RFC, the capability is general:

- shared native/Android application cores;
- server and edge/WASI handlers;
- CPU and accelerator kernels;
- command-line and embedded subsets;
- plugin or sandbox modules;
- migration and schema tools compiled from application declarations; and
- test/instrumentation artifacts rooted in selected production functions.

Annotations describe extension-owned eligibility or intent; resolved root sets
and multi-target build transactions provide the generic compiler mechanism.

## Relationship to existing work

`typed-subparser-metadata-and-code-generation.md` provides the resolved DSL
selection and transactional declaration-generation foundation.
`docs/programmable-builds.md` provides program nodes, extension-defined targets,
foreign exports, ABI manifests and graph-wide output rollback. This RFC joins
those capabilities so one typed source graph can deliberately contribute code
to several artifacts without manual parallel export lists.
