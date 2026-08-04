# RFC: Import aliases and qualified module resolution

- Status: Draft
- Date: 2026-08-04
- Scope: import syntax, module-local namespaces, qualified name and type
  resolution, declaration identity, contract projections, compiler reflection,
  diagnostics, and incremental caching

## Summary

Abla imports currently merge declarations from every imported module into one
source-visible namespace. This is convenient for small programs, but it makes
same-named declarations collide and gives a consumer no concise way to state
which module owns a reference.

This RFC proposes explicit import aliases:

```abla
import "../shared/counter.ab" as counters
import contract "../backend/counter_rpc.ab" as counterRpc

fun next(value: int): int = counters.nextCount(value)

fun remote(value: int): int = counterRpc.incrementRemotely(value)

class ScreenState(val account: models.Account)
```

An alias is a compile-time namespace binding. It is not a runtime object, does
not allocate storage, and cannot be passed to a function. An aliased import
exposes its declarations only through that alias; it does not add their names
to unqualified lookup in the importing module.

The feature applies equally to implementation imports and the contract imports
proposed by the [contract-imports RFC](contract-imports-and-rpc-projections.md).
It supplies the source-level
qualification needed when two modules contain the same declaration name while
preserving one canonical declaration identity independent of the alias chosen
by each importer.

## Motivation

### Collision-free composition

Two libraries may legitimately expose the same short name:

```text
payments/client.ab     fun connect(...)
analytics/client.ab    fun connect(...)
```

Flattening both into the importing namespace either rejects the program or
silently makes resolution depend on import order. Aliases make both references
explicit:

```abla
import "payments/client.ab" as payments
import "analytics/client.ab" as analytics

val payment = payments.connect(configuration)
val telemetry = analytics.connect(configuration)
```

Import order must never select one of two otherwise ambiguous declarations.

### Contract and implementation coherence

A mobile client may import a backend contract while also defining or importing
a local function with the same short name:

```abla
import "counter_local.ab" as localCounter
import contract "../backend/counter.ab" as serverCounter

val local = localCounter.increment(value)
val remote = serverCounter.increment(value)
```

Both calls retain the canonical identity of their target. The remote call is
also marked contract-only and must be consumed by an authorized extension, as
defined by the contract-imports RFC.

### Readable ownership

Qualified references document where a declaration comes from without encoding
filesystem paths in ordinary expressions. This is particularly useful in
generated-client packages, platform integrations, build definitions, and
modules that combine several implementations of a common policy.

### Stable compiler reflection

Compiler extensions currently receive declaration handles but canonical
function identities are not fully module-qualified. An alias feature requires
the compiler to distinguish:

- the source spelling used by this importer;
- the import alias used for lookup;
- the canonical module identity; and
- the canonical declaration identity.

That distinction also benefits generated diagnostics, contract manifests,
reactive summaries, cache keys, and foreign ABI manifests.

## Current behavior

The bootstrap import scanner records ordinary imports as strings and provider
imports as expressions. `BootstrapModuleGraph` recursively loads every module
and merges its declarations and compile-time actions into one parse result.

Semantic resolution primarily selects declarations by short source name and,
for methods, receiver owner. Module interface fingerprints exist, but a
declaration does not yet carry a first-class canonical module origin through
all semantic and reflection APIs.

Expression syntax already parses `left.member` and `left.member(...)`. Type
parsing preserves punctuation as text, so dotted type spellings can be parsed,
but neither form currently recognizes a module namespace binding.

## Goals

The proposal must:

1. let one module bind a direct import to an explicit local alias;
2. keep declarations from an aliased import out of unqualified lookup;
3. resolve qualified functions, values, constructors, types, and interfaces;
4. distinguish namespace qualification from runtime member access;
5. support ordinary and contract imports with the same lookup model;
6. permit same-named declarations from different aliased modules;
7. retain one module-qualified canonical identity independent of local alias;
8. preserve ordinary ownership, phase, trust, effect, and reachability checks;
9. keep aliases module-local and non-transitive;
10. produce deterministic diagnostics and cache identities; and
11. preserve current unaliased-import visibility semantics during the source
    migration away from `#import`.

## Non-goals

- Treating a module as a runtime value or object.
- Dynamic module loading or runtime symbol lookup.
- Re-exporting an imported alias in the first implementation.
- Defining `public` and `private` visibility.
- Wildcard, selective, or renamed individual declaration imports.
- Making imports dependent on runtime control flow.
- Allowing an alias to choose between overloaded declarations by itself.
- Defining package names or package-manager dependency aliases.
- Replacing canonical package/module identity with a local nickname.

## Proposed syntax

The import grammar is conceptually:

```text
import [contract] <source> [as <identifier>]
```

`source` is either a string literal or a compile-time expression returning
`ImportSource`. `contract` projects declarations without implementations, and
`as` binds the resulting module to a local namespace alias.

Local and standard-library imports are:

```abla
import "../shared/models.ab" as models
import "abla/http" as http
import contract "../backend/account_rpc.ab" as accountRpc
```

Typed package providers use the same declaration shape:

```abla
import github("AndreBaltazar8/abla-mvc") as mvc
import contract github("company/service-contracts") as services

import gitImportSource(
    "company-ui",
    "ssh://git@git.example.invalid/platform/company-ui.git",
    "tag",
    "v1.2.0"
) as companyUi

import generatedSchema() as schema
```

The provider expression returns `ImportSource` exactly as it does today.
`contract` and `as` belong to the surrounding import declaration; they are not
arguments passed into `github`, `gitImportSource`, or a custom provider.

The alias is one ordinary identifier. Keywords, empty names, dotted names, and
generated hygiene names are rejected. The alias is explicit, statically bound,
and part of the import edge rather than the imported module.

This RFC intentionally replaces the prototype `#import(...)` spelling instead
of adding a second permanent syntax. Migration is mechanical:

```text
#import("module.ab")             -> import "module.ab"
#import(github("owner/repo"))    -> import github("owner/repo")
```

The alias/contract implementation is complete only when compiler and standard
library sources use `import` and `#import` has been removed from the lexer,
scanner, parser, documentation, and tests.

## Namespace semantics

### Compile-time-only binding

For:

```abla
import "math/vector.ab" as vectors
```

`vectors` is a module namespace binding available while parsing and resolving
the importing module. It has no Abla runtime type. These are invalid:

```abla
val stored = vectors
consume(vectors)
val aliases = [vectors]
```

The compiler diagnoses an alias used without a declaration qualification.

### Qualified declarations

The first implementation supports:

```abla
vectors.zero                         // imported top-level val
vectors.origin                       // imported top-level var or val
vectors.length(point)                // imported top-level function
vectors.Point(10, 20)                // imported constructor
vectors.Point                        // imported nominal type in type position
vectors.Shape                        // imported interface in type position
vectors.callback                     // imported function reference
```

The same `.` token remains ordinary member syntax. Resolution distinguishes the
forms semantically:

- if the leftmost bare identifier is a visible module alias, the first segment
  is namespace qualification;
- otherwise the expression is ordinary field, method, or extension-member
  access; and
- after a qualified value or call produces a runtime value, later segments are
  ordinary runtime members.

For example:

```abla
models.defaultAccount.name
```

resolves `models.defaultAccount` statically, then reads the runtime `name`
field.

### Type qualification

Qualified types are valid everywhere an ordinary nominal type is valid:

```abla
fun load(id: int): models.Account = models.Account(id, "")

class Session(
    val current: models.Account?,
    val pending: array<models.Account>
)
```

Normalization resolves the source spelling to the canonical nominal type
identity. Diagnostics may retain the local spelling for readability, but
ownership, layout, generic arguments, and equality operate on canonical type
identity rather than the alias text.

### Inherent methods

An instance of an aliased nominal type uses ordinary member syntax:

```abla
val account: models.Account = models.Account(1, "Abla")
val label = account.displayName()
```

The alias is not repeated because `displayName` is selected from the canonical
receiver type.

Aliasing a module does not inject that module's extension methods into
unqualified member lookup in the first implementation. A later selective
extension-import proposal may define that policy. This restriction prevents an
apparently isolated alias from changing method resolution throughout the
importer.

### Top-level runtime values

An ordinary aliased implementation import may expose top-level `val` and `var`
declarations through the alias. Their initialization and lifetime are exactly
the same as under an unaliased implementation import. The alias does not create
a second copy of a global.

A contract import never exposes runtime initializers or global storage, even
when aliased.

## Lookup and shadowing

### Alias declaration scope

An import alias belongs to the importing module's declaration scope. It is not
visible inside modules imported by that module and is not automatically visible
to importers of that module.

The following are errors in one module:

- two import edges using the same alias;
- an alias matching a top-level function, type, value, or generated
  declaration in that module;
- importing the same canonical module both aliased and unaliased; and
- importing the same canonical module through two aliases.

The last two restrictions can be relaxed later, but rejecting them initially
keeps initialization, diagnostics, and extension registration unambiguous.

### Local shadowing

A parameter or local may use the same text as an import alias. In expression
position the innermost runtime binding wins, so its member access is ordinary
runtime access. In type position runtime bindings do not participate, so the
module alias remains available.

Extensions and style tools may warn about such shadowing. It is not a semantic
ambiguity because lookup priority is fixed and independent of declaration or
import order.

### Unaliased imports

An alias remains optional:

```abla
import "math/vector.ab"
```

They continue to make eligible declarations available through unqualified
lookup. If two unaliased imports provide the same eligible name and neither is
the same canonical declaration, lookup reports ambiguity. Source order does
not break the tie.

An application can introduce aliases one edge at a time by qualifying only
references originating from that edge. Migration from `#import` to `import` is
a repository-wide syntax rewrite rather than a permanent compatibility mode.

## Direct versus transitive visibility

Aliases name direct import edges only:

```text
app.ab --as services--> services.ab --> models.ab
```

`app.ab` can use declarations directly exposed by `services.ab` as
`services.name`. It cannot use `services.models.Account` merely because
`services.ab` imports `models.ab`.

If `app.ab` needs `Account`, it imports `models.ab` itself under an alias. A
future re-export feature may deliberately expose another module, but ordinary
imports do not create accidental transitive APIs.

The imported module continues to resolve its own implementation dependencies
using its own import environment. Alias locality changes consumer visibility,
not the imported module's internal behavior.

## Ordinary import behavior

Aliasing an ordinary implementation import changes name visibility only. It
does not suppress:

- imported function or method bodies;
- top-level runtime initialization;
- compile-time actions;
- explicitly authorized compile effects;
- subparser registrations; or
- runtime reachability from selected imported declarations.

Applications seeking implementation isolation use a contract import, not an
ordinary alias.

Compile actions and subparser registrations remain module actions rather than
namespace members. Importing the module ordinarily activates them according to
the existing module graph rules. This RFC does not create syntax such as
`alias.$subparser`.

## Contract imports

Aliases are the preferred source form for contract imports:

```abla
import contract "../backend/counter.ab" as counterRpc

val action = counterRpc.incrementRemotely(state.count)
```

The alias controls lookup only. The selected declaration remains
contract-only, and all mandatory-consumption rules from the
[contract-imports RFC](contract-imports-and-rpc-projections.md) still apply.

Two modules may expose the same RPC function name safely:

```abla
import contract "../billing/rpc.ab" as billing
import contract "../shipping/rpc.ab" as shipping

val invoice = billing.status(orderId)
val parcel = shipping.status(orderId)
```

Their canonical identities and contract digests differ by module identity even
though both short names are `status`.

Contract type closure may include types declared in another module. The
consumer must either receive those types as part of the structured contract
projection or import their defining module directly under an alias. A
projected type's canonical identity never depends on which route made it
visible.

## Canonical identity

Every source declaration participating in cross-module lookup receives a
canonical identity containing at least:

- canonical package identity and locked revision when applicable;
- canonical module path within the package;
- declaration kind;
- nominal owner for a method;
- source-visible declaration name; and
- a normalized signature discriminator if Abla later supports overloads.

For example, two importers may write:

```abla
import "shared/models.ab" as models
import "shared/models.ab" as domain
```

in separate modules. `models.Account` and `domain.Account` refer to the same
canonical type. The aliases are not part of that type's identity.

Renaming a local alias invalidates and recompiles the importer because its
source lookup changed. It does not change the imported module interface,
contract digest, native symbol identity, or another importer's cache.

## Semantic representation

The compiler should represent an import as a structured edge rather than a
string or an evaluated provider alone:

```text
ImportEdge {
    importerIdentity
    requestedSource
    resolvedModuleIdentity
    kind: implementation | contract
    alias: optional identifier
    sourceSpan
}
```

Each parsed declaration retains its defining module identity separately from
its source-visible name. A module-local resolution environment contains:

- unqualified declarations from the current module;
- unqualified declarations from compatibility imports;
- alias-to-module edges; and
- generated declarations published into the current module.

Qualified resolution produces the same declaration handle used by ordinary
resolution. It does not rewrite `alias.name` into a globally mangled source
identifier and repeat name lookup later.

IR and backend symbol formation consume canonical declaration handles or
identities. Alias spelling must not leak into native symbol identity unless an
explicit export requests that spelling.

## Compiler reflection and generated code

Existing reflection operations continue to report the declaration's short
name, owner, parameters, annotations, and result type. Add explicit origin
queries such as:

```abla
compile extern:"compiler" fun compilerFunctionModuleIdentity(
    function: int
): string

compile extern:"compiler" fun compilerTypeModuleIdentity(type: int): string

compile extern:"compiler" fun typedCallSourceQualifier(
    expression: SyntaxExpression
): string
```

`typedCallSourceQualifier` is diagnostic/source metadata. Generated adapters
must retain and invoke the selected declaration handle through
`syntaxCallTarget` or `syntaxMethodCallTarget`; they must not reconstruct a
qualified name from alias text.

Generated modules have their own compiler-assigned namespace and origin. A
generated declaration may reference an imported target handle available to the
owning extension request. Publication revalidates the handle against the same
typed snapshot, as with existing generated calls.

Compatibility source generators that must render a qualified reference can ask
the compiler for a collision-free source spelling in their generated module.
The handle-based builder remains preferred.

## Ownership, effects, and reachability

Qualification does not change a declaration contract:

- `own`, `var`, borrowed, affine, and nullable rules are identical;
- trusted, external, no-escape, compile-only, and contract-only markers remain;
- compile and runtime effects are those of the selected declaration;
- globals retain their original defining module and initialization; and
- native reachability follows the selected canonical function handle.

A qualified call cannot bypass an ambiguous or inaccessible declaration and
cannot convert a contract-only declaration into a local implementation.

Thread capture restrictions also apply normally. A module alias itself cannot
be captured because it is not a runtime place; a qualified shared value or
function is analyzed according to the value it resolves to.

## Packages, providers, and capabilities

Aliases do not alter package resolution. The requested import is resolved,
locked, vendored, and checked offline using the same canonical dependency and
`ImportSource` rules as an unaliased edge.

For provider imports, `contract` and the alias belong outside the provider
expression:

```abla
import github("owner/repository") as service
import contract github("owner/service-contracts") as serviceContract
import companyRegistry("checkout", "v3") as checkout
```

The provider resolves an `ImportSource`; the enclosing import declaration
chooses implementation versus contract projection and binds the resulting
module alias. The provider cannot dynamically choose either property.

Ordinary implementation imports request their normal compile capabilities.
Contract aliases follow contract-extraction capability rules and do not execute
implementation-only compile actions.

## Caching and incremental builds

The importing module's frontend cache identity includes, for each direct edge:

- import kind;
- canonical resolved module identity;
- imported interface or contract identity;
- local alias spelling or the unaliased marker;
- deterministic provider identity; and
- any parser-provider fingerprint required to understand the importer.

Edge ordering is normalized or otherwise made deterministic. Reordering two
independent aliased imports must not change canonical declaration identities or
generated native symbols.

The imported module's interface cache excludes consumer alias spellings. A
consumer alias rename invalidates that consumer, while an implementation-only
body edit follows the ordinary or contract-specific invalidation policy.

Cached semantic records store canonical declaration identities and validated
module-local lookup bindings. A stale alias map is a cache miss, never a reason
to resolve a cached short name against a different module.

## Diagnostics

Proposed stable errors include:

- `E_IMPORT_ALIAS_INVALID`
- `E_IMPORT_ALIAS_DUPLICATE`
- `E_IMPORT_ALIAS_DECLARATION_COLLISION`
- `E_IMPORT_ALIAS_TARGET_DUPLICATE`
- `E_IMPORT_ALIAS_UNKNOWN`
- `E_IMPORT_ALIAS_MEMBER_UNKNOWN`
- `E_IMPORT_ALIAS_USED_AS_VALUE`
- `E_IMPORT_QUALIFIED_TYPE_UNKNOWN`
- `E_IMPORT_UNQUALIFIED_AMBIGUOUS`
- `E_IMPORT_EXTENSION_NOT_VISIBLE`

Diagnostics identify both the alias declaration and attempted qualified use.
For example:

```text
error[E_IMPORT_ALIAS_MEMBER_UNKNOWN]: module alias `billing` has no exposed
declaration named `state`
  = alias `billing` resolves to package/billing/rpc.ab
  = imported here: mobile/app.ab:3
```

An ambiguity diagnostic lists every candidate using canonical module identity
and suggests adding aliases. Contract diagnostics additionally preserve the
projected backend declaration origin.

## Implementation outline

### Stage 1: structured import edges and origins

1. Replace snapshot import strings with structured import edges carrying kind,
   alias, source span, and canonical target.
2. Retain canonical defining-module identity on parsed declarations.
3. Diagnose duplicate aliases, declaration collisions, and duplicate target
   edges before semantic analysis.
4. Include the edge map in frontend cache identity.

### Stage 2: qualified type and expression lookup

1. Recognize aliases in type normalization and nominal lookup.
2. Recognize alias-qualified functions, constructors, values, and function
   references before ordinary member resolution.
3. Keep aliased declarations out of unqualified candidate sets.
4. Propagate selected canonical handles through ownership, effects, IR, and
   reachability.
5. Add ambiguity diagnostics for compatibility unaliased imports.

### Stage 3: reflection and contract integration

1. Expose canonical module-origin reflection for functions and types.
2. Preserve source qualifier metadata on reflected typed calls.
3. Use the same alias map for structured contract projections.
4. Verify that contract-only consumption and generated adapters retain target
   identity without rendering source names.
5. Add cache and fixed-point tests across alias renames and import reordering.

## Testing plan

Add tests for:

1. qualified calls to two same-named top-level functions;
2. qualified constructors and nominal parameter/result types;
3. qualified interfaces, nullable types, arrays, and nested generic arguments;
4. qualified top-level immutable and mutable values;
5. a qualified function reference invoked indirectly;
6. inherent methods on values of an aliased type;
7. aliased extension methods not leaking into unqualified member lookup;
8. alias use as a runtime value being rejected;
9. duplicate aliases and alias/declaration collisions;
10. local shadowing following fixed lexical precedence;
11. duplicate aliased/unaliased edges to one canonical module being rejected;
12. unaliased same-name ambiguity independent of import order;
13. aliases remaining private to the importing module;
14. ordinary aliased compile actions and subparser registrations running once;
15. package, provider, vendor, relative, absolute, and offline alias imports;
16. alias names not changing canonical reflected declaration identity;
17. importer cache invalidation after an alias rename;
18. imported interface caches surviving a consumer-only alias rename;
19. import reordering preserving native symbols and deterministic output;
20. two same-named contract RPC calls selected through different aliases;
21. a qualified contract call still requiring explicit consumption;
22. generated adapters invoking the selected handle without source-name lookup;
23. diagnostics reporting alias use and canonical declaration origin; and
24. clean bootstrap and fixed-point compiler agreement.

## Acceptance criteria

This RFC is complete when:

- an importer can bind ordinary and contract modules to explicit aliases;
- aliased declarations are available only through qualified lookup;
- functions, values, constructors, types, interfaces, and function references
  resolve correctly;
- two modules may expose the same short declaration name without collision when
  imported under different aliases;
- aliases are compile-time-only, direct, and module-local;
- canonical declaration/type identities do not depend on alias spelling;
- ordinary ownership, effects, reachability, contract consumption, and
  capability checks remain intact;
- cache behavior distinguishes consumer alias changes from imported interface
  changes;
- diagnostics identify both source qualifier and canonical origin; and
- conformance and fixed-point tests pass without source-order-dependent lookup.

## Alternatives considered

### Derive an implicit alias from the filename

Rejected as the only model because filenames collide, package entry modules are
often named `entry.ab`, and moving a file would silently change source lookup.
A tool may suggest an explicit filename-derived alias.

### Keep declarations unqualified and resolve collisions by import order

Rejected because refactoring or formatting imports could change program
meaning. Ambiguity must be explicit and deterministic.

### Import under an alias but also expose every declaration unqualified

Rejected because it does not solve collision isolation and makes adding an
alias purely cosmetic.

### Treat modules as runtime objects

Rejected because modules contain types, compile-time declarations, globals,
annotations, and functions rather than one runtime object layout. It would add
allocation and dynamic lookup to a static naming feature.

### Add only selective declaration imports

Selective imports may be useful later, but they do not provide a durable
namespace for several related declarations or solve qualified contract and
type references.

### Use globally unique long declaration names in source

Rejected because package paths and revisions are implementation identity, not
an ergonomic source API. Canonical identities remain fully qualified inside
the compiler while source uses an explicit local alias.

### Re-export aliases automatically

Rejected because it makes transitive dependencies part of a module's API by
accident. Re-export must be explicit and should be designed together with
visibility and public interface policy.
