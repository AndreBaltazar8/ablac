// malloc, calloc, realloc and free on the Windows process heap (HeapAlloc), for the Abla C library link with
// ABLA_WINDOWS_PROCESS_HEAP=ON (build-static-compiler.ps1 -CLibrary abla-heap). A measurement arm, not what ships: it puts the
// allocator the /MT build has (the UCRT's malloc is the process heap) under the Abla C library, so a speed difference between
// the two links can be split into the allocator's part and the rest (docs/design/windows-crt-free-compiler.md, step 7).
//
// Written from the Win32 heap API's documentation (HeapAlloc, HeapReAlloc, HeapFree, GetProcessHeap). The Abla C library still
// allocates for itself on the Abla heap (strdup, _wcsdup, _aligned_malloc), and a caller may free such a block with free: each
// block made here carries a tag just before the pointer it gives out, and free and realloc hand an untagged pointer to the
// Abla heap's own (abla_libc_free, abla_libc_realloc in src/static_libc/memory.ab).
#include <stddef.h>
#include <stdint.h>

extern "C" {
__declspec(dllimport) void* __stdcall GetProcessHeap(void);
__declspec(dllimport) void* __stdcall HeapAlloc(void* heap, unsigned long flags, size_t bytes);
__declspec(dllimport) void* __stdcall HeapReAlloc(void* heap, unsigned long flags, void* block, size_t bytes);
__declspec(dllimport) int __stdcall HeapFree(void* heap, unsigned long flags, void* block);
void abla_libc_free(void* block);
void* abla_libc_realloc(void* block, size_t size);
}

namespace {
const unsigned long heapZeroMemory = 0x00000008;
// The header: 16 bytes, so the pointer keeps HeapAlloc's 16-byte alignment; the tag is its second word.
const size_t header = 16;
const uint64_t tag = 0x48ea9a110c0ffee5ull;

void* tagged(void* base) {
    if (!base) return nullptr;
    char* block = static_cast<char*>(base) + header;
    reinterpret_cast<uint64_t*>(block)[-1] = tag;
    return block;
}

bool ours(void* block) { return reinterpret_cast<const uint64_t*>(block)[-1] == tag; }

void* base(void* block) { return static_cast<char*>(block) - header; }
}

extern "C" void* malloc(size_t size) {
    if (size > SIZE_MAX - header) return nullptr;
    return tagged(HeapAlloc(GetProcessHeap(), 0, size + header));
}

extern "C" void* calloc(size_t count, size_t size) {
    if (size != 0 && count > (SIZE_MAX - header) / size) return nullptr;
    return tagged(HeapAlloc(GetProcessHeap(), heapZeroMemory, count * size + header));
}

extern "C" void free(void* block) {
    if (!block) return;
    if (!ours(block)) {
        abla_libc_free(block);
        return;
    }
    reinterpret_cast<uint64_t*>(block)[-1] = 0;
    HeapFree(GetProcessHeap(), 0, base(block));
}

extern "C" void* realloc(void* block, size_t size) {
    if (!block) return malloc(size);
    if (!ours(block)) return abla_libc_realloc(block, size);
    if (size > SIZE_MAX - header) return nullptr;
    return tagged(HeapReAlloc(GetProcessHeap(), 0, base(block), size + header));
}
