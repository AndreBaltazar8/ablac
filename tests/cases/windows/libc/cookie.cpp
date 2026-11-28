// The /GS cookie the loader seeds must survive the start-up of the compiler linked without Microsoft's C library
// (tools/windows/static-compiler/crt-free-start.cpp, which tools/test-windows-libc.sh links this with): a TLS callback, which the
// loader runs after it seeds the cookie of an image whose load configuration names it and before the entry point, records it, and
// wmain compares. Exit 0: kept; 1: replaced; 2: the loader seeded nothing (still the default when the callback ran).
#include <windows.h>

extern "C" UINT_PTR __security_cookie;
static const UINT_PTR default_cookie = 0x00002B992DDFA232ull;
static UINT_PTR seen;

static void NTAPI cookie_capture(PVOID, DWORD reason, PVOID) {
    if (reason == DLL_PROCESS_ATTACH && !seen) seen = __security_cookie;
}

// The TLS directory Microsoft's tlssup supplies (crt-free-start.cpp's __declspec(thread) needs one too).
extern "C" {
ULONG _tls_index = 0;
#pragma section(".tls", read, write)
#pragma section(".tls$ZZZ", read, write)
#pragma section(".CRT$XLA", long, read)
#pragma section(".CRT$XLB", long, read)
#pragma section(".CRT$XLZ", long, read)
__declspec(allocate(".tls")) char _tls_start = 0;
__declspec(allocate(".tls$ZZZ")) char _tls_end = 0;
__declspec(allocate(".CRT$XLA")) PIMAGE_TLS_CALLBACK __xl_a = 0;
__declspec(allocate(".CRT$XLB")) PIMAGE_TLS_CALLBACK __xl_b = cookie_capture;
__declspec(allocate(".CRT$XLZ")) PIMAGE_TLS_CALLBACK __xl_z = 0;
extern const IMAGE_TLS_DIRECTORY64 _tls_used = {(ULONGLONG)&_tls_start, (ULONGLONG)&_tls_end, (ULONGLONG)&_tls_index,
    (ULONGLONG)(&__xl_a + 1), 0, 0};
}

// What crt-free-start.cpp's operator new and _alloca_probe name, which the Abla runtime supplies in the compiler.
extern "C" void* malloc(size_t size) { return HeapAlloc(GetProcessHeap(), 0, size); }
extern "C" void free(void* block) { HeapFree(GetProcessHeap(), 0, block); }
extern "C" void* _aligned_malloc(size_t size, size_t) { return malloc(size); }
extern "C" void _aligned_free(void* block) { free(block); }
__asm__(".globl __chkstk\n__chkstk:\n    ret\n");

static void say(const char* text) {
    DWORD written;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, lstrlenA(text), &written, nullptr);
}

extern "C" int wmain() {
    if (seen == 0 || seen == default_cookie) {
        say("cookie: the loader seeded nothing\n");
        return 2;
    }
    if (__security_cookie != seen) {
        say("cookie: start-up replaced the loader's cookie\n");
        return 1;
    }
    say("cookie: the loader's cookie kept\n");
    return 0;
}
