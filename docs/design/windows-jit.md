# The JIT on Windows (C2)

Step 2 of [windows-target.md](windows-target.md), item C2: `ablac run` (ORC), the compile-time native tier (`src/ct_jit.ab`,
`src/ct_eval.ab`) and `ablac run --watch` in `ablac.exe`. Written before code, against the compiler as it is after C3
(`win-paths`): the front end runs on Windows under Wine, and compile-time code runs in the evaluator. Nothing here can run before
the windows-msvc LLVM archives (#1137) exist; step 0 below is what to confirm first, once they do.

Marked **[checked]** where I read the code or ran it, **[confirm]** where it depends on how the pinned LLVM (23.1.3) behaves for
`x86_64-pc-windows-msvc`, which only the archives will show.

## What the JIT does today, and what each part needs on Windows

| Part (Linux and macOS today) | Where | Windows |
| --- | --- | --- |
| One `LLJIT` from `LLVMOrcCreateLLJIT` with the default builder, its default object linking layer | `stdlib/abla/llvm/orc`, `llvmOrcCreateSession` [checked] | the linking layer LLJIT picks for COFF: §1 |
| A process symbol generator (`LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess`): JIT'd code calls the runtime and the compiler bridge in the compiler's own image, which `--export-dynamic` exports [checked] | same; `src/toolchain.ab` | an executable exports nothing by default: §2 |
| Executable memory: LLVM's own memory managers (`sys::Memory`) | inside LLVM | VirtualAlloc/VirtualProtect, inside LLVM; nothing of ours: §3 |
| Large frames: none on Linux (no stack probes by default) | | `__chkstk`: §3 |
| Thread-locals of JIT'd code: emulated (`__emutls_get_address`, `src/emutls_export.ab`) | [checked] | the same, if the JIT's target machine emulates TLS for COFF [confirm]: §3 |
| The guard around a native compile-time call: `setjmp`, then a `longjmp` from a signal handler (1 abort, 2 trap, 3 time limit, 4 bad access, 5 panic), `pthread_self` to know the thread | `ct_jit.ab` `abla_ct_guard_<g>` [checked] | own setjmp/longjmp (no SEH unwinding), GetCurrentThreadId: §4 |
| Bad access, trap, stack overflow in JIT'd code: SIGSEGV/SIGBUS/SIGILL on an alternate stack, `longjmp` to the guard | `bootstrapCtArmFaults` [checked] | the vectored exception handler the runtime already installs: §4 |
| The time limit: SIGALRM (`setitimer`), its handler jumps to the guard; an interpreted site's alarm makes a blocked call return EINTR | `bootstrapCtArmAlarm`, `bootstrapCtArmInterpreterAlarm` [checked] | a watchdog that redirects the thread: §5. Since C3 (`24f3301de`) nothing is armed on Windows: no time limit is enforced |
| Unwind information for JIT'd frames: `.eh_frame` registered by LLVM | inside LLVM | `.pdata`/`.xdata` registration (RtlAddFunctionTable): §6 |
| `ablac run --watch` restarts by `execve` of itself with a reason in the environment | `src/live_watch.ab` [checked] | no exec on Windows: §7 |

## 1. The object linking layer: JITLink COFF, RuntimeDyld as the fallback

LLJIT chooses its object linking layer from the triple. For x86-64 COFF the pinned LLVM has both JITLink's COFF linker and
RuntimeDyld's COFF loader. **[confirm]** which one `LLVMOrcCreateLLJIT` gives on `x86_64-pc-windows-msvc`. The LLVM-C API can
force RuntimeDyld (`LLVMOrcLLJITBuilderSetObjectLinkingLayerCreator` with
`LLVMOrcCreateRTDyldObjectLinkingLayerWithSectionMemoryManager`); there is no C function for JITLink's `ObjectLinkingLayer`, which
would be a few lines in our C++ shim (`runtime/abla_lld_shim.cpp`, the only C++ we have).

**Recommendation: JITLink.** It is the linker ORC develops (RuntimeDyld is in maintenance), it already links the Linux and macOS
JIT here, so the code model and relocation questions are the same ones, and its plugin interface is where §6's unwind
registration goes. RuntimeDyld stays the fallback if the probe in step 0 finds JITLink COFF missing a relocation our objects use;
the session code (`llvmOrcCreateSession`) takes one branch either way.

Both resolve `IMAGE_REL_AMD64_REL32` to a symbol outside 2 GB of the JIT'd code by a stub; **[confirm]** that calls into the
compiler image from JIT memory get one (JITLink's COFF x86-64 builds a GOT and PLT stubs; RuntimeDyld's COFF needs the small code
model with stubs, which LLJIT's default target machine gives).

## 2. Symbols the JIT'd code takes from the compiler

On Linux the compiler is linked with `--export-dynamic` and the process generator finds everything (`dlsym`). On Windows,
`DynamicLibrarySearchGenerator::GetForCurrentProcess` searches the export tables of the loaded modules, the executable's included;
an executable linked without exports has none. Two ways:

- **Exports (recommended).** `ablac.exe` is linked with an export for every external definition of the compiler's object: the
  runtime (`__ablaRuntime*`), the bridge (`abla_ct_bridge_*`), `__emutls_get_address`, the ORC-reachable C entry points. The list
  is the object's defined external symbols (`llvm-nm --defined-only --extern-only`), written as a `.def` beside the link
  (`bootstrapLinkWindowsExecutable` with `compiler = true`, which already sets the 128 MiB stack). Same set as Linux's, found the
  same way. The cost is the export table: a few hundred KB of names for the compiler.
- **Absolute symbols.** The compiler defines, in the main JITDylib, the addresses it knows of itself
  (`LLVMOrcAbsoluteSymbols`). It needs a list of every symbol JIT'd code may name, which is the same list kept by hand.

## 3. Memory, stack probes and thread-locals

- **Executable memory** is LLVM's (`sys::Memory::allocateMappedMemory` and `protectMappedMemory`, VirtualAlloc and VirtualProtect
  on Windows), not ours. The compiler maps no executable memory of its own: no `mmap` with PROT_EXEC in `src/` [checked]. The
  runtime's `mmap`/`mprotect` translations already map protections to VirtualAlloc/VirtualProtect if that changes.
- **`__chkstk`.** A Win64 function with a frame over 4 KiB calls `__chkstk` to touch its pages in order. JIT'd code would need it
  in the process. Recommendation, as the target design already says for programs: the `"probe-stack"="inline-asm"` function
  attribute on every function of a module the JIT compiles for Windows (`ablac run`'s modules and each compile-time slice), so
  LLVM inlines the probe and no symbol is needed. **[confirm]** that the pinned LLVM honours it for COFF x86-64 (it does for ELF).
- **Thread-locals.** JIT'd code cannot use Windows' TLS (`_tls_index`, the loader's TLS directory). It has to be emulated, as on
  macOS: `__emutls_get_address` from `src/emutls_export.ab` (exported, §2), whose non-macOS path keeps its own registry
  (`pthread_key_create` is defined to answer ENOSYS on Windows since C3 and is not called there). **[confirm]** that LLJIT's
  target machine for this triple emulates TLS; if not, the JIT target machine builder needs `EmulatedTLS` set, which the C API
  does not expose: one more shim function.

## 4. The guard, faults and traps

The guard (`abla_ct_guard_<g>`) is IR the slice emits: `setjmp`, mark the thread (`pthread_self`), call the entry, disarm. A
handler `longjmp`s to it with how the call stopped.

- **setjmp/longjmp.** MSVC's `longjmp` unwinds the frames it crosses through SEH; JIT'd frames without registered unwind
  information would make that fail. The guard uses our own pair, `abla_setjmp`/`abla_longjmp` (callee-saved registers, rsp, the
  return address, and on Win64 xmm6-xmm15 too; no unwinding), as macOS' own `_setjmp`/`_longjmp` (#811 G4) are.
- **The thread.** `pthread_self` becomes `GetCurrentThreadId` (exported, or read inline from the TEB: the thread id is at gs:0x48).
- **Faults.** The runtime's vectored exception handler (`abla_runtime_windows_fault`, installed by every hosted program's `main`)
  reports only exceptions raised in the image and lets the rest go on. It gains one cell: the armed guard of the current thread
  (a thread-local word set by the guard while it is armed, cleared on return). When an exception arrives while it is set, the
  handler does what the Linux signal handler does: it changes the CONTEXT it was given to resume in a small routine that calls
  `abla_longjmp(guard buffer, how)` (Rip, Rcx, Rdx, and Rsp aligned below the faulting frame) and returns
  EXCEPTION_CONTINUE_EXECUTION. How: 0xC0000005 an access violation 4, 0xC000001D an illegal instruction (`ud2`, LLVM's trap) 2,
  0xC0000094/0xC0000095 integer division 4.
- **Stack overflow** (0xC00000FD) in JIT'd code: the handler runs on what is left of the stack, so threads that run compile-time
  code reserve room first (`SetThreadStackGuarantee(64 KiB)`), and after jumping back the guard page is put back
  (`VirtualProtect` with PAGE_GUARD on the page below the committed stack, which Windows removes when it raises the exception;
  the CRT's `_resetstkoflw` does the same).
- **`abort`** in the slice (a fatal handler) becomes the same jump with 1, as it is.

## 5. Interrupting a running compile-time call (the time limit)

Linux arms SIGALRM: its handler runs on the target thread and jumps to the guard (3), unless the thread is in the compiler's own
code (the slice's `inCompiler` and `deferred` words), where the jump waits until it returns to the slice. Windows has no signal
to the thread. The design:

- **A watchdog thread** in the compiler (one, made on first use) waits for the deadline of the armed call
  (`WaitForSingleObject` on an event with the remaining time as its timeout; arming sets the deadline and the event).
- **At the deadline** it reads the slice's words. In the compiler: it sets `deferred`, as the signal handler does, and the slice
  jumps on its way out. In JIT'd code: `SuspendThread`, `GetThreadContext`, and if Rip is still in JIT memory, the same CONTEXT
  change as for a fault with 3, `SetThreadContext`, `ResumeThread`. A suspended thread may hold a lock only in the compiler's
  or the runtime's code, which is exactly the deferred case, so the redirect never leaves a lock held.
- **The redirect's conditions** (ablac-60's review; the technique Go's asynchronous preemption and .NET use; Win64 has no red
  zone, so lowering Rsp and pointing Rip at the jump routine is safe and the old frame is never resumed):
  1. only when Rip is inside a JIT allocation: in ntdll, kernel32 or the runtime (JIT'd code in the middle of a system call),
     the thread is resumed and the watchdog tries again about a millisecond later, since a redirect there could leave a loader,
     heap or I/O lock held;
  2. a thread suspended in a kernel wait reports the wait's call site, and the redirect takes effect only when the wait returns,
     so the wait slices and CancelSynchronousIo below are needed beside it, not instead of it;
  3. the watchdog never suspends itself, and between SuspendThread and ResumeThread it allocates nothing and takes no lock the
     target could hold (the heap's above all);
  4. Wine does SuspendThread and SetThreadContext through wineserver and signals: they work, more slowly and less exactly, so the
     windows-run job on Windows is the answer for this part.
- **A blocked call** (an interpreted site's file or pipe read, the case the Linux alarm breaks with EINTR): the watchdog calls
  `CancelSynchronousIo` on the thread, which ends a synchronous ReadFile/WriteFile with ERROR_OPERATION_ABORTED, which the runtime
  reports as EINTR (ERROR_OPERATION_ABORTED to -4 in the read and write translations). Waits the runtime makes itself (`Sleep`,
  `WaitOnAddress`, `WaitForSingleObject` in wait4, the poll loops) go through one helper that waits at most about 20 ms a slice
  and then looks at the thread's "interrupted" word, so every wait returns EINTR (WaitOnAddress is not alertable: an APC would
  not wake it). The word is per thread, not one for the process: the compiler's other threads (code generation, a generation's
  own threads) must not see EINTR. The runtime gives each thread its word in native TLS and a function that returns its address
  (`abla_runtime_windows_interrupt_cell`); the guard records that address while it is armed, and the watchdog writes 1 through
  it. CreatePipe's handles are synchronous; CancelSynchronousIo ends a read of one with EINTR under Wine **[checked]**
  (tests/cases/windows/preempt.ab), on the runner **[confirm]**. The same test redirects a thread spinning in VirtualAlloc'd
  code from another thread (SuspendThread, GetThreadContext, abla_windows_redirect, SetThreadContext, ResumeThread) under
  Wine **[checked]**.
- **New kernel32 imports** (for the compiler, which is CRT-linked per #104, so they can come from the CRT's kernel32 import
  library rather than our list): SuspendThread, ResumeThread, GetThreadContext, SetThreadContext, CancelSynchronousIo,
  CreateEventW, SetEvent, WaitForSingleObject (already), SetThreadStackGuarantee.

Until this is built the state is C3's: no time limit on Windows; a site that loops forever hangs the build.

## 6. Unwind information for JIT'd code

Not needed for the guard (§4's jump does not unwind). Needed for: a crash report's stack (`RtlLookupFunctionEntry`, the Windows section of docs/debugging.md)
through JIT'd frames, which `ablac run` programs print; a debugger's stack; and Windows' own handling of a stack overflow in a
frame it cannot unwind (it still delivers the exception to a vectored handler, which is all we need).

**Recommendation:** a JITLink plugin in the shim that, after fixups, finds each linked graph's `.pdata` section and registers it
with `RtlAddFunctionTable(pdata, count, base)`, `base` the lowest address of the graph's allocation (the RVAs in `.pdata` and
`.xdata` are relative to it, and one allocation is under 4 GB), and `RtlDeleteFunctionTable` when the resource tracker removes the
module (a redefinition in `ablac run --live`). **[confirm]** that JITLink's COFF keeps `.pdata` and `.xdata` (its
`SEHFrameKeepAlivePass` is there for that). First version without it: crash stacks stop at the first JIT'd frame, which the report
already handles (a frame without unwind data ends the walk).

## 7. `ablac run --watch` without exec

Linux: on a change the program cannot take live, `bootstrapLiveRestart` re-executes `ablac` with the same arguments and
`ABLAC_WATCH_RESTARTED=<reason>`. Windows has no exec; spawning a new `ablac.exe` and exiting would end the process the shell waits on.

**Recommendation: a supervising parent.** On Windows, `ablac run --watch` starts itself as a child (the runtime's spawn, the same
arguments, the standard handles inherited, `ABLA_LIVE_SUPERVISED=1`) and waits. The child does the watching. To restart, it
writes the reason where the parent reads it (an environment value is not returned, so a file beside the cache) and exits with a
status of its own (75, EX_TEMPFAIL). The parent starts a new child with `ABLAC_WATCH_RESTARTED=<reason>`. Any other status ends the
parent with that status. One level of processes whatever the number of restarts; the "refused again after a restart" check is
unchanged. Ctrl+C reaches both through the console, and the parent ends when the child does.

`linuxReexecute` itself (the compiler's stack raise) is not needed on Windows: the image is linked with its 128 MiB stack
(`2384128e8`), and `getrlimit` reads it back, so `bootstrapEnsureCompilerStack` never asks.

## Order of work, once #1137 is published

0. **Probe** (answers, little code): the real `ablac.exe` from the archives (C1) under Wine and on the windows-run job.
   Run `ablac run hello.ab` and one compile-time native site. Read off every **[confirm]** above: which linking layer, the stubs
   into the image, the probe attribute, the TLS model, `.pdata` kept, CancelSynchronousIo on a pipe.
1. §2 exports and §3 (probe-stack attribute, emulated TLS): `ablac run hello.ab` works.
2. §4 guard and faults: compile-time sites that abort, trap, access 16 and overflow stop with their codes, as
   `tools/test-compile-time-*` check on Linux.
3. §5 the watchdog: a looping site stops at its limit; an interpreted site blocked on a pipe read stops.
4. §7 `--watch`.
5. §6 unwind registration.

Tests: `tools/test-windows-compiler.sh` grows each step's case with the real LLVM in place of the stub (run, a native site, each
stop, the limit), under Wine; the windows-run job runs the same `ablac.exe` on Windows, which is the answer for §4 and §5 (Wine's
SuspendThread/SetThreadContext and exception dispatch are close to Windows but not the truth).

## Decisions (the lead, 2026-11-22)

1. §2: **exports through a `.def`**, the `--export-dynamic` equivalent, one symbol path. Built first: it needs no LLVM.
2. §5: **the suspended-thread redirect**, as on Linux and free on other hosts (the cooperative check would cost every host a
   load and a branch per back-edge). Its tests: a JIT'd tight loop with no calls interrupted at its limit, and a site blocked in
   I/O.
3. §7: **the supervising parent on Windows only**; Linux and macOS keep exec (it works, with no extra process). One restart
   path for every host only if it simplifies later.
