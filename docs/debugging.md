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

`ablac run` and `ablac serve` execute without debug information. The setting is
part of the build cache's identity, so switching it never reuses the other
kind of object.

What a debug build contains:

- **Line tables** (DWARF 5, line tables only: no types or variables). Each
  instruction's location is the Abla expression it was lowered from; an
  implicit return belongs to the body's last line.
- **Readable symbols.** Each emitted function is named
  `<module>.<declaration>`: `renderer.Renderer.draw` for the method `draw` of
  `Renderer` in `renderer.ab`, `exit.panic` for `panic` in
  `abla/process/exit/entry.ab` (an `entry.ab` takes its directory's name),
  `main.update.lambda` for a lambda in `update`. Exported symbols keep their
  export names. Global initializers and compiler-generated drops have no
  source position and no line rows.
- **Frame pointers** on native targets (`"frame-pointer"="all"`), so unwinders
  and crash reporters walk the whole Abla stack.
- **A stack on a crash** (hosted executables): a trap (an index out of range, a
  failed check), a bad memory access or an abort prints `fatal signal` and the
  stack before the process ends with the signal as before; `panic(message)`
  prints the message and the stack, then exits with status 101. The frames are
  named by the symbol table; on macOS the image's load address follows, for
  `atos`. Return addresses are printed one byte back, inside their calls, so
  `atos`/`addr2line` report the call's line.

## Native: lldb, atos, crash reports

The executable's DWARF stays in its object file (`<output>.o`, kept beside the
output; Mach-O executables point at it, as with any unlinked debug map). Keep
the object next to the executable, or run `dsymutil <output>` to gather a
`.dSYM` that travels with it.

```sh
ablac build app.ab -o build/app --fast
lldb build/app -o run -k bt          # stops at a trap; bt shows app.ab:line:col frames
```

```text
* frame #0: app`self.__ablaRuntimeArrayIndex at entry.ab:1456:9
  frame #4: app`app.inner at app.ab:5:5
  frame #5: app`app.middle at app.ab:10:5
  frame #6: app`app.main at app.ab:14:18
```

Breakpoints take Abla files and lines (`breakpoint set -f app.ab -l 10`) or
the readable names as a pattern (`breakpoint set -r 'app\.middle$'`; lldb reads
a plain dotted name as a C++ scope). There is no variable information yet.

The stack a debug build prints on its own resolves with `atos` (macOS) or
`addr2line` (Linux):

```sh
atos -o build/app -l <load address> <address>   # → app.inner (in app) (app.ab:5)
addr2line -f -e build/app <address>            # Linux: position-independent offsets
```

macOS crash reports (`~/Library/Logs/DiagnosticReports`) show the readable
names for every frame thanks to the frame-pointer chain.

## WebAssembly: browser developer tools

A debug module (`artifact = "module"` on a WebAssembly target) is published with
two files beside it:

- `<module>.debug.wasm` — the module with its DWARF;
- `<module>.map` — a source map from code offsets to Abla file:line:col, with
  the sources inlined. A frame inside a function's inlined calls maps to the
  call in that function, so each frame of a stack reads at its own line.

The module itself keeps its `name` section (functions are named as above, so
stack traces read `at renderer.Renderer.draw (…wasm-function[812]:0x1a2b)`),
drops its DWARF, and names both files in custom sections — `sourceMappingURL`
and `external_debug_info` — as URLs relative to its own. Serve the two files
next to the module; a hosting page that fails to serve them only loses the
debugging. Release modules have none of this.

Developer tools in Chromium-based browsers:

- **Without extensions**, the source map works: the Sources panel lists the
  Abla files (under `file://`), and breakpoints and stepping work by line in
  them. The call stack shows the readable names.
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

## Cost

Debug information leaves release builds untouched. In a development build of
a large browser program (about 6,900 functions) it adds roughly 100 KB to the
served module (the name section), a source map of a few MB and a debug module
of a few tens of MB that only developer tools load, and some seconds of
build time (code generation with line tables, and the map). `--no-debug`
skips all of it.
