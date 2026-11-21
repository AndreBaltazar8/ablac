# Windows target: the interface audit

Companion to [windows-target.md](windows-target.md) (todo #1046), measured on master aaef105a. It turns the design's sizes into lists: what the runtime asks of the operating system, what the stdlib asks of the Linux syscall layer, and what each one becomes on Windows. Counts are call sites, not calls.

## 1. The runtime's operating-system surface is small

`stdlib/abla/runtime/platform/host.ab` (5,347 lines) is the heap, the collector and the thread machinery for Linux and the libc hosts, and **it already reaches the operating system through 23 raw system-call sites and a handful of libc externs**. The rest is OS-neutral logic (size classes, bins, the registry, marking). So the Windows port of the heap and collector is a swap of about ten primitives, not a rewrite; the design doc's "L" for the heap is the porting of assumptions (tail trimming, `mremap` growth, 4 KiB page size), not of the algorithm.

| Primitive | Linux site (host.ab) | Windows |
|---|---|---|
| futex wait / wake on a 32-bit word | `:97`, `:102` (syscall 202) | `WaitOnAddress` / `WakeByAddressSingle`/`All` (DLL name to be settled by W1a's probe, see the design) |
| map anonymous memory | `:309`, `:4798`, `:5119` (9, mmap) | `VirtualAlloc(MEM_RESERVE|MEM_COMMIT)`, results aligned to the 64 KiB granularity |
| unmap | `:319` (11) | `VirtualFree(MEM_RELEASE)` of the whole reservation only |
| grow or move a mapping | `:890` (25, mremap) | none: reserve large, commit in steps (`MEM_COMMIT`), or allocate new and copy |
| return pages / mark freeable | `:458`, `:684` (28, madvise) | `MEM_DECOMMIT` or `DiscardVirtualMemory`; `MEM_RESET` for "contents not needed" |
| protect pages | `:5218`, `:5246` (10, mprotect) | `VirtualProtect` (`PAGE_READONLY`, `PAGE_READWRITE`) |
| monotonic clock, sleep | `:1389`, `:1397` (228, 35) | `QueryPerformanceCounter`, `Sleep`/waitable timer |
| thread id | `:1406` (186 or 178) | `GetCurrentThreadId` |
| process id | `:2711` (39) | `GetCurrentProcessId` |
| read a small file (`/proc/self/maps`, cgroup limits) | `:1438`-`:1442`, `:2751`-`:2774` (openat/read/close) | `VirtualQuery` walk plus PE headers for the scan ranges; `GlobalMemoryStatusEx` / job object limits for the memory limit |
| install a signal action / alternate stack | `:1064` (rt_sigaction/sigaltstack), `:1052`-`:1099` | `AddVectoredExceptionHandler`, `SetThreadStackGuarantee` |
| libc: `pthread_create/join`, `pthread_mutex_*`, `pthread_cond_*` | externs at the file's head (hosts that keep libc) | `CreateThread`/`WaitForSingleObject`, the futex-style word, a condition on the same word |
| libc: `_longjmp`, `abla_stm_invoke` | `:1908`, `:1913`, head | register save and restore, as the design says |
| libc: `write`, `_exit`, `malloc` family | head | `WriteFile`, `ExitProcess`; the Windows heap does not use `malloc` |

The Darwin runtime already shows the shape: `darwin/entry.ab` (1,578 lines) and `wasm.ab` (1,548 lines) replace the same interface. A **Windows platform file** is therefore the 69 `__ablaRuntimePlatform*` functions below, implemented over these primitives, plus the allocator and collector shared with Linux.

**Recommended first step of W1c: split `host.ab` into the OS primitives (the table above) and the allocator/collector, both still for Linux, and compile the second for Windows unchanged.** Otherwise the Windows runtime copies 5,000 lines of heap and collector that then drift from the Linux ones. Test: the existing memory tests on Linux, unchanged output, and the objects' symbol lists compared before and after.

## 2. The 69 `__ablaRuntimePlatform*` functions (what `runtime/self` expects)

Grouped by what Windows must supply. "Shared" means the Linux implementation is OS-neutral once the primitives above exist.

- **Mutex and condition** (`MutexBytes`, `MutexInitialize`, `MutexLock`, `MutexLockBlocking`, `MutexUnlock`, `MutexDestroy`, `ConditionBytes`, `ConditionInitialize`, `ConditionWait`, `ConditionBroadcast`, `GlobalLock`, `GlobalUnlock`): the futex-word protocol, shared; only the wait and wake primitive changes. `MutexBytes` stays 64.
- **Threads** (`ThreadsEnable`, `ThreadsEnabled`, `ThreadCreate`, `ThreadJoin`, `ThreadRegister`, `ThreadUnregister`, `OnlyThread`, `ThreadSignalStackEnter`, `ThreadSignalStackLeave`, `NativeEnter`, `NativeLeave`, `NativeLeaveIfIn`): create/join are `CreateThread`/`WaitForSingleObject`; the signal-stack pair becomes `SetThreadStackGuarantee` bookkeeping; register/unregister and native enter/leave (how a thread tells the collector it is in foreign code) are shared, with stack bounds from the TEB.
- **Memory** (`RawAllocate`, `RawFree`, `Allocate`, `AllocateLayout`, `AllocateOwned`, `Free`, `MemoryRelease`, `PromoteAllocation`, `MemoryFreeze`, `MemoryCollect`, `MemoryCheckpoint`, `MemoryReset`, `MemoryLiveBytes`, `MemoryHeapStat`, `MemoryCensusTake`, `MemoryCensusWord`, `MemoryLimit`, `MemorySetLimit`, `MemorySetCollectionGrowth`, `MemorySetFreeBlockLimit`, `MemorySetManualCollection`, `MemorySetStress`, `MemorySetTrace`, `MemorySetLayout`, `MemorySetBackgroundFree`, `MemorySetGcWorkers`, `MemoryDebugHold`, `UnalignedWords`): shared; they call the mapping primitives.
- **Regions, roots, STM** (`RegionBegin`, `RegionEnd`, `RegionActive`, `RootBytes`, `RootStore`, `RootsSet`, `StmDescriptor`, `StmSetDescriptor`, `Attempt`, `Abandon`, `UnwindSave`, `UnwindRestore`): shared except `Attempt`/`UnwindSave`/`UnwindRestore` (register save and restore, per architecture; they exist for AArch64 and x86-64 Linux, and the x86-64 Win64 variant saves `rbx rbp rdi rsi r12-r15 xmm6-xmm15 rsp` plus the return address).
- **Panic** (`Panic`): prints and ends; Windows: `WriteFile` to stderr, then the status the design leaves to decision #104 (exit status of an unhandled panic).

Definition of done for the runtime file: every name above is defined for the Windows target, checked by a test that links an empty program and lists the undefined `__ablaRuntimePlatform*` symbols (none).

## 3. The syscall layer: every number the stdlib and compiler call

From `grep linuxSyscall` at the 69 files that import `abla/sys/linux/*` (x86-64 numbers; the macOS shim `runtime/abla_darwin_compat.c` has 106 cases for the same list). Grouped by Windows treatment; counts are call sites in `stdlib` and `src`.

**Faithful translation (Win32 has the same thing):**
read 0 (22), write 1 (7), open 2 (3), close 3 (61), stat 4 (2), fstat 5 (8), lstat 6 (2), lseek 8 (4), pread64 17 (2), access 21 (2), nanosleep 35 (2), getpid 39 (3), fsync 74 (5), ftruncate 77 (4), getcwd 79, chdir 80, rename 82, mkdir 83, rmdir 84, unlink 87, readlink 89, symlink 88, link 86, gettimeofday 96, clock_gettime 228 (8), exit 60 (8), exit_group 231 (8), openat 257 (7), newfstatat 262, unlinkat 263, getrandom 318 (2), mmap/munmap/mprotect/madvise 9/11/10/28, getrusage 98, getrlimit/setrlimit 97/160, getdents64 217 (2, through `FindFirstFileExW`), utimes 235 (`SetFileTime`), uname 63 (a fixed answer: sysname "Windows"; `RtlGetVersion` for the release), geteuid 107 (a fixed answer), gettid 186, sched_getaffinity 204 (`GetProcessAffinityMask`), chmod/fchmod 90/91 (only the read-only attribute: a documented partial).

**Sockets (translate, with the table of option numbers and the poll shim):**
socket 41 (10), connect 42, accept/accept4 43/288, sendto 44, recvfrom 45, shutdown 48, bind 49, listen 50, getsockname 51, getpeername 52, setsockopt 54, getsockopt 55, fcntl 72 (17, for `O_NONBLOCK` and `FD_CLOEXEC`; the first becomes `ioctlsocket`, the second is a no-op because handles are created non-inheritable), dup2 33 (15; `DuplicateHandle` into the table slot), poll 7 (5, `WSAPoll` for sockets), ioctl 16 (8, `FIONREAD` and the terminal queries; `GetConsoleMode` for `isatty`), pipe2 293 (`CreatePipe`, handle-list inheritance).

**Replace at the call site, not in the shim (no Windows equivalent of the model):**
- fork 57 (4), clone 56 (8), execve 59 (4), wait4 61 (8), setpgid 109, getpgid 121: `abla/process/command` and `supervisor` spawn with `CreateProcessW`, wait on the process handle, `TerminateProcess` for `kill` 62 (13 call sites; `wait4` 8), and the `clone` sites in `sys/linux/process` (1,235 lines) are the work; fork-stop machinery (#811) compiles out.
- epoll_create1 291, epoll_ctl, epoll_wait: used by the async HTTP client, the websocket server and `abla/net` loops: a poll-set shim over `WSAPoll` with the same level-triggered contract (design: sockets).
- signalfd, rt_sigaction 13, rt_sigprocmask 14 (10), sigaltstack 131, tgkill 234 (2; emutls thread liveness), setitimer 38: signals; see the design: console control handler, vectored exceptions, thread-liveness via the thread-end hook and `FlsAlloc` callbacks.
- flock 73 (file locks): `LockFileEx`/`UnlockFileEx`.
- futex 202 outside the runtime (4): the `abla/process` waits: `WaitOnAddress`.
- `/proc` and `/sys` readers: `abla/process/metrics`, `ablaHostProcessorCount` (`/sys/devices/system/cpu/online`), `abla/device`: `K32GetProcessMemoryInfo`, `GetSystemInfo`/`GetLogicalProcessorInformationEx`.

Anything not listed that appears later gets an entry here first; the shim's default for an unknown number is a visible `ENOSYS`, never a silent zero.

## 4. Where the stdlib is POSIX-shaped beyond the syscall layer

Grep results at aaef105a that the paths and runtime items must clear (each is a row in the W1g and W1d checklists):

- `Path` syntax in the stdlib: now in `abla/fs/path` (this branch), with the host's syntax chosen by `pathHostIsWindows()`; `Path.parent/name/extension/child` delegate to it.
- The compiler's own lexical path code: `src/module_paths.ab` `bootstrapNormalizeModulePath` (module identity, `/`-only, absolute means a leading `/`); callers of `Path(...).child("...")` with `/`-containing names; places that split on byte 47 directly. Next step of W1g: make `bootstrapNormalizeModulePath` call `pathNormalize` + `pathToCanonical`, with the compiler's module identities (cache keys, discovery cache, build-file-relative paths) staying `/`-canonical and a drive letter kept as one component-like root. Changing the compiler's module identity affects cache keys and the bootstrap lineage: do it as its own step with a stage 2 == stage 3 check, not inside the syntax refactor.
- Absolute-path assumptions written as `"/"` literals (`/etc/passwd`, `/tmp`, `/dev/null`, `/proc/self/...`, `/etc/resolv.conf`, `/etc/hosts`, `/etc/ssl`): each needs a Windows answer in `abla/platform/host`, `abla/dns`, `tls/hosted`, `abla/random`, `homePath` (`USERPROFILE`, then `HOMEDRIVE`+`HOMEPATH`) and the temp directory (`GetTempPathW`).
