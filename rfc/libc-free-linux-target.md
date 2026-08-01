# RFC: Libc-Free Native Linux Executables

- Status: Implemented baseline
- Target: LLVM backend, native linker driver, and Linux runtime
- Motivated by: Abla's original freestanding target and Abla MVC deployment

## Summary

Add an explicit native Linux target that produces executables with no libc,
dynamic-loader, C runtime startup, or other host runtime dependency.

This is different from statically linking libc. A libc-free Abla executable
should provide its own Linux entry point and runtime primitives, use raw Linux
system calls where operating-system services are required, and contain no
undefined references to `malloc`, `free`, `memcpy`, or other libc symbols.

The existing hosted target may remain available for C interoperability and for
platforms whose native runtime is not yet implemented. The proposed raw target
should be selectable and continuously tested as a first-class compiler target.

The initial x86-64 implementation is available as
`--target x86_64-linux-raw`. It links directly with LLD, supplies `_start`,
`mmap`/`munmap` allocation hooks and fallback memory primitives from the
target runtime object, rejects host/LLVM capability imports, and is gated by
ELF interpreter, dynamic dependency, undefined-symbol, execution, allocation,
portable-I/O, and argument checks. Additional architectures and a lower-
overhead allocator remain follow-up work.

## Motivation

Avoiding a mandatory libc dependency was one of Abla's project targets and is
already reflected in the architecture documents:

- `docs/language.md` says that the language ABI does not require libc;
- `docs/bootstrap.md` separates the freestanding core from host libc adapters;
- `docs/freestanding.md` describes `linux/raw` alongside `posix/libc`, WASI,
  and embedded target families; and
- `docs/standard-library.md` specifies raw Linux facilities that do not pull in
  libc's `syscall` wrapper.

The current LLVM path does not yet preserve that property in its final native
artifact. This is visible in a small real application: the Abla MVC HTTP server
can otherwise run in a minimal container, but its generated object still
requires allocation and memory symbols from libc, and the normal linker driver
adds the host dynamic loader and C runtime.

A libc-free target provides several useful properties:

- deployment in a `FROM scratch` container or minimal root filesystem;
- no accidental dependency on the build host's glibc version or Nix store;
- a smaller, easier-to-audit runtime boundary;
- a concrete validation of Abla's target/runtime abstraction; and
- a foundation for embedded and other freestanding environments.

## Reproduction

Build the current MVC application through the LLVM backend:

```sh
cd ../abla-mvc
make app
nm -u build/app.o
readelf -l build/app
readelf -d build/app
```

At the time of writing, `nm -u build/app.o` includes:

```text
free
malloc
memcpy
```

The linked executable has a glibc ELF interpreter, a `DT_NEEDED` entry for
`libc.so.6`, and host-specific runtime paths. Consequently, copying the binary
to a different Linux environment does not produce a self-contained Abla
program.

The direct allocation dependency comes from the LLVM runtime emitted by
`bootstrap/compiler/backend_llvm.ab`, which currently declares and calls
`malloc` and `free`. LLVM memory intrinsics may also lower to an external
`memcpy` or related symbol. Finally, invoking the ordinary host `clang` link
mode supplies libc, CRT objects, and the dynamic ELF interpreter.

## Goals

- Produce a native Linux executable that has no libc dependency.
- Keep the existing hosted/libc target available where useful.
- Make runtime capabilities explicit in target selection.
- Supply startup, termination, allocation, panic, and memory primitives without
  libc for the raw Linux target.
- Diagnose unsupported hosted imports instead of silently reintroducing libc.
- Make libc independence verifiable in automated tests.
- Preserve deterministic and reproducible output.

## Non-goals

- Removing C FFI or the hosted POSIX/libc target.
- Reimplementing the complete POSIX API.
- Treating a statically linked musl or glibc executable as libc-free.
- Making raw Linux binaries portable to non-Linux kernels.
- Requiring every target to use the same allocator or startup implementation.

## Proposed target model

Expose the runtime choice as an explicit target or profile. Exact spelling is
open, but examples include:

```sh
ablac build app.ab --target x86_64-linux-raw -o app
```

or:

```sh
ablac build app.ab --freestanding --no-libc -o app
```

The compiler should not infer libc-free output solely from the build host. A
target description should select:

- target triple and ABI;
- startup and linker policy;
- allocator and panic hooks;
- I/O and process facilities;
- supported native imports; and
- whether libc/C runtime symbols are allowed.

Selecting the raw Linux standard-library surface may select or require the raw
runtime profile, but the resolved choice should remain visible in build output
and cache keys.

## Required runtime work

### Process startup and exit

Provide a target-specific `_start` rather than depending on `crt1.o`. On
x86-64 Linux it should read the kernel-provided initial stack, construct the
Abla representation of arguments and environment if requested, call the Abla
entry function, and terminate through the raw `exit_group` system call.

Other architectures should provide their own startup implementation rather
than sharing architecture-specific assembly accidentally.

### Allocation and deallocation

Replace the unconditional `malloc` and `free` imports with target runtime
hooks. The raw Linux implementation may build an allocator over `mmap` and
`munmap`, or use another documented raw-system-call strategy.

The allocator contract must define:

- minimum alignment;
- zero-size allocation behavior;
- overflow and out-of-memory behavior;
- deallocation behavior;
- interaction with checkpoints and Abla allocation accounting; and
- concurrency expectations.

The present linked-list allocation metadata may remain above the target hook,
provided the hook itself is not implemented with libc.

### Memory primitives

The backend must prevent LLVM optimizations from creating an undeclared libc
dependency. At minimum, the raw target must internally provide or lower:

- `memcpy`;
- `memmove`;
- `memset`; and
- any comparison or length primitives emitted by later optimization passes.

Possible implementations are compiler-emitted loops, internal runtime
functions, or an explicitly linked compiler-runtime object. The important
contract is that the final raw artifact has no unresolved external memory
symbol. This must be checked after optimization and object generation, not
only at the source IR level.

### Panic and basic I/O

Panic output and termination must use raw Linux `write` and `exit_group`
operations, without stdio, `errno`, or libc's `syscall` wrapper. Standard I/O,
networking, clocks, and process facilities exposed by the raw Linux standard
library should follow the same rule.

Raw syscall wrappers should correctly model clobbers, negative errno returns,
partial I/O, and architecture-specific calling conventions.

## Linker driver

The raw target needs a separate native link recipe. It should use LLD or an
equivalent linker with no default C runtime or system libraries, conceptually:

```text
-nostdlib -static
```

The actual flags depend on whether the compiler invokes Clang or LLD directly.
The link must include only Abla objects and the selected target runtime.

The resulting ELF must have:

- an Abla-provided entry point;
- no `PT_INTERP` segment;
- no `DT_NEEDED` entry for libc or a dynamic loader;
- no unresolved libc/compiler-helper symbols; and
- no build-host runtime search path.

If compiler-generated arithmetic requires helper routines, those helpers must
come from a deliberate libc-free compiler runtime or be emitted internally.

## Capability and diagnostic rules

A program that selects the raw target but imports a hosted native function
should fail before linking with a targeted diagnostic. For example:

```text
target.native-import-unavailable: native import `fopen` requires the
posix/libc runtime and is unavailable for x86_64-linux-raw
```

The compiler should not silently fall back to a hosted target, and a raw target
must not become libc-linked simply because an optimization introduced a symbol.

Target selection, runtime objects, and allowed native symbols must participate
in incremental cache fingerprints.

## Acceptance criteria

For an executable compiled for the raw Linux target:

```sh
nm -u app
readelf -l app
readelf -d app
ldd app
```

must establish all of the following:

- no undefined symbols remain;
- no `INTERP` program header exists;
- no `NEEDED` dynamic entry exists;
- no RPATH or RUNPATH points at the build host; and
- `ldd` reports that the artifact is not dynamically linked.

The test suite should compile and run, at minimum:

1. a Hello World program;
2. argument and exit-code handling;
3. allocation, reallocation patterns, checkpoints, and deallocation;
4. strings and arrays large enough to exercise lowered memory operations;
5. panic output and termination;
6. file or pipe I/O through raw Linux APIs; and
7. the Abla MVC HTTP server, including a request with `?query=1`.

At least one integration test should run the generated executable in a
`FROM scratch` container or an equivalently empty root filesystem. CI should
also inspect the final ELF so a successful run on a machine with libc cannot
mask a regression.

## Suggested implementation stages

1. Introduce target/runtime metadata and a raw-target native-symbol allowlist.
2. Supply internal memory primitives and verify objects after LLVM lowering.
3. Add a raw Linux allocator and raw panic/write/exit facilities.
4. Add `_start` and the no-CRT/no-libc linker recipe for x86-64 Linux.
5. Add ELF inspection and runtime conformance tests to `make check`.
6. Extend the same target contract to other architectures and freestanding
   environments.

Each stage should keep the hosted target working. The raw target should only be
declared stable once all acceptance checks are enforced automatically.

## Deployment workaround versus project goal

Applications can currently be made portable by relinking their generated
object against static musl inside a container build. That is useful as a
temporary packaging technique, but it is not a solution to this RFC: the
result still contains libc and does not test Abla's freestanding runtime
boundary.

The requested outcome is an Abla-produced native artifact whose execution does
not require or embed libc at all.
