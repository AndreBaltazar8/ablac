# Programmable builds

Abla build orchestration is an extension concern, not a collection of
platform policies embedded in `ablac`. The compiler provides a bounded service
surface for declaring programs and producing verified artifacts; ordinary
Abla packages decide how Android, browser, server, embedded, or other projects
compose those primitives.

The low-level executable node is `compilerBuildProgram`; public extensions may
use the grouped `compiler.buildProgram(...)` method:

```abla
import "abla/compiler"
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

Resolved declarations can also become roots of a named target artifact:

```abla
compile fun configureClient(): void {
    val action = compiler.findFunction("clientAnswer")
    compiler.contributeArtifactRoot(
        "browser", "wasm32-module", "module",
        "build/client.wasm", action, "abla_client_answer", true, true
    )
    return
}

#compiler.transform(configureClient)
```

Repeated contributions to `browser` aggregate into one target-correct child
compilation. The generated entry, module, object/LLVM/ABI sidecars, native root,
and any prior versions share the graph rollback journal. This generic mechanism
does not assign meaning to annotations such as `@client`; the selecting
extension checks annotation policy through compiler reflection.

The call adds a node to the current compilation transaction. After validating
the root program, the driver drains those nodes in deterministic declaration
order. A child program may register more programs, enabling an extension-owned
`build.ab` to construct its graph dynamically. Names and output paths must be
unique, paths are project-relative, each evaluation may submit at most 32
nodes, and the complete recursively expanded graph is capped at 64 nodes.
Publication is graph-transactional across the root, every recursively
discovered artifact, ABI/LLVM/object sidecars, and compile-time generated
file. Before a path is changed, an existing file is atomically renamed into a
private bounded journal; a later node failure restores prior files and removes
new ones in reverse order. A successful graph discards the journal. At most 512
distinct output paths may participate, and exceeding that bound fails with
`E_BUILD_GRAPH_TRANSACTION` before the unjournaled path is modified. A
rollback failure is reported separately as `E_BUILD_GRAPH_ROLLBACK`.
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
executable-only. Build libraries may also register bounded target descriptors
with `defineTarget`: a name, LLVM triple, object format, linker
flavor/emulation, and generic hosted/libc-free capabilities. A descriptor with
linker flavor and emulation `none` can emit objects or static libraries for
any triple implemented by the installed LLVM; linked artifacts require a
supported format-specific linker contract. Target descriptions are part of
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

The libc-free platform runtime also implements the allocation, address,
byte-load/store, and 64-bit-load/store primitives from `abla/unsafe/memory`.
They let trusted guest adapters exchange bounded data through exported linear
memory without adding imports. Allocation is monotonic and reclaimed when the
WebAssembly instance is discarded; unsupported host-specific unsafe operations
remain unavailable rather than becoming ambient capabilities.

`compilerExportFunction(handle, name)` provides the first stable foreign ABI
rung. It exports a C-identifier symbol for a resolved top-level function while
keeping internal Abla symbols and value layouts hidden. This initial bounded
surface accepts up to 16 value `bool`/`i64`, borrowed `string`, or direct
non-escaping `(i64) -> i64` callback parameters, no runtime globals, and
`void`, `bool`, `i64`, or owned `string` results. Adapters box scalars
without exposing `%AblaValue`. A string lowers to a pointer/`u64` byte slice;
the adapter accepts null only for an empty slice, copies the exact bytes into
tracked Abla-owned storage, and adds its own terminator before calling user
code. C conformance covers embedded NUL/non-UTF-8 bytes and the empty-null
case. Every native artifact publishes a sibling `.abi.json` after
successful linking through the staged-output transaction. Schema `abla.abi.v1`
records the selected target,
artifact container, foreign symbol, source declaration, parameter list, ABI
result representation, ownership/nullability, and failure containment status.
The sidecar is cached with the object and restored on a cache hit. The current
direct-export manifest deliberately says `panic: not-contained`; consumers can
reject that contract instead of assuming exceptions or traps are isolated.
`compilerExportCheckedFunction` is the opt-in contained form on hosted x86-64
Linux. It returns an `i32` status, writes a successful result through an
out-pointer, and copies panic bytes into a caller-provided bounded buffer while
reporting the full required length. Status `0` is success, `1` is a contained
panic, and `2` is an invalid boundary argument. Recovery restores nested panic
and GC-root frames, so the host can call again after failure. Cleanup is
abortive and external side effects are not rolled back; those limitations are
explicit in the manifest. Other targets reject checked exports until their
descriptor/runtime supplies a compatible containment capability. The surface
is still intentionally narrow. A string result is copied into a non-null opaque
foreign handle. The manifest names `abla_owned_bytes_data`,
`abla_owned_bytes_length`, and the mandatory exactly-once
`abla_owned_bytes_release`, and declares validity until release. This first
handle implementation is limited to libc-backed targets; libc-free WASM fails
with a target-capability diagnostic instead of importing an undeclared
allocator. A callback lowers to a C function pointer plus an explicit context
pointer. It is synchronously borrowed for the exported call, may be invoked
directly by that function, and may not be stored, returned, captured, or passed
on; export validation rejects those escape shapes. The manifest records the C
calling convention, scalar signature, call lifetime, forbidden retention, and
forbidden unwind. Typed class handles and checked-containment support on more
targets remain.

## Foundation status

The compiler foundation now provides generated source, recursively requested
program nodes, extension-defined target descriptors, executable/library/module
artifacts, explicit foreign exports, versioned ABI and ownership metadata,
content-addressed leaf caching, bounded effects and graph expansion, structured
extension diagnostics, and graph-wide transactional publication. These are
generic compiler mechanisms; none encodes a mobile, browser, UI, packaging, or
framework policy.

The next compiler-level increments are explicit dependency edges between
program and artifact nodes, module-granular typed-IR invalidation, independently
declared sidecars, richer target capability negotiation, and resource accounting
for external tools. They extend the same contracts rather than adding platform
workflows to `ablac`.

The Android proof uses only those facilities. It intentionally stops at a
single arm64 library and generated integration skeleton: Android SDK discovery,
APK packaging, signing, manifests, resources, additional ABIs, and application
policy remain extension/toolchain work. The WASM/MVC proof likewise stops at a
scalar exported module and thin host loader; typed model/state exchange, DOM or
canvas renderers, hydration, host integration, and bundler policy remain library
work. Neither workflow belongs in `ablac` itself.

`import "abla/compiler"` now exposes the compile-time-only `compiler` service
object as the primary façade. `import "abla/build"` remains the small
compatibility/convenience façade over these
compiler services. Its `buildProgram`, `defineTarget`, and `exportFunction`
helpers contain no platform policy; Android and WASM/MVC extensions wrap them
with their own typed descriptors and generated artifacts.
