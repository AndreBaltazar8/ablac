# Running code during compilation

Prefix an expression with `#` to evaluate it while compiling and lift its result
into the program. The ordinary function `square` can run at either phase;
`#square(6)` runs at compile time and `square(7)` is an ordinary runtime call.
A `compile fun` is only callable at compile time.

This does not grant arbitrary build-time access to the host. File, environment,
process and other effects require explicit capabilities, and evaluation is
bounded. Start with pure computations before adding build inputs. Libraries
and the language's type and ownership rules apply at both phases.

See [compile-time execution](../compile-time.md) for capabilities, limits and
which values can be lifted into the output program.

[Runnable source](../../tests/cases/tour/08-compile-time.ab):

```abla run source=../../tests/cases/tour/08-compile-time.ab
import "abla/io"

fun square(n: int): int = n * n
compile fun banner(name: string): string = "hello $name"

fun main {
    val frozen = #square(6)
    println("$frozen ${square(7)}")
    println(#banner("compiler"))
}
// output:
// 36 49
// hello compiler
```

[Previous](07-collections.md) · [Tour](README.md) · [Next](09-sub-languages.md)
