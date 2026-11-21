# Ownership and resources

A `resource class` has one owner responsible for cleanup. Borrowing a resource
as an ordinary parameter lets the callee inspect it without taking ownership.
An `own` parameter takes it; `move(ticket)` transfers ownership and prevents
later use of the old binding. Cleanup calls `drop()` when the owner ends.

Here `inspect` borrows the ticket. `consume` owns it, so cleanup happens before
control returns to `main`. For ordinary objects passed to a function, a `var`
parameter is required when the callee mutates through that parameter. Do not
replace these rules with a general assumption that all objects are immutable.

See [ownership](../ownership.md) for borrowing, mutation, moved values and
resource containers, and [cleanup](../concurrency.md#defer) for `defer`.

[Runnable source](../../tests/cases/tour/05-ownership.ab):

```abla run source=../../tests/cases/tour/05-ownership.ab
import "abla/io"

resource class Ticket(val number: int) {
    fun drop(): void {
        println("closed $number")
        return
    }
}

fun inspect(ticket: Ticket): int = ticket.number
fun consume(own ticket: Ticket): void {
    println("consumed ${ticket.number}")
    return
}

fun main {
    val ticket = Ticket(7)
    println("borrowed ${inspect(ticket)}")
    consume(move(ticket))
    println("done")
}
// output:
// borrowed 7
// consumed 7
// closed 7
// done
```

[Previous](04-classes.md) · [Tour](README.md) · [Next](06-errors.md)
