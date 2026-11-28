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

## Sealed interfaces and `when`

A `sealed interface` lists all its classes in its own module, so a `when` with
an `is` arm for each class, and `null ->` for a nullable value, needs no
`else`. In an arm with one `is`, the value has that class's type
(`shape.side`). An arm can name several classes (`is Rectangle, is Dot`); there
the value keeps the interface's type, not null, so the arm calls what `Shape`
declares. Shared arms like this need v0.2.80 or a current source build. See
[interfaces](../language.md#interfaces).

[Runnable source](../../tests/cases/tour/04-sealed.ab):

```abla run source=../../tests/cases/tour/04-sealed.ab
import "abla/io"

sealed interface Shape {
    fun area(): int
}

class Square(val side: int) : Shape {
    fun area(): int = side * side
}
class Rectangle(val width: int, val height: int) : Shape {
    fun area(): int = width * height
}
class Dot : Shape {
    fun area(): int = 0
}

fun describe(shape: Shape?): string = when (shape) {
    is Square -> "square of side ${shape.side}"
    is Rectangle, is Dot -> "area ${shape.area()}"
    null -> "no shape"
}

fun main {
    println(describe(Square(3)))
    println(describe(Rectangle(2, 5)))
    println(describe(null))
}
// output:
// square of side 3
// area 10
// no shape
```

[Previous](03-functions.md) · [Tour](README.md) · [Next](05-ownership.md)
