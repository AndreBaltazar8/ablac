# Abla language contract

Status: bootstrap specification, version 0.1.

This document distinguishes deliberate language behavior from limitations of
the original prototype. Changes require a language test and an update here.

## Design rules

1. Compile time and runtime use the same language and library model.
2. Compile-time effects are explicit at the call site with `#`.
3. Source is expression-oriented and semicolons are optional.
4. Diagnostics identify a source span and explain the expected construct.
5. The compiler output and module graph are deterministic.
6. Native access is capability-based and isolated in declared modules.
7. Compiler reflection uses stable handles rather than mutable implementation
   objects.

## Lexical structure

Source is UTF-8. The bootstrap accepts ASCII letters and `_` in identifiers;
Unicode identifier classes are reserved for a later version. Spaces, tabs, and
comments separate tokens. Newlines are significant only where they can
terminate a statement or where the grammar forbids a line break.

Line comments begin with `//`. Block comments use `/* ... */` and may nest.

Integer literals are decimal or hexadecimal (`0x2a`) and may contain `_`
between digits. Floating literals are decimal, default to `f64`, and require a
fractional digit or a valid decimal exponent (`1.5`, `2e3`, `1.25e-2`); `_` may
separate their digits. Floating literals and arithmetic are currently runtime
only, operands must have the same width, and `abla/float` provides the explicit
signed `int` to `f64` numerical conversion `f64FromInt`. Explicit `f32`
conversion remains forthcoming. Strings use `"..."` and support the escapes
`\t`, `\b`, `\r`, `\n`, `\'`, `\"`, `\\`, `\$`, byte-preserving `\xNN`, and
ASCII `\uXXXX`. `$name` and `${expression}` are string interpolation. A
template made only of literal text and module `val`s that hold such strings is
one compile-time constant, so composing text from named pieces costs nothing.

The compiler accepts `;` as an explicit separator, but never requires it.

## Declarations

The compatible declaration forms are:

```abla fragment
val immutable = 1
var mutable: int = 2

fun inferred(a: int) = a + 1
fun block(a: int): int {
    a + 1
}

extern:"c" fun puts(text: cstring): int
compile fun generate() { ... }

class Point(val x: int, val y: int) {
    fun sum() = x + y
}

interface Printable {
    fun print()
}
```

The last expression in a block is its value. A function with no declared
return type is inferred. An empty block has type `void`. `val` may be assigned
exactly once; `var` may be reassigned.

A typed local `var` may defer its first assignment:

```abla fragment
var answer: int
if (ready) answer = 42 else answer = fallback()
use(answer)
```

The verified control-flow graph requires every path to assign the binding
before a read. An untyped deferred declaration and a deferred `val` are
rejected; `val` continues to receive its value at its declaration until
single-assignment path merging is implemented.

A local is in scope from its declaration to the end of its block. A local of a
nested block may shadow a parameter, an outer local, or a field; the outer
binding is visible again once that block ends, including to a lambda that
captures it:

```abla
fun scaled(width: f64, flag: bool): f64 {
    var result = width
    if (flag) {
        val flag = 0.5      // shadows the parameter inside this block
        result = width * flag
    }
    if (flag) result else 0.0   // the parameter again
}
```

Two locals of one block may not share a name (`local.duplicate`), and a local
of a function's or lambda's body block may not redeclare one of its parameters
(`local.shadows-parameter`): the parameters are declared in that scope.

### Delegated bindings

A delegated binding looks like an ordinary `val` or `var`, but every read and
every write of it goes through an object you choose: the *delegate*. Use one
when a value needs a policy attached to it (clamping, validation, logging,
counting, a value kept somewhere else) without making every use site call
that policy by hand.

```abla
import "abla/io"

class Clamped(var current: int, val minimum: int, val maximum: int) {
    fun getValue(): int = current
    fun setValue(next: int): void {
        current = if (next < minimum) minimum else if (next > maximum) maximum else next
        return
    }
}

fun main {
    var volume: int by Clamped(40, 0, 100)
    println("start: $volume")
    volume = 140                // calls setValue(140); the delegate keeps 100
    println("after 140: $volume")
    volume -= 150               // getValue, then setValue(-50); it keeps 0
    println("after -= 150: $volume")
}
// output:
// start: 40
// after 140: 100
// after -= 150: 0
```

`var volume: int by Clamped(40, 0, 100)` evaluates `Clamped(40, 0, 100)` once
and stores that object. From then on, `volume` in an expression means
`getValue()` on the stored object and `volume = x` means `setValue(x)`.

#### The delegate contract

- The delegate is an instance of a class with a zero-argument `getValue()`
  method. Its result type is the *exposed* type: what `volume` reads as.
- A delegated `var` also needs `setValue(next: T): void`, where `T` is the
  exposed type. A delegated `val` needs no setter and cannot be assigned
  (`assignment.immutable`).
- The type annotation is optional: `var volume by Clamped(40, 0, 100)` takes
  its type from `getValue()`. When it is written, `getValue()` must return
  exactly that type.
- `by` works on local and top-level `val`/`var`, and on `compile val` /
  `compile var`. It does not work on parameters or class properties.

#### When the accessors run

- Every read calls `getValue()` once. That includes reads inside string
  templates and the read half of a compound assignment.
- Every assignment evaluates its right-hand side once and calls `setValue()`
  once. `volume -= 150` is one `getValue()` and one `setValue()`.
- The value of an assignment expression is the value that was *assigned*, not
  what the delegate kept. `val attempted = (volume = 140)` sets `attempted` to
  `140` even though `volume` reads back `100`. No extra `getValue()` call is
  made to find out.

```abla
import "abla/io"

class Counted(var current: int, var reads: int, var writes: int) {
    fun getValue(): int {
        reads += 1
        current
    }
    fun setValue(next: int): void {
        writes += 1
        current = next
        return
    }
}

fun main {
    var score by Counted(0, 0, 0)
    score = 10                 // 1 write
    score += 5                 // 1 read, 1 write
    val copy = score           // 1 read
    println("score $score")    // 1 read
    val attempted = (score = 7)
    println("assigned $attempted; reads ${(^score).reads}, writes ${(^score).writes}")
}
// output:
// score 15
// assigned 7; reads 3, writes 3
```

#### Reaching the delegate: `^name`

Prefix `^` names the stored delegate object instead of the exposed value. Its
static type is the delegate's class, so you can read its fields, call its
methods, and pass it to functions under the usual parameter and ownership
rules. On a delegated `var`, `^name = replacement` swaps in a new delegate:

```abla
import "abla/io"

class Clamped(var current: int, val minimum: int, val maximum: int) {
    fun getValue(): int = current
    fun setValue(next: int): void {
        current = if (next < minimum) minimum else if (next > maximum) maximum else next
        return
    }
}

fun widen(var policy: Clamped): void {
    policy.current = policy.maximum   // a `var` parameter may mutate the delegate
    return
}

fun main {
    var volume: int by Clamped(40, 0, 100)
    println("limit ${(^volume).maximum}")
    widen(^volume)
    println("widened to $volume")
    ^volume = Clamped(5, 0, 10)      // replace the delegate itself
    volume += 100
    println("new policy: $volume")
}
// output:
// limit 100
// widened to 100
// new policy: 10
```

Write `(^volume).maximum` with the parentheses. Prefix `^` applies to the
whole member chain after it, so `^volume.maximum` means `^(volume.maximum)`,
and `volume.maximum` is not a delegated binding:

```abla error
class Clamped(var current: int, val minimum: int, val maximum: int) {
    fun getValue(): int = current
}

fun main: int {
    val volume by Clamped(40, 0, 100)
    ^volume.maximum
}
// error: E_NOT_DELEGATED
// error: delegate projection requires an addressable delegated binding
```

The rules for `^`:

- Only a delegated `var` can have its delegate replaced; on a `val` that is
  `E_DELEGATE_REPLACE_VAL`.
- The replacement must have the same class as the current delegate
  (`E_DELEGATE_TYPE_MISMATCH`).
- The replacement expression is evaluated first. Then the old delegate is
  dropped, if it is a resource.
- `move(^name)` is rejected (`E_DELEGATE_MOVE_PROJECTION`): it would leave the
  binding with no delegate to call.
- `val alias = ^name` borrows the delegate. Replacing it while `alias` is
  still used later is `E_DELEGATE_BORROW_CONFLICT`.
- `^` on an ordinary binding is `E_NOT_DELEGATED` ("`n` has ordinary
  storage"). Between two integer expressions, `^` is XOR.

#### Closures, ownership and lifetime

A closure captures the binding itself, not a snapshot of its value. Each call
of the closure goes through the delegate that is current at that moment,
including one installed by `^name = ...` after the closure was created.

```abla
import "abla/io"

class Box(var current: int) {
    fun getValue(): int = current
    fun setValue(next: int): void {
        current = next
        return
    }
}

fun main {
    var value by Box(1)
    val read = { value }
    value = 7
    println("after assignment: ${read()}")
    ^value = Box(11)
    println("after replacement: ${read()}")
}
// output:
// after assignment: 7
// after replacement: 11
```

The delegate may be a `resource class`. It is dropped exactly once: when the
binding goes out of scope, or when `^name = replacement` replaces it. A
getter may not hand out an owned affine value (`E_DELEGATE_AFFINE_VALUE`), but
it may return a view tied to the delegate, as in
`fun getValue(): borrow(this) Ticket`.

A top-level delegated binding is initialized in the normal top-level
initializer order, and its delegate expression runs once.

#### At compile time

Delegated bindings behave the same under `#`, inside `compile fun`, and as
`compile val` / `compile var`. The getter's and setter's effects count as the
binding's effects, so a getter that reads the environment needs the
`environment` capability like any other caller (`compile.effect-denied`). The
compiler's binding reflection (`compiler.findBinding`,
`compiler.bindingIsDelegated`, `compiler.bindingDelegateType`, ...; see
[compiler-api.md](compiler-api.md#binding-reflection)) reports a binding's
delegation, exposed and delegate types, mutability, accessor handles,
whether replacement is allowed, and the `by` span. Reflection describes the
declaration only. The live delegate object is reachable only through
`^name` in source.

```abla
import "abla/io"

class Box(var current: int) {
    fun getValue(): int = current
    fun setValue(next: int): void {
        current = next
        return
    }
}

compile fun staged(): int {
    var value by Box(5)
    value += 1
    value * 7
}

fun main {
    println("${#staged()}")
}
// output:
// 42
```

#### Diagnostics

| Code | Cause |
|---|---|
| `E_DELEGATE_GETTER_MISSING` | The delegate has no zero-argument `getValue()`, or it doesn't return the declared type |
| `E_DELEGATE_SETTER_MISSING` | A delegated `var` whose delegate has no `setValue(T): void` |
| `E_NOT_DELEGATED` | `^` applied to something that isn't a delegated binding (including `^a.b`; write `(^a).b`) |
| `E_DELEGATE_REPLACE_VAL` | `^name = ...` on a delegated `val` |
| `E_DELEGATE_TYPE_MISMATCH` | `^name = ...` with a delegate of a different class |
| `E_DELEGATE_MOVE_PROJECTION` | `move(^name)` |
| `E_DELEGATE_AFFINE_VALUE` | `getValue()` returns an owned affine value |
| `E_DELEGATE_BORROW_CONFLICT` | The delegate is replaced while a borrow of it from `^name` is still used |

> Known issue: in a method, a field whose name is also the name of a
> top-level delegated binding currently resolves to the top-level binding at
> run time. Until that's fixed, don't give a top-level delegated binding the
> same name as a field of any class.

Function declarations may omit `()` only when they have no parameters. This
retains prototype compatibility. Trailing lambdas are supported. Lambdas are
lexical closures: captured bindings outlive their declaring call, nested
closures forward environments transitively, and a captured `var` is one shared
mutable binding rather than a copied snapshot. Capturing `this` follows the
same rules.

Function and primary-constructor parameters may have defaults. Calls may bind
top-level function and constructor parameters by name; positional arguments
must come first, every argument expression is evaluated once in source order,
and omitted defaults may refer to earlier parameters:

```abla
class Window(val width: int = 80, val height: int = width / 2)

fun area(width: int = 80, height: int = width / 2): int =
    width * height

val window = Window(height = 30)
val pixels = area(height = 30, width = 100)
```

Unknown, duplicate, ambiguous, or missing required names are compile-time
errors. The compiler lowers named calls to the ordinary positional ABI, so
foreign consumers and generated code do not need a second calling convention.

Annotations accept an optional expression argument. `@export("symbol")` and
`@exportChecked("symbol")` attach the stable foreign symbol directly to a
top-level function; the same signature and target validation used by the
compiler export API still applies:

```abla fragment
@export("micro_handle")
fun handle(pointer: int, length: int): int = dispatch(pointer, length)
```

An array publishes ABI aliases for the same implementation without repeating
the annotation:

```abla fragment
@export(["current_name", "compatibility_name"])
fun handle(pointer: int, length: int): int = dispatch(pointer, length)
```

Native naked-assembly exports coalesce those names to one LLVM definition.
Other exports retain ordinary adapters for each public name.

The direct scalar ABI preserves `bool`, `char`, `f32`, `f64`, and every
currently lowered signed or unsigned 8/16/32/64-bit integer type. WebAssembly
represents narrow integers in its `i32` lane while the adapter preserves their
declared bit width; `i64` and `u64` use its `i64` lane, and floating values use
their matching native lane. Managed classes and arrays are not exported as
opaque runtime values.
Unchecked exports whose complete signature is scalar call the typed direct ABI
without constructing universal runtime values. Checked exports retain their
panic-containing status ABI. A program may publish up to 128 explicitly named
exports; larger surfaces should be split at package or artifact boundaries.

### Overloads and operator functions

Functions, extension functions and methods may share a name when their
parameter types differ. Each call is resolved statically to one declaration:
the candidate whose parameters accept the argument types, preferring the one
with the most exact type matches. Two equally good candidates are rejected as
`call.overload-ambiguous`, and a call no candidate accepts as
`call.overload-no-match`; two declarations with the same parameter types remain
`symbol.duplicate`.

```abla fragment
fun N.mul(other: N): N = …
fun N.mul(k: f64): N = …
operator fun N.plus(other: N): N = …
operator fun N.unaryMinus(): N = …
operator fun f64.times(n: N): N = …

val sum = a + b * 0.5 - -c        // a.plus(b.times(0.5)).minus(c.unaryMinus())
val scaled = 0.5 * a              // the receiver may be a scalar
```

`operator fun` on a receiver gives an arithmetic operator meaning for that
type: `plus` (`+`), `minus` (`-`), `times` (`*`), `div` (`/`), `rem` (`%`)
and `unaryMinus` (prefix `-`). An operator applies when its receiver is the
left operand's type and a candidate accepts the right operand; otherwise the
expression is ordinary scalar arithmetic, whose code is unchanged. Overloaded
declarations are published under distinct internal names before semantic
analysis, so overloading adds no dispatch at runtime. Named arguments and
function references do not select among overloads.

## Types

The core types are `void`, `bool`, signed integer types (`i8`, `i16`, `i32`,
`i64`, with `int` aliasing `i64`), unsigned counterparts, floating types
(`f32`, `f64`), `char`, `string`, `array<T>`, and `any`.

A nominal scalar gives a primitive value a distinct source type without adding
runtime storage:

```abla
type Pin = int

fun Pin.next(): Pin = Pin(this + 1)
fun pinNumber(pin: Pin): int = pin
```

`Pin(4)` is the explicit conversion from the underlying integer. The reverse
direction is implicit: inside an extension, `this` is the integer itself, and a
`Pin` can be consumed wherever its underlying integer is accepted. A plain
integer is not accepted where `Pin` is required. Arithmetic uses the primitive
value and produces the underlying primitive type, so constructing a new `Pin`
remains explicit. Extensions still resolve against the nominal `Pin` type.
After semantic resolution the typed IR erases the nominal spelling to its
primitive representation; there is no allocation, object header, or dynamic
dispatch. `type` is contextual at declaration position and remains available
as an ordinary identifier elsewhere.

Primitive integer conversions are also explicit calls: `u32(value)`,
`i16(value)`, and the other integer spellings convert without allocating.
Narrowing keeps the low bits; widening sign-extends a signed source and
zero-extends an unsigned source. This makes register-width intent visible and
lets fixed-width values remain native through locals, calls, globals, branches,
and exports.

`T?` is nullable. Nullability is part of every type and is not represented by a
sentinel integer. `T*` is a native pointer type confined to trusted platform
implementations and does not implicitly transfer ownership.

A stable nullable local or parameter is refined to `T` only on a control-flow
path that proves it non-null:

```abla fragment
val connection = weakConnection.upgrade()
if (connection != null) {
    inspect(connection.get())
}
```

Both `value != null` and `null != value` refine the true branch; `==` refines
the false branch, and `!`, guaranteed `&&` true paths, and guaranteed `||`
false paths preserve the corresponding polarity. The fact is branch-local.
Mutable locals are not refined, fields are not refined through a receiver, and
the original nullable type returns after the branch. These restrictions avoid
invalidating a proof through assignment or an alias; later data-flow work may
accept a mutable place when it can prove no intervening write.

### Ownership and resources

Ownership has its own page, [ownership.md](ownership.md). In brief:

- Plain values (`int`, `bool`, `f64`, `string`, ...) are copied. Ordinary
  class objects, arrays and closures are *managed references*: they are
  shared freely and collected automatically, but a function changes an
  object it receives only through a `var` parameter, and an alias may not
  observe a change made after it was taken
  ([details](ownership.md#changing-objects-through-references)).
- `resource class` declares an *affine* type, whose values have one owner.
  Ownership moves with `move(x)`, and `drop()` runs exactly once when the last
  owner goes away
  ([details](ownership.md#resources-values-with-one-owner)). A class that
  stores an affine value is affine too.
- Parameters borrow by default. `var p: T` borrows exclusively for one call;
  `own p: T` takes ownership
  ([details](ownership.md#parameters-borrow-var-and-own)).
- Iterating over an array of resources borrows each element, and iterating
  over `move(array)` takes each one out
  ([details](ownership.md#collections-of-resources)).
- `Shared<T>.get()` views and `borrow(source)` results are tied to their
  owner by a control-flow check (`E_BORROW_CONFLICT`)
  ([details](ownership.md#borrowed-views-and-borrow-results)).
- `Cell<T>`, `Shared<T>`, `Weak<T>` and `Mutex<T>` make sharing explicit
  ([details](ownership.md#sharing-cell-shared-weak-mutex)).
- Closures are `Fn`, `FnMut` or `FnOnce` depending on what they do to their
  captures; `move { ... }` moves resources into a closure
  ([details](ownership.md#closures-and-ownership)).

### Scoped allocation regions

`region { ... }` creates a lexical allocation generation and reclaims it after
the body's affine values have been destroyed. Only an allocation-independent
scalar may cross the boundary:

```abla fragment
val status = region {
    val document = parseDocument(source)
    consume(document)
    0
}
```

Heap values cannot be returned, assigned into older locals or objects, captured
by an escaping closure, or passed through a call that may retain them. Receiver
and heap-parameter mutation effects propagate through wrappers, and unknown
foreign declarations retain by default. `noescape extern` is the FFI promise
that Abla-managed arguments do not survive the call; `trusted` separately
controls whether unsafe operations are authorized. Nested regions reset in
LIFO order. Arbitrary indirect calls remain conservatively retaining until
their type is `FnNoEscape`; ordinary function values remain retaining.
Non-local exits are rejected until cleanup-bearing edges are part of the
exception/control-flow model.

All tracked heaps have a hard cumulative allocation budget. The default is one
GiB and portable `abla/memory` code may change it explicitly. Exceeding it is a
controlled runtime panic before the platform allocation occurs. Ordinary
freely aliased objects can be reclaimed, including cycles, at an explicit
`memoryCollect()` safe point. The compiler emits liveness-compressed shadow
roots through direct and higher-order calls and traces precise allocation
layouts. Hosted native programs collect under allocation pressure by default:
every allocating function is a function-entry safe point. A program opts out
with `memorySetManualCollection()` (a call that `main` can reach compiles it
without those safe points, and it collects only at `memoryCollect()`); wasm and
freestanding programs are manual by default. `memorySetLimit` and
`memorySetCollectionGrowth` select pressure collection on every target (see
[the standard library](standard-library.md)). Affine native buffers are pinned until deterministic destruction or
region reset.

Function types use `(A, B) -> R`; an extension receiver uses `T.(A) -> R`.
Generic arguments use `Type<A, B>`.

## Expressions and control flow

Calls, member access, and indexing bind most tightly, followed by unary
operators, multiplication/division, addition/subtraction, shifts, comparison,
equality, bitwise AND/XOR/OR, logical conjunction/disjunction, and assignment.
Assignment is right-associative and produces the assigned value for prototype
compatibility. Compound assignment `place op= value` (`+=`, `-=`, `*=`, `/=`,
`%=`) means `place = place op value`, so an operator function applies to it as
well. Its place is evaluated twice and therefore may contain only names,
literals, fields and indexes, never a call.

Integer arithmetic and bitwise operators preserve their common declared width.
Fixed-width addition, subtraction, and multiplication wrap at that width;
division and ordered comparisons use the type's signedness. `&`, `|`, `^`, and
`~` operate on every bit in that width. `<<` shifts left, `>>` is arithmetic for
signed types and logical for unsigned types, and `>>>` is always logical. A
negative signed shift count or a count greater than or equal to the type width
produces zero. Arithmetic and `&`, `|`, and `^` operands must have the same
integer type. A shift count may use any integer type and is converted to the
shifted value's width before the range check, so `i32(value) >> 24` does not
need a redundant `i32(24)`. Use an explicit primitive conversion for other
mixed-width operations. Prefix `^binding` remains the delegate projection;
between two integer expressions, `^` is XOR.

`if` and `when` are expressions when all paths yield compatible values:

```abla fragment
val sign = if (n < 0) -1 else if (n > 0) 1 else 0

val label = when (n) {
    0 -> "zero"
    1, 2 -> "small"
    else -> "other"
}
```

Every `when` must be exhaustive. A Boolean subject may cover `true` and
`false` explicitly; every other subject currently requires one final `else`
arm. An `else` arm may appear only once and must be last. Repeated literal
integer, Boolean, string, or `null` matches are rejected. The subject is
evaluated once, and the first matching arm supplies the expression value at
compile time and runtime.

`never` is the uninhabited result type for expressions that cannot complete.
It joins with the type of a completing branch, so a diverging arm does not
force the whole expression to have type `never`:

```abla
fun waitForever(): never {
    while (true) {}
}

fun value(flag: bool): int = when (flag) {
    true -> 42
    false -> waitForever()
}
```

The compiler currently proves a loop divergent when its condition is the
literal `true` and no `break` can target that loop. It lowers proven
divergence to a verified unreachable terminator in native LLVM and generated
C control flow. A declared `never` function is rejected if any path can
produce a value or fall through.

`while` and `do ... while` are statements. `return expression` immediately
exits the innermost function, method, or lambda; a bare `return` returns
`void`. Return values are checked against declared result types, and explicit
returns execute identically at compile time and runtime. `break` exits the
innermost loop and `continue` starts its next condition check; both are valid
in `while`, `do ... while`, and `for` during compile-time or runtime execution.
`for (value in source)` iterates arrays, byte-indexed strings, inclusive
ascending integer ranges (`first..last`), and exclusive ascending ranges
(`first until end`). Range expressions are ordinary `array<int>` values.

## Trusted native implementations

Abla does not expose a general unsafe-block programming model. A raw native
declaration uses `trusted extern`, and only a function whose complete
implementation is declared `trusted` may call it:

```abla fragment
trusted extern:"intrinsic" fun platformRead(address: i64*): int

trusted fun checkedRead(buffer: NativeBuffer, offset: int): int {
    if (offset < 0 || offset + 8 > buffer.capacity) 0
    else platformRead(buffer.pointerAt(offset))
}
```

Calling `platformRead` from an ordinary function is a compile error. Calling
the checked wrapper is ordinary safe code. The intended stable policy also
requires a package-manifest grant before non-platform packages may define a
trusted implementation; that manifest enforcement remains part of the effect
and package-interface work.

## Compile-time execution

Compile-time execution has its own page, [compile-time.md](compile-time.md).
In brief:

- `#expression` evaluates an expression during compilation and stores the
  result in the program as a constant. `#` binds to the operand right after
  it, call and member chain included: `#f() + 1` is `(#f()) + 1`
  ([details](compile-time.md#expression)).
- `compile fun` declares a function that exists only during compilation;
  ordinary functions work in both phases
  ([details](compile-time.md#compile-fun)).
- A top-level `#expression` is an action, run for its effect after semantic
  analysis ([details](compile-time.md#top-level-actions)).
- `compile val` / `compile var` hold one value for the whole compilation,
  shared by every compile-time evaluation
  ([details](compile-time.md#compile-val-and-compile-var)).
- Files, environment, processes, network, clock and randomness need a
  capability, authorized in `abla.toml` and requested with
  `#compilerGrant` ([details](compile-time.md#capabilities-files-environment-processes-network)).
- Reflection, transforms and generated code are the `abla/compiler` module
  ([compiler-api.md](compiler-api.md)).

Typed deferred-expression reflection also exposes deterministic state access
paths. Paths are rooted at semantic parameters, receivers, locals, or globals
and retain field, constant/dynamic index, `Cell`, delegate, and conservative
wildcard projections. Function summaries propagate those paths through calls
by substituting resolved arguments; recursion or an unavailable body widens to
an explicit unknown result. Extensions may compare read and write paths for
prefix-aware invalidation and may lift a recorded expression into a generated
function only by listing explicit, ownership-safe captures (see
[compiler-api.md](compiler-api.md)).

## Compile-time subparsers

`$name` invokes a registered compile-time subparser at the current source
cursor. The handler returns an ordinary expression, so its result is usable at
runtime or under `#`. Handlers may delegate delimited regions back to the Abla
expression parser, which makes parser stacks and template interpolation
possible. Registration staging, cursor ownership, determinism, and hygiene are
specified in `docs/subparsers.md`.

A handler may record a deferred extension request containing a syntax handle,
payload, namespace, and Abla finalizer. The finalizer can inspect the syntax and
target declaration metadata, then return one bounded virtual module. The
combined handwritten/generated program passes normal semantic, ownership,
effect, IR, and backend validation atomically. Generated identifiers carry a
compiler-only hygiene marker that source and ordinary syntax builders cannot
mint. Complete overload/conversion maps and populated generic substitutions
remain later refinements.

## Cleanup, generators, tasks, and threads

These have their own page, [concurrency.md](concurrency.md). In brief:

- `defer { ... }` runs cleanup when the enclosing block ends, however it
  ends; several `defer`s run last-registered first
  ([details](concurrency.md#defer)).
- `generator { ... yield value ... }` produces a `Generator<T>` for a `for`
  loop ([details](concurrency.md#generators)).
- `task { ... }` is a cooperative coroutine (`Task<T>`); `await` runs it
  and returns its result ([details](concurrency.md#tasks)).
- `thread { ... }` starts an OS thread (`Thread<T>`); `await` joins it. A
  thread may capture only `Shared`, `Mutex` and `Weak` handles
  ([details](concurrency.md#threads)).

## Modules and imports

Imports are top-level declarations. A direct implementation import may retain
compatibility visibility or bind the target to a module-local alias:

```abla fragment
import "path/to/file.ab"
import "shared/models.ab" as models

fun load(value: models.Account): models.Account =
    models.normalize(value)
```

An import argument may also be a typed compile-time source-provider call. The
provider returns `ImportSource` rather than performing network I/O during
parsing:

```abla fragment
import github("AndreBaltazar8/abla-mvc") as mvc
```

User-defined compile functions can return `ImportSource` through
`gitImportSource(...)` or through `importSource(...)` with a deferred resolver
that supplies a `ResolvedImport` of source files. Resolution, immutable locks,
offline behavior, and vendoring are documented in `docs/packages.md`.

Imports are canonicalized, cached by content and configuration, cycle checked,
and processed deterministically. Compile-time and runtime code can import the
same module; phase filtering happens per declaration. An aliased module is a
compile-time namespace, not a runtime value. Its functions, globals,
constructors, interfaces, and nominal types are available only through the
alias. Aliases are direct and module-local; importing a facade does not expose
the aliases used inside that facade.

Canonical declaration and type identities derive from the normalized defining
module, not the consumer's alias spelling. Consequently, alias renames affect
only the importing frontend and do not rename native symbols or reflected
canonical identities. Two unaliased direct imports exposing the same short
name are diagnosed as `E_IMPORT_UNQUALIFIED_AMBIGUOUS`; source order never
selects a winner.

A contract import exposes callable signatures, annotations, defaults, ownership
modes, and reachable nominal data shapes without adding their implementations
to the runtime program:

```abla fragment
import contract "../backend/counter.ab" as counter

val request = $rpc(counter.incrementRemotely(41))
```

Contract calls are ordinary typed direct calls while a deferred compiler
extension inspects them. The extension must replace the call with executable
client-side syntax. A contract call left in the final program fails with
`E_CONTRACT_CALL_NOT_CONSUMED` before IR construction. Contract extraction does
not stage backend initializers or compile actions and follows only imports
needed by declaration shapes, so implementation-only dependencies and ambient
capabilities remain outside the consumer. Interface fingerprints exclude
function bodies; changing a signature, annotation, default, or reachable data
shape changes the contract identity, while a body-only edit does not.

Portable console programs import `abla/io`; the selected target profile
provides the implementation behind the same source API:

```abla
import "abla/io"
fun main: int {
    println("Hello, world!")
    0
}
```

`readInputLine()` returns `InputLine(text, available)` so EOF remains distinct
from a valid empty line. The shorter `readLine()` intentionally maps EOF to an
empty string.

## Native declarations

Prototype-compatible `extern:"c"` declarations are supported by the C ABI
native module. Portable standard-library APIs do not expose C strings or
variadic functions. Native declarations must use ABI-safe types; conversions
between `string` and `cstring` are explicit or generated by a declared adapter.

The bootstrap may link libc for the host runtime. The language ABI itself does
not require libc. Freestanding targets provide allocation, panic, I/O, and
process hooks through a target runtime.

The current native ABI maps Abla `int` to C `int64_t`, `bool` to C `_Bool`,
`cstring` inputs to `const char*`, explicit `T*` to opaque native pointers, and
`void` directly. A `string` supplied to a declared `cstring` parameter receives
a generated NUL-terminated input adapter. Native `cstring` results are rejected
until ownership is declared. Other types require an explicit adapter rather
than an unchecked cast. Native libraries are registered explicitly in the VM
and linked explicitly for generated code.

Export adapters are a separate, manifest-described boundary. Their current
borrowed `string` input is length-delimited `(const uint8_t*, uint64_t)`, not a
C string. The adapter validates the pair and copies it into Abla ownership, so
the caller retains and may immediately reuse or release its buffer after the
call. The ABI manifest records `ownership: borrowed` and
`calleeAction: copy`.

An exported `(int) -> int` callback parameter lowers to a C callback taking an
explicit context pointer followed by `int64_t`. It is borrowed synchronously
for that exported call. The Abla function may invoke it directly, but export
validation rejects storing, returning, capturing, or forwarding it, so the
foreign pointer cannot outlive its caller-owned context. The manifest records
the callback signature, C calling convention, call lifetime, forbidden
retention, and the requirement that it not unwind across the ABI.

Checked export adapters are opt-in through `exportCheckedFunction`. Their C ABI
returns an `int32_t` status and moves the normal result to an out-pointer. A
panic becomes status `1`; its bytes are copied into a caller-owned buffer and
the full length is reported even when that buffer truncates the message.
Status `2` reports invalid boundary output pointers. This contains control flow
and restores the runtime's recovery/root frames, but cleanup is abortive and
external side effects are not transactional. Direct exports remain explicitly
uncontained. Targets that do not advertise the required runtime capability
reject checked exports.

An exported `string` result is copied into an opaque foreign handle rather than
leaking the tracked `%AblaValue` or an interior runtime pointer. Callers inspect
it through the manifest-named data/length functions and must call the release
function exactly once. Its bytes remain valid until release. The initial handle
allocator is available on libc-backed targets; a libc-free extension must
provide its own compatible allocation contract before selecting this result
ABI.

## Compatibility baseline

The original examples establish the initial compatibility suite:

- functions, calls, trailing lambdas, and extension functions;
- variables, arrays, classes, interfaces, and annotations;
- arithmetic, comparisons, `if`, `when`, `while`, and `do while`;
- nullable values and pointers;
- imports and C externals;
- compile-time execution and compiler-context transformations.

Compatibility means accepted useful syntax and intended results, not matching
the prototype's LLVM text, unchecked casts, races, accidental `i32` ABI, or
known TODO behavior.
