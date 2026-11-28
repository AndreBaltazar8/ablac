# Programs with a C boundary on aarch64-linux: options (G3)

A program has a C boundary when it brings a C library of its own. That happens in three ways: `extern "c"` or `extern "host"`
functions that only a C library defines, a manifest's `nativeLibraries`, or `src/` and `abla/llvm` imports, which link LLVM in
the process. On x86-64 Linux such a program links glibc by design. On aarch64-linux it does not build at all. This note says
why, lists the ways to fix that, and ends with a recommendation. Whether Abla supports glibc-linked programs on AArch64 is
André's decision, so the last section is written as decision text.

## What is true today

**x86-64 Linux** (src/toolchain.ab, the hosted executable link). A program links without libc (#806) unless it brings a C
library. Then, and only then, the link goes through the system's clang driver with `-pthread`. That gives the dynamic glibc
link with crt1, libc.so.6, ld-linux and the `-l` names of `nativeLibraries`. The same happens when the libc-free link leaves a
C function undefined: the link is retried hosted, and `--verbose` says why. This needs a C toolchain and glibc's development
files on the building machine. The libc-free link needs neither, because it uses the built-in lld.

**aarch64-linux and riscv64-linux** have only the libc-free link, from any host, including the native AArch64 compiler:
`-nostdlib -nostartfiles -static-pie -e abla_start` (#811). Nothing retries it hosted. A program with a C boundary stops with
lld's raw `undefined symbol` list and `E_NATIVE_TOOLCHAIN`, with no Abla diagnostic. `E_BUILD_TARGET_CAPABILITY` (manifest
`nativeLibraries` on a target that cannot link them) is only given for targets that are not hosted, and aarch64-linux is hosted.

The nine `nobuild-a64` lines of tools/libc-free-programs-allowlist.txt are three different things:

| Programs | Boundary | Needs |
|---|---|---|
| `bootstrap-llvm`, `conformance-ir-cache`, `lowered-ir-cache`, `native-function-address`, `stable-native-symbols`, `xtensa-interrupt-handler` | import `src/`, so LLVM in the process | libLLVM and a C library: glibc, or Abla's own (src/static_libc) with the static archives |
| `unsafe-boundary` | `extern "c" dlsym` | a dynamic loader: glibc |
| `import-alias-externs` | `extern "c" sin` (libm) | a C library: glibc's libm |
| `compile-time-recursion-deep` | none | the x86-64 compiler's own stack (not a C boundary) |

- **The LLVM group needs a C library as well as LLVM.** The AArch64 compiler is itself an Abla program that links LLVM: the
  static AArch64 LLVM archives (nix/aarch64-static-native-deps.nix, from any host) on Abla's own C library, which its entry
  (src/orc_main_static.ab) imports from src/static_libc. With `ABLA_STATIC_LLVM_LIB` and `ABLA_STATIC_TARGET_LIBS` set, the
  link takes that route (`staticLlvm`) for any program. But `bootstrap-llvm` imports no C library, so with 0.2.79 it stops
  at the link's aliases (`--defsym: symbol not found: abla_libc_setitimer`, and more). The C library is in `src/`, not the
  standard library, so a user's program that imports `abla/llvm` cannot bring it either. On aarch64-linux these programs
  need what any C-boundary program needs: a C library at link time. That's glibc and libLLVM.so under A or B, or Abla's
  C library made part of the standard library (a larger change that nothing asks for).
- **`import-alias-externs`** calls libm's `sin` through `extern "c"`. A release build for aarch64-linux links and exits 42
  under qemu-aarch64, but only because the optimizer folds `sin(0.0)`. The `--fast` build the test makes leaves `sin`
  undefined. It's a real C boundary, so its line stays.
- **`unsafe-boundary`**: `dlsym` needs the dynamic loader, and a static-pie program has none.

**Who hits it outside the tests** (sibling repositories, 2026-11-28):
- abla-graphics, abla-doom and abla-one's desktop gallery name `vulkan`, `X11`, `EGL` and `GL`.
- abla-grad names `cuda` and `nvrtc`.
- mono-life has an `extern` declaration in src/net.ab.

All of those are shared libraries the system provides, and the Vulkan and GL drivers are loaded by their loaders at run time.
None can be linked statically, so on AArch64 (ARM laptops, a Raspberry Pi with a desktop, Jetson, Graviton) they need the
same dynamic glibc link x86-64 has.

## Options

### A. A hosted glibc link on a native AArch64 host

The aarch64 branch does what x86-64 does: libc-free first, and the hosted clang-driver link (`--target=aarch64-linux-gnu
-pthread`, the `-l` names) when the program brings a C library. It only does this on a native aarch64-linux host, which has
the machine's own glibc, start files and libraries, with the same requirement x86-64 has (clang, or a C toolchain, plus the
libraries' development files). A cross build from x86-64 still cannot link these programs. It fails with an Abla diagnostic
instead of lld's list (see "In every option").

- Cost: small. It's one branch of the link, plus the native runner job below.
- Covers graphics, CUDA on Jetson-class machines and dlsym on the machine they run on, which is where those programs are
  built in practice.
- Keeps the rule Abla already has: a C library only when the program brings one.

### B. A as well as cross links through a nix AArch64 sysroot

A, plus the hosted link from x86-64 against an AArch64 sysroot: `clang --target=aarch64-linux-gnu --sysroot=<dir>`, with glibc,
the start files and each named library's `.so`. nixpkgs gives these as substitutes without building, as
aarch64-static-native-deps.nix already does for libstdc++, by importing nixpkgs with `system = "aarch64-linux"`.

- Cost: medium and open-ended. The compiler needs a way to be given the sysroot (a variable or a flag, and its cache key in
  tools/build-cache-inputs.tsv). Each library a program names must exist for AArch64 in that sysroot. CUDA for AArch64 is
  unfree and versioned separately, so it would not be covered.
- Running such a program under qemu-aarch64 needs `-L <sysroot>`. Vulkan and GL programs cannot be meaningfully run there:
  qemu-user has no GPU.
- What it buys: building ARM graphics binaries on an x86-64 machine. Nobody has asked for that yet.

### C. Not supported: aarch64-linux stays libc-free

C boundaries are documented as x86-64 Linux only. The build fails early with `E_BUILD_TARGET_CAPABILITY` naming the boundary
(`nativeLibraries`, the extern "c" name it could not resolve, `extern "host"`). The LLVM group still works through the static
archives.

- Cost: least. It closes the door for the graphics and CUDA repositories on ARM Linux.
- It fits "Abla should never require libc" (#806) most strictly. But x86-64 already links glibc when a program brings one, so
  AArch64 would be the odd one out, not the rule.

### In every option

These need no decision:
1. A link that cannot work says so, with `E_BUILD_TARGET_CAPABILITY` naming the boundary. The build stops before the link when
   the manifest names `nativeLibraries`, the program calls `extern "host"` functions, or it links LLVM with no static
   archives named. When the link leaves C functions undefined (`dlsym`), it gives one error naming them after the linker's
   report. Under A the help line would say "build on an AArch64 Linux machine" instead of x86-64.
2. The nine lines stay until A or B. The six LLVM programs are the compiler's own tests, which import `src/`.
3. `compile-time-recursion-deep` is a separate item: the cross compiler's stack, not a C boundary.

## What CI needs

- **For the shared items:** nothing new. tools/test-target-descriptors.sh checks the new diagnostics with the x86-64
  compiler's cross builds (no QEMU run needed).
- **For A:** one job on GitHub's `ubuntu-24.04-arm` runner, which aarch64-native-fixpoint.yml already uses. It runs the
  AArch64 compiler natively and builds:
  - `unsafe-boundary` (dlsym);
  - a `nativeLibraries` program against a library the runner image has (libz or libm; the runner has no GPU, so not Vulkan);
  - one LLVM program;
  - all three run, and a libc-free program must stay libc-free (no `NEEDED` entries).

  That's a few minutes per run. It could run with each master push or nightly, like the Windows smoke.
- **For B, on top of A:** the sysroot derivation, an x86-64 job that cross-links the same programs, and QEMU runs with `-L`.
  Cross graphics programs can only be checked for their link, not run.
- **For C:** only the shared items.

## Recommendation

Do the shared item now: it is small and needs no decision, and the eight C-boundary programs then fail with an
error that names their boundary instead of lld's list. Then do **A**: the same rule as
x86-64 (libc-free unless the program brings a C library) on native AArch64 hosts, with a clear error for cross builds. That
covers the programs people actually build on ARM Linux machines, at one branch and one native CI job. Leave B until someone
needs to build ARM graphics binaries on x86-64. Its cost is in maintaining a sysroot of system libraries, not in the compiler.

## Decision text for André

> **Programs with a C boundary on aarch64-linux (G3).** Today an aarch64-linux program that links a C library (its manifest
> names `nativeLibraries` such as vulkan, GL or cuda, or it calls C functions like `dlsym`) does not build. The build fails
> with a raw linker error, even on an ARM Linux machine. On x86-64 Linux the same program links the system's glibc. That
> affects abla-graphics, abla-doom, abla-one's desktop gallery and abla-grad on ARM Linux, and programs that link LLVM. A
> clearer error for these builds is being added regardless.
>
> - **A (recommended):** on an ARM Linux machine, link glibc exactly as x86-64 does, only for programs that bring a C library.
>   Building such a program for ARM from an x86-64 machine stays unsupported, with a clear error. One native ARM CI job.
> - **B:** A, plus building them for ARM from x86-64 through a downloaded ARM system library set (nix). More CI, and each new
>   system library must exist in that set. Graphics programs can't be run under emulation, only linked.
> - **C:** ARM Linux stays libc-free. These programs are documented as x86-64 Linux only, with a clear error.
