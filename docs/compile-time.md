# Compile-time execution

Abla code can run while the program is being compiled. It is the same
language, type checker and standard library as at run time: a function you
call at run time can also be called during compilation, and what it returns
becomes part of the compiled program. This page covers how to run code at
compile time and what that code may do.

- [`#expression`](#expression)
- [`compile fun`](#compile-fun)
- [Top-level actions](#top-level-actions)
- [`compile val` and `compile var`](#compile-val-and-compile-var)
- [Ordinary globals at compile time](#ordinary-globals-at-compile-time)
- [Capabilities: files, environment, processes, network](#capabilities-files-environment-processes-network)
- [Limits](#limits)
- [Declaration blocks](#declaration-blocks)
- [What works at compile time today](#what-works-at-compile-time-today)
- [How a compilation runs](#how-a-compilation-runs)
- [Diagnostics](#diagnostics)

Related pages: [compiler-api.md](compiler-api.md) (reflection, transforms,
generated code), [subparsers.md](subparsers.md) (`$name` syntax handlers),
[programmable-builds.md](programmable-builds.md) (building other programs).

## `#expression`

Prefix an expression with `#` to evaluate it during compilation. The result
is stored in the program as a constant:

```abla
import "abla/io"

class Entry(val name: string, val code: int)

fun fib(n: int): int = if (n < 2) n else fib(n - 1) + fib(n - 2)

fun table(): array<Entry> {
    val entries: array<Entry> = []
    for (i in 1..3) entries.append(Entry("item$i", fib(i * 5)))
    entries
}

val entries = #table()

fun main {
    for (entry in entries) println("${entry.name} = ${entry.code}")
    println("${#fib(20) + 1}")
}
// output:
// item1 = 5
// item2 = 55
// item3 = 610
// 6766
```

`fib(20)` runs once, inside the compiler. The program only contains the
number. `table()` is an ordinary function: the program could call it at run
time too, and here it runs at compile time because of the `#`.

Things to know about `#`:

- **It binds tightly.** `#` applies to the operand right after it, including
  that operand's calls, member accesses and indexes. `#fib(20) + 1` means
  `(#fib(20)) + 1`, and `#config.items[0]` evaluates the whole chain. Use
  parentheses for anything larger: `#(a() + b())`.
- **It runs once per build**, not once per execution. A `#` inside a function
  body or a loop is still one constant.
- **It sees declarations, not the surrounding function.** The expression is
  evaluated with the program's top-level declarations in scope. It cannot
  read the parameters or locals of the function it appears in, because
  those don't exist yet.
- **Its result becomes a program value.** Integers of every width, `bool`,
  `string`, `f32`, `f64` (bit for bit, NaN payloads included), `null`,
  arrays, `Map`s, `Cell`s, class objects (shared references and cycles are
  rebuilt as such) and `Json` all work. So do closures: the compiler
  rebuilds the function around constants holding what it captured. The
  program gets fresh values, which it may change like any others. A value
  that only makes sense inside the compiler is rejected with its type and
  the reason (`compile.result`): generators, tasks, threads, borrowed views,
  `Weak` handles, raw pointers, and objects of a class with `drop()` (also
  when reached through a field).

```abla
import "abla/io"

fun greeter(greeting: string): (string) -> string = { name: string -> "$greeting, $name!" }

fun counter(): FnMut() -> int {
    var n = 0
    return { n += 1; n }
}

fun main {
    val greet = #greeter("Hello")
    println(greet("compile time"))
    val next = #counter()          // `n` starts at 0 in the program
    println("${next()} ${next()}")
}
// output:
// Hello, compile time!
// 1 2
```

```abla error
fun numbers(): Generator<int> = generator { yield 1 }

fun main: int {
    val values = #numbers()
    0
}
// error: compile.result: `Generator<int>` cannot become a program value
```

```abla error
fun main: int {
    val n = 4
    #(n * 2)
}
// error: compile.runtime-local:n
```

A `#` expression runs while the program is compiled, before any of the
run-time code around it: reading one of that code's locals is
`compile.runtime-local:<name>`.

## `compile fun`

A `compile fun` exists only during compilation. Use it for code that only
makes sense there: code that reflects on the program, generates code,
registers syntax, or uses compile-time capabilities.

```abla
import "abla/io"

compile fun squares(count: int): array<int> {
    val result: array<int> = []
    for (i in 1..count) result.append(i * i)
    result
}

fun main {
    val table = #squares(5)
    println("${table[4]}")
}
// output:
// 25
```

A `compile fun` can be called from `#` expressions, from other compile-time
code, and by the compiler as a [subparser](subparsers.md) handler, extension
finalizer or [transform](compiler-api.md). An ordinary function is available
in both phases. A function that reaches a platform facility with no
compile-time implementation (see [below](#what-works-at-compile-time-today))
fails when it is evaluated at compile time.

Calling a `compile fun` from run-time code is `compile.call-runtime:<name>`;
reach it through `#`:

```abla error
compile fun twice(x: int): int = x * 2

fun main: int = twice(21)
// error: compile.call-runtime:twice
```

## Top-level actions

A `#expression` on its own at the top level of a module is an *action*. It
runs for its effect, and its result is discarded:

```abla
import "abla/io"

class RouteTable(val paths: array<string>)

compile val routeTable = RouteTable([])

compile fun route(path: string): void {
    routeTable.paths.append(path)
    return
}

compile fun describeRoutes(): string {
    var text = ""
    for (path in routeTable.paths) text = "$text $path"
    "${routeTable.paths.size} routes:$text"
}

#route("/users")
#route("/orders")

fun main {
    println(#describeRoutes())
}
// output:
// 2 routes: /users /orders
```

Actions run in source order, after the whole program has passed semantic
analysis. Each runs as its own evaluation, so state only carries from one to
the next through a [`compile val`](#compile-val-and-compile-var), as above.

Four actions are recognized from their literal source form, because the
compiler needs them before it can evaluate anything:

| Action | Effect |
|---|---|
| `#compilerGrant("capability")` | requests a [capability](#capabilities-files-environment-processes-network) for this module |
| `#compilerRegisterSubparser("name", handler)` | registers a `$name` [subparser](subparsers.md) |
| `#compilerGenerateModule("namespace", "source")` | adds a generated module to the program |
| `#compiler.transform(handler)` | runs a [transform](compiler-api.md) over the program |

Grants and subparser registrations take effect only as literal top-level
actions: a grant stays visible in source, and subparsers are registered
before any compile-time code runs. Called from compile-time code, they fail
with `E_COMPILE_GRANT_PHASE` and `E_EXT_SUBPARSER_REGISTRATION`.
`compilerGenerateModule` (and `compiler.generateModule`) also works from
compile-time code that a `compiler.transform` handler runs, because
transforms run before the program is analyzed:

```abla
import "abla/compiler"

compile fun configure(): void {
    compiler.generateModule("answer", "fun generatedAnswer(): int = 42\n")
    return
}

#compiler.transform(configure)

fun main: int = generatedAnswer()
// exit: 42
```

Anywhere later (a top-level action, a `#` expression), the program has
already been analyzed, and the call fails with
`E_EXT_GENERATED_MODULE_PHASE`.

An action that runs code (anything other than the literal actions above,
except a transform) disables the whole-program native object cache for that
build. Every build then runs it
again.

## `compile val` and `compile var`

A compile-time global holds one value for the whole compilation. The first
reference evaluates its initializer. After that, every evaluation sees the
latest value: `#` expressions, top-level actions, subparser handlers,
finalizers and transforms, in every module of the compilation.

```abla
import "abla/io"

compile var builds = 0

compile fun nextId(): int {
    builds += 1
    builds
}

val first = #nextId()
val second = #nextId()

fun main {
    println("$first $second ${#nextId()}")
}
// output:
// 1 2 3
```

- Run-time code can't read a compile-time global (`compile.value-runtime`).
  Copy what you need into the program with `#`.
- Between evaluations the value is kept whole: data, objects (shared
  references and cycles stay as they are) and closures with what they
  captured. A global that holds something that exists only while one
  evaluation runs (a generator, a task) is evaluated afresh for each
  evaluation.
- A module that the native object cache skips runs no handlers. A provider
  that collects from its uses should be built with `--no-cache`.


## Ordinary globals at compile time

A top-level `val` or `var` without `compile` belongs to the run-time
program. Compile-time code reads and changes it as it would a `compile var`:
it holds one value for the whole compilation, made by its initializer the
first time compile-time code reads it, and what one evaluation changes
through it (or assigns to a `var`) is what the next one sees. The program
itself still starts from the initializer; nothing compile-time code does
leaks into it.

```abla
import "abla/io"

class Box(var n: int)

val box = Box(1)
var count = 0

fun bump(): int {
    box.n += 1
    count += 1
    box.n * 10 + count
}

fun main {
    println("${#bump()} ${#bump()}")
    println("${bump()} ${bump()}")
}
// output:
// 21 32
// 21 32
```

An initializer reads the other globals' initial values, as the program
initializes every global before code changes any: `val doubled = count * 2`
read after `count` changed still starts from `count`'s initializer. Between
evaluations the values are kept as data (integers, booleans, strings, null,
arrays and objects, without cycles); a global holding anything else is made
afresh by the next evaluation.

## Capabilities: files, environment, processes, network

Compile-time code runs inside the compiler, so anything it can reach is
reachable by everyone who builds the program. Ambient access is therefore
denied by default. A capability needs two things:

1. the project authorizes it, in `compileCapabilities` of the nearest
   `abla.toml` at or above the entry module's directory, and
2. the module requests it in source, with a top-level
   `#compilerGrant("name")` action.

```toml file=abla.toml
compileCapabilities = ["filesystem.read"]
```

```text file=greeting.txt
hello from a file
```

A file is read at compile time with the same `abla/fs` API as at run time,
under the `filesystem.read` grant:

```abla
import "abla/io"
import "abla/fs"
import "abla/compiler"

#compilerGrant("filesystem.read")

val greeting = #path("greeting.txt").readText()

fun main {
    print(greeting)
}
// output:
// hello from a file
```

Without the grant, the build stops with `compile.effect-denied:filesystem.read`.
Without the manifest entry, it stops with `compile.capability-not-authorized:filesystem.read`.
In a package, a dependency's `compileCapabilities` must be a subset of the
root project's (`E_PACKAGE_CAPABILITY_DENIED`).

The compiler works out which capabilities each function needs, transitively.
The error names the whole call path, as in
`compile.effect-denied:environment:readBuildEnvironment->compilerEnvironment`.
The check happens before evaluation starts, so a denied path never runs.

| Capability | What it allows | Providers | Native object cache |
|---|---|---|---|
| `filesystem.read` | read files, list directories, file metadata | `abla/fs`: `p.readText()`, `p.readTextResult()`, `p.exists()`, `p.info()`, `p.revision()`, `p.isSymbolicLink()`, `p.entries()`, `currentDirectory()` (the internal `ablaHostReadFile`/`ablaHostListDirectory` too) | kept: each read is journaled and revalidated, a failed one too |
| `filesystem.write` | stage output files, directories, moves and removals, published only if the build succeeds | `compilerWriteFile(path, contents)`; `abla/fs`: `p.writeText()`, `p.writeTextAtomic()`, `p.appendText()`, `p.createDirectories()`, `p.createParentDirectories()`, `p.moveTo(destination)`, `p.remove()` | disabled |
| `environment` | read named environment variables | `compilerEnvironment(name)` (`""` when unset) | kept: each value is journaled and revalidated |
| `process.io` | run a child process | `compilerRunProcess(arguments)` | disabled |
| `network` | one TCP request/response | `compilerTcpExchange(ipv4, port, request, maxBytes, timeoutMs)` | disabled |
| `clock` | read the clocks, sleep | `compilerClockMilliseconds()`; `abla/process/time`'s `sleep`, `monotonicMilliseconds()`, `realtimeMilliseconds()` and their nanosecond forms | disabled |
| `random` | random integers | `compilerRandomInteger(maxExclusive)` | disabled |
| `trusted.native` | run trusted and `extern` code (raw memory, C functions, system calls) | see [below](#what-works-at-compile-time-today) | disabled |

The `compiler*` providers come from `import "abla/compiler"`. File paths are
relative to the directory the compiler runs in.

Under `#`, the `abla/fs` writes, moves and removals are staged exactly like
`compilerWriteFile`: nothing touches the disk until the build succeeds, then
the staging is published in the order it happened (each file written with its
directories made as needed, each directory made, each moved or removed path
deleted); a failed build publishes nothing. The same bounds apply, and paths
must be project-relative.

Until then, compile-time code sees the disk with the staging laid over it,
which is what the program sees after the same operations at run time:

- a staged file reads back with its staged contents (`readText`,
  `readTextResult`, `exists`, `info`), and `appendText` appends to them;
- each staged change is a new `revision()`, so `watchFile` sees a staged
  rewrite;
- a write makes its parent directories, as at run time, and `entries()` lists
  what was staged in a directory along with what is on disk;
- `remove()` and `moveTo()` act on staged and disk paths alike: a removed path
  is gone, and a directory with something in it is not removed.

Another process (one started under `process.io`) sees only the disk, so a
file the build has staged isn't there for it yet. `removeTree()` asks what a
path is without following links, which is native code (`trusted.native`).

`print`, `println`, `eprint` and `eprintln` need no capability: under `#` they
write to the compiler's own standard output and error. What a compilation
prints is not an input of the build, so it changes neither the program nor
whether a cached build is reused (a cached build just doesn't print again,
like a warning). Reading standard input (`readLine`) needs `process.io`. A
compile-time evaluation is a program the compiler runs with no arguments:
`processArgumentCount()` is 0 under `#`.

Bounds:

- `compilerWriteFile`: paths are project-relative, without `.` or `..`
  components. At most 16 MiB per file, 4096 paths and 256 MiB per build.
  Writing the same path again replaces its staged contents.
- `compilerRunProcess`: at most 128 arguments of 4096 bytes each. The same
  watchdog that bounds the compiler bounds the child.
- `compilerTcpExchange`: numeric IPv4 addresses only, at most 1 MiB each
  way, and a timeout of at most 10 seconds.

```toml file=abla.toml
compileCapabilities = ["filesystem.write", "environment"]
```

```abla
import "abla/io"
import "abla/compiler"

#compilerGrant("filesystem.write")
#compilerGrant("environment")

compile fun writeManifest(): bool =
    compilerWriteFile("build/manifest.txt", "mode=${compilerEnvironment("BUILD_MODE")}\n")

val written = #writeManifest()

fun main {
    println("manifest written: $written")
}
// output:
// manifest written: true
```

The manifest's unknown capability names are ignored. A grant with an
unknown name is `compile.capability-unknown`.

### Native code at compile time

With `trusted.native`, compile-time code runs native code as a compiled program
does. A call to an `extern:"c"` declaration calls the C function, with the
argument and result conversions of a compiled call. Its symbol is looked up in
the compiler process (the C library) and in the libraries of the root
manifest's `nativeLibraries`, which the compiler loads for the build: it
searches `LIBRARY_PATH`, the system library directories and the dynamic
loader's own paths. `trusted` code's raw memory operations, the allocator behind
`abla/unsafe/memory`, and the system calls under `abla/fs`, `abla/process` and
`abla/net` act on real memory and the real system. The standard library's own
use of raw memory (byte buffers it allocates and owns) is contained: it needs
no capability, the same as the runtime's memory. A program's own `trusted`
raw-memory code, including calls into `abla/unsafe`, needs `trusted.native`. `nativeFunctionAddress(f)`
gives C code an entry that calls back into `f`, so a C sort with an Abla
comparison works as at run time.

```toml file=abla.toml
compileCapabilities = ["trusted.native"]
```

```abla
import "abla/io"
import "abla/compiler"
import "abla/unsafe/memory"
import "abla/unsafe/native"

#compilerGrant("trusted.native")

noescape extern:"c" fun strlen(text: cstring): int
noescape extern:"c" fun qsort(base: i64*, count: int, size: int, compare: i64*): void

trusted fun compareWords(left: int, right: int): i32 =
    i32(ablaUnsafeLoadI64(nativePointerFromAddress(left)) -
        ablaUnsafeLoadI64(nativePointerFromAddress(right)))

trusted fun sortedDigits(): int {
    val buffer = nativeByteBuffer(32)
    val values = [4, 2, 3, 1]
    var index = 0
    while (index < 4) {
        buffer.storeI64(index * 8, values[index])
        index = index + 1
    }
    qsort(buffer.address, 4, 8, nativePointerFromAddress(
        nativeFunctionAddress(compareWords)
    ))
    var digits = 0
    index = 0
    while (index < 4) {
        digits = digits * 10 + buffer.loadI64(index * 8)
        index = index + 1
    }
    buffer.close()
    digits
}

val nameLength = #strlen("compile time")
val sorted = #sortedDigits()

fun main {
    print("$nameLength $sorted\n")
}
// output:
// 12 1234
```

The rest of `abla/platform/host` works in both phases too: a compiled program
links its functions, and compile-time code performs each under the capability
it implies — `ablaHostFileKind`, `FileSize`, `FileRevision` and
`CurrentDirectory` are `filesystem.read` (journaled like a read); writes, moves
and removals `filesystem.write`; standard output and error none (and
`Argument`/`ArgumentCount` none: there are no arguments under `#`); standard
input and processes `process.io`; `Net*` (and the `Tls*` functions
of `abla/platform/host/tls`) `network`; `Sleep` and `MonotonicMilliseconds`
`clock`; `SecureRandom` `random`.

Without the grant, a native call is rejected before it runs
(`compile.effect-denied:trusted.native`, or `E_COMPILE_NATIVE_DENIED` from a
parser handler, which runs before that check). A symbol found nowhere is
`E_COMPILE_NATIVE_SYMBOL`, which names the manifest libraries that were not
found.

Native code under `#` runs in the compiler's process, not the program's:
`ablaHostIsMacOS()` reports the host the compiler runs on, and a symbol only the
program defines (its own `@export` functions) isn't there, so `dlsym` finds
nothing. A load, store or call through such a null address (or any address in
the null page) fails the evaluation with `E_EVAL_NATIVE_ADDRESS`; the compiler
doesn't crash. Call C functions through `extern:"c"` declarations: the
evaluator calls a function pointer itself only through `ablaUnsafeCallVoid0`,
`ablaUnsafeCallI32` and `ablaUnsafeCallVoidPointer3`, and the other typed
`ablaUnsafeCall*` functions of `abla/unsafe/native` work only at run time.
`nativeStaticAllocate` storage is zeroed and lasts for the compilation.

### Capabilities and the build cache

A build whose compile-time code read nothing from outside can reuse its
cached native objects. `filesystem.read` and `environment` keep that
possible because their inputs are journaled. Each read records the
provider's identity, the size and a two-hash fingerprint of what was read.
A later build revalidates every journaled input before it reuses the cache.
Environment values themselves are not stored in the cache sidecar. The
manifest is part of the cache identity too. Every other capability makes a
build that uses it uncacheable.

Parser handlers and extension finalizers get the same granted capabilities
as the rest of their module, and their journals join the same cache record.
Because they run before semantic analysis has finished, their grants are
checked against the manifest before they run.

## Limits

Each compile-time evaluation may take at most 50,000,000 evaluation steps.
An endless loop stops with:

```text
error[E_EVAL_STEP_LIMIT]: compile-time evaluation ran past 50000000 steps (an endless loop?)
```

`ABLA_EVAL_STEP_LIMIT=<n>` lowers the limit for a build (it never raises
it), which is useful in tests.

Recursion at compile time is bounded by the compiler's own stack. The
evaluator measures how much of that stack nested evaluation has used and stops
1.5 MB short of the limit; a call takes a few nesting levels (about three for
a simple recursive function). The `ablac` launcher gives the compiler the
largest stack the system allows: on macOS that is 64 MB, about 16,000 levels
or 5,000 nested calls of a small function. A plain 8 MB stack allows about
1,700 levels. Deeper recursion stops with one error instead of crashing the
compiler:

```text
error[E_EVAL_STACK_DEPTH]: compile-time evaluation nested 16408 levels deep and used up the compiler's stack (unbounded recursion, or recursion deeper than the compiler's stack allows)
```

`ABLA_EVAL_DEPTH_LIMIT=<n>` lowers the limit (it never raises it), and
`ABLA_MAX_STACK_KB` sets the launcher's stack. When compile-time code runs
on the coming JIT tier it recurses as deep as at run time, and the `auto`
mode moves an evaluation that hits the depth limit onto the JIT.

Memory introspection (`memoryLiveBytes`, `memoryCollect`, ...) has no
meaning inside the compiler, and is not available at compile time: each
function used is one `E_EVAL_MEMORY_UNAVAILABLE` error.

### Threads at compile time

The compile-time interpreter runs one thing at a time. A `thread { }` body
doesn't start when the thread is created; it runs when the thread is
awaited. Code that waits for its own thread before awaiting it never
finishes under `#`: a server that accepts a connection from a client thread
it started, or a loop that waits for a flag the thread sets. The evaluation
runs until the compiler's time limit stops it. Await the thread before
anything waits on it, or keep such code at run time. Threads that run
alongside each other under `#` come with the JIT tier.

## Declaration blocks

In compile-time code, braces whose first member is a declaration (`fun`,
`class`, `interface`, `resource`, `trusted`, `extern`, `compile`, or an
`@annotation`) are a *declaration block*, not a lambda. The block is a
value of type `DeclarationBlock` that holds the declarations' source:

```abla fragment
compile fun buildHelper(): void {
    val helper = compiler.newModule("helper")
    helper.use(compiler.function("sharedLogic"))
    helper.declare {
        fun main: int = sharedLogic()
    }
    helper.emit("build/helper")
    return
}
```

The declarations are parsed where they are written, so mistakes are
reported at their own position. Their only consumer is
`IndependentModule.declare` ([programmable-builds.md](programmable-builds.md)).
A block may also contain `val`, `var` and `#` members, but not as its first
member: braces that start with one of those are an ordinary lambda.
Declaration blocks exist only at compile time; using one in run-time code is
`declaration.block.compile-only`. Limits: 1 MiB of source per block and 32
blocks per module.

## What works at compile time today

Compile-time evaluation is being brought to full parity with run time. The
compiler team tracks the remaining gaps case by case.

| Area | Under `#` today |
|---|---|
| Functions, recursion, classes and methods, arrays, `Map`, strings, string templates | works |
| Closures used within one evaluation; tasks and `await` | works |
| `thread { }` | runs when it is awaited, not alongside the code that started it ([threads at compile time](#threads-at-compile-time)) |
| Generators | works |
| `f32`/`f64` arithmetic, `abla/math`, `abla/float/text` | works |
| `abla/json`, `$json`, `$jsons` | works |
| Delegated bindings, resources and `drop`, ownership checks | works |
| Granted capabilities through the providers above | works |
| Closures as `#` results | works |
| `print`/`println` | works, no grant: to the compiler's standard output |
| `abla/fs` reads, `abla/process/time` | works with `filesystem.read` / `clock` |
| `abla/fs` writes, moves and removals | works with `filesystem.write`, staged until the build succeeds |
| Standard-library code built on its own raw memory (byte buffers) | works, no grant |
| Other system calls (processes, sockets) | works with `trusted.native` ([native code](#native-code-at-compile-time)) |
| `extern:"c"` functions, trusted raw memory, `nativeFunctionAddress` callbacks | works with `trusted.native` |
| `abla/platform/host` | works: each function under the capability it implies |
| Fixed-width integer conversions (`u16(x)`); nominal conversions (`Pin(x)`), integer extension methods | fixed-width works; the rest partly: being fixed |
| Run-time globals | see [above](#ordinary-globals-at-compile-time) |
| Process arguments (`processArgumentCount()`) | works: compile-time code sees none, so the count is 0; no capability needed |

Compile-time code prints with `println` like any program; its output is
the compiler's.

## How a compilation runs

1. Parse the entry module and everything it imports. Literal top-level
   grants, subparser registrations and generated modules are collected here.
2. Type-check the whole program, including generated declarations.
3. Run top-level actions, in order, then the transforms they registered.
4. Lower the program: each `#expression` is evaluated where it is lowered,
   and its value is stored as a constant.
5. Check the result and generate code.

Generated declarations are type-checked before any later compile-time code
can see them. Program changes made at compile time are transactional: if a
step fails, none of its changes are kept.

## Native evaluation

`ABLA_COMPILE_EVAL=jit` (or `auto`) runs compile-time code as machine code
instead of in the evaluator; the default is still `interp` while the native
tier is completed. After type checking, each compile pass builds one *slice*
of the program: the declarations its `#expression`s and actions reach, the
runtime, and an exported entry per site, with compile declarations compiled
as ordinary code. The slice goes through the same code generator as the
program and is loaded into the compiler with LLVM's in-process JIT; each
entry then runs exactly where the evaluator would have run its site, in the
same order. The native code has a runtime of its own: values, closures
included, come back through the same codec the evaluator's results use, so a
site gives the same program constant on either tier.

Native code calls the compiler API, parser externs and host providers
(`extern:"compiler"`, `extern:"parser"`, `extern:"host"`) through the compiler
bridge: each call runs the evaluator's implementation on the site's evaluation,
so grants, the input journal, staged writes and diagnostics are the
evaluator's, and compiler-owned values (syntax, cursors, builders) cross as
handles.

A site the native tier cannot take yet runs in the evaluator: code that passes
a function to a compiler API call, a compile global still holding a kept value
native code can't take in (an object, a map, a nested array, or any value of a
`compile val`), a global whose
initializer is itself compile-time code, a result only the compiler can hold
(a generator, task, thread, borrow, `Weak` or raw pointer), a cross-target
build (compile-time code always runs on the host), the REPL, and a
compilation that compile-time code starts (it runs inside the outer pass).

- A runtime panic in native compile-time code is the evaluator's error for the
  same failure, with the same text (`E_EVAL_OUT_OF_BOUNDS`,
  `E_EVAL_DIVISION_BY_ZERO`, else `E_CT_PANIC`); an abort, a failed check or
  recursion past the end of the compiler's stack is `E_CT_STOPPED`. The
  compiler survives each, and the rest of the pass runs in the evaluator.
- Native code has no step limit. One evaluation may run for
  `ABLA_COMPILE_EVAL_TIME_LIMIT` seconds (default 600, `0` for no limit), then
  stops with `E_CT_TIME_LIMIT`.
- `compile val`/`compile var` hold one value for the compilation on both
  tiers: after each native call their values are kept as the evaluator keeps
  them. When an evaluated site changes a `compile var` the slice holds whose
  type is `int`, `bool`, `f64` or `string`, or an array of those, the new
  value goes back into the native code. A change to a global of any other
  type makes the rest of the pass fall back to the evaluator.
- `ABLA_COMPILE_EVAL_TRACE=1` prints, per site, whether it ran natively or why
  it did not; `ABLA_COMPILE_EVAL_DUMP=<directory>` keeps each slice's LLVM
  module.

## Diagnostics

| Code | Meaning |
|---|---|
| `E_EVAL_EXPRESSION` | compile-time evaluation failed; the message names the expression kind and its byte range |
| `E_EVAL_STEP_LIMIT` | an evaluation ran past the step limit |
| `E_EVAL_DIVISION_BY_ZERO` | an integer division or remainder by zero, which panics at run time |
| `E_EVAL_OUT_OF_BOUNDS` | an index or slice outside a string or an array, or a negative `truncate` or `filledArray` count; the message is the run-time panic's |
| `E_CT_STOPPED` | native compile-time code aborted, failed a check or ran past the end of the stack ([native evaluation](#native-evaluation)) |
| `E_CT_TIME_LIMIT` | a native evaluation ran past `ABLA_COMPILE_EVAL_TIME_LIMIT` |
| `E_CT_PANIC` | native compile-time code panicked with a reason the evaluator has no code of its own for |
| `compile.effect-denied:<capability>:<call path>` | the code needs a capability that this module didn't grant |
| `compile.capability-not-authorized:<capability>` | the module grants a capability that `abla.toml` doesn't authorize |
| `compile.capability-unknown:<name>` | the grant names no known capability |
| `compile.value-runtime:<name>` | run-time code reads a `compile val`/`compile var` |
| `compile.result: <type> cannot become a program value: <reason>` | a `#` result that exists only inside the compiler (a generator, task, thread, borrow, `Weak`, raw pointer, or object with `drop()`) |
| `declaration.block.compile-only` | a declaration block in run-time code |
| `E_COMPILE_GRANT_PHASE` | compile-time code called `compilerGrant`; grants are literal top-level actions |
| `E_EXT_SUBPARSER_REGISTRATION` | an invalid or duplicate subparser registration, or one made from compile-time code |
| `E_EXT_GENERATED_MODULE_PHASE` | `compilerGenerateModule` ran after the program was analyzed (outside a transform) |
| `E_PACKAGE_CAPABILITY_DENIED` | a dependency asks for a capability the root project doesn't authorize |
