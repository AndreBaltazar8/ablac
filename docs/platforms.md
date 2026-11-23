# Platform support and evidence

These tiers describe the checks wired into this source tree, not a stability
promise or a fresh green CI run. Read each row's scope: executing a compiler
under qemu, running a library on Simulator, and testing a physical device are
different evidence. Optional/manual jobs count only when actually run.

The published asset baseline is [v0.2.64](https://github.com/AndreBaltazar8/ablac/releases/tag/v0.2.64),
whose asset names are saved in [the release snapshot](readiness-data/release-assets-v0.2.64.json).
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
| Platform | Tier | Compiler host evidence | Program target evidence | Published v0.2.64 assets |
|---|---|---|---|---|
| Linux x86-64 | T1 | Native suite, dynamic self-build and static compiler fixpoint | Native executables; default libc-free link with explicit dependency exceptions | `ablac-x86_64-linux`, `ablac-static-x86_64-linux`, `abla-toolchain-x86_64-linux.tar.gz` |
| Linux AArch64 | T2 | Cross-built static compiler executed under qemu; no native host full-suite gate | Static programs cross-built and selected programs executed under qemu | None; AArch64 static compiler not a v0.2.64 asset |
| macOS arm64 | T2 | Native compiler, selected host checks and self-rebuild | Native Mach-O; selected runtime paths, iOS Simulator integration | `ablac-arm64-macos`, `abla-toolchain-arm64-macos.tar.gz` |
| macOS Intel | T2 | Native compiler and selected host checks; release self-rebuild | Native Mach-O; selected runtime paths | `ablac-x86_64-macos`, `abla-toolchain-x86_64-macos.tar.gz` |
| Android arm64 | T2 | No Android-hosted compiler gate | Shared libraries checked against NDK; exports executed by bionic under qemu | None for Android |
| iOS arm64 and Simulator | T2 Simulator / T3 device | No iOS-hosted compiler gate | Device archive/XCFramework checks; selected exported calls run on arm64 Simulator | None for iOS |
| WebAssembly hosted | T2 | No Wasm-hosted compiler gate | Release/development modules execute with the `abla_host` ABI under Node | No standalone Wasm compiler asset; build support in host toolchains |
| WebAssembly hostless | T2 | No Wasm-hosted compiler gate | Import-free runtime fixtures and differential programs execute under Node | No standalone Wasm compiler asset; build support in host toolchains |
| Xtensa / ESP32 | T3 | No compiler hosted on the microcontroller | Object/assembly checks and optional companion integration; no required board run | No ablac ESP32 binary; separately versioned LLVM companion |
| Windows x86-64 | T2 | The packaged `ablac.exe` is exercised on `windows-latest` in release runs (`windows: with` or `only`), not in push CI; no Windows self-rebuild or suite shard yet | Cross-built on Linux; selected programs run natively on `windows-latest` in CI (the freestanding exit-status program and the hosted crash program with its symbolized backtrace); the hosted file, process, socket and thread programs run under Wine on Linux only | None in v0.2.64; `abla-toolchain-x86_64-windows.zip` is built by the release workflow and not yet published |
| Windows ARM64 | T2 | No Windows-hosted compiler | Hosted programs cross-built on Linux and run natively on `windows-11-arm` in CI | None for Windows ARM64 |
<!-- readiness-platforms:end -->

`tools/readiness.sh` reads this marked table directly. Update
the definitions and evidence together when promoting a tier.

## Linux x86-64

In [CI](../.github/workflows/ci.yml), job `linux`, named **Linux suite (shard
${{ matrix.shard }}/2)**, runs `make test` split into two shards after rebuilding
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
The source release workflow now promotes the static binary to the default asset
and retains a dynamic binary under a new name; that future naming is not the
v0.2.64 asset inventory above.

## Linux AArch64

[CI](../.github/workflows/ci.yml) job `libc-free-aarch64`, **Linux module
programs link no libc (AArch64)**, cross-builds module programs and compares
exceptions to the checked-in allowlist. This job alone is link evidence.
Job `static-compiler-aarch64`, **Static compiler for AArch64 under qemu**,
cross-builds the compiler and executes its program builds, `ablac run`, and
compile-time evaluation tiers under qemu. With `STATIC_AARCH64_MODULES=1`, it
also uses the emulated compiler to build the module corpus; known emulator
exceptions are recorded separately. See
[test-static-compiler-aarch64.sh](../tools/test-static-compiler-aarch64.sh).

The current [Release](../.github/workflows/release.yml) `compiler` Linux entry
has **Build and check the static compiler for AArch64 Linux**, producing
`ablac-static-aarch64-linux`. It is absent from the v0.2.64 published snapshot.
The artifact check runs under qemu on an x86-64 builder; it skips the compiler
self-build fixpoint unless explicitly requested. There is no native AArch64
full-suite job, no published v0.2.64 AArch64 toolchain archive, and no basis for
calling this the same host coverage as x86-64. `--target aarch64-linux` is now
a built-in target in [the compiler](../src/toolchain.ab).

## macOS arm64 and Intel

[CI](../.github/workflows/ci.yml) job `macos`, named **${{ matrix.name }}**,
contains **macOS host and compiler fixed point** on `macos-15` (`full: true`)
and **macOS host and compiler fixed point (Intel)** on `macos-15-intel`
(`full: false`). Both run **Exercise the native macOS host paths**, foreign
thread entry, stop-the-world GC, stack guards, emulated TLS, live reload,
watch mode, REPL sessions, and the libSystem import guard. Only the arm64
`full` entry runs **Check the compiler fixed point and native child** and
**Link iOS slices and exercise an exported C call on Simulator**. These are
selected tests; `full: true` here does not mean the Linux full suite.

[Release](../.github/workflows/release.yml) job `compiler` has `macos-15` /
`ablac-arm64-macos` and `macos-15-intel` / `ablac-x86_64-macos` entries, native
self-build and host checks, and **Exercise the packaged toolchain**.

Known gaps: Homebrew LLVM 23.1.x is affected by the **fdiv miscompile**:
`0.0 / (0.0 * x)` can become zero instead of NaN in optimized code, without
fast-math flags. The minimized case and affected modes are in
[TODO](../TODO.md#known-upstream-llvm-miscompiles); a patch file in the repository
does not prove the installed Homebrew LLVM has it. REPL session behavior is
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
The manually dispatched `android-pointer-tags-control` job, **AArch64
tagged-pointer positive and negative controls**, is additional optional evidence.

There is no Android entry in Release's `compiler` matrix, no Android compiler
asset, and no required UI, lifecycle or physical-device gate. API 24 and bionic
imports remain deliberate integration constraints; see [target details](targets.md).

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
and release) and the 63 standard-library programs listed in
[programs.txt](../tests/cases/windows/programs.txt) (collections, text, date,
files, process exit, loopback HTTP and WebSocket, threads, ...). The Linux job
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

In [Release](../.github/workflows/release.yml), the `windows` input selects the
Windows toolchain jobs: `windows-object`, `windows-link`, `windows-package`
(`abla-toolchain-x86_64-windows.zip`, see
[package-windows-toolchain.sh](../tools/package-windows-toolchain.sh)) and
`windows-exercise`, which unpacks the zip on `windows-latest` with only
System32 on `PATH` and builds and runs a hello world and a program that imports
a project module, with `--backtrace`, from a moved toolchain and from a path
with a space. `windows: fixpoint` adds `windows-fixpoint`, the compiler's
self-build on a Windows runner. [Windows compiler link](../.github/workflows/windows-compiler-link.yml)
links the Windows compiler against its static LLVM SDK.

ARM64. Job `windows-arm64-cross` cross-builds hosted programs and
`windows-arm64-run`, **Windows ARM64 program runtime**, runs the checked
images on `windows-11-arm`.

Gaps: no published Windows asset yet (the zip is prepared by the release
workflow, after the v0.2.64 baseline); the Windows compiler is exercised in
release runs, not in push CI; the Linux cross-builds link with the external
`lld-link`, not the in-process one of the packaged toolchain. Of the
standard library's test programs (`tests/abla-tests.json`), those in
`programs.txt` run on Windows; the rest of the survey is blocked by:
Linux system calls the Windows runtime does not translate (`symlink` in
`filesystem.ab`, `sendmsg` in `linux-net.ab`, `getrusage` in
`process-metrics.ab`, `rt_sigprocmask` in `signal-watch.ab`,
`epoll_create1` in the WebSocket server tests, `geteuid` in
`path-home`, and raw `linuxSyscall` calls in `udp-ephemeral.ab`);
no TLS on a hosted Windows program (`network-advanced.ab` fails to link
`OpenSSL_version_num`; the TLS tests need an OpenSSL); tests that run POSIX tools
(`printf`, `sh` in `process-capture.ab`, `host-process-configured.ab`,
`inferred-command`); POSIX path semantics (`path-syntax`: `Path` follows
the host, see `module-path-identity`); IPv6 loopback and the socket poller
(`hosted-network.ab` fails under Wine and is unchecked on a runner);
the asynchronous resolver and HTTP client (`dns-async.ab`, `http-async.ab` exit 1
under Wine, cause not yet diagnosed);
and tests whose success depends on arguments, the environment or files a
driver script sets up (`fs-tree`, `process-environment`, `path-file-mode`,
`path-directory-mode`). The rest of the compiler's own tests (`tests/cases`
programs driven by shell scripts) build and run on Linux only. Accepting `coff` in a generic target descriptor proves
neither a working Windows linker/runtime nor Windows hosting. See
[the Windows design](design/windows-target.md).
