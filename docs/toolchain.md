# `ablac` toolchain interface

The final tool is one self-hosted native `ablac` executable. C emission remains
an optional bootstrap/debug backend in `src/main.ab`, not part
of the production `orc_main.ab` compiler graph or the normal user workflow.

The public `ablac` launcher resolves compiler-owned standard-library and
runtime sources from its toolchain root, independently of the caller's working
directory. Installed or custom layouts may override that root with
`ABLA_SYSROOT`; `ABLA_STDLIB` remains available as a narrower standard-library
override. Project inputs, outputs, and caches continue to use project or
invocation-relative paths.

The Linux x86-64 toolchain archive requires glibc 2.35 or later. Ubuntu 22.04,
Debian 12 and later meet that requirement; so do RHEL 9 and its rebuilds, whose
glibc 2.34 carries the one 2.35 interface (`_dl_find_object`) that the bundled
libgcc_s asks for. An upstream 2.34 without that interface, as in Fedora 35, cannot
load it. The archive uses the system dynamic loader and bundles LLVM and its other
non-glibc dependencies. The release job checks every ELF file of the archive
(`tools/test-linux-toolchain-portability.sh`) and runs the compiler in Ubuntu 22.04
and AlmaLinux 9.
The standalone `ablac-x86_64-linux` release asset is the statically linked compiler
(src/orc_main_static.ab on LLVM's static archives and Abla's own C library: a static-pie executable with no
loader and no needed library, checked by tools/test-static-artifact.sh including its fixpoint) and the bootstrap
compiler (docs/bootstrap.md). It cannot `dlopen`, so compile-time `nativeLibraries` need
`ablac-dynamic-x86_64-linux`, which ships beside it for one release: that is the compiler built in the Nix shell,
the byte-reproducible one, and it names a Nix-store dynamic loader and finds libLLVM, libssl and libcrypto through
Nix-store RUNPATH entries, so it runs only where those store paths exist. Use the toolchain archive (still
packaged from the dynamic compiler) for an installed toolchain.

```sh
ablac build app.ab -o build/app
ablac build app.ab -o build/app --fast
ablac build app.ab -o build/app --fast --no-cache
ablac build app.ab -o build/app -g        # debug information in a release build
ablac run app.ab -- arguments  # compiled in process (--o1 IR pipeline) and called there, live on x86-64 Linux and macOS (--no-live; --watch reloads on a save)
ablac run --built app.ab   # built (--o1, cached) and exec'd
ablac test tests/*.ab      # build and run test programs (abla/test); --watch runs them again on each save
ablac fmt --check src/     # check layout without writing (formatter.md)
ablac repl
ablac serve app.ab
```

`ablac run` compiles the program in process, runs the `--o1` IR pipeline on it
(`--fast`: the fast one; `--jit` names this default) and calls it through LLVM
ORC; its `argv[0]` is the source path. The object LLJIT generated is kept in
`build/.abla-cache/run-*` with the size and hashes of every source file the
program read: a rerun with all of them (and the compiler) unchanged adds that
object and starts without compiling. A program with an executable top-level
compile action (other than a subparser registration), a nondeterministic
compile grant or a staged compile output is not kept. `--built` builds it through the build
cache instead and execs it in its place (`--release` does that with the release
profile): an unchanged program starts without compiling, it gets a process of
its own, and none of the compiler's memory stays behind, which suits a
long-running program. The executable is kept as `build/.abla-run/<source path>`.
Either way the program keeps the standard streams, the working directory and
the environment.

`ablac test` builds test programs into `build/abla-test/`, each named by the
files in it, so runs at once in one directory don't share a build (several files
as few programs as possible, each test still run in its own process), runs them,
prints `PASS <file>` or `FAIL <file> (exit <status>)` and a summary, and
exits with 1 when any failed; see [stdlib/testing.md](stdlib/testing.md). Test programs
are built with the `--o1` profile, as `ablac run`'s: a suite's time is mostly its tests
running. `--fast` builds them with the development profile instead, for tests that
run for less time than their build takes.

Built-in hosted targets are `x86_64-linux`, `x86_64-macos`, and
`arm64-macos`. Cross-linking Mach-O on Linux requires `ABLA_MACOS_SDK`; optional
`ABLA_MACOS_LLVM_LIB` and `ABLA_MACOS_OPENSSL_LIB` select directories holding
target dylibs or `.tbd` stubs. `tools/build-macos-from-linux.sh` prepares the
stubs from the pinned target-library ABIs and builds both Mac architectures.

## Packages

`ablac package update --project <dir>` evaluates typed `ImportSource`
expressions, resolves Git selectors or invokes deferred custom resolvers, and
transactionally publishes an immutable `abla.lock` plus validated cache
entries. Project builds prepare the locked graph before module loading without
invoking custom resolvers; `--offline` forbids Git fetching.
`ablac package vendor --project <dir>` publishes the complete locked source
graph under `vendor/`. The provider and lock contract is specified in
`docs/packages.md`.

## Build

`build` loads the module graph, executes bounded compile-time actions, verifies
typed IR, emits LLVM objects, and links the requested executable or library.
`--emit executable|object|static-library|shared-library` selects the hosted
artifact container; executable remains the default. Libraries without `main`
must explicitly publish at least one supported foreign adapter through the
compiler API; internal Abla symbols remain hidden.

An x86-64 Linux executable links no C library. It is a static
position-independent executable with its own entry point, memory routines,
system calls and threads, and it imports nothing. The compiler links libc and
the dynamic loader only when the program brings a C library itself: a TLS
connection (OpenSSL), the manifest's `nativeLibraries`, `extern "host"` calls,
or an `extern:"c"` function that the libc-free link cannot resolve. There is no
option for it: the program decides. `ablac build --verbose` prints a note
naming why a build linked libc. macOS executables link libSystem (below), and libraries
and objects are unchanged.

A macOS executable is an ordinary dynamic image that names `libSystem.B.dylib`: Apple's linker
refuses a dynamic image without it, and an arm64 static image is killed by the kernel (CI probes, #811; an
Intel static image runs). What a program calls out of it shrinks with the work in #811. The portable standard
library's system calls (files, directories, `stat`, `getdents`, descriptors, sockets, `poll` and `epoll` on
kqueue, process creation and waiting, signal masks, time and random numbers, resource limits, terminals)
are BSD system calls issued by the program itself (`__ablaRuntimeDarwinSyscall` in
`abla/runtime/platform/darwin`, a file only a Mach-O target loads, the inline `svc #0x80` / `syscall` of the `ablaDarwinSyscall` intrinsic),
and so are the runtime's panic output, exit and its fault handlers. `tools/libsystem-imports-allowlist.txt`
lists what a program, release and `--fast`, and the compiler still import; `tools/test-libsystem-imports.sh`
runs in the macOS CI job, and the list may only shrink.

The monotonic clock (`clock_gettime` of `CLOCK_MONOTONIC` through the portable surface) is the kernel's
`mach_absolute_time` from `gettimeofday`, in nanoseconds (by `hw.tbfrequency` on Apple Silicon; an x86-64 process's ticks, Rosetta's too, are nanoseconds): time since boot without the time
asleep, as Linux's `CLOCK_MONOTONIC` counts it (libSystem's `CLOCK_MONOTONIC` counts sleep too). The wall clock
is `gettimeofday`'s, to the microsecond.

What stays in libSystem, and why:

- `pthread_create` and `pthread_join` (decision #57): a Mach thread that libSystem does not know has none of
  its per-thread state, and the kernel's thread registration (`bsdthread_register`) is refused once libSystem
  has made it, which it has by the time `main` runs. Nothing else of libpthread: locks wait on `__ulock_wait`
  and `__ulock_wake`, and the stack guard needs no thread bounds (a fault near the interrupted stack pointer
  is an overflow).
- the thread-local bootstrap `__tlv_bootstrap`: Mach-O thread locals are descriptors that dyld's bootstrap
  resolves, and it stays (#811, 2026-11-15). The ways around it were looked at and refused. `TPIDR_EL0` is
  not preserved across context switches on Apple Silicon (the CI probe on 6409ecd4: 200000 of 200000 reads
  differed). Reaching a pthread key's slot directly (`TPIDRRO_EL0` + key * 8 on arm64, `%gs` on x86-64) reads
  libpthread's private data structure, which Apple changes without notice; and where a changed system call
  fails loudly (an error, a crash), a moved slot would make a thread-local read another key's or another
  thread's value with no error at all.
- `fork`: libSystem's fork handlers bring its state over to the child (Mach ports, malloc, locks). The BSD
  `fork` call alone left a child that ran C code broken (an OpenSSL handshake in a forked child failed on both
  Macs, #811), and the runtime cannot tell a child that only execs from one that does not.
- the compiler itself: libLLVM, OpenSSL, `dlopen`/`dlsym` for compile-time native calls, and its
  threads.

What a macOS program imports (`tools/libsystem-imports-allowlist.txt`, release and `--fast`, both Macs):

| Program | Imports |
|---|---|
| one that starts no thread (hello, files, strings, float `%`, tasks, pure-Abla TLS) | `libSystem.B.dylib`, `__tlv_bootstrap`, `_fork` (a `--fast` task program on Apple Silicon also `_pthread_join`) |
| one that starts threads (`thread { }`) | those, `_pthread_create`, `_pthread_join` |
| one with a TLS connection through OpenSSL (`abla/tls/hosted`) | those, `libssl` and `libcrypto` and `_OpenSSL_version_num` (its lines marked " ?" were not yet checked on a Mac) |
| a dylib (`--emit shared-library`, `tests/cases/libsystem-dylibs`) | `libSystem.B.dylib`, `__tlv_bootstrap`, and `_pthread_create`, `_pthread_join` when it starts threads (#833; not yet checked on a Mac) |

The memory and jump routines, float remainder, system calls, signals and their trampoline, clocks, random
numbers, the running image's path and the stack guard are the program's own (a dylib's too); the image uses
chained fixups (no `dyld_stub_binder`), and an `@hostImport` symbol of a dylib is a flat-namespace bind.

`ablac run` on macOS JIT-compiles the program with LLVM's emulated TLS (LLJIT has no MachOPlatform), so a thread-local of
the program is a call of `___emutls_get_address`. The compiler defines that function itself (`abla/runtime/emutls`, exported
from `src/emutls_export.ab`), on the Abla heap and atomics: compiler-rt's imports libSystem's `malloc`, `free`, `realloc`,
pthread mutexes and keys, so the compiler imports none of them (#826), except the two key calls below. A control block gets its index from one process-wide
counter by a compare-and-swap, and each thread has one table of its variables' addresses, grown by copying. A thread's table and variables are freed when the thread ends: the runtime calls a thread-end hook last (`__ablaRuntimeThreadEndHook` in `abla/runtime/self`), which the first table a thread makes points at `emutlsThreadEnd`; a JIT-compiled program has a runtime of its own, whose hook the compiler sets before `main` runs (`llvmOrcInstallThreadEnd` in `abla/llvm/orc`). A thread the runtime did not start (a host's pthread calling an exported function, a thread of LLVM's) never reaches that hook. On macOS the first table such a thread makes also stores a value under one pthread key whose destructor is `emutlsThreadEnd`, and the system runs it as the thread ends (`_pthread_key_create` and `_pthread_setspecific` are the compiler's only libSystem imports from this module; `tools/libsystem-imports-allowlist.txt`; not yet checked on a Mac). On Linux a key would be a new libc import of the compiler (#806, `tools/libc-imports-allowlist.txt`), so the module uses system calls only: each thread's first table is entered in a registry with the thread's id (`gettid`), and a later registration frees the tables of the threads that have gone, found with `tgkill(pid, id, 0)` (ESRCH). The sweep is lazy, when the registry has doubled since the last one (at least 8 entries), so a bounded number of ended threads' tables wait (about 16 KiB in the test); an id given again to a new thread is recognised at its registration; `emutlsReclaim` sweeps at once. Without any of this such a thread leaves
8 * (1 + capacity) bytes (the capacity is the largest index it used, at least 8; indexes are process-wide and never reused)
plus each variable's size and its alignment padding: `tests/cases/emutls/foreign-lib.ab` and `foreign-driver.c` (run by `tools/test-emutls.sh`) call an export from 1,600 short-lived pthreads and require 0 bytes left after a sweep (3.6 MB without). `tests/cases/emutls` (500 threads one after another) measures none; before the hook it measured 654 bytes per thread for ten variables (indexes 1 to 10) and 7,796 for eighty, so a JIT-compiled program that started and joined a million threads touching ten variables left about 650 MB behind. `tests/cases/emutls/jit-threads.ab` runs a hundred thousand JIT-compiled threads and checks the resident size (not verified on a Mac yet). The heap lock is made live before
`ablac run` calls the program's `main` (`runtimeMemoryEnableSharing`), because a thread the runtime did not start allocates
from the compiler's heap.

The BSD system call numbers and structure layouts in the dispatcher are not checked on Linux: the macOS CI
job runs `tools/test-darwin-syscalls.sh` (one line per call, the same program that runs on Linux with Linux's own
numbers) before building stage 2, and that run is what judges each one.

The heap of such an executable is Abla code over the `mmap`, `munmap`, `mremap` and `madvise` system
calls (`__ablaRuntimeHostHeap*` in `abla/runtime/platform/host.ab`); `runtimeMemoryRelease()` gives
its free memory back to the system. Its lock is taken only once a second thread exists (an Abla
thread or the background-free helper). A fork while another thread holds the heap lock (or the runtime's
own mutex) does not leave the child locked for ever: the first runtime lock the child finds held notices the
fork, through a page of its own that the kernel zeroes in the child (`MADV_WIPEONFORK`, Linux 4.14, so no
system call and no hook on the allocation path), frees both locks, and, when the heap's lock was held, drops
the free lists, bins and cache of large mappings (their memory leaks) and never merges blocks again in that
child, since a list the other thread was updating may be half written. A kernel without that advice does not
detect it. Only the runtime's own locks are repaired: a user `Mutex` or `Shared` that a vanished thread
held stays held, as POSIX has it. When the runtime mutex or the heap lock was found held, the thread that held
it may have been halfway through registering an allocation, so collection stays off in that child for good
(`memoryCollect()` returns 0; allocation goes on). An Abla thread pool does not survive a fork (its workers are gone); the standard library's
process functions and the compiler's own capture still prepare everything before the fork and allocate
nothing in the child, which stays the safest way to run a program after a fork, as POSIX asks of any
multithreaded process.

Programmable external targets can additionally request a generic `module`
artifact. The current WebAssembly linker produces a no-entry module, preserves
explicit foreign exports, retains unresolved symbols from explicit foreign
declarations as ordinary `env` function imports, and strips PID-bearing name
metadata for byte-level reproducibility. `@wasmImport("module")` on an
`extern:"c"` declaration imports it from that module instead of `env`;
`@wasmImport(["module", "field"])` also renames the import field, which
otherwise is the symbol name. Other targets ignore the annotation:

```abla
@wasmImport("wasi_snapshot_preview1")
trusted noescape extern:"c" fun fd_write(fd: i32, iovs: i32, count: i32, written: i32): i32
```

The embedding runtime must validate the imported symbol names and signatures

An extern that nothing defines (a typo, a symbol the host was meant to supply)
therefore links silently as an `env` import. `ablac build --wasm-imports` prints
every import of the linked module as `note:` lines. A `wasmHostImports` list in
the entry's `abla.toml` (`module.name` strings, or `module.*` for a whole module)
names the imports the host defines, and every other import is a `warning:`; the
runtime's own `abla_host.*` imports are always expected. Without the list and the
flag a build prints nothing (tools/test-wasm-imports.sh).
before instantiation. A Wasm build with debug information keeps the function
names and publishes `<module>.map` and `<module>.debug.wasm` beside the module.

A bare wasm32 module (`wasm32-unknown-unknown`, such as a page's) has no kernel
and no C library, so the standard library's system calls (`abla/io`'s
`println`, `abla/process/exit`, `abla/process/time`'s clocks, random bytes) go
to the browser host ABI instead: a few imports from module `abla_host`, of
which a module imports only those its program reaches. Every other system call
fails with `-ENOSYS` (-38). A float `%` needs no import: the module carries an
exact fmod.

| Import | Signature | |
|---|---|---|
| `abla_host.write` | `(fd: i32, data: i32, length: i32) -> i32` | writes `length` bytes at `data` to descriptor 1 or 2; the bytes written, or `-errno` |
| `abla_host.exit` | `(code: i32)` | ends the program with `code` (a host throws); never returns |
| `abla_host.clock_ns` | `(clock: i32) -> i64` | 0: the wall clock in nanoseconds since 1970-01-01T00:00:00Z; 1: a monotonic clock in nanoseconds |
| `abla_host.random` | `(data: i32, length: i32) -> i32` | fills `length` bytes at `data` with cryptographically random bytes; `length`, or `-errno` |

Pointers are addresses in the module's exported `memory`.

A panic traps. A module that imports `abla_host.write` for another reason also
writes `panic: <message>` and a newline to descriptor 2 first; no module gains
an import for it. A development build decides when the module is optimized; a
release build links without the message, and links again with it only if that
first link imports `write`.

Development (`--fast`) builds carry debug information: DWARF line tables,
readable function symbols and, natively, frame pointers and a printed stack on
a crash. Release builds don't; `-g`/`--debug`, `--no-debug` and
`ABLA_DEBUG=1|0` override either. See [debugging.md](debugging.md).

A development (`--fast`) WebAssembly build optimizes its module and writes its object
in the compiler's own process, with the passes and options `opt` and `llc -O0` would
use, and keeps no LLVM text. Before writing the object it moves the optimized module
into a fresh LLVM context (as in-memory bitcode), so what building and optimizing it
left in the old context is freed and the build's peak memory stays below that of a
separate `opt` and `llc`. `ABLA_KEEP_LLVM_TEXT=1` keeps the text, as
`<module>.ll` beside the module, and runs `opt` and `llc` on it;
`ABLA_LLVM_OUT_OF_PROCESS=1` runs them on the module as bitcode instead. Release
builds always write that text (their LTO step reads it), and so do native builds.
After in-process Wasm code generation, the compiler restores LLVM 23's global
minimum jump-table size to its default of 4 (Wasm sets it to 2). This keeps later
native optimization independent of earlier Wasm builds in the same process.
Handed over as bitcode, the module also loses the names of its local values in `opt`
and `llc` (nothing after them reads those names; functions and globals keep theirs),
and neither tool verifies it again, since the compiler verified it as it emitted it.
With `ABLA_KEEP_LLVM_TEXT=1` the names stay; `ABLA_LLVM_VERIFY=1` turns LLVM's
verifiers back on. Its object is compiled with static relocations: a module links as
one static image, so position-independent code would only reach its globals through
the GOT. Its inliner works to a threshold of 100 rather than LLVM's 225 (each
function carries it as `function-inline-threshold`), which takes a large program's
optimization and code generation about 14% less work for a run time within a percent
or two; `ABLA_FAST_INLINE_THRESHOLD=<n>` sets it.

A large development module (a WebAssembly module, or an executable's object on
macOS) is optimized whole and then generated as 8 units by child compilers at once,
whose objects are combined into the build's one file (a WebAssembly object, or an
archive of the units that the link loads whole); release builds are always one
whole-module object. `ABLA_CODEGEN_UNITS=<n>` sets the number of units (1 turns
units off), `ABLA_CODEGEN_JOBS=<n>` how many children run at once (default: the
cores), `ABLA_CODEGEN_UNITS_MINIMUM=<n>` the fewest IR instructions a module is cut
at (default 150,000), and `ABLA_CODEGEN_UNITS_TRACE=1` prints the cut. A unit's
object is kept in the code generation cache (`<cache directory>/codegen`) under a
key of the unit's code, so a unit no edit changed isn't generated again, by any
build: nothing there can be stale, so `--no-cache` leaves it on;
`ABLA_CODEGEN_CACHE=0` turns it off, and `ABLA_CODEGEN_CACHE_MB=<n>` bounds it
(default 2048: past it the oldest objects go). See
[llvm-backend.md](llvm-backend.md#code-generation-units).

A release WebAssembly module ends with Binaryen's `wasm-opt -O3`, run with as many
workers as the online CPUs, up to 4 (its output does not depend on the count);
`ABLA_WASM_OPT_CORES=<n>` sets it.

An extension-defined target with linker flavor and emulation `none` may use
any object triple implemented by the installed LLVM and emit an `object` or
`static-library`. LLVM target registration is not architecture-specific.
The same generic contract is available directly from the CLI with
`--target-triple <triple> --object-format <format>`; it defaults to an object
artifact and deliberately cannot request an executable or shared library.
An object or static library does not require a hosted `main`; freestanding
startup code and interrupt vectors may provide their own roots and entry
symbols. A hosted executable continues to require `main` unless it publishes a
supported foreign entry adapter.
Executables, shared libraries, and modules require an explicit supported
runtime/linker contract; a target descriptor cannot silently imply a host ABI,
startup sequence, sysroot, or platform linker.
There is currently no built-in freestanding executable target. Defining an
LLVM object triple does not silently imply a host ABI, startup sequence,
allocator, sysroot, or executable-link contract.

Every successful artifact publishes `<output>.abi.json` through the compiler's
staged-output transaction after linking. The versioned manifest is derived
from resolved export requests rather than handwritten platform glue and
includes target/artifact identity plus
ownership, nullability, and failure-containment metadata. It is a member of the
native cache record, so a cache hit restores a missing sidecar instead of
silently publishing an undocumented binary. Schema version 1 exposes value
scalars, copied borrowed-byte inputs, call-scoped non-escaping scalar
callbacks, and owned-byte result handles. Direct exports honestly mark panics
as uncontained. Opt-in checked exports on hosted x86-64 Linux and macOS publish their
status/out-pointer/caller-buffer ABI and abortive-cleanup semantics; unsupported
targets reject them with `E_EXPORT_TARGET_CAPABILITY` rather than silently
downgrading containment.
The current owned-byte result handle is available only when the target provides
the libc allocation contract; libc-free module targets reject it before object
emission.

The default hosted release profile runs the deterministic
`default<O2>,globaldce` pipeline. Release builds for MCU triples run
`default<O2>,globaldce` on functions marked `minsize` (LLVM 23 has no
`default<Oz>`); the target still receives LLVM's optimized machine-code
generator, while whole-program optimization prioritizes constrained flash.
Hosted `--fast` skips whole-module optimization and selects LLVM's low-latency
code generator for edit/build cycles. A hosted release executable is linked from
its own whole-program (LTO) object. Its ordinary object, the relocatable sidecar
`<output>.o`, takes a whole second optimization and code generation (most of a large
program's release build after the front end) and nothing in the build reads it, so it
is built only on request: `build --sidecar` (or `ABLA_SIDECAR=1`) builds it beside the
executable, which is the same either way. `--no-sidecar` (or `ABLA_NO_SIDECAR=1`)
declines it whatever the environment asks; a build without it removes a stale one. A
program that links LLVM links its ordinary object and builds it either way. External cross targets run a bounded
`default<O1>,globaldce` pass in fast mode, because target lowering must not
validate unreachable host-only runtime assembly. It still runs the complete
frontend, compile-time evaluator, verifier, object emitter, and linker; it is
not a cached or partial build. The default output is a native executable under
`build/`.

Native objects are cached under `build/.abla-cache` in the working directory,
or in the directory `--cache-dir <dir>` (on `build`, `test` and `run`) or
`ABLA_CACHE_DIR` names; `ablac run`'s objects too. A directory outside the tree
outlives it: a build in a fresh copy of a project, made from the copy's root,
finds the entries an earlier copy's builds left (entries are keyed by content
and by paths as the build names them, so projects and copies can share one
directory). A hit requires an exact
comparison of the complete bundled source after matching its length, two
independent deterministic fingerprints, target/LLVM ABI version, and
optimization profile. Cache manifests are published only after successful
object emission. The entry manifest is part of the identity. Successful
`filesystem.read` staging records every observed path, content size, and two
content fingerprints; a hit re-reads and validates those inputs before it may
skip the frontend. Corrupt input records are misses. Ambient effects without a
deterministic input contract remain uncached. Subparser handlers and generated-
module finalizers merge their transaction-local read journals into the same
artifact identity. Persistent frontend snapshots revalidate those inputs
before reusing staged syntax. A hit skips
frontend and LLVM work, restores the recorded
libLLVM/host-adapter link decisions and relinks; a release executable or Wasm
module also takes the LTO object its entry's first build made, kept under a key
of the `opt` and `clang` it was made with (the file each name runs, its size
and time), so a hit neither prepares nor compiles the module again. Every
Mach-O build links the Darwin adapter's object, which the cache keeps by the
adapter's source, `clang`, SDK and target; a local adapter change is never
hidden. The
cache ABI tag in `src/toolchain.ab` must be bumped whenever
object semantics change without a corresponding source-graph change.
`--no-cache` bypasses both lookup and publication while still emitting the
`.ll`/object sidecars. It is the reproducibility and profiling mode used by the
pure self-rebuild gate; options after the source are order-independent.

A module whose package doesn't set `visibility` is [strict](language.md#strict-imports)
by default; `build --flat-imports` builds those modules flat instead (not a package that says `visibility = "imports"`), the opt-out for code
not yet migrated, and `--strict-imports` says the default explicitly (the mode is part of
the cache identity, a build's and `ablac run`'s). `ablac test` and `ablac run` take the same
three modes. A repository whose scripts call the compiler many times sets `visibility = "flat"`
in its abla.toml instead, which every one of those calls reads. Both are deprecated: each prints one
`warning[W_FLAT_IMPORTS_DEPRECATED]` per build (the flag's even from the cache), naming the flag or the
manifest, and `ABLA_ALLOW_FLAT_IMPORTS=1` silences it ([packages](packages.md)). An `E_NAME_NOT_IMPORTED` in a module strict only by default has a
second `help:` line naming the opt-out. `build --strict-imports=warn` leaves those modules flat and prints,
as a warning, each diagnostic `--strict-imports` would give them, with the
same place and `help:` line: a name of a module they don't import, an
extension function, operator or overload of one, a name two imports pass on
through `export import`. Each is printed once, and the build doesn't use the
cache (the warnings come from the front end). A package that sets
`visibility` is not affected. `build --visibility-report <file>` builds as usual, without the
cache, and writes to `<file>` one tab-separated line per name a module would
lose under strict imports: module, line, column, name, declaring module and
the import to add, and a line with a seventh column, `member` or `overload`,
for each extension function or operator call and each overload choice that
relies on a module the caller doesn't import (found once the call is typed). `ablac run tools/fix-imports.ab -- <file>` adds those
imports (a module the file already imports, even under an alias, is left alone). To migrate a package that doesn't
build strict yet: `ablac build app.ab -o app --flat-imports --visibility-report report.tsv`, then the fixer, then
`ablac build app.ab -o app`; a new import that makes a name ambiguous needs an alias, which that build reports.

A build warns about each import the importing file doesn't use: `warning[W_UNUSED_IMPORT]: <file>: nothing
`import "x"` declares is used here`, with the import's place. A use is any name the module declares (a call, a type,
an extension method or operator it resolves to, the receiver of an extension the file declares, a `$name` subparser it
or a module it passes on registers, a call a subparser generates in the file, a compile function an import line calls
as its provider, a function or type compile code anywhere in the build looks up by name (`compilerFindFunction("x")`,
`compilerFindType("x")`), abla/float/text's `f64Text` for an interpolated float). The warning is for the project's own modules only: not the standard library, a vendored package
(`.abla/packages/`), another project's module or a checkout linked into the project. It is never given for an aliased,
exported or contract-only import, an import of a module that does something by being loaded (an `@export` function or
a top-level `#` action, or a runtime hook `fun __abla...` the backend binds by name), an import in a module that runs compile code (what it compiles may read the module) or defines syntax (the code its
subparser generates may call the module), or after
a front end that stopped at an error (an IR error such as a library's `E_NO_MAIN`, or a failed link, still gets it). A
package's entry gets a different line instead: the import is neither used nor passed on, `export import` it if the
package means to offer it. `--no-warn-unused-imports` or `ABLA_WARN_UNUSED_IMPORTS=0` turns it off;
`--warn-unused-imports` turns it on over the environment. A cache hit prints the lines its entry kept. `ablac
fix-imports [<file.ab> | --project <dir>] --prune [--dry-run]` removes the warned imports (never an entry's, never the
last import of a file with a `#compilerGrant`, never one in another project), builds again and puts back any file whose
build got worse, and refuses a build that stops in the front end.

Compile-time build definitions may register additional program nodes through
the versioned compiler API. After the root succeeds, `build` drains the bounded
graph in declaration order; a requested program may add further nodes. This
mechanism is target- and framework-neutral—the compiler executes program,
artifact, and bounded external-target requests, while libraries own Android,
WASM, MVC, RPC, or packaging policy. The Android arm64 shared-library and
WASM/MVC module proofs plus remaining transaction/ABI work are documented in
`docs/programmable-builds.md`.

Long-lived builds additionally retain a module snapshot store in pure Abla.
Each snapshot atomically associates source text, scanned import edges, two
content fingerprints, and the observed file size/revision. On a watched
rebuild, unchanged modules reuse both their source and dependency scan; a
changed module refreshes only its own snapshot, and changed import edges select
the new active graph without accidentally retaining the old dependency. This
state also caches one dependency-fingerprinted staged AST per module path.
Imported compile-time subparser registrations participate in that fingerprint,
so changing a parser provider invalidates every later syntax tree that could
have invoked it. Keeping one AST version per path bounds edit-history growth.
This is deliberately distinct from the whole-graph native object cache. Typed
interfaces and independently emitted module objects are the next granularity
step; an edited graph still goes through whole-program semantic analysis and
code generation today.

## Run and REPL

`run` executes the same verified IR without compiling through C. The current
bootstrap milestone executes textual LLVM IR with the Abla-authored ORC binding
inside the final compiler process, avoiding object emission and native linking.
A program that selects a host capability resolves its host functions from the
compiler process; no adapter library is built for the JIT.
The bootstrap compiler retains a separate runner until the C bootstrap path is
retired. `ablac repl` is a live run (`src/live_repl.ab`, where live mode runs: x86-64 Linux and macOS): one
program runs for the whole session and each line is a reload of it. A declaration (`fun`, `val`, `var`,
`class`, `import`, ...) replaces the one of the same name or is added (`defined`); a variable keeps its value
from line to line. Any other line is an expression whose value prints (an int, a string, a float; an array,
which does not interpolate, as `<array of size N>`), or a statement (`total += 5`). A line that panics prints `E_LIVE_PANIC` and its message on
stderr and leaves the session as it was; a change the running code cannot take is refused (`E_LIVE_SIGNATURE`,
...) with the old definition kept; a line that does not compile prints its diagnostics. `:reset` starts a new
program with nothing defined. Elsewhere `repl` compiles each line on its own in a child compiler, so only
declarations persist. In both, an entry whose bracket (`(`, `[`, `{`), string or `/*` comment is still open
continues on the next line (`....> `), so a function or class body can span lines; an empty line ends an
entry still open. `:help` lists the commands, `:type <expr>` shows the type of an expression without running it
(the live REPL; the compiler's own inference, through `#compiler.typeName`), `:quit` (or the end of the input) ends
the session, and any other entry starting with `:` is an unknown command, refused without a compile. On a
terminal the REPL edits a line itself (`src/repl_editor.ab`, no readline): left and right, Home and End (Ctrl-A,
Ctrl-E), Backspace and Delete, up and down through the session's earlier lines, Ctrl-K and Ctrl-U cut to the end
and to the start, Ctrl-C drops the entry, and Ctrl-D on an empty line ends the session. The terminal's own settings are back while an entry runs, so
Ctrl-C interrupts it as before. `ABLA_REPL_EDITOR=0` (or `TERM=dumb`, or input that is not a terminal) reads lines as
they come.

The interpreter is not a second language implementation. Compile-time `#`
evaluation, `run`, tests, the REPL, and macro/subparser handlers share the same
instructions, values, limits, native registry, and diagnostics. The JIT is a
different execution backend for that IR and must pass interpreter/JIT parity.

### Live run: `ablac run` (`--no-live` to opt out)

`ablac run` (with the default `--o1` or with `--fast`) runs the program so that its functions can be redefined
while it runs. It is the default where live mode is supported, x86-64 Linux and macOS (decision #65); `--no-live`
runs it as before, and elsewhere `run` is not live unless `--live` asks (no ablac is built for AArch64 Linux). `--built` and
`--release` ignore both without a warning, and `ablac build` and `ablac test` never build this way.

The functions of the program's own source files (not the standard library, the runtime or module
initialisers) are called through one table of code pointers: direct calls, function values, closures, thread
and generator entries and recursion all reach the newest body. The price is two dependent loads per call and
no inlining of those functions. A live run has its own object-cache key.

The program asks for a reload with `abla/live`, after its source files were edited on disk
(`tests/cases/live-jit/reload.ab` edits its own copy and reloads):

```abla fragment
import "abla/io"
import "abla/live"

if (liveAvailable()) {
    val result = liveReload()
    println(result.message)
}
```

`liveReload()` compiles the program's sources again as the next generation and keeps only the functions whose
code changed. It returns a `LiveResult` whose `status` is `applied()` (0), `refused()` (1), `failed()` (2) or
`unavailable()` (3: not a live run). Calls made after it returns take the new bodies; a thread that is
inside an old body finishes it on the old code; old code is never freed, so each applied reload costs memory (measured: 4 to 76 kB of code a reload; past 256 MB in a run, stderr says once that a restart gives it back);
the calling thread blocks while the compiler works. A refused reload changes nothing and the old code keeps
running; the message names the reason:

| Code | Reason |
|---|---|
| `E_LIVE_LAMBDA` | a lambda's captures, parameters or result changed (an edited or added lambda applies) |
| `E_LIVE_GLOBAL` | a new variable whose initializer reads a value computed before it, so it can't run alone (other new variables of the program's own files are initialized once when the reload applies; a new one of the standard library is refused) |
| `E_LIVE_SIGNATURE` | a changed parameter list or result of a function the running code takes as a value (anywhere, a lambda in another module too) or of a method; any other such function moves to a new entry: the running code keeps the old one, new code calls the new one |
| `E_LIVE_LAYOUT` | a class's name, fields or size changed |
| `E_LIVE_CALLER` | an unchanged function would compile differently (for example through an escape fact); the message names it and the edited callees |
| `E_LIVE_BUSY` | another reload is running |

A program that no longer compiles is `failed` with `E_LIVE_COMPILE` (the diagnostics go to stderr), and new code
that cannot be loaded is `E_LIVE_LINK`. A new variable whose initializer panics is `failed` with `E_LIVE_PANIC` and
the panic's message: the reload's code goes and the program keeps running with its variables as they were (a live
run keeps the runtime's panic recovery for it). `ABLA_LIVE_DUMP_MODULE=<prefix>` writes each reload module as
`<prefix>-<generation>.ll`. `ABLA_LIVE_TRACE` (any value) prints how many functions go through the
table; `ABLA_LIVE_DUMP=<dir>` writes each compiled body per generation as `<generation>-<name>.ll`.
Tested on x86-64 Linux and on both Macs (arm64 and Intel, in CI). What is built and what is not: [the design](design/live-jit.md).

`ablac run --watch` is a live run that reloads by itself: when one of the program's own source files changes, the
same reload runs and its outcome goes to stderr as one line, `ablac run --watch: applied: <functions>`, or
`E_LIVE_COMPILE` after the diagnostics. A save that does not compile keeps the program running its code, and the
next good save is applied. A changed signature that applies (the function is never taken as a value) adds a line
per such function, `live: <name>'s signature changed; callers redefined: <callers> (it applies when they are
entered again)`: a caller that never returns keeps its old body. A save the running code cannot take (a refusal: a
changed signature of a function taken as a value, a layout, a new global; or new code that does not link) restarts
the run: one line, `ablac run --watch: restarting the program:
<code>: <function>: <why>`, then ablac replaces itself (the same process) with a fresh run of the same arguments
and environment, so the program starts again on the saved sources and its state is lost (its descriptors close: the
standard library opens them close-on-exec). The restarted run takes its reason out of the environment before the
program sees it (`ABLAC_WATCH_RESTARTED`); if its first reload is refused for that same reason, it says so and keeps
running its code rather than restarting again. A reload the program asked for itself (`liveReload`) never restarts.
The program's `main` runs on a thread of its own, and the compiler's thread waits for the files to change (`abla/fs/watch`: inotify on Linux, kqueue on macOS,
through system calls, no libc). It lets a burst of writes settle (an editor saves in several steps: a quiet 120 ms,
at most about 3 s) and reloads only when a file's contents changed. Only the files the module graph read are
watched, not the standard library, the cache or output directories, and the list follows each reload (an added
import is watched from then on). `--watch` implies `--live`; it does not go with `--built`, `--release` or
`--no-live`. `tools/test-live-watch.sh` edits a running program, saves a broken file and changes a result type.

`ablac test --watch <files>` runs the tests, then again each time a file they read changes: each run is a child
`ablac test` with the same arguments (its output is a plain run's), followed by one line on stderr, `ablac test --watch:
passed|failed; watching N files`. The files are each test's module graph (import discovery), not the standard
library's; the wait is `run --watch`'s (inotify or kqueue, a burst of writes settles, only a change of contents runs
the tests). It runs until stopped. `tools/test-test-watch.sh` breaks and fixes a module a test imports, and saves one it
does not.

## Compiler diagnostics

Every failed compilation renders at least one primary `error[E_*]` diagnostic
for every counted error. Parser diagnostics carry the normalized module source
identity and byte range. Extension-generated declarations additionally retain
their generated namespace and originating extension-expression range through
semantic analysis and typed IR lowering.

Failure summaries partition the total into parser, extension, semantic, and IR
counts; those four counts always add to the displayed total. A function-level
IR verification failure names the function and invariant category. Lowering or
emission failures that cannot be associated with a function use the explicit
`E_IR_UNCLASSIFIED` or `E_IR_EMISSION` fallback rather than disappearing into
the aggregate count.

`E_NATIVE_TOOLCHAIN` is reserved for a nonzero result from an external native
compiler, linker, or archiver. Compiler diagnostics, unsupported target or
artifact requests, and filesystem publication failures retain their own error
codes and are not relabelled as native-toolchain failures.

## Serve

`serve` is a persistent run mode intended for HTTP servers, build daemons, and
interactive applications. It content-fingerprints the complete imported module graph and
swaps code only after parsing, typing, compile-time actions, LLVM emission, and
native linking succeed. Watched rebuilds use the fast AOT profile. A failed edit leaves the previous valid generation
running. The supervisor currently uses validated native worker processes. An
Abla HTTP worker handles `SIGTERM` as a drain request: it completes the active
request, stops accepting, closes its listener, and exits. The supervisor waits
up to five seconds before force termination, then starts the next generation.
ORC resource trackers already support in-process code reclamation; moving the
network worker itself into that session remains a later concurrency milestone.
The supervisor retains module snapshots across accepted and rejected
generations, reports refreshed/reused module counts, and updates its watch set
from the newly active import graph.

Thus `run` is a one-shot JIT execution, while `serve` is the watched,
reload-safe long-running supervisor. Both can run an HTTP server; only `serve`
observes source changes and retains the last valid generation.

An ordinary compile-time action remains bounded and terminating. Network,
filesystem mutation, processes, clocks, and other ambient effects require
explicit capabilities and become recorded build inputs where reproducibility
is requested. A long-running server belongs to `run`/`serve`, even when its
startup and reload path evaluates compile-time Abla code.

## Resource safety

Compiler subprocesses and bootstrap generations always run behind the project
resource guard. The guarded `build/ablac` launcher enforces address-space,
wall-clock, CPU, and core-dump limits. REPL evaluations additionally use a
checked lexical allocation region and ORC resource tracker. The same region
checker is available to HTTP libraries, though request-handler adoption still
needs an explicit API policy for promoted response values and long-lived state.

The complete compiler rebuild uses
`tools/build-self-hosted-release.sh build/ablac.bin build/ablac-next`. It splits
deterministic LLVM emission, object generation, and linking into separate
bounded processes so the frontend and LLVM object-generation heap peaks do not
coexist. After emission it may reuse an optimized executable only from an exact
content-addressed match over the module, runtime inputs, host, toolchain, and
release profile. `ABLA_RELEASE_SELFHOST_CACHE=0` forces a cold backend. The
release gate still verifies byte-identical IR from the rebuilt compiler.

## Environment variables

| Variable | Effect |
|---|---|
| `ABLA_SYSROOT`, `ABLA_STDLIB` | where the toolchain's standard library and runtime are found (above) |
| `ABLA_LLVM`, `ABLA_LLD` | other prefixes of the LLVM and LLD the compiler links |
| `ABLA_DEBUG=1\|0` | debug information on or off, overriding the build profile ([debugging.md](debugging.md)) |
| `ABLA_CACHE_DIR` | where builds and `ablac run` keep their caches (default `build/.abla-cache`; `--cache-dir` wins) |
| `ABLA_MAX_MEMORY_MB`, `ABLA_MAX_SECONDS`, `ABLA_MAX_CPU_SECONDS`, `ABLA_KILL_GRACE_SECONDS` | the launcher's resource guard for the compiler and anything compile-time code starts ([performance.md](performance.md)) |
| `ABLA_MAX_STACK_KB` | the compiler's stack size in a packaged toolchain |
| `ABLA_NATIVE_JOBS` | how many parts of a large release module are generated at once; the output does not depend on it |
| `ABLA_CODEGEN_UNITS`, `ABLA_CODEGEN_JOBS`, `ABLA_CODEGEN_UNITS_MINIMUM`, `ABLA_CODEGEN_UNITS_TRACE`, `ABLA_CODEGEN_CACHE`, `ABLA_CODEGEN_CACHE_MB` | a development build's code generation units and their cache (above) |
| `ABLA_EVAL_STEP_LIMIT`, `ABLA_EVAL_DEPTH_LIMIT` | override the compile-time step limit or lower the recursion-depth limit ([compile-time.md](compile-time.md#limits)) |
| `ABLA_COMPILE_EVAL=auto\|interp\|jit`, `ABLA_COMPILE_EVAL_TRACE=1`, `ABLA_COMPILE_EVAL_DUMP=<dir>`, `ABLA_COMPILE_EVAL_PASSES=fast\|balanced`, `ABLA_COMPILE_EVAL_UNITS=0`, `ABLA_COMPILE_EVAL_TIME_LIMIT=<s>`, `ABLA_COMPILE_EVAL_TRIAL_STEPS=<n>` | run each compile-time site natively when the native tier can take it and in the evaluator otherwise (`auto`, the default, leaves a pass with no loop, recursion or call through a C function pointer in its sites to the evaluator, and first tries a site that can act on nothing outside it there within a step budget, default 1000000, `0` none; `jit` takes every site it can), or every site in the evaluator (`interp`), report each site's tier and why a site stays in the evaluator, keep the native slices, and bound one native evaluation (default 600 s, `0` none) ([compile-time.md](compile-time.md#native-evaluation)) |
| `ABLA_JIT_CACHE=0`, `ABLA_JIT_CACHE_TRACE=1` | turn `ablac run`'s object cache off, or report its decisions on standard error (above) |
| `ABLA_PACKAGE_CACHE` | the package cache directory ([packages.md](packages.md)) |
| `ABLA_KEEP_LLVM_TEXT`, `ABLA_LLVM_OUT_OF_PROCESS`, `ABLA_LLVM_VERIFY`, `ABLA_FAST_INLINE_THRESHOLD`, `ABLA_WASM_OPT_CORES`, `ABLA_SIDECAR`, `ABLA_NO_SIDECAR` | code-generation controls (above) |
| `ABLA_MACOS_SDK`, `ABLA_MACOS_LLVM_LIB`, `ABLA_MACOS_OPENSSL_LIB`, `ABLA_MACOS_CLANG` | cross-linking for macOS: the SDK, target libraries, and the `clang` used to link (default `clang`) |
| `ABLA_COMPILER_COLLECT_GROWTH_MB` | without a launcher memory budget, the compiler collects garbage each time its heap grows by this much (default 256; 0 never collects) |
| `ABLA_COMPILER_MEMORY_TRACE`, `ABLA_COMPILER_REACHABILITY_TRACE` | when non-empty, print the compiler's live memory per phase, or its reachability decisions, to standard error; `ablac analyze --stdio` prints `abla-analysis-memory <phase> <reachable bytes>` (after a collection) at the phases of each analysis (tools/test-analysis-memory.sh bounds the edit loop against the cold analysis) |
| `ABLA_EVAL_INDEX_CHECK`, `ABLA_OVERLOAD_CHECK`, `ABLA_BORROW_INDEX_CHECK`, `ABLA_RECEIVER_INDEX_CHECK`, `ABLA_EXPECTED_INDEX_CHECK`, `ABLA_MODULE_INDEX_CHECK`, `ABLA_LIFT_CODEC_CHECK` | compiler self-checks for its own tests: `=1` cross-checks a fast path against the slow one and reports any disagreement |

Source formatting, preservation checks and editor stdin usage are described in
[formatter.md](formatter.md).
