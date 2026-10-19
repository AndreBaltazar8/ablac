# Cleanup, generators, tasks and threads

This page covers code that doesn't run straight through from top to bottom:
cleanup that runs when a scope ends (`defer`), sequences produced on demand
(`generator`), cooperative coroutines (`task`) and operating-system threads
(`thread`).

- [`defer`](#defer)
- [Generators](#generators)
- [Tasks](#tasks)
- [Threads](#threads)
- [At compile time](#at-compile-time)
- [Diagnostics](#diagnostics)

Tasks and threads need a hosted target (Linux or macOS). Generators and
`defer` work everywhere.

## `defer`

`defer { ... }` registers cleanup that runs when the enclosing block ends,
however it ends: by falling through, or by `return`, `break` or `continue`.
Several registrations in one block run in reverse order, last registered
first, and before the block's resources are dropped.

```abla
import "abla/io"

fun process(items: array<string>): int {
    println("open")
    defer { println("close") }
    for (item in items) {
        defer { println("  done $item") }
        if (item == "skip") continue
        println("  handle $item")
    }
    if (items.size > 2) return items.size
    defer { println("only when small") }
    0
}

fun main {
    println("result ${process(["a", "skip"])}")
    println("result ${process(["a", "b", "c"])}")
}
// output:
// open
//   handle a
//   done a
//   done skip
// only when small
// close
// result 0
// open
//   handle a
//   done a
//   handle b
//   done b
//   handle c
//   done c
// close
// result 3
```

- A `defer` is registered when execution reaches it. The last one above is
  never reached on the `return items.size` path, so it doesn't run there.
- The body must be a block that produces `void` (`defer.result`); a final
  assignment such as `defer { depth -= 1 }` counts as a statement, as at the
  end of a `void` function. It can't `return`, `break` or `continue` out of
  itself (`defer.control`).
- A `defer` inside a loop body runs at the end of every iteration, including
  one cut short by `continue` or `break`.
- A panic ends the program without running pending `defer`s.

## Generators

A generator produces a sequence of values, one `yield` at a time, for a
`for` loop to consume. Its type is `Generator<T>`, where `T` is the type of
the yielded values:

```abla
import "abla/io"

fun countdown(from: int): Generator<int> = generator {
    var n = from
    while (n > 0) {
        yield n
        n -= 1
    }
}

fun evensUpTo(limit: int): Generator<int> = generator {
    for (i in 0..limit) if (i % 2 == 0) yield i
}

fun main {
    for (n in countdown(3)) println("$n")
    var sum = 0
    for (even in evensUpTo(10)) sum += even
    println("sum of evens: $sum")
}
// output:
// 3
// 2
// 1
// sum of evens: 30
```

- `yield value` gives one value to the consumer. `yield` takes the whole
  expression after it: `yield k * 10` yields `k * 10`.
- A generator body must contain at least one `yield` (`generator.empty`).
  `yield` outside a generator is `yield.outside-generator`.
- Yielded values can't be borrowed views or affine values (`yield.affine`).
  Every `yield` in one generator must have the same type (`yield.type`).
- A generator is single-pass: iterate over it once.
- Generators can be nested: a generator body may iterate another generator.

A generator is lazy. Creating one runs nothing; each time its `for` loop asks
for the next value, the body runs from where it stopped up to the next
`yield`, keeping its locals as they were. So the producer and the consumer
take turns, and a generator may go on forever, since its consumer decides
when to stop:

```abla
import "abla/io"

fun naturals(): Generator<int> = generator {
    defer { println("closed") }
    var n = 0
    while (true) {
        println("producing $n")
        yield n
        n += 1
    }
}

fun main {
    for (n in naturals()) {
        println("got $n")
        if (n == 1) break
    }
    println("done")
}
// output:
// producing 0
// got 0
// producing 1
// got 1
// closed
// done
```

- Leaving the loop early, by `break` or by `return` from inside it, closes
  the generator: its pending `defer`s run and what it owns is dropped, last
  first. Finishing the body does the same. A generator that is dropped
  without being iterated, or before it is finished, is closed when it is
  dropped.
- What a generator owns: affine values it captures, which move into it when
  it is created, and the affine locals of its body that are alive at a
  `yield`.
- `yield` is a statement of the generator's body: of a block, a branch of a
  statement `if` or `when`, or a loop body. It has no value, so it can't be
  part of an expression (`generator.yield-position`). It can't be inside a
  `region` either: while the generator waits at a `yield`, its consumer runs,
  and what the consumer allocates would land in the region and be freed with
  it.
- A generator is compiled into a resumable state machine (`src/generator.ab`),
  the same at run time, under `ablac run`, on WebAssembly and at compile
  time. A body's locals that live across a `yield` are kept in the
  generator, between steps, and a loop without a `yield` in it keeps its
  locals on the stack.

## Tasks

`task { ... }` creates a cooperative coroutine of type `Task<T>`, where `T`
is the body's result. It doesn't start yet. `await` runs it, waits for it
to finish and returns its result. A task runs on the current OS thread, and
awaiting a task from inside a task doesn't block that thread.

```abla
import "abla/io"

fun parse(text: string): int {
    println("  parsing $text")
    text.size
}

fun main {
    val first = task { parse("alpha") }
    val second = task { parse("be") }
    println("tasks created")
    val total = await first + await second
    println("total $total")
    val outer = task {
        val inner = task { parse("nested") }
        await inner * 10
    }
    println("${await outer}")
}
// output:
// tasks created
//   parsing alpha
//   parsing be
// total 7
//   parsing nested
// 60
```

- `await` binds tightly: `await first + await second` adds two results.
- A task is affine: `await` consumes it, and it can't be copied. To await
  tasks kept in an array, iterate over `move(array)`:
  `for (job in move(jobs)) total += await job`. Awaiting a borrowed element
  is `ownership.await-borrow`
  ([ownership.md](ownership.md#collections-of-resources)).
- `await` applies to a `Task` or a `Thread` (`await.type`).
- A task's result can't be a borrowed view or an affine value
  (`task.affine-result`).
- A panic inside a task ends the whole program at once, exactly as on the
  main thread: the message goes to standard error and the exit status is
  101. `await` doesn't catch it.

## Threads

`thread { ... }` starts an operating-system thread immediately and returns
a `Thread<T>`. `await` joins it and returns its result. A thread that goes
out of scope without being awaited is joined then, so no thread outlives
the scope that started it.

```abla
import "abla/io"

resource class Counter(var value: int)

fun addBatch(var counter: Counter): int {
    counter.value += 10
    counter.value
}

fun main {
    val state = Mutex(Counter(0))
    val forWorker = state.clone()
    val worker = thread { forWorker.with(addBatch) }
    val mine = state.with(addBatch)
    val theirs = await worker
    println("results add up to ${mine + theirs}")
    println("final value ${state.with(addBatch) - 10}")
}
// output:
// results add up to 30
// final value 20
```

Whichever thread takes the lock first sees 10 and the other sees 20, so the
two results always add up to 30.

A thread shares nothing by accident:

- A thread body may capture only `Shared<T>`, `Mutex<T>` and `Weak<T>`
  handles, which move into the thread. Clone the handle first if the parent
  needs it too (`thread.capture-type`).
- It can't assign to a captured variable (`thread.capture-mutation`) or name
  a mutable top-level `var` (`thread.mutable-global`).
- Every global it reaches, in its body or through the functions, methods and
  function values it calls, must be one no other thread can change: a `val`
  of a scalar, a string, a function, or a `Shared`, `Mutex` or `Weak`
  handle (or an optional one of those), or a compile-time value. A class
  instance, an array, a map or a `var` is `thread.shared-global:<name>`:
  wrap it in a `Mutex` (or `Shared`). The runtime's own globals are its
  business. A standard-library `val` marked `@threadShared` (abla/json's
  shared empty values, float text's tables) was reviewed as never changed
  once built, so threads share it; the annotation is accepted only in the
  standard library (`threadShared.library`) and only on a `val`
  (`threadShared.val`). A `task` runs on its starter's thread and is not
  checked.
- Its result can't be a borrowed view or an affine value.

A panic inside a thread also ends the whole process at once, with the
message on standard error and exit status 101; other threads don't keep
running, and `await` doesn't catch it.

```abla
import "abla/io"

fun main: int {
    println("starting")
    val worker = thread {
        val values = [1, 2, 3]
        values[7]            // panics on the worker thread
    }
    await worker
}
// output:
// starting
// exit: 101
```

The worker's reason, `panic: index 7 out of bounds for array of size 3`,
goes to standard error, the same for a task and under `ablac run`.

```abla error
fun main {
    var hits = 0
    val worker = thread { hits += 1 }
    await worker
}
// error: thread.capture-mutation
```

To share mutable state between threads, put it in a `Mutex`
([ownership.md](ownership.md#sharing-cell-shared-weak-mutex)).

## At compile time

`defer`, generators, tasks and `await` work at compile time, under `#`,
exactly as at run time: a generator is as lazy there, running the same state
machine. A generator, task or thread can't be the result of a `#`
expression ([compile-time.md](compile-time.md#expression)).

## Diagnostics

| Code | Meaning |
|---|---|
| `defer.result` | the `defer` body produces a value |
| `defer.control` | `return`, `break` or `continue` inside a `defer` body |
| `generator.empty` | a generator body with no `yield` |
| `generator.result` | a generator body whose last expression has a value |
| `generator.yield-position` | a `yield` inside an expression or a `region` |
| `generator.body`, `task.body`, `thread.body` | `generator`, `task` or `thread` without a `{ ... }` body |
| `yield.outside-generator` | `yield` outside a `generator { }` |
| `yield.type` | yields of different types in one generator |
| `yield.value` | a `yield` without a value |
| `yield.affine` | yielding an affine value or a borrowed view |
| `await.type` | `await` on something that isn't a `Task` or `Thread` |
| `ownership.await-borrow` | `await` on a borrowed task, such as a loop element |
| `task.affine-result`, `thread.affine-result` | a task or thread whose result is affine or borrowed |
| `await.operation` | `await` without an operand |
| `thread.capture-type` | a thread body captures something other than a `Shared`/`Mutex`/`Weak` handle |
| `thread.capture-mutation` | a thread body assigns to a captured variable |
| `thread.mutable-global` | a thread body names a mutable top-level `var` |
| `thread.shared-global:<name>@<offset>` | a thread reaches a global another thread may change or alias |
| `threadShared.library:<name>`, `threadShared.val:<name>` | `@threadShared` outside the standard library, or not on a `val` |
