# Console, files, processes and time

| Import | What it gives you |
|---|---|
| `abla/io` | `print`, `println`, `eprint`, `eprintln`, line input, buffered writers |
| `abla/io/buffered` | a buffered file writer |
| `abla/fs` | `Path`: reading, writing, listing and watching files |
| `abla/process` | everything below in one import |
| `abla/process/arguments` | command-line arguments |
| `abla/process/environment` | environment variables |
| `abla/process/command` | running child processes |
| `abla/process/exit` | `exit` and `panic` |
| `abla/process/time` | clocks and `sleep` |
| `abla/process/supervisor` | supervised child processes with logs and process-tree termination |

These run on Linux and macOS. They talk to the kernel directly, without
libc. At compile time they are not available yet
([compile-time.md](../compile-time.md#what-works-at-compile-time-today)).

## Console: `abla/io`

```abla
import "abla/io"

fun main {
    print("no newline, ")
    println("then a newline")
    eprintln("this goes to standard error")
    val out = bufferedStandardOutput()
    for (i in 1..3) out.writeLine("buffered line $i")
    out.flush()
}
// output:
// no newline, then a newline
// buffered line 1
// buffered line 2
// buffered line 3
```

| Function | Effect |
|---|---|
| `print(text)`, `println(text = "")` | write to standard output |
| `eprint(text)`, `eprintln(text = "")` | write to standard error |
| `readInputLine()` | the next input line as `InputLine(text, available)`; `available` is `false` at end of input |
| `readLine()` | the next line, or `""` at end of input |
| `bufferedStandardOutput(capacity = 4096)`, `bufferedStandardError(...)` | a `BufferedTextWriter` |
| `writer.write(text)`, `writer.writeLine(text = "")`, `writer.flush()` | buffer text, and write it out; each returns `false` after a failure |
| `writer.pendingBytes()`, `writer.isHealthy()` | inspect it |
| `bufferedTextWriter(capacity, sink, initiallyFailed)` | a writer over any `(string) -> bool` sink |
| `bufferedFileWriter(path, capacity = 65536, append = false)` | from `abla/io/buffered`: a writer to a file |

A `BufferedTextWriter` is flushed when you call `flush()`, and when its
buffer fills.

## Files: `abla/fs`

```abla
import "abla/io"
import "abla/fs"
import "abla/text"

fun main {
    val dir = path("notes")
    dir.createDirectories()
    val file = dir.child("todo.txt")
    file.writeText("buy milk\n")
    file.appendText("write docs\n")
    println("${file.name()} ${file.extension()} exists=${file.exists()} size=${file.info().size}")
    for (line in file.readText().trim().split("\n")) println("- $line")
    for (entry in dir.entries()) println("entry ${entry.name()}")
    file.writeTextAtomic("done\n")
    print(file.readText())
    println("removed ${dir.removeTree()}, exists=${dir.exists()}")
}
// output:
// todo.txt txt exists=true size=20
// - buy milk
// - write docs
// entry todo.txt
// done
// removed true, exists=false
```

| Function | Result |
|---|---|
| `path(text)`, `Path(text)`, `currentDirectory()` | a `Path` |
| `p.child(name)`, `p.parent()`, `p.name()`, `p.extension()`, `p.text` | path arithmetic |
| `p.exists()`, `p.info()`, `p.revision()`, `p.isSymbolicLink()` | metadata. `FileInfo` has `size`, `kind`, `revision`, `exists()`, `isFile()`, `isDirectory()`, `modifiedMilliseconds()` |
| `p.readText()` | the whole file as a string |
| `p.writeText(text)`, `p.appendText(text)` | write or append; `bool` success |
| `p.writeTextAtomic(text)` | write a temporary file and rename it over `p`, so readers never see a partial file |
| `p.createDirectories()`, `p.createParentDirectories()` | `mkdir -p` |
| `p.entries()` | the entries of a directory, as `Path`s |
| `p.copyTo(destination)`, `p.copyTreeTo(destination)`, `p.moveTo(destination)` | copy a file, copy a tree (returns the number of files), move |
| `p.remove()`, `p.removeTree()` | delete a file or empty directory, or a whole tree |
| `watchFile(p)`, `watchFiles(paths)` | a `FileWatch`; `changed()` reports a change since the last `refresh()` |

Write operations return `false` on failure instead of stopping the program.
`readText()` returns `""` for a file that doesn't exist or can't be read, the
same as for an empty file, so check `exists()` (or `info().isFile()`) first
when the difference matters. A missing file's `info().size` is `-1`.

## Processes: `abla/process`

```abla
import "abla/io"
import "abla/process"
import "abla/process/environment"

fun main {
    println("${processArgumentCount()} arguments")
    println(processEnvironmentOr("ABLA_DOC_EXAMPLE_UNSET", "fallback"))
    val output = command("echo").argument("hello").argument("child").captureText()
    print(output)
    val status = command("sh").argument("-c").argument("exit 3").run()
    println("status $status")
    val start = monotonicMilliseconds()
    sleep(20)
    println("slept at least 20 ms: ${monotonicMilliseconds() - start >= 20}")
}
// output:
// 0 arguments
// fallback
// hello child
// status 3
// slept at least 20 ms: true
```

| Function | Result |
|---|---|
| `processArgumentCount()`, `processArgument(i)` | the program's arguments, not counting the program itself |
| `processExecutable()` | the program's path |
| `processEnvironment(name)` | `string?`: `null` when unset (from `abla/process/environment`) |
| `processEnvironmentOr(name, fallback)` | the value, or `fallback` |
| `command(executable)` | a `Command`, found on `PATH`; `.argument(value)` adds an argument and returns the command |
| `cmd.run()` | run it and wait; its exit status |
| `cmd.captureText()` | run it and wait; its standard output |
| `cmd.start()` | start it; a `ChildProcess`, with `stop(graceMilliseconds = 5000)` |
| `exit(code)` | end the program now (from `abla/process/exit`) |
| `panic(message)` | print the message and a stack trace, and exit with status 101 |

`ablac run file.ab -- a b` passes `a` and `b` as `processArgument(0)` and
`processArgument(1)`.

## Time: `abla/process/time`

| Function | Result |
|---|---|
| `monotonicMilliseconds()`, `monotonicNanoseconds()` | a clock that never goes backwards, for measuring durations |
| `realtimeMilliseconds()`, `realtimeNanoseconds()` | wall-clock time since 1970 |
| `utcNow()` | the current date as a `UtcDate` ([dates](security-and-dates.md#dates-abladate)) |
| `sleep(milliseconds)`, `sleepNanoseconds(nanoseconds)` | pause the thread |
| `monotonicClock()` | an affine `MonotonicClock` that reuses its buffers, for hot loops |
