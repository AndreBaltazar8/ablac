# Target support

This matrix describes the checks present in this repository, not a promise that
all standard-library APIs work on every LLVM target. A cross-compiled object,
an emulator run of arithmetic fixtures, and a native application test are
separate levels of evidence. Conditional checks count only when their required
tools are installed. This page does not record a fresh run of those checks.

## Target selection

The compiler's built-in `--target` list is exactly `x86_64-linux`,
`x86_64-macos`, and `arm64-macos`; see `bootstrapSupportedTargets` and
`bootstrapTargetDescriptor` in [src/toolchain.ab](../src/toolchain.ab).
There is no built-in `arm64-linux`, Android, or Wasm alias.

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
| iOS arm64 Simulator — build-defined `ios-arm64-simulator`, `arm64-apple-ios17.0-simulator` | CI linking and selected runtime execution on Apple Silicon | The same macOS CI step links a C harness, runs exported Abla functions through `simctl`, and checks managed collection, target identity, interface/callback/resource paths and startup VM growth. [test-ios-availability.py](../tools/test-ios-availability.py) cross-checks runtime refusals and allowed compile-time host work for both triples. This does not establish physical-device memory limits or entitlement behavior. See [the iOS build API](stdlib/ios-build.md). |
| Linux arm64 — raw or build-defined `aarch64-unknown-linux-gnu` | Cross-compiled; conditional emulator execution of selected freestanding fixtures in the local suite | [test-wide-integers.sh](../tools/test-wide-integers.sh) builds an object using [build-objects.ab](../tests/cases/wide-integers/build-objects.ab), links its own startup and C stubs, and runs under `qemu-aarch64` when available. There is no released Linux arm64 compiler or built-in hosted executable target; the fixture explicitly does not test a normal hosted application. [test-ct.sh](../tools/test-ct.sh) reads the constant-time fixtures' disassembly for this target, in the release and the `--fast` build, following calls between functions ([constant-time.md](constant-time.md)). |
| Wasm32 without EH — build-defined `wasm32-module`, `wasm32-unknown-unknown` | CI cross-build determinism; local-suite runtime under Node | Release “Verify cross-target build determinism” runs [test-build-same-process.sh](../tools/test-build-same-process.sh), comparing development/release Wasm outputs without executing Wasm. [test-wasm-host.sh](../tools/test-wasm-host.sh) runs development and release modules under Node with `abla_host` imports; [test-wide-integers.sh](../tools/test-wide-integers.sh) runs arithmetic under Node. This does not establish general WASI or browser integration coverage. |
| Wasm32 with EH — same target, exception-enabled code paths | Local-suite runtime and section inspection | [test-stm-wasm-unwinding.sh](../tools/test-stm-wasm-unwinding.sh) runs development/release STM retry and `orElse` cases under Node or Bun, checks tags and imports, and verifies unrelated modules remain unchanged. It exercises **legacy `try/catch_all` EH**, not every Wasm EH encoding or engine. |
| Xtensa / ESP32 family, including the ESP32-S3 use case — raw `xtensa-esp-unknown-elf` | CI cross-compilation and assembly inspection; experimental backend; conditional emulator checks locally | Linux release “Verify the Xtensa LLVM” runs [test-llvm-xtensa.sh](../tools/test-llvm-xtensa.sh), using `-mcpu=esp32` and inspecting objects, intrinsics and assembly. [test-wide-integers.sh](../tools/test-wide-integers.sh) can run selected arithmetic with an ESP toolchain and `qemu-xtensa -cpu dc232b`; otherwise it reports compile-only coverage. Neither is an ESP32-S3 board run. [SIMD coverage](simd.md) describes S3 scalar fallback and compile-only vector checks. |
| Android arm64 — build-defined `android-arm64`, `aarch64-linux-android24` | Local-suite cross-compilation and integration-file inspection | [test-android-extension.sh](../tools/test-android-extension.sh) checks an AArch64 shared library, exports, reproducibility and generated JNI/Kotlin/Gradle files. [test-android-rpc-example.sh](../tools/test-android-rpc-example.sh) also executes the **host** RPC server. Neither runs an Android app, emulator or device; no Android compiler binary is released. |
| RISC-V64 — raw/build-defined `riscv64-unknown-elf` or `riscv64-unknown-linux-gnu` | Local-suite object inspection; conditional freestanding emulator execution | [test-target-descriptors.sh](../tools/test-target-descriptors.sh) checks raw ELF objects, exports and rejection of unsupported executable linking. [test-wide-integers.sh](../tools/test-wide-integers.sh) supplies startup/stubs and runs selected arithmetic under `qemu-riscv64` when installed, including a configuration without the M extension. No hosted compiler release. |
| RISC-V32 — raw `riscv32-unknown-elf` | Local-suite object/helper inspection; conditional freestanding emulator execution | [test-wide-integers.sh](../tools/test-wide-integers.sh) builds objects, checks arithmetic helper dependencies and runs with its own startup under `qemu-riscv32` when installed, without the M extension. No hosted compiler release. |
| Other triples / formats, including COFF | Experimental generic emission contract only | [src/toolchain.ab](../src/toolchain.ab) accepts the raw descriptor formats listed above. [test-target-descriptors.sh](../tools/test-target-descriptors.sh) proves that mechanism for selected ELF targets; it is not evidence of Windows hosting, arbitrary CPU support, or runtime coverage for every LLVM backend. |

## Toolchain and runtime boundaries

Linux-to-macOS linking requires an extracted SDK in `ABLA_MACOS_SDK` and suitable
target libraries; [tools/build-macos-from-linux.sh](../tools/build-macos-from-linux.sh)
checks that prerequisite. Being able to emit a Mach-O object without linking is
not equivalent to having that SDK or being able to run the result on Linux.

Xtensa needs the patched LLVM described in [llvm-xtensa.md](llvm-xtensa.md).
The ordinary packaged Linux toolchain and Homebrew LLVM used by macOS release
jobs do not supply that backend. Emulator arithmetic tests do not cover the
ESP32 startup, board peripherals, networking stack or a firmware application.
Those belong to the embedding framework and its own tests.

For freestanding targets, a framework must provide startup, runtime hooks and
link policy; see [freestanding.md](freestanding.md). For Wasm, the host must
provide the imports the module actually uses. Native libc, files, sockets and
threads are not implied by successful Wasm or freestanding code generation.
