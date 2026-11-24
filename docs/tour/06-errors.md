# Handling expected failures

Represent an expected absence with a nullable result. Check for `null` before
using the value, or supply a fallback with `??`. Here `divide` returns null
before dividing by zero. In `showAnswer`, `?? return` leaves the function
when the result is absent. On the next line, `result` has type `int`.
Inside a loop, use `?? continue` to skip an item or `?? break` to end the loop.
Use a separate `if` when the missing case needs its own work.

For richer failures, define a result class or interface carrying the value and
error information. Check each API's contract: some functions return nullable
values, others return a result object. There is no general exception/catch
mechanism to rely on. `panic` terminates the program with status 101; it is not
a recoverable error value and does not run pending `defer` cleanup.

See [nullable types](../language.md#nullable-types),
[diagnostics](../diagnostics.md), and [debugging](../debugging.md).

[Runnable source](../../tests/cases/tour/06-errors.ab):

```abla run source=../../tests/cases/tour/06-errors.ab
import "abla/io"

fun divide(numerator: int, denominator: int): int? {
    if (denominator == 0) return null
    numerator / denominator
}

fun showAnswer(numerator: int, denominator: int): void {
    val result = divide(numerator, denominator) ?? return
    println("answer $result")
}

fun main {
    showAnswer(12, 3)
    showAnswer(12, 0)
    val missing = divide(12, 0)
    println("fallback ${missing ?? -1}")
}
// output:
// answer 4
// fallback -1
```

[Previous](05-ownership.md) · [Tour](README.md) · [Next](07-collections.md)
