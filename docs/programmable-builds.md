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

The built-in hosted Linux target can emit `executable`, `object`,
`static-library`, and `shared-library` nodes. The raw Linux target remains
executable-only. Build libraries may also register bounded ELF or WebAssembly target
descriptors with `defineTarget`: a name, LLVM triple, linker flavor/emulation,
and generic hosted/libc-free capabilities. Target descriptions are part of
the native cache identity. They are limited to 16 per compile-time evaluation
and 32 across a recursively expanded graph; invalid and duplicate definitions
fail before their program node is compiled.

The compiler interprets those generic properties but knows nothing about
Android. `abla/android/build` owns the first platform proof: its `build.ab`
helper defines an AArch64 Android target, requests only an exported
`libabla_app.so`, and generates the ABI header, JNI bridge, Kotlin declaration,
CMake import, and Gradle source-set fragment. The regression inspects the ELF
machine/type and dynamic symbol table and checks byte-identical repeated
output. Cross-target fast builds still run bounded O1/global-DCE before LLVM
target lowering so dead host-runtime details cannot invalidate another
architecture.

`abla/wasm/build` owns the format-level `wasm32-unknown-unknown` descriptor and
requests a generic `module` artifact. `abla/mvc/wasm/build` composes it with an
extension-generated JavaScript loader. Its proof module exports only the stable
`abla_mvc_revision` adapter, carries no runtime imports, and is byte-identical
across repeated cached builds. The compiler contains WebAssembly object/linker
support, but no fetch, JavaScript, browser, DOM, rendering, or MVC policy. LLD
name/debug metadata is stripped from the deployable module because its
transactional temporary filename is nondeterministic; explicit debug sidecars
remain roadmap work.

`compilerExportFunction(handle, name)` provides the first stable foreign ABI
rung. It exports a C-identifier symbol for a resolved top-level function while
keeping internal Abla symbols and value layouts hidden. This initial bounded
surface accepts zero parameters, no runtime globals, and `void`, `bool`, or
`i64` results. Every native artifact now publishes a sibling `.abi.json` after
successful linking through the staged-output transaction. Schema `abla.abi.v1`
records the selected target,
artifact container, foreign symbol, source declaration, parameter list, ABI
result representation, ownership/nullability, and failure containment status.
The sidecar is cached with the object and restored on a cache hit. The current
manifest deliberately says `panic: not-contained`; consumers can reject that
contract instead of assuming exceptions or traps are isolated. The surface is
still intentionally narrow: byte slices, opaque owned handles, callbacks, and
actual panic containment must be implemented before richer values cross the
boundary.

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

The Android proof now uses only those facilities. It intentionally stops at a
single arm64 library and generated integration skeleton: Android SDK discovery,
APK packaging, signing, manifests, resources, additional ABIs, and application
policy remain extension/toolchain work. The WASM/MVC proof likewise stops at a
scalar exported module and thin host loader; typed model/state exchange, DOM or
canvas renderers, hydration, callbacks, error containment, and bundler policy
remain library work. Neither workflow belongs in `ablac` itself.

`#import("abla/build")` is the first ordinary library façade over these
compiler services. Its `buildProgram`, `defineTarget`, and `exportFunction`
helpers contain no platform policy; Android and WASM/MVC extensions wrap them
with their own typed descriptors and generated artifacts.
