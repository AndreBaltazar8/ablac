// The start-up and C++ support that libcmt gave the Windows compiler, for the link without libucrt and libcmt
// (decision #163, step 1 of docs/design/windows-crt-free-compiler.md). For now only the ablac-crt-candidate inventory link
// has it; ablac.exe keeps /MT until the plan's last step. It calls no C library: Win32, and VCRuntime for the exception
// handlers. Compiled with /GS- (it defines the stack cookie checks) and /Zl (it names no default library).
//
// - wmainCRTStartup: the stack cookie, the C and C++ initializers between the .CRT$XIA/XIZ and .CRT$XCA/XCZ markers
//   (LLVM's static cl::opts and registries), then wmain (crt-start.cpp), which enters the Abla runtime;
// - atexit: records the function; C's exit (called by LLVM's and lld's C++) runs the table, last first. The Abla runtime
//   ends the process with ExitProcess, which ran no C runtime exit handlers under /MT either;
// - the thread-safe static guards (_Init_thread_header/footer/abort, _Init_thread_epoch) in the MSVC ABI;
// - the /GS cookie and __security_check_cookie (the __GSHandlerCheck handlers and ARM64's __security_push_cookie and
//   __security_pop_cookie are Microsoft's own, from libcmt.lib: CMakeLists.txt links those members);
// - _load_config_used (the delay-load helper reads it), the Control Flow Guard pointers (no-ops: the compiler is not
//   built with /guard:cf), __isa_enabled for the STL's vector algorithms, and _alloca_probe;
// - type_info's vftable and scalar deleting destructor, _IsNonwritableInCurrentImage for VCRuntime's handler checks,
//   and __tlregdtor (thread_local destructors are not run);
// - operator new and delete over malloc and free.
#include <windows.h>

typedef void(__cdecl* abla_pvfv)(void);
typedef int(__cdecl* abla_pifv)(void);

#pragma section(".CRT$XIA", long, read)
#pragma section(".CRT$XIZ", long, read)
#pragma section(".CRT$XCA", long, read)
#pragma section(".CRT$XCZ", long, read)
extern "C" __declspec(allocate(".CRT$XIA")) const abla_pifv __xi_a[] = {nullptr};
extern "C" __declspec(allocate(".CRT$XIZ")) const abla_pifv __xi_z[] = {nullptr};
extern "C" __declspec(allocate(".CRT$XCA")) const abla_pvfv __xc_a[] = {nullptr};
extern "C" __declspec(allocate(".CRT$XCZ")) const abla_pvfv __xc_z[] = {nullptr};
#pragma comment(linker, "/merge:.CRT=.rdata")

extern "C" int wmain();
extern "C" void* malloc(size_t size);
extern "C" void free(void* block);
extern "C" void* _aligned_malloc(size_t size, size_t alignment);
extern "C" void _aligned_free(void* block);

// --- the stack cookie ---------------------------------------------------------------------------------------------------
// /GS (learn.microsoft.com, "/GS (Buffer Security Check)"): code reads __security_cookie, a value that differs per run, and
// calls __security_check_cookie with it at return, which ends the process when it changed. The loader seeds it (the image's
// load configuration names it), and start-up keeps that seed; only when it is still the built-in default does start-up make
// one. The default is the one the Visual Studio CRT source's gs_cookie.c gives (DEFAULT_SECURITY_COOKIE), so code that reads
// the cookie before either sets it gets the value it expects. tools/test-windows-libc.sh checks the seed is kept.

extern "C" UINT_PTR __security_cookie = 0x00002B992DDFA232ull;
extern "C" UINT_PTR __security_cookie_complement = ~0x00002B992DDFA232ull;

static void abla_security_init_cookie() {
    // The loader has seeded the cookie already when the image's load configuration names it (_load_config_used below), from the
    // system's random source: a value that is no longer the default is kept, as Microsoft's __security_init_cookie keeps it.
    if (__security_cookie != 0x00002B992DDFA232ull) {
        __security_cookie_complement = ~__security_cookie;
        return;
    }
    LARGE_INTEGER counter;
    QueryPerformanceCounter(&counter);
    FILETIME time;
    GetSystemTimeAsFileTime(&time);
    UINT_PTR cookie = (UINT_PTR)counter.QuadPart ^ ((UINT_PTR)time.dwHighDateTime << 32 | time.dwLowDateTime) ^
        (UINT_PTR)GetCurrentThreadId() << 16 ^ (UINT_PTR)GetCurrentProcessId() ^ (UINT_PTR)&cookie;
    cookie &= 0x0000FFFFFFFFFFFFull;
    if (cookie == 0x00002B992DDFA232ull || cookie == 0) cookie = 0x00002B992DDFA233ull;
    __security_cookie = cookie;
    __security_cookie_complement = ~cookie;
}

extern "C" void __cdecl __security_check_cookie(UINT_PTR cookie) {
    if (cookie != __security_cookie) __fastfail(FAST_FAIL_STACK_COOKIE_CHECK_FAILURE);
}

#if defined(_M_ARM64)
// The interlocked functions MSVC's ARM64 objects call out of line (libcpmt's ppltasks.cpp and others), with the
// semantics learn.microsoft.com documents for the _Interlocked intrinsics (the result value; _nf: no fence).
extern "C" long abla_interlocked_increment(long volatile* target) __asm__("_InterlockedIncrement");
extern "C" long abla_interlocked_increment(long volatile* target) {
    return __atomic_add_fetch(target, 1, __ATOMIC_SEQ_CST);
}
extern "C" long abla_interlocked_increment_nf(long volatile* target) __asm__("_InterlockedIncrement_nf");
extern "C" long abla_interlocked_increment_nf(long volatile* target) {
    return __atomic_add_fetch(target, 1, __ATOMIC_RELAXED);
}
extern "C" long abla_interlocked_decrement(long volatile* target) __asm__("_InterlockedDecrement");
extern "C" long abla_interlocked_decrement(long volatile* target) {
    return __atomic_sub_fetch(target, 1, __ATOMIC_SEQ_CST);
}
extern "C" long abla_interlocked_or(long volatile* target, long value) __asm__("_InterlockedOr");
extern "C" long abla_interlocked_or(long volatile* target, long value) {
    return __atomic_fetch_or(target, value, __ATOMIC_SEQ_CST);
}
extern "C" void* abla_interlocked_exchange_pointer(void* volatile* target, void* value)
    __asm__("_InterlockedExchangePointer");
extern "C" void* abla_interlocked_exchange_pointer(void* volatile* target, void* value) {
    return __atomic_exchange_n(target, value, __ATOMIC_SEQ_CST);
}
extern "C" void* abla_interlocked_compare_exchange_pointer(void* volatile* target, void* exchange, void* comparand)
    __asm__("_InterlockedCompareExchangePointer");
extern "C" void* abla_interlocked_compare_exchange_pointer(void* volatile* target, void* exchange, void* comparand) {
    __atomic_compare_exchange_n(target, &comparand, exchange, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return comparand;
}
#endif

// --- Control Flow Guard and the load configuration ----------------------------------------------------------------------

static void __cdecl abla_guard_check_icall(UINT_PTR) {}

#if defined(_M_X64)
// The dispatch thunk gets the target in rax.
extern "C" __attribute__((naked)) void abla_guard_dispatch_icall() { __asm__("jmp *%rax"); }
#elif defined(_M_ARM64)
// The dispatch thunk gets the target in x15.
extern "C" __attribute__((naked)) void abla_guard_dispatch_icall() { __asm__("br x15"); }
#endif

extern "C" const void* __guard_check_icall_fptr = (const void*)&abla_guard_check_icall;
extern "C" const void* __guard_dispatch_icall_fptr = (const void*)&abla_guard_dispatch_icall;

extern "C" const IMAGE_LOAD_CONFIG_DIRECTORY _load_config_used = {
    sizeof(IMAGE_LOAD_CONFIG_DIRECTORY), // Size
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // TimeDateStamp .. EditList
    (ULONGLONG)&__security_cookie,       // SecurityCookie
};

// --- the STL's processor feature word (vector_algorithms.cpp) and _alloca_probe ----------------------------------------

#if defined(_M_X64)
// Bit 0: x86; bit 1: SSE2, which every x64 processor has. The vector algorithms then take their SSE2 paths.
extern "C" int __isa_enabled = 0x3;
extern "C" int __isa_available = 1;

// The same probe as __chkstk (the Abla runtime's, a weak definition), under the name MSVC's code also calls.
__asm__(".globl _alloca_probe\n_alloca_probe:\n    jmp __chkstk\n");
#elif defined(_M_ARM64)
// LLVM's DynamicLibrary names it among the symbols a JIT'd module may call.
__asm__(".globl _alloca_probe\n_alloca_probe:\n    b __chkstk\n");
#endif

// --- type_info ----------------------------------------------------------------------------------------------------------

// type_info's scalar deleting destructor, the one entry of its vftable: type_info objects are static and never deleted.
extern "C" void* abla_type_info_scalar_deleting_destructor(void* self, unsigned int) { return self; }

#if defined(_M_X64) || defined(_M_ARM64)
__asm__(".section .rdata,\"dr\"\n"
        ".p2align 3\n"
        "    .quad 0\n" // the complete object locator: none, as in code built without RTTI
        ".globl \"??_7type_info@@6B@\"\n"
        "\"??_7type_info@@6B@\":\n"
        "    .quad abla_type_info_scalar_deleting_destructor\n"
        ".text\n");
#endif

// --- VCRuntime's handler checks and thread_local destructors ------------------------------------------------------------

extern "C" IMAGE_DOS_HEADER __ImageBase;

// Whether `target` lies in a section of this image that is not writable (an exception handler must).
extern "C" BOOL __cdecl _IsNonwritableInCurrentImage(PBYTE target) {
    PBYTE base = (PBYTE)&__ImageBase;
    if (__ImageBase.e_magic != IMAGE_DOS_SIGNATURE) return FALSE;
    PIMAGE_NT_HEADERS headers = (PIMAGE_NT_HEADERS)(base + __ImageBase.e_lfanew);
    if (headers->Signature != IMAGE_NT_SIGNATURE) return FALSE;
    UINT_PTR rva = (UINT_PTR)(target - base);
    PIMAGE_SECTION_HEADER section = IMAGE_FIRST_SECTION(headers);
    for (WORD index = 0; index < headers->FileHeader.NumberOfSections; index++, section++) {
        if (rva >= section->VirtualAddress && rva < section->VirtualAddress + section->Misc.VirtualSize) {
            return (section->Characteristics & IMAGE_SCN_MEM_WRITE) == 0;
        }
    }
    return FALSE;
}

// Registers a thread_local object's destructor. They are not run (lld's ELF reader's thread_locals hold only memory).
extern "C" int __cdecl __tlregdtor(abla_pvfv) { return 0; }

// --- atexit -------------------------------------------------------------------------------------------------------------

static SRWLOCK abla_exit_lock = SRWLOCK_INIT;
static abla_pvfv abla_exit_table[512];
static unsigned abla_exit_count = 0;

extern "C" int __cdecl atexit(abla_pvfv function) {
    AcquireSRWLockExclusive(&abla_exit_lock);
    int status = -1;
    if (abla_exit_count < sizeof(abla_exit_table) / sizeof(abla_exit_table[0])) {
        abla_exit_table[abla_exit_count++] = function;
        status = 0;
    }
    ReleaseSRWLockExclusive(&abla_exit_lock);
    return status;
}

// exit() (src/static_libc/windows/process.ab) runs the table, the last recorded first, as C's exit does: the C++ static destructors
// (llvm::outs() flushes in its own) and what LLVM registered. Each entry is taken out before it runs, under the lock, so a function that
// calls exit itself, or records another, sees only what is left.
extern "C" void __cdecl abla_crt_run_exit_table() {
    for (;;) {
        AcquireSRWLockExclusive(&abla_exit_lock);
        abla_pvfv function = abla_exit_count != 0 ? abla_exit_table[--abla_exit_count] : nullptr;
        ReleaseSRWLockExclusive(&abla_exit_lock);
        if (!function) return;
        function();
    }
}

// --- thread-safe statics (the MSVC ABI: 0 not started, -1 running, then the epoch it finished in) ----------------------

extern "C" int _Init_global_epoch = -2147483647 - 1;
extern "C" __declspec(thread) int _Init_thread_epoch = -2147483647 - 1;
static SRWLOCK abla_static_lock = SRWLOCK_INIT;
static CONDITION_VARIABLE abla_static_done = CONDITION_VARIABLE_INIT;

extern "C" void __cdecl _Init_thread_header(int* guard) {
    AcquireSRWLockExclusive(&abla_static_lock);
    if (*guard == 0) {
        *guard = -1;
    } else {
        while (*guard == -1) {
            SleepConditionVariableSRW(&abla_static_done, &abla_static_lock, INFINITE, 0);
            if (*guard == 0) {
                *guard = -1;
                break;
            }
        }
        _Init_thread_epoch = _Init_global_epoch;
    }
    ReleaseSRWLockExclusive(&abla_static_lock);
}

extern "C" void __cdecl _Init_thread_footer(int* guard) {
    AcquireSRWLockExclusive(&abla_static_lock);
    ++_Init_global_epoch;
    *guard = _Init_global_epoch;
    _Init_thread_epoch = _Init_global_epoch;
    ReleaseSRWLockExclusive(&abla_static_lock);
    WakeAllConditionVariable(&abla_static_done);
}

extern "C" void __cdecl _Init_thread_abort(int* guard) {
    AcquireSRWLockExclusive(&abla_static_lock);
    *guard = 0;
    ReleaseSRWLockExclusive(&abla_static_lock);
    WakeAllConditionVariable(&abla_static_done);
}

// --- operator new and delete -------------------------------------------------------------------------------------------

namespace std {
enum class align_val_t : size_t;
struct nothrow_t;
} // namespace std

void* __cdecl operator new(size_t size) {
    void* block = malloc(size ? size : 1);
    if (!block) __fastfail(FAST_FAIL_FATAL_APP_EXIT);
    return block;
}
void* __cdecl operator new[](size_t size) { return operator new(size); }
void* __cdecl operator new(size_t size, const std::nothrow_t&) noexcept { return malloc(size ? size : 1); }
void* __cdecl operator new[](size_t size, const std::nothrow_t&) noexcept { return malloc(size ? size : 1); }
void* __cdecl operator new(size_t size, std::align_val_t alignment, const std::nothrow_t&) noexcept {
    return _aligned_malloc(size ? size : 1, (size_t)alignment);
}
void __cdecl operator delete(void* block) noexcept { free(block); }
void __cdecl operator delete[](void* block) noexcept { free(block); }
void __cdecl operator delete(void* block, size_t) noexcept { free(block); }
void __cdecl operator delete[](void* block, size_t) noexcept { free(block); }
void __cdecl operator delete(void* block, size_t, std::align_val_t) noexcept { _aligned_free(block); }

// --- the entry ----------------------------------------------------------------------------------------------------------

extern "C" void wmainCRTStartup() {
    abla_security_init_cookie();
    for (const abla_pifv* entry = __xi_a + 1; entry < __xi_z; ++entry) {
        if (*entry && (*entry)() != 0) ExitProcess(255);
    }
    for (const abla_pvfv* entry = __xc_a + 1; entry < __xc_z; ++entry) {
        if (*entry) (*entry)();
    }
    ExitProcess((UINT)wmain());
}
