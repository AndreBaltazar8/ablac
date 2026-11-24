# Programmable builds

Abla build orchestration is an extension concern, not a collection of
platform policies embedded in `ablac`. The compiler provides a bounded service
surface for declaring programs and producing verified artifacts; ordinary
Abla packages decide how Android, browser, server, embedded, or other projects
compose those primitives.

The low-level executable node is `compilerBuildProgram`; public extensions may
use the grouped `compiler.buildProgram(...)` method:

```abla fragment
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

**Paths are read against the build file (decision #91 A).** A relative entry or output of `compilerBuildProgram`,
`buildProgram`, `wasmBuildModule` or an independent module's `emit` is read against the directory of the file whose
`#` site makes the call, as an import is. The example above, in `tools/app.ab`, builds `tools/src/app.ab` into
`tools/build/libabla-app`, whichever directory `ablac build` runs from. A missing entry is `E_SOURCE_NOT_FOUND`.

The paths stay inside the build file's project (the compile-time effect boundary: a dependency's compile code, run by
its consumer, writes only inside its own tree): the nearest directory above the build file with an `abla.toml` (a
vendored or locked package's own, never the consumer's) that names a package (`name = ...`; a manifest that only grants
capabilities, such as a test case's `compileCapabilities`, bounds nothing), else the repository root (`.git`), else the working
directory. `"../../build/x"` from a file two directories down is inside; a path that leaves the project, absolute or
relative, is `E_BUILD_PATH_OUTSIDE`, and nothing is built.

Every other path compile-time code names follows the same rule (decision #95 A, v0.2.66): `compilerWriteFile`,
`abla/fs` reads, writes, listings and metadata in `#` code, in either tier
([compile-time.md](compile-time.md#paths-at-compile-time)), so a helper that writes a generated project and then builds
it (abla/android/build, abla/mvc/wasm/build) reads both against the same file.

The working-directory reading kept for one release with `warning[W_BUILD_PATH_CWD]` (build calls in v0.2.65, the rest
of compile-time file access in v0.2.66) is gone (#1044): a path spelled from the working directory is not found, and
the build says so. Write it relative to the source file.

For a program assembled from declarations in the current compilation, the
higher-level independent-module surface owns entry generation and the child
node:

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

#buildHelper()
```

The same builder can emit a function-only module. A lifted reference carries
its destination annotation and foreign name, while the Wasm package owns the
target descriptor and `emitWasm` convenience:

```abla fragment
import "abla/compiler"
import "abla/wasm/build"

compile fun buildClient(): void {
    val client = compiler.newModule("client")
    val answer = compiler.function("answer").annotated("client-copy")
    client.use(answer.exported("app_answer"))
    client.emitWasm("build/client.wasm", fast = true)
    return
}

#buildClient()
```

`compiler.reference(handle)` is the no-relookup form for a reflected function.
Generated adapters can be added through `declareGenerated(builder)` and
selected with `export(generatedName, foreignName)`. Both paths use the same
checked child compilation and the same per-file publication; no
extension-authored entry file is involved.

The declaration block is syntax, not source text passed by the application.
The destination is compiled as a fresh program, and only reachable code is
retained in its native artifact. Use the low-level node API when an entry file
already exists; use an independent module when compile-time code is declaring
that entry.

Resolved declarations can also become roots of a named target artifact:

```abla fragment
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
compilation, published like any other node (below). This generic mechanism
does not assign meaning to annotations such as `@client`; the selecting
extension checks annotation policy through compiler reflection.

The call adds a node to the current build. After validating
the root program, the driver drains those nodes in deterministic declaration
order. A child program may register more programs, enabling an extension-owned
`build.ab` to construct its graph dynamically. Names and output paths must be
unique, paths are build-file-relative and project-contained as described above,
each evaluation may submit at most 32
nodes, and the complete recursively expanded graph is capped at 64 nodes.
Each file a build publishes (an artifact, its ABI/LLVM/object sidecars, a
compile-time generated file) is written beside its name, as
`<name>.tmp.<pid>` (or under its final name in `<artifact>.publish.<pid>/` where
the linker records the name), and renamed over it, so every file is always
whole: the earlier build's or the new one's. Each node publishes when it builds.
A node that fails leaves its earlier artifact and ABI manifest, or none, and
the nodes built before it keep their new outputs; the build fails and says
which node. Files a successful build drops (a stale object or LLVM text beside
an artifact that no longer has one) go only once its artifact is published.
A build that is stopped (killed, or by a panic) leaves only temporaries: the
next build of that artifact removes those named after it whose process has
gone, and every build removes per-process scratch directories in `build/` of
processes that have gone.

Clean-up of old build transactions: compilers up to 0.2.32 instead moved a
build's earlier outputs into `build/.abla-build-transaction-<pid>`, to put them
back if the graph failed, and a stopped build left that directory behind. Every
build now removes those in `build/` of its working directory once their process
has gone, putting nothing back (builds since have made those outputs again).
This step goes once no compiler that makes them is in use.
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
`static-library`, and `shared-library` nodes. Libc-free Linux executables are
selected by their dependencies, not by a separate raw-target CLI alias.
Build libraries may also register bounded target descriptors
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

`libabla_app.so` imports nothing from bionic and names no `libc.so` (decision #121). The five bionic functions its
runtime calls (`pthread_key_create` with a destructor for a thread's end, `pthread_getspecific`, `pthread_setspecific`,
and `pthread_create` and `pthread_join` for its own threads) come from a table that the generated `libabla_jni.so`, which
links bionic, installs in its `JNI_OnLoad` before Java can call an export: `abla_android_host_install`, declared with the
table's layout in the generated `abla-app.h` (version 1, five entries, none null: a table with a null function answers -1 and
installs nothing). The library copies the table into storage of its own, so a host's may be a local or be freed afterwards, and
publishes the copy once with release and reads it with acquire. Installing again answers 0 for the same five functions and 1 for
other ones (the first stay). A program that loads `libabla_app.so` by itself calls `abla_android_host_install` with the same table
first; without it the library still loads, and its first call of one of the five writes why to standard error and ends
the process with status 70.

The extension also finds the Android NDK, which the compiler does not: a library with a thread-local and no import of
`abla/android/emutls` needs the NDK's compiler-rt builtins archive (`__emutls_get_address`), and a user's native input
may import bionic functions, which the NDK sysroot's API 24 `libc.so` stub supplies (linked as needed). `androidNdkLookup` reads `ABLA_ANDROID_NDK`, `ANDROID_NDK_ROOT`,
`ANDROID_NDK_HOME` and, under `ANDROID_HOME` and `ANDROID_SDK_ROOT`, `ndk/<version>` and `ndk-bundle` (`Path.entries()`;
the newest version wins; `ABLA_ANDROID_BUILTINS` names the archive itself), and passes what it finds to the link with
`defineTargetLinkInput(target, path)`: an absolute, one-line path (at most 16 per target) that joins the target's
shared-library link after the object, in the order given, and is part of the target's cache identity. With no NDK the
library links without them, as it always did. A build script that builds an Android library therefore grants the
lookup its two effects: `#compilerGrant("environment")` and `#compilerGrant("filesystem.read")`, and lists them in
`compileCapabilities` in its `abla.toml`. Without them the build stops with `compile.effect-denied:<capability>:` and the
call path (`androidBuildArm64Library->androidNdkLookup->...`), and the diagnostic's help says to add the grant.
`tools/test-android-extension.sh` finds a synthetic NDK both ways and fails if the compiler names any NDK variable.

`abla/wasm/build` owns the format-level `wasm32-unknown-unknown` descriptor and
requests a generic `module` artifact. `abla/mvc/wasm/build` composes it with an
extension-generated JavaScript loader. Its proof module exports only the stable
`abla_mvc_revision` adapter, carries no runtime imports, and is byte-identical
across repeated cached builds. The compiler contains WebAssembly object/linker
support, but no fetch, JavaScript, browser, DOM, rendering, or MVC policy. LLD
name/debug metadata is stripped from the deployable module because its
temporary filename is nondeterministic; explicit debug sidecars
remain roadmap work. Linking uses one worker so artifact construction stays
within the same bounded process budget on high-core-count hosts.

The libc-free platform runtime also implements the allocation, address,
byte-load/store, and 64-bit-load/store primitives from `abla/unsafe/memory`.
They let trusted guest adapters exchange bounded data through exported linear
memory without adding imports. Allocation is monotonic and reclaimed when the
WebAssembly instance is discarded; unsupported host-specific unsafe operations
remain unavailable rather than becoming ambient capabilities.
Its C boundary uses fixed-width counts rather than host `size_t`, so managed
strings, arrays, and objects retain the same generated LLVM contract on wasm32
and native targets. Trusted adapters can therefore adopt request memory and
hand ordinary strings to runtime `$json`/`$jsons` code.

`@export("name")` provides the direct source-level form of the first stable
foreign ABI rung. The equivalent `compilerExportFunction(handle, name)` API is
retained for extensions that choose a function dynamically. Both export a
C-identifier symbol for a resolved top-level function while
keeping internal Abla symbols and value layouts hidden. This initial bounded
surface accepts up to 16 value `bool`, `char`, `f32`, `f64`, signed or unsigned
8/16/32/64-bit integer, borrowed `string`, or direct
non-escaping `(i64) -> i64` callback parameters and `void`, any supported
scalar, or owned `string` results. Runtime globals initialize once and retain
state between calls; direct exports do not add synchronization. When every
module global is a scalar with a compile-time-proven initializer, the compiler
places those initial values directly in the artifact and removes the lazy
first-export guard automatically. Mutable `var` globals remain mutable after
startup and need no source annotation for this optimization. Adapters
preserve the declared width and signedness while boxing scalars without exposing
`%AblaValue`. A string lowers to a pointer/`u64` byte slice;
the adapter accepts null only for an empty slice, copies the exact bytes into
tracked Abla-owned storage, and adds its own terminator before calling user
code. C conformance covers embedded NUL/non-UTF-8 bytes and the empty-null
case. Every native artifact publishes a sibling `.abi.json` after
successful linking, with the build's staged outputs. Schema `abla.abi.v1`
records the selected target,
artifact container, foreign symbol, source declaration, parameter list, ABI
result representation, ownership/nullability, and failure containment status.

### Collection in a shared library

A hosted shared library collects under allocation pressure by default, as a program with `main` does: its allocating
functions are safe points, and a collection runs when the heap passes its threshold (32 MB to start, then half again
past what it kept). It opts out the way a program does, by reaching `memorySetManualCollection()` from an export; the
growth is set with `memorySetCollectionGrowth(bytes)`. A module for Wasm or a freestanding target is manual by default,
and compile-time slices are as they were. The environment variables `ABLA_GC_STRESS`, `ABLA_GC_POISON` and
`ABLA_GC_TRACE` are read from the process environment, which a library does not have, so they have no effect in one.

### Which loops are collection points

A function that allocates has a safe point at its entry, and a loop that
allocates (an instruction in it may allocate) has one on its back edge. A loop that allocates nothing has none, except a
spin wait: a loop of a user function that reads memory with an atomic or volatile access (`ablaRuntimeAtomic*`,
`ablaUnsafeAtomic*`, `ablaUnsafeVolatileLoad*`) gets the back-edge safe point too, because it waits for another thread, which
may be the one that is collecting. Any other loop that allocates nothing is not a collection point: a counted compute loop
holds up a collection until it ends (the stop waits 20 ms, more on a loaded machine, and gives up, as for a blocked thread), which delays the
collection and nothing else. A loop that reads shared data without an atomic access is a data race and is not made a
collection point. The runtime's own waits (the futex locks, the stop itself) never poll: they run inside the
collector. Polling every back edge was measured and dropped (+9 to +20% on sieve, trees and matrix), so the rule is by
shape; `tests/cases/gc-spin` is the test (a worker spinning on an atomic while another thread makes 1.5 GB of garbage:
no abandoned stop, a bounded heap).

### Calling exports from several threads

A shared library (the default x86-64 Linux target, arm64 Android, and any other hosted shared library) is entered
from threads it did not start: a host's UI thread and workers, JNI callers, at the same time. Each exported
function is a thunk that enters the runtime and leaves it after the body:

- the first entry makes the heap lock live (the mode a program is in once it starts a thread); other callers wait
  for that, and every allocation takes the heap lock from then on;
- each thread inside registers with the collector, and a collection stops the others first (stop-the-world, #811):
  the collecting thread sets the byte threshold to 0, so every other thread's next safe point calls the collector
  and parks there; their root chains are then marked with the collector's own. A thread that cannot park (blocked
  in the system, in a loop that never allocates, or in a region) makes the collector give up after 20 ms (longer on a loaded machine: while the collecting thread itself is kept off the CPU, up to 200 ms, and while the thread the stop waits for is runnable but has not run, which Linux says in /proc/self/task/<id>/stat, up to a second): that
  collection does not run (`memoryHeapStat(8)` counts these, `ABLA_GC_TRACE=1` names the thread), and none is
  tried for 200 ms. The same holds for the threads of a program: collection no longer waits for `thread` workers to
  end. A thread in `join`, or in a system call of the standard library's wrappers or a blocking C call (SSL, read/write,
  long LLVM calls), counts as stopped: the compiler treats those calls as collection points, with the function's live
  values rooted across them, and brackets them with `abla_runtime_native_enter/leave`; an address taken of a string
  (`nativeStringAddress` and the like) keeps the string rooted to the end of its function. The runtime's own futex and
  mutex waits do not count: a stop waits 20 ms for them and gives up. A call into the host (an `@hostImport` symbol: a
  JNI callback, a UI thread's message) counts as stopped the same way; an export the host calls from inside such a call
  runs Abla code again, so the thread stops counting as stopped until that export returns;
- the module globals are initialized by one caller while the others wait; an export entered again on the
  initializing thread (the library called the host, which called an export) goes on, with the globals as far as
  they are initialized;
- nested calls from one thread are fine, and overlapping calls run in parallel: no call waits for another's end.

Cost: two atomic updates per call, and, once sharing is on, the heap lock on every allocation (no lock-free
small-block fast path), the cost of a threaded program. Measured by `tools/test-foreign-threads.sh` (x86-64
Linux) and `tools/test-android-run.sh` (bionic's linker on qemu-aarch64): 1, 4 and 8 pthreads calling an
allocating export, with and without `ABLA_GC_STRESS=1`, and a nested export during initialization.

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
extension diagnostics, and whole-file publication. These are
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

`internalFunction(source, symbol)` gives inline or module assembly a locally
linked name and remains prunable when no reachable source, native, or assembly
edge uses it. `requiredInternalFunction(source, symbol)` covers the narrower
case where LLVM or a target backend can introduce the symbol only after that
reachability pass, such as freestanding memory or integer-division helpers. It
retains a local definition without adding a public ABI export. Both operations
are target-neutral linking mechanisms; frameworks choose the concrete symbols.
