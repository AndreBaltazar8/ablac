# Debugging Abla programs

A build with debug information maps the machine code back to Abla: every
lowered expression carries its file, line and column into DWARF line tables,
each function is named after its declaration, and native code keeps a
frame-pointer chain. Debuggers, crash reports and browser developer tools then
show Abla stacks and sources.

## When a build has debug information

| Build | Debug information |
| --- | --- |
| `ablac build … --fast` (development) | on |
| `ablac build …` (release: O2, and for WebAssembly LTO + wasm-opt) | off: the output is unchanged |
| `-g` / `--debug` | on, for any build (a release WebAssembly module then skips wasm-opt, whose rewrite would lose the line tables) |
| `--no-debug` | off, for any build |
| `ABLA_DEBUG=1` / `ABLA_DEBUG=0` | on / off when no flag says otherwise; also reaches the programs a build program (`buildProgram`, `wasmBuildModule`) builds |

`ablac run --built` builds as `ablac build` does in its profile (`--o1` by
default), with debug information for `--fast` or when `ABLA_DEBUG` asks;
`ablac run` (in process) and `ablac serve` execute without debug information. The setting is
part of the build cache's identity, so switching it never reuses the other
kind of object.

What a debug build contains:

- **Line tables** (DWARF 5). Each instruction's location is the Abla
  expression it was lowered from; an implicit return belongs to the body's
  last line. An optimized build (`-g` on a release build) has line tables only:
  its optimizations would leave variables wrong.
- **Variables and their types** in a native development build (`--fast`):
  every function's parameters and locals, by the names the source gave them
  ([Variables](#variables)).
- **Source paths relative to the project.** A native object's compilation
  directory is `.` (like clang's `-fdebug-compilation-dir=.`) and a source is
  named relative to the entry source's directory, the project root: `ablac build
  d/main.ab`, `cd d && ablac build main.ab` and `ablac build /abs/d/main.ab` give
  the same bytes, naming `main.ab` and `sub/helper.ab`. A source outside the
  root that the build named relatively keeps a `..` path from it; the standard
  library's (and any other absolute file outside the root) keep their absolute
  paths, which `--path-prefix-map OLD=NEW` rewrites (clang's
  `-fdebug-prefix-map`: `--path-prefix-map $ABLA_SYSROOT=/abla` makes the object
  the same on every machine; a build that gives it skips the build cache). Run the
  debugger from the project root and it finds the sources; elsewhere, map them
  (`settings set target.source-map . /path/to/project` in lldb). The working
  directory never reaches the object, so a copy of a project built from its own
  root gives the same object, and a shared build cache (`--cache-dir`) serves
  both (tools/test-reproducible-paths.sh). A WebAssembly module's DWARF keeps
  absolute paths, which browser developer tools resolve as file URLs.
- **Readable symbols.** Each emitted function is named
  `<module>.<declaration>`: `renderer.Renderer.draw` for the method `draw` of
  `Renderer` in `renderer.ab`, `exit.panic` for `panic` in
  `abla/process/exit/entry.ab` (an `entry.ab` takes its directory's name),
  `main.update.lambda` for a lambda in `update`. Exported symbols keep their
  export names. Global initializers and compiler-generated drops have no
  source position and no line rows.
- **Frame pointers** on native targets (`"frame-pointer"="all"`), so unwinders
  and crash reporters walk the whole Abla stack.
- **A stack on a crash** (hosted executables): `panic(message)` and the
  runtime's own panics (an index out of bounds, a division by zero, a stack
  overflow, the memory limit) print `panic: <message>` and the stack, then
  exit with status 101; a trap (a failed internal check), a bad memory access
  or an abort prints `fatal signal` and the stack before the process ends
  with the signal as before (a bad memory access with its address, as a
  release build names it). The frames are
  named by the symbol table; on macOS the image's load address follows, for
  `atos`. Return addresses are printed one byte back, inside their calls, so
  `atos`/`addr2line` report the call's line. A release build prints the same
  `panic: <message>` (exit status 101) without the stack, and a bad memory
  access (a SIGSEGV or SIGBUS the kernel raised) as
  `fatal signal: a bad memory access at 0x0000000000000010` before the process
  ends by the signal.

## Native: lldb, atos, crash reports

The executable's DWARF stays in its object file (`<output>.o`, kept beside the
output; Mach-O executables point at it, as with any unlinked debug map). Keep
the object next to the executable, or run `dsymutil <output>` to gather a
`.dSYM` that travels with it.

```sh
ablac build app.ab -o build/app --fast
lldb build/app -o 'breakpoint set -n _exit' -o run -k bt   # stops at a panic
```

```text
* frame #2: app`self.__ablaRuntimePanicIndex at entry.ab:742:5
  frame #4: app`app.inner at app.ab:5:5
  frame #5: app`app.middle at app.ab:10:5
  frame #6: app`app.main at app.ab:14:18
```

Breakpoints take Abla files and lines (`breakpoint set -f app.ab -l 10`) or
the readable names as a pattern (`breakpoint set -r 'app\.middle$'`; lldb reads
a plain dotted name as a C++ scope). gdb takes them as they are
(`break app.middle`, `break app.ab:10`).

### Variables

A development build (`--fast`) describes every function's parameters and
locals, by the names the source gave them, with types that read their values
as Abla wrote them (tools/test-debug-variables.sh):

| Abla | Shown as |
| --- | --- |
| `int`, `float`, `bool` (and the sized integers) | the number or bool |
| `string` | `{data = "pt=5", length = 4}` (a rope's `data` is null) |
| an instance of a class | its fields: `{class = …, extension = 0, x = 2, y = 3}` (the first two are its header) |
| a nullable instance | a pointer to it: `print *maybe` |
| `array<int>`, `array<float>` | a pointer to `{length, capacity, data}`: `print *items.data@items.length` (gdb), `parray 3 items->data` (lldb) |
| any other value | the universal value: `{tag, flags, word0, word1}` |

```text
(gdb) break probe.ab:14
(gdb) run
Breakpoint 1, probe.describe (p=..., label=...) at probe.ab:14
(gdb) info args
p = {class = 4611826755781206992, extension = 0, x = 2, y = 3}
label = {data = 0x7ffff7fb2744 "pt", length = 2}
(gdb) info locals
items = 0x7ffff7ea8080
maybe = 0x7ffff7ea8030
text = {data = 0x7ffff7ea80e0 "pt=5", length = 4}
total = 5
ratio = 3.75
```

A field that refers to another instance is an untyped pointer (the layout does
not say which class). `--fast` still optimizes a little (O1), so a local can
read `<optimized out>` after its last use. The calls through the dispatch
table appear between frames as `<function>.boxed` (`probe.main.lambda.boxed`,
the entry the table calls) without a line, and `step`/`next` pass through
them. A release build with `-g` has no variables.

The stack a debug build prints on its own resolves with `ablac symbolize`,
given the program and the text it printed (a file, or standard input): each
frame's function and file:line:column, with the functions inlined into it
(llvm-symbolizer on the program; atos on macOS, with the load address the text
names). The program must be the very one that crashed.

```sh
build/app 2> crash.txt
ablac symbolize build/app crash.txt
```

```text
#2 self.__ablaRuntimePanicArrayIndex at …/stdlib/abla/runtime/self/entry.ab:1912:5
#3 self.__ablaRuntimeArrayIndex at …/stdlib/abla/runtime/self/entry.ab:2928:37
    (inlined by) self.__ablaRuntimeArrayGetWordOther at …/entry.ab:3172:19
#4 self.__ablaRuntimeArrayGetI64 at …/stdlib/abla/runtime/self/entry.ab:3156:12
    (inlined by) app.inner at app.ab:7:12
    (inlined by) app.middle at app.ab:10:31
    (inlined by) app.main at app.ab:13:16
```

By hand, `atos -o build/app -l <load address> <address>` (macOS) or
`addr2line -f -i -e build/app <address less the load address>` (Linux) give the
same.

macOS crash reports (`~/Library/Logs/DiagnosticReports`) show the readable
names for every frame thanks to the frame-pointer chain.

### A release build that names its stack: `--backtrace`

`ablac build --backtrace` makes a release build (optimized as usual, no debug
information, no symbol table) that prints the stack on a panic or a fault, as
a debug build does, each frame named by a table of the program's functions
built into it. A fault's stack starts at the faulting instruction:

```text
fatal signal: a trap, a bad memory access or an abort
stack (return addresses: subtract the load address, then addr2line or gdb on the program gives file:line):
0x000055718bd589d9 in sema.BootstrapStringSet.slotOf (the faulting instruction)
0x000055718b770b5e in sema.BootstrapStringSet.add
0x000055718bb55645 in overload.bootstrapOverloadAddNames
…
0x000055718b7aa8f3 in main
load address 0x000055718b500000
```

A frame is named by the function its address is in, so a function inlined
into another shows as the one it was inlined into. On Linux (and Windows:
below) the build also
writes `<output>.debug` beside the program: the same build's line tables,
which the program itself doesn't carry, tied to it by its build id and a
debug link. Keep it with the program (it needn't ship): `ablac symbolize`
(and gdb) find it there and add file:line and the inlined calls to the
stack the program printed. Frames outside the program
(the C library's, in a program that links it) are left unnamed. Without
`--backtrace` a release build is byte for byte what it was.

A WebAssembly module's host walks its stack, so there `--backtrace` (on the
build that runs `wasmBuildModule` or `buildProgram`) keeps the module's name
section, its functions under their readable names, and a trap's stack in a
browser or Node names them:

```text
RuntimeError: unreachable
    at crash.wasm.self.__ablaRuntimePanic (wasm://wasm/crash.wasm-948bddf2:wasm-function[5]:0x16c6)
    at crash.wasm.crash.crash (wasm://wasm/crash.wasm-948bddf2:wasm-function[8]:0x1c1e)
```

### Windows

A hosted Windows program (`--target x86_64-windows-hosted`) reports how it
died as a Linux one does, through a vectored exception handler its `main`
installs. Every build says what ended it: a panic its message (status 101), a
stack overflow `panic: stack overflow` (status 101), a bad memory access
`fatal signal: a bad memory access at 0x…` and any other exception its code.
The process then ends with the exception's code as its status (0xC0000005 for
an access violation), as Windows would end it, without the error-reporting
dialog. A `--backtrace` build prints the stack too, named as on Linux; a `-g`
or `--fast` build prints it unnamed:

```text
fatal signal: a bad memory access at 0x0000000000000010
stack (return addresses: subtract the load address, then llvm-symbolizer on the program gives file:line):
0x0000000140001f1e in crash.main.boxed (the faulting instruction)
0x0000000140009b74 in main
0x0000000140009eb5 in abla_windows_start
0x00006fffffec48ac
load address 0x0000000140000000
```

The stack is unwound by the system (`RtlVirtualUnwind`) over the unwind
tables that a `-g` or `--backtrace` build gives every function; a release
build imports neither the unwinder nor those tables.

`ablac symbolize` gives the stack's file:line as on Linux. A `-g` or
`--fast` program carries its DWARF. A `--backtrace` program carries neither
DWARF nor a symbol table: the build writes `<output>.debug` beside it (the
same build's line tables, named by the program's debug link), which
`ablac symbolize` and llvm-symbolizer find there:

```sh
crash.exe store 2> crash.txt        # on Windows
ablac symbolize crash.exe crash.txt
```

By hand, llvm-symbolizer takes each address less the load address plus the
image's preferred base (0x140000000). The frames past
`abla_windows_start` are the system's. An exception that a system library
raises and handles itself never reaches the report, since only an exception
raised by the program's own code is reported. A stack overflow prints no
stack, because the handler runs on what is left of the overflowed one.
tools/test-windows-crash.sh checks all of this under Wine.

## WebAssembly: browser developer tools

A debug module (`artifact = "module"` on a WebAssembly target) is published with
two files beside it:

- `<module>.debug.wasm` — the module with its DWARF;
- `<module>.map` — a source map from code offsets to Abla file:line:col, with
  the sources inlined. A frame inside a function's inlined calls maps to the
  call in that function, so each frame of a stack reads at its own line.

The module itself keeps its `name` section (functions are named as above, so
stack traces read `at renderer.Renderer.draw (…wasm-function[812]:0x1a2b)`; a
function's dispatch-table entry, often where its body was inlined, is
`<name>.boxed`: `probe.main.lambda.boxed`),
drops its DWARF, and names both files in custom sections — `sourceMappingURL`
and `external_debug_info` — as URLs relative to its own. Serve the two files
next to the module; a hosting page that fails to serve them only loses the
debugging. Release modules have none of this.

Developer tools in Chromium-based browsers:

- **Without extensions**, the source map works: the Sources panel lists the
  Abla files (under `file://`), and breakpoints and stepping work by line in
  them. The call stack shows the readable names.
  The map puts the standard library's sources on its ignore list (`ignoreList`,
  and `x_google_ignoreList` for older Chromium), so stepping over a line does
  not stop in the runtime code inlined into it, and those frames are hidden by
  default.
- **With the "C/C++ DevTools Support (DWARF)" extension** (Chrome Web Store),
  developer tools read `<module>.debug.wasm` instead: Abla sources, line
  breakpoints and stepping that follows inlined calls. Enable *Settings →
  Experiments → WebAssembly Debugging: Enable DWARF support* if your version
  still lists it. The DWARF names absolute source paths; when the sources live
  elsewhere, map them under the extension's options (*Path substitutions*).

A host that catches traps can symbolize their stacks itself: read the
module's `sourceMappingURL` section (`WebAssembly.Module.customSections`), fetch
the map, decode its mappings (one generated line; the column is the module
byte offset that stack frames print as `:0x…`), and look up each frame's
offset — the greatest mapped offset at or below it.

## Collector stress: `ABLA_GC_STRESS=1`

A value that some function fails to keep rooted is only freed when a
collection happens to run while it is unrooted, which under normal pressure
can take millions of allocations. Run a hosted native program with
`ABLA_GC_STRESS=1` to make every safe point collect: the program reads the
variable once at startup, and then each allocating function collects on entry
(and a loop that allocates on every 1,024th pass over its back edge, so building
a long list doesn't walk it once per node).
A missing root then frees its value at once, and the next use of it fails
close to the cause.

```sh
ABLA_GC_STRESS=1 build/app
```

The collector also **poisons what it frees**: both sweeps fill each freed block
with `0xDB` bytes (`0xDBDBDBDBDBDBDBDB` as an `int`) before the block goes back to
the heap. Without the variable a freed block keeps its old bytes until it is
reused, so a use after free often still "works": a string reads right, a native
C string still holds its path. Under stress it reads garbage at once. An `int`
or an address that comes out as `-2604246222170760229`, a string of `\xDB`
bytes, or a pointer to such a block means the value was freed while something
still held it: look for an address kept as an integer past a safe point
(`nativeCStringAddress` copies are collected allocations too, so a native table
must live in a native buffer, not in such copies), or a value that no root
holds. Run a program once plain and once under stress and compare; the suite
does this in `tools/test-gc-stress-io.sh`, where each program must exit 42 both
ways.

Expect the program to run much slower (each collection walks the whole heap),
so use small inputs. The variable changes nothing else: results and output
are the same as without it, unless the program uses freed memory. A program in manual collection mode
(`memorySetManualCollection()`) has no safe points, so it is unaffected.
WebAssembly modules don't read it. Without the variable it costs nothing:
the safe point's check is the same compare either way.

A program can also stress a part of itself: `memorySetStress(true)` and
`memorySetStress(false)` from `abla/memory` turn stress on and off, and
`memorySetStressStride(n)` makes only every `n`-th safe point collect while it
is on (1, the default: every one). A stride keeps a long run within a time
budget; a stop another thread asked for is never skipped. `memoryHeapStat(14)`
counts the collections that finished, so a test can check that its window
really collected.

The compiler itself is such a program, and under `ABLA_GC_STRESS=1` its fixed
work (the prelude and the standard library) collects at every safe point: a
hello build, or a three-module editor session, takes longer than ten minutes.
`ABLA_COMPILER_GC_STRESS=<scope>[:<stride>][,...]` stresses its heap only while
it runs one part: `ct` (a native compile-time call of a generation that can start
threads), `analysis` (each request the analysis service handles) or
`analysis-edit` (those after the service's first analysis). The compiler then
writes `abla-gc-stress <label> collections <n> stops <m>` to standard error for
each window (the label is `ct`, or `analysis` and the request's method): its
collections of the compiler's heap, and those that stopped other threads. `tools/test-ct-threads-heap-stress.sh` and
`tools/test-analysis-gc-stress.sh` use it.

### Poison only: `ABLA_GC_POISON=1`

`ABLA_GC_POISON=1` poisons what each collection frees, as stress does, but
collects no more often than usual. Use it when a program is too large to run
under stress, and make collections more frequent some other way: a smaller
growth (`ABLA_GC_GROWTH=<bytes>`, or `memorySetCollectionGrowth`). For the
compiler itself, `ABLA_COMPILER_COLLECT_GROWTH_MB` sets its own step (default
256 MB; 1 collects every megabyte). A block freed while something still held
its address then reads as `0xDB` bytes at the next use, not as its old bytes.
The program reads the variable once at startup, and stress already includes
it. `tools/test-ct-readback-collect.sh` builds with both variables: a
compile-time reply buffer kept only as an `int` was freed by a collection
inside the code that filled it.

```sh
ABLA_GC_POISON=1 ABLA_GC_GROWTH=1048576 build/app
```

## Cost

Debug information leaves release builds untouched. In a development build of
a large browser program (about 6,900 functions) it adds roughly 100 KB to the
served module (the name section), a source map of a few MB and a debug module
of a few tens of MB that only developer tools load, and some seconds of
build time (code generation with line tables, and the map). `--no-debug`
skips all of it. A native development build's variables and types add about
40% to its executable (168 KB to 240 KB for tests/cases/debug-variables, 154
KB to 220 KB for tests/cases/action-journal/queries.ab) and 2% to 11% to its
build time.

`--backtrace` adds the walk and the table to a release executable: 9 KB to
hello (30 KB to 39.5 KB) and binary-trees (36 KB to 45.6 KB), with a
57 KB and 65 KB `.debug` file beside them; to the compiler
itself (about 3,250 functions) 116 KB of names and 52 KB of table, offset by
smaller code. Its frame pointers cost up to 7% in speed (binary-trees +6.9%,
fannkuch +1.8%, fasta +1.2%, mandelbrot and spectral-norm unchanged) and
nothing measurable in the compiler's build time. On a WebAssembly module the
name section is the whole cost: 496 bytes on tests/cases/wasm-backtrace (7,576
to 8,072), 653 on binary-trees, about 100 KB for 6,900 functions.

## Collector trace: `ABLA_GC_TRACE=1`

`ABLA_GC_TRACE=1` writes one line to standard error for each collection, `gc: live <bytes> bytes before, <bytes> after, <n> ms, mapped <bytes> parked <bytes>` (live bytes by the heap's own count, the heap's chunks mapped and the freed bytes parked on its lists),
and a line for each stop that parked threads (`gc: stopped <n> thread(s)`) or was abandoned and why, and one for each freeze (`gc: freeze <n> ms`, the copy into a frozen group, the page directory build included). The live bytes after a
collection are what the next one marks again, so for a long-running server they are its long-lived state: the framework's
own event server (tests/cases/http-peer/server.ab shape, 300,000 requests) keeps 22 KB and collects in 2 ms, so only an
application's caches could make a copy into read-only memory (`docs/design/frozen-heap.md`) worth having.

A foreground collection also prints `gc: directory reason <n>`. The reason is
0 when the registry sufficed, 1 under GC stress, 2 when the directory was forced,
3 after a recent fallback, 4 when the mapping snapshot was unavailable, 5 when
the registry was outside the snapshot, 6 on a pointer lookup miss, or 7 when
scanning raw words. Reason 6 has a matching `gc: directory miss source <n> result <n>`
line. Source 1 is a root and 2 is a value reached during marking. Result 0
means no tracked allocation contains the pointer, 1 is a payload start, and 2
is an interior pointer.

With adaptive pacing, `ABLA_GC_TRACE=1` also prints `gc: native charge <bytes> next <bytes>`.
These are the native allocation volume accounted for since the preceding
collection and the next pressure threshold.
