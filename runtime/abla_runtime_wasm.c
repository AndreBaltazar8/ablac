#include "abla_runtime.h"

// A libc-free module owns one linear-memory arena. Browser artifacts are
// instantiated afresh and do not retain pointers outside that instance, so a
// monotonic allocator is sufficient; memory is reclaimed with the instance.
extern unsigned char __heap_base;

static uintptr_t wasm_heap_cursor;

static size_t align_eight(size_t value) {
    return (value + 7u) & ~(size_t)7u;
}

void* abla_platform_alloc(size_t requested) {
    const size_t size = requested == 0 ? 1 : requested;
    if (wasm_heap_cursor == 0) {
        wasm_heap_cursor = align_eight((uintptr_t)&__heap_base);
    }
    const uintptr_t begin = wasm_heap_cursor;
    const uintptr_t end = begin + align_eight(size);
    if (end < begin) __builtin_trap();

    const size_t page_size = 65536;
    const size_t current_pages = __builtin_wasm_memory_size(0);
    const size_t required_pages = (end + page_size - 1) / page_size;
    if (required_pages > current_pages) {
        const size_t growth = required_pages - current_pages;
        if (__builtin_wasm_memory_grow(0, growth) == (size_t)-1) {
            __builtin_trap();
        }
    }
    wasm_heap_cursor = end;
    return (void*)begin;
}

void abla_platform_free(void* pointer) {
    (void)pointer;
}

_Noreturn void abla_platform_panic(const char* message, uint64_t length) {
    (void)message;
    (void)length;
    __builtin_trap();
}

void abla_platform_memory_set_scan(void* pointer, int64_t size) {
    (void)pointer;
    (void)size;
}

void abla_platform_memory_set_layout(void* pointer, int64_t layout) {
    (void)pointer;
    (void)layout;
}

void abla_platform_memory_set_cache_owner(void* pointer, void* owner) {
    (void)pointer;
    (void)owner;
}
