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
    println("${#fib(30) + 1}")
}
// output:
// item1 = 5
// item2 = 55
// item3 = 610
// 832041
```

`fib(30)` runs once, inside the compiler. The program only contains the
number. `table()` is an ordinary function: the program could call it at run
time too, and here it runs at compile time because of the `#`.

Things to know about `#`:

- **It binds tightly.** `#` applies to the operand right after it, including
  that operand's calls, member accesses and indexes. `#fib(30) + 1` means
  `(#fib(30)) + 1`, and `#config.items[0]` evaluates the whole chain. Use
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
// error: E_EVAL_EXPRESSION
```

> Known issue (being fixed by ct-parity): reading a local under `#` is reported only when the
> evaluation reaches it, as `E_EVAL_EXPRESSION: compile-time evaluation
> failed while evaluating identifier n`. It is not a type error naming the
> local.

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

> Known issue (being fixed by ct-parity): calling a `compile fun` from run-time code is not rejected by
> the type checker. It fails later, in code generation, with
> `E_LLVM_INSTRUCTION_UNSUPPORTED: function main cannot lower ... call target
> <name>`.

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

These work only as literal top-level actions. Called from inside a
`compile fun`, `compilerGrant`, `compilerRegisterSubparser` and
`compilerGenerateModule` currently do nothing, and they don't report an
error either (being fixed by ct-bridge).

An action that runs code (anything other than a grant) disables the
whole-program native object cache for that build. Every build then runs it
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
- Between evaluations the value is kept as data: integers, booleans,
  strings, `null`, arrays and objects. A global that holds anything else (a
  closure, a handle) is evaluated afresh for each evaluation.
- A module that the native object cache skips runs no handlers. A provider
  that collects from its uses should be built with `--no-cache`.

> Known issue (being fixed by ct-parity): a `compile val` currently clashes with *any* identifier of the
> same name, even a local in another module. `compile val registry` breaks
> every build, because the runtime has a local named `registry`. Prefer
> distinctive names until this is fixed.

## Ordinary globals at compile time

A top-level `val` or `var` without `compile` belongs to the run-time
program. Compile-time code can read it, but today every *reference* to it
during compile-time evaluation evaluates its initializer again. Changes made
through it are lost, even within one evaluation:

```abla
import "abla/io"

class Box(var n: int)

val box = Box(1)

fun bump(): int {
    box.n += 1
    box.n
}

fun main {
    println("${#bump()} ${#bump()}")
    println("${bump()} ${bump()}")
}
// output:
// 1 1
// 2 3
```

At compile time, `box.n += 1` changes one fresh `Box(1)` and the next line
reads another. Assigning to a run-time `var` (`counter += 1` on a top-level
`var counter`)
during compile-time evaluation currently fails with `E_EVAL_EXPRESSION`.

These two rules are being changed so that a run-time global has one value for
the whole compilation, exactly like a `compile var`. This page will be
updated when that lands. Until then, keep compile-time state in
`compile val`/`compile var`.

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

The intended way to read a file at compile time is the same `abla/fs` API
as at run time, under the `filesystem.read` grant:

```abla fragment
import "abla/io"
import "abla/fs"
import "abla/compiler"

#compilerGrant("filesystem.read")

val greeting = #path("greeting.txt").readText()
```

That form doesn't work yet: `abla/fs` ends in system calls, which compile-time
evaluation can't make yet (being added by ct-native; the build currently
stops with `compile.effect-denied:trusted.native`). Until then, use the
host runtime's file function. It is internal and will go away once the
`abla/fs` form works:

```abla
import "abla/io"
import "abla/compiler"
import "abla/platform/host"

#compilerGrant("filesystem.read")

val greeting = #ablaHostReadFile("greeting.txt")

fun main {
    print(greeting)
}
// output:
// hello from a file
```

Without the grant, the build stops with `compile.effect-denied:filesystem.read:ablaHostReadFile`.
Without the manifest entry, it stops with `compile.capability-not-authorized:filesystem.read`.
In a package, a dependency's `compileCapabilities` must be a subset of the
root project's (`E_PACKAGE_CAPABILITY_DENIED`).

The compiler works out which capabilities each function needs, transitively.
The error names the whole call path, as in
`compile.effect-denied:environment:readBuildEnvironment->compilerEnvironment`.
The check happens before evaluation starts, so a denied path never runs.

| Capability | What it allows | Providers | Native object cache |
|---|---|---|---|
| `filesystem.read` | read files, list directories | `abla/fs` (coming); today the internal `ablaHostReadFile(path)`, `ablaHostListDirectory(path)` (sorted) | kept: each read is journaled and revalidated |
| `filesystem.write` | stage output files, published only if the build succeeds | `compilerWriteFile(path, contents)` | disabled |
| `environment` | read named environment variables | `compilerEnvironment(name)` (`""` when unset) | kept: each value is journaled and revalidated |
| `process.io` | run a child process | `compilerRunProcess(arguments)` | disabled |
| `network` | one TCP request/response | `compilerTcpExchange(ipv4, port, request, maxBytes, timeoutMs)` | disabled |
| `clock` | read the wall clock | `compilerClockMilliseconds()` | disabled |
| `random` | random integers | `compilerRandomInteger(maxExclusive)` | disabled |
| `trusted.native` | run trusted and `extern` code (raw memory, C functions, system calls) | see [below](#what-works-at-compile-time-today) | disabled |

The `compiler*` providers come from `import "abla/compiler"`. The
`ablaHost*` file functions come from `import "abla/platform/host"`. File
paths are relative to the directory the compiler runs in.

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
it), which is useful in tests. Memory introspection (`memoryLiveBytes`,
`memoryCollect`, ...) has no meaning inside the compiler, and is not
available at compile time.

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
| Generators | being fixed |
| `f32`/`f64` arithmetic, `abla/math`, `abla/float/text` | works |
| `abla/json`, `$json`, `$jsons` | works |
| Delegated bindings, resources and `drop`, ownership checks | works |
| Granted capabilities through the providers above | works |
| Closures as `#` results | works |
| `print`/`println`, `abla/fs`, `abla/process`, sockets: anything that ends in a system call | not yet: `compile.effect-denied:trusted.native` (being added by ct-native) |
| `extern:"c"` functions, trusted raw memory | not yet: being added behind the `trusted.native` capability |
| Fixed-width and nominal conversions (`u16(x)`, `Pin(x)`), integer extension methods | partly: being fixed |
| Run-time globals | see [above](#ordinary-globals-at-compile-time) |

So, for now, compile-time code cannot print. When ct-native lands the
system-call mapping, `println` under `#` will write to the compiler's own
standard output. Until then, to inspect what compile-time code computes,
return the value with `#` and print it at run time, or stage a file with
`compilerWriteFile`.

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

## Diagnostics

| Code | Meaning |
|---|---|
| `E_EVAL_EXPRESSION` | compile-time evaluation failed; the message names the expression kind and its byte range |
| `E_EVAL_STEP_LIMIT` | an evaluation ran past the step limit |
| `compile.effect-denied:<capability>:<call path>` | the code needs a capability that this module didn't grant |
| `compile.capability-not-authorized:<capability>` | the module grants a capability that `abla.toml` doesn't authorize |
| `compile.capability-unknown:<name>` | the grant names no known capability |
| `compile.value-runtime:<name>` | run-time code reads a `compile val`/`compile var` |
| `compile.result: <type> cannot become a program value: <reason>` | a `#` result that exists only inside the compiler (a generator, task, thread, borrow, `Weak`, raw pointer, or object with `drop()`) |
| `declaration.block.compile-only` | a declaration block in run-time code |
| `E_PACKAGE_CAPABILITY_DENIED` | a dependency asks for a capability the root project doesn't authorize |
