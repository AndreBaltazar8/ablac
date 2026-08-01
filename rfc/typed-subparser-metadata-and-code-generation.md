# RFC: Typed Subparser Metadata and Transactional Code Generation

- Status: Implemented for the current non-generic language: deferred finalizers consume compact post-resolution call maps with default/conversion bindings, direct AST publication, owned local/assignment/lambda builders, and compiler-only declaration hygiene; the stable substitution API becomes populated when generics land
- Target: post-0.1 compiler extension API
- Authors: Abla MVC exploration

## Summary

Add a generic compiler-extension mechanism that lets a compile-time subparser:

1. mark a source expression for deferred processing;
2. inspect that expression after name resolution and type checking;
3. report diagnostics against its original source span; and
4. transactionally generate declarations that are resolved, type-checked, and
   committed only when valid.

The motivating use case is an MVC view DSL that recognizes server actions:

```abla
fun counterView(model: CounterViewModel): Html = $mvcview
    <main>
        <span id="counter">{model.value}</span>
        <button
            onclick={incrementCounter(1)}
            update="#counter">
            Increment
        </button>
    </main>
```

Here, `onclick={incrementCounter(1)}` is not JavaScript and must not invoke the
function while rendering. It identifies a compiled Abla server function. The
MVC extension should be able to validate the call and generate an opaque action
identifier, a typed transport adapter, serialization code, and an action
registry entry. Only functions explicitly referenced by the DSL are exposed.

This RFC does not put MVC behavior into the compiler. It proposes generic
typed-extension facilities that can also support serializers, database query
DSLs, command handlers, dependency injection, and similar libraries.

## Motivation

Abla subparsers can already define embedded syntax such as `$json` and `$html`.
A subparser owns its raw source region, can delegate embedded expressions back
to the Abla parser, and returns an ordinary expression. This is sufficient when
the embedded syntax only needs to construct a value.

Some DSLs also need to understand the resolved meaning of an embedded
expression. An MVC view parser encountering a call needs to know:

- which function the callee resolves to;
- whether overload or member resolution selected one unambiguous declaration;
- the complete parameter and result types;
- whether the declaration is compile-only, trusted, or otherwise ineligible;
- whether argument and result types have framework-supported codecs; and
- where to place a diagnostic when any of those requirements fail.

The extension may then need to synthesize declarations. For an MVC server
action, these declarations include a transport adapter and a registry entry
that keeps the target function reachable during dead-code elimination.

The same need appears in other domains. A serializer DSL needs typed class
fields. A query DSL needs resolved field types. A command framework needs to
collect explicitly marked handlers and generate a dispatcher. Solving this as
a generic compiler API avoids adding a separate compiler feature for each
framework.

## Current limitations

### Opaque parsed expressions

`parserParseAblaExpression` returns a `SyntaxExpression`, but the public parser
API does not expose the expression's structure. A subparser cannot determine
whether the result is a call, inspect its callee or arguments, or retain a
stable reference to its source span.

### Subparsers run before semantic analysis

Subparser expansion occurs while the module is being parsed. At that point,
the embedded expression has not completed name resolution or type checking.
Pure syntax inspection cannot reliably determine which declaration a name
denotes or which codecs a call requires.

### Reflection is declaration-level and read-only

The version 0 compiler API exposes stable function handles, names, parameter
counts, result types, and compile-only status. It does not expose parameter
types, class field schemas, typed expression handles, or the relationship
between a call expression and its selected declaration.

### No validated generation transaction

A subparser can build the expression that replaces its own source region, but
it cannot attach deferred metadata to the program or generate top-level
functions, globals, and registry declarations after semantic analysis.

Mutating a live compiler AST would violate the existing transactional and
deterministic design goals. Generated declarations therefore require an
explicit transaction that re-runs normal validation before commit.

## Goals

- Preserve the existing rule that a subparser returns an ordinary Abla
  expression.
- Let a subparser associate deferred extension metadata with embedded source.
- Expose stable, read-only typed handles after semantic analysis.
- Support precise diagnostics at the original embedded expression.
- Allow hygienic generation of functions, globals, and registry values.
- Resolve and type-check generated declarations before committing them.
- Include extension inputs and outputs in deterministic cache fingerprints.
- Ensure generated references participate in reachability analysis.
- Bound extension rounds, generated declaration counts, and execution cost.
- Keep framework policies, protocols, and serialization outside the compiler.

## Non-goals

- Embedding MVC, HTTP, JSON, or browser behavior in the compiler.
- Exposing mutable compiler implementation objects or backend pointers.
- Allowing arbitrary in-place mutation of resolved declarations.
- Treating event bodies as unrestricted browser-side Abla or JavaScript.
- Automatically exposing every function in a program as a remotely callable
  endpoint.
- Defining one universal serialization format.
- Bypassing ordinary visibility, type, ownership, effect, or trust checks.

## Proposed compilation model

The exact API spelling is deliberately open. The required lifecycle is:

1. A registered subparser parses its source region.
2. It returns the ordinary replacement expression.
3. It may also record a namespaced deferred request associated with one or more
   syntax expressions and their source spans.
4. Normal parsing, name resolution, and type checking continue.
5. After referenced expressions are typed, a registered extension finalizer
   receives stable read-only typed handles for its requests.
6. The finalizer validates framework-specific rules and may open a generation
   transaction.
7. Generated declarations are parsed or constructed as owned syntax, assigned
   hygienic identities, and added to a candidate program.
8. The compiler re-runs resolution, typing, ownership/effect checks, and IR
   verification for the candidate.
9. The transaction commits only if the complete candidate is valid. On
   failure, diagnostics are reported and the original program is unchanged.
10. Staging repeats to a bounded fixed point when generated declarations
    contain additional compile-time work.

The compiler should reject dependency cycles between extension finalizers and
cap the number of finalization rounds, following the existing bounded
subparser-staging model.

## Required read-only information

### Syntax structure

An extension should be able to inspect, without consuming, at least:

- expression kind;
- identifier text;
- member-access receiver and name;
- call target and ordered arguments;
- literal kind and value where applicable; and
- stable source span.

The API must define ownership explicitly. Inspection must not invalidate a
syntax handle that is also used in the returned expansion expression.

### Typed expression information

After semantic analysis, a deferred request should expose:

- normalized expression type;
- resolved declaration for identifiers and call targets;
- selected function or method identity;
- ordered argument expressions and their types;
- inserted default arguments or conversions, if any;
- effect, phase, trust, and ownership information relevant to calling; and
- original source span and expansion provenance.

### Declaration information

Stable declaration handles should expose enough information for frameworks to
build adapters:

- canonical module and declaration identity;
- source-level and canonical names;
- parameter names and normalized types;
- result type;
- class fields and their normalized types;
- visibility;
- compile-only/runtime availability;
- trusted/native status;
- annotations when annotations become part of the stable compiler API; and
- generic substitutions when generics participate in a selected call.

These are read-only handles. They must never expose C++, backend, or mutable
semantic pointers.

## Deferred request API sketch

The following illustrates the capability rather than prescribing final names:

```abla
compile abstract class SyntaxExpression
compile abstract class TypedExpression
compile abstract class DeclarationHandle
compile abstract class SourceSpan
compile abstract class GenerationTransaction

compile extern:"compiler" fun compilerRecordExtensionRequest(
    namespace: string,
    payload: string,
    expression: SyntaxExpression
)

compile extern:"compiler" fun compilerRegisterExtensionFinalizer(
    namespace: string,
    finalizer: (array<TypedExtensionRequest>) -> void
)
```

`payload` is deterministic framework-owned metadata. A structured compile-time
value may replace it once stable compile-time value serialization exists.

Possible typed inspection operations include:

```abla
compile extern:"compiler" fun typedExpressionKind(
    expression: TypedExpression
): string

compile extern:"compiler" fun typedCallTarget(
    expression: TypedExpression
): DeclarationHandle

compile extern:"compiler" fun typedCallArguments(
    expression: TypedExpression
): array<TypedExpression>

compile extern:"compiler" fun declarationParameterTypes(
    declaration: DeclarationHandle
): array<string>

compile extern:"compiler" fun declarationResultType(
    declaration: DeclarationHandle
): string
```

The production API should prefer stable type handles over strings once the
type-reflection contract is ready.

## Transactional generation API

An extension finalizer must be able to generate declarations, not mutate
existing declarations in place. Required construction includes:

- functions and typed parameters;
- blocks, local declarations, calls, returns, and conditionals;
- lambdas or equivalent generated adapter functions;
- arrays and class construction;
- globals or another deterministic registry root; and
- references to resolved declarations without reconstructing names.

The compiler exposes both owned declaration builders and the earlier generated
virtual-module compatibility path. Direct finalizers return a
`GeneratedModuleBuilder`; its declarations retain AST identity, namespace, and
origin span and enter ordinary resolution/typing without a source round-trip.
Both paths are validated exactly like ordinary source before commit.

Generated symbols must use compiler-assigned hygienic identities. Extension
authors should not need to reserve source-level naming prefixes to avoid
collisions.

Generated declarations must record:

- the extension namespace;
- the originating source span;
- the finalizer version or fingerprint; and
- their generated-to-source provenance for diagnostics.

## MVC server-action example

Given:

```abla
fun incrementCounter(amount: int): MvcAction {
    val value = counterIncrement(amount)
    replace("#counter", counterValueView(value))
}

fun counterView(model: CounterViewModel): Html = $mvcview
    <button
        onclick={incrementCounter(1)}
        update="#counter">
        Increment
    </button>
```

the `$mvcview` provider would:

1. parse normal HTML, attributes, text, and interpolations;
2. recognize `onclick` as an MVC event attribute;
3. delegate its braced contents to the Abla expression parser;
4. record that expression as an `abla.mvc.action` deferred request; and
5. return an ordinary HTML construction expression containing a placeholder
   for framework-generated action metadata.

After semantic analysis, the MVC finalizer would:

1. require the marked expression to be a direct call;
2. resolve its selected function;
3. reject compile-only, trusted, native, inaccessible, or otherwise
   ineligible targets;
4. validate call arity and types through ordinary semantic analysis;
5. require framework-supported codecs for every parameter and result;
6. assign a deterministic opaque action identifier;
7. generate a transport adapter that decodes arguments, invokes the typed
   function, and encodes its result;
8. add that adapter to a generated action registry; and
9. make the view expansion render the opaque identifier and serialized
   arguments into HTML metadata.

Conceptually, the emitted markup may resemble:

```html
<button
  data-abla-action="a_7f31c2"
  data-abla-arguments="[1]"
  data-abla-update="#counter">
```

The action identifier must not be a client-controlled function name. The
generated registry is an explicit allowlist, and only functions referenced by
validated view expressions are reachable through it.

The MVC library, not the compiler, implements the HTTP endpoint, browser
runtime, JSON or other transport, DOM update behavior, authorization, CSRF
protection, request limits, and error envelopes.

## Type and codec policy

The compiler supplies type information; the framework decides whether a type
has a transport codec.

An initial MVC implementation may support only:

- `int`;
- `bool`;
- `string`; and
- a fixed `MvcAction` result type.

Later framework versions may recursively derive codecs for arrays, nullable
types, and classes using stable type and field reflection. Unsupported types
must produce a diagnostic at the event expression rather than fall back to an
unchecked dynamic representation.

Resources, native pointers, borrowed values, compiler-only handles, and trusted
capabilities should be rejected unless a future framework explicitly defines a
safe transport contract for them.

## Diagnostics

Diagnostics should identify both the embedded use and relevant declaration.
Examples include:

```text
view.ab:8:22: MVC action must be a direct function call
view.ab:8:22: compile-only function 'rebuildIndex' cannot be a runtime action
view.ab:8:39: no MVC codec is available for parameter type 'Socket'
counter.ab:3:1: action result type 'NativeBuffer' has no MVC codec
```

Generated-code failures should retain an expansion trace from the generated
declaration back to the event attribute and provider module.

## Determinism and caching

Deferred requests and generated output participate in the module and staged-AST
fingerprints. A cache key must include:

- provider source and transitive imports;
- extension namespace and API version;
- finalizer IR or another stable implementation fingerprint;
- request payload and consumed source bytes;
- resolved declaration/type identities;
- granted compile-time capabilities; and
- generated declaration content.

For the same declared inputs, request order, action identifiers, diagnostics,
and generated declarations must be deterministic.

Opaque action identifiers should be derived from stable semantic inputs such as
the extension namespace, canonical declaration identity, selected signature,
and an explicit occurrence discriminator. They must not depend on memory
addresses, process order, or unstable internal declaration indexes.

## Safety and resource bounds

- Finalizers execute in the bounded compile-time machine.
- Ambient filesystem, process, environment, clock, randomness, and network
  access remain capability-controlled and fingerprinted.
- Typed and syntax handles are compilation-scoped and cannot enter runtime IR.
- Generation is size- and round-limited.
- Transactions publish no partial declarations.
- Generated code passes the same semantic, ownership, effect, IR, and backend
  verification as handwritten code.
- An extension cannot make an inaccessible function callable merely by
  naming it in metadata.
- A framework remains responsible for runtime authentication and input
  validation even when transport decoding is generated.

## Reachability and linking

Generated registries are ordinary reachability roots when referenced by the
application. Their handler references keep only explicitly registered actions
and required codecs alive. Unreferenced functions and unused framework
features remain eligible for dead-code elimination.

The compiler should not retain every declaration merely because typed
reflection was enabled during compilation.

## Incremental and `serve` behavior

Changing an MVC view event expression must invalidate:

- that view's subparser expansion;
- its deferred typed request;
- affected generated adapters and registry entries; and
- the final native object or future independently emitted module objects.

Unchanged requests and generated declarations should remain reusable. Adding
or removing an action must update the registry before `ablac serve` replaces
the active worker. A failed generated adapter must reject the new generation
and preserve the last valid worker, matching existing `serve` semantics.

## Testing requirements

Compiler-level positive tests should cover:

- deferred direct-function and method calls;
- stable typed declaration identity;
- parameter and result reflection;
- generated functions and globals;
- reachability through a generated registry;
- deterministic output across repeated builds;
- imported subparser providers;
- incremental invalidation; and
- VM, LLVM, and generated-C parity where the backend supports the feature.

Negative tests should cover:

- a marked expression that is not a call;
- unknown or ambiguous call targets;
- invalid arity and argument types;
- compile-only, trusted, or inaccessible targets;
- unsupported resource and pointer types;
- generation name collisions;
- cyclic finalizers;
- excessive staging rounds or output size;
- invalid generated declarations; and
- transaction rollback after diagnostics.

An MVC integration test should prove that the example view:

1. compiles without a handwritten action registry;
2. emits one opaque action identifier;
3. routes a request only to the referenced function;
4. decodes `1` as an `int`;
5. invokes the compiled action;
6. encodes the resulting `MvcAction`; and
7. hot reloads safely under `ablac serve`.

## Suggested implementation stages

### Stage 1: Read-only typed expression handles

Add structural syntax inspection, source spans, deferred requests, typed call
inspection, and complete function parameter reflection. Permit validation and
diagnostics but require frameworks to keep handwritten registries.

### Stage 2: Generated virtual modules

Allow a finalizer to submit a deterministic virtual module that is parsed and
validated transactionally. This is sufficient for generated adapters and
registries even before a complete declaration-builder API exists.

### Stage 3: Hygienic declaration builders

Add owned builders for declarations and statements, direct stable declaration
references, provenance, and compiler-assigned hygienic identities.

### Stage 4: Structured type reflection

Replace canonical type strings with stable type handles, class-field
reflection, generic substitutions, and framework-derived compound codecs.

## Alternatives considered

### Parse event calls entirely inside the subparser

The provider can manually parse a direct identifier and its argument syntax.
This cannot reliably resolve overloads, validate semantic types, derive codecs,
or generate typed dispatch adapters. It also duplicates base-language parsing.

### Require a handwritten registry

An explicit registry works with the current language and remains a useful
prototype path. It duplicates information already present in the view, can
drift from the markup, and does not provide the intended compile-time guarantee
that every event has exactly one valid transport adapter.

### Register actions when a view renders

Runtime registration makes endpoint availability depend on whether a view was
previously rendered. It complicates concurrency and lifecycle semantics and
cannot derive arbitrary typed adapters without reflection. Registration should
be a deterministic compilation result.

### Expose functions by name through a dynamic dispatcher

Accepting a function name from the client and invoking it dynamically weakens
type safety and creates an unsafe remote-call surface. A generated opaque-ID
allowlist is intentionally required.

### Add MVC-specific compiler intrinsics

This would solve one use case quickly but duplicate mechanisms needed by other
typed DSLs. Generic deferred typed metadata and transactional generation fit
Abla's stated compiler-extension direction better.

## Open questions

- Should deferred requests attach to syntax expressions, explicit marker
  expressions, or both?
- At which semantic milestone are typed handles stable enough for finalizers?
- Should the first generation API accept virtual source modules or require AST
  builders from the start?
- How should generated global registry roots be declared without introducing
  hidden initialization order?
- How are extension namespaces versioned across independently distributed
  packages?
- Which stable semantic inputs should form opaque generated identifiers?
- How should method receiver capture and closure capture be represented to a
  generated transport adapter?
- Can one finalizer depend explicitly on another without creating order-sensitive
  behavior?
- What is the smallest useful structured type-handle API beyond canonical type
  strings?

## Acceptance criteria

This RFC is complete when an ordinary library-provided subparser can implement
the MVC example without compiler-specific MVC logic and with all of the
following properties:

- the event expression is resolved and type-checked normally;
- invalid actions receive precise source diagnostics;
- adapters and registry declarations are generated transactionally;
- only explicitly referenced functions are remotely reachable;
- generated references survive reachability analysis;
- repeated builds are deterministic;
- incremental builds invalidate the correct inputs;
- invalid generated code leaves the program unchanged; and
- the compiler continues to expose stable handles rather than mutable
  implementation objects.
