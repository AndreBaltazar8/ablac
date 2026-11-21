# Hello, Abla

`fun main` is the entry point. `import "abla/io"` makes `println` available;
printing is a library operation. A main without a result type exits with status
zero. A main returning `int` uses that value as its exit status.

Save the example as `hello.ab`, then run `ablac run hello.ab`. Or build it with
`ablac build hello.ab -o hello` and run `./hello`. In this repository, use
`build/ablac` in place of an installed `ablac`.

The `// output:` comments state exactly what the example prints. They are also
the documentation tests' expected output, not extra instructions to execute.
See [programs](../language.md#programs) and [I/O modules](../standard-library.md).

[Runnable source](../../tests/cases/tour/01-hello.ab):

```abla run source=../../tests/cases/tour/01-hello.ab
import "abla/io"

fun main {
    println("Hello, Abla!")
}
// output:
// Hello, Abla!
```

[Previous](00-install.md) · [Tour](README.md) · [Next](02-values.md)
