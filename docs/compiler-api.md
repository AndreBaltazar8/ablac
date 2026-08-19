# Compiler API

Status: bootstrap API, version 0.2. The module is imported with
`import "abla/compiler"` and is available only to compile-time code.

The public surface is the compile-time-only `compiler: Compiler` service:

```abla
import "abla/compiler"
@client
fun answer(value: int): int = value + 1

compile fun configure(): void {
    val function = compiler.findFunction("answer")
    if (compiler.annotation(function, 0) == "client") {
        compiler.replaceFunctionBody(function, "value + 2")
    }
    return
}

#compiler.transform(configure)
```

Its methods group reflection, validated transforms, files, targets, child
programs, artifact roots, and foreign exports behind one coherent object. The
standalone `compiler...` externs remain the versioned bootstrap ABI used by the
standard library; new extension code should prefer the service object.

## Function reflection

The low-level reflection ABI includes:

```abla
compile extern:"compiler" fun compilerFunctions(): array<int>
compile extern:"compiler" fun compilerFindFunction(name: string): int
compile extern:"compiler" fun compilerFunctionName(handle: int): string
compile extern:"compiler" fun compilerFunctionCanonicalIdentity(handle: int): string
compile extern:"compiler" fun compilerFunctionModuleIdentity(handle: int): string
compile extern:"compiler" fun compilerFunctionParameterCount(handle: int): int
compile extern:"compiler" fun compilerFunctionParameterType(handle: int, parameter: int): string
compile extern:"compiler" fun compilerFunctionResultType(handle: int): string
compile extern:"compiler" fun compilerTypeModuleIdentity(handle: int): string
compile extern:"compiler" fun compilerFunctionIsCompileOnly(handle: int): bool
compile extern:"compiler" fun compilerFunctionIsTrusted(handle: int): bool
compile extern:"compiler" fun compilerFunctionIsExternal(handle: int): bool
```

A handle is an opaque integer that is stable for the duration of one
compilation. `compilerFindFunction` returns `-1` when no declaration matches;
passing that value to an accessor is a compile-time diagnostic. Overload-aware
lookup will use signature queries rather than changing this function's meaning.

Compiler API declarations are excluded from enumeration. The returned function
order follows deterministic semantic declaration order. Type names use the
canonical compiler spelling (`int` currently reports as `i64`).
`compilerFunctionName` and reflected type spellings remain source-facing short
names. Canonical identity and the explicit module-origin queries distinguish
same-named declarations imported under aliases; neither result depends on the
consumer's alias spelling.

The VM reads owned IR metadata for handles and never exposes AST, semantic, C++,
or backend pointers. Marker annotations are retained with source spans, included
in interface/IR fingerprints, and exposed through `compiler.annotationCount`
and `compiler.annotation`.

`#compiler.transform(handler)` opens the bounded mutation stage before final
semantic analysis. `compiler.replaceFunctionBody(handle, source)` currently
accepts one unique top-level runtime function and either an expression or block
body. The compiler parses the body as exactly one synthetic function, preserves
the original declaration identity/signature/annotations, and then runs ordinary
typing, ownership, trust, effect, IR, and target verification over the complete
candidate. A failure publishes no artifact. The service object itself is a
`compile val`; referring to it from runtime code is a phase diagnostic and it
creates no runtime global.

Function handles now cover top-level, extension, and inherent methods. They
expose canonical owner/name identity, source parameter names, normalized
parameter/result types, phase/trust/native flags, and class-field metadata.
Typed syntax inspection resolves direct and receiver-bearing calls, including
receiver/argument types from enclosing function parameters and preceding local
declarations. `syntaxCallTarget` and `syntaxMethodCallTarget` retain the selected
handle as compiler-owned provenance, so an extension does not reconstruct its
call target by name; using an inherent method without its receiver is rejected
before syntax publication. Structured type handles intern canonical nullable,
array, sharing/borrow, pointer, function, nominal, and affine/resource types;
they expose elements, function parameters/results, and nominal declarations
without semantic pointers. Selected calls additionally expose result/parameter
type handles, argument-to-parameter mapping, inserted-default count,
parameter ownership, inserted conversion descriptions, and phase/trust flags.
Only deferred request expressions retain these compact post-resolution records;
raw parser handlers cannot query typed state. The stable generic-substitution
surface returns zero until generic declarations land.

## Binding reflection

Top-level values use stable declaration handles through `compiler.bindings()`
and `compiler.findBinding(name)`. The binding surface reports its source name,
mutability, and storage form. For delegated bindings it additionally reports
the exposed type, delegate type, selected getter and optional setter function
handles, whether delegate replacement is allowed, and the source offsets of
the `by` initializer:

```abla
val binding = compiler.findBinding("volume")
if (compiler.bindingIsDelegated(binding)) {
    val valueType = compiler.bindingExposedType(binding)
    val policyType = compiler.bindingDelegateType(binding)
    val getter = compiler.bindingGetter(binding)
}
```

The low-level ABI uses `compilerBindings`, `compilerFindBinding`, and the
`compilerBinding...` accessors declared by `abla/compiler`. Getter and setter
results are ordinary function-reflection handles; a missing accessor is `-1`.
An ordinary binding reports `false` for delegation and replacement, `unknown`
for its delegate type, and `-1` for accessor handles and `by` offsets. Handles
describe compilation-owned metadata and never expose a live runtime value or
delegate object.

## Typed dependency and mutation reflection

Deferred expressions and function handles expose bounded, compiler-owned
read/write summaries through `abla/compiler/parser`. An opaque
`TypedAccessPath` has a semantic root (`parameter`, `receiver`, `local`, or
`global`) followed by field, constant-index, dynamic-index, `cell`, `delegate`,
or wildcard segments. Root parameters use declaration-order indexes; global
identities are module-qualified. Queries never return a backend pointer or a
live application value.

`typedExpressionReadCount`/`typedExpressionRead` and their write and consume
counterparts inspect any resolved deferred expression, not only a direct call.
`typedFunctionRead...` and `typedFunctionWrite...` report declaration summaries
relative to parameters, receivers, and globals. Direct and member calls
substitute callee parameter paths with the caller's resolved argument path.
Aliases, constant and dynamic indexes, `Cell.get`/`Cell.set`, delegated
getter/setter bodies, receiver-field shorthand, globals, and imported helper
functions retain structured paths. Recursive, indirect, contract-only, or
otherwise unavailable bodies widen conservatively through the `ReadsUnknown`
and `WritesUnknown` flags.

Path query operations expose the root identity and ordered segments.
`typedAccessPathsIntersect(left, right)` implements the prefix-aware
invalidation relation: a write to a prefix intersects every dependency below
it, dynamic/wildcard projections are conservative, and disjoint fields or
constant indexes remain distinct. Ordering and the 64-path/8-segment bounds
are deterministic. Exceeding a bound widens to unknown or wildcard metadata
instead of silently omitting an access.

`typedExpressionHasEffect` and `typedFunctionHasEffect` expose the ordinary
transitive capability summary using the stable effect names
`filesystem.read`, `filesystem.write`, `environment`, `process.io`, `network`,
`clock`, `random`, and `trusted.native`. A framework can therefore require a
binding evaluator to be read-only and capability-free while permitting a
handler's declared state writes.

`compilerGeneratedLiftedFunction` consumes a recorded expression and parallel
capture-name, generated-parameter, type, and mutable-mode arrays. It rewrites
free references to explicit parameters while respecting nested local/lambda
bindings. Unlisted free variables, borrowed or affine captures, and writes
through a capture not declared mutable fail transactionally with stable
reactive diagnostics. The resulting declaration is still parsed, typed,
ownership-checked, effect-checked, lowered, and target-verified with its
generated namespace and originating expression span.

Initial-phase subparsers can construct an ordinary context-typed closure with
`syntaxInferredLambda(parameterNames, body, moving)`. Its parameters carry the
same `unknown` type syntax as unannotated source-lambda parameters; the
surrounding callable use must infer them during normal semantic analysis.
`syntaxLambda` remains the explicit reflected-type-handle form for phases where
those handles are available. Both forms pass through the same capture-family,
ownership, effect, semantic, and IR validation.

Deferred call inspection also exposes
`typedCallIsContract(expression)`. It reports whether the selected declaration
came from an `import contract` projection while `typedCallTarget` and all
signature, annotation, default, conversion, type-handle, canonical-identity,
and module-origin queries continue to work normally. Contract calls are
metadata-only: the finalizer must return syntax that no longer contains the
call, or final semantic validation emits `E_CONTRACT_CALL_NOT_CONSUMED` before
IR construction.

## Effects and generated modules

`compilerGrant(capability)` requests a staged ambient effect. The entry
module's sibling `abla.toml` must also list it in `compileCapabilities`; source
cannot forge the compiler's internal authorization marker. The request is
source- and manifest-fingerprinted. Read-only filesystem staging journals each
observed path and a dual content identity, which is revalidated before object
cache reuse. `compilerEnvironment(name)` similarly reads one named environment
input after an `environment` grant; cache sidecars retain only its size and
content fingerprints. Subparser and finalizer transactions merge their
journals into the lowered program, and persistent frontend snapshots
revalidate them before reusing a staged parse. Because parser staging precedes
full semantic analysis, the source request and manifest authorization are
intersected before invoking a handler/finalizer; denial cannot perform the
effect. Other ambient grants remain uncached.

`compilerClockMilliseconds()`, `compilerRandomInteger(maxExclusive)`, and
`compilerRunProcess(arguments)` are bounded ambient providers for tooling that
deliberately opts out of hermetic caching. They require `clock`, `random`, and
`process.io` respectively; process argument count and size are evaluator
bounded, while the compiler watchdog bounds time and memory.

`compilerGenerateModule(namespace, source)` submits a bounded deterministic
virtual module. Generated declarations are parsed and validated together with
the complete candidate; failure publishes nothing. Subparsers can instead call
`compilerRecordExtensionRequest(namespace, payload, expression, finalizer)`.
The Abla finalizer receives the immutable syntax handle and returns the virtual
module source. It may construct that result through an owned
`GeneratedModuleBuilder`: function/value builders consume compiler-owned syntax
and structured type handles, assign deterministic collision-checked internal
identities, and require an explicit checked operation for a source-visible
export. Rendering remains a compatibility path. Direct finalizers publish the
owned AST through the same resolve/type-check transaction, so failure publishes
nothing. References to builder-owned declarations carry an opaque compiler-only
hygiene marker that parsed source and ordinary syntax builders cannot forge.

Direct deferred calls additionally expose `typedExpressionType`,
`typedCallTarget`, and `typedCallArgumentType`. The target is the same stable
declaration handle used by function reflection; ambiguous/non-call targets are
diagnostics. This first typed-expression rung covers direct named calls and
literal, lexical-local, and receiver-bearing arguments. Inserted conversions
and complete post-resolution node maps remain.

`parserSourceIdentity(cursor)` returns the canonical identity of the module
owned by the active parser cursor. Providers should include it with the source
span when constructing request namespaces, because byte offsets are local to a
module and can be identical in separate imports.

## Programmable build nodes

`compilerBuildProgram(name, entry, output, target, artifact, fast, cache)`
registers a bounded program node during compile-time execution. The compiler
driver validates and drains the resulting graph in deterministic declaration
order; requested programs may themselves register more nodes. Paths are
project-relative, names and outputs are unique, one evaluation may register at
most 32 nodes, and the recursively expanded graph is capped at 64 nodes.

This is a general compiler-service primitive. Android, WASM, MVC, UI, RPC, and
packaging policy belong to libraries that construct nodes and emit sidecars,
not to the frontend. The hosted Linux toolchain supports executable, object,
static-library, and shared-library artifacts. Extension-defined WebAssembly
targets additionally use the generic `module` artifact; stable exported
adapters remain separate from those containers. See
`docs/programmable-builds.md` for the ABI, target-description, and
transactional build-graph roadmap.

`compiler.contributeArtifactRoot(name, target, artifact, output, function,
exportName, fast, cache)` adds an exact resolved top-level scalar root to a
named child artifact. Contributions with identical artifact configuration are
aggregated into one generated entry and one child compilation. The bounded rung
accepts value `bool`/`int` parameters and `void`/`bool`/`int` results, requires
an unambiguous top-level identity, and publishes only the requested explicit
foreign symbols. Each child is independently optimized, target-lowered,
verified, linked, manifested, and committed in the parent build transaction.
For libc-free Wasm, uncontained panic paths lower to target-neutral
`unreachable`; the ABI manifest records `panic: not-contained`.

`compilerDefineTarget(name, llvmTriple, objectFormat, linkerFlavor,
linkerEmulation, hosted, libcFree)` registers an extension-owned target for the
same graph. Values are bounded identifier-like tokens. The current generic
implementation accepts ELF with the host Clang driver for hosted x86-64 aliases
or direct LLD for non-hosted, libc-backed targets. The latter may emit object,
static-library, and shared-library artifacts but require extension-provided
runtime/startup support before libc-free targets or executables. Descriptors
are graph-scoped, deterministic, duplicate-checked, and included in cache
identities. A non-hosted libc-free WebAssembly descriptor may emit an object,
archive, or no-entry module through `wasm-ld`. Platform packages such as
`abla/android/build` and `abla/wasm/build` own concrete triples and integration
policy.

The root and recursively registered program nodes share one bounded output
transaction. Artifacts, generated source, and compiler-owned sidecars journal
their prior filesystem entry before replacement. If any later node fails, old
files are restored and newly created paths are removed; only a completely
successful graph commits. The journal accepts at most 512 distinct paths and
reports transaction and rollback failures with stable build diagnostic codes.

`@export("name")` is the source-level form for marking one resolved top-level
function for a stable foreign adapter. `@exportChecked("name")` selects the
contained variant. They perform the same validation and emit the same ABI
manifest as `compilerExportFunction(handle, name)` and
`compilerExportCheckedFunction(handle, name)`; those functions remain available
for compiler extensions that select exports dynamically. The ABI rung accepts
up to 16 value `bool`, `char`, signed or unsigned 8/16/32/64-bit integer,
borrowed `string`, or direct non-escaping `(i64) -> i64` callback parameters
and a `void`, supported scalar, or owned `string` result in programs without
runtime globals. A foreign string lowers to
`(pointer, u64)`;
the adapter validates it and copies its exact bytes into tracked Abla-owned
storage before invoking user code. Empty input permits a null pointer. A
callback lowers to a C function pointer plus context pointer and is
synchronously borrowed for the exported call. It may be called directly but
not stored, returned, captured, or forwarded; export validation rejects a
source use that could escape that lifetime. The callback must return normally.
The backend emits only the requested C symbol; internal Abla function symbols
stay hidden. Hosted executables with exports publish those requested symbols
through the process dynamic-symbol table, so a native API may retain an
Abla-authored callback without a foreign-language trampoline. A string result
becomes a non-null opaque owned-bytes handle with
generated data/length accessors and an exactly-once release operation. This
first handle runtime requires a libc-backed target; libc-free targets reject it
with `E_EXPORT_TARGET_CAPABILITY` until their extension supplies a compatible
allocator contract. Unsupported signatures fail with
`E_EXPORT_SIGNATURE_UNSUPPORTED` rather than exposing the internal
`%AblaValue` representation. Successful
artifacts receive a staged `.abi.json` sidecar describing the target,
container, exported symbol, lowered representation, ownership/transfer action,
nullability, and the current uncontained-panic contract. Cached objects retain
and restore the same manifest.

`compilerExportCheckedFunction(handle, name)` requests the contained variant.
On the currently supported hosted x86-64 Linux target, its C adapter returns an
`i32` status, writes the ordinary result through an out-pointer, and copies a
panic message into caller-provided bounded byte storage while returning the
full required length. Status values are `0` for success, `1` for panic, and `2`
for invalid output arguments. A caught panic restores the nested recovery and
GC-root frames, allowing later calls in the same process. Recovery is abortive:
resource cleanup is not run and prior external side effects are not rolled
back. The ABI manifest records all of these properties. Targets without the
checked-panic capability fail with `E_EXPORT_TARGET_CAPABILITY`.
