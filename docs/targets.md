# Target support

This matrix describes the checks present in this repository, not a promise that
all standard-library APIs work on every LLVM target. A cross-compiled object,
an emulator run of arithmetic fixtures, and a native application test are
separate levels of evidence. Conditional checks count only when their required
tools are installed. This page does not record a fresh run of those checks.

## Target selection

The compiler's built-in `--target` list is `x86_64-linux`, `aarch64-linux`,
`riscv64-linux`, `x86_64-macos`, `arm64-macos`, `x86_64-windows` and
`aarch64-windows` (hosted programs: the runtime and standard library over
`kernel32`; each is the target the Windows compiler selects for itself),
`x86_64-windows-freestanding` (a freestanding program: its own entry, no
runtime and no standard library), and `wasm32-wasi`. Before v0.2.80,
`x86_64-windows` was the freestanding target and the hosted one was
`x86_64-windows-hosted`, which `--target` still accepts as another name for
`x86_64-windows` ([migrating to v0.2.80](migrating-to-v0.2.80.md#11-x86_64-windows-is-the-hosted-windows-target)).
The names are defined by
`bootstrapSupportedTargets` and `bootstrapTargetDescriptor` in
[src/toolchain.ab](../src/toolchain.ab).
There is no built-in `arm64-linux` or Android alias. AArch64 Linux uses
the spelling `aarch64-linux`. The [platform support matrix](platforms.md)
records current CI coverage tiers and distinguishes source workflow artifacts
from the assets actually published in v0.2.79.

Other targets come from two mechanisms:

- Build programs register a descriptor with `defineTarget`. The
  [Wasm library](../stdlib/abla/wasm/build/entry.ab) registers `wasm32-module`;
  the [Android library](../stdlib/abla/android/build/entry.ab) registers
  `android-arm64`. The [iOS library](stdlib/ios-build.md) registers `ios-arm64`
  and `ios-arm64-simulator`. These names belong to that build program's target
  registry.
- `--target-triple` with `--object-format` requests generic object emission.
  `bootstrapRawObjectTargetDescriptor` accepts a nonempty triple and one of
  `elf`, `macho`, `coff`, or `wasm`. The installed LLVM must still implement the
  triple. This contract supplies no platform startup, hosted ABI, sysroot or
  executable linker. Formats and triple strings passing descriptor validation
  alone do not establish working platform support.

See [programmable builds](programmable-builds.md) for the build API and
[the toolchain reference](toolchain.md) for CLI options.

## WASI Preview 1 commands

Build a source with `fun main` using
`ablac build app.ab --target wasm32-wasi -o app.wasm`, then run
`wasmtime run app.wasm`. Put Wasmtime options, such as `--env NAME=value`,
before the module path and program arguments after it.

This target uses the `wasi_snapshot_preview1` ABI directly and needs no WASI
libc or SDK. The command receives arguments and environment variables from
the host. Standard input/output, standard error, exit status, wall and
monotonic clocks, and random bytes work through WASI. Browser and hostless
modules use `wasm32-module` and their existing export and host-import contracts.

To grant file access, run `wasmtime run --dir ./data::. app.wasm`. Abla
resolves relative paths through the preopen named `.` in the guest. The
portable `abla/fs` operations for reading, writing, appending, creating
directories and reading path metadata use that capability. Absolute paths
and `..` components are rejected, and the host checks links during
resolution. Creation permissions come from the host.

[test-wasm-wasi.sh](../tools/test-wasm-wasi.sh) exercises development and
release commands under Wasmtime when it is installed.

## Evidence matrix

“Release CI” below means the manually dispatched
[release workflow](../.github/workflows/release.yml). Its compiler matrix builds
and packages three native compilers; it does not run the entire `make test`
suite. The local-suite checks below are registered in the [Makefile](../Makefile).

| Target / selection | Evidenced level | Checks and limits |
| --- | --- | --- |
| Linux x86_64 — `x86_64-linux`, `x86_64-unknown-linux-gnu` | CI-built and released; native execution in CI and the local suite | Release matrix asset `ablac-x86_64-linux` on Ubuntu. “Build the tagged compiler from the prepared bootstrap”, “Rebuild with the tagged compiler's own code generator”, and “Verify the compiler self-rebuild” build the compiler repeatedly. “Exercise the packaged toolchain” builds and runs hello. [test-reproducible-elsewhere.sh](../tools/test-reproducible-elsewhere.sh) is also a Linux release gate. [test-ct.sh](../tools/test-ct.sh) reads the constant-time fixtures' disassembly for this target, in the release and the `--fast` build, following calls between functions ([constant-time.md](constant-time.md)). |
| macOS arm64 — `arm64-macos`, `arm64-apple-macosx11.0.0` | CI-built and released; native execution in CI | Release matrix asset `ablac-arm64-macos` on `macos-15`, with the same self-build and packaged-toolchain gates. “Exercise native macOS functionality” runs [test-macos-host.sh](../tools/test-macos-host.sh): native Mach-O, I/O, filesystem, networking, TLS and process checks. This is a selected host test, not the full Linux suite. |
| macOS x86_64 — `x86_64-macos`, `x86_64-apple-macosx11.0.0` | CI-built and released; native execution in CI | Release matrix asset `ablac-x86_64-macos` on `macos-15-intel`; the same native host and self-build gates as arm64. [test-math-no-libm.sh](../tools/test-math-no-libm.sh), another release gate, inspects both Mach-O targets on macOS. |
| iOS arm64 device — build-defined `ios-arm64`, `arm64-apple-ios17.0` | CI cross-compilation, archive assembly and XCFramework inspection | [test-ios-target.sh](../tools/test-ios-target.sh) checks SDK-free objects and `LC_BUILD_VERSION`; [test-ios-static-library.sh](../tools/test-ios-static-library.sh) checks the same-platform C adapter when SDKs are configured. The macOS [push CI](../.github/workflows/ci.yml) runs [test-ios-simulator.sh](../tools/test-ios-simulator.sh), which creates both archives and the XCFramework. No device executable link or physical-device execution; no released iOS compiler executable. |
| iOS arm64 Simulator — build-defined `ios-arm64-simulator`, `arm64-apple-ios17.0-simulator` | CI linking and selected runtime execution on Apple Silicon | The same macOS CI step links a C harness, runs exported Abla functions through `simctl`, and checks managed collection, target identity, interface/callback/resource paths and startup VM growth. [test-ios-availability.sh](../tools/test-ios-availability.sh) cross-checks runtime refusals and allowed compile-time host work for both triples. This does not establish physical-device memory limits or entitlement behavior. See [the iOS build API](stdlib/ios-build.md). |
| Linux arm64 — `aarch64-linux`, `aarch64-unknown-linux-gnu` | Cross-built libc-free programs; static compiler and selected runtime checks under qemu in CI | Jobs `libc-free-aarch64` and `static-compiler-aarch64` check module links and the emulated static compiler's builds, run mode and compile-time tiers. Release publishes the static AArch64 compiler, `ablac-static-aarch64-linux`, from v0.2.65. This is not a native AArch64 full-suite run. See [the platform evidence and gaps](platforms.md#linux-aarch64). [test-wide-integers.sh](../tools/test-wide-integers.sh) also runs selected fixtures under `qemu-aarch64` when available; [test-ct.sh](../tools/test-ct.sh) inspects constant-time disassembly. |
| Wasm32 without EH — build-defined `wasm32-module`, `wasm32-unknown-unknown` | CI cross-build determinism; local-suite runtime under Node | Release “Verify cross-target build determinism” runs [test-build-same-process.sh](../tools/test-build-same-process.sh), comparing development/release Wasm outputs without executing Wasm. [test-wasm-host.sh](../tools/test-wasm-host.sh) runs development and release modules under Node with `abla_host` imports; [test-wide-integers.sh](../tools/test-wide-integers.sh) runs arithmetic under Node. This does not establish general WASI or browser integration coverage. [test-ct.sh](../tools/test-ct.sh) reads the constant-time fixtures' disassembly for this target, in the release and the `--fast` build, following calls between functions ([constant-time.md](constant-time.md)). |
| Wasm32 with EH — same target, exception-enabled code paths | Local-suite runtime and section inspection | [test-stm-wasm-unwinding.sh](../tools/test-stm-wasm-unwinding.sh) runs development/release STM retry and `orElse` cases under Node or Bun, checks tags and imports, and verifies unrelated modules remain unchanged. It exercises **legacy `try/catch_all` EH**, not every Wasm EH encoding or engine. |
| Xtensa / ESP32 family, including the ESP32-S3 use case — raw `xtensa-esp-unknown-elf` | CI cross-compilation and assembly inspection; experimental backend; conditional emulator checks locally | Linux release “Verify the Xtensa LLVM” runs [test-llvm-xtensa.sh](../tools/test-llvm-xtensa.sh), using `-mcpu=esp32` and inspecting objects, intrinsics and assembly. [test-wide-integers.sh](../tools/test-wide-integers.sh) can run selected arithmetic with an ESP toolchain and `qemu-xtensa -cpu dc232b`; otherwise it reports compile-only coverage. Neither is an ESP32-S3 board run. [SIMD coverage](simd.md) describes S3 scalar fallback and compile-only vector checks. [test-ct.sh](../tools/test-ct.sh) reads the constant-time fixtures' disassembly for this target, in the release and the `--fast` build, following calls between functions ([constant-time.md](constant-time.md)). |
| Android arm64 — build-defined `android-arm64`, `aarch64-linux-android24` | Local-suite cross-compilation and integration-file inspection | [test-android-extension.sh](../tools/test-android-extension.sh) checks an AArch64 shared library, exports, reproducibility and generated JNI/Kotlin/Gradle files. [test-android-rpc-example.sh](../tools/test-android-rpc-example.sh) also executes the **host** RPC server. Neither runs an Android app, emulator or device; no Android compiler binary is released. [test-android-link.sh](../tools/test-android-link.sh) builds, with the NDK's API 24 sysroot (found through `ABLA_ANDROID_NDK`, `ANDROID_NDK_ROOT`/`ANDROID_NDK_HOME` or `ANDROID_HOME`/`ANDROID_SDK_ROOT`; skipped without one), scalar, thread-local and threaded libraries in release and debug builds and checks that none imports a symbol or names a needed library, and that a control importing `pthread_create` is rejected. These are link checks. A library that imports `abla/android/emutls` has its own `__emutls_get_address` on bionic's thread keys and the system call routine; the key functions, and `pthread_create` and `pthread_join` when it starts a thread, are not imports: the library calls them through the table the generated `libabla_jni.so` installs in `JNI_OnLoad` (`abla_android_host_install`, decision #121; [programmable builds](programmable-builds.md)). Decision #62 (André): the minimum stays API 24 and the pthread keys stay (no move to API 29 and its ELF TLS). One that does not import it takes the function from the NDK's compiler-rt builtins (same lookup, or `ABLA_ANDROID_BUILTINS`), which imports `malloc`, `free`, `realloc`, `abort` and the pthread calls from the NDK libc.so stub, kept as a dependency then. [test-android-run.sh](../tools/test-android-run.sh) executes a library: bionic's own linker from Google's arm64 Android 36 image (`tools/prepare-bionic-sysroot.sh`, `ABLA_BIONIC_ROOT`) on qemu-aarch64 loads it, and its exports (getrandom, heap, a thread, four allocating threads, eight foreign threads at once) run, with the table installed by the driver and by the generated `libabla_jni.so's` `JNI_OnLoad`; without the table an export ends the process with status 70 and a message; skipped without the sysroot, the NDK or qemu. |
| Linux RISC-V64 — `riscv64-linux` | Cross-built libc-free executables with LP64D on RV64GC CPUs | [test-riscv64-linux.sh](../tools/test-riscv64-linux.sh) checks static PIE, system calls, TLS, threads, collection and stack faults under `qemu-riscv64`. The `libc-free-riscv64` CI job also checks the Linux module programs. |
| RISC-V64 raw/build-defined — `riscv64-unknown-elf` or `riscv64-unknown-linux-gnu` | Local-suite object inspection and freestanding emulator execution | [test-target-descriptors.sh](../tools/test-target-descriptors.sh) checks raw ELF objects and exports. [test-wide-integers.sh](../tools/test-wide-integers.sh) supplies its own startup and runs arithmetic under `qemu-riscv64`, including a configuration without the M extension. |
| RISC-V32 — raw `riscv32-unknown-elf` | Local-suite object/helper inspection; conditional freestanding emulator execution | [test-wide-integers.sh](../tools/test-wide-integers.sh) builds objects, checks arithmetic helper dependencies and runs with its own startup under `qemu-riscv32` when installed, without the M extension. No hosted compiler release. |
| Windows x86_64 — `x86_64-windows` (hosted) and `x86_64-windows-freestanding`, `x86_64-pc-windows-msvc` | Cross-built on Linux; link lanes and Wine lanes in the local suite; the packaged host toolchain is exercised on `windows-latest` in release runs | **Freestanding** (`x86_64-windows-freestanding`): a program whose `abla_start` ends the process through `kernel32` (no runtime, no standard library, no C runtime) is linked by lld-link into a PE32+ console image, with import libraries the compiler writes from [runtime/windows/imports](../runtime/windows/imports) ([src/coff_import.ab](../src/coff_import.ab): no SDK). [test-windows-link.sh](../tools/test-windows-link.sh) checks that it is reproducible, that its imports are within [windows-imports-allowlist.txt](../tools/windows-imports-allowlist.txt) with no C runtime under any name, and runs it under Wine when Wine is installed. **Hosted** (`x86_64-windows`, formerly `x86_64-windows-hosted`, which is still accepted; it is the target the Windows compiler selects for itself): the Abla runtime and the standard library over `kernel32` and Winsock through `platform/windows`, with no C runtime. [test-windows-hosted.sh](../tools/test-windows-hosted.sh) cross-builds the programs in `tests/cases/windows/hosted` (hello, process arguments, environment, files, processes, loopback sockets, threads), checks their imports, and compares what they print under Wine with what the same program prints on Linux; [test-windows-syscalls.sh](../tools/test-windows-syscalls.sh) and [test-windows-crash.sh](../tools/test-windows-crash.sh) cover the compiler's own system calls and panic, access-violation, illegal-instruction and stack-overflow reports. On `windows-latest`, the `ci.yml` job `windows-run` runs the freestanding exit-status program and the hosted crash program (the access violation report, and the `--backtrace` stack symbolized to file and line). The same job also runs the hosted programs and the standard-library programs of `tests/cases/windows/programs.txt` on the runner and compares what they print with Linux. The statically linked compiler (the release one, and `ablac.exe`) links with lld's COFF driver in its own process, as it does ELF; [test-windows-arm64.sh](../tools/test-windows-arm64.sh) checks that its images are byte for byte the external `lld-link`'s, for x64 and ARM64. A compiler built without lld in it (the development `build/ablac`) runs the external `lld-link`. The Windows host toolchain is the release asset `abla-toolchain-x86_64-windows.zip` ([package-windows-toolchain.sh](../tools/package-windows-toolchain.sh)): `bin/ablac.exe` (lld in its own process, the C runtime linked statically, no DLL beyond Windows system ones), `bin/llvm-objcopy.exe` for `--backtrace`, and `share/abla`. The release's `windows-exercise` job unpacks it on `windows-latest` with only System32 on `PATH` and builds and runs programs (a hello world and one that imports a project module, with and without `--backtrace`, and the toolchain moved to another directory), including from a path with a space; [release-check.sh](../tools/release-check.sh) check 11 judges the layout. A Release run with `windows` set to `with` or `fixpoint` also compares two native self-builds of the Windows compiler (`windows-fixpoint`). The design is [design/windows-target.md](design/windows-target.md). |
| Windows ARM64 — `aarch64-windows`, `aarch64-pc-windows-msvc` | Hosted libc-free programs cross-built on Linux. Native compiler package from v0.2.69. | [test-windows-arm64.sh](../tools/test-windows-arm64.sh) checks the PE images, TLS, unwind and imports. The `windows-arm64-run` CI job executes the checked images on `windows-11-arm`. [Release](../.github/workflows/release.yml) cross-builds the compiler object on Linux, links against the pinned static ARM64 LLVM and lld SDK and packages `ablac-windows-arm64.zip`. The native smoke checks the packaged compiler with only System32 on `PATH`, including a two-module project, `--backtrace` and a relocated toolchain in a path with a space. |
| Other triples / formats, including COFF | Experimental generic emission contract only | [src/toolchain.ab](../src/toolchain.ab) accepts the raw descriptor formats listed above. [test-target-descriptors.sh](../tools/test-target-descriptors.sh) proves that mechanism for selected ELF targets; it is not evidence of Windows hosting, arbitrary CPU support, or runtime coverage for every LLVM backend. |

## Toolchain and runtime boundaries

Android arm64 shared libraries use 16 KiB ELF load-segment alignment. The
generated JNI adapter requests the same alignment from the NDK linker.
[The Android extension check](../tools/test-android-extension.sh) inspects
the ELF segments. [The bionic execution check](../tools/test-android-run.sh)
uses QEMU user mode with the host page size, so an Android device or system
image running a 16 KiB kernel is needed for the corresponding runtime check.
APK and App Bundle packaging also have their own alignment requirements.
[Android's 16 KiB compatibility guide](https://developer.android.com/guide/practices/page-sizes)
describes both checks.

Linux-to-macOS linking requires an extracted SDK in `ABLA_MACOS_SDK` and suitable
target libraries; [tools/build-macos-from-linux.sh](../tools/build-macos-from-linux.sh)
checks that prerequisite. Being able to emit a Mach-O object without linking is
not equivalent to having that SDK or being able to run the result on Linux.

Xtensa needs the patched LLVM described in [llvm-xtensa.md](llvm-xtensa.md).
The packaged toolchains and the patched LLVM of the macOS release
jobs do not supply that backend. Emulator arithmetic tests do not cover the
ESP32 startup, board peripherals, networking stack or a firmware application.
Those belong to the embedding framework and its own tests.

For freestanding targets, a framework must provide startup, runtime hooks and
link policy; see [freestanding.md](freestanding.md). For Wasm, the host must
provide the imports the module actually uses. Native libc, files, sockets and
threads are not implied by successful Wasm or freestanding code generation.
