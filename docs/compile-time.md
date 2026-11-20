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
  body or a loop is still one constant, and so is a global it initializes:
  compile-time code that reads the global, or calls the function, gets the
  value the `#` already has. Its effects happen once, when the build first
  needs its value: at the `#` itself, or when compile-time code that reads
  it starts and the globals initialize, in dependency order as at run time
  (a global initializes after the globals its initializer reads, through the
  functions it calls).
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

The compiler's own API (`compilerEnvironment`, `compilerWriteFile`, the
reflection and syntax functions of `abla/compiler`) exists only while the
program compiles in the same way, so an ordinary function that calls it is
run-time code calling it. Make that function a `compile fun`:

```abla error
import "abla/compiler"

fun homeLength(): int = compilerEnvironment("HOME").size

fun main: int = #homeLength()
// error: compile.call-runtime:compilerEnvironment
```

Compile-time reflection ignores `private`. `compiler.functions()` lists every
declaration. `compiler.findClass(name)` and `findFunction(name)` find a
[private](language.md#modules-and-imports) declaration by its source name,
the calling module's when the evaluation knows it, else the only one of that
name in the program. `compiler.isPrivate(handle)` tells which ones are
private. Ordinary `#` code still resolves names as its module sees them, so
a private name used directly from another module is an error there as
anywhere.

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
  captured. A kept closure retains the lambda body it was created with, even
  if a later transform replaces that body; a newly created closure uses the
  replacement. A closure kept before a later compile-time transform cannot
  currently be lifted into the run-time program: its original captured layout
  is no longer known. Calls in the interpreter still use its original body.
  A global that holds something that exists only while one
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
evaluations the interpreter keeps supported globals together in one graph:
arrays, maps, objects and closures preserve shared references and cycles,
including references shared between ordinary and compile-time globals.
Mutating an array through one global is therefore visible through another
global that names the same array. A value that cannot be kept, such as a
generator or task, is evaluated afresh on its next use. If a mutation makes an
already-kept shared graph unpersistable, compilation stops before changing the
journal and names the global and unsupported value kind. This prevents another
alias from seeing an older copy of the shared value.

Under `auto` (the default) and `jit`, an ordinary global (a plain `val` or `var`, not a
`compile val` or `compile var`) that compile-time code can write has one owner
for the pass. The native tier owns it when every site of the pass that reaches
it can run natively. The global must also have a type the native tier can hand
back (written out, a literal's, a class constructor's, a plain function's declared
result, or a TVar delegate) that holds no closure (unless one site of the pass alone
reaches it, as abla-forge's `engineApp`, whose schedules hold closures), and no earlier evaluation may
have kept a value of it. Those
sites then share the native copy, made by its initializer. After each native
call its value goes into the interpreter's store, so a later pass, or an
interpreted evaluation that reads it, sees the one value. If one of those sites
can't run natively, every site that reaches the global runs in the interpreter,
whatever the order or number of the sites (a site can run again through a
compile function, a generic instantiation or a rebuilt module). If an
interpreted evaluation changes a global the native tier owns, the generation
stops and the rest of the pass is interpreted. A TVar-delegated global (such as
the pure TLS trust-store cache) is never kept between evaluations, in either
tier: the native one lives for the pass. So does a global whose value holds
resources, a raw pointer (`i64*`: the interpreter has no raw memory), or a value
that always holds a closure (a class with a function field): the interpreter
makes those afresh at each evaluation, so nothing goes back to its store, and
under declaration edits a closure-holding one still stays interpreted. Code can write a global when it assigns it, stores into its fields or
elements, calls a built-in mutator (`append`, `set`, `remove`, ...) on it or on
something that may alias it, or hands it to code the analysis cannot follow
(an extern, a closure called as a value); code that only reads a table leaves
it alone, and a site that reads only such a table stays native.
`ABLA_COMPILE_EVAL_TRACE=1` names the global and the code that may write it, and says which globals are native for the pass.
A site that makes a closure, in a build where compile-time code changes declarations (`replaceFunctionBody`, `applyTransform`, added
fields or conformances), runs in the interpreter too: a native closure is
positional and would run the edited body. Use `compile var` for state that
sites share, and keep it simple enough for the native tier.

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
A call through an interface counts what its implementers do, but only those the `#` expression's code can
make: reading a string through `Source` isn't denied because a `FileSource` exists that nothing here creates.
Of a class that doesn't conform to the interface, nothing is: a `read` extension of a file handle the expression
makes isn't what a `Source`'s `read` runs.
The same holds for a vector's extensions: a `Map`'s `get` doesn't reach abla/simd's `i8x16.get` unless the
expression's code calls something that returns an `i8x16`.
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
| `filesystem.write` | write files, make directories, move and remove paths: real writes, as at run time | `compilerWriteFile(path, contents)`; `abla/fs`: `p.writeText()`, `p.writeTextAtomic()`, `p.appendText()`, `p.createDirectories()`, `p.createParentDirectories()`, `p.moveTo(destination)`, `p.remove()` | disabled |
| `environment` | read named environment variables | `compilerEnvironment(name)` (`""` when unset) | kept: each value is journaled and revalidated |
| `process.io` | run a child process | `compilerRunProcess(arguments)` | disabled |
| `network` | one TCP request/response | `compilerTcpExchange(ipv4, port, request, maxBytes, timeoutMs)` | disabled |
| `clock` | read the clocks, sleep | `compilerClockMilliseconds()`; `abla/process/time`'s `sleep`, `monotonicMilliseconds()`, `realtimeMilliseconds()` and their nanosecond forms | disabled |
| `random` | random integers | `compilerRandomInteger(maxExclusive)` | disabled |
| `trusted.native` | run trusted and `extern` code (raw memory, C functions, system calls) | see [below](#what-works-at-compile-time-today) | disabled |
| `time.unlimited` | the module's `#` sites run without `ABLA_COMPILE_EVAL_TIME_LIMIT` (a game played under `#`, a long generation); only the module that requests it, every other module keeps the limit | no provider: the request itself | kept: it changes no result |
| `transform.library` | a transform changes a standard-library function's body or removes a standard-library extension field (annotations need no grant; a program's own modules never do) | `compilerReplaceFunctionBody`, `compilerRemoveExtensionField` on a standard-library target (see [compiler-api.md](compiler-api.md)) | kept: the edits are part of each module's fingerprint |

`trusted.native` is all or nothing: it lets compile-time code load and call
any C library, so it can open windows, use the GPU and audio, and open
sockets, whatever the other grants say. A game client run under `#` reaches
X11, Vulkan, ALSA and libcurl that way, by opening them with `dlopen`, and
never asks for `network`.

The `compiler*` providers come from `import "abla/compiler"`. File paths are
relative to the directory the compiler runs in.

Under `#`, the `abla/fs` writes, moves and removals, and `compilerWriteFile`,
are real writes, as at run time: each one is on disk when the call returns, so
what the site does next sees it. That holds for its reads, its own system calls
(`linkTo`, `permissions`, raw `openat`) and the processes it starts
(`compilerRunProcess`, `compilerCaptureProcess`), in both tiers. Paths may be
anywhere the compiler may write, `/tmp` included, as at run time
(`compilerWriteFile` keeps its own contract, below). `removeTree()` asks what
a path is without following links, which is native code (`trusted.native`);
so are `linkTo`, `linkTarget` and `linkInfo`.

A build that fails after a site wrote keeps what the site wrote, as a program
that fails after writing does: a failed build can leave partial output. A
build that fails before any site runs (in parsing or analysis) writes nothing.
A build that grants `filesystem.write` is never taken from the native object
cache, so its sites run, and write, on every build.

`print`, `println`, `eprint` and `eprintln` need no capability: under `#` they
write to the compiler's own standard output and error. What a compilation
prints is not an input of the build, so it changes neither the program nor
whether a cached build is reused (a cached build just doesn't print again,
like a warning). Reading standard input (`readLine`) needs `process.io`. A
compile-time evaluation is a program the compiler runs with no arguments:
`processArgumentCount()` is 0 under `#`.

Bounds:

- `compilerWriteFile`: paths are project-relative, without `.` or `..`
  components. At most 16 MiB per file and 256 MiB per build. Each write goes
  beside its target and is renamed over it, so a reader sees the old contents
  or the new ones, whole.
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
import "abla/unsafe/memory/raw"

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
input and processes `process.io`; `Net*` `network`; `Sleep` and `MonotonicMilliseconds`
`clock`; `SecureRandom` `random`. The `Tls*` functions of `abla/platform/host/tls` are not providers: they are
`abla/tls/pure` (TLS in Abla, no OpenSSL) compiled into the site like any stdlib code. What they ask for is `network` and
nothing else, by the rule below. Under `ABLA_COMPILE_EVAL=auto` such a site runs natively by itself (a handshake is far
more than the interpreter's trial steps, and the trial stops before the first system call).

### A standard-library module that carries its own effects under `network`

A few trusted standard-library modules are *network scopes*: `abla/tls/pure` and `abla/platform/host/tls`. What the code
of such a module does by itself (sockets and the other system calls, raw memory, the trust store and
`SSL_CERT_FILE`/`SSL_CERT_DIR`, the clock for certificate validity, random numbers for the handshake) is the module's
own business: the capability analysis turns the effects `trusted.native`, `filesystem.read`, `environment`, `clock` and
`random` that reach a scope's declaration into `network`, at that declaration, and a caller is asked for `network` only.
It is the containment the standard library already has for raw memory, one level up.

The rule is narrow:

- Only the effects of the scope's declarations and of what they call are turned into `network`. A program's own system
  call, file read, environment read or clock read beside the TLS call still needs its own grant.
- `filesystem.write` and `process.io` are never turned into `network`: a scope that reached them would be denied for them.
- No public declaration of a scope hands back the contents of a file or the value of an environment variable: the
  files it reads (the trust store, a CA file, a certificate and key the caller names) are parsed as certificates and
  keys and never returned as bytes, and the environment is read for `SSL_CERT_FILE`/`SSL_CERT_DIR` only. So `network`
  does not become a general file or environment reader. A declaration added to a scope that returned raw file or
  environment contents would have to stay out of it.
- A function the program passes in (a callback, a closure) keeps its own effects, which are the program's.
- A declaration that makes none of those effects (a parser, a key schedule) asks for nothing.
- Nothing else is a scope: `abla/sys/linux/net` and the rest of the standard library need their grants when `#` code
  calls them, as before.

The scope changes what is asked, not what runs: the code runs in the site's native slice, and the native object cache is
off for it like for every `network` site.
The check is the static one: the capability analysis denies the program's own file, environment or clock use before the site runs, in every
tier. The interpreter also keeps the scope while it runs a scope's code, and the native tier's compiler bridge lets provider calls through
under `network`, because compiled code does not say which declaration called. `tools/test-compile-tls.sh` holds the denials in each tier.

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
`ablaUnsafeCallI32` and `ablaUnsafeCallVoidPointer3`. The other typed
`ablaUnsafeCall*` calls (`ablaUnsafeCallExact_*` among them, which code that
finds C functions with `dlsym` calls them through) work in the native tier,
so under `auto` a site that reaches one runs natively.
`nativeStaticAllocate` storage is zeroed and lasts for the compilation.

### Capabilities and the build cache

A build whose compile-time code read nothing from outside can reuse its
cached native objects. `filesystem.read` and `environment` keep that
possible because their inputs are journaled. Each read records the
provider's identity, the size and a two-hash fingerprint of what was read.
A later build revalidates every journaled input before it reuses the cache.
Environment values themselves are not stored in the cache sidecar. The
manifest is part of the cache identity too. `time.unlimited` changes no
result, so it keeps the cache too. Every other capability makes a build that
uses it uncacheable.

### Non-reproducible sites

A `#` site whose code can reach `trusted.native`, `clock`, `random`,
`network`, `process.io` or `filesystem.write` may give a different value, or
leave a different file behind, on the next build. The compiler refuses none
of them, and reports each one after a successful build:

```text
note: non-reproducible: clock.ab:7 `#(compilerClockMilliseconds() > 0)` reached clock
```

The capabilities named are the granted ones among those the site's code can
reach, as the capability check works them out (a `#` inside another is part of
that one). More than eight sites are one line with their number. The list is
also in the output's ABI manifest, `<output>.abi.json`, for a release or a
check to read:

```json
"nonReproducible":[
    {"site":"clock.ab:7","expression":"#(compilerClockMilliseconds() > 0)","capabilities":["clock"]}
  ]
```

A build with a pure site has no notes and no `nonReproducible` key. A build
with such a site is never a cache hit (each of those capabilities makes it
uncacheable), so every build of it prints the same notes.

The compile-time tier (`ABLA_COMPILE_EVAL`) is part of the cache identity of
a build and of an `ablac run` record. The tiers can disagree: a site the
evaluator stops on can finish natively. So a build cached under one tier is
never reused under another.

Parser handlers and extension finalizers get the same granted capabilities
as the rest of their module, and their journals join the same cache record.
Because they run before semantic analysis has finished, their grants are
checked against the manifest before they run.

## Limits

Each compile-time evaluation may take 50,000,000 evaluation steps by default.
The limit bounds accidental endless loops as well as finite computations.
An endless loop stops with:

```text
error[E_EVAL_STEP_LIMIT]: compile-time evaluation ran past 50000000 steps (an endless loop?); adjust ABLA_EVAL_STEP_LIMIT; the native tier has no step limit, and ABLA_COMPILE_EVAL_TRACE=1 says why it did not take this site
```

`ABLA_EVAL_STEP_LIMIT=<n>` overrides the limit for a build, either raising it
for heavier computations or lowering it in tests. It accepts a positive decimal
integer of at most 18 digits; empty, zero, negative, malformed or longer values
keep the default. For example, `ABLA_EVAL_STEP_LIMIT=200000000 ablac build app.ab`
allows four times the default work per evaluation. Increasing the limit also lets
an accidental endless loop run longer. The step limit is the evaluator's: by
default a site the native tier can take runs as native code, which has none,
unless no site of its pass reaches a loop or recursion
([native evaluation](#native-evaluation)). `ABLA_COMPILE_EVAL_TRACE=1` says
why a site ran in the evaluator.

Recursion at compile time is bounded by the compiler's own stack. The
evaluator measures how much of that stack nested evaluation has used and stops
1.5 MB short of the limit; a call takes a few nesting levels (about three for
a simple recursive function). The `ablac` launcher gives the compiler the
largest stack the system allows: on macOS that is 64 MB, about 16,000 levels
or 5,000 nested calls of a small function. A plain 8 MB stack allows about
1,700 levels. Deeper recursion stops with one error instead of crashing the
compiler:

```text
error[E_EVAL_STACK_DEPTH]: compile-time evaluation used up the compiler's stack (unbounded recursion, or recursion deeper than the compiler's stack allows)
```

`ABLA_EVAL_DEPTH_LIMIT=<n>` lowers the limit (it never raises it), and
`ABLA_MAX_STACK_KB` sets the launcher's stack. These bounds are the
evaluator's. In the [native tier](#native-evaluation) compile-time code runs
as machine code on the compiler's stack, with frames like a program's, so it
recurses about as deep as at run time (100,000 levels of a small function
fit); running past the end of the stack stops it with the same `E_EVAL_STACK_DEPTH`, and
there is no step limit, only a [time limit](#native-evaluation).

The runtime memory API (`memoryLiveBytes`, `memoryCollect`, `memoryReset`,
...) needs a heap of the program's own. The evaluator has none, so there each
function used is one `E_EVAL_MEMORY_UNAVAILABLE` error. The exceptions do
nothing the program could count: `memoryCollect()` is a safe point the program
asks for, and the evaluator's values are the compiler's, so it returns 0 bytes
reclaimed; `memorySetBackgroundFree` only changes when freed memory goes back to
the system. A program that only collects evaluates; one that measures
(`memoryLiveBytes`, a checkpoint and reset) is refused. Native compile-time code has
a runtime of its own, and the API measures and manages that heap.

### Threads at compile time

The evaluator runs one thing at a time. A `thread { }` body doesn't start
when the thread is created; it runs when the thread is awaited. Code that
waits for its own thread before awaiting it never finishes there: a server
that accepts a connection from a client thread it started, or a loop that
waits for a flag the thread sets. The evaluation runs until the step limit or
the compiler's watchdog stops it. Await the thread before anything waits on
it, or run such code in the [native tier](#native-evaluation), where threads
run alongside the code that started them, as at run time.

In the native tier, a site that stops (a panic, `exit`, the time limit, a bad
memory access) while a thread it started is still running ends the build
there with `E_CT_STOPPED`, naming the stop: that thread can't be stopped, and
the compiler can't go on beside it. Await every thread before code that can
stop; a site that has awaited its threads reports its panic as usual.

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

A computation under `#` prints what it prints at run time. The compiler's
parity check (`tools/test-compile-time-parity.sh`) runs every probe and every
module test program both ways, in both tiers, and compares their output and
exit status. Where the two differ by design, the difference has a name and a
reason:

- the evaluator runs a thread's body when it is awaited
  ([threads](#threads-at-compile-time)), and has no program heap for the
  runtime memory API ([limits](#limits));
- code past the evaluator's step limit, or with real-time deadlines it can't
  meet, finishes in the native tier;
- a program that reads its own executable, or calls its own exported
  functions, finds the compiler under `#`;
- a program that panics at run time stops the build with the same panic
  under `#`, because a compile-time panic is a compile error.

Every case has an expected status in each tier
(`tests/cases/parity/expected-pass.txt`), and every standard-library module
is reached by some case or listed with the reason it isn't
(`tests/cases/parity/uncovered-modules.txt`, a list that only shrinks);
`tools/test-compile-time-parity-guard.sh` checks both. Test programs whose
build is meant to fail aren't cases (`tests/cases/parity/negative.txt`).

Status, over the 371 cases:

- `auto` (the default) and `jit`: 362 pass. The other 9 differ by design:
  - 6 panic the same way on both sides;
  - 2 report the process they run in (its executable, its addresses), which under `#` is the compiler;
  - 1 is a server that never exits, so it has no result to compare.
- `interp` (the evaluator, chosen explicitly): 311 pass. The other 60:
  - the evaluator's limits, by design: 19 measure or reset the program heap the evaluator doesn't have, 16 run
    past its step limit, 8 start threads whose bodies run only when awaited, 1 keeps real-time deadlines, 2
    read the compiled runtime's own boxed words (`__ablaRuntimeArrayGet`), which the evaluator's values don't
    have, and 1 uses SIMD vectors (`abla/simd`, about 870 intrinsics over 20 lane types), which only native code
    has;
  - 6 of the native tiers' kind (3 same panics, the process twice, the server), and one program whose own `#`
    recursion is deeper than the evaluator's stack;
  - 5 the evaluator can't build, each with its reason in `expected-pass.txt`:
    - the compiler run under `#` passing its 4096 MB memory limit (2);
    - the step limit inside a longer build (3);
  - 1 that differs: a forked child, a copy of the compiler running the evaluator, runs out of memory.

  All of these but the 6 of the native tiers' kind pass under `auto` and `jit`, which run that code natively.

| Area | Under `#` today |
|---|---|
| Functions, recursion, classes and methods, arrays, `Map`, strings, string templates | works |
| Closures used within one evaluation; tasks and `await` | works |
| `thread { }` | evaluator: runs when it is awaited ([threads at compile time](#threads-at-compile-time)); native tier: alongside the code that started it |
| Generators | works |
| `f32`/`f64` arithmetic, `abla/math`, `abla/float/text` | works |
| `abla/json`, `$json`, `$jsons` | works |
| Delegated bindings, resources and `drop`, ownership checks | works |
| Granted capabilities through the providers above | works |
| Closures as `#` results | works |
| `print`/`println` | works, no grant: to the compiler's standard output |
| `panic(message)`, `exit(code)` (`abla/process`) | no grant: stop the evaluation with `E_CT_PANIC` (the message) or `E_CT_STOPPED`, never the compiler, on either tier and with `trusted.native` too |
| `abla/fs` reads, `abla/process/time` | works with `filesystem.read` / `clock` |
| `abla/fs` writes, moves and removals | works with `filesystem.write`: real writes, as at run time |
| Standard-library code built on its own raw memory (byte buffers) | works, no grant |
| Other system calls (processes, sockets) | works with `trusted.native` ([native code](#native-code-at-compile-time)) |
| `extern:"c"` functions, trusted raw memory (static and thread-local storage included), `nativeFunctionAddress` callbacks | works with `trusted.native` |
| `abla/platform/host` | works: each function under the capability it implies |
| Fixed-width integer conversions (`u16(x)`), nominal conversions (`Pin(x)`), integer extension methods | works |
| `abla/ct`'s secret integers (`secretU8` to `secretU64`) and their operators | works, no grant: a secret integer is its integer, typed, and nothing is secret or timed under `#`. The stack wipes (`ctScrubStack...`) are not evaluated: they need `trusted.native` and do nothing |
| `abla/simd/target`: `simdTargetArch()`, `targetHas`, `cpuHas` | works, no grant: the architecture is the build's target, not the compiler's host; `cpuHas` answers false for every feature, so compile-time code takes the portable software path (a hardware path must give the same answers) |
| Volatile loads and stores (`abla/unsafe/mmio`) | work as ordinary ones, with the grant raw memory has |
| The runtime memory API (`memoryLiveBytes`, `memoryReset`, ...) | evaluator: `E_EVAL_MEMORY_UNAVAILABLE` (`memoryCollect()` returns 0); native tier: its own runtime's heap ([limits](#limits)) |
| Run-time globals | see [above](#ordinary-globals-at-compile-time) |
| Process arguments (`processArgumentCount()`) | works: compile-time code sees none, so the count is 0; no capability needed |
| An interactive program (a window, rendering, input, audio, sockets) | native tier: works with `trusted.native` and `time.unlimited` ([below](#interactive-programs-at-compile-time)) |

Compile-time code prints with `println` like any program; its output is
the compiler's.

A `panic` (or `exit`) in compile-time code fails the build with its message;
the compiler goes on to report it:

```abla error
import "abla/process"

compile fun rows(): int = panic("the table is empty")

val count = #rows()

fun main: int = count
// error: E_CT_PANIC
// error: the table is empty
```

## Interactive programs at compile time

A `#` site can run a whole interactive program. A game client built on a
native engine (X11, Vulkan, ALSA, libcurl) runs inside `ablac build` with no
special support. It opens a window, renders, takes keyboard input, plays audio
and talks to its game server until the player closes the window. Then the
site's value is compiled into the program:

```abla fragment
import "abla/compiler"
#compilerGrant("trusted.native")
#compilerGrant("environment")
#compilerGrant("filesystem.read")
#compilerGrant("filesystem.write")
#compilerGrant("time.unlimited")
import "./main.ab"
import "./game.ab"

trusted fun ctPlay(): string {
    val status = nativeRun("Panda Trails", 1280, 720)
    "status $status, yaw ${player.yaw}"
}

val played = #ctPlay()

fun main: int {
    println("played at compile time: $played")
    0
}
```

```toml
compileCapabilities = ["filesystem.write", "filesystem.read", "environment", "trusted.native", "time.unlimited"]
```

What makes it work:

- **Grants.** The engine opens its C libraries with `dlopen`, so
  `trusted.native` is what reaches the window, the GPU, audio and sockets
  (see [Capabilities](#capabilities-files-environment-processes-network):
  `trusted.native` is all or nothing, and `network` is never asked). The
  client also reads its assets (`filesystem.read`), its settings
  (`environment`) and writes generated files (`filesystem.write`). The
  libraries have to be findable as at run time: the play script below
  sets the engine's library path before it builds.
- **No time limit for that module.** A site that runs until a person closes a
  window needs `time.unlimited`. The other modules' sites keep
  `ABLA_COMPILE_EVAL_TIME_LIMIT`, so one that hangs by mistake still stops
  the build.
- **One run.** The site's code runs once per build, even when the slice
  reaches it first through a global it initializes. Before #1022 the client
  ran twice, once when the slice initialized its globals and once at its site.
- **The native tier.** The client runs as native code, which the default `auto`
  tier picks for it: the evaluator would be far too slow for a game loop.

Its value isn't reproducible. What the site returns depends on the player's
input, the wall clock (frame timing, the camera) and the server's state. Every
build of it runs the game again, since `trusted.native` makes the build
uncacheable, and the build says so
([Non-reproducible sites](#non-reproducible-sites)):

```text
note: non-reproducible: ctplay.ab:21 `#ctPlay()` reached trusted.native, filesystem.write
```

Audio and the window leave nothing in the program; only the site's value
(here the run's status and the panda's heading) is compiled in.

The play script that builds it:

```sh
#!/usr/bin/env bash
# Play the game inside `ablac build`: close the window to finish the build.
set -euo pipefail
. "$forge/scripts/native-env.sh"; native_env "$forge"   # the engine's library path, for dlopen
export NATIVE_ASSETS=$game NATIVE_SERVER=ws://127.0.0.1:9/ws   # the game's own settings: assets, server
cd "$game/src/client"
out=$(mktemp -d)
ablac build ctplay.ab -o "$out/ctplay" --fast --no-cache
"$out/ctplay"    # played at compile time: status 0, yaw -1.70
```

## How a compilation runs

1. Parse the entry module and everything it imports. Literal top-level
   grants, subparser registrations and generated modules are collected here.
2. Type-check the whole program, including generated declarations.
3. Run top-level actions, in order, then the transforms they registered.
4. Lower the program: each `#expression` is evaluated where it is lowered,
   and its value is stored as a constant. A top-level `val` or `var` whose
   initializer contains a `#expression` is always lowered, whether or not
   anything reads it and whether or not the program has `main`, so its
   compile-time effects (an export, an internal link name, a written file,
   output, an error) are the same in every build. Code that runs only for its
   effect still reads best as a [top-level action](#top-level-actions).
5. Check the result and generate code.

Generated declarations are type-checked before any later compile-time code
can see them. Program changes made at compile time are transactional: if a
step fails, none of its changes are kept.

### Committing program changes

A `#expression` may change the program too, with the compiler API's
`compiler.replaceFunctionBody`, `compiler.addFunctionAnnotation` and
`compiler.instantiate` (an instance of a [generic](language.md#generics) the
program doesn't use yet), as a
[transform](compiler-api.md#transforms-changing-the-program) does. Each change is
an *edit* of a declaration as parsed. When a lowering of the program (a *round*)
has made edits, they are committed, the program is checked again and lowered
again, and its `#expression`s run again from the compile globals they started
from:

```abla
import "abla/io"
import "abla/compiler"

fun answer(): int = 1

compile fun specialize(): int {
    compiler.replaceFunctionBody(compiler.findFunction("answer"), "41")
    1
}

val marker = #specialize()

fun main {
    println("${answer() + marker}")
}
// output:
// 42
```

- A round whose edits are all ones already committed changes nothing, and is
  the last: the site above asks for the same body again in the second round.
- Edits are committed in a fixed order (by target, then kind and origin),
  whatever order the sites ran in. Two different bodies for one function are
  `E_COMPILER_EDIT_CONFLICT`; a target that is not exactly one declaration is
  `E_COMPILER_EDIT_TARGET`.
- Each commit rewrites the whole program again (receiver names, generics'
  instances, overloads, delegated properties, ...), so an added overload can
  change which function an untouched call resolves to, and each instance's
  `#` code and folded type queries see the program as committed.
- After 8 rounds that each changed the program, the build stops with
  `compile.edit-fixpoint`, listing the last round's edits and the site that
  asked for each.
- Output a discarded round printed stays printed: a site's `println` appears
  once per round.
- A standard-library target needs the `transform.library` capability, as it
  does from a transform; the runtime's functions are never changed.
- A program that makes no edits is lowered once, as before.

## Native evaluation

Compile-time code runs as machine code where it can, and in the evaluator
where it can't. `ABLA_COMPILE_EVAL` chooses the tier:

- `jit`: each site the native tier can take runs natively, and every other
  site runs in the evaluator. The choice is made for each site before
  anything runs, from what the slice below proves about the site (its reach,
  the globals it can write and the type of its result), so no site runs twice
  to choose, and a site with effects (a network call, a process, a file
  write) performs them once.
- `auto` (the default, also when the variable is unset or empty): as `jit`,
  except for a compile pass none of whose sites can run long. Such a pass
  runs in the evaluator, without a native generation, whose code generation
  costs hundreds of milliseconds. A site *can run long* when the code it
  reaches holds a loop (`while`, `do`/`while`, `for`), a lambda (a local
  function can call itself through one), an `atomic` block or a call through
  a function value, or when the functions it reaches call each other in a
  cycle (recursion). Without any of these the evaluator's work for a site is
  bounded by the size of its code. The rule is decided before any site runs
  and covers the whole pass, so no global is shared between the tiers. A
  table built in a loop, a hash, a parser or a TLS handshake runs natively;
  `#square(6)` costs no code generation.

  In a pass that can run long, a site that can act on nothing outside the
  evaluator first gets a *trial*: the evaluator runs it within what is left
  of the pass's step budget (`ABLA_COMPILE_EVAL_TRIAL_STEPS`, default
  1000000, about as long as building a native generation takes; 0 turns
  trials off). Such a site is
  not a top-level action, reaches no compile global and no ordinary global
  compile-time code writes, and its code calls no `extern:"c"` function and
  no compile-time provider (files, output, the environment, the clock,
  random numbers) and no compiler API (`compilerEnvironment`, `compilerWriteFile`,
  `compilerFunctions`…). The pass must also change no declaration. Running such a
  site twice is harmless, and the evaluator stops a trial before anything
  that would not be (a provider or C call, a system call, static storage).
  A site whose trial finishes keeps the evaluator's result. One whose trial
  runs out of steps, is stopped, or fails runs natively, as under `jit`. If
  every site of the pass finishes, the pass builds no native generation. A
  site that acts outside the evaluator never gets a trial: it runs once, on
  the tier chosen for it before the pass runs.
- `interp`: every site runs in the evaluator.
- `bridge`: the evaluator, calling the compiler API through the native
  bridge (a check of the bridge).

`ABLA_COMPILE_EVAL_TRACE=1` prints the tier each site ran on and, for a site
left to the evaluator, the reason and the time it took there; a trial that did
not finish says why. Under `auto` and `jit`, a site the evaluator ran for a
second or more is noted without the trace too, because the evaluator is often
10 to 100 times slower than native code:

```text
note: the `#` site at slow.ab:16:14 ran in the compile-time evaluator for 3.6 s, not as native code: reaches extern:"compiler" fun compilerApplyTransform, which takes a function (not passed through the compiler bridge yet) (ABLA_COMPILE_EVAL_TRACE=1 says why for every site)
```

Any site that takes five seconds or more is noted too, in any tier, with the tier it ran on (unless the note above
already gave its time):

```text
note: the `#` site at slow.ab:12:14 took 5.2 s (native); ABLA_COMPILE_EVAL_TIMES=1 lists every site's time
```

`ABLA_COMPILE_EVAL_TIMES=1` lists, at the end of the build, every site's time with its tier, slowest first, then each
native generation's costs:

```text
compile-time evaluation times:
  5.2 s  native  slow.ab:12:14 `#nap()`
  0.0 s  native  slow.ab:13:13 `#(1 + 1)`
  generation 1: 845 declarations, 327 functions; preparation 34 ms (with the write analysis), analysis 49 ms, lowering 59 ms, emission 57 ms, code 345 ms
```

The action journal (`ABLA_ACTION_JOURNAL`) records evaluated actions only:
when it is on and `ABLA_COMPILE_EVAL` names no tier, the tier is `interp`.

After type checking, each
compile pass builds one *slice* of the program: the declarations its `#expression`s and actions reach, the
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
so grants, the input journal, writes and diagnostics are the
evaluator's, and compiler-owned values (syntax, cursors, builders) cross as
handles.

A site the native tier cannot take yet runs in the evaluator: code that passes
a function to a compiler API call, a capability provider whose types the compiler
bridge cannot carry, a compile global still holding a kept value
native code can't take in (an object, a map, a nested array, or any value of a
`compile val`), a result only the compiler can hold
(a generator, task, thread, borrow, `Weak` or raw pointer), a cross-target
site not proven portable, the REPL, and a compilation that compile-time code
starts inside the active outer pass.

Under `auto` (the default) and `jit`, a Wasm32 module (including a `wasmBuildModule`
child) can run portable compile-time sites natively. Other cross-target families
keep their existing evaluator fallback. The slice
always uses the host's code generator and layout; a Wasm platform runtime is
replaced by the compiler-owned hosted platform inside the slice, while user
modules remain those parsed for the target. Only encoded values cross back
to the target program. A separate conservative reachability check permits scalar
integer computations, strings, arrays and plain classes, with audited `abla/bytes`,
`abla/crypto`, `abla/text`, `abla/json` and filesystem declarations, plus known capability
providers through their existing evaluator bridges. A direct `compilerEnvironment(name)`
read is also bridged: it requires the source grant and manifest authorization for
`environment`, and the named value is journaled and revalidated on cache reuse.
An environment read reached through another global's initializer remains
interpreted; for example, `val ASSET_HOST = #assetHost()` followed by
`#assetTable(ASSET_HOST)` cannot yet replace replay with the earlier value.
The trace names that global. Other compiler and parser queries
remain interpreted for cross-target sites. It rejects unknown constructs and dependencies, raw pointers
and memory operations, native externs, target/CPU probes, SIMD, assembly, resources
`when is` interface dispatch, floating-point computation, and unrecognised modules or annotations. Extension-field defaults are implicit
roots of every native slice, so a module containing them also keeps cross-target
sites interpreted until those roots have a portability proof. Such sites keep the evaluator's behavior;
`ABLA_COMPILE_EVAL_TRACE=1` names the first dependency the proof refuses. The
`ablaAtCompileTime()` branches used by byte buffers are true on both tiers, so
unexecuted native staging paths do not make their portable SHA operations target
dependent. This does not permit a genuinely reentrant
compile pass to replace its outer pass's JIT state.

JSON in a cross-target site (#795): `jsonParse`, `jsonDocument` and their readers
(`Json`, `JsonNode`, `JsonCursor`), `JsonLimits` and the error results run natively when every
declaration they reach passes the same checks as any other code. These keep a site in
the evaluator, and the trace names them. Floats: `asF64`, `readNumber`, `f64ParseRange`
and the encoder's `number` are refused, because a finite set of passing tests does not prove that
the host and the evaluator agree on every NaN payload, signed zero, subnormal, rounding mode,
conversion and fused operation; a proof would need a specified operation set, not samples.
And the shared empty arrays and number every parsed scalar points at (`jsonNoKeys`, `jsonNoValues`,
`jsonNoNumber`, and the two limits records) are ordinary globals: any compile-time code that can
write one (`jsonNull().keys.append(x)`, or a raw store) sends every site that reaches it to the
evaluator, as for any ordinary global. The encoders' raw-pointer writes (`jsonStringify`) go to buffers of their own, and a
`JsonLimits` read from a global (`jsonDefaultLimits()` passed explicitly, or a user's `val`) reaches them only through scalar
fields; since #828 neither keeps a site in the evaluator. The scanning intrinsics (`ablaJsonWhitespaceEnd`,
`ablaJsonFindPlainStringEnd`, `ablaJsonMatchCompactObjectField`, `ablaJsonCompactArrayNext`,
`ablaJsonAvailableIntegerEnd`, `ablaJsonIntegerValueAt`, `ablaJsonStringIsPlain`,
`ablaTextIsValidUtf8`, `ablaTextReadU32LittleEndian`, `ablaTextFindByte`, `ablaTextAsciiEqualInsensitive`,
`ablaUtf8EncodeScalar`) cross because the evaluator and the native
code answer alike for every argument (`tests/cases/compile-eval-json/intrinsics.ab`). `$json` and
`$jsons` stay in the evaluator: they use the parser API.

For a statically resolved method on a concrete receiver, or any extension function
(an operator such as abla/ct's `secretU64.minus` included), the slice's reach and
the ordinary-global write analysis use the type checker's selected declaration,
in host and cross-target builds alike (#828). An unrelated type's method with the
same name does not become a dependency of that call. Unknown, ambiguous,
generic or interface dispatch keeps the conservative candidate set; retained
class bodies and eager global initializers still need their existing checks.
The write analysis gives a parameter of a scalar or string type no origins: such
a value is no part of any global's heap, whatever it was computed from.

- A runtime panic in native compile-time code is the evaluator's error for the
  same failure, with the same text (`E_EVAL_OUT_OF_BOUNDS`,
  `E_EVAL_DIVISION_BY_ZERO`, else `E_CT_PANIC`); an abort, a failed check or
  recursion past the end of the compiler's stack is `E_CT_STOPPED`. `panic` is
  a runtime panic with its message, and `exit(code)` is `E_CT_STOPPED`
  ("compile-time code called exit(3)"), as in the evaluator. The compiler
  survives each, and the rest of the pass runs in the evaluator.
- Native code manages memory as a hosted program's `main` does: globals are
  collector roots, and allocation pressure collects unless the code calls
  `memorySetManualCollection()`.
- Native code has no step limit. One evaluation may run for
  `ABLA_COMPILE_EVAL_TIME_LIMIT` seconds (default 600, `0` for no limit), then
  stops with `E_CT_TIME_LIMIT`. An interpreted site has the same limit besides
  its step limit. A call blocked in the kernel (an accept, a wait for a child,
  a read of a pipe) is interrupted when the limit passes, so a build never hangs
  on compile-time code. A provider call (the clock, `sleep`, a file read, the
  compiler API) runs in the compiler: a native site stops when that call
  returns, never in the middle of it, and a compile-time `sleep` wakes at the
  limit instead of sleeping on. The sites of a module that requests `time.unlimited`
  (and whose manifest authorizes it) have no time limit; every other module's
  keep it. An unlimited module's site can run inside another site's native
  call: the first call of a generation initializes the globals the
  generation keeps, and a site in one of their initializers runs there. The
  call's limit is paused while that site's code runs, and only then, so the
  rest of the call keeps its limit.
- `compile val`/`compile var` hold one value for the compilation on both
  tiers: after each native call their values are kept as the evaluator keeps
  them. When an evaluated site changes a `compile var` the slice holds whose
  type is `int`, `bool`, `f64` or `string`, or an array of those, the new
  value goes back into the native code. A change to a global of any other
  type makes the rest of the pass fall back to the evaluator.
- `ABLA_COMPILE_EVAL_TRACE=1` prints, per site, whether it ran natively or why
  it did not; `ABLA_COMPILE_EVAL_DUMP=<directory>` keeps each slice's LLVM
  module.
- A slice of up to 700 functions (the usual one) is optimized with the `--o1`
  pipeline, a larger one (a TLS stack) with the fast one: code that works hard
  runs several times faster optimized and a small slice pays about 15% more
  code generation for it, a large one twice that. `ABLA_COMPILE_EVAL_PASSES=fast|balanced`
  chooses for every slice.
- A generation of 60,000 IR instructions or more is cut into code generation
  units after its passes, as an ordinary build is
  ([toolchain.md](toolchain.md)): child compilers generate them at once, at the
  same level, and the session loads their objects. A unit's object goes to the
  code generation cache under a key that names this host's processor and the
  JIT's machine, so it is never shared with an ordinary build. Functions that
  use a thread-local stay in a small module that the session generates itself.
  Splitting took a 72,000-instruction generation from 1.9 s to 0.6 s and the
  5,326 functions of #1022 from 9.3 s to 3.3 s (1.4 s from the cache); below
  50,000 the passes dominate and it neither gains nor costs. `ABLA_COMPILE_EVAL_UNITS=0`
  keeps every generation one module; `ABLA_CODEGEN_UNITS_MINIMUM` changes the
  threshold.
- While a generation is prepared, analyzed and lowered, the compiler collects
  when its heap has grown by what the last collection kept, if that is more
  than its usual step (256 MB, `ABLA_COMPILER_COLLECT_GROWTH_MB`): the
  program's own analysis stays live meanwhile and every collection walks it
  again. A small slice changes nothing; the client of #1022 (about 350 MB kept)
  spends 0.9 s less in those phases, at the same peak.

## Diagnostics

A `#` site that fails is reported the same way in both tiers: the error's code and text, where it failed, the
program's functions it was in (innermost first), the site it came from, and a last line that says compile-time
evaluation failed (`tests/cases/ct-site-errors/bounds.ab`):

```text
error[E_EVAL_OUT_OF_BOUNDS]: index 7 out of bounds for array of size 3
source[eval]:bounds.ab:246:255
  --> bounds.ab:4:45
source[frame:pick]:bounds.ab:192:255
  = note: in `pick`, declared at bounds.ab:3:1
source[frame:table]:bounds.ab:257:332
  = note: in `table`, declared at bounds.ab:6:1
source[site]:bounds.ab:346:354
  = note: in `#table()` at bounds.ab:12:13
compile-time evaluation failed: 1 error(s)
```

The place line (`-->`) is the one part that differs. The evaluator knows the expression it was evaluating. Native code
has no line table, so its place is the site, and the line says so:

```text
  --> bounds.ab:12:13 (its `#` site: the native tier's code has no line table)
```

Native code finds the functions from its frames, so it names the ones it didn't inline into their callers (here
`pick` and `table` are `@noinline`; a small function is often inlined, and then only its caller is named). Both tiers
name a run of recursive calls once, at most eight functions, and none of the standard library's.

A site that can run again without anyone seeing it, one that reaches no compile-time provider (files, the
environment, the clock, output…), no compiler API, no `extern:"c"` code, no compile global and no global compile-time
code writes, is run again in the evaluator when its native code fails (but not past the time limit). If it fails
there the same way within a million steps, the report has the evaluator's place and path, inlined functions too:

```text
  --> bounds.ab:4:45 (found by rerunning the site in the evaluator)
```

`ABLA_COMPILE_EVAL_TRACE=1` says for each native failure whether its site was rerun, and if not, why.

The `source[...]` lines are the same places for tools, in byte offsets.

| Code | Meaning |
|---|---|
| `E_EVAL_EXPRESSION` | compile-time evaluation failed; the message names the expression kind and its byte range |
| `E_EVAL_STEP_LIMIT` | an evaluation ran past the step limit |
| `E_EVAL_STACK_DEPTH` | an evaluation nested deeper than the compiler's stack allows ([limits](#limits)) |
| `E_EVAL_MEMORY_UNAVAILABLE` | the runtime memory API called in the evaluator, which has no program heap |
| `E_EVAL_DIVISION_BY_ZERO` | an integer division or remainder by zero, which panics at run time |
| `E_EVAL_OUT_OF_BOUNDS` | an index or slice outside a string or an array, or a negative `truncate` or `filledArray` count; the message is the run-time panic's |
| `E_CT_STOPPED` | compile-time code called `exit`, or native compile-time code aborted, failed a check or made a bad memory access ([native evaluation](#native-evaluation)) |
| `E_CT_TIME_LIMIT` | an evaluation ran past `ABLA_COMPILE_EVAL_TIME_LIMIT` |
| `E_CT_PANIC` | compile-time code called `panic`, or native compile-time code panicked with a reason the evaluator has no code of its own for |
| `compile.effect-denied:<capability>:<call path>` | the code needs a capability that this module didn't grant |
| `compile.capability-not-authorized:<capability>` | the module grants a capability that `abla.toml` doesn't authorize |
| `compile.capability-unknown:<name>` | the grant names no known capability |
| `compile.value-runtime:<name>` | run-time code reads a `compile val`/`compile var` |
| `compile.call-runtime:<name>` | run-time code calls a `compile fun` or the compiler API ([`compile fun`](#compile-fun)) |
| `compile.result: <type> cannot become a program value: <reason>` | a `#` result that exists only inside the compiler (a generator, task, thread, borrow, `Weak`, raw pointer, or object with `drop()`) |
| `declaration.block.compile-only` | a declaration block in run-time code |
| `E_COMPILE_GRANT_PHASE` | compile-time code called `compilerGrant`; grants are literal top-level actions |
| `E_EXT_SUBPARSER_REGISTRATION` | an invalid or duplicate subparser registration, or one made from compile-time code |
| `E_EXT_GENERATED_MODULE_PHASE` | `compilerGenerateModule` ran after the program was analyzed (outside a transform) |
| `E_PACKAGE_CAPABILITY_DENIED` | a dependency asks for a capability the root project doesn't authorize |
