// The /GS exception-dispatch probe (tools/windows/check-gs-handler.ps1; docs/design/windows-crt-free-compiler.md, step 7).
// Compiled by MSVC's cl with /GS, which gives `victim` (a frame with a local buffer and so a stack cookie) the exception
// handler __GSHandlerCheck: when an exception is dispatched through that frame, the handler checks the frame's cookie
// and ends the process when it changed (learn.microsoft.com, "/GS (Buffer Security Check)": the cookie is checked "in
// the exception handlers as well"). Linked with ablac.exe's start-up and C library (CMakeLists.txt, abla-gs-probe).
//
//   abla-gs-probe intact    the exception passes victim's frame and reaches wmain's handler: exit status 1
//   abla-gs-probe corrupt   victim's cookie is overwritten first: __GSHandlerCheck ends the process with
//                           STATUS_STACK_BUFFER_OVERRUN (0xC0000409), before wmain's handler runs
#include <windows.h>
#include <intrin.h>

// Every byte from `from` up to `to`, through a volatile pointer the optimizer cannot follow: past the buffer, these are
// the cookie and the saved registers, up to (not including) the return address.
__declspec(noinline) static void smash(char* from, char* to) {
    for (char* volatile byte = from; byte < to; byte = byte + 1) *byte = 0x41;
}

__declspec(noinline) static void raise_through() { RaiseException(0xE0AB1A00, 0, 0, nullptr); }

__declspec(noinline) static int victim(bool corrupt) {
    volatile char buffer[64];
    for (int index = 0; index < 64; ++index) buffer[index] = (char)index;
    if (corrupt) smash((char*)buffer + sizeof(buffer), (char*)_AddressOfReturnAddress());
    raise_through();
    return buffer[7];
}

// Whether the command line holds " corrupt" (no C library function: the abla link has none).
static bool asks_corrupt() {
    static const wchar_t word[] = L" corrupt";
    for (const wchar_t* at = GetCommandLineW(); *at; ++at) {
        int index = 0;
        while (word[index] && at[index] == word[index]) ++index;
        if (!word[index]) return true;
    }
    return false;
}

// Our start-up calls wmain with no arguments (crt-free-start.cpp), libcmt's with three; neither needs them here.
extern "C" int wmain() {
    bool corrupt = asks_corrupt();
    __try {
        victim(corrupt);
    } __except (GetExceptionCode() == 0xE0AB1A00 ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
        return 1;
    }
    return 2;
}
