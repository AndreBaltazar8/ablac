# Compiler API

Status: bootstrap API, version 0.1. The module is imported with
`#import("abla/compiler")` and is available only to compile-time code.

## Function reflection

The initial API is read-only:

```abla
compile extern:"compiler" fun compilerFunctions(): array<int>
compile extern:"compiler" fun compilerFindFunction(name: string): int
compile extern:"compiler" fun compilerFunctionName(handle: int): string
compile extern:"compiler" fun compilerFunctionParameterCount(handle: int): int
compile extern:"compiler" fun compilerFunctionParameterType(handle: int, parameter: int): string
compile extern:"compiler" fun compilerFunctionResultType(handle: int): string
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

The VM reads owned IR metadata for handles and never exposes AST, semantic, C++,
or backend pointers. Future mutation APIs will operate on explicit edit
transactions, re-run resolution/type checking, and commit only after validation.

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

`compilerExportFunction(handle, name)` marks one resolved top-level function
for a stable foreign adapter. The ABI rung accepts up to 16 value `bool`/`i64`,
borrowed `string`, or direct non-escaping `(i64) -> i64` callback parameters
and a `void`, `bool`, `i64`, or owned `string` result in programs without
runtime globals. A foreign string lowers to
`(pointer, u64)`;
the adapter validates it and copies its exact bytes into tracked Abla-owned
storage before invoking user code. Empty input permits a null pointer. A
callback lowers to a C function pointer plus context pointer and is
synchronously borrowed for the exported call. It may be called directly but
not stored, returned, captured, or forwarded; export validation rejects a
source use that could escape that lifetime. The callback must return normally.
The backend emits only the requested C symbol; internal Abla function symbols
stay hidden. A string result becomes a non-null opaque owned-bytes handle with
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
