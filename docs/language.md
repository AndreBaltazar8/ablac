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
between digits. Strings use `"..."` and support the escapes `\t`, `\b`, `\r`,
`\n`, `\'`, `\"`, `\\`, `\$`, and `\uXXXX`. `$name` and `${expression}` are
string interpolation.

The compiler accepts `;` as an explicit separator, but never requires it.

## Declarations

The compatible declaration forms are:

```abla
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

```abla
var answer: int
if (ready) answer = 42 else answer = fallback()
use(answer)
```

The verified control-flow graph requires every path to assign the binding
before a read. An untyped deferred declaration and a deferred `val` are
rejected; `val` continues to receive its value at its declaration until
single-assignment path merging is implemented.

Function declarations may omit `()` only when they have no parameters. This
retains prototype compatibility. Trailing lambdas are supported. Lambdas are
lexical closures: captured bindings outlive their declaring call, nested
closures forward environments transitively, and a captured `var` is one shared
mutable binding rather than a copied snapshot. Capturing `this` follows the
same rules.

## Types

The core types are `void`, `bool`, signed integer types (`i8`, `i16`, `i32`,
`i64`, with `int` aliasing `i64`), unsigned counterparts, floating types
(`f32`, `f64`), `char`, `string`, `array<T>`, and `any`.

`T?` is nullable. Nullability is part of every type and is not represented by a
sentinel integer. `T*` is a native pointer type confined to trusted platform
implementations and does not implicitly transfer ownership.

A stable nullable local or parameter is refined to `T` only on a control-flow
path that proves it non-null:

```abla
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

`resource class` declares an affine nominal type:

```abla
resource class Socket(var descriptor: int)
```

A resource may reserve a zero-argument `drop(): void` method. The compiler
invokes it exactly once for a directly owned, still-live resource on ordinary
scope exit, reassignment, early return, `break`, `continue`, and owned-parameter
exit. Moves clear the source storage, so cleanup at a later merge is a checked
no-op rather than a second invocation:

```abla
resource class Socket(val descriptor: int) {
    fun drop(): void {
        platformClose(descriptor)
        return
    }
}
```

`drop` is compiler-reserved on resource classes: duplicate declarations or a
non-`void`/parameterized signature are rejected. The compiler generates one
verified drop helper per reachable affine type. Direct resources, structural
wrappers, nested fields, arrays, and nullable resources therefore clean up
recursively at compile time, in LLVM, and in generated C. Replacing an affine
field or array element drops the previous value first.

Consuming a field or element clears only that slot and leaves the owner
partially initialized. Unmoved sibling fields and statically distinct array
indexes remain usable; rereading the moved place or using the complete owner is
rejected across CFG joins. Assigning a compatible owned value back into a
mutable moved field or array element reinitializes that place; whole-owner use
becomes valid only when every incoming CFG path has restored every moved
subplace. The remaining live fields are destroyed at the owner's ordinary
lifetime end, so projection remainders are neither leaked nor double-dropped.
A dynamic index is tracked conservatively as an unknown array place. Moving a
field out of a class that defines its own `drop` is rejected
because doing so could violate the user destructor's invariants.
Each moving lambda also has a verified companion drop function describing its
capture layout. An uninvoked, replaced, returned-from, nested, or
container-held `FnOnce` recursively destroys its still-owned captures and
releases its environment; invocation transfers those captures into the lambda
body and releases the environment afterward. Compile-time evaluation, LLVM,
and generated C use the same rule.

`move(local)` transfers an affine local and invalidates the source binding on
every control-flow path. A subsequent read or second move is rejected by the
IR verifier; assigning a mutable binding again starts a new lifetime. Returning
a local is an implicit move because the source lifetime ends on that edge.
Ordinary parameters borrow resources by default, so inspection does not consume
the caller's binding. Borrowed parameters cannot be returned or stored. A
`var` parameter is an exclusive mutable borrow for the duration of one call,
and an `own` parameter explicitly consumes an affine argument:

```abla
fun inspect(socket: Socket): int = socket.descriptor
fun reset(var socket: Socket): int {
    socket.descriptor = -1
    socket.descriptor
}
fun close(own socket: Socket): int = platformClose(socket.descriptor)
fun forward(own socket: Socket): Socket = move(socket)

var socket = Socket(openDescriptor())
inspect(socket)          // borrowed; socket remains available
reset(socket)            // exclusively borrowed; available after the call
close(move(socket))      // ownership transferred; socket is invalid
close(Socket(otherFd))   // a fresh value transfers directly
```

`own` is valid only on an affine function, extension, or method parameter;
using it on a scalar or another freely copyable type is a compile error. Class
primary-constructor properties remain spelled `val` or `var`. An affine value
stored in either property is already transferred by construction, so a bare
`own` constructor parameter is rejected rather than silently consuming and
discarding a value that is not a field.

`var` applies to affine owners and managed references: resource classes,
ordinary classes/interfaces, and arrays. Its argument must be a uniquely
addressable place or a value proven fresh through a constructor-returning
function/method; arbitrary returned references are not assumed unique. It
cannot be `move(...)` or an ordinary parameter. The callee may mutate
fields/elements and call mutating methods, but cannot rebind the parameter or
let the view escape. Ordinary managed parameters are read-only, including
nested field/index mutation and `append`. Defaults and raw `extern`
declarations are not valid for `var` parameters.

Mutating receivers are inferred with receiver-type-specific transitive
summaries, including mutation through managed fields. One call rejects an
exclusive view overlapping any other managed/affine argument or receiver and
still permits disjoint projections.

A direct immutable local alias of an array, a class with a mutable field, or a
class that reaches such a field through nested `val` class fields is converted
to a source-linked managed view:

```abla
val counter = Counter(20)
val view = counter
val observed = view.value
increment(counter) // legal: `view` was last used above
```

The alias cannot mutate, escape, be stored, become a mutable local, or overlap
a mutation while a later use is reachable. The typed CFG uses exact field and
constant-index provenance, so mutations of disjoint sibling places remain
legal. Runtime functions, compile functions, and methods use the same rule and
are pre-verified before staged execution. Arrays reached only through `val`
fields and references stored into new aggregates remain the next
immutable-sharing rung; those need lifetime propagation across aggregate
boundaries rather than merely deeper type classification.

A function or method also cannot disguise a mutable managed parameter or
receiver as an ordinary result. Direct projections and branch/block tails
derived from a parameter require an explicit source-linked result such as
`borrow(owner) Counter` or `borrow(this) Counter`. Mutating fluent APIs should
return `void` unless retaining the returned view is an intentional part of
their contract.

Ordinary mutable managed results must otherwise be provably fresh. The proof
covers literals/constructors, local `val` builder identities, complete `if` and
`when` joins, staged/region wrappers, and calls whose implementation has the
same proof. Returning a global, a stored global projection, or an opaque
non-factory result without `borrow(source)` is rejected. Affine `own` results
continue to use move semantics rather than this shared-reference rule.

Existing local and owned-parameter bindings require `move` at a consuming call;
fresh constructor and function results transfer directly. Function, method, and
constructor-property transfers use the same rule. The callee owns an `own`
parameter and may forward it with `move` or return it at the end of its
lifetime. A single call cannot give overlapping affine places to an `own` or
`var` parameter and another live argument: for example,
`consumeAfterInspect(ticket, move(ticket))` and `copy(ticket, ticket)` are
rejected because aliases would coexist inside the callee. Segment-aware
checking still allows disjoint calls such as `copy(pair.left, pair.right)` and
`inspectAndConsume(pair.left, move(pair.right))`. A method receiver is live for
the complete call; a mutating receiver is exclusive and a shared receiver
cannot overlap an owned argument. Inferred callable types preserve both `var`
and `own` parameter modes, so indirect calls apply the same mutation, transfer,
and overlap rules. The modes are also available in explicitly written callable
types:

```abla
fun invoke(callback: (own: Socket) -> int, own socket: Socket): int =
    callback(move(socket))

fun modify(callback: (var: Socket) -> int, var socket: Socket): int =
    callback(socket)
```

`(Socket) -> int`, `(var: Socket) -> int`, and `(own: Socket) -> int` are
different types, so a mutating or consuming function cannot be assigned to a
shared callable slot.

Callable families describe how a closure itself may be invoked. `Fn(A) -> R`
is reusable and read-only, `FnMut(A) -> R` may mutate captured state, and
`FnOnce(A) -> R` consumes its environment. A parameter accepting `FnMut` must
be declared `var`; a parameter accepting `FnOnce` must be declared `own`:

```abla
fun twice(var callback: FnMut() -> int): int =
    callback() + callback()

fun finish(own callback: FnOnce() -> int): int = callback()
```

The compiler infers `FnMut` when an ordinary lambda assigns through a captured
place and implements the capture as one shared mutable cell, so compiled and
staged execution observe the same updates. `move { ... }` infers `FnOnce`.
`FnMut` and `FnOnce` values are affine and cannot be copied accidentally.

`Cell<T>` is explicit interior mutability for copy scalars. It can be retained
in a `val` field and changed only through `set`; `get` returns the scalar by
value. Managed references and affine resources are rejected as cell payloads,
so `Cell` cannot manufacture an escaping mutable alias. It is a local
single-thread abstraction and will remain non-transferable when concurrency
traits land; cross-thread mutation uses `Mutex<T>`.

```abla
class Counter(val value: Cell<int>)

val counter = Counter(Cell(0))
counter.value.set(counter.value.get() + 1)
```

`Shared<T>` is explicit, thread-safe shared ownership for an affine value and
`Weak<T>` is its non-owning counterpart. The handles are themselves affine:
copying a handle implicitly is rejected, while `clone()` deliberately creates
a second handle. This keeps reference-count changes visible in source and
prevents ordinary assignment from silently becoming an atomic operation:

```abla
val original = Shared(Socket(openDescriptor()))
val second = original.clone()
inspect(original.get())

val observer = original.downgrade()
val possibleOwner = observer.upgrade() // Shared<Socket>?
val live = observer.isAlive()
```

`Shared(value)` consumes an existing affine binding in the same way as any
other owning call, so an existing local is written `Shared(move(value))`.
`get()` returns a compiler-tracked, non-escaping `borrow:T`: it may be inspected,
passed to an ordinary borrowed parameter, or bound to an inferred immutable
local when the receiver is a stable local/parameter-rooted place:

```abla
val owner = Shared(Socket(openDescriptor()))
val view = owner.get()
inspect(view)
val descriptor = view.descriptor // last use of `view`
val transferred = move(owner)    // legal after the last use
```

Typed-IR CFG liveness ties `view` to the exact source place. Moving, replacing,
or mutating an overlapping source is rejected on every path that can reach a
later view use; field- and constant-index-disjoint sibling places remain legal.
This analysis is non-lexical. Every runtime function, compile function, and
method whose syntax can bind a borrow is verified in side-effect-suppressed IR
before any staged `#` evaluation. Borrow locals are immutable and inferred from
a direct stable `get()`, another stable borrow local, or a field/index
projection rooted in one. Copies and projections retain the original owner
place rather than the intermediate view, so they may outlive that view and end
independently. `if` and exhaustive `when` expressions may join borrow branches
when every branch resolves to that same original owner place, including through
block results; a conditional choice between different owner roots is rejected.
Functions, compile functions, and methods may return a view only through an
explicit source-linked contract:

```abla
fun view(owner: Shared<Ticket>): borrow(owner) Ticket = owner.get()

resource class Holder(val handle: Shared<Ticket>) {
    fun view(): borrow(this) Ticket = this.handle.get()
}
```

Every explicit and implicit return must be proven to originate at that named
ordinary parameter or `this`; field projections conservatively retain the
whole declared source lifetime. At a direct call, the source is substituted
with the caller's exact owner place and participates in the same CFG last-use
analysis. A function-value result can retain the same relation using a
zero-based parameter index, including through local/global aliases,
higher-order parameters, and returned function values:

```abla
val callback: (Shared<Ticket>) -> borrow(0) Ticket = view
val ticket = callback(owner)
```

`Borrow<T>` is the explicit immutable-view spelling for parameters and locals;
it never manufactures provenance, so an initializer still has to be derived
from a checked owner. `own`/`var`/defaulted sources, cross-owner returns, and
extern lifetime promises are rejected. A returned view passed beside an
overlapping `own` or `var` argument is rejected before argument evaluation can
invalidate it.
Borrows without such a contract cannot be captured, returned, stored in objects/arrays/globals,
reshared, consumed, mutably borrowed, or mutated through. Heap-valued
projections remain borrowed so an intermediate projection cannot launder the
lifetime.

`Mutex<T>` is the checked shared-mutation abstraction. It owns an affine
payload, may be explicitly cloned, and holds a per-control atomic lock for the
entire callback passed to `with`:

```abla
resource class Counter(var value: int)

fun increment(var counter: Counter): int {
    counter.value = counter.value + 1
    counter.value
}

val state = Mutex(Counter(40))
val next = state.with(increment)
```

The current sound baseline requires a named callback with exactly one matching
`var` parameter and an allocation-independent scalar result. Consequently the
exclusive payload borrow cannot escape the locked call. Native LLVM and C
paths use atomic acquire/release locking; compile-time evaluation enforces the
same ownership and escape contract.

`downgrade()` creates a `Weak<T>` without extending the payload lifetime.
`upgrade()` atomically returns a new strong handle when the payload is still
alive and `null` otherwise; `isAlive()` is only an observation and does not pin
the value. The implementation uses atomic strong and weak counts and an
implicit weak reference while any strong owner remains. The last strong owner
runs the payload's verified drop helper exactly once, while the control block
remains valid until the last weak handle is destroyed.

The first sound implementations of `Shared`, `Weak`, and `Mutex` restrict `T`
to affine types. Ordinary classes
and primitive arrays still use freely aliased reference semantics, so accepting
them here would imply safety guarantees that the language cannot yet enforce.
General immutable sharing, profile-selected non-atomic local sharing, and
refinement of provably unmodified mutable places are later rungs; none weaken
the rules above.

### Scoped allocation regions

`region { ... }` creates a lexical allocation generation and reclaims it after
the body's affine values have been destroyed. Only an allocation-independent
scalar may cross the boundary:

```abla
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
function types carry region effects. Non-local exits are rejected until
cleanup-bearing edges are part of the exception/control-flow model.

All tracked heaps have a hard cumulative allocation budget. The default is one
GiB and portable `abla/memory` code may change it explicitly. Exceeding it is a
controlled runtime panic before the platform allocation occurs. Ordinary
freely aliased objects can be reclaimed, including cycles, at an explicit
`memoryCollect()` safe point. The compiler emits liveness-compressed shadow
roots through direct and higher-order calls and traces precise allocation
layouts. `memorySetLimit` selects automatic function-entry pressure safe
points. Affine native buffers are pinned until deterministic destruction or
region reset.

Reusable lambdas cannot implicitly capture affine values. `move { ... }`
creates a consuming closure and transfers its affine free variables at closure
creation:

```abla
var socket = Socket(openDescriptor())
val closeLater = move { platformClose(socket.descriptor) }
socket = Socket(otherDescriptor) // starts a new lifetime
closeLater()                     // consumes the closure
```

The inferred closure type has `FnOnce` semantics: it is itself affine, cannot
be copied, and its invocation invalidates the binding. A second call, use of an
outer resource after capture, ordinary `{ ... }` resource capture, and moving a
borrowed parameter into a closure are rejected.

Affinity propagates through stored fields and arrays. A class need not be
spelled `resource class` to be affine when one of its `val`/`var` constructor
properties contains an affine value. Resource fields and array elements are
borrowed when inspected and require an explicit consuming projection when
extracted:

```abla
var box = TicketBox(Ticket(40))
val ticket = move(box.ticket) // leaves only `box.ticket` uninitialized
box = TicketBox(Ticket(2))    // replacing the owner starts a new lifetime

var tickets = [Ticket(40)]
val first = move(tickets[0])  // leaves only the constant index uninitialized
tickets = [Ticket(2)]         // replacing the array restores the whole owner
```

Place liveness follows nested field and array-index segments. Independent
fields and statically distinct indexes remain available, including below a
nested array projection. A computed index aliases every index at that segment,
but it does not poison unrelated fields. Assigning through a computed index
cannot prove that a previously moved dynamic slot was restored; replacing a
known enclosing place or the complete owner can. Implicit owned extraction from
a borrowed container is rejected. Read-only borrow copies and field/index
projections may be stored as immutable locals and retain transitive provenance
to the original owner place. `Fn`/`FnMut`/`FnOnce`, `Borrow<T>`, and indexed
borrow-return function types are available. Checked call-scoped mutable managed
references are available; lifetime-polymorphic/cross-owner joins, persistent
immutable-alias provenance, and mutable borrows that outlive one call remain
in progress.

Function types use `(A, B) -> R`; an extension receiver uses `T.(A) -> R`.
Generic arguments use `Type<A, B>`.

## Expressions and control flow

Calls, member access, and indexing bind most tightly, followed by unary
operators, multiplication/division, addition/subtraction, comparison,
equality, logical conjunction/disjunction, and assignment. Assignment is
right-associative and produces the assigned value for prototype compatibility.

`if` and `when` are expressions when all paths yield compatible values:

```abla
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

```abla
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

`#expression` evaluates an expression during compilation:

```abla
val table = #makeTable()

fun main {
    #println("building main")
    use(table)
}
```

A `compile` declaration is available only during compilation. A normal,
phase-safe declaration is available in both phases. Runtime-only native
capabilities cause a compile-time error when invoked without a compile-time
provider.

Compile-time evaluation is staged:

1. parse and construct the module graph;
2. resolve declarations and types;
3. execute pending compile expressions to a fixed point;
4. validate the transformed typed program;
5. generate target code.

Generated declarations are typed before later compile-time code can observe
them. Mutations are transactional: on diagnostic failure, the program remains
unchanged. Stable reflection handles expose declarations, types, annotations,
and syntax builders. They never expose C++ or backend pointers.

Compile-time libraries are ordinary Abla modules. The compiler supplies a
versioned `compiler` module containing reflection, diagnostics, source,
filesystem, environment, and process capabilities. Ambient filesystem and
network access are denied by default. Capability use requires both a package
authorization beside the entry module and a source-visible request:

```toml
# abla.toml
compileCapabilities = ["filesystem.read"]
```

```abla
#import("abla/compiler")
#import("abla/io")

#compilerGrant("filesystem.read")
fun schemaSize(): int {
    val schema = #ablaHostReadFile("api.json")
    schema.size
}
```

The compiler infers transitive effect bitsets for allocation, compiler access,
filesystem read/write, environment, process I/O, network, clock, randomness,
and trusted native calls. A denied staged path fails before evaluation. Until
an ambient provider has a deterministic input contract, its grant disables
native object-cache reuse/publication. `filesystem.read` and
`compilerEnvironment(name)` are deterministic providers: staged reads journal
their observed provider identity, size, and dual content fingerprint and
revalidate them on every hit without storing environment values in the cache
sidecar. The sibling manifest is also part of cache identity. Parser handlers
and extension finalizers receive the complete granted-effect mask, merge their
input journals into the same artifact contract, and long-lived frontend
snapshots revalidate them before reuse. Their request/manifest intersection is
checked before parser evaluation, since that phase precedes complete semantic
analysis. Manifest authorization is injected as
an internal AST marker that ordinary source cannot construct.

The compiler module also provides bounded clock, random-integer, and process
execution operations. These require explicit `clock`, `random`, or
`process.io` grants and always disable native-object cache hits and publication.
The same watchdog process group bounds the compiler and any staged child.

The version 0.1 bootstrap exposes deterministic read-only function handles,
complete signatures, selected-call ownership/default/phase/trust metadata,
canonical method ownership, class-field metadata,
lexical/direct/member expression inspection, compiler-owned resolved-call
builders, trust/phase/native metadata, structural syntax inspection, and
bounded generated virtual modules; see `docs/compiler-api.md`. Generated
source is parsed and the complete candidate is revalidated rather than exposing
live host AST objects. Direct finalizers instead publish compiler-owned syntax
trees with opaque generated-declaration references.

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

## Modules and imports

The prototype spelling remains valid:

```abla
#import("path/to/file.ab")
```

The stable module form will be:

```abla
import abla.math
import "./local.ab"
```

Imports are canonicalized, cached by content and configuration, cycle checked,
and processed deterministically. Compile-time and runtime code can import the
same module; phase filtering happens per declaration.

Portable console programs import `abla/io`; the selected target profile
provides the implementation behind the same source API:

```abla
#import("abla/io")

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
