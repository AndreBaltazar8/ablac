# Debug an Abla program

When the compiler rejects a program, start with the source span it reports
and use the [diagnostics reference](../diagnostics.md) to look up the code.
Once a program builds, a debugger can stop it at an Abla source line so you
can inspect its state.

Save this example as `debug-total.ab`.

[Runnable source](../../tests/cases/tour/14-debugging.ab).

```abla run source=../../tests/cases/tour/14-debugging.ab
import "abla/io"

fun total(price: int, quantity: int): int {
    val amount = price * quantity
    return amount
}

fun main {
    println("Total: ${total(7, 6)}")
}
// output:
// Total: 42
```

Build the executable with development settings and debug information. Run
these commands from the directory where you saved the file.

```sh
ablac build debug-total.ab --fast -g -o debug-total
./debug-total
```

The program prints `Total: 42`. Keep the debug object beside the executable,
especially on macOS. For GDB, start `gdb ./debug-total`, enter
`break debug-total.ab:5` and `run`, then use `info args` and `print amount`.
For LLDB, start `lldb ./debug-total`, enter
`breakpoint set -f debug-total.ab -l 5` and `run`, then use
`frame variable price quantity amount`. Inspect `amount` at the return line to see `42`. Development builds still
optimize some code, so a debugger can report an input as `<optimized out>`
after its last use.

In VS Code, configure a native GDB or LLDB launch adapter to run the same
executable, using the build directory as its working directory. Open
`debug-total.ab`, set a breakpoint on the return line, start debugging, then
look in Variables. The Abla editor language service and the native debug
adapter handle different tasks.

A release build with `-g` has source lines but omits the development
build's variable descriptions. See [debugging](../debugging.md) for DWARF,
crash stacks, WebAssembly source maps and debugger source-path mapping.

[Previous](13-repl.md) · [Tour](README.md)
