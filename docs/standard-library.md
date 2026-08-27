# Standard library architecture

Abla's standard library is source-modular. Importing one feature must not pull
unrelated policy or compiler machinery into the program:

| Import | Responsibility |
|---|---|
| `abla/core` | phase-safe scalar helpers |
| `abla/math` | phase-safe numeric algorithms |
| `abla/bits` | named compatibility functions for native 64-bit bit operations |
| `abla/bytes` | phase-safe owned byte buffers, byte encoding, borrowed slices, stable hashing |
| `abla/crypto` | portable SHA-256, protocol SHA-1, HMAC, PBKDF2, Base64, hexadecimal, constant-time comparison, and legacy MD5 |
| `abla/text` | phase-safe UTF-8 validation, scalar indexing, and slicing |
| `abla/io` | portable console, EOF-aware line input, and callback-backed buffered text writers |
| `abla/io/buffered` | opt-in buffered file writer adapter |
| `abla/process/supervisor` | hosted child-process launch, isolated logs, polling, process-tree termination, monotonic timing, and processor discovery |
| `abla/fs` | `Path`, metadata, atomic text writes, directory entries, watches |
| `abla/process` | `Command`, `ChildProcess`, arguments, sleep, and monotonic timing |
| `abla/process/arguments`, `/command`, `/time` | size-selectable portable process capabilities, including an affine allocation-free clock |
| `abla/random` | bounded cryptographic entropy using raw Linux `getrandom` |
| `abla/random/hosted` | bounded `/dev/urandom` entropy for Linux and macOS hosted programs |
| `region { ... }` | compiler-checked lexical allocation generation (language construct) |
| `abla/runtime/memory` | internal emitted checkpoint/live-byte/budget/collection intrinsics used by the portable facade, compiler, and tests |
| `abla/net` | affine dual-stack TCP/UDP sockets, structured I/O results, deadlines, and epoll readiness on raw Linux |
| `abla/net/hosted` | DNS-capable dual-stack TCP/UDP plus epoll on Linux and kqueue on macOS |
| `abla/dns` | bounded DNS A/AAAA codec, compression-pointer parser, UDP resolver, and hostname connect helper |
| `abla/http` | HTTP/1 client/server, chunk-aware client parsing, pluggable transport, and version-aware routing |
| `abla/http/stream` | keep-alive/chunked policy, gzip negotiation, and Server-Sent Events framing |
| `abla/http/event` | bounded epoll HTTP/1.1 manager with pipelining, partial writes, and backpressure |
| `abla/http/tls` | certificate-verified HTTPS client transport |
| `abla/compression/gzip` | RFC gzip framing, CRC-32, and fixed-Huffman DEFLATE compression |
| `abla/tls/hosted` | dynamically loaded OpenSSL client/listener transport with hostname and certificate verification |
| `abla/websocket` | bounded RFC 6455 handshake, framing, connection lifecycle, and routed server helpers |
| `abla/websocket/json`, `/rpc` | optional bounded JSON messages and transport-neutral RPC method routing |
| `abla/websocket/event` | bounded epoll WebSocket manager with fragmentation, ping/pong, and output backpressure |
| `abla/websocket/tls` | certificate-verified WSS client transport |
| `abla/json` | [bounded JSON parsing, deterministic serialization, and `$json` literals](json.md) |
| `abla/float` | runtime `f64` bit-pattern access and explicit signed `int` to `f64` numerical conversion |
| `abla/http/json` | opt-in adapters between JSON values and HTTP requests/responses |
| `abla/html` | HTML data model and `$html` subparser |
| `abla/compiler/*` | compile-time parser/reflection APIs only |
| `abla/build` | framework-neutral compile-time program and export requests |
| `abla/android/build` | Android-owned arm64 target, `libabla_app.so` request, and generated JNI/Kotlin/CMake/Gradle integration |
| `abla/wasm/build` | WebAssembly-owned wasm32 target and no-entry module request |
| `abla/mvc/wasm/build` | MVC composition that generates a thin browser loader around the WASM module |
| `abla/unsafe/memory` | internal trusted native boundary plus checked pointer cells/buffers; retained at this legacy import path while typed resource modules stabilize |
| `abla/unsafe/mmio` | trusted volatile 8/16/32/64-bit memory-mapped I/O primitives for platform frameworks and device drivers |
| `abla/sys/linux` | opt-in raw x86-64 Linux syscall and native descriptor APIs |
| `abla/sys/linux/fs` | raw-kernel `Path`, metadata, atomic writes, entries, and watches |
| `abla/sys/linux/io` | raw-kernel buffered input lines, polling, and full output writes |
| `abla/sys/linux/process` | arguments, environment/PATH, sleep, fork/exec, capture, and child lifecycle |
| `abla/sys/linux/net` | affine TCP/UDP sockets, poll/epoll readiness, plus signalfd graceful SIGTERM draining |
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

`abla/io` console output and EOF-aware line input use the Linux descriptor
implementation and work unchanged in hosted and JIT execution. `abla/fs` and
`abla/process` use the same Linux implementations as the compiler, including
atomic files, directory enumeration/watch identities, arguments, sleep, and
command/child lifecycle. `abla/process/time` exposes millisecond/nanosecond
monotonic values, checked nanosecond sleep, and an affine `MonotonicClock` that
reuses its three kernel buffers in hot loops. Linux lowers these operations to
`clock_gettime` and `nanosleep` syscalls without libc. The narrow compatibility
ABI remains isolated in
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
platform APIs. Raw dereference and call intrinsics are callable only from a
function-level trusted implementation; ordinary consumers borrow the checked
resources. A static reservation only produces an opaque integer address, while
using that address as memory remains trusted. The trusted boundary also
provides fixed-signature call-through-address operations for native extension
entry points. Each operation encodes its exact pointer and integer lanes; there
is no unchecked variadic call surface.
Native counter integrations can use the monotonic atomic `i64` fetch-add
operation instead of introducing a foreign runtime helper or data race.
Trusted embedded drivers can also request function-scoped native storage with
`nativeStackAllocate`; LLVM lowers the intrinsic directly in its caller to
`alloca`, and the unsafe 8/16/32/64-bit loads, stores, copy, and memory-set
operations lower directly to LLVM memory instructions. The address must not
escape its calling function. `nativeStaticAllocate` reserves one
zero-initialized LLVM global per constant-sized call site for process-lifetime
driver storage. Higher-level packages should wrap that raw address in a checked
nominal handle or an ownership-checked resource type.

`abla/unsafe/xtensa` can also turn a named top-level `() -> void` function into
a native Xtensa interrupt-entry address. This is a compiler operation, not a
boxed `Fn` conversion: closures and local aliases are rejected, the entry uses
the target's native calling convention, and its directly reachable Abla code
is placed in `.iram1.text` automatically. The platform framework remains
responsible for installing that address and for keeping every indirectly
reached function and datum interrupt-safe. The same module exposes the
linker-provided Xtensa dispatcher-table address as a native scalar so a
framework can install entries directly without calling a C registration ABI.

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
the compiler preserves the same intrinsic contract while final LLVM
output lowers it directly; portable applications select `abla/fs` explicitly.

`abla/sys/linux/io` adds a stateful input reader that preserves bytes following
a line terminator, distinguishes EOF from an empty line, accepts CRLF, and can
poll for readiness. Its stdout/stderr helpers retry interrupted and partial
writes. Like the raw filesystem profile, it links no project C symbols.

`abla/sys/linux/net` implements affine IPv4/IPv6 TCP listeners/connections, UDP sockets,
structured I/O outcomes, and single/multi-descriptor readiness with `socket`,
`setsockopt`, `getsockopt`, `bind`, `listen`, `getsockname`, `getpeername`,
`accept4`, `sendto`, `recvfrom`, `poll`, and `epoll` syscalls. Graceful service
shutdown blocks `SIGTERM`, consumes
it through `signalfd`, and polls the listener and shutdown descriptor together;
an active HTTP request therefore finishes before the next accept observes the
drain request. The current `abla/net` facade selects this backend, so AOT and
JIT HTTP servers link and run without the project C capability adapter.
Hosted services that need the same transport concepts on macOS can explicitly
select `abla/net/hosted`; its narrow runtime adapter uses `getaddrinfo`, epoll,
or kqueue while keeping descriptors inside affine Abla resources.
The complete contract and current platform boundary are documented in
[networking.md](networking.md).

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
