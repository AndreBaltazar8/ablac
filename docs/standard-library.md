# Standard library architecture

Abla's standard library is source-modular. Importing one feature must not pull
unrelated policy or compiler machinery into the program:

| Import | Responsibility |
|---|---|
| `abla/core` | phase-safe scalar helpers |
| `abla/math` | phase-safe numeric algorithms |
| `abla/bytes` | phase-safe owned byte buffers, borrowed slices, stable hashing |
| `abla/text` | phase-safe UTF-8 validation, scalar indexing, and slicing |
| `abla/io` | portable console, EOF-aware line input, and callback-backed buffered text writers |
| `abla/io/buffered` | opt-in buffered file writer adapter |
| `abla/fs` | `Path`, metadata, atomic text writes, directory entries, watches |
| `abla/process` | `Command`, `ChildProcess`, arguments, sleep |
| `abla/process/arguments`, `/command`, `/time` | size-selectable portable process capabilities |
| `region { ... }` | compiler-checked lexical allocation generation (language construct) |
| `abla/runtime/memory` | internal emitted checkpoint/live-byte/budget/collection intrinsics used by the portable facade, compiler, and tests |
| `abla/net` | typed TCP listener/connection facade; raw Linux backend today |
| `abla/http` | HTTP/1 client/server, pluggable transport, and version-aware routing |
| `abla/json`, `abla/html` | data models and `$json`/`$html` subparsers |
| `abla/compiler/*` | compile-time parser/reflection APIs only |
| `abla/unsafe/memory` | internal trusted native boundary plus checked pointer cells/buffers; retained at this legacy import path while typed resource modules stabilize |
| `abla/sys/linux` | opt-in raw x86-64 Linux syscall and native descriptor APIs |
| `abla/sys/linux/fs` | raw-kernel `Path`, metadata, atomic writes, entries, and watches |
| `abla/sys/linux/io` | raw-kernel buffered input lines, polling, and full output writes |
| `abla/sys/linux/process` | arguments, environment/PATH, sleep, fork/exec, capture, and child lifecycle |
| `abla/sys/linux/net` | TCP sockets plus poll/signalfd graceful SIGTERM draining |
| `abla/llvm/aot`, `abla/llvm/orc` | in-process object emission and persistent JIT sessions |

`ByteBuffer` currently uses immutable chunks and `ByteSlice` is a checked view.
That representation is portable and works in both `#` evaluation and native
code; a target backend may specialize it to contiguous storage while preserving
the source API. Bytes are one-byte strings at this layer so no integer-to-Unicode
conversion can silently corrupt binary data.

`abla/text` layers explicit Unicode scalar semantics over byte-preserving
strings. Validation rejects overlong encodings, surrogate code points,
truncation, and values beyond U+10FFFF. It has no locale or large Unicode table
dependency and works during both staged and runtime execution.

`abla/io` console output and EOF-aware line input now use the selected raw
Linux descriptor implementation and work unchanged in hosted, JIT, and
`x86_64-linux-raw` executables. `abla/fs` and `abla/process` now select the
same complete raw Linux implementations used by the compiler, including
atomic files, directory enumeration/watch identities, arguments, sleep, and
command/child lifecycle. The narrow compatibility ABI remains isolated in
`BufferedTextWriter` batches text behind an ordinary `(string) -> bool` sink.
Its stdout/stderr constructors stay in `abla/io`; the file adapter is a
separate `abla/io/buffered` import and flushes through append-only atomic kernel
writes after an explicit truncate decision. This callback boundary is also the
integration point for sockets, compression, and future TLS transports.

Native memory is deliberately outside `abla/core`. `NativeI64Cell`,
`NativePointerCell`, and `NativeByteBuffer` are affine `resource class` values
with checked operations and idempotent `close`; the LLVM backend lowers their
trusted implementation directly instead of routing it through C. They are the
out-parameter and bounded-buffer building blocks used by LLVM ORC and raw
platform APIs. Raw intrinsics are callable only from a function-level trusted
implementation; ordinary consumers borrow the checked resources.

`abla/sys/linux` is likewise explicit and target-specific. Its current
x86-64 implementation lowers `openat`, `read`, `write`, `close`, and `getpid`
through LLVM inline `syscall` assembly and offers checked descriptor and native
byte-buffer wrappers. It neither silently replaces the portable `abla/fs`
surface nor pulls libc's `syscall` wrapper into programs that select it.

`abla/sys/linux/fs` builds the complete text-file/path/watch layer on that
surface: `newfstatat`, `getcwd`, `openat`, `read`, `write`, `fsync`, `mkdir`,
`rename`, `unlink`/`rmdir`, and `getdents64` are issued from Abla, with owned
native buffers for kernel out-parameters. The Linux self-hosted compiler uses
it for module loading, cache files, atomic outputs, and watched graphs. The
clean seed C backend preserves the same intrinsic contract while final LLVM
output lowers it directly; portable applications select `abla/fs` explicitly.

`abla/sys/linux/io` adds a stateful input reader that preserves bytes following
a line terminator, distinguishes EOF from an empty line, accepts CRLF, and can
poll for readiness. Its stdout/stderr helpers retry interrupted and partial
writes. Like the raw filesystem profile, it links no project C symbols.

`abla/sys/linux/net` implements TCP listeners and connections with
`socket`, `setsockopt`, `bind`, `listen`, `getsockname`, `accept4`, `poll`, and
descriptor I/O syscalls. Graceful service shutdown blocks `SIGTERM`, consumes
it through `signalfd`, and polls the listener and shutdown descriptor together;
an active HTTP request therefore finishes before the next accept observes the
drain request. The current `abla/net` facade selects this backend, so AOT and
JIT HTTP servers link and run without the project C capability adapter.

Allocation regions are intentionally narrower than a garbage collector.
`region { ... }` rejects heap-backed results, stores into older locals/objects,
retaining foreign calls, and direct or transitive mutation of outer receivers
and heap parameters. Affine resources are destroyed before the generation is
reset. The raw numeric checkpoint API remains internal because it cannot encode
those lifetime facts. The REPL uses the checked form after unloading each JIT
generation; HTTP handlers can adopt it once their response promotion and
long-lived-state policy is explicit.

`abla/memory` exposes `memoryLiveBytes()`, `memoryLimit()`,
`memorySetLimit(bytes)`, and the explicit `memoryCollect()` safe point. The
collector returns reclaimed bytes, preserves compiler-rooted locals,
parameters, globals, affine/native payloads, and higher-order call buffers, and
reclaims unreachable cyclic arrays/objects using precise allocation layouts.
Compile-time tree evaluation treats the safe point as a successful no-op. The
limit accounts for cumulative payload bytes of
all tracked runtime allocations, defaults to one GiB on every target, rejects
negative values or a value below current live usage, and fails before asking
the platform allocator for memory. Installing a limit also selects bounded
function-entry pressure safe points. Native resource allocations are pinned
until explicit ownership drop or region reset.

## HTTP versioning

The router preserves the original repository's multiple-handler idea without
hard-wiring it into the transport. Routes have a method, path pattern, handler,
and optional ordered version key. A configurable request header chooses the
newest version not newer than the requested version; no header selects latest.
ISO dates are the initial canonical keys because lexical and chronological
ordering agree.

```abla
val api = httpRouter("Stripe-Version")
api.version("2024-01-01").get("/customers/:id", customerV1)
api.version("2025-01-01").get("/customers/:id", customerV2)
```

Handlers remain ordinary typed Abla functions, so V2 can call V1 and transform
its typed model. Future `@route` and `@version` compile-time annotations will
generate the same route table rather than introduce a second router.

## Keeping binaries small

1. Imports select source modules; HTTP does not import JSON, files, TLS, or the
   compiler.
2. Platform implementations are selected by target profile (`posix`, future
   `linux-raw`, WASI), never all linked together.
3. IR reachability starts at `main`, global initializers, exports, and
   address-taken functions. Unreachable declarations are removed before LLVM.
4. Runtime functions use individual sections and LLD garbage collection;
   LLVM global DCE removes unused internal functions.
5. Optional facilities such as TLS, Unicode databases, HTTP/2, reflection, and
   compiler services remain separate imports.

Steps 1, 3, 4, and 5 are active today. Native programs with no `extern:"host"`
instructions select an LLVM-emitted allocator/panic implementation and dead
strip the complete project C adapter; importing a host capability selects the
tracked ABI-compatible allocator. Emitted allocation generations and raw
network transport are both active; typed errors and target-profile selection
are the next platform boundary milestones.
