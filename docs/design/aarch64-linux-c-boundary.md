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
| `bootstrap-llvm`, `conformance-ir-cache`, `lowered-ir-cache`, `native-function-address`, `stable-native-symbols`, `xtensa-interrupt-handler` | import `src/`, so LLVM in the process | AArch64 LLVM archives, no C library |
| `unsafe-boundary` | `extern "c" dlsym` | a dynamic loader: glibc |
| `import-alias-externs` | `extern "c" sin` | nothing any more |
| `compile-time-recursion-deep` | none | the x86-64 compiler's own stack (not a C boundary) |

- **The LLVM group does not need glibc.** The AArch64 compiler is itself an Abla program that links LLVM. It links the static
  AArch64 LLVM archives on Abla's own C library (src/static_libc). The link already takes that route when
  `ABLA_STATIC_LLVM_LIB` is set (`staticLlvm` in the aarch64 branch). That route has been proven only for the compiler's own
  entry; the six programs have not been built through it yet, which is item 1 below. nix/aarch64-static-native-deps.nix provides the archives,
  libstdc++.a, libgcc.a and libz.a from any host, as the static AArch64 job and aarch64-native-fixpoint.yml use them. The
  allowlist's note ("libLLVM has no AArch64 build here") is true of the pinned shell's dynamic libLLVM, not of those archives.
- **`import-alias-externs` is stale.** With 0.2.79 it builds for aarch64-linux and exits 42 under qemu-aarch64: `sin` is
  Abla's own now (#806). Its line can go.
- **`unsafe-boundary`** is the real case. `dlsym` needs the dynamic loader, and a static-pie program has none.

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
1. The LLVM group builds for aarch64-linux through the static archives. The libc-free AArch64 lane sets `ABLA_STATIC_LLVM_LIB`
   and `ABLA_STATIC_TARGET_LIBS` from nix/aarch64-static-native-deps.nix, and those six `nobuild-a64` lines go (and the RV64
   twins if an RV64 cohort exists; there is none today).
2. `import-alias-externs`' line goes.
3. A link that cannot work says so. When the aarch64 link is libc-free and the program brings a C library, the build stops
   before lld with `E_BUILD_TARGET_CAPABILITY`. The error names the boundary and what would build it: the native host under A,
   the sysroot under B, or "x86-64 Linux only" under C.
4. `compile-time-recursion-deep` is a separate item: the cross compiler's stack, not a C boundary.

## What CI needs

- **For the shared items:** the libc-free-aarch64 job fetches nix/aarch64-static-native-deps.nix. It's binary-cached, and
  about the same download the static AArch64 job already makes. The job then builds and runs the six LLVM programs under
  QEMU, and a test checks the new diagnostic.
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

Do the shared items now. They are small, need no decision, and remove seven of the nine lines. Then do **A**: the same rule as
x86-64 (libc-free unless the program brings a C library) on native AArch64 hosts, with a clear error for cross builds. That
covers the programs people actually build on ARM Linux machines, at one branch and one native CI job. Leave B until someone
needs to build ARM graphics binaries on x86-64. Its cost is in maintaining a sysroot of system libraries, not in the compiler.

## Decision text for André

> **Programs with a C boundary on aarch64-linux (G3).** Today an aarch64-linux program that links a C library (its manifest
> names `nativeLibraries` such as vulkan, GL or cuda, or it calls C functions like `dlsym`) does not build. The build fails
> with a raw linker error, even on an ARM Linux machine. On x86-64 Linux the same program links the system's glibc. That
> affects abla-graphics, abla-doom, abla-one's desktop gallery and abla-grad on ARM Linux. Programs that link LLVM can be
> fixed without glibc, and that's being done regardless.
>
> - **A (recommended):** on an ARM Linux machine, link glibc exactly as x86-64 does, only for programs that bring a C library.
>   Building such a program for ARM from an x86-64 machine stays unsupported, with a clear error. One native ARM CI job.
> - **B:** A, plus building them for ARM from x86-64 through a downloaded ARM system library set (nix). More CI, and each new
>   system library must exist in that set. Graphics programs can't be run under emulation, only linked.
> - **C:** ARM Linux stays libc-free. These programs are documented as x86-64 Linux only, with a clear error.
