# Abla documentation

Start with the [README](../README.md) for what Abla is and how to build the
compiler. The documents below are grouped by what you are trying to do.

## Writing Abla

| Document | What it covers |
|---|---|
| [language.md](language.md) | The language reference: syntax, declarations, types, ownership, control flow, modules |
| [ownership.md](ownership.md) | Who may change a value and who cleans it up: `var`/`own` parameters, `move`, resources, borrows, `Shared`/`Mutex`, closures |
| [concurrency.md](concurrency.md) | `defer`, generators, tasks and threads |
| [regions.md](regions.md) | `region { ... }`: scoped allocation and its escape rules |
| [standard-library.md](standard-library.md) | The `abla/...` modules and their layering |
| [json.md](json.md) | `abla/json`, `$json` and `$jsons` |
| [networking.md](networking.md) | Sockets, HTTP, WebSocket, TLS and JWT |
| [debugging.md](debugging.md) | Debug builds, stack traces, panics |

## Compile time

| Document | What it covers |
|---|---|
| [compile-time.md](compile-time.md) | `#expression`, `compile fun`, top-level actions, `compile val`/`compile var`, capabilities, limits, declaration blocks |
| [compiler-api.md](compiler-api.md) | The `abla/compiler` module: reflection, transforms, generated code, exports |
| [subparsers.md](subparsers.md) | `$name` subparsers: parsing your own syntax at compile time |
| [programmable-builds.md](programmable-builds.md) | Building other programs, Wasm modules and libraries from compile-time code |
| [packages.md](packages.md) | `import github(...)` and other source providers, `abla.lock`, vendoring |

## Tools and targets

| Document | What it covers |
|---|---|
| [toolchain.md](toolchain.md) | `ablac build`, `run`, `repl`, `serve`, `package`; targets and Wasm |
| [llvm-backend.md](llvm-backend.md) | How code is emitted; `@naked`, `@section`, inline assembly |
| [freestanding.md](freestanding.md) | Programs without libc or an operating system |
| [performance.md](performance.md) | Compiler speed and memory budgets |

## The compiler project

[status.md](status.md), [bootstrap.md](bootstrap.md),
[self-hosting.md](self-hosting.md), [full-self-hosting.md](full-self-hosting.md),
[reliability-roadmap.md](reliability-roadmap.md),
[compile-effect-path-performance.md](compile-effect-path-performance.md) and
[original-audit.md](original-audit.md) record the state and the plans of the
compiler itself.

## Examples

Every Abla code block in these documents is checked by
`tools/test-doc-examples.sh`, which `make test` runs. The word after `abla` in
the block's fence says what is checked:

| Fence | Checked |
|---|---|
| ` ```abla ` | A complete program. It must compile. If it declares `fun main`, it is run. |
| ` ```abla build ` | A complete program that is compiled but not run (a server, a program that reads input). |
| ` ```abla error ` | A program that must fail to compile. Each `// error: TEXT` comment in it names text the diagnostics must contain. |
| ` ```abla fragment ` | Not compiled: syntax shown out of context. |
| ` ```abla file=NAME ` | Not compiled on its own: written as `NAME` next to the later programs of the same document, so they can import it. |

A runnable program states what it prints with an `// output:` comment followed
by one `//` line per output line, and its exit status with `// exit: N`
(when a program has an `// output:` block, its expected exit status is 0
unless it says otherwise):

```abla
import "abla/io"

fun main: int {
    println("Hello, world!")
    3
}
// output:
// Hello, world!
// exit: 3
```

A ` ```toml file=abla.toml ` block applies to the next program only, which is
how a document shows a compile-time capability grant.

Run the checks for one document while editing it:

```sh
tools/test-doc-examples.sh build/ablac docs/language.md
DOC_EXAMPLES_FILTER=language.md:120 tools/test-doc-examples.sh build/ablac
```
