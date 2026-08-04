# RFC: Delegated bindings and explicit delegate projection

- Status: Draft
- Date: 2026-08-04
- Scope: local and stored bindings, getter/setter lowering, delegate access,
  ownership and borrowing, runtime delegate replacement, effects, reflection,
  and compile-time/runtime parity

## Summary

Abla should allow a binding to store a delegate object while presenting the
delegate's value as though it were an ordinary `val` or `var`:

```abla
val token: string by lazyToken()
var volume: int by ClampedInt(40, 0, 100)

play(token)       // calls the delegate getter, then passes a string
volume = 140      // calls the delegate setter with 140
println(volume)   // calls the getter and observes 100
```

This RFC calls the feature a *delegated binding* and the stored object its
*delegate*. It proposes Kotlin-inspired `by` declaration syntax, but gives
Abla an explicit way to access the delegate itself:

```abla
inspect(^volume)       // passes the ClampedInt delegate, not an int
reconfigure(^volume)   // may mutate the delegate under ordinary `var` rules
^volume = ClampedInt(20, 0, 50) // replace the delegate of a `var` binding
```

`volume` and `^volume` are deliberately different projections of one storage
location:

- `volume` has the exposed value type and invokes `getValue` or `setValue`;
- `^volume` has the delegate type and uses ordinary Abla ownership rules; and
- the delegate expression is evaluated exactly once when the binding is
  initialized, not once per read.

The first implementation is structurally typed. A readable delegate provides
`getValue`; a delegate for a mutable binding also provides `setValue`. Abla
does not need operator overloading, runtime reflection, or a universal boxed
`Delegate<T>` interface to implement the feature.

An end-to-end concrete delegate can be an ordinary class:

```abla
class ClampedInt(
    var current: int,
    val minimum: int,
    var maximum: int
) {
    fun getValue(): int = current

    fun setValue(next: int): void {
        if (next < minimum) current = minimum
        else if (next > maximum) current = maximum
        else current = next
        return
    }
}

fun raiseLimit(var policy: ClampedInt): void {
    policy.maximum = policy.maximum + 50
    return
}

fun main: int {
    var volume: int by ClampedInt(40, 0, 100)
    volume = 124
    raiseLimit(^volume)
    volume = 124
    volume
}
```

`main` returns `124`: the first assignment is clamped to `100`, projecting the
delegate raises its limit, and the second assignment is accepted.

## Motivation

### Reusable storage and access policy

Some binding behavior is naturally reusable but is not an ordinary stored
value:

- lazy or deferred initialization;
- range validation and normalization;
- observable state and invalidation;
- persistence in a file, database row, environment, or platform preference;
- access logging, metrics, or debugging;
- synchronization and actor/thread confinement; and
- a computed view backed by another object.

Without delegation, every use must expose the wrapper at every read:

```abla
val volume = ClampedInt(40, 0, 100)
volume.setValue(140)
playAt(volume.getValue())
```

or the language must first gain one-off computed-property syntax and users
must repeat identical accessors at every declaration. A delegated binding
keeps the policy explicit at its declaration while preserving the value type
at ordinary use sites.

### The delegate is sometimes the useful value

Transparent reads are convenient, but hiding the delegate permanently would
throw away useful capabilities. A lazy delegate may expose whether evaluation
has happened. An observable delegate may expose subscriptions. A persistence
delegate may support `flush`, and a validation delegate may allow its bounds
to be reconfigured.

The projected form makes that distinction explicit:

```abla
consume(volume)          // int
inspectPolicy(^volume)   // ClampedInt
```

This is preferable to a function silently receiving a different object merely
because its parameter happens to use a special mode. A reader can see at the
call site whether a getter runs or the backing object is passed.

### Safe replacement is useful but must not be type-erased

Changing a delegate at runtime can swap policy or reset state:

```abla
var endpoint: string by CachedEndpoint(primaryUrl())

^endpoint = CachedEndpoint(fallbackUrl())
```

This is possible without dynamic typing when the replacement has the same
static delegate type. The binding already owns a delegate storage slot;
replacement is an ordinary checked reassignment of that slot. Supporting an
unrelated delegate type would instead require an explicit common class,
interface, or future existential box and is outside the implicit language
feature.

## Terminology

- A **delegated binding** is a declared name with a `by` initializer.
- The **exposed value** is what ordinary reads and writes of the name observe.
- The **delegate** is the value produced by the `by` expression and stored by
  the binding.
- A **value projection** is an ordinary use such as `volume`.
- A **delegate projection** is an explicit use such as `^volume`.
- The **delegate contract** is the statically resolved `getValue` and optional
  `setValue` method pair.

“Delegate” is used instead of “delegator” because it is the established term
for the object receiving delegated work.

## Current behavior

Abla currently supports initialized and typed-deferred local `var` bindings,
top-level values, and `val`/`var` primary-constructor properties. A binding
stores its declared value directly. A read loads that value and assignment to
a `var` replaces it.

The ownership model already distinguishes the operations this RFC needs:

- ordinary parameters inspect values without consuming affine owners;
- `var` parameters are call-scoped exclusive mutable borrows of addressable
  managed or affine places;
- `own` parameters and `move` explicitly transfer affine values;
- source-linked `borrow(source)` results prevent returned views from escaping
  their owner; and
- replacing an affine place drops its old live value exactly once.

`Cell<T>` provides explicit interior mutability for copy scalars, but using a
cell still exposes `.get()` and `.set()` at every use. There is no syntax for a
binding whose ordinary access invokes user code, and no expression that names
storage hidden behind such a binding.

## Goals

The proposal must:

1. let a `val` or `var` store a delegate while exposing another statically
   known value type;
2. evaluate the delegate initializer exactly once;
3. lower every ordinary read and write to statically resolved methods;
4. keep ordinary arguments value-oriented;
5. make access to the delegate explicit and first-class;
6. allow the delegate to be inspected or mutably borrowed under existing
   ownership rules;
7. define safe same-type runtime delegate replacement;
8. preserve affine destruction, borrow provenance, regions, and closure
   capture behavior;
9. account for getter and setter effects in semantic summaries;
10. behave identically during compile-time evaluation and runtime execution;
11. avoid mandatory runtime property metadata or reflection allocation; and
12. produce deterministic lowering, diagnostics, and interface fingerprints.

## Non-goals

- General operator overloading.
- Raw references, pointers, or an address-of operator.
- Dynamically changing the delegate's static type.
- Making access implicitly atomic, synchronized, pure, or observable.
- A universal runtime `Delegate<T>` base class.
- Kotlin-compatible `thisRef`, `KProperty`, or `provideDelegate` behavior in
  the first version.
- Automatically forwarding arbitrary methods from the delegate to the exposed
  value or in the other direction.
- Hiding delegate projection at the call site based on parameter overload
  resolution.
- Allowing an affine exposed value to be consumed by an innocent-looking read
  in the first implementation.
- Adding class-body stored properties solely for this feature. Delegation can
  extend to them when that declaration form is available.

## Proposed syntax

### Declaration

The declaration grammar is conceptually:

```text
delegated-binding := ("val" | "var") identifier [":" type] "by" expression
```

Examples:

```abla
val answer by ConstantInt(42)
var retries: int by ClampedInt(3, 0, 10)
```

`by` is a declaration keyword only in this RFC. It is not a general infix
operator. A delegated declaration always has an initializer; these forms are
invalid:

```abla
var missing: int by       // missing delegate expression
var deferred: int         // valid ordinary deferred var, not delegated
val impossible: int by D  // invalid if D does not provide getValue
```

When the exposed type is omitted, it is inferred from the selected
`getValue()` result. The delegate type is always inferred from the `by`
expression and retained in typed IR even though it is not written beside the
binding name.

### Delegate projection

Prefix `^` projects the delegate storage of a delegated place:

```abla
^answer
^settings.timeout
^items[index].cachedValue
```

The operand must resolve to one addressable delegated binding or property.
`^` does not operate on an arbitrary expression and is not numeric XOR,
exponentiation, pointer dereference, or address-of. These uses are invalid:

```abla
^ordinaryValue
^makeObject().delegatedProperty
^(if (ready) first else second)
```

The fresh-receiver example is initially rejected because it would project a
delegate from temporary storage whose lifetime and mutation behavior are not
visible. A later temporary-borrow rule may admit it without changing syntax.

`^` binds as a unary operator over a complete postfix place, so
`^settings.timeout` means “the delegate of `settings.timeout`”. Parentheses can
make unusual cases explicit.

### Why not `$name`

Swift uses `$name` for a property wrapper's projected value. In Abla, `$name`
already introduces a library-provided subparser and also appears in string
interpolation. Reusing it would make lexical scanning and source reading
context-dependent. `^` is currently unassigned and visually suggests the
backing layer without claiming pointer semantics.

## Delegate contract

### Readable binding

For delegate type `D` and exposed type `T`, an ordinary read requires a
statically resolved method equivalent to:

```abla
fun D.getValue(): T
```

The actual declaration uses Abla's normal method syntax. No `operator`
annotation is required. `getValue` is compiler-recognized only while checking
or lowering a `by` declaration; calling `delegate.getValue()` explicitly
remains an ordinary method call.

If `T` is inferred, the selected method must have one unambiguous result type.
If `T` is declared, the ordinary return-conversion rules must accept the
method's result as `T`. Defaults, variadic arguments, or an overload requiring
arguments do not satisfy the contract.

### Mutable binding

A `var` delegated binding additionally requires:

```abla
fun D.setValue(value: T): void
```

The setter receives the exposed type after normal assignment conversion. It
must return `void`; the binding does not use a setter result. A `val` does not
require `setValue`, and remains non-assignable even if the delegate happens to
provide one.

The names are intentionally conventional rather than an interface in the
first version. Abla does not yet need associated types or a boxed generic
protocol merely to connect `D` to `T`. A future standard-library interface may
document reusable generic delegates without changing the structural lowering.

### Receiver mutability

The compiler checks the selected methods exactly as an explicit call on the
stored delegate would be checked. If `getValue` mutates the delegate receiver,
the binding must provide an addressable mutable receiver and the read is a
mutation for alias analysis. `setValue` will normally be a mutating method.

The `val`/`var` keyword governs the exposed binding, not whether the delegate
type contains internal mutable state:

- `val x by d` forbids `x = value` and `^x = otherDelegate`;
- it may still invoke a stateful getter when the delegate's normal type and
  ownership rules permit that method;
- `var x by d` permits value assignment through `setValue`; and
- only `var x by d` permits replacement of the delegate storage.

This matches Abla's existing rule that `val` prevents binding reassignment but
does not promise deep immutability.

## Desugaring and storage model

Conceptually:

```abla
var volume: int by ClampedInt(40, 0, 100)
```

behaves like compiler-owned storage and accessors:

```abla
var volume$delegate = ClampedInt(40, 0, 100)

// read of volume
volume$delegate.getValue()

// volume = next
volume$delegate.setValue(next)
```

`volume$delegate` is illustrative and cannot be named or collided with in
source. Typed IR stores a stable binding identity, delegate type, exposed type,
mutability, and resolved getter/setter identities. Lowering must not recover
these facts later from a textual synthesized name.

The delegate expression is evaluated once at the declaration in ordinary
source order. If it does not complete, the binding never becomes initialized.
Reads never reevaluate that expression.

### Reads

Every value-context read invokes `getValue` exactly once. This includes an
ordinary function argument, interpolation, comparison, return, and
initialization of another binding:

```abla
val first = volume          // one getValue call; first is an ordinary int
consume(volume, volume)     // two calls, evaluated left to right
```

The compiler cannot cache, merge, duplicate, or remove getter calls unless the
ordinary effect and purity system independently proves that transformation
valid. Merely declaring the binding `val` is not such a proof.

### Writes

For:

```abla
volume = expression
```

the right-hand side is evaluated once, converted to the exposed type, and then
passed once to `setValue`. The assignment expression retains Abla's current
result rule: its value is the converted right-hand-side value, not a second
call to `getValue`. A normalizing setter may therefore make the next read
different from the assignment expression's result:

```abla
val attempted = (volume = 140) // attempted is 140
val stored = volume             // stored may be 100
```

This avoids an implicit additional getter and preserves the language's
existing assignment-expression behavior. If compound assignments are added,
their delegated expansion must specify one getter followed by one setter.

### Scope exit and destruction

The binding owns the stored delegate. If it is affine, ordinary verified drop
rules destroy it exactly once at scope exit, early control-flow exit, or valid
replacement. The exposed value is not separately stored and is not separately
dropped.

Consuming `move(^binding)` is rejected in the first implementation. It would
leave the binding without a delegate and require a second definite-assignment
state layered under every later value access. Explicit replacement provides
the useful policy-swap operation without exposing partially initialized
delegated storage.

## Passing values and delegates

Ordinary argument syntax observes the exposed value:

```abla
fun consume(value: int): void { ... }
consume(volume)
```

This invokes `getValue` and passes the resulting `int` under normal scalar copy
semantics.

Delegate projection observes the stored delegate:

```abla
fun inspect(delegate: ClampedInt): int = delegate.maximum

fun widen(var delegate: ClampedInt): void {
    delegate.maximum = delegate.maximum + 10
    return
}

inspect(^volume)
widen(^volume)
```

The projected expression is an addressable place rooted at the original
binding. An ordinary parameter borrows an affine delegate or uses normal value
semantics for a copyable delegate. A `var` parameter creates the same
call-scoped exclusive mutable borrow that it would for any other managed or
affine place. It can mutate delegate fields but cannot rebind the caller's
delegate slot, because Abla `var` parameters do not rebind their arguments.

An immutable alias obtained from `^volume` retains provenance to the delegate
slot. Replacing or exclusively mutating that slot is rejected while a later
alias use remains reachable:

```abla
val policy = ^volume
inspect(policy)
^volume = ClampedInt(1, 0, 10) // legal only after policy's last use
```

Returning a view into a delegate requires the existing `borrow(source)`
contract. Storing, capturing, consuming, sharing, or crossing a region with a
delegate projection follows the same rules as the delegate type used directly.
The projection creates no escape hatch around ownership.

### No delegate-catching parameter mode

This RFC does not add a form such as:

```abla
fun reset(^parameter: ClampedInt): void
reset(volume) // proposed alternative, not this RFC
```

Under that alternative, the same argument spelling could invoke a getter or
pass hidden storage depending on overload resolution and an indirect callable
type. It would also require a new mode in every callable type, reflection API,
ABI description, and higher-order call check.

Writing `reset(^volume)` is local, explicit, works with ordinary functions and
function values, and makes the delegate's static type available through normal
type checking. If repeated ergonomics later justify a delegate parameter mode,
it can desugar to the same projection model.

## Runtime delegate replacement

Assignment to the projection replaces the stored delegate rather than calling
the exposed setter:

```abla
volume = 60                         // setValue(60)
^volume = ClampedInt(60, 0, 80)     // replace the ClampedInt delegate
```

Replacement is permitted only when:

1. the delegated binding is declared `var`;
2. the right-hand side has the same statically accepted delegate type;
3. the delegate place is initialized and addressable;
4. no overlapping immutable or mutable borrow remains live;
5. region rules permit the new delegate to inhabit the binding's region; and
6. ordinary affine replacement/drop verification succeeds.

The new delegate expression is evaluated before the old delegate is dropped,
matching safe ordinary reassignment. After successful evaluation, the old
delegate is destroyed if required and the new one becomes active. The setter
is not called during replacement. The next value read calls `getValue` on the
new delegate.

Replacement with a different concrete type is rejected even when both types
happen to expose compatible methods:

```abla
var value: int by FirstIntDelegate(1)
^value = SecondIntDelegate(2) // type mismatch
```

A program that needs this policy can declare the delegate expression as an
explicit shared interface or future existential wrapper. Dynamic dispatch is
then visible in that type rather than being secretly introduced by `by`.

A `val` delegate can expose an explicit `reset` or interior-mutation API, but
its backing slot cannot be replaced:

```abla
val token by LazyToken(loadToken)
reset(^token)                    // allowed if normal mutable-borrow rules allow
^token = LazyToken(otherLoader)  // rejected: delegate binding is val
```

## Ownership and result types

### Copyable exposed values

Copy scalars are the simplest and required first rung. Each getter call
produces an ordinary value. Setter input follows normal conversion and copy
rules.

### Managed and borrowed exposed values

A getter returning a managed class, interface, array, or string is checked as
an ordinary method return. If the result is a view into delegate-owned state,
the method must declare and prove a receiver-linked result such as:

```abla
fun getValue(): borrow(this) Buffer = this.storage.get()
```

At a binding read, `this` substitutes to the exact delegate storage place.
Borrow liveness therefore prevents delegate mutation or replacement while a
later use of the returned view is reachable. A getter that constructs a fresh
managed result may return it under the existing freshness rules.

The delegated syntax does not erase whether the result is fresh, borrowed, or
freely copyable. Typed IR retains the getter's result provenance.

### Affine exposed values

The first implementation rejects a getter whose exposed result is an owned
affine value. Reading a name normally suggests observation, while such a getter
would silently consume, recreate, or transfer a resource on every read.

A later extension could add an explicit consuming projection with a
`takeValue` contract. It must not overload ordinary `move(binding)` until the
language specifies reinitialization, repeated reads, failed takes, and drop
behavior. Delegates themselves may already be affine; the restriction concerns
the exposed getter result.

## `val`, laziness, and observable change

For an ordinary binding, users often read `val` as a stable value. In Abla it
formally prevents reassignment and does not promise deep immutability. A
delegated `val` makes the distinction especially visible:

```abla
val clockReading: int by ClockDelegate()
```

Two reads may differ if `getValue` reads a clock or mutable external state.
That behavior is legal but effectful. APIs should prefer a truthful name and
an explicit effectful delegate over presenting volatile I/O as a constant.
The compiler and reactive extensions must never infer stability from `val`
alone.

A lazy delegate is a strong use case because repeated reads conventionally
return the same stored result after one initialization. That property belongs
to the delegate implementation or a future purity contract, not to the `by`
syntax itself.

## Closures and lifetime

A closure that reads a delegated local captures the delegate storage, not a
snapshot returned by `getValue`:

```abla
var count: int by CounterDelegate(0)
val read = { count }
count = 4
val later = read() // invokes getValue and observes the delegate's current state
```

If a snapshot is intended, source can request one explicitly:

```abla
val snapshot = count
val readSnapshot = { snapshot }
```

A captured delegated `var` uses the same shared capture-cell model as an
ordinary captured `var`; replacement through `^count` updates the delegate slot
observed by closures. Getter/setter mutation contributes to `FnMut` inference.
Capturing an affine delegate requires the existing `move { ... }` rules, and a
borrowed delegate projection cannot escape through a closure.

## Globals, properties, and initialization

### Locals and top-level bindings

The first complete surface supports local and top-level delegated bindings.
Top-level delegate initialization follows the existing deterministic global
initializer order. Compile-time and runtime globals store the delegate type in
their actual layout while source lookup exposes the value type.

An uninitialized or deferred delegated declaration is not supported. Deferred
behavior belongs inside a fully initialized delegate such as `LateInt`:

```abla
var answer: int by LateInt()
answer = 42
use(answer)
```

Here the delegate exists from the declaration onward. It decides whether a
read before the first setter call returns a value or panics. The ordinary CFG
definite-assignment checker cannot prove the delegate's internal state unless a
future refinement contract explicitly exposes it.

### Stored properties

When Abla supports initialized class-body stored properties, the same syntax
applies per instance:

```abla
class Preferences(val store: PreferenceStore) {
    var theme: string by StoredString(store, "theme", "system")
}
```

The object layout contains `StoredString`, not a separate `string`. The
initializer runs once per constructed object after required constructor
parameters are available and before the object escapes. `^preferences.theme`
projects that instance's delegate.

Primary-constructor `val`/`var` parameters are not delegated in the first
version. A syntax such as `class C(var x: int by D(...))` is unclear about
whether callers supply `x`, `D`, or neither. It should wait for initialized
stored-property syntax rather than give constructor parameters a surprising
ABI.

## Effects, reactivity, and optimization

A value read is semantically a direct method call to `getValue`; a value write
is a direct call to `setValue`. Existing transitive effect analysis must include
their complete effects:

- receiver and global reads/writes;
- allocation and panic/divergence;
- filesystem, network, clock, randomness, process, and native capabilities;
- borrow creation and ownership changes; and
- region retention.

The [reactive dependency reflection RFC](reactive-dependency-reflection.md)
should report both the source-level delegated path and the getter/setter's
transitive paths. A framework may recognize a standard observable delegate,
but the compiler does not make every delegated binding reactive.

Optimizers must initially treat access as the resolved call it is. A pure,
stable getter may later be commoned only under the same proof needed for the
equivalent explicit method call. A setter may clamp, reject, persist, notify,
or do nothing; the compiler cannot replace it with a store.

## Compile-time execution

Delegation is phase-neutral. A phase-safe delegate can be used in runtime or
compile-time code:

```abla
compile fun generatedPort(): int {
    val port: int by EnvironmentInt("PORT", 8080)
    port
}

val port = #generatedPort()
```

The evaluator stores the delegate and invokes the same resolved methods in the
same order as native execution. A runtime-only getter or setter fails when
called during compilation. Capabilities remain explicit at the call site of
the surrounding compile-time expression and are checked transitively through
delegate methods.

Generated syntax may create a delegated declaration only through a structured
builder that records both exposed and delegate contracts. Generated code goes
through ordinary semantic, ownership, and IR verification; extensions cannot
install an unverified getter or setter handle.

## Reflection, interfaces, and ABI

Semantic reflection for a binding should expose:

- whether it is delegated;
- exposed value type;
- delegate type;
- `val`/`var` mutability;
- canonical getter and optional setter identities;
- whether delegate replacement is permitted; and
- source span of the `by` expression.

The reflection API returns stable handles, not the live delegate object. An
extension may construct syntax for a value read or delegate projection through
compiler-owned builders.

Module interface and incremental cache fingerprints include the exposed type,
delegate type when visible or layout-relevant, mutability, method contracts,
effects, ownership provenance, and delegation kind. A change from ordinary
storage to delegation can change effects and object/global layout even when the
exposed type is unchanged, so it must invalidate affected implementations.

Foreign exports expose only behavior explicitly described by their ABI. A
delegated top-level value is not automatically exported as a foreign global.
Generated getters/setters used at a foreign boundary must be ordinary checked
adapter functions.

## Concurrency and reentrancy

Delegation does not provide synchronization. Sharing a delegate across tasks or
threads requires the same future transfer/share traits and current checked
abstractions as sharing the delegate explicitly. A `Mutex`-backed delegate can
provide synchronized access; an ordinary mutable class delegate cannot claim
that property merely because it appears behind `by`.

Getter and setter methods may be reentrant. If they directly or transitively
read or write their own delegated binding, they can recurse. The compiler
should diagnose a syntactically direct self-reference in the delegate
initializer, but general recursive access follows normal call-graph behavior.
A standard lazy delegate should detect initialization cycles and issue a
controlled panic rather than expose uninitialized storage.

No read-modify-write atomicity is implied. `value = value + 1` performs one
getter and one later setter with the same race properties as spelling those
calls directly.

## Diagnostics

Required diagnostics include:

```text
error[E_DELEGATE_GETTER_MISSING]: `Cache` does not provide
`getValue() -> string` required by delegated binding `token`
```

```text
error[E_DELEGATE_SETTER_MISSING]: mutable delegated binding `volume`
requires `ClampedInt.setValue(int) -> void`
```

```text
error[E_NOT_DELEGATED]: `plain` has ordinary storage and cannot be projected
with `^`
```

```text
error[E_DELEGATE_REPLACE_VAL]: delegate of `token` cannot be replaced because
the binding is declared `val`
```

```text
error[E_DELEGATE_BORROW_CONFLICT]: cannot replace delegate of `volume` while
the view `policy` may be used later
```

```text
error[E_DELEGATE_AFFINE_VALUE]: delegated getter returns owned affine `Socket`;
the first delegated-binding version supports copy, fresh managed, or checked
borrowed results only
```

Diagnostics should point to the binding name, `by` expression, candidate
method, and conflicting use where applicable. A method body failure retains
ordinary generated/source provenance instead of being reported as a generic
delegation error.

## Implementation outline

### Stage 1: typed local delegation

1. Reserve `by` in declaration context and lex `^`.
2. Extend binding AST/semantic records with the delegate initializer and type.
3. Resolve `getValue` and `setValue` once during semantic analysis.
4. Support copy-scalar local exposed values.
5. Lower reads/writes to explicit typed call operations in staged evaluation,
   LLVM, and generated C.
6. Include calls in effect, liveness, and reachability summaries.

### Stage 2: projection and replacement

1. Add a delegate-place projection to typed place paths.
2. Permit ordinary and `var` borrows of `^binding`.
3. Implement same-type `^binding = expression` for delegated `var` storage.
4. Reuse affine replacement/drop and region verification.
5. Preserve projected provenance through aliases, calls, and CFG joins.
6. Reject consuming projection and non-addressable temporary roots.

### Stage 3: complete storage surface

1. Add top-level delegated bindings and deterministic initialization.
2. Support fresh managed and receiver-linked borrowed getter results.
3. Integrate closure capture cells and callable-family inference.
4. Extend initialized class-body stored properties when that feature lands.
5. Publish structured semantic reflection and generated-syntax builders.
6. Include delegation in module interfaces, cache keys, and ABI layout records.

This order keeps the first rung small without choosing a throwaway syntax or a
second runtime model.

## Testing plan

### Parser and type tests

1. inferred and explicitly typed `val` delegates;
2. inferred and explicitly typed `var` delegates;
3. missing, ambiguous, wrong-arity, wrong-result, and inaccessible getters;
4. missing, wrong-input, non-`void`, and inaccessible setters;
5. `^` on delegated locals, fields, and indexes;
6. `^` on ordinary names and non-addressable expressions;
7. declaration recovery after malformed `by` syntax; and
8. no regression in `$` subparsers, `#` expressions, unary operations, or type
   parsing.

### Runtime and staged parity

9. delegate initializer called exactly once;
10. getter called once per source read;
11. setter called once after right-hand-side evaluation;
12. assignment expression returns the converted attempted value;
13. normalizing setter changes a later read;
14. compile-time and native traces have identical evaluation order;
15. runtime-only effects fail during staged execution; and
16. generated C and LLVM agree for getter, setter, projection, and replacement.

### Ownership and lifetime

17. affine delegate dropped once on ordinary and early scope exit;
18. affine delegate replacement drops the old instance once;
19. replacement evaluates the new instance before dropping the old one;
20. immutable delegate aliases block overlapping mutation/replacement until
    last use;
21. `var` delegate borrow permits internal mutation but not slot rebinding;
22. `move(^binding)` is rejected;
23. receiver-linked getter borrows prevent delegate invalidation;
24. borrowed projections cannot escape, be stored, or cross a region;
25. closure reads capture live delegate storage rather than one getter result;
26. `FnMut` inference includes mutating getters/setters; and
27. moving closure rules hold for affine delegates.

### Replacement and negative cases

28. same-type replacement of a delegated `var` succeeds;
29. replacement of a delegated `val` fails;
30. replacement with another structural but different delegate type fails;
31. value assignment invokes the setter and never replaces the delegate;
32. delegate assignment replaces the delegate and never invokes the setter;
33. outstanding disjoint sibling delegate projections remain usable; and
34. dynamic index projections conservatively conflict.

### Effects, reflection, and caching

35. getter/setter global and receiver effects appear transitively;
36. delegated reactive access reports source and transitive access paths;
37. reflection reports stable exposed/delegate/method identities;
38. a getter/setter contract change invalidates dependent cache entries;
39. a delegate implementation-only edit preserves unaffected interface caches
    where ordinary rules permit; and
40. diagnostics retain user and generated source provenance.

## Acceptance criteria

The RFC is implemented when:

- `val/var name [: T] by expression` has one specified parse and storage model;
- ordinary reads and writes invoke the checked contract exactly once;
- `name` passes the exposed value and `^name` explicitly exposes the delegate;
- existing borrow, `var`, ownership, affine-drop, region, and capture checks
  apply to projected delegate places;
- same-type runtime replacement is supported only for `var` bindings and is
  distinct from exposed-value assignment;
- getters and setters retain their true effects in every compiler phase;
- staged, LLVM, and generated-C behavior is conformant;
- negative tests cover missing contracts, illegal projection, borrow conflicts,
  invalid replacement, and unsupported affine results; and
- the language contract is updated from this draft only when the matching
  implementation and conformance tests land.

## Alternatives considered

### Keep wrapper access explicit

Explicit `.getValue()` and `.setValue()` need no language feature and remain
appropriate when wrapper identity is central. They become noisy for storage
policies intended to behave like properties, and cannot preserve ordinary
value syntax for framework-generated or generic code.

### Add only computed properties

User-written `get`/`set` blocks would solve one declaration at a time. They are
still valuable, but do not by themselves package reusable state and behavior
into an object that can be inspected, passed, or replaced.

### Use Swift-style wrapper attributes

Swift property wrappers synthesize wrapper storage from an attributed wrapper
type and expose a separate projected value. That model is powerful, especially
when initial wrapped values feed wrapper initializers. Abla's proposed `by`
form is smaller: the right-hand side is already the complete delegate value,
so it does not require attribute-specific constructor rewriting.

The Swift model is described in the official [Properties language
guide](https://docs.swift.org/swift-book/LanguageGuide/Properties.html#ID617).

### Copy Kotlin exactly

Kotlin lowers delegated properties through `getValue(thisRef, property)` and
`setValue(thisRef, property, value)`, with an optional `provideDelegate` hook.
That supplies receiver and reflective property metadata to every access. The
official [Kotlin language
specification](https://kotlinlang.org/spec/declarations.html#delegated-property-declaration)
defines that expansion.

Abla should not allocate or pass runtime property metadata on every ordinary
binding access before it has a stable runtime reflection model. A delegate can
receive any required key, owner, or configuration explicitly in its initializer.
An optional compiler-owned `BindingInfo` or one-time provision hook can be a
later RFC if real delegates need declaration identity.

### Use `$name` for the delegate

This matches Swift's familiar projected-value spelling but conflicts with
Abla's `$subparser` prefix and string interpolation. It also suggests a
user-declarable identifier even though the projection is a place operation.

### Use `delegate(name)` instead of `^name`

A compiler intrinsic is lexically simpler and more searchable. It looks like
an ordinary function despite requiring an addressable delegated place, and
member/index projections become visually heavy. `^name` communicates that a
different layer of the same place is selected. The intrinsic spelling remains
a viable choice if user testing finds `^` too cryptic.

### Mark the receiving parameter

A parameter mode could make `f(binding)` pass the value to one overload and
the delegate to another. This hides an important distinction at the call site,
complicates higher-order callable types, and makes overload selection affect
whether user code runs a getter. Explicit `f(^binding)` composes with the
existing parameter and ownership model.

### Never permit delegate replacement

Kotlin's synthesized delegate storage is generally not a public reassignable
property, and immutable delegate identity is easier to reason about. Abla can
permit replacement without weakening its model because `var` already denotes
reassignable storage, `^` makes the operation explicit, and affine/borrow
verification already governs replacement. `val` retains the stable-slot
option.

### Allow any structurally compatible replacement

This would turn the backing slot into a hidden existential container and add
allocation or dynamic dispatch depending on the replacement. Requiring the
same static delegate type keeps layout, dispatch, effects, and drop behavior
deterministic. Programs can opt into polymorphism through an explicit common
type.

### Expose the delegate only through reflection

Runtime reflection would make a basic operation expensive, dynamically typed,
and unavailable in freestanding configurations. Delegate projection is
statically typed, zero-discovery, and compatible with Abla's stable-handle
reflection principle.
