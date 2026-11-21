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

[Previous](02-values.md) · [Tour](README.md) · [Next](04-classes.md)
