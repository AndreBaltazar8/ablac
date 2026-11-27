# Windows compiler without the C runtime: options

Status: André chose B (decision #163); the plan is at the end. First written as a proposal (todo #1046 follow-up;
decision #104.1 left it as "a later, separate todo"). Inventory by ablac-15 (agents-memory
`abla/ablac-windows-crt-inventory.md`), note by ablac-a5. Written against master 648cf072a (v0.2.78).

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
   It runs as the `Windows compiler link` workflow with `crt_inventory: true`, once per `architecture` (x64, arm64):
   tools/windows/crt-inventory.ps1 uploads the map, the member log, bytes per archive and each leave-one-out link's
   undefined symbols. The shipped `ablac` link is not changed by it.
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

## Decision and plan: B

André chose B (decision #163): Abla's own C library, with Microsoft's C++ library (libcpmt) and low-level helpers
(libvcruntime) kept, as Linux keeps libstdc++ and libgcc.

### What the inventory measured

From the `crt_inventory` runs 45983657838 (x64) and 45983661891 (arm64):

- **Bytes in the image.** UCRT 268 KB (x64) / 235 KB (arm64); libcpmt 59 / 32 KB; libvcruntime 25 / 15 KB; libcmt
  9 / 9 KB. The compiler image is 84 / 74 MB.
- **Linking without UCRT.** That leaves 157 (x64) / 153 (arm64) undefined symbols. ARM64 needs none that x64 does
  not.
- **The 157 by kind.**

  | Kind | Symbols |
  | --- | ---: |
  | math | 34 |
  | start-up and exit | 26 |
  | strings and number parsing | 25 |
  | file descriptors | 14 |
  | process | 13 |
  | locale | 11 |
  | heap | 10 |
  | printf/stdio | 9 |
  | date-format tables | 8 |
  | time | 5 |
  | threads | 2 |

  All are public UCRT exports. None is a `__acrt_*` internal except the public `__acrt_iob_func`.
- **Linking without UCRT and libcmt.** That also drops libcmt's start-up objects. Those include its default-library
  directive for libvcruntime, so the probe also loses VCRuntime's names. The candidate link names `libvcruntime.lib`
  explicitly.

### Where the code goes

- **Windows C library.** A new `src/static_libc/windows/` exports the UCRT names that src/orc_windows_main.ab needs.
  It reuses the Linux modules' implementations, which make Linux system calls. On a Windows target those already go to
  the runtime's translation (stdlib/abla/runtime/platform/windows/entry.ab, `__ablaRuntimeWindowsSyscall`). That
  translation already has the descriptor table over handles, files, time, environment, threads and the VirtualAlloc
  heap.
- **ABI differences.** The Windows layer differs from Linux only where the Windows ABI does:
  - `long` is 32 bits (LLP64), so the `strtol`/`atol` family and `_lseek` need their own widths;
  - `long double` is `double`;
  - `va_list` is a plain pointer on x64 and ARM64 Windows;
  - errno is `_errno()`.

### Steps, in order

Each step lowers the undefined count of one candidate link. That link uses the same inputs as `ablac.exe` with
`/nodefaultlib:libucrt.lib /nodefaultlib:libcmt.lib /defaultlib:libvcruntime.lib`. Add it to the inventory as
`ablac-crt-candidate`. Each step's evidence is a `crt_inventory` run on both architectures, with the candidate's count
and its undefined list. The shipped `ablac.exe` keeps `/MT` until step 7.

1. **Candidate link and start-up.** Our own entry replaces `wmainCRTStartup`:
   - it runs the C and C++ initializers between our own `.CRT$XIA`/`.CRT$XIZ` and `.CRT$XCA`/`.CRT$XCZ` markers
     (LLVM's static `cl::opt`s and registries are there), then `abla_windows_start`;
   - `exit` runs the `atexit`/`_onexit` table in reverse;
   - it supplies the thread-safe static guards (`_Init_thread_header`/`_footer`/`_epoch`, over a SRW lock and
     WaitOnAddress), the `/GS` cookie and its initialisation, `_tls_used` (the runtime already writes loader TLS for
     programs), the 26 start-up names and the onexit tables.

   **Check:** the candidate starts, and `ablac --version` runs natively on both runners.
2. **Heap and process** (10 + 13):
   - `malloc`/`calloc`/`realloc`/`free`/`_aligned_*`/`_strdup`/`_wcsdup` on the runtime heap, and `_heapwalk` as
     "no more entries";
   - `exit`/`_exit`/`abort`/`signal`/`getenv`/`rand`/`rand_s`/`_errno`/`_invoke_watson`/`_set_abort_behavior`/
     `_set_error_mode`/`terminate`. `abort` and `_invoke_watson` end the process with the panic status.
3. **Descriptors and stdio** (14 + 9):
   - `_open_osfhandle`, `_get_osfhandle`, `_read`/`_write`/`_close`/`_lseek(i64)`, `_setmode` and `_chsize_s` over
     the runtime's descriptor table (LLVM's `raw_fd_ostream` writes through these);
   - `__acrt_iob_func` returns three FILE records;
   - `fflush`/`fputc`/`fputs`/`putchar`;
   - `__stdio_common_vfprintf`/`vsprintf`/`vsprintf_s`/`vsscanf`, on static_libc's formatter (format.ab,
     floatfmt.ab) with a Windows `va_list` reader. The formatter must take an argument-reader parameter instead of
     SysV's `va_list`.
4. **Strings, parsing and math** (25 + 34):
   - the static_libc functions with Windows widths;
   - `_dclass`/`_ldclass`/`_fpclass`/`_dsign` and `feclearexcept`/`fetestexcept` over MXCSR (x64) and FPSR (ARM64).
5. **Time and threads** (5 + 2):
   - `_time64`, `_gmtime64_s`, `_localtime64(_s)` (UTC, as the Linux static compiler does) and `strftime`;
   - `_beginthreadex`/`_endthreadex` over the runtime's thread start, so each thread gets its TLS and interrupt word.
6. **The C locale** (11 + 8). Stand-ins that describe the C locale only:
   - `___lc_codepage_func` returns 0;
   - `___lc_collate_cp_func` returns 0;
   - `___lc_locale_name_func` returns six null names;
   - `___mb_cur_max_func` returns 1;
   - `__pctype_func` returns the 256-entry C ctype table;
   - `__strncnt` is `strnlen`;
   - `_lock_locales`/`_unlock_locales` do nothing;
   - `setlocale` answers "C" and refuses others;
   - `localeconv` returns the C `lconv`;
   - `_configthreadlocale` returns the old mode;
   - `_Getdays`/`_Getmonths`/`_Gettnames` and their `_W_` forms return the C names in a block that only our
     `_Strftime`/`_Wcsftime` read.

   **Check:** the candidate's undefined count is 0 on both architectures.
7. **Switch.** The shipped link drops libucrt and libcmt. Today's packages and Windows seed stay until all of these
   pass:
   - native x64 and ARM64 start-up, release and `--fast` builds with only System32 on `PATH`;
   - the import and archive provenance checks;
   - the native compile-time probes;
   - stage 2 == stage 3 for COFF and PE;
   - cold hello, JSON and self-build measured against the `/MT` compiler on the same runners, with PE and zip sizes no
     worse.

### Not changed

- `libcpmt` and `libvcruntime` stay. `memcpy`/`memset`/`memchr`/`strchr`/`strstr`/`strrchr`/`wcschr`, exception
  handlers, `_purecall` and `type_info` come from VCRuntime, as on Linux they come from libgcc.
- Programs that ablac builds for Windows are unaffected: they already link no C runtime.

## Related gap (not part of this decision)

No native Windows test recovers from a stack overflow on a worker thread. `fault-guard.exe` covers the calling thread
twice, including re-arming the guard page. A worker-thread test is a separate, small item.
