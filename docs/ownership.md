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
  method changes its receiver (`this`), including through fields of fields,
  and then treats the receiver as a `var` argument.

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

A function may return an object it created, or the result of a function
that does. That includes constructor calls, literals, a local `val` built up
in the function, and `if`/`when` whose every branch is such a value:

```abla fragment
fun fresh(start: int): Counter = Counter(start)     // fine
fun same(counter: Counter): Counter = counter       // rejected
```

Returning a parameter or `this` as an ordinary result is rejected
(`ownership.managed-return-borrow-contract`): the caller would get a second,
unchecked name for its own object. Return a new object built from it
instead, or return nothing and let the caller keep using its own reference.
A method that changes its receiver should return `void`, not `this`.

> Known issues (being fixed by ct-own): returning a top-level `val` (`fun current(): Counter =
> shared`) is currently accepted, although it creates the same kind of
> alias. The help text for `ownership.managed-return-borrow-contract` says a
> parameter may be returned, but returning one is exactly what it rejects.

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
- One call can't both give a value away and borrow it: `inspect(t, move(t))`
  is `ownership.borrow-own-alias`.
- A constructor property can't be spelled `own`: storing an affine value in
  a `val`/`var` property already transfers it
  (`ownership.owned-constructor-parameter`).

> Known issue (being fixed by ct-own): a mistake that the control-flow check finds (a use after
> `move`, a double `move`, a move on only one branch, reading a partly moved
> owner, a second call of a `FnOnce`) is currently reported as
> `E_IR_FUNCTION_VERIFICATION: function main violated a typed IR invariant`,
> without the variable's name or position.

## Collections of resources

An array of resources owns its elements. Iterating over it borrows each
element; iterating over `move(array)` takes each element out:

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

`borrow(...)` contracts currently apply to `Shared<T>` views. Ordinary class
results follow the [returning references](#returning-references) rules
instead.

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
  (`ownership.fnmut-parameter-mode`, `ownership.fnonce-parameter-mode`).
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
| `ownership.managed-return-borrow-contract` | A parameter or `this` is returned as an ordinary result | return a new object |
| `ownership.capture-move-required` | A plain closure captures a resource | `move { ... }` |
| `ownership.fnmut-parameter-mode`, `ownership.fnonce-parameter-mode` | An `FnMut` passed to a non-`var` parameter, an `FnOnce` to a non-`own` one | fix the parameter mode |
| `ownership.await-borrow` | `await` on a borrowed task, such as a loop element | iterate over `move(array)` |
| `ownership.owned-parameter-type` | `own` on a type that isn't affine | drop `own` |
| `ownership.owned-constructor-parameter` | `own` on a constructor property | write `val`/`var` |
| `ownership.mutable-borrow-default`, `ownership.mutable-borrow-extern` | A `var` parameter with a default, or on an `extern` | remove it |
| `ownership.place-drop` | Moving a field out of a class with its own `drop` | move the whole object |
| `ownership.place-move-required` | Taking a resource field or element without `move` | `move(box.field)` |
| `move.local-or-place` | `move(...)` of something that isn't a local or a field/element path | move a local |
| `resource.drop-duplicate`, `resource.drop-signature` | A bad `drop` declaration | one `fun drop(): void` |
| `shared.element-affine`, `mutex.element-affine`, `cell.element-copy` | A wrapper with a payload it doesn't accept | see [sharing](#sharing-cell-shared-weak-mutex) |
| `E_BORROW_CONFLICT` | An owner is moved, replaced or changed while a view or alias of it is used later | finish using the view first |
| `E_DELEGATE_BORROW_CONFLICT` | A delegate is replaced while a `^name` view is used later | see [delegated bindings](language.md#delegated-bindings) |
