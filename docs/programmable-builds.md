# Programmable builds

Abla build orchestration is an extension concern, not a collection of
platform policies embedded in `ablac`. The compiler provides a bounded service
surface for declaring programs and producing verified artifacts; ordinary
Abla packages decide how Android, browser, server, embedded, or other projects
compose those primitives.

The first executable slice is `compilerBuildProgram`:

```abla
#import("abla/compiler")

val app = #compilerBuildProgram(
    "app-core",
    "src/app.ab",
    "build/libabla-app",
    "x86_64-linux",
    "executable",
    true,
    true
)

fun main: int = if (app) 0 else 1
```

The call adds a node to the current compilation transaction. After validating
the root program, the driver drains those nodes in deterministic declaration
order. A child program may register more programs, enabling an extension-owned
`build.ab` to construct its graph dynamically. Names and output paths must be
unique, paths are project-relative, each evaluation may submit at most 32
nodes, and the complete recursively expanded graph is capped at 64 nodes.
`compilerWriteFile` can stage generated source consumed by a requested node;
its ordinary `filesystem.write` authorization and output bounds still apply.
Until build-plan manifests can be restored independently, any module graph
that calls `compilerBuildProgram` deliberately bypasses whole-program native
object caching so a cache hit can never skip graph construction. Requested
leaf programs still use their selected cache policy.

Program nodes execute only under `ablac build`. LLVM-only emission, `run`, and
`serve` reject a discovered build graph with `E_BUILD_COMMAND_UNSUPPORTED`
instead of silently dropping requests or leaving process-private request data.

Only the `executable` artifact and the built-in Linux target descriptions are
implemented in this first slice. The API deliberately carries artifact and
target names so subsequent static-library, shared-library, object, and WASM
support extends the toolchain without adding mobile, UI, RPC, or browser
concepts to the compiler frontend.

## Direction

The general build service will grow around program handles and immutable
descriptors for:

- generated and existing source modules;
- external target descriptions and toolchain commands;
- explicit imports, exports, ABI metadata, and ownership contracts;
- declared sidecar artifacts;
- dependencies between program and artifact nodes;
- graph-wide transactional publication;
- content-addressed incremental execution;
- cycle, depth, process, memory, and output limits; and
- structured diagnostics carrying program and artifact context.

An Android extension should eventually use only those facilities to generate
JNI/Kotlin/Gradle integration and request an Android NDK shared library. A
WASM/MVC extension should use the same facilities to request a browser module
and generate its host adapter. Neither workflow belongs in `ablac` itself.
