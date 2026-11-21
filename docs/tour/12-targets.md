# Building for targets

A normal `ablac build` selects the host. Try this example as a native executable
with `ablac build targets.ab -o targets`. The test runs it on the current host;
that does not prove it runs on every platform.

The built-in `--target` names are `x86_64-linux`, `x86_64-macos` and
`arm64-macos`. Cross-linking requires the corresponding SDK and libraries.
Wasm, Android and iOS targets are registered by their build libraries; they
are not interchangeable built-in CLI aliases. Start with the platform's build
example rather than guessing a target name. Linux programs are libc-free by
default unless their dependencies require a C library; no opt-in flag is needed.

See [target selection and evidence](../targets.md),
[programmable builds](../programmable-builds.md),
[Wasm](../freestanding.md), and [iOS](../stdlib/ios-build.md).

[Runnable source](../../tests/cases/tour/12-targets.ab):

```abla run source=../../tests/cases/tour/12-targets.ab
import "abla/io"

fun main {
    println("Built for the selected host target")
}
// output:
// Built for the selected host target
```

[Previous](11-concurrency.md) · [Tour](README.md) · [Next](13-repl.md)
