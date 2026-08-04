#include "abla_runtime.h"

#include <stdint.h>

static int raw_argc;
static char** raw_argv;

void abla_runtime_set_arguments(int argc, char** argv) {
    raw_argc = argc;
    raw_argv = argv;
}

static AblaValue raw_pointer(void* pointer) {
    return abla_i64((int64_t)(uintptr_t)pointer);
}

static void* raw_as_pointer(AblaValue value) {
    return (void*)(uintptr_t)(uint64_t)abla_as_i64(value);
}

void abla_platform_memory_set_cache_owner(void* pointer, void* owner) {
    (void)pointer;
    (void)owner;
}

AblaValue ablaUnsafeAllocate(AblaValue size) {
    void* pointer = abla_platform_alloc((size_t)abla_as_i64(size));
    abla_platform_memory_set_layout(pointer, 10);
    return raw_pointer(pointer);
}
AblaValue ablaUnsafeFree(AblaValue pointer) {
    abla_platform_free(raw_as_pointer(pointer));
    return abla_void();
}
AblaValue ablaUnsafeLoadI64(AblaValue address) {
    return abla_i64(*(const int64_t*)raw_as_pointer(address));
}
AblaValue ablaUnsafeStoreI64(AblaValue address, AblaValue value) {
    *(int64_t*)raw_as_pointer(address) = abla_as_i64(value);
    return abla_void();
}
AblaValue ablaUnsafeLoadPointer(AblaValue address) {
    return raw_pointer(*(void* const*)raw_as_pointer(address));
}
AblaValue ablaUnsafeStorePointer(AblaValue address, AblaValue value) {
    *(void**)raw_as_pointer(address) = raw_as_pointer(value);
    return abla_void();
}
AblaValue ablaUnsafeNullPointer(void) { return abla_i64(0); }
AblaValue ablaUnsafePointerIsNull(AblaValue value) {
    return abla_bool(raw_as_pointer(value) == (void*)0);
}
AblaValue ablaUnsafeCallMain(AblaValue address) {
    int (*function)(int, char**) = (int (*)(int, char**))raw_as_pointer(address);
    return abla_i64(function(0, (char**)0));
}
AblaValue ablaUnsafeCStringAddress(AblaValue value) {
    return raw_pointer((void*)abla_as_cstring(value));
}
AblaValue ablaUnsafePointerAddress(AblaValue value) { return value; }
AblaValue ablaUnsafePointerOffset(AblaValue value, AblaValue offset) {
    return raw_pointer((uint8_t*)raw_as_pointer(value) + abla_as_i64(offset));
}
AblaValue ablaUnsafeLoadU8(AblaValue address) {
    return abla_i64(*(const uint8_t*)raw_as_pointer(address));
}
AblaValue ablaUnsafeStoreU8(AblaValue address, AblaValue value) {
    *(uint8_t*)raw_as_pointer(address) = (uint8_t)abla_as_i64(value);
    return abla_void();
}
AblaValue ablaUnsafeAdoptString(AblaValue address, AblaValue length) {
    char* data = (char*)raw_as_pointer(address);
    const int64_t size = abla_as_i64(length);
    data[size] = '\0';
    AblaValue result = abla_string_static(data, (size_t)size);
    result.as.string.owned = true;
    return result;
}
AblaValue ablaUnsafeBorrowCString(AblaValue address) {
    const char* data = (const char*)raw_as_pointer(address);
    size_t length = 0;
    while (data[length] != '\0') ++length;
    return abla_string_static(data, length);
}

AblaValue ablaLinuxSyscall(
    AblaValue number,
    AblaValue argument0,
    AblaValue argument1,
    AblaValue argument2,
    AblaValue argument3,
    AblaValue argument4,
    AblaValue argument5) {
    register int64_t r10 __asm__("r10") = abla_as_i64(argument3);
    register int64_t r8 __asm__("r8") = abla_as_i64(argument4);
    register int64_t r9 __asm__("r9") = abla_as_i64(argument5);
    int64_t result;
    __asm__ volatile(
        "syscall"
        : "=a"(result)
        : "a"(abla_as_i64(number)), "D"(abla_as_i64(argument0)),
          "S"(abla_as_i64(argument1)), "d"(abla_as_i64(argument2)),
          "r"(r10), "r"(r8), "r"(r9)
        : "rcx", "r11", "memory");
    return abla_i64(result);
}

AblaValue ablaLinuxArgumentCount(void) {
    return abla_i64(raw_argc > 0 ? raw_argc - 1 : 0);
}
AblaValue ablaLinuxArgument(AblaValue index_value) {
    const int64_t index = abla_as_i64(index_value);
    if (index < 0 || index + 1 >= raw_argc) {
        abla_platform_panic("argument index out of bounds", 28);
    }
    return ablaUnsafeBorrowCString(raw_pointer(raw_argv[index + 1]));
}
AblaValue ablaLinuxEnvironmentPointer(void) {
    return raw_pointer(raw_argv == (char**)0 ? (void*)0 : raw_argv + raw_argc + 1);
}

AblaValue ablaRuntimeMemoryCheckpoint(void) {
    return abla_i64(abla_platform_memory_checkpoint());
}
AblaValue ablaRuntimeMemoryReset(AblaValue checkpoint) {
    abla_platform_memory_reset(abla_as_i64(checkpoint));
    return abla_void();
}
AblaValue ablaRuntimeMemoryLiveBytes(void) {
    return abla_i64(abla_platform_memory_live_bytes());
}
AblaValue ablaRuntimeMemoryLimit(void) {
    return abla_i64(abla_platform_memory_limit());
}
AblaValue ablaRuntimeMemorySetLimit(AblaValue limit) {
    abla_platform_memory_set_limit(abla_as_i64(limit));
    return abla_void();
}
AblaValue ablaRuntimeMemoryCollect(void) {
    return abla_i64(abla_platform_memory_collect((void*)0));
}
