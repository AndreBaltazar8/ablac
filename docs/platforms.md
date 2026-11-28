# Platform support and evidence

These tiers describe the checks wired into this source tree, not a stability
promise or a fresh green CI run. Read each row's scope: executing a compiler
under qemu, running a library on Simulator, and testing a physical device are
different evidence. Optional/manual jobs count only when actually run.

The published asset baseline is [v0.2.79](https://github.com/AndreBaltazar8/ablac/releases/tag/v0.2.79),
whose asset names are saved in [the release snapshot](readiness-data/release-assets-v0.2.79.json).
The workflows on master can prepare artifacts that this release did not ship.
Checksums accompany the published compiler and toolchain assets.

## Tier definitions

- **T1 — native host and full suite:** an installable native compiler release,
  native self-build checks, and the full suite distributed across required CI
  jobs. This does not mean every optional SDK or physical board is covered.
- **T2 — scoped runtime CI:** required CI executes selected compiler or runtime
  checks, either natively or under the stated emulator. Coverage stops at those
  checks; a released native host compiler is not implied.
- **T3 — cross-build or conditional integration:** object/link checks or
  optional integration jobs, without required execution on that device/host.
- **Planned:** no host/runtime acceptance gate or release artifact.

## Matrix

<!-- readiness-platforms:start -->
| Platform | Tier | Compiler host evidence | Program target evidence | Published v0.2.79 assets |
|---|---|---|---|---|
| Linux x86-64 | T1 | Native suite, dynamic self-build and static compiler fixpoint | Native executables; default libc-free link with explicit dependency exceptions | `ablac-x86_64-linux` (static), `ablac-dynamic-x86_64-linux`, `abla-toolchain-x86_64-linux.tar.gz`, `abla-toolchain-dynamic-x86_64-linux.tar.gz` |
| Linux AArch64 | T2 | Cross-built static compiler exercised under qemu in CI; native self-build and smoke on manual dispatch | Static programs cross-built and selected programs executed under qemu | `ablac-static-aarch64-linux` (since v0.2.65) |
| macOS arm64 | T2 | Native compiler, selected host checks and self-rebuild | Native Mach-O; selected runtime paths, iOS Simulator integration | `ablac-arm64-macos`, `abla-toolchain-arm64-macos.tar.gz` |
| macOS Intel | T2 | Native compiler and selected host checks; release self-rebuild | Native Mach-O; selected runtime paths | `ablac-x86_64-macos`, `abla-toolchain-x86_64-macos.tar.gz` |
| Android arm64 | T2 | No Android-hosted compiler gate | Shared libraries checked against NDK; exports executed by bionic under qemu | None for Android |
| iOS arm64 and Simulator | T2 Simulator / T3 device | No iOS-hosted compiler gate | Device archive/XCFramework checks; selected exported calls run on arm64 Simulator | None for iOS |
| WebAssembly hosted | T2 | No Wasm-hosted compiler gate | Release/development modules execute with the `abla_host` ABI under Node | `abla-playground-0.2.79.tar.gz` (the compiler front end as Wasm, [playground.md](playground.md)); no standalone Wasm compiler |
| WebAssembly hostless | T2 | No Wasm-hosted compiler gate | Import-free runtime fixtures and differential programs execute under Node | No standalone Wasm compiler asset; build support in host toolchains |
| Xtensa / ESP32 | T3 | No compiler hosted on the microcontroller | Object/assembly checks and optional companion integration; no required board run | No ablac ESP32 binary; separately versioned LLVM companion |
| Linux RISC-V 64 | T2 | Static compiler (pinned patched LLVM/lld) executed under qemu in CI: release and fast hello, in-process object emission; self-build fixed point under qemu on manual dispatch | Static LP64D programs; every module program that links static runs under qemu and matches x86-64 (335 of 336) | None; the RV64 compiler is not a release asset |
| Windows x86-64 | T2 | Packaged compiler smoke on `windows-latest` nightly and on dispatch; native fixed point required when the zip ships | Cross-built on Linux; the freestanding exit-status program, the hosted crash program with its symbolized backtrace, and selected hosted programs run natively on `windows-latest` in CI | `abla-toolchain-x86_64-windows.zip` (since v0.2.68) |
| Windows ARM64 | T2 | Packaged compiler smoke and native fixed point on `windows-11-arm` required when the zip ships | Hosted programs cross-built on Linux and run natively on `windows-11-arm` in CI | `ablac-windows-arm64.zip` (since v0.2.69) |
<!-- readiness-platforms:end -->

`tools/readiness.sh` reads this marked table directly. Update
the definitions and evidence together when promoting a tier.

## Linux x86-64

In [CI](../.github/workflows/ci.yml), job `linux`, named **Linux suite (shard
${{ matrix.shard }}/4)**, runs `make test` split into four shards after rebuilding
the compiler with its own backend. This includes the x86-64 module-program
libc-free guard. Job `static-compiler`, named **Static compiler (no loader, no
libc)**, builds the static compiler, checks no loader/no needed library, builds
and runs hello, and checks its static self-build fixed point through
[test-static-artifact.sh](../tools/test-static-artifact.sh).

In [Release](../.github/workflows/release.yml), job `compiler` has the
`ubuntu-24.04` / `ablac-x86_64-linux` matrix entry. Its steps include **Verify
the compiler rebuilds byte for byte elsewhere**, **Build and check the static
compiler**, and **Exercise the packaged toolchain**. The archive's portability
checks run on the documented older Linux distributions. The release workflow
does not substitute for the full push suite.

Gaps: the dynamic toolchain has host library requirements even when an emitted
program links no libc. Programs that explicitly bring C libraries still need
those libraries. Static compile-time library emulation has documented numeric
limits; inspect [the remaining math differences](../TODO.md#known-upstream-llvm-miscompiles).
The LLVM 23.1.x fdiv issue below also applies wherever an unpatched LLVM is used.
From v0.2.65 the static binary is the default asset, `ablac-x86_64-linux`, and
the dynamic one ships beside it as `ablac-dynamic-x86_64-linux`.

## Linux AArch64

[CI](../.github/workflows/ci.yml) job `libc-free-aarch64`, **Linux module
programs link no libc (AArch64)**, cross-builds module programs and compares
exceptions to the checked-in allowlist. Its program parity step runs the
selected images under QEMU.
Job `static-compiler-aarch64`, **Static compiler for AArch64 under qemu
(1/3 to 3/3)**, cross-builds the compiler and executes its program builds, `ablac run`, and
compile-time evaluation tiers under qemu (part 1). With `STATIC_AARCH64_MODULES=1`, it
also uses the emulated compiler to build the module corpus, a third per part; known emulator
exceptions are recorded separately. See
[test-static-compiler-aarch64.sh](../tools/test-static-compiler-aarch64.sh).

The current [Release](../.github/workflows/release.yml) `compiler` Linux entry
has **Build and check the static compiler for AArch64 Linux**, producing
`ablac-static-aarch64-linux`, published from v0.2.65.
The artifact check runs under qemu on an x86-64 builder; it skips the compiler
self-build fixpoint unless explicitly requested. There is no native AArch64
full-suite job. `--target aarch64-linux` is a built-in target in
[the compiler](../src/toolchain.ab).

The dispatch-only [AArch64 Linux native fixed point](../.github/workflows/aarch64-native-fixpoint.yml)
cross-builds a static seed with the pinned LLVM and lld archives, then runs
it on `ubuntu-24.04-arm`. With an empty `PATH`, the seed builds and runs
hello and rebuilds the compiler until stage 2 and stage 3 match byte for byte.
Stage 3 builds hello with `--fast` and builds the JWT fixture in release mode.
The JWT result must match the x86-64 compiler's AArch64 cross-build. This
exercises native compiler child processes and leaves Raspberry Pi hardware
and older-kernel compatibility outside the check's coverage.

### Linux program parity on AArch64 and RISC-V 64

The `libc-free-aarch64` and `libc-free-riscv64` CI jobs verify that 124
selected programs have the expected exit status and byte-identical stdout
on x86-64 and on their QEMU target. The jobs reuse the corresponding
module images from the link check and build the remaining cases with
`--fast`. Each execution starts in its own directory. All three kinds of
image must be ELF for the intended architecture, with neither `PT_INTERP`
nor `DT_NEEDED`. [Program list](../tests/cases/linux/programs.txt),
[comparison runner](../tools/test-linux-programs.sh),
[CI jobs](../.github/workflows/ci.yml).

The survey covered 128 distinct sources from the direct build/run pairs
in [tests/abla-tests.json](../tests/abla-tests.json) and the
[Windows program list](../tests/cases/windows/programs.txt). Four cases
need a different setup.

- `host-runtime.ab` reads `tests/cases/bootstrap/value.ab` relative to
  the repository root. All three images return 42 from that directory.
- `network-advanced.ab` used OpenSSL in the original survey and lacked cross-target libraries.
  It now uses pure TLS and cross-builds without shared libraries.
- `unsafe-boundary.ab` calls `dlsym`. The native image links a C library
  and the libc-free cross links have no definition for that symbol.
- `https-loopback.ab` starts its TLS server by executing
  `/proc/self/exe`. Both guest runs time out waiting for the server when
  QEMU user mode cannot re-execute the guest image.

Configured recipes such as the GC-stress map differential, process
environment, flat imports and retained LLVM text use their own harnesses.
The module link lane also includes build fixtures and expected compile
failures. Its cross-link exceptions are recorded separately.
[Module link allowlist](../tools/libc-free-programs-allowlist.txt).

#### Every module program under QEMU (#1208)

In the original survey, 349 of the 553 programs in `tests/cases/modules` built for x86-64 (the others were negative cases, which are expected compile
failures, and programs that need a manifest or flags: `nobuild` lines of the allowlist). Of those, 338 linked statically for AArch64 Linux
and RISC-V 64 Linux. The same two CI jobs run every statically linked module program under QEMU, next to its
x86-64 `--fast` build, and compare standard output and exit status ([tools/test-linux-parity.sh](../tools/test-linux-parity.sh), surveyed
by [tools/survey-linux-parity.sh](../tools/survey-linux-parity.sh); each native program is run twice, so a program whose own output
varies is named instead of failing the comparison). Result on the first full run, both targets alike: 335 programs print and exit exactly
what x86-64 does, 1 differs by design, 2 are not run here. The step builds 336 x86-64 references and runs 3 executions of each: 4 minutes on 4 CPUs
per target (user time 5.5 minutes).

The groups that keep a module program from matching, each one named in a list that may only shrink:

- Does not link static (`nobuild-a64` and `nobuild-rv64` in the
  [allowlist](../tools/libc-free-programs-allowlist.txt)): `bootstrap-llvm`, `conformance-ir-cache`, `lowered-ir-cache`,
  `native-function-address`, `stable-native-symbols` and `xtensa-interrupt-handler` import `src/` and so link libLLVM, which has no
  AArch64 or RISC-V 64 build in the pinned shell (the compiler itself is built on static archives instead, #806 step C);
  `import-alias-externs` and `unsafe-boundary` name C functions (`sin`, `dlsym`);
  `compile-time-recursion-deep` runs out of the x86-64 compiler's own stack when building.
- Differs by design ([blockers](../tools/linux-parity-blockers.tsv)): `proc-self-exe` prints the size of its own file, which differs
  by architecture.
- Not run here (`skip` in the blockers): `runtime-out-of-memory` needs the `ulimit -v` of `tools/test-runtime-memory.sh` (unlimited it
  takes memory until it is killed) and `run-built` needs the arguments, environment and standard input that `tools/test-run-built.sh` gives it.
- What the survey found: `tool-support` failed its `/proc/self/smaps` check on RISC-V 64 only. Under qemu-user the file is the
  emulator's own (7382 bytes there, 8802 natively, 10160 on AArch64) and the check wanted more than 8192; the program now creates its own
  64 mappings first, so the check no longer depends on the emulator. No program differed because of a missing system call, a kernel structure
  or a numeric difference.

The 22 programs outside `tests/cases/modules` that `tests/cases/linux/programs.txt` runs are as before. The other directories of
`tests/cases` are not programs to compare: they test the compiler (diagnostics, caches, compile-time evaluation, the editor service,
Android, Windows) through recipes in `tests/abla-tests.json` that name their own flags, inputs and expected output.

## Linux RISC-V 64

Everything on this target has run under QEMU user mode (`qemu-riscv64`, the version `shell.nix` pins); no RV64 hardware or hosted runner is
part of the CI. What is proven, and by what:

- **Programs.** `--target riscv64-linux` builds hosted, libc-free LP64D PIE executables (own startup, TLS, system-call translation, threads;
  [the runtime](../src/backend/llvm/riscv64.ab)). The `libc-free-riscv64` job
  ([CI](../.github/workflows/ci.yml)) links all 338 module programs that link static on any target, runs 124 selected programs
  and then every module program under QEMU and compares standard output and exit status with the x86-64 build: 335 of 336 match
  and 1 differs by design ([results and blockers](#every-module-program-under-qemu-1208)).
- **The compiler.** The same job builds the compiler itself as a static LP64D PIE
  ([tools/test-static-compiler-riscv64.sh](../tools/test-static-compiler-riscv64.sh)) from the pinned patched LLVM 23.1.3 and lld
  archives (`llvm-23.1.3-fdiv-1-riscv64-linux.tar.xz`, SHA-256 `5962b6786305393b5ad28900cc4dd0ad8644bc908751f5d53d88f2906e7ff999`,
  cross-built by [llvm-riscv64-static.yml](../.github/workflows/llvm-riscv64-static.yml), consumed by
  [nix/riscv64-static-native-deps.nix](../nix/riscv64-static-native-deps.nix)) and runs it under QEMU with an empty `PATH`: release and
  `--fast` hello, and in-process object emission.
- **The fixed point.** The dispatch-only [RV64 static compiler convergence](../.github/workflows/rv64-static-convergence.yml) builds stage 2 with that
  seed and stage 3 with stage 2, both under QEMU, and compares the bytes. Run 45588819403 (source `130b50ec2`, the compiler reporting 0.2.72): stage 2 took 5178 s
  and stage 3 5288 s on one hosted x86-64 runner each, and the two images are byte-identical (SHA-256
  `9b2f7bdafb5e86b24bc8cc0d5894403aa5584f060031f39d067063fcd69d9b84`). The earlier run 45302710345 (source `9d6d3b81c`) agreed the same
  way (`0afdf044237d644a84f3e11cf0205ef65a174ba4ff02f4a34ed71b9416caaf21`, 5176 s and 5126 s, 4.4 GB resident each). The job limit is
  240 minutes per stage, so the fixed point is not part of the per-commit CI.

What is not covered: a run on RISC-V hardware or a native runner (QEMU user mode emulates the Linux system-call interface, so kernel
differences, `riscv_hwprobe` on older kernels and real timing are unchecked), performance of the compiler or its programs, an installable
release (there is no `ablac-riscv64-linux` asset and no `setup-abla` support), and a fixed-point run for every commit.

## macOS arm64 and Intel

[CI](../.github/workflows/ci.yml) job `macos`, named **${{ matrix.name }}**,
has four entries, a `host` and a `live` lane on each of `macos-15` and
`macos-15-intel`: **macOS host tests (Apple Silicon)**, **macOS host and
compiler fixed point**, **macOS host and compiler fixed point (Intel)** and
**macOS live compiler tests (Intel)**. The host lanes run the native host
paths (foreign thread entry, stop-the-world GC, stack guards, emulated TLS),
the live lanes live reload, watch mode and REPL sessions, and one lane per
architecture the libSystem import guard. The Apple Silicon live lane also runs
the compiler fixed point and native child and **Link iOS slices and exercise
an exported C call on Simulator**. These are selected tests, not the Linux full
suite.

[Release](../.github/workflows/release.yml) job `compiler` has `macos-15` /
`ablac-arm64-macos` and `macos-15-intel` / `ablac-x86_64-macos` entries, native
self-build and host checks, and **Exercise the packaged toolchain**.

Known gaps: CI and release jobs install the pinned, patched LLVM
(`tools/install-macos-llvm.sh`), but a local build on Homebrew LLVM 23.1.x is
affected by the **fdiv miscompile**: `0.0 / (0.0 * x)` can become zero instead
of NaN in optimized code, without fast-math flags. The minimized case and
affected modes are in [TODO](../TODO.md#known-upstream-llvm-miscompiles). REPL session behavior is
tested, but interactive editor/PTY behavior has no Mac CI gate here. SDK and
libSystem dependencies remain; macOS is not a static Linux-style executable
environment. See [the runtime boundary](toolchain.md).

## Android

The [CI](../.github/workflows/ci.yml) `linux` job's **Fetch the checksum-pinned
Android NDK and bionic sysroot** step configures the dependencies used by the
suite. [test-android-link.sh](../tools/test-android-link.sh) checks NDK imports;
[test-android-run.sh](../tools/test-android-run.sh) loads a shared library with
the Android system image's bionic linker under qemu-aarch64 and executes
exports, heap, random and thread checks. This is runtime evidence, stronger
than merely generating JNI/Gradle files, and weaker than an app/device run.
[test-android-seccomp.sh](../tools/test-android-seccomp.sh) checks what qemu-user cannot: Android starts app processes under a seccomp
filter and ends one that makes a call outside it with SIGSYS. The test builds five libraries (scalar, threaded, rich release and debug
runtimes), finds every call of the library's AArch64 translator in its machine code with the constant x86-64 number passed, maps it through the
translator's table and handlers to the AArch64 calls it makes, and requires each to be allowed to an app by the bionic policy of
Android 8.0, 10, 12, 14 and 16 (API 26 to 36; the pinned files and how the policy is made are in
[tests/data/android-seccomp](../tests/data/android-seccomp/README.md); API 24 and 25 have no app filter). The 16 distinct calls found
(`clock_gettime close exit_group futex getpid gettid madvise mmap mremap munmap nanosleep openat process_vm_readv read sigaltstack write`)
are all allowed. Two call sites in the debug stack printer take their number from a stack slot reloaded after a loop and are listed in
[android-seccomp-unresolved.tsv](../tools/android-seccomp-unresolved.tsv). A control library that calls `setuid` must be rejected. This is
the policy as published in AOSP, not a run on a device: vendor kernels and the Zygote's own filter setup are not covered.
The manually dispatched `android-pointer-tags-control` job, **AArch64
tagged-pointer positive and negative controls**, is additional optional evidence.

There is no Android entry in Release's `compiler` matrix, no Android compiler
asset, and no required UI, lifecycle or physical-device gate. API 24 and the bionic
thread functions the generated JNI adapter hands the library (the library itself imports nothing) remain
deliberate integration constraints; see [target details](targets.md).

## iOS

The arm64 `macos` matrix entry in [CI](../.github/workflows/ci.yml) runs **Link
iOS slices and exercise an exported C call on Simulator** through
[test-ios-simulator.sh](../tools/test-ios-simulator.sh). It builds device and
Simulator archives/XCFramework slices, links a C harness, and runs selected
exported functions on Simulator. The suite also checks target descriptors and
availability refusals.

There is no iOS compiler-host release entry or published iOS asset. Device
archives do not establish signed device executable linking, entitlements,
App Store compatibility or physical-device runtime coverage. Simulator results
do not establish device memory limits. See [iOS build integration](stdlib/ios-build.md).

## WebAssembly

Both rows are covered through the `linux` suite job in
[CI](../.github/workflows/ci.yml), not a separate native compiler-host job.
Hosted [test-wasm-host.sh](../tools/test-wasm-host.sh) runs release/development
modules under Node with only the `abla_host` write, exit, clock and random
imports. Hostless [test-wasm-gc.sh](../tools/test-wasm-gc.sh) checks no runtime
imports, roots and collection; [the fuzzer suite](../tools/test-fuzz-abla.sh)
checks hostless capability refusals and differential execution with planted
disagreement controls. The [Release](../.github/workflows/release.yml)
`compiler` job's **Verify cross-target build determinism** checks Wasm build
determinism, which is not itself a runtime test.

There is no Wasm-hosted compiler asset, generic WASI compatibility promise,
browser test matrix, or OS-thread/file/socket support implied by a module
that executes under Node. Hostless modules cannot use facilities requiring host
imports. STM tests cover the documented legacy exception encoding, not all
engines or exception proposals. See [target details](targets.md).

## Xtensa / ESP32

The Linux entry of [Release](../.github/workflows/release.yml) job `compiler`
runs **Verify the Xtensa LLVM**; all three host entries run **Install the
Xtensa companion into the packaged toolchain and build for Xtensa**. They check
code generation, object/assembly properties and separately versioned companion
installation. The companion is not an ESP32-hosted Abla compiler.

[CI](../.github/workflows/ci.yml) also defines optional jobs
`xtensa-companion-install`, **Optional Xtensa installer (${{ matrix.runner }})**,
and `xtensa-companion-routing`, **Stock parent Xtensa routing
(${{ matrix.runner }})**, gated by workflow-dispatch inputs. Arithmetic emulator
checks in the suite are conditional on the SDK/emulator. There is no required
ESP32-S3 board, radio, peripheral, flashing or complete firmware runtime gate
in these workflows. See [companion installation and limits](llvm-xtensa.md).

## Windows

x86-64. [CI](../.github/workflows/ci.yml) job `windows-cross`, **Windows
programs, cross-built on Linux**, builds a freestanding program
(`x86_64-windows`) and the hosted crash program (`x86_64-windows-hosted`, the
runtime and standard library over `kernel32`), with and without `--backtrace`,
and runs [test-windows-link.sh](../tools/test-windows-link.sh). Job
`windows-run`, **Windows programs, run on Windows**, runs the images on
`windows-latest`: the exit status of the freestanding program, the hosted
crash program's access-violation report, its backtrace symbolized to file and
line, the seven hosted programs in `tests/cases/windows/hosted` (hello,
arguments, environment, files, processes, loopback sockets, threads; `--fast`
and release) and the 86 standard-library programs listed in
[programs.txt](../tests/cases/windows/programs.txt) (collections, text, date,
files, `homePath` (`USERPROFILE` where there is no `HOME`), process metrics (the runtime's system call 4008: working set, commit charge, the descriptor table's entries, the creation time; `tests/cases/windows/process-metrics.ab` is the module test without its `ulimit -n` shell), process exit, loopback HTTP and WebSocket, threads, ...). The Linux job
leaves each image with the output and exit status the same program has built
natively for Linux and their hashes;
[test-hosted.ps1](../tools/windows/test-hosted.ps1) compares what the runner's
Windows prints and returns. The local suite runs the same images under Wine:
[test-windows-hosted.sh](../tools/test-windows-hosted.sh) and
[test-windows-programs.sh](../tools/test-windows-programs.sh) compare what each
prints under Wine with the Linux run, and
[test-windows-crash.sh](../tools/test-windows-crash.sh),
[test-windows-syscalls.sh](../tools/test-windows-syscalls.sh) and
[test-windows-compiler.sh](../tools/test-windows-compiler.sh) cover the crash
reports, the system calls the compiler makes and the compiler's image against
a stub LLVM.

Starting a program on Windows is one `CreateProcessW` call (the runtime's system call 4001), with these rules, each tested by
[spawn-safety.ab](../tests/cases/windows/spawn-safety.ab): a name with no separator is looked for in the directory the running program was loaded from
(the compiler's toolchain lies beside it) and then in the directories `PATH` lists, never in the current directory, which `CreateProcessW`'s own search
tries between the two; a command line over 250,000 bytes is refused (E2BIG) before anything is written; and a batch file (`.bat` or `.cmd`) is not started
with an argument that has a quote, `%`, `^`, `&`, `|`, `<`, `>`, `(`, `)`, `!` or a line break (EINVAL), because `cmd.exe` splits its command line by rules
the argument quoting does not follow. Pass such an argument through a file or the environment instead, or start the program the batch file wraps.

[Windows x64 toolchain smoke](../.github/workflows/windows-x64-ci.yml) runs
nightly on master and can be started manually from the Actions run list.
It calls the same [Windows x64 toolchain workflow](../.github/workflows/windows-x64-toolchain.yml)
as [Release](../.github/workflows/release.yml). That workflow cross-builds
the compiler object, links `ablac.exe` against the static LLVM SDK, and builds
`abla-toolchain-x86_64-windows.zip` with
[package-windows-toolchain.sh](../tools/package-windows-toolchain.sh).
It checks the zip's checksum, then exercises the installed compiler on
`windows-latest` with only System32 on `PATH`. The smoke test builds and runs
hello and a program that imports a project module, checks `--backtrace`, and
repeats the checks after moving the toolchain to a path with a space.
Release runs the [native fixed point](bootstrap.md#windows-release-fixed-points)
for each shipped Windows zip. `windows: fixpoint` exercises it on demand.

ARM64. Job `windows-arm64-cross` cross-builds hosted programs and
`windows-arm64-run`, **Windows ARM64 program runtime**, runs the checked
images on `windows-11-arm`. The same standard-library programs as on x64 (`tests/cases/windows/programs.txt`,
`tools/test-windows-programs.sh <compiler> aarch64-windows`) are cross-built for ARM64 there: all 81 build, with the import allowlist and no C
runtime checked, and the runner runs them with `tools/windows/test-hosted.ps1`: all pass there (CI run 45560269126) and a program that
differs fails the job (Wine has no ARM64, so nothing runs the list before CI). `https-loopback` had failed on ARM64 because the CPU probe
read `ID_AA64ISAR0_EL1`, which Windows refuses; Windows targets now take the fixed answer Apple's do (AES and PMULL present).

The release workflow includes `ablac-windows-arm64.zip` from v0.2.69
alongside the x86-64 zip introduced in v0.2.68. `windows_arm64: with`
(the default) builds and checks the ARM64 zip before publication.
`windows_arm64: only` exercises that toolchain by itself. Its Linux job
emits ARM64 COFF and the native Windows job links LLVM, lld and the static
MSVC runtime into `ablac.exe`. The package includes `llvm-objcopy.exe`
for split debug information. The smoke builds and runs a hello world, a
two-module project and a `--backtrace` build on `windows-11-arm`, with
only System32 on `PATH` and from a moved toolchain in a path with a space.
The release check validates the zip layout, size, version and console PE
architecture and rejects a compiler with C runtime DLL imports.

The ARM64 compiler still needs a full standard-library suite. The release
compiler runs the COFF linker in process. Development
compilers built without lld invoke the external `lld-link`. Of the
standard library's test programs (`tests/abla-tests.json`), those in
`programs.txt` run on Windows; the rest of the survey is blocked by:
signals (`signal-watch.ab` needs `signalfd`: the runtime answers `rt_sigprocmask`
with an empty mask, and Windows has no POSIX signals to watch);
tests that fork, as they are (`dns-async.ab`, `http-async.ab`, `websocket-server.ab` and `websocket-server-protocol.ab` have thread-based
copies in `tests/cases/windows`); tests that run POSIX tools
(`printf`, `sh` in `process-capture.ab`, `host-process-configured.ab`,
`inferred-command`); POSIX path semantics (`path-syntax`: `Path` follows
the host, see `module-path-identity`); and tests whose success depends on arguments, the environment or files a
driver script sets up (`fs-tree`, `process-environment`, `path-file-mode`,
`path-directory-mode`). `filesystem.ab` is in `programs.txt` for the Windows runner only: its symbolic link
(`CreateSymbolicLinkW`) is one Wine reports made and does not make. `udp-ephemeral.ab` runs under Wine too
(`SO_REUSEADDR` on a UDP socket now reaches Windows, which shares the port as Linux does), and `linux-net.ab` (a send with
`MSG_DONTWAIT` does not block, and a non-blocking one offers at most 64 KiB, so its deadline sees a partial write). The rest of the compiler's own tests (`tests/cases`
programs driven by shell scripts) build and run on Linux only.

Sockets and TLS on a hosted Windows program: the poller (`epoll_create1`, `epoll_ctl`, `epoll_wait`) is emulated over `WSAPoll`
(level triggered, at most 4096 sockets per poller), `sendmsg` sends its vector with one `send` per piece, and an address that does
not fit the caller's room is cut as on Linux. The pure TLS 1.3 client and server (`abla/tls/pure`, the HTTPS client built on it) need
no OpenSSL; their random bytes are `ProcessPrng`, and the default trust store is the user's ROOT certificate store (crypt32, minus every certificate of the Disallowed store and every root whose enhanced key usage property does not allow server authentication, as Windows' own chain building treats them; `tools/test-windows-system-roots.sh` checks it under Wine; the
runtime's system call 4006, loaded from System32 on first use, so a program without TLS does not import it; an error there leaves the store empty and nothing verifies) where Linux reads a CA bundle file; `SSL_CERT_FILE` and `SSL_CERT_DIR` still replace it. Known limitation: Windows keeps most public roots in its AuthRoot store and copies one into ROOT when a certificate chain first needs it, so a machine that has not yet done that (a fresh or offline one) has a ROOT store without them and fails closed with "unknown authority" for those sites; point `SSL_CERT_FILE` at a CA bundle there.
`tests/cases/windows/https-loopback.ab` runs a handshake between a program and its own child over loopback. The DNS resolver's defaults have Windows sources too: the name servers and primary suffix come from iphlpapi's `GetNetworkParams` (the
runtime's system call 4007, loaded from System32 on first use; IPv4 servers only, as on Linux) where Linux reads `/etc/resolv.conf`, and the
hosts file is the one under `%SystemRoot%\System32\drivers\etc` (`dnsConfigurationText`, `dnsHostsText`); an explicit path or name server
in the options is used as given. `tests/cases/windows/dns-default.ab` checks both. Accepting `coff` in a generic target descriptor proves
neither a working Windows linker/runtime nor Windows hosting. See
[the Windows design](design/windows-target.md); the options for a compiler without the static C runtime are in [design/windows-crt-free-compiler.md](design/windows-crt-free-compiler.md).
