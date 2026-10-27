# Standard library

The standard library is a set of ordinary Abla modules, imported by path:
`import "abla/text"`. Importing a module pulls in only that module and what it
needs, so a program that never touches JSON, TLS or the compiler doesn't
carry them.

## By task

| Page | Modules |
|---|---|
| [Text, bytes and number formatting](stdlib/text.md) | `abla/text`, `abla/bytes`, `abla/float/text` |
| [Console, files, processes and time](stdlib/system.md) | `abla/io`, `abla/fs`, `abla/process/*` |
| [Numbers, bits and randomness](stdlib/numbers.md) | `abla/core`, `abla/math`, `abla/math/v8`, `abla/math/fast`, `abla/float`, `abla/bits`, `abla/integer`, `abla/random` |
| [Hashing, encoding and dates](stdlib/security-and-dates.md) | `abla/crypto`, `abla/date` |
| [Testing](stdlib/testing.md) | `abla/test` and `ablac test` |
| [JSON](json.md) | `abla/json`, `abla/http/json`, `$json` |
| [Networking](networking.md) | `abla/net`, `abla/http/*`, `abla/websocket/*`, `abla/tls/hosted`, `abla/dns`, `abla/dns/async`, `abla/jwt` |
| [Compiler API](compiler-api.md), [subparsers](subparsers.md), [programmable builds](programmable-builds.md) | `abla/compiler`, `abla/compiler/parser`, `abla/build`, `abla/wasm/build`, `abla/android/build` |

Built into the language rather than imported: `string`, arrays, `Map`,
`Cell`, `Shared`, `Weak`, `Mutex`, tasks, threads, generators and
`region { ... }` ([language.md](language.md)).

## All modules

| Import | Responsibility |
|---|---|
| `abla/core` | `int.abs()`, `int.sign()` |
| `abla/math` | numeric algorithms: integer `min`/`max`/`clamp`, `f64` functions and constants |
| `abla/math/v8` | `abla/math`'s declarations with the results of V8's `Math` (Node 22, x86-64), bit for bit |
| `abla/math/fast` | `abla/math`'s declarations with fast fdlibm-style results (within about 1 ulp) |
| `abla/float` | `f64`/`f32` conversions and bit patterns |
| `abla/float/text` | shortest round-trip `f64` text and parsing; needed to interpolate floats |
| `abla/integer` | exact integer intrinsics (`u32.countLeadingZeros()`) |
| `abla/bits` | named functions for 64-bit bit operations |
| `abla/bytes` | byte buffers, byte encoding, borrowed slices, stable hashing |
| `abla/text` | string helpers (split, trim, replace, ...) and UTF-8 validation, code points and slicing |
| `abla/crypto` | SHA-256, SHA-1, MD5, HMAC, PBKDF2, Base64, hexadecimal, constant-time comparison |
| `abla/date` | UTC calendar dates, ISO 8601 and HTTP dates |
| `abla/test` | checks for test programs run by `ablac test` |
| `abla/io` | console output, end-of-input-aware line input, buffered text writers |
| `abla/io/buffered` | buffered file writer |
| `abla/fs` | `Path`, metadata, atomic text writes, directory entries, watches |
| `abla/process` | arguments, environment, commands, exit, time: everything below |
| `abla/process/arguments`, `/environment`, `/command`, `/exit`, `/time` | the same, one capability per import, including an affine allocation-free clock |
| `abla/process/supervisor` | hosted child-process launch, isolated logs, polling, process-tree termination, monotonic timing, and processor discovery |
| `abla/process/metrics` | the process's CPU time, resident/virtual memory, open descriptors and their limit, start time and tracked heap bytes |
| `abla/random` | bounded cryptographic entropy (`getrandom`) |
| `abla/random/hosted` | the same function under its hosted name, `hostedSecureRandomBytes` |
| `abla/random/result` | `SecureRandomResult` |
| `abla/memory` | heap limit, collection mode, `memoryCollect()`, live-byte statistics |
| `abla/json` | [bounded JSON parsing, deterministic serialization, and `$json` literals](json.md) |
| `abla/html` | HTML data model and the `$html` subparser |
| `abla/net` | affine dual-stack TCP/UDP sockets, structured I/O results, deadlines, and epoll readiness on raw Linux |
| `abla/net/contracts` | transport-neutral network outcome types |
| `abla/net/hosted` | DNS-capable dual-stack TCP/UDP plus epoll on Linux and kqueue on macOS |
| `abla/dns` | bounded DNS A/AAAA codec, compression-pointer parser, a resolver with /etc/hosts, resolv.conf search domains and ndots, and a hostname connect helper |
| `abla/dns/async` | `DnsAsyncResolver`: many nonblocking A/AAAA queries driven by `step` or an outside poller |
| `abla/http` | HTTP/1 client/server, chunk-aware client parsing, pluggable transport, and version-aware routing |
| `abla/http/stream` | keep-alive/chunked policy, gzip negotiation, and Server-Sent Events framing |
| `abla/http/event` | bounded epoll HTTP/1.1 manager with pipelining, partial writes, and backpressure |
| `abla/http/async` | nonblocking HTTP(S) client driven by a poll loop |
| `abla/http/tls` | certificate-verified HTTPS client transport |
| `abla/http/json` | adapters between JSON values and HTTP requests/responses |
| `abla/compression/gzip` | RFC gzip framing, CRC-32, and fixed-Huffman DEFLATE compression |
| `abla/tls/hosted` | dynamically loaded OpenSSL client/listener transport with hostname and certificate verification |
| `abla/websocket` | bounded RFC 6455 handshake, framing, connection lifecycle, and routed server helpers |
| `abla/websocket/client` | client masking keys |
| `abla/websocket/json`, `/rpc` | bounded JSON messages and transport-neutral RPC method routing |
| `abla/websocket/event` | bounded epoll WebSocket manager with fragmentation, ping/pong, and output backpressure |
| `abla/websocket/server` | connection-oriented WebSocket server with admission, broadcast and draining |
| `abla/websocket/server/tls` | TLS for `abla/websocket/server`: a certificate and key as `WebSocketServerOptions(tls = ...)`, nonblocking handshakes |
| `abla/websocket/tls` | certificate-verified WSS client transport |
| `abla/jwt`, `abla/jwt/remote` | JWS RS256/ES256 verification against a key set, and a cached remote JWKS |
| `abla/compiler`, `abla/compiler/parser` | compile-time reflection, transforms, generated code and subparser APIs (compile time only) |
| `abla/build` | framework-neutral compile-time program and export requests |
| `abla/android/build` | Android arm64 target, `libabla_app.so` request, and generated JNI/Kotlin/CMake/Gradle integration |
| `abla/wasm/build` | WebAssembly wasm32 target and no-entry module request |
| `abla/mvc/wasm/build` | an MVC composition that generates a thin browser loader around the Wasm module |
| `abla/llvm/aot`, `abla/llvm/orc` | in-process object emission and persistent JIT sessions |
| `abla/unsafe/memory` | the trusted native boundary plus checked pointer cells and buffers |
| `abla/unsafe/memory/raw` | raw stack, static and section memory, and raw loads and stores (trusted) |
| `abla/unsafe/native` | typed call-through-address functions and atomics (trusted) |
| `abla/unsafe/mmio` | trusted volatile 8/16/32/64-bit memory-mapped I/O primitives for platform frameworks and device drivers |
| `abla/unsafe/xtensa` | Xtensa interrupt-entry addresses and dispatcher tables |
| `abla/sys/linux` | opt-in raw x86-64 Linux syscall and native descriptor APIs |
| `abla/sys/linux/fs`, `/io`, `/process`, `/net`, `/random` | the raw-kernel implementations behind the portable modules |
| `abla/platform/host` | the hosted runtime's `ablaHost*` functions; portable code uses the modules above instead |
| `abla/runtime/*` | the runtime itself, linked automatically; internal (its address intrinsics are callable only from it: `native.runtime-internal`) |

There are no visibility modifiers, so a module's internal helpers are also
importable. The functions named on the task pages are the supported API.

## Architecture notes

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
`clock_gettime` and `nanosleep` syscalls without libc.

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

A NUL-terminated native string becomes an Abla string with `nativeCString`,
which copies it: the string stays valid after the native memory is released or
reused. `borrowNativeCString` reads it in place, without a copy, and is valid
only while that memory is. A string made from a borrowed one can share the same
bytes, because string operations don't copy what they can share: a template
such as `"${s}"`, `+` with an empty side, a concatenation longer than 64 bytes
(it keeps references to its parts), and a stored value. Use a borrowed string,
and anything made from it, only while the memory is live; text that outlives
the memory comes from `nativeCString`.

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

Freestanding startup code that owns writable-memory preparation can call
`nativeInitializeGlobals()` after data and BSS are ready. The call runs the
same once-only initializer used by ordinary foreign entries. Its presence also
tells the compiler that this entry owns initialization, so LLVM does not insert
an unsafe earlier guard ahead of a kernel or firmware boot function.

`abla/unsafe/xtensa` can also turn a named top-level `() -> void` function into
a native Xtensa interrupt-entry address. This is a compiler operation, not a
boxed `Fn` conversion: closures and local aliases are rejected, the entry uses
the target's native calling convention, and its directly reachable Abla code
is placed in `.iram1.text` automatically. The platform framework remains
responsible for installing that address and for keeping every indirectly
reached function and datum interrupt-safe. The same module exposes the
linker-provided Xtensa dispatcher-table address as a native scalar so a
framework can install entries directly without calling a C registration ABI.
For a framework that owns the classic dual-core dispatcher ABI,
`nativeXtensaOwnedDispatcherTableAddress` emits initialized 64-entry interrupt
and 128-entry exception tables as native globals and returns the interrupt
table address. It also emits the classic ESP32's 32-byte read-only interrupt
level table. Separate intrinsics expose all three table addresses and the two
unhandled-handler symbols without a foreign call. It adds no runtime
initializer or allocation and safely completes earlier external declarations
of the same tables. Platform code must still provide the ABI's unhandled
routines and vector path, and must not combine this ownership primitive with a
competing table definition. An exact Xtensa `xt_unhandled_interrupt` export and
its direct Abla call graph are automatically kept in IRAM because the vector
can invoke that ABI while flash is unavailable.

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
compiler preserves the same intrinsic contract while final LLVM output lowers
it directly; portable applications select `abla/fs` explicitly.

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
drain request. On macOS the Darwin adapter backs `rt_sigprocmask` with
`pthread_sigmask` and a `signalfd` with a kqueue watching `EVFILT_SIGNAL`, so a
Mach-O server drains the same way. The current `abla/net` facade selects this backend, so AOT and
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
reset. The raw numeric checkpoint functions (`memoryCheckpoint`,
`memoryReset` in `abla/memory`) cannot encode those lifetime facts, so they
are for runtime and compiler internals, not for application code. The REPL uses the checked form after unloading each JIT
generation; HTTP handlers can adopt it once their response promotion and
long-lived-state policy is explicit.

`abla/memory` exposes `memoryLiveBytes()`, `memoryLimit()`,
`memorySetLimit(bytes)`, `memorySetCollectionGrowth(bytes)`,
`memorySetManualCollection()`, `memorySetBackgroundFree(enabled)`, and the
explicit `memoryCollect()` safe point. The
collector returns reclaimed bytes, preserves compiler-rooted locals,
parameters, globals, affine/native payloads, and higher-order call buffers, and
reclaims unreachable cyclic arrays/objects using precise allocation layouts.
Compile-time tree evaluation treats the safe point as a successful no-op. The
limit accounts for cumulative payload bytes of
all tracked runtime allocations, defaults to one GiB on every target, rejects
negative values or a value below current live usage, and fails before asking
the platform allocator for memory. Native resource allocations are pinned
until explicit ownership drop or region reset.

`memoryCensus()` says what the tracked heap holds, for diagnostics: per
allocation layout (strings' bytes, arrays, class instances, ...) how many
allocations and their payload bytes, which add up to `memoryLiveBytes()`;
the instances' declared fields by the tag of the value each holds; and what
the allocations cost past their payloads (their headers, and on Wasm the
allocator's block headers and size-class rounding). It walks the heap once
and collects nothing, so call `memoryCollect()` first to count only what is
reachable.

Collection has two modes:

- **Pressure collection** (the default for hosted native programs with
  `main`). Every allocating function is a safe point: on entry (where its
  root frame is pushed) and on the back edge of each of its loops that
  allocates, it collects once the tracked heap has grown past a threshold, so
  a loop that only builds strings or grows arrays collects too. (Comparing or indexing a
  string may flatten a rope, which allocates the rope's own copy; that alone
  makes no safe point.) The first collection runs
  at 32 MiB; each later one once the heap has grown by
  `max(64 MiB, half of what the last collection kept)`, capped below the limit.
  `memorySetCollectionGrowth(bytes)` lowers the least growth for programs that
  care about their footprint. Without a rebuild, `ABLA_GC_GROWTH=<bytes>`
  (decimal, at least 1 MiB; read once at startup) sets the least growth and
  starts the first collection at half of it: a smaller step collects more often
  over less garbage, so each pause is shorter. Run with `ABLA_GC_STRESS=1` to
  collect at every safe point instead
  ([debugging.md](debugging.md#collector-stress-abla_gc_stress1)).
- **Manual collection** (the default for wasm and freestanding targets, and
  for modules entered through their exports). Only an explicit
  `memoryCollect()` frees cyclic garbage. The compiler roots only the
  functions that can reach that call, so the program carries no safe-point
  code. A hosted program opts into it with `memorySetManualCollection()`: a
  call anywhere `main` can reach compiles it without pressure safe points, and
  at run time the call stops pressure collection.

`memorySetBackgroundFree(true)` (hosted native targets; elsewhere a no-op) moves
returning unreachable blocks to the system allocator out of the collection: the
sweep hands them to a helper thread of the runtime's own, which frees them while
the program goes on, and the next collection waits for it first. It is off by
default, so a program has no helper thread unless it asks; results are the same
either way, and the memory is back with the system allocator before the next
collection. A forked child drops the batch its parent's helper was freeing. The
compiler turns it on.

`memorySetLimit(bytes)` and `memorySetCollectionGrowth(bytes)` select pressure
collection in either mode: a program that can reach either is compiled with
pressure safe points, and the call turns collection under pressure on at run
time (after `memorySetManualCollection()` too).

Near its limit, pressure collection stops before it would run at nearly every
allocating call. Its threshold stays below the limit, leaving a quarter of it
(at most 64 MiB) as room. When a collection keeps so much that less than 1/64
of the limit is left under that threshold, the next collection waits until
half of the remaining room to the limit is used, and never for less than 1/64
of the limit. A program whose live data grows to its limit reaches the limit's
panic (`memory limit exceeded`, exit code 101) after a few collections. A
program whose reachable data stays within about 1/64 of its limit also
panics, where it would otherwise collect without end and make almost no
progress. A long-running program, such as a server, that must not stop there
needs a higher limit.

| Program | Default | Opt out / in |
| --- | --- | --- |
| hosted native, with `main` | pressure | `memorySetManualCollection()` |
| wasm, freestanding, export-only modules | manual | `memorySetLimit` / `memorySetCollectionGrowth` |

## HTTP versioning

The router preserves the original repository's multiple-handler idea without
hard-wiring it into the transport. Routes have a method, path pattern, handler,
and optional ordered version key. A configurable request header chooses the
newest version not newer than the requested version; no header selects latest.
ISO dates are the initial canonical keys because lexical and chronological
ordering agree.

```abla fragment
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
