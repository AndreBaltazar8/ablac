# Values and types

Use `val` for a binding assigned once and `var` for a binding you reassign.
The compiler infers the type from the initializer, or you can write it after
`:`. Here the inferred type of `count` is `int`. `string` holds text and `bool`
holds `true` or `false`. String templates embed `$name` or `${expression}`.

`int?` may hold an integer or `null`. `a ?? b` evaluates `b` only when `a` is
null. A `val` binding does not by itself freeze the object it refers to; the
ownership chapter explains mutation and borrowing.

See [types](../language.md#types) and the [text API](../stdlib/text.md).

[Runnable source](../../tests/cases/tour/02-values.ab):

```abla run source=../../tests/cases/tour/02-values.ab
import "abla/io"

fun main {
    val name: string = "Ada"
    var count = 2
    count += 1
    val active: bool = count > 0
    val optional: int? = null
    println("$name: $count, active=$active")
    println("fallback: ${optional ?? 10}")
}
// output:
// Ada: 3, active=true
// fallback: 10
```

[Previous](01-hello.md) · [Tour](README.md) · [Next](03-functions.md)
