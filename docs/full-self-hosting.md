# Full self-hosting without C or libc

This is the authoritative route from the current compiler to a freestanding
Abla toolchain. The master queue is in [status.md](status.md); this document
defines the self-hosting boundary, architecture, stages, and proof required to
remove C, libc, and eventually external native-toolchain programs.

## What “done” means

These are separate properties and must not be conflated:

| Property | Current evidence | State |
| --- | --- | --- |
| Compiler sources are Abla | `bootstrap/compiler/orc_main.ab` and imports | yes |
| An Abla-built compiler reproduces compiler LLVM IR | `tools/test-pure-self-rebuild.sh` on the last promoted compiler | previously proven; current worktree must be re-proven |
| Compiler avoids the project C runtime | no `ablaHost`, `abla_host_*`, or `abla_platform_*` symbols | yes for the promoted native compiler |
| Raw user programs avoid libc | `tools/test-libc-free-target.sh` | yes for `x86_64-linux-raw` |
| Compiler executable avoids libc | `ldd build/ablac.bin` shows libc and `libLLVM` | no |
| A build needs no C/C++ compiler or native linker | toolchain invokes LLVM/Clang/LLD paths | no |
| A clean seed reaches fixed point without compiling C/C++ | `make all` still builds the C++ seed | no |

The final gate is stronger than source self-hosting:

> A reviewed seed executable compiles the pure-Abla compiler. That compiler
> compiles itself to a deterministic, static executable using only Abla code
> and target syscalls. The second compiler repeats the result without loading
> libc/libLLVM or executing a C/C++ compiler, assembler, or external linker.

A seed artifact is unavoidable: no compiler can build its own source from an
empty machine without some already executable translator. The seed may be a
reviewed binary. It must not make C or C++ part of the normal build or trusted
production source closure. Diverse bootstrap routes can audit the seed.

## Final architecture

```text
reviewed seed ablac
        |
        v
pure-Abla frontend -> typed IR -> verifier -> optimizer
                                      |
                    +-----------------+-----------------+
                    |                                   |
                    v                                   v
       baseline Abla native backend          optional LLVM adapter
       object/ELF/JIT, always present         hosted accelerator only
                    |
                    v
       Abla startup + runtime + stdlib
                    |
                    v
         target ABI / direct syscalls
```

The baseline backend is the self-hosting root. LLVM remains valuable for high
optimization and ORC workflows, but `libLLVM` is C++ and transitively loads
libc. Therefore the LLVM adapter cannot be required by the freestanding
compiler or used as evidence for the final no-C/no-libc claim.

The first baseline target is `x86_64-linux-raw`. Portability remains at the
public `abla/io`, `abla/fs`, `abla/process`, and `abla/net` interfaces; only the
target implementation and code emitter are Linux/x86-64-specific.

## Implementation stages

### 0. Restore the current compiler to green

- Fix the undefined indirect-dispatch label recorded in `status.md`.
- Preserve stable linkage names while hashing complete extracted LLVM for
  object-cache validity.
- Re-run captures, address-taken functions, incremental reuse, final native
  conformance, and fixed-point tests before promoting another compiler.

This is required before changing the bootstrap boundary; otherwise backend
failures and freestanding failures become indistinguishable.

### 1. Seal the pure-source fixed point

- Define one production entry graph with no import of `backend_c.ab`.
- Require seed -> stage 1 -> stage 2 compiler builds through public `ablac
  build`, with identical normalized IR and deterministic outputs.
- Record source graph, target, profile, compiler identity, and all compile-time
  inputs in a reproducible manifest.
- Keep the C emitter only as a differential oracle outside the production
  import graph.

Exit gate: `tools/test-pure-self-rebuild.sh` passes from a clean workspace
under the 4 GiB watchdog, and a graph audit finds no production C backend or
project C runtime import.

### 2. Split the compiler core from hosted LLVM

Create two explicit entry graphs:

- `ablac-core`: frontend, compile-time evaluator, IR/verifiers, packages,
  baseline backend, raw platform, and CLI;
- `ablac-llvm`: optional package adding LLVM AOT optimization and ORC JIT.

The core must not import `abla/llvm/aot`, `abla/llvm/orc`, host adapters, or
`extern:"c"` declarations. `build`, interpreter-backed `run`, package loading,
diagnostics, and cache management must work in the core before LLVM is loaded.

Exit gate: the core compiler links and runs when `libLLVM`, `clang`, `llc`,
`opt`, `llvm-extract`, and C runtime objects are unavailable.

### 3. Implement the baseline native backend in Abla

Build it behind a target interface rather than embedding x86 rules in the
frontend:

- lower typed IR to a small machine-independent low IR;
- select x86-64 instructions and SysV/raw-start calling conventions;
- implement deterministic block layout, branches, calls, stack frames, and
  closure environments;
- add liveness and a simple linear-scan allocator, spilling when necessary;
- emit relocations, symbols, sections, unwind policy, and deterministic ELF64
  relocatable objects;
- add an Abla static linker, or initially emit one whole-program static ELF
  directly to avoid needing an external linker;
- retain LLVM IR emission as an optional backend and differential oracle.

Correctness comes before aggressive optimization. A whole-program static ELF
writer is the shortest route to self-hosting; `.o` archives and shared-library
support can follow without holding up the no-linker gate.

Exit gate: `ablac-core build` creates and executes representative compiler,
closure, collection, subparser, file, process, and HTTP programs with no LLVM
library or external object/link tools.

### 4. Remove assembly and CRT build dependencies

The current raw path compiles `runtime/abla_linux_raw_x86_64.S` with Clang.
Replace it with backend-emitted startup code:

- emit `_start`, decode `argc`/`argv`/`envp`, call Abla `main`, and issue
  `exit_group`;
- lower syscall intrinsics directly to `syscall` with verified registers and
  clobbers;
- emit memory copy/set and any compiler builtins directly or as ordinary Abla;
- provide mmap allocation, panic, clocks, signals, and process primitives in
  target Abla modules;
- make native methods either compiler intrinsics or imported Abla functions,
  never implicit C shims.

Exit gate: the source/build closure for the compiler and a normal raw program
contains no `.c`, `.cc`, `.cpp`, `.S`, CRT object, libc, or dynamic loader.

### 5. Make all compiler I/O pure Abla

- Finish typed `Result<T, Errno>` wrappers for filesystem, pipes, processes,
  polling, sockets, signals, environment, clocks, and atomic rename.
- Route the compiler through portable interfaces backed by
  `abla/sys/linux/*`; do not expose raw syscall details to compiler logic.
- Preserve transactional outputs and compile-time capability/input journals.
- Replace any remaining host-created string/array bridge with Abla-owned data.

Exit gate: module loading, diagnostics, packages, cache reads/writes, process
supervision, and HTTP serving pass with the host adapter absent.

### 6. Preserve every execution mode without LLVM

- `build`: baseline backend emits a static executable directly.
- `run`: first use the shared verified IR interpreter; then optionally add a
  baseline in-memory code emitter using mmap plus explicit relocations.
- `repl`: retain typed declarations and evaluator state; machine-code JIT is
  an optimization, not a semantic requirement.
- `serve`: supervise baseline-built workers, validate generations before swap,
  and preserve the last good generation on failure.
- `--backend llvm`: opt-in hosted acceleration with identical semantics and
  differential tests against the baseline backend.

Exit gate: all four commands work with LLVM hidden from the environment;
interpreter, baseline native, and LLVM results agree on the parity corpus.

### 7. Establish the distributable seed and trust policy

- Publish a small, versioned seed compiler binary plus its source hash, target,
  build manifest, and cryptographic digest.
- Make stage 1 and stage 2 deterministic: no timestamps, random identifiers,
  absolute build paths, ambient environment reads, or unstable iteration.
- Reproduce the seed successor through at least two routes: the previous Abla
  release and the retained compatibility bootstrap.
- Document diverse double compilation for detecting a compromised seed.
- Keep legacy C/C++ sources available for archaeology/auditing, but exclude
  them from default builds, releases, and production tests.

Exit gate: a clean machine with the seed and Abla sources—but no C/C++
compiler, libc development files, LLVM, assembler, or linker—reaches the same
stage-2 compiler digest.

## Dependency policy

The freestanding release closure may contain:

- Abla source and data files;
- one reviewed seed executable for the first build;
- kernel interfaces supplied by the target;
- deterministic package sources and lockfile.

It must not contain or execute:

- generated or handwritten C/C++ production code;
- libc, CRT startup, a dynamic ELF interpreter, or project C runtime objects;
- `libLLVM`, LLVM command-line programs, Clang, GCC, an assembler, or LLD;
- ambient compile-time network/process effects not declared by capabilities.

The optional LLVM distribution is allowed to depend on LLVM and the hosted
system ABI, but it must be branded and tested as an adapter, never as the only
working compiler.

## Proof suite to add

`tools/test-full-self-host.sh` should be the final umbrella gate. It must:

1. expose only the reviewed seed and pure-Abla sources;
2. build stage 1 with `ablac-core` and stage 2 with stage 1;
3. compare deterministic stage outputs and manifests;
4. use `readelf` to reject `INTERP` and `NEEDED` entries;
5. require `nm -u` to be empty and reject project/host/LLVM symbols;
6. record child processes and reject LLVM, C/C++, assembler, and linker tools;
7. build and run the compiler probe, standard-library probe, subparser probe,
   package/offline probe, and HTTP server probe;
8. run everything behind the 4 GiB/time watchdog;
9. repeat from a clean output/cache directory.

Existing gates remain necessary but are not sufficient individually:

```sh
tools/test-pure-self-rebuild.sh build/ablac.bin
tools/test-libc-free-target.sh build/ablac.bin
tools/test-final-native-conformance.sh build/ablac.bin
```

The full self-host goal is complete only when the umbrella gate passes and the
baseline compiler can be used for continued language and standard-library
development without returning to C, libc, LLVM, or the bootstrap compiler.
