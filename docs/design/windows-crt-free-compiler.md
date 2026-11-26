# Windows compiler without the C runtime: options

Status: proposal for André's decision, 2026-11-26, no code (todo #1046 follow-up; decision #104.1 left it as "a later,
separate todo"). Inventory by ablac-15 (agents-memory `abla/ablac-windows-crt-inventory.md`), note by ablac-a5. Written
against master 648cf072a (v0.2.78).

## What is true today

- **Programs** that ablac builds for Windows use no C runtime. Each image imports only system DLLs (kernel32, ws2_32,
  ...), and the import-allowlist lane rejects any `msvcrt`, `ucrtbase`, `vcruntime` or `api-ms-win-crt-*` import
  (docs/design/windows-target.md, test lanes).
- **The compiler** (`ablac.exe`, x64 since v0.2.68, ARM64 since v0.2.69) links the static MSVC CRT (`/MT`,
  `tools/windows/static-compiler/CMakeLists.txt`). Its imports are 9 system DLLs and 241 (x64) / 236 (ARM64) symbols. It
  imports no CRT DLL. The CRT code is inside the image: startup (`wmainCRTStartup`, which runs the C and C++ static
  initializers), heap, stdio and file descriptors, locale, math, and the C++ runtime that LLVM, lld and the lld shim use.
- The compiler object Abla emits names **no** CRT function. Its 432 undefined names are resolved by the generated
  import libraries (104), LLVM and lld (321), the shim (6) and the linker (`__ImageBase`). **The whole CRT dependency
  comes from the C++ closure (LLVM, lld, the shim) and from startup.**
- On Linux, "libc-free" (#806 step C) means: no glibc. The static compiler replaces the C library with Abla's own
  `src/static_libc` (about 6,000 lines of Abla: memory, stdio, strings, math, locale, time, threads, unwind glue). It still
  links GCC's C++ runtime archives `libstdc++.a` and `libgcc.a` (`tools/build-static-compiler.sh`). So Linux parity means
  "our C library, the toolchain's C++ runtime", not "no runtime code we didn't write".

What the user sees is already the same on both systems. Neither compiler needs a C runtime installed or a matching
version: on Linux because glibc is gone, on Windows because `/MT` puts the CRT inside the executable. What is left on
Windows is where the code comes from (Microsoft's UCRT, VCRuntime and STL inside our binary) and consistency with Linux,
not a dependency anyone can trip over.

## The Windows CRT, in the parts that matter here

| Part | Static library | What the compiler uses it for |
| --- | --- | --- |
| UCRT (the C library) | `libucrt.lib` | `malloc`/`free`, stdio and CRT file descriptors (LLVM's `raw_fd_ostream` writes through `_write` on Windows), `getenv`, string and math functions, locale, `qsort`, time |
| VCRuntime | `libvcruntime.lib` | `memcpy`/`memset`, `_initterm` start-up glue, security cookie (`/GS`), C++ exception and RTTI support, thread-safe statics |
| C++ standard library (MSVC STL) | `libcpmt.lib` + headers | `std::` containers, `std::mutex`/`thread`, `std::filesystem` parts LLVM's Support uses |
| Start-up | `libcmt.lib` | `wmainCRTStartup`: CRT init, C++ global constructors (LLVM's static `cl::opt`s and registries), then `wmain` → `abla_windows_start` |

The shim is built with exceptions and RTTI off (`/EHs-c-`, `/GR-`, `_HAS_EXCEPTIONS=0`), as LLVM is by default, which keeps the C++
runtime's exception machinery small, but `libcpmt` itself was compiled by Microsoft with its own settings and calls into
UCRT internals. **Unverified: how much of `libcpmt` and `libvcruntime` the link actually pulls in, and through which
symbols.** The inventory's next step (below) answers that.

## Options

### A. Keep the static CRT (status quo, #104.1)

Nothing changes. The compiler has no runtime dependency; programs stay CRT-free and checked. **Cost: none. Risk: none.**
**What it gives up:** the compiler is the one Abla binary that carries third-party C runtime code, and Windows differs
from Linux there. Linking the static CRT is how any `/MT` application ships, so redistribution is not a question.

### B. Linux parity: our C library, the toolchain's C++ runtime

Replace `libucrt.lib` (and `libcmt.lib`'s start-up) with a Windows port of `src/static_libc`, and keep VCRuntime and the
MSVC STL static libraries, just as Linux keeps `libstdc++.a`/`libgcc.a`. Steps:

1. Link with `/NODEFAULTLIB:libucrt.lib /NODEFAULTLIB:libcmt.lib` and list every unresolved symbol, by archive member
   that needed it.
2. Port the needed `static_libc` parts to Win32. Most map onto code the Windows runtime already has: heap on
   `VirtualAlloc`, files and handles, time, environment. Plus a CRT-style file-descriptor table for LLVM's
   `_open`/`_write`/`_close`/`_get_osfhandle`.
3. Own start-up: run the C++ static initializers (`_initterm` over the `.CRT$XC*` sections, which VCRuntime or the
   linker lays out), then `abla_windows_start`. Exit runs `atexit` and destructors in order.
4. Keep `/Brepro`, the 128 MiB stack and the fixed-point checks. The new seed is promoted only after both architectures
   pass natively.

**Cost:** L, like #806 step C on Linux, but helped by the existing Windows runtime. **Main risk:** `libcpmt.lib` and
`libvcruntime.lib` are built against UCRT and may call UCRT internals that are not public (locale objects, `_Getcvt`,
`__acrt_*` helpers). If step 1 shows that coupling is deep, B becomes C. **Unknown until step 1 has run.**

### C. No Microsoft runtime at all: LLVM's own C++ runtime

Build LLVM, lld and the shim against libc++ and compiler-rt's builtins on top of the Windows `static_libc`. No
libc++abi is needed with exceptions off, but RTTI-free LLVM still needs a few runtime pieces: `operator new`/`delete`,
guard variables for static locals, `__chkstk`. **Cost:** XL. It means building our own Windows LLVM toolchain
configuration, and libc++ on the MSVC ABI without the MSVC STL is a less tested upstream setup. The LLVM SDK we pin would
need a matching libc++ build for x64 and ARM64. **Gain over B:** no Microsoft code in the compiler. **Risk:** high,
mostly in build infrastructure rather than in Abla.

### D. Move LLVM into a helper process

The main `ablac.exe` would be CRT-free, and a second executable would keep LLVM and lld with the static CRT. This meets
the goal only for the main image. It adds a process boundary on the hot path: bitcode hand-off, cancellation,
diagnostics. In-process ORC (`ablac run`, the REPL, native compile-time calls) cannot move out simply. **Not
recommended**; listed because it came up in the inventory.

## Recommendation

1. **Measure first (S, CI only, no product change).** Add `/lldmap` and `/verbose` to a publish-off link on both Windows
   runners. Keep the map, the link response file and the archive-member selection as artifacts. Classify every pulled-in
   symbol by library (UCRT, VCRuntime, STL, Win32) and by role (start-up, heap, stdio/fd, locale, math, threads, C++
   support), with bytes as well as symbol counts. Then try the step-1 link of option B
   (`/NODEFAULTLIB:libucrt.lib`) and list what is unresolved. That turns B's main risk into a number.
2. **Then choose between A and B with that list.** If the UCRT surface LLVM reaches is ordinary (memory, stdio/fd, a few
   strings and math functions, locale stubs), B is a bounded port and gives Windows the same meaning of "libc-free" as
   Linux. If `libcpmt`/`libvcruntime` reach deep into UCRT internals, A is the honest answer until there is a reason to
   pay for C.
3. **C only with a reason beyond parity**, for example a supply-chain rule that the compiler contains no third-party
   runtime code. In that case it also applies to Linux's `libstdc++.a`/`libgcc.a`.

Whatever is chosen keeps the current production packages and Windows seed until the replacement passes:
- native x64 and ARM64 start-up, release and `--fast` builds with only System32 on `PATH`;
- the import and archive provenance checks;
- the native compile-time probes;
- stage 2 == stage 3 for COFF and PE;
- cold hello, JSON and self-build measured against the `/MT` compiler on the same runners, with PE and zip sizes.

## Questions for André

1. **Goal:** is the Windows compiler's static CRT acceptable as it is (A), or should Windows match Linux's meaning of
   libc-free (B)? Or should no Microsoft runtime code be in the compiler at all (C, which raises the same question for
   Linux's libstdc++)?
2. **May the measurement step run now?** It is a CI-only link with map artifacts; nothing ships differently.

## Related gap (not part of this decision)

No native Windows test recovers from a stack overflow on a worker thread. `fault-guard.exe` covers the calling thread
twice, including re-arming the guard page. A worker-thread test is a separate, small item.
