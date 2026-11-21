# Tasks and threads

`task { ... }` creates a cooperative coroutine; `await` drives it to completion
and obtains its result. It does not imply another processor is running it.
`thread { ... }` starts an operating-system thread; awaiting it joins the
thread and obtains its result. Both require a hosted target.

The example shares no mutable state. To share state between threads, use
`Shared`, `Mutex` and `Weak` according to the ownership rules; an ordinary
mutable object cannot simply be captured and changed by several threads.
Printing after each `await` gives this program a deterministic output order.

See [tasks and threads](../concurrency.md) for cancellation, capture rules and
synchronization, and [ownership](../ownership.md) for shared handles.

[Runnable source](../../tests/cases/tour/11-concurrency.ab):

```abla run source=../../tests/cases/tour/11-concurrency.ab
import "abla/io"

fun main {
    val cooperative = task { 20 + 22 }
    println("task ${await cooperative}")
    val worker = thread { 6 * 7 }
    println("thread ${await worker}")
}
// output:
// task 42
// thread 42
```

[Previous](10-modules.md) · [Tour](README.md) · [Next](12-targets.md)
