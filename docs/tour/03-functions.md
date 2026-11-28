# Functions and control flow

Parameters and return types follow `:`. An expression body uses `=`; a block
returns its last expression, while `return` leaves early. Named arguments can
be written in a different order. Omitted arguments use the declared defaults.

`if` is an expression: both branches below produce a string. `1..3` includes
both ends; `0 until 3` would stop before 3. A loop can accumulate into a `var`.
Use `when` for several alternatives as programs grow.

See [functions](../language.md#functions) and
[control flow](../language.md#control-flow).

[Runnable source](../../tests/cases/tour/03-functions.ab):

```abla run source=../../tests/cases/tour/03-functions.ab
import "abla/io"

fun price(quantity: int, unit: int = 5): int = quantity * unit

fun label(value: int): string {
    if (value == 0) return "empty"
    if (value < 10) "small" else "large"
}

fun main {
    println("${price(3)} ${price(unit = 7, quantity = 2)}")
    var total = 0
    for (n in 1..3) total += n
    println("$total is ${label(total)}")
}
// output:
// 15 14
// 6 is small
```

## Updating a flag: `&&=` and `||=`

`ready &&= check()` keeps `ready` true only while every check passes, and it
calls `check()` only while `ready` is still true: once the network check fails,
the printer is never checked. `warned ||= cond` sets a flag once a condition
holds. See [operators](../language.md#expressions-and-operators).

[Runnable source](../../tests/cases/tour/03-logical.ab):

```abla run source=../../tests/cases/tour/03-logical.ab
import "abla/io"

fun check(name: string, ok: bool): bool {
    println("checking $name")
    ok
}

fun main {
    var ready = true
    ready &&= check("disk", true)
    ready &&= check("network", false)
    ready &&= check("printer", true)
    var warned = false
    warned ||= !ready
    println("ready $ready, warned $warned")
}
// output:
// checking disk
// checking network
// ready false, warned true
```

[Previous](02-values.md) · [Tour](README.md) · [Next](04-classes.md)
