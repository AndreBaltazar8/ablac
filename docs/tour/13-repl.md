# Trying ideas in the REPL

Run `ablac repl`, enter a function declaration, then an expression that calls
it. The session keeps definitions. `:help` lists commands, `:reset` clears the
session, and `:quit` ends it. Entries continue across lines while a bracket is
open. The equivalent complete program below prints the same answer.

[Session input](../../tests/cases/tour/repl.in) is a real fixture too:

```text
fun twice(n: int): int = n * 2
twice(21)
:quit
```

The function definition answers `defined`, the expression answers `42`, and
each prompt is `abla> `. `tools/test-tour.sh` checks that session's full stdout
and exit status. See [the toolchain reference](../toolchain.md) for the REPL's
platform behavior. To continue, use the [language reference](../language.md)
and [stdlib module index](../standard-library.md) to explore an API you need.

## Load declarations from a file

The live REPL on x86-64 Linux and macOS supports `:load <file>`. A load
adds the file's declarations. If the file defines `main`, the session
exposes it as `loadedMain()` for you to call. A failed load leaves your
session as it was. From the repository root, load the helper from the
modules chapter and call it:

```text source=repl-load.in
:load tests/cases/tour/pricing.ab
withTax(200, 20)
:quit
```

The call outputs `240`.

[Runnable source](../../tests/cases/tour/13-repl.ab):

```abla run source=../../tests/cases/tour/13-repl.ab
import "abla/io"

fun twice(n: int): int = n * 2

fun main {
    println("${twice(21)}")
}
// output:
// 42
```

[Previous](12-targets.md) · [Tour](README.md) · [Next](14-debugging.md)
