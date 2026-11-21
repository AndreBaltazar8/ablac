# Arrays and maps

An `array<T>` grows with `append`, has a `size`, and supports iteration. A
`Map<K, V>` associates keys with values; `get` returns a nullable value because
the key might not exist. Explicit type arguments keep an empty map's intended
key and value types clear.

The example uses integer values so iteration and map storage copy those values.
Resources and borrowed views have additional ownership rules; do not assume
that copying an integer and transferring a resource are the same operation.

See [arrays](../language.md#arrays), [maps](../language.md#maps), and
[array operations](../stdlib/arrays.md).

[Runnable source](../../tests/cases/tour/07-collections.ab):

```abla run source=../../tests/cases/tour/07-collections.ab
import "abla/io"

fun main {
    val numbers = [2, 3]
    numbers.append(5)
    var sum = 0
    for (n in numbers) sum += n
    val counts: Map<string, int> = Map()
    counts.set("sum", sum)
    println("${numbers.size} items, sum ${counts.get("sum") ?? 0}")
    println("absent ${counts.get("absent") ?? -1}")
}
// output:
// 3 items, sum 10
// absent -1
```

[Previous](06-errors.md) · [Tour](README.md) · [Next](08-compile-time.md)
