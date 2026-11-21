# Classes and interfaces

A class lists constructor properties as `val` or `var`. Methods can refer to
those properties. An interface declares operations; the class explicitly
names the interfaces it implements after `:`. Merely having matching method
names does not make a class conform.

`describe` accepts any `Shape`, so it can work with other shapes without
knowing their concrete class. The interface call selects the implementation
of the actual value passed in.

See [classes](../language.md#classes) and
[interfaces](../language.md#interfaces).

[Runnable source](../../tests/cases/tour/04-classes.ab):

```abla run source=../../tests/cases/tour/04-classes.ab
import "abla/io"

interface Shape {
    fun area(): int
}

class Rectangle(val width: int, val height: int) : Shape {
    fun area(): int = width * height
}

fun describe(shape: Shape): string = "area ${shape.area()}"

fun main {
    val rectangle = Rectangle(3, 4)
    println(describe(rectangle))
}
// output:
// area 12
```

[Previous](03-functions.md) · [Tour](README.md) · [Next](05-ownership.md)
