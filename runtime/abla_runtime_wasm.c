#include "abla_runtime.h"

// A libc-free module owns one linear-memory arena. Browser artifacts are
// instantiated afresh and do not retain pointers outside that instance, so a
// monotonic allocator is sufficient; memory is reclaimed with the instance.
extern unsigned char __heap_base;

static uintptr_t wasm_heap_cursor;

static void* wasm_pointer(AblaValue value) {
    return (void*)(uintptr_t)(uint64_t)abla_as_i64(value);
}

static AblaValue wasm_pointer_value(void* pointer) {
    return abla_i64((int64_t)(uintptr_t)pointer);
}

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

// Freestanding guests use these explicit unsafe-memory primitives to bridge
// their exported scalar ABI to linear memory. The monotonic arena is reclaimed
// with the WebAssembly instance, so free is intentionally a no-op.
AblaValue ablaUnsafeAllocate(AblaValue size_value) {
    const int64_t size = abla_as_i64(size_value);
    if (size < 0) __builtin_trap();
    return wasm_pointer_value(abla_platform_alloc((size_t)size));
}

AblaValue ablaUnsafeFree(AblaValue pointer) {
    abla_platform_free(wasm_pointer(pointer));
    return abla_void();
}

AblaValue ablaUnsafeLoadI64(AblaValue address) {
    const unsigned char* source = (const unsigned char*)wasm_pointer(address);
    uint64_t value = 0;
    for (size_t index = 0; index < 8; ++index) {
        value |= (uint64_t)source[index] << (index * 8);
    }
    return abla_i64((int64_t)value);
}

AblaValue ablaUnsafeStoreI64(AblaValue address, AblaValue value) {
    unsigned char* destination = (unsigned char*)wasm_pointer(address);
    const uint64_t stored = (uint64_t)abla_as_i64(value);
    for (size_t index = 0; index < 8; ++index) {
        destination[index] = (unsigned char)(stored >> (index * 8));
    }
    return abla_void();
}

AblaValue ablaUnsafeNullPointer(void) {
    return abla_i64(0);
}

AblaValue ablaUnsafePointerIsNull(AblaValue value) {
    return abla_bool(abla_as_i64(value) == 0);
}

AblaValue ablaUnsafePointerAddress(AblaValue value) {
    (void)wasm_pointer(value);
    return value;
}

AblaValue ablaUnsafePointerOffset(AblaValue value, AblaValue offset) {
    const uint64_t base = (uint64_t)abla_as_i64(value);
    const int64_t displacement = abla_as_i64(offset);
    return abla_i64((int64_t)(base + (uint64_t)displacement));
}

AblaValue ablaUnsafeLoadU8(AblaValue address) {
    const unsigned char value = *(const unsigned char*)wasm_pointer(address);
    return abla_i64((int64_t)value);
}

AblaValue ablaUnsafeStoreU8(AblaValue address, AblaValue value) {
    *(unsigned char*)wasm_pointer(address) =
        (unsigned char)abla_as_i64(value);
    return abla_void();
}
