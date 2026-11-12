# Ownership, borrowing and resources

Abla checks, at compile time, who may change a value and who is responsible
for cleaning it up. This page explains those rules from the ground up. The
checks are the same at run time and at compile time (under `#`), and they cost
nothing when the program runs: there is no reference counting unless you ask
for it with `Shared`.

- [Three kinds of values](#three-kinds-of-values)
- [Parameters: borrow, `var` and `own`](#parameters-borrow-var-and-own)
- [Changing objects through references](#changing-objects-through-references)
- [Resources: values with one owner](#resources-values-with-one-owner)
- [Temporary lifetimes and loop sources](#temporary-lifetimes-and-loop-sources)
- [Collections of resources](#collections-of-resources)
- [Borrowed views and `borrow(...)` results](#borrowed-views-and-borrow-results)
- [Sharing: `Cell`, `Shared`, `Weak`, `Mutex`](#sharing-cell-shared-weak-mutex)
- [Closures and ownership](#closures-and-ownership)
- [At compile time](#at-compile-time)
- [Reading ownership diagnostics](#reading-ownership-diagnostics)

## Three kinds of values

| Kind | Examples | Copying `val b = a` | Cleanup |
|---|---|---|---|
| Plain values | `int`, `bool`, `f64`, `char`, `string`, nominal `type`s | copies | none needed |
| Managed references | ordinary `class` objects, arrays, plain closures | both names refer to the same object | the garbage collector |
| Affine values | `resource class` objects and anything that contains one; `Shared`/`Weak`/`Mutex` handles; `FnMut`/`FnOnce` closures | rejected: write `move(a)` | deterministic: `drop()` runs exactly once |

Strings are immutable, so sharing one is the same as copying it. Managed
references can be shared freely, but the compiler controls who may *change*
the object behind them. Affine values have exactly one owner at a time:
ownership moves from one name to another, and when the last owner goes away
the value is destroyed on the spot.

## Parameters: borrow, `var` and `own`

A parameter's mode says what the function may do with the caller's value:

| Mode | Spelling | The function may | The caller |
|---|---|---|---|
| Borrow (default) | `counter: Counter` | read it | keeps the value |
| Exclusive borrow | `var counter: Counter` | read and change it, for the duration of the call | keeps the value, sees the changes |
| Ownership transfer | `own ticket: Ticket` | do anything, including keep or destroy it | gives the value away: `consume(move(ticket))` |

The default is the safe one: a function cannot change an object it was
merely handed. To let it, say so with `var`:

```abla
import "abla/io"

class Counter(var value: int) {
    fun increment(): void {
        value += 1
        return
    }
}

fun total(counters: array<Counter>): int {
    var sum = 0
    for (counter in counters) sum += counter.value
    sum
}

fun bumpAll(var counters: array<Counter>): void {
    for (counter in counters) counter.increment()
    counters.append(Counter(100))
    return
}

fun main {
    val counters = [Counter(1), Counter(2)]
    println("total ${total(counters)}")
    bumpAll(counters)
    println("total ${total(counters)}, size ${counters.size}")
}
// output:
// total 3
// total 105, size 3
```

Without `var`, `bumpAll` would be rejected at `counter.increment()` and at
`counters.append(...)`:

```abla error
class Counter(var value: int)

fun bump(counter: Counter): void {
    counter.value += 1
    return
}

fun main {
    bump(Counter(0))
}
// error: ownership.borrow-mutation:member.assign.value:counter
// error: declare the parameter `var` to change the caller's value
```

Rules for `var` parameters:

- `var` is for things that can be changed through a reference: classes,
  arrays and resources. A `var` parameter cannot have a default, and an
  `extern` function cannot take one (`ownership.mutable-borrow-default`,
  `ownership.mutable-borrow-extern`).
- The argument must be something only this call can reach: a local, a field
  or element of one (`counters[0]`), or a value that is provably new, such as
  a constructor call or a function that returns one. An arbitrary returned
  reference is not assumed to be unique (`ownership.mutable-borrow`).
- The function may change fields and elements and call methods that change
  them. It may not keep the reference: it can't store it, return it or
  capture it in a closure.
- One call may not pass the same object twice when one of the uses can
  change it. `copyInto(c, c)` with `var target` is
  `ownership.mutable-alias`. Disjoint parts are fine:
  `copyInto(pair.left, pair.right)`.
- Methods work the same way. The compiler works out on its own whether a
  method changes its receiver (`this`), including through fields of fields
  and elements of array fields (`parts[i].grow()` changes `this`), and then
  treats the receiver as a `var` argument.

`own` is valid only for affine types (`ownership.owned-parameter-type`
otherwise). See [resources](#resources-values-with-one-owner).

### Modes in function types

A function type carries its parameter modes, so calls through a function
value follow the same rules. `(Counter) -> int`, `(var: Counter) -> int` and
`(own: Ticket) -> int` are three different types, and a function that
changes or consumes its argument can't be passed where a borrowing one is
expected:

```abla fragment
fun invoke(callback: (own: Ticket) -> int, own ticket: Ticket): int =
    callback(move(ticket))

fun modify(callback: (var: Counter) -> int, var counter: Counter): int =
    callback(counter)
```

## Changing objects through references

Ordinary objects are shared freely, but the compiler tracks *aliases*: other
names for the same object. You can make an alias, and you can change the
object, but not in an order where the alias would observe the change:

```abla
import "abla/io"

class Counter(var value: int)

fun increment(var counter: Counter): void {
    counter.value += 1
    return
}

fun main {
    val counter = Counter(20)
    val view = counter
    println("view reads ${view.value}")
    increment(counter)          // fine: `view` is not used after this point
    println("counter is ${counter.value}")
}
// output:
// view reads 20
// counter is 21
```

If `view` were read after `increment(counter)`, the program would be
rejected:

```abla error
class Counter(var value: int)

fun increment(var counter: Counter): void {
    counter.value += 1
    return
}

fun main: int {
    val counter = Counter(20)
    val view = counter
    increment(counter)
    view.value
}
// error: E_BORROW_CONFLICT
// error: `counter` is changed while `view`, which borrows it, is still used afterwards
```

The analysis follows the program's control flow, not its block structure: an
alias stops mattering after its last use. It also tracks fields and constant
indexes separately, so changing `pair.left` doesn't conflict with a view of
`pair.right`. Such an alias (a `val` that names an array or an object with
mutable state) cannot itself be used to change the object, stored, returned,
or turned into a `var` (`ownership.borrow-mutation`,
`ownership.borrow-mutable-local`).

### Returning references

A function may return a reference that is new, or one rooted in a global:

- a new object: a constructor call, a literal, a local `val` built up in
  the function, or the result of a function or method that returns a new
  object (whatever its receiver: `local.clone()`, `holder.items[0].clone()`);
- a reference rooted in a top-level binding, such as a global itself, a
  field of one, an element of one, an entry of a global `Map`
  (`store.get(key) ?? panic(…)`), a `for` variable over one, a `val` read
  from one, or a `borrow(name) T` result of a call given one. A global
  outlives every call, so returning it creates no unchecked alias;
- an `if`/`when` whose every branch is one of these, or ends in a call of
  type `never` (`panic(…)`), which gives no value.

```abla fragment
val shared = Counter(0)

fun fresh(start: int): Counter = Counter(start)     // fine: new
fun current(): Counter = shared                     // fine: rooted in a global
fun same(counter: Counter): Counter = counter       // inferred borrow(counter)
```

A result rooted in one parameter or `this` can carry an inferred borrow
contract, as `same` does above. If the compiler cannot infer one source,
returning a borrowed reference as an unrestricted result is rejected
(`ownership.managed-return-borrow-contract`). Declare `borrow(name) T`
([below](#borrowed-views-and-borrow-results)), build a new value, or let the
caller keep its own reference.

## Resources: values with one owner

`resource class` declares a type whose values have exactly one owner. Use it
for anything that must be released exactly once: a file descriptor, a socket,
a lock, a native buffer. An optional `drop(): void` method runs when the
owner goes away:

```abla
import "abla/io"

resource class Ticket(val seat: int) {
    fun drop(): void {
        println("  release seat $seat")
        return
    }
}

class Booking(val name: string, val ticket: Ticket)

fun show(ticket: Ticket): string = "seat ${ticket.seat}"
fun refund(own ticket: Ticket): int = ticket.seat
fun issue(seat: int): Ticket = Ticket(seat)

fun main {
    var current = issue(1)
    println(show(current))
    current = issue(2)                // the old ticket is dropped here
    println("refunded ${refund(move(current))}")
    val booking = Booking("ada", issue(3))
    val taken = move(booking.ticket)  // moves only that field out
    println("${booking.name} took ${show(taken)}")
    println("end of main")
}
// output:
// seat 1
//   release seat 1
//   release seat 2
// refunded 2
// ada took seat 3
// end of main
//   release seat 3
```

What happened, line by line:

- `issue(1)` returns a new ticket. Returning a local or a fresh value moves
  it to the caller.
- `show(current)` borrows the ticket. Borrowing is the default for every
  parameter, so looking at a resource never consumes it.
- Assigning `current` again drops the ticket it held first.
- `refund(move(current))` gives the ticket away. `refund` owns it, so it is
  dropped when `refund` returns. `current` can't be used after the `move`
  (until it is assigned again).
- `move(booking.ticket)` moves one field out. `booking.name` is still usable,
  but `booking` as a whole is not, until a ticket is put back into that
  field.
- `taken` is dropped when `main` ends.

The rules:

- `drop` takes no parameters and returns `void`. A second `drop`, or another
  signature, is an error (`resource.drop-duplicate`,
  `resource.drop-signature`). The compiler calls it; you don't.
- A resource is dropped exactly once, at the first of: the end of its
  owner's scope (including `return`, `break` and `continue`), reassignment of
  its owner, or the end of the function that received it with `own`. A value
  that was moved away is not dropped where it used to be.
- A new resource that nothing takes is dropped where it is discarded: a
  statement such as `issue(5)` on its own, the body of a loop, or the branch
  of an `if` without `else`. A block whose value is one of its own locals
  (`{ val t = issue(5); t }`) hands that local on with its value, so the block
  doesn't drop it too.
- A temporary has a shorter lifetime than a bound owner. Its precise boundary and examples are
  [below](#temporary-lifetimes-and-loop-sources).
- Copying is rejected: `val b = a` must be `val b = move(a)`
  (`ownership.move-required`). Passing `a` to an `own` parameter also needs
  `move(a)`. A fresh value, like `refund(issue(5))`, needs no `move`.
- `move(x)` takes a local, a parameter, or a field or constant-index element
  path such as `box.ticket` or `tickets[0]` (`move.local-or-place`). Moving
  out of a top-level binding is rejected.
- After `move(x)`, reading `x` or moving it again is an error on every path
  that can reach it. Assigning a `var` again starts a new lifetime.
- A class that holds a resource in a property is itself affine, even without
  the `resource` keyword. Dropping it drops its fields, recursively, and so
  do arrays and nullable values that hold resources.
- You can't move a field out of a class that defines its own `drop`
  (`ownership.place-drop`): its `drop` would then see a missing field.
- In a method or extension function, a field named on its own (`ticket`) is
  the place `this.ticket`: the same rules apply to both spellings. Copying a
  resource field out needs `move` (`ownership.place-move-required`), the
  receiver's fields can't be moved out of it (`ownership.place-owner`), and a
  view of a field, or of an element of an array a field holds (`val` field or
  `var`), conflicts with a later change to it (`E_BORROW_CONFLICT`), as a
  view of a local does.
- One call can't both give a value away and borrow it: `inspect(t, move(t))`
  is `ownership.borrow-own-alias`.
- A constructor property can't be spelled `own`: storing an affine value in
  a `val`/`var` property already transfers it
  (`ownership.owned-constructor-parameter`).

Mistakes the control-flow check finds are reported with the place, a note
pointing at the move, and a fix:

```abla error
resource class Ticket(val seat: int)

fun consume(own ticket: Ticket): int = ticket.seat

fun main: int {
    val source = Ticket(1)
    consume(move(source))
    source.seat
}
// error: ownership.use-after-move:source
// error: `source` is used after it was moved
```

| Code | Meaning |
|---|---|
| `ownership.use-after-move:<place>` | a value is used after it was moved; the note shows the move |
| `ownership.use-after-conditional-move:<place>` | a value is moved on some paths (a branch, or an earlier turn of a loop) and used after |
| `ownership.partial-move:<owner>` | an owner is used whole after one of its parts was moved out and not put back on every path |
| `ownership.once-called-again:<callback>` | a `move { ... }` closure may already have run |
| `assignment.unassigned:<name>` | a variable declared without a value is read before every path assigns it |

## Temporary lifetimes and loop sources

The examples in this section are excerpts from the linked tests. Their helper
resources append their drop events to a log; the comments give the checked
part of that log. The test names contain the complete declarations and expected
output. An owned value handed into a constructor, an `own` parameter, a local,
or `move` is no longer a temporary owned by the enclosing statement.

**Statements and nested owners.** A fresh value borrowed by a call or used as
an affine projection receiver is held until the whole statement finishes.
Fresh owners created by one statement drop newest first, including nested
constructor arguments. The selected root is held once: for an array projection
it is the array, not both the array and its element. The following checked
excerpt logs the call `B2`, then the outer holder/item `HI2`, then the inner
holder/item `HI1` ([test](../tests/cases/drop-temporaries/nested-order.ab)).

```abla fragment
inspect(Holder(Item(Holder(Item(1)).item.id + 1)).item)
events = events + "|"
// B2HI2HI1|
```

This includes extension-method receivers. `look` logs `B1`, then the
temporary drops at the end of the statement
([test](../tests/cases/extension-temporary-receiver/main.ab)).

```abla fragment
Item(1).look()
log = log + "|"
// B1I1|
```

An `if` or `when` receiver holds only its selected fresh arm; it leaves a
selected borrowed arm to its existing owner. These two calls print the
fresh-path drop before the marker and the existing owner's drop after it
([test](../tests/cases/conditional-method-temporary/main.ab)).

```abla fragment
extension(true)
extension(false)
// B1I1|I2B2|I2
```

Both fresh operands of an operator method remain alive through the call and
drop newest first after it. Here `P` is the operator body and `V5` the
following statement ([test](../tests/cases/operator-temporary-operands/main.ab)).

```abla fragment
val y = Item(2) + Item(3)
log = log + "V$y|"
// PI3I2V5|
```

**Conditions and subjects.** A temporary in an `if`, `while` or `do`-`while`
condition drops after that evaluation and before its body or the next
statement. A loop condition is evaluated and cleaned up on each pass. A
`when` subject finishes before the first match condition: temporaries used to
compute its value drop at that boundary. In this checked example `make(6)`
drops before the arm appends `six`
([test](../tests/cases/drop-temporaries/positions.ab)).

```abla fragment
mark("when subject")
when (make(6).id) { 6 -> order = order + " six" else -> order = order + " other" }
// |when subject 6 six
```

If the subject value itself is a fresh resource, the `when` owns it through
the match conditions and selected arm, then drops it before the next statement
([test](../tests/cases/when-subject-owner/main.ab)).

```abla fragment
when (face(1)) { is Item -> log += "Y" else -> log += "N" }
log += "|"
// YI1|
```

The same boundary applies to an `if` condition: the drop precedes its body
([test](../tests/cases/drop-temporaries/positions.ab)).

```abla fragment
mark("if condition")
if (make(4).ok()) order = order + " then"
// |if condition 4 then
```

The `while` condition below runs four times: three times for its body and once to
stop ([test](../tests/cases/drop-temporaries/branches.ab)).

```abla fragment
mark("condition each pass"); var i = 0
while (make(20 + i).ok() && i < 3) { i = i + 1 }
// |condition each pass 20 21 22 23
```

The final `23` comes from the left operand on the stopping pass, after the
three increments. The checked `do`-`while` example drops after each condition
([same test](../tests/cases/drop-temporaries/branches.ab)).

```abla fragment
mark("do while"); var k = 0
do { k = k + 1 } while (make(40 + k).ok() && k < 2)
// |do while 41 42
```

A short-circuit right operand has its own boundary; an operand that is skipped
creates and drops nothing. Here the left temporary is held through the right
operand, and their temporaries drop newest first at the join
([test](../tests/cases/drop-temporaries/branches.ab)).

```abla fragment
mark("left operand")
val e = make(5).ok() && make(6).ok()
// |left operand 6 5
```

No `1` is logged when the right operand is skipped
([same test](../tests/cases/drop-temporaries/branches.ab)).

```abla fragment
mark("and skipped")
val a = false && make(1).ok()
// |and skipped
```

Each `when` match condition is compared before its temporaries drop; they drop
before the next match is evaluated or the matching arm runs. A fresh affine
match value is also dropped after comparison; a borrowed match value remains
owned by its owner. The first and second matches below each drop a holder and
item before `B` ([test](../tests/cases/when-temporary-condition/main.ab)).

```abla fragment
when (2) { Holder(Item(1)).item.id -> log = log + "A"
    Holder(Item(2)).item.id -> log = log + "B"; else -> log = log + "C" }
// HI1HI2B
```

A conditional match can choose a fresh value or a borrowed one. On the fresh
path `I2` precedes the arm; on the borrowed path the existing owner drops
after the marker ([test](../tests/cases/when-affine-value/main.ab)).

```abla fragment
choose(true)
choose(false)
// I2N|I1M|I1
```

**Loop sources.** A generator loop closes its source on exhaustion, `break`,
`return`, or when an enclosing generator is dropped while suspended. It frees
the generator only if the loop owns it. A borrowed parameter, global, or field
or index of an owner is borrowed; a fresh or moved generator is owned. An
`if` or `when` source follows the selected arm, including across a `yield`.
When a field comes from a fresh temporary owner, the loop holds the selected
root through the loop: it closes the generator first, then drops that owner.
The following excerpt logs `generator holder break` in native and `#`
([test](../tests/cases/modules/generator-temporary-holder-order.ab)).

```abla fragment
for (value in Holder(numbers()).gen) break
events = events + "break | "
// generator holder break |
```

A `for` range bound is part of the loop statement: its temporary owner stays
through the loop body and drops when the loop ends
([test](../tests/cases/ownership-doc-lifetimes/main.ab)).

```abla fragment
for (i in 0 until Holder(Item(2)).item.id) { log = log + "B$i" }
log = log + "|"
// B0B1HI2|
```

A borrowed generator's owner retains its handle after the loop has closed it;
the later owner drop does not close it a second time. Here `first` returns from
its loop, and the caller continues with the owner still in scope
([test](../tests/cases/modules/generator-borrowed-close.ab)).

```abla fragment
val one = sequence()
first(one); events = events + "after-first "
// close after-first
```

A global generator is also borrowed: a second loop sees it already closed,
while an independently owned generator still yields
([test](../tests/cases/modules/generator-borrowed-global.ab)).

```abla fragment
for (value in global) println("$value")
for (value in global) println("bad $value")
// 1; the second loop prints nothing
```

The same rule applies to indexed sources and mixed conditional sources. The
following checked loop chooses the borrowed parameter or a fresh generator;
the enclosing test repeats both paths and prints `1000`
([test](../tests/cases/modules/generator-borrowed-conditional.ab)).

```abla fragment
var total = 0
for (value in if (choose) values else numbers()) total = total + value
// enclosing test: 1000
```

A fresh generator passed directly to a borrowing function remains owned by the
caller until that calling statement ends. The loop closes it and the later
drop does not close it again ([same test](../tests/cases/modules/generator-borrowed-close.ab)).

```abla fragment
first(sequence())
events = events + "after-temporary"
// close after-temporary
```

The fresh generator returned by `outer()` is owned by the outer loop; dropping
it while suspended closes its inner borrowed source before that source's
temporary holder is dropped ([test](../tests/cases/modules/generator-temporary-holder-order.ab)).

```abla fragment
for (value in outer()) break
events = events + "outer-drop"
// generator holder outer-drop
```

**Default arguments.** A default evaluated in an ordinary function or method
prologue owns its temporary until the callee returns, after its locals and in
newest-first order. An omitted constructor default or caller-side named default
is evaluated at the caller and holds its temporary until the calling statement
ends. If a generated helper is needed to preserve name resolution, its
non-escaping temporaries instead follow that helper's lifetime. In this test
`F1` is the body, `L` its local, then `HI1` the default owner and field
([test](../tests/cases/default-temporary-owner/main.ab)).

```abla fragment
value(1)
events = events + "|"
// F1LHI1|
```

Methods use the same prologue rule: `M3` is the body, `L` its local, and
`HI3` the default's owner ([same test](../tests/cases/default-temporary-owner/main.ab)).

```abla fragment
Methods().value(3)
events = events + "|"
// M3LHI3|
```

The caller-side named case keeps its owner across evaluation of the next
argument `side()`, which appends `S` ([same test](../tests/cases/default-temporary-owner/main.ab)).

```abla fragment
pair(value(a = 15), side())
events = events + "|"
// F15LSHI15|
```

An omitted constructor default is caller-side as well. Its holder drops after
the constructor call and before the following `C4` marker
([same test](../tests/cases/default-temporary-owner/main.ab)).

```abla fragment
val box = Box(4)
events = events + "C${box.b}|"
// HI4C4|
```

A helper forced by name shadowing drops its temporary before the called
function and the next caller argument
([test](../tests/cases/default-shadow-helper/main.ab)).

```abla fragment
val Holder = 5
pair(value(tag = Holder), side())
// HI5F5S|
```

**Exits and defers.** `return` computes its result first. For each scope left
by `return`, `break` or `continue`, innermost first, the exiting statement's
temporaries belonging to that scope drop, its defers run, and its locals drop.
An enclosing statement's older temporary remains until its own scope is left.
A prologue default owner remains until after the callee's locals. Here `HI1`
precedes defer `D` ([test](../tests/cases/exit-temporary-defer/main.ab)).

```abla fragment
returned()
log = log + "|"
// HI1D|
```

`break` and `continue` follow the same rule. The test's two iterations clean
`HI4` and `HI5` before the respective `D0` and `D1` defers
([same test](../tests/cases/exit-temporary-defer/main.ab)).

```abla fragment
loop()
log = log + "|"
// HI4D0HI5D1|
```

Nested scopes run their own defers in order, innermost first
([same test](../tests/cases/exit-temporary-defer/main.ab)).

```abla fragment
nested()
log = log + "|"
// HI2NO|
```

An inner argument block can defer before the enclosing statement's older
temporary is dropped: the checked trace is `NHI7O`
([same test](../tests/cases/exit-temporary-defer/main.ab)).

```abla fragment
nestedArgument()
log = log + "|"
// NHI7O|
```

**Refused transfers and escaping views.** The compiler does not allow moving an
affine field out of a fresh temporary owner. Binding it, returning it, passing
it to an `own` parameter or assigning it reports
`ownership.place-move-required`; an explicit `move` of that field reports
`ownership.place-owner` ([test](../tests/cases/drop-temporaries/affine-projection-refused.ab)).

```abla error
resource class Item
resource class Holder(val item: Item)
fun bind(): void { val x = Holder(Item()).item }
// error: ownership.place-move-required:local.x
```

Adding `move` does not make a temporary field a movable place
([same test](../tests/cases/drop-temporaries/affine-projection-refused.ab)).

```abla error
resource class Item
resource class Holder(val item: Item)
fun moved(): void { val x = move(Holder(Item()).item) }
// error: ownership.place-owner
```

A borrowed resource parameter cannot be returned as an owned result, even
when the function's result type is inferred
([test](../tests/cases/inferred-affine-return/function.ab)).

```abla error
resource class Item(val id: int) { fun drop(): void {} }
fun view(x: Item) = x
// error: ownership.borrow-escape
```

A borrowed result contract cannot name a defaulted parameter
(`ownership.borrow-return-source-default`); capturing a borrowed parameter in
a closure or task is `ownership.borrow-capture`, and storing one where it can
escape is `ownership.borrow-escape`
([tests](../tests/cases/default-temporary-owner/)). For example
([test](../tests/cases/default-temporary-owner/refused-return.ab)):

```abla error
resource class Item(val id: int)
resource class Holder(val item: Item)
fun view(x: Item = Holder(Item(1)).item): borrow(x) Item = x
// error: ownership.borrow-return-source-default
```

Capturing that borrowed default parameter in a suspended generator is refused;
the task form is checked too ([test](../tests/cases/default-temporary-owner/refused-capture.ab)).

```abla error
resource class Item(val id: int)
resource class Holder(val item: Item) { fun drop(): void {} }
fun produce(x: Item = Holder(Item(1)).item): Generator<int> = generator { yield x.id }
// error: ownership.borrow-capture
```

Storing it in an owning global array is refused
([test](../tests/cases/default-temporary-owner/refused-store.ab)).

```abla error
resource class Item(val id: int)
resource class Holder(val item: Item)
var stored: array<Item> = []
fun save(x: Item = Holder(Item(1)).item): void { stored.append(x) }
// error: ownership.borrow-escape
```

A managed field view of a temporary can currently be kept after the statement and observes its owner's
drop effects; do not assume it extends the temporary owner's lifetime.

These rules also apply to compile-time evaluation under `#`. There are still
known gaps: temporary resources passed through interface calls,
interface default bodies, and some built-in container methods can leak rather
than drop. Bind the resource to a `val` or transfer it to `own` instead.

## Collections of resources

An array of resources owns its elements. A loop's source determines who owns
each element:

- A fresh array or `move(array)` belongs to the loop. Each iteration takes
  its element: if the body does not consume it, it drops when that iteration
  ends. On `break` or `return`, the current element drops, then the remaining
  elements drop in array order. A full loop logging each item `B` and each
  drop `I` prints `B1I1B2I2|`; breaking after the first prints `B1I1I2|`.
- A borrowed array (a local, parameter, global, field, or index) stays with
  its owner. Its iterator is a borrow and cannot be moved or awaited. Its
  owner drops the elements later, so a full loop with the same markers prints
  `B1B2I1I2|` when the owner then leaves scope.
- An array borrowed from a temporary owner, such as `mapping().values()` or
  `Holder(items()).items`, is also borrowed by the loop. The temporary owner
  stays until the loop ends and then drops its elements once; the full-loop
  trace is `B1B2I1I2|`.

An `if` or `when` source follows the selected arm. If any arm may be borrowed,
the iterator must be treated as borrowed in the body: moving or awaiting it
is rejected, even if another arm is fresh. To transfer the elements, use a
fresh container or `move(...)` on the container. These rules apply in ordinary
functions and in generators, including across suspension
([test](../tests/cases/owned-container-loop/main.ab)).

For example, iterating over `move(array)` takes each element out:

```abla
import "abla/io"

resource class Ticket(val seat: int) {
    fun drop(): void {
        println("  release seat $seat")
        return
    }
}

fun refund(own ticket: Ticket): int = ticket.seat

fun main {
    val tickets = [Ticket(4), Ticket(5)]
    for (ticket in tickets) println("holds seat ${ticket.seat}")
    for (ticket in move(tickets)) println("refunded ${refund(move(ticket))}")
    println("done")
}
// output:
// holds seat 4
// holds seat 5
//   release seat 4
// refunded 4
//   release seat 5
// refunded 5
// done
```

In the first loop `ticket` is only borrowed, so it can't be given away. That
matters most for tasks, which are affine. `await` consumes its task, so it
needs the owning loop:

```abla
import "abla/io"

fun main {
    var jobs: array<Task<int>> = []
    for (i in 0 until 3) jobs.append(task { i * 2 })
    var total = 0
    for (job in move(jobs)) total += await job
    println("$total")
}
// output:
// 6
```

```abla error
fun main: int {
    val jobs: array<Task<int>> = []
    jobs.append(task { 2 })
    var total = 0
    for (job in jobs) total = total + await job
    total
}
// error: ownership.await-borrow:job
```

`await move(job)` inside the borrowing loop doesn't help either: a borrowed
loop element can't be moved (`move.local`).

Single elements can be moved out with a constant index, as with fields:
`move(tickets[0])` leaves only that slot empty. A computed index
(`tickets[i]`) is tracked as "some element", so after moving one out the
compiler treats every element as possibly moved until the array is replaced
or the slot reassigned. Replacing an element (`tickets[1] = Ticket(9)`)
drops the old one first.

A `Map` whose values are resources follows the same rules: `get` and
`values()` borrow (moving a `get` result out is `ownership.borrow-move`, an
element of `values()` `move.local`), and a borrowed value can't be held
across a change to the map (`E_BORROW_CONFLICT`). `set` drops the value it
replaces, `remove` drops the removed value, `clear` drops them all,
`take(key)` moves one out as a `V?`, and the map drops its remaining values
when it goes out of scope. The same holds at compile time.

## Borrowed views and `borrow(...)` results

`Shared<T>.get()` returns a *view* of the shared value: a reference the
compiler ties to its owner. A view may be read, passed to borrowing
parameters and kept in a `val`. It may not outlive its owner's use: the owner
can't be moved, replaced or changed while the view is still used later.

A function can return a view if its result type says which parameter it
comes from, with `borrow(parameterName)`, or `borrow(this)` in a method.
`Borrow<T>` spells a parameter or local that is such a view:

```abla
import "abla/io"

resource class Ticket(val seat: int)

fun view(owner: Shared<Ticket>): borrow(owner) Ticket = owner.get()
fun seatOf(ticket: Borrow<Ticket>): int = ticket.seat

fun main {
    val owner = Shared(Ticket(12))
    val ticket = view(owner)
    println("seat ${seatOf(ticket)}")
    val moved = move(owner)   // fine: `ticket` is not used after this
    println("moved")
}
// output:
// seat 12
// moved
```

Reading `ticket.seat` after `move(owner)` would be `E_BORROW_CONFLICT`.

Rules for views:

- A view can't be captured by a closure, stored in an object, an array or a
  global, returned without a `borrow(...)` contract, moved, or changed
  through (`ownership.borrow-capture`, `ownership.borrow-store`,
  `ownership.borrow-escape`, `ownership.borrow-mutation`).
- Copies of a view and fields read through it stay tied to the original
  owner, so they can't be used to launder the lifetime.
- `if` and `when` may choose between views only when every branch views the
  same owner (`ownership.borrow-source`).
- The parameter named in `borrow(name)` must be an ordinary (borrowed)
  parameter, not `own`, `var` or defaulted
  (`ownership.borrow-return-source-mode`,
  `ownership.borrow-return-source-default`). Every return path must really
  come from it (`ownership.borrow-return-source`).
- In a function type, the source is a zero-based parameter index:
  `(Shared<Ticket>) -> borrow(0) Ticket`.

`borrow(name) T` works on ordinary class and array results too. Every return
path must be a place rooted at `name` (a parameter, or `this` including a
field read by name in a method), a `for` variable over such a place, or a
new value (`ownership.borrow-return-source` otherwise). At the call, the
result is a view of the caller's argument or receiver:

```abla
import "abla/io"

class Counter(var value: int)

class Holder(val counter: Counter) {
    fun view(): borrow(this) Counter = counter
}

fun same(counter: Counter): borrow(counter) Counter = counter

fun increment(var counter: Counter): void {
    counter.value += 1
    return
}

fun main {
    val counter = Counter(10)
    val view = same(counter)
    val before = view.value
    increment(counter)   // fine: `view` is not used again
    val holder = Holder(Counter(20))
    println("$before ${counter.value} ${holder.view().value}")
}
// output:
// 10 11 20
```

Reading `view.value` after `increment(counter)` would be
`E_BORROW_CONFLICT: in main, counter is changed while view, which borrows
it, is still used afterwards`, with a note pointing where `view` borrows
`counter`.

The contract may be left out. When every return path of a class or array
result comes from one parameter or from `this` (or is a new object that
stores it, or a call that borrows from it), the compiler infers
`borrow(name)`: `fun same(counter: Counter): Counter = counter` and
`fun get(): Counter = counter` in a method behave as above. So does a
nullable result (`fun get(): Counter? = counter`, also a generic `T`
instantiated with a nullable class), where a `null` path has no source. A
result whose paths come from several sources keeps its declared type, and a
written contract is always kept as written.

A view of a global (`holder.get()` with `holder` a global) is as lasting as
the global, so a local holding it is an ordinary reference, as
`val c = holder.counter` is: it may be a `var`, and the global may change
while it is used.

A scalar or a string read through a view (`view.name`, `view.names[0]`) is
a value of its own, as one read through a parameter is: it joins a plain
string (`view?.name ?? "none"`, `if (f) view.name else ""`), may be
returned, and stays valid when the view's source changes. Inside a
`region { ... }` a string read through a view of a region's object stays a
view, because the region frees it ([regions](regions.md)).

## Sharing: `Cell`, `Shared`, `Weak`, `Mutex`

When one owner isn't enough, these wrappers make sharing explicit:

| Type | Gives you | Payload | Threads |
|---|---|---|---|
| `Cell<T>` | a mutable scalar inside an otherwise read-only object | copy scalars only | single thread |
| `Shared<T>` | several owners of one affine value; the last one drops it | affine types | thread-safe (atomic counts) |
| `Weak<T>` | an observer that doesn't keep the value alive | affine types | thread-safe |
| `Mutex<T>` | exclusive access to an affine value, under a lock | affine types | thread-safe |

`Cell` changes a value without a `var` parameter, because `set` replaces a
scalar rather than handing out a reference:

```abla
import "abla/io"

class Stats(val hits: Cell<int>)

fun record(stats: Stats): void {
    stats.hits.set(stats.hits.get() + 1)
    return
}

fun main {
    val stats = Stats(Cell(0))
    record(stats)
    record(stats)
    println("hits ${stats.hits.get()}")
}
// output:
// hits 2
```

`Shared` and `Weak` handles are affine themselves. Copying one is an error;
`clone()` makes a second strong handle, deliberately, so reference-count
traffic is always visible in the source:

```abla
import "abla/io"

resource class Connection(val id: int) {
    fun drop(): void {
        println("  connection $id closed")
        return
    }
}

fun describe(connection: Connection): string = "connection ${connection.id}"

fun main {
    val owner = Shared(Connection(7))
    val second = owner.clone()
    val observer = owner.downgrade()
    println(describe(owner.get()))
    val gone = move(owner)
    println("alive: ${observer.isAlive()}")
    val upgraded = observer.upgrade()     // Shared<Connection>?
    if (upgraded != null) println("upgraded: ${describe(upgraded.get())}")
    println("end of main")
}
// output:
// connection 7
// alive: true
// upgraded: connection 7
// end of main
//   connection 7 closed
```

- `Shared(value)` takes ownership: write `Shared(move(local))` for an
  existing binding.
- `get()` returns a [view](#borrowed-views-and-borrow-results).
- `downgrade()` makes a `Weak<T>` without keeping the value alive.
  `upgrade()` returns a new strong handle, or `null` when the value is gone.
  `isAlive()` only observes, without pinning the value.
- The last strong handle drops the payload, exactly once.

`Mutex<T>` holds its lock for the whole callback passed to `with`. The
callback is a named function with exactly one `var` parameter of the payload
type and a scalar result, so the exclusive reference can't escape the lock:

```abla
import "abla/io"

resource class Counter(var value: int)

fun increment(var counter: Counter): int {
    counter.value += 1
    counter.value
}

fun main {
    val state = Mutex(Counter(40))
    val other = state.clone()
    state.with(increment)
    println("${other.with(increment)}")
}
// output:
// 42
```

`Shared`, `Weak` and `Mutex` accept only affine payloads
(`shared.element-affine`, `mutex.element-affine`): ordinary classes and arrays
already alias freely, and wrapping them would promise a safety the language
can't enforce yet. `Cell` rejects managed and affine payloads
(`cell.element-copy`). `Mutex.with` rejects a lambda or a callback of the
wrong shape (`mutex.with.callback`, `mutex.with.callback-mode`).

## Closures and ownership

A closure captures variables, not values: a captured `var` is one shared
variable, so changes made inside the closure are visible outside and the
other way round. What a closure does with its captures decides its type:

| Type | The closure | How to accept one |
|---|---|---|
| `Fn(A) -> R` or `(A) -> R` | only reads its captures | an ordinary parameter |
| `FnMut(A) -> R` | changes a captured variable | a `var` parameter |
| `FnOnce(A) -> R` | consumes a captured resource (`move { ... }`) | an `own` parameter |
| `FnNoEscape(A) -> R` | is guaranteed not to keep its arguments | an ordinary parameter; required for region-owned values |

```abla
import "abla/io"

resource class Ticket(val seat: int) {
    fun drop(): void {
        println("  release seat $seat")
        return
    }
}

fun apply(callback: (int) -> int, value: int): int = callback(value)
fun twice(var callback: FnMut() -> int): int = callback() + callback()
fun finish(own callback: FnOnce() -> int): int = callback()

fun main {
    val offset = 10
    println("${apply({ x -> x + offset }, 5)}")
    var calls = 0
    val counted = { calls += 1; calls }
    println("${twice(counted)} after $calls calls")
    val ticket = Ticket(9)
    val useTicket = move { ticket.seat * 2 }
    println("${finish(move(useTicket))}")
}
// output:
// 15
// 3 after 2 calls
//   release seat 9
// 18
```

- The compiler infers `FnMut` when a closure assigns to a captured variable,
  and `FnOnce` for `move { ... }`. `FnMut` and `FnOnce` closures are affine:
  copying one is an error and passing one to `own` needs `move(...)`.
- An `Fn` can be passed where an `FnMut` is expected, not the other way round
  (`ownership.fnmut-parameter-mode`, `ownership.fnonce-parameter-mode`). A
  closure that assigns a captured local or changes an object it captured
  (a field, an element, a mutating method) is an `FnMut`, so passing it to
  `g: () -> int` is `function.argument:...:mut:function:()->i64`: declare
  the parameter `var g: FnMut() -> int`. A plain function type promises a
  value that can be copied and called from anywhere, which a closure
  changing its captures can't be.
- An ordinary `{ ... }` closure can't capture a resource
  (`ownership.capture-move-required`). `move { ... }` moves every affine
  variable it uses into the closure when the closure is created. Calling the
  closure moves them into its body, so they are dropped when the call ends.
  A `move` closure that is never called drops them when it goes away.
- A closure can't capture a borrowed view or a borrowed parameter
  (`ownership.borrow-capture`).
- An ordinary function satisfies `FnNoEscape` when the compiler can see that
  it doesn't keep its arguments. At a foreign or opaque boundary, write
  `noescape` explicitly. See [regions.md](regions.md).

## At compile time

The same checks run on code evaluated during compilation. Every function,
`compile fun` and method that can bind a borrow is checked before any `#`
expression runs, so a conflict in compile-time code is reported as
`E_BORROW_CONFLICT` in that function, exactly as at run time. Resources
used at compile time are dropped by the same rules, and `drop` runs at the
same points.

## Reading ownership diagnostics

Ownership errors are reported as `error[E_SEMANTIC]: <code>:<where>:<name>`,
followed by a `source[semantic]:<file>:<begin>:<end>` byte range and usually
a `help:` line. In `ownership.move-required:argument.function.consume:ticket`,
the code is `ownership.move-required`, the place is the argument of a call
to `consume`, and the value is `ticket`.

| Code | Meaning | Usual fix |
|---|---|---|
| `ownership.move-required` | A single-owner value is copied or passed to `own` without `move` | `move(name)`, or pass a fresh value |
| `ownership.borrow-mutation` | Changing an object reached through a borrowed parameter or an alias | make the parameter `var` |
| `ownership.mutable-borrow` | A `var` argument that isn't provably unique | pass a local, a field path, or a fresh value |
| `ownership.mutable-alias` | The same object reaches one call twice and one use changes it | pass different objects |
| `ownership.borrow-own-alias` | The same value is given away and borrowed in one call | pass different values |
| `ownership.borrow-escape` | A borrowed parameter or view is returned, stored or passed to `own` | take it as `own`, or build a new value |
| `ownership.borrow-store` | A borrowed value is stored where it would outlive the borrow | store the owner instead |
| `ownership.borrow-capture` | A closure captures a borrowed value | capture the owner or a copy |
| `ownership.borrow-mutable-local` | A borrow or alias is bound to a `var` | use `val` |
| `ownership.borrow-source` | `if`/`when` chooses between views of different owners | view one owner |
| `ownership.managed-return-borrow-contract` | A managed borrowed result has no valid inferred or explicit contract | declare `borrow(name) T`, or return a new object |
| `ownership.borrow-return-source` | A `borrow(name) T` result returns something not rooted at `name` | return a place of `name`, or a new value |
| `ownership.use-after-move`, `ownership.use-after-conditional-move`, `ownership.partial-move`, `ownership.once-called-again`, `assignment.unassigned` | See [resources](#resources-values-with-one-owner) | use the value before moving it, or assign it again |
| `ownership.capture-move-required` | A plain closure captures a resource | `move { ... }` |
| `ownership.fnmut-parameter-mode`, `ownership.fnonce-parameter-mode` | An `FnMut` passed to a non-`var` parameter, an `FnOnce` to a non-`own` one | fix the parameter mode |
| `ownership.await-borrow` | `await` on a borrowed task, such as a loop element | iterate over `move(array)` |
| `ownership.owned-parameter-type` | `own` on a type that isn't affine | drop `own` |
| `ownership.owned-constructor-parameter` | `own` on a constructor property | write `val`/`var` |
| `ownership.mutable-borrow-default`, `ownership.mutable-borrow-extern` | A `var` parameter with a default, or on an `extern` | remove it |
| `ownership.place-drop` | Moving a field out of a class with its own `drop` | move the whole object |
| `ownership.assignment-value` | Using an assignment's value when it is a resource (a function's result, a kept `if` branch, the last expression of a lambda whose function type expects a result): the place owns it now. A lambda with no known expected type isn't checked | write the value to a local first, or return the variable after assigning |
| `ownership.place-move-required` | Taking a resource field or element without `move` | `move(box.field)` |
| `move.local-or-place` | `move(...)` of something that isn't a local or a field/element path | move a local |
| `resource.drop-duplicate`, `resource.drop-signature` | A bad `drop` declaration | one `fun drop(): void` |
| `shared.element-affine`, `mutex.element-affine`, `cell.element-copy` | A wrapper with a payload it doesn't accept | see [sharing](#sharing-cell-shared-weak-mutex) |
| `E_BORROW_CONFLICT` | An owner is moved, replaced or changed while a view or alias of it is used later | finish using the view first |
| `E_DELEGATE_BORROW_CONFLICT` | A delegate is replaced while a `^name` view is used later | see [delegated bindings](language.md#delegated-bindings) |
