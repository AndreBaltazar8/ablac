# Compiler API

`import "abla/compiler"` gives compile-time code a view of the program being
compiled, and controlled ways to change it. It is available only at compile
time: in `compile fun`s, `#` expressions and top-level actions
([compile-time.md](compile-time.md)). This page describes API version 0.2.

Everything goes through one object, `compiler`. Declarations are named by
*handles*: opaque integers that are stable for one compilation.

## Reflection: reading the program

```abla
import "abla/io"
import "abla/compiler"

@route("/users")
fun listUsers(page: int): string = "users page $page"

@route("/orders")
fun listOrders(page: int): string = "orders page $page"

fun helper(): int = 0

compile fun routeTable(): array<string> {
    val rows: array<string> = []
    for (function in compiler.functionsAnnotated("route")) {
        val name = compiler.functionName(function)
        val first = compiler.parameterType(function, 0)
        val path = compiler.annotationArgumentText(function, 0)
        rows.append("$path $name($first) -> ${compiler.resultType(function)}")
    }
    rows
}

fun main {
    for (row in #routeTable()) println(row)
}
// output:
// /users listUsers(i64) -> string
// /orders listOrders(i64) -> string
```

`routeTable` runs inside the compiler, and the program receives its result
as a constant array. Types are reported in their canonical spelling (`int`
is `i64`), and a result type the source leaves out is reported as inferred
from the body. `compiler.annotationArgumentText(function, annotation)` gives
an annotation argument's literal text (see
[function reflection](#function-reflection)).

## Transforms: changing the program

A transform is a zero-argument `compile fun` registered with a top-level
`#compiler.transform(handler)`. It runs before final semantic analysis and
may replace function bodies and add annotations. The changed program is then
checked completely, as if it had been written that way:

```abla
import "abla/io"
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

fun main {
    println("${answer(40)}")
}
// output:
// 42
```

A transform may change any module's declarations: its own module's, another
of the program's modules', or the standard library's. A change to another
module is an *edit*, kept with the transforming module's parse (so a rebuild
that reuses that parse still makes it) and applied by the module graph to the
complete program before analysis:

- Edits apply in module order, and the modules parsed after a transform's see
  its changes.
- Two transforms that give one function different bodies fail the build with
  `E_COMPILER_EDIT_CONFLICT`, naming both; the same body twice is one change.
- An edit whose target is not exactly one declaration is
  `E_COMPILER_EDIT_TARGET`.
- Another module's [private](language.md#modules-and-imports) function is
  found by its source name and edited like any other. A new body reads names
  as the function's own module does, whoever wrote it: that module's private
  names and what it imports (under strict imports, only that), not the
  transforming module's.
- The runtime's functions (`abla/runtime`) are never changed:
  `E_COMPILER_TRANSFORM_RUNTIME`. Its guarantees, such as which code may hold an
  object's address, rest on its code as written. The call returns false and
  the build fails, never reporting a change it then drops.
- A standard-library function's body, or a standard-library extension field's
  removal, needs the [`transform.library`](compile-time.md#capabilities-files-environment-processes-network)
  capability: the project lists it in `compileCapabilities` and the
  transforming module has `#compilerGrant("transform.library")`. Without it
  the call is refused with `E_COMPILE_NATIVE_DENIED` naming
  `transform.library`. Annotations, and a program's own modules, need no
  grant. With `ABLA_COMPILE_EVAL_TRACE=1` each granted change prints a
  `note[transform]:` line naming the transform's site and the function.

## The `compiler` service at a glance

| Methods | Purpose |
|---|---|
| `functions()`, `findFunction(name)`, `functionsAnnotated(annotation)` | find function handles (`-1` when not found) |
| `functionName`, `functionIdentity`, `functionModuleIdentity`, `functionOwner`, `parameterCount`, `parameterName`, `parameterType`, `resultType`, `annotationCount`, `annotation`, `isCompileOnly`, `isTrusted`, `isExternal` | read a function's signature and metadata |
| `bindings()`, `findBinding(name)`, `bindingName`, `bindingIsMutable`, `bindingIsDelegated`, `bindingExposedType`, `bindingDelegateType`, `bindingGetter`, `bindingSetter`, `bindingCanReplaceDelegate`, `bindingByBegin`, `bindingByEnd` | read top-level bindings ([below](#binding-reflection)) |
| `transform(handler)` | register a transform (only as a literal top-level action) |
| `replaceFunctionBody(function, source)`, `addFunctionAnnotation(function, name)` | change the program, from a transform or a `#expression` ([committing changes](compile-time.md#committing-program-changes)) |
| `extensionFields(type)`, `fieldsOf(type, includeExtensions)`, `addExtensionField(type, name, fieldType, initial, mutable)`, `removeExtensionField(type, name)` | a class's [extension fields](#extension-fields) |
| `conformances(type)`, `conformsTo(type, interface)`, `implementers(interface)`, `witness(type, interface)`, `declareInterface(name, members, parents)`, `addConformance(type, interface, members)` | [interfaces](#interfaces) and the classes conforming to them |
| `findType(name)`, `typeName(type)`, `classOf(type)`, `typeConformsTo(type, interface)`, `isResource(type)`, `typeArguments(type)` | type handles, as a [generic](#generics)'s `#` code sees its type parameters |
| `instantiations(generic)`, `instantiate(generic, typeArguments)`, `functionTypeArguments(function)` | a [generic](#generics)'s instances |
| `fieldIsDelegated(type, name)`, `fieldDelegateType(type, name)` | whether a class's property is [delegated](language.md#delegated-class-properties), and its delegate's type |
| `function(name)`, `reference(handle)` | a `FunctionReference`, for building other programs |
| `newModule(name)` | an `IndependentModule`: a separate program built from chosen functions ([below](#independent-modules-and-declaration-blocks)) |
| `buildProgram(...)`, `defineTarget(...)`, `contributeArtifactRoot(...)` | [programmable builds](programmable-builds.md) |
| `exportFunction`, `exportCheckedFunction`, `internalFunction`, `requiredInternalFunction` | [foreign exports](#programmable-build-nodes) |
| `writeFile(path, contents)` | stage an output file (needs `filesystem.write`) |

The lower-level `compiler*` functions (`compilerFindFunction`, ...) are the
versioned ABI underneath; the standard library uses them, and new code should
prefer the `compiler` methods. Typed inspection of expressions, used by
subparser finalizers, is in `abla/compiler/parser` ([below](#typed-dependency-and-mutation-reflection)
and [subparsers.md](subparsers.md)).

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
and `compiler.annotation`. An annotation's argument (`@route("/users")` has
one, a bare `@marker` none) is reflected by
`compiler.annotationArgumentCount(function, annotation)`, its syntax kind and
literal text by `compiler.annotationArgumentKind` and
`compiler.annotationArgumentText`, and the whole argument as a syntax handle by
`compiler.annotationArgument` (from `abla/compiler/parser`).

`#compiler.transform(handler)` opens the bounded mutation stage before final
semantic analysis. `compiler.replaceFunctionBody(handle, source)` currently
accepts one unique top-level runtime function and either an expression or block
body. The compiler parses the body as exactly one synthetic function, preserves
the original declaration identity/signature/annotations, and then runs ordinary
typing, ownership, trust, effect, IR, and target verification over the complete
candidate. A failure publishes no artifact. The service object itself is a
`compile val`; referring to it from runtime code is a phase diagnostic and it
creates no runtime global.

## Class and type reflection

Classes and types have handles too. `compilerFindClass(name)` returns a
class handle, and type handles come from `compilerFindType(spelling)`,
`compilerFunctionParameterTypeHandle`, `compilerFunctionResultTypeHandle` and
`compilerClassFieldTypeHandle`:

```abla
import "abla/io"
import "abla/compiler"

class Order(val id: int, var items: array<string>, val note: string?)

fun total(order: Order, discounts: array<int>): int = 0

compile fun describeOrder(): array<string> {
    val rows: array<string> = []
    val order = compilerFindClass("Order")
    for (i in 0 until compilerClassFieldCount(order)) {
        val mutability = if (compilerClassFieldIsMutable(order, i)) "var" else "val"
        rows.append("$mutability ${compilerClassFieldName(order, i)}: ${compilerClassFieldType(order, i)}")
    }
    val type = compilerFunctionParameterTypeHandle(compiler.findFunction("total"), 1)
    rows.append("${compilerTypeName(type)}: kind ${compilerTypeKind(type)}, element ${compilerTypeName(compilerTypeElement(type))}")
    rows.append("string? is nullable: ${compilerTypeIsNullable(compilerFindType("string?"))}")
    rows
}

fun main {
    for (row in #describeOrder()) println(row)
}
// output:
// val id: i64
// var items: array:string
// val note: nullable:string
// array:i64: kind array, element i64
// string? is nullable: true
```

| Function | Result |
|---|---|
| `compilerFindClass(name)` | a class handle, or `-1` |
| `compilerClassFieldCount`, `compilerClassFieldName`, `compilerClassFieldType`, `compilerClassFieldIsMutable`, `compilerClassFieldTypeHandle` | the constructor properties, in order |
| `compilerClassFieldIsDelegated`, `compilerClassFieldDelegateType` | whether a constructor property is [delegated](language.md#delegated-class-properties), and its delegate's type (`compilerClassFieldType` is the type it reads as) |
| `compilerFindType(spelling)` | a type handle |
| `compilerTypeName`, `compilerTypeKind` | the canonical spelling (`array:i64`, `nullable:string`) and its kind: `primitive`, `nominal` (classes and named types), `nullable`, `array`, `shared`, `weak`, `mutex`, `borrow`, `function`, `function.mutable`, `function.once` or `pointer` |
| `compilerTypeIsNullable`, `compilerTypeIsAffine` | flags |
| `compilerTypeArgumentCount`, `compilerTypeArgument`, `compilerTypeElement`, `compilerTypeResult` | the parts of generic, array and function types |
| `compilerTypeDeclaration(type)` | the class handle of a class type, or `-1` |
| `compilerFunctionGenericSubstitutionCount/Name/TypeHandle` | an instance of a generic function (or a method of a generic class's instance): its type parameters' names and type arguments; zero for any other function |

## Independent modules and declaration blocks

`compiler.function(name)` turns a resolved function declaration into a
`FunctionReference`. Unlike a bare integer handle, the wrapper can carry
immutable destination metadata with `.annotated(name)`. The annotation is not
added to the source declaration; it is applied and revalidated only while the
destination program is compiled.

`compiler.newModule(name)` creates an independent program builder. `use`
accepts only one unique, top-level runtime function reference and records its
origin module. `declare { ... }` accepts a compile-time-only declaration block,
not a closure or a string. The parser validates all declarations when the quote
is created, retains their exact syntax and source provenance, and the child
compilation parses, resolves, types, ownership-checks, optimizes, and verifies
the complete destination again. Normal reachability optimization retains the
selected functions' transitive globals, types, and callees in the final
artifact while removing unreachable source declarations.

```abla
import "abla/compiler"

val offset = 2
fun existing(): int = 40 + offset

compile fun buildTool(): void {
    val tool = compiler.newModule("answer-tool")
    tool.use(compiler.function("existing").annotated("copied"))
    tool.declare {
        fun main: int = existing()
    }
    tool.emit("build/answer-tool")
    return
}

#buildTool()

fun main: int = 0
```

A reference may also carry foreign export metadata. The source declaration
keeps its Abla name; `.exported(name)` names only the destination module's
bounded foreign symbol. `compiler.reference(handle)` preserves a handle from
annotation or typed-expression reflection without resolving it again by name:

```abla fragment
val client = compiler.newModule("client")
val functions = compiler.functionsAnnotated("client")
val action = compiler.reference(functions[0]).annotated("browser-copy")
client.use(action.exported("app_client_action"))
client.emit("build/client.wasm", "wasm32-module", "module")
```

An exported function is a sufficient root, so a function-only module does not
need a synthetic `main`. Duplicate or invalid export names fail during module
construction. `.checkedExported(name)` requests the same contained boundary as
`compiler.exportCheckedFunction` and remains conditional on target support.

Extensions importing `abla/compiler/parser` may attach a compiler-owned
`GeneratedModuleBuilder` through `declareGenerated`. The builder stays opaque;
the compiler publishes its declarations into the standalone child without the
extension rendering or writing an entry source. The name returned by
`compilerGeneratedFunction` can then be selected with
`module.export(sourceName, foreignName)`. Ordinary quoted declarations continue
to use `declare { ... }`.

The emitted program is a normal standalone build node, not a child runtime or
a link back to the parent executable. `emit` defaults to the current host,
`executable`, optimized mode, and cache reuse where its compile actions permit
it; named/default arguments can override any of those choices. Module names,
outputs, declaration counts,
annotation names, source identities, and recursively emitted programs are
bounded. Invalid/stale references, duplicate annotations, runtime declaration
blocks, repeated emission, and graph conflicts have stable diagnostics and
publish no partial artifact. Independent-module construction calls inherited
from source modules become bounded no-ops in the child, preventing recursive
self-emission, while actions explicitly declared in its own declaration block
still execute.

Top-level compile expressions are executable actions. A value binding is not
required merely to retain the result, so `#buildTool()` intentionally evaluates
and drops the returned value after its compile-time effects are staged.

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

## Extension fields

A class's extension fields ([language.md](language.md#extension-fields)) are
listed by handle (`compiler.findClass(name)`): `compiler.extensionFields(type)`
returns their names in declaration order, and `compiler.fieldsOf(type)` returns
the declared fields and then the extension fields (`includeExtensions = false`
for the declared ones only). From a transform, `compiler.addExtensionField`
declares one as if the program did, with the default given as source.
`compiler.removeExtensionField` removes one, the transform's own module's or
another module's (an edit, as for [transforms](#transforms-changing-the-program)):

```abla
import "abla/io"
import "abla/compiler"

class Enemy(val level: int)

var Enemy.unused: int = 0

compile fun fields(): void {
    val enemy = compiler.findClass("Enemy")
    compiler.addExtensionField(enemy, "maxHp", "int", "this.level * 10")
    compiler.removeExtensionField(enemy, "unused")
    return
}

#compiler.transform(fields)

fun main {
    println("${Enemy(3).maxHp}")
}
// output:
// 30
```

`compilerExtensionFieldCount`, `compilerExtensionFieldName`,
`compilerExtensionFieldType` and `compilerExtensionFieldIsMutable` are the
versioned ABI underneath.

## Private declarations

`compiler.isPrivate(handle)` says whether a class or function handle names a
`private` declaration ([modules](language.md#modules-and-imports)).
`compiler.findClass(name)` and `findFunction(name)` take the name as the
source writes it. For a private declaration (or one in a module imported
under an alias), they find the calling module's own, or else the only one in
the program. Reflection (`functions()`, `functionsAnnotated`) lists every
declaration, private ones included.

## Interfaces

[Interfaces](language.md#interfaces) and conformances can be read and declared
as the syntax does. A class is a handle (`compiler.findClass(name)`), and an
interface is its name:

- `compiler.conformances(type)` lists the interfaces the class conforms to: the
  ones it declares, then the ones `extend` adds, then the ones those extend.
- `compiler.conformsTo(type, interface)` checks one interface.
- `compiler.implementers(interface)` lists the classes conforming to an
  interface, in declaration order.
- `compiler.witness(type, interface)` says what answers each member for the
  class, as `member:kind`. The kind is `method` (the class's own), `extension`
  (an extension function), `default` (the interface's body) or `missing`.

From a transform:

- `compiler.declareInterface(name, members, parents)` declares an interface
  (extending `parents`, if any). Each member is given as source
  (`fun area(): f64`, or with a default body).
- `compiler.addConformance(type, interface, members)` is the programmatic
  `extend`. It makes the class conform, and adds each member's source as an
  extension function of the class. A member's source is written like a
  method, starting with `fun`, and `this` is the instance.

Like any program change, these take effect when the transforms have run,
before analysis. So a derive written in Abla reads `fieldsOf` and adds a
conformance with members it generates:

```abla
import "abla/io"
import "abla/compiler"

interface Describe {
    fun describe(): string
}

class Point(val x: int, val y: int)

compile fun derive(): void {
    val point = compiler.findClass("Point")
    var parts = ""
    for (field in compiler.fieldsOf(point)) {
        parts = if (parts == "") "$field=\${this.$field}"
            else "$parts, $field=\${this.$field}"
    }
    compiler.addConformance(point, "Describe", ["fun describe(): string = \"Point($parts)\""])
    return
}

#compiler.transform(derive)

fun main {
    val described: Describe = Point(1, 2)
    println(described.describe())
}
// output:
// Point(x=1, y=2)
```

`compilerConformanceCount`, `compilerConformanceName`,
`compilerImplementerCount`, `compilerImplementerName`, `compilerWitnessCount`,
`compilerWitnessEntry`, `compilerDeclareInterface` and `compilerAddConformance`
are the versioned ABI underneath. A request outside a transform, or without a
class handle and an interface name, is `E_COMPILER_TRANSFORM_INTERFACE`.

## Generics

`#` code in a [generic](language.md#generics)'s body runs once per
instance, and names a type parameter `T` as its type argument's type
handle (the handle `compiler.findType` returns). Type handles have their
own queries:

- `compiler.findType(name)` is the handle of a type as spelled
  (`int`, `array<string>`, `Square`), and `compiler.typeName(type)` its
  spelling (`i64`, `Box<i64>` for an instance of a generic class).
- `compiler.classOf(type)` is its class's handle (for `fieldsOf`,
  `conformances`, `witness`), or `-1` when it is no class.
- `compiler.typeConformsTo(type, interface)` says whether it is a class
  conforming to the interface (as `conformsTo` answers for its class), or is
  that interface.
- `compiler.isResource(type)` says whether it is a resource; an instance of
  a generic class is one when it holds one.

An `if` whose condition is a `#` query of `typeConformsTo` or `isResource`
on type parameters is decided per instance before the instance is checked,
and keeps only the branch it takes
([language guide](language.md#compile-time-code-per-instance)).

The instances themselves can be read and asked for:

- `compiler.instantiations(generic)` lists the instances of the generic
  class or function `generic` that the program has, as written
  (`Box<i64>`), in the order they were made (those a transform asked for
  first). `findType`, `findClass` and `findFunction` take that
  spelling (`findFunction("first<Square>")`, `findFunction("Box<string>.get")`).
- `compiler.typeArguments(type)` are the type arguments of a generic class's
  instance as type handles (an array's or a nullable's element too), and
  `compiler.functionTypeArguments(function)` those of a generic function's
  instance, or of a method of a generic class's instance.
- `compiler.instantiate(generic, typeArguments)` is the instance for those
  type arguments, as written (`instantiate("Box", ["int"])` is `Box<i64>`).
  An instance the program doesn't use yet is made as if the program used
  it, its bounds checked as a use's would be: from a transform, with the
  program's other instances; from other `#` code, for the next round of
  lowering ([committing program changes](compile-time.md#committing-program-changes)),
  so the round that asked doesn't see it yet and the next one does. A site
  that asks for a new instance in every round stops after 8 with
  `compile.edit-fixpoint`, which lists the instances the last round asked
  for and the sites that asked. Something that is no generic, or the wrong
  number of type arguments, is `E_COMPILER_GENERIC_INSTANTIATE`.

```abla
import "abla/io"
import "abla/compiler"

class Box<T>(val value: T)

compile fun ask(): void {
    compiler.instantiate("Box", ["string"])
    return
}

#compiler.transform(ask)

compile fun boxes(): string {
    var text = ""
    for (name in compiler.instantiations("Box")) {
        val arguments = compiler.typeArguments(compiler.findType(name))
        text = "$text $name of ${compiler.typeName(arguments[0])};"
    }
    text
}

fun main {
    println("${Box(1).value}${#boxes()}")
}
// output:
// 1 Box<string> of string; Box<i64> of i64;
```

## Binding reflection

Top-level values use stable declaration handles through `compiler.bindings()`
and `compiler.findBinding(name)`. The binding surface reports its source name,
mutability, and storage form. For delegated bindings it additionally reports
the exposed type, delegate type, selected getter and optional setter function
handles, whether delegate replacement is allowed, and the source offsets of
the `by` initializer:

```abla
import "abla/io"
import "abla/compiler"

class Clamped(var current: int, val minimum: int, val maximum: int) {
    fun getValue(): int = current
    fun setValue(next: int): void {
        current = if (next < minimum) minimum else if (next > maximum) maximum else next
        return
    }
}

var volume: int by Clamped(40, 0, 100)

compile fun describeVolume(): string {
    val binding = compiler.findBinding("volume")
    if (!compiler.bindingIsDelegated(binding)) return "volume is not delegated"
    val valueType = compiler.bindingExposedType(binding)
    val policyType = compiler.bindingDelegateType(binding)
    val getter = compiler.functionName(compiler.bindingGetter(binding))
    val setter = compiler.functionName(compiler.bindingSetter(binding))
    "volume: $valueType by $policyType ($getter/$setter)"
}

fun main {
    println(#describeVolume())
}
// output:
// volume: i64 by Clamped (getValue/setValue)
```

Types are reported by their canonical spelling, so `int` reads as `i64`.

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
successful graph commits. The journal accepts at most 4096 distinct paths and
reports transaction and rollback failures with stable build diagnostic codes.

`@export("name")` is the source-level form for marking one resolved top-level
function for a stable foreign adapter. `@exportChecked("name")` selects the
contained variant. They perform the same validation and emit the same ABI
manifest as `compilerExportFunction(handle, name)` and
`compilerExportCheckedFunction(handle, name)`; those functions remain available
for compiler extensions that select exports dynamically.
`@export(["primary", "compatibility"])` publishes multiple native names for
one source implementation; naked assembly definitions use LLVM aliases so the
body is emitted once. The ABI rung accepts
up to 16 value `bool`, `char`, `f32`, `f64`, signed or unsigned
8/16/32/64-bit integer,
borrowed `string`, or direct non-escaping `(i64) -> i64` callback parameters
and a `void`, supported scalar, or owned `string` result. Runtime globals are
initialized exactly once before the first exported call and retain their state
between calls. Direct exports add no locking; a foreign caller that invokes
state-mutating exports concurrently must provide synchronization. A foreign
string lowers to `(pointer, u64)`;
the adapter validates it and copies its exact bytes into tracked Abla-owned
storage before invoking user code. Empty input permits a null pointer. A
callback lowers to a C function pointer plus context pointer and is
synchronously borrowed for the exported call. It may be called directly but
not stored, returned, captured, or forwarded; export validation rejects a
source use that could escape that lifetime. The callback must return normally.
The backend emits only the requested C symbol; internal Abla function symbols
stay hidden. Hosted executables with exports publish only those requested
symbols and required owned-result helpers through the process dynamic-symbol
table, so a native API may retain an
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
