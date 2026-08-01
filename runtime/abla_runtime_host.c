#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "abla_runtime.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int host_argc;
static char** host_argv;
static char** host_envp;
static bool host_stdin_line_available;
static volatile sig_atomic_t host_shutdown_requested;

typedef union AblaAllocationHeader AblaAllocationHeader;
union AblaAllocationHeader {
    struct {
        AblaAllocationHeader* previous;
        AblaAllocationHeader* next;
        uint64_t generation;
        size_t size;
        size_t scan_size;
        uint8_t scan_layout;
    } allocation;
    max_align_t alignment;
};

static AblaAllocationHeader* host_allocation_head;
static AblaAllocationHeader* host_allocation_tail;
static uint64_t host_allocation_generation;
static size_t host_allocation_live_bytes;
// Tracked heap budget. Programs must explicitly opt in before consuming more
// than one GiB, so a runaway compiler cannot silently exhaust the host.
static size_t host_allocation_limit = (size_t)1024 * 1024 * 1024;

// Private value-ABI helpers used only by the C platform adapter. Production
// LLVM modules provide their own Abla-authored value runtime; keeping this
// bridge private lets native links omit the legacy abla_runtime.c object.
struct AblaArray {
    size_t length;
    size_t capacity;
    AblaValue* values;
};

struct AblaStringRope {
    AblaString left;
    AblaString right;
    char* flattened;
};

static AblaValue host_value_void(void) {
    return (AblaValue){.tag = ABLA_VOID};
}

static AblaValue host_value_i64(int64_t value) {
    return (AblaValue){.tag = ABLA_I64, .as.i64 = value};
}

static AblaValue host_value_bool(bool value) {
    return (AblaValue){.tag = ABLA_BOOL, .as.boolean = value};
}

static AblaValue host_value_string_static(const char* data, size_t length) {
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = data,
            .length = length,
            .owned = false,
            .rope = (AblaStringRope*)0}};
}

static int64_t host_value_as_i64(AblaValue value) {
    if (value.tag != ABLA_I64) abla_platform_panic("expected i64", 12);
    return value.as.i64;
}

static const char* host_string_storage(AblaString value) {
    if (value.data != (const char*)0) return value.data;
    if (value.rope == (AblaStringRope*)0) {
        abla_platform_panic("invalid string storage", 22);
    }
    if (value.rope->flattened != (char*)0) return value.rope->flattened;

    size_t capacity = 64;
    size_t count = 1;
    AblaString* pending =
        (AblaString*)abla_platform_alloc(sizeof(AblaString) * capacity);
    abla_platform_memory_set_layout(pending, 9);
    pending[0] = value;
    if (value.length == SIZE_MAX) {
        abla_platform_free(pending);
        abla_platform_panic("string length overflow", 22);
    }
    char* flattened = (char*)abla_platform_alloc(value.length + 1);
    size_t output = 0;
    while (count != 0) {
        const AblaString current = pending[--count];
        const char* data = current.data;
        if (data == (const char*)0 && current.rope != (AblaStringRope*)0) {
            data = current.rope->flattened;
        }
        if (data != (const char*)0) {
            if (output > value.length ||
                current.length > value.length - output) {
                abla_platform_free(pending);
                abla_platform_free(flattened);
                abla_platform_panic("invalid string rope", 19);
            }
            memcpy(flattened + output, data, current.length);
            output += current.length;
            continue;
        }
        if (current.rope == (AblaStringRope*)0) {
            abla_platform_free(pending);
            abla_platform_free(flattened);
            abla_platform_panic("invalid string rope", 19);
        }
        if (count > SIZE_MAX - 2) {
            abla_platform_free(pending);
            abla_platform_free(flattened);
            abla_platform_panic("string rope is too deep", 23);
        }
        if (count + 2 > capacity) {
            if (capacity > SIZE_MAX / 2 ||
                capacity * 2 > SIZE_MAX / sizeof(AblaString)) {
                abla_platform_free(pending);
                abla_platform_free(flattened);
                abla_platform_panic("string rope is too deep", 23);
            }
            const size_t next_capacity = capacity * 2;
            AblaString* next = (AblaString*)abla_platform_alloc(
                sizeof(AblaString) * next_capacity);
            abla_platform_memory_set_layout(next, 9);
            memcpy(next, pending, sizeof(AblaString) * count);
            abla_platform_free(pending);
            pending = next;
            capacity = next_capacity;
        }
        pending[count++] = current.rope->right;
        pending[count++] = current.rope->left;
    }
    abla_platform_free(pending);
    if (output != value.length) {
        abla_platform_free(flattened);
        abla_platform_panic("invalid string rope", 19);
    }
    flattened[value.length] = '\0';
    value.rope->flattened = flattened;
    return flattened;
}

static const char* host_value_string_data(AblaValue value) {
    if (value.tag != ABLA_STRING) abla_platform_panic("expected string", 15);
    return host_string_storage(value.as.string);
}

static const char* host_value_as_cstring(AblaValue value) {
    return host_value_string_data(value);
}

static void* host_value_as_pointer(AblaValue value) {
    return (void*)(uintptr_t)(uint64_t)host_value_as_i64(value);
}

static AblaValue host_value_pointer(void* value) {
    return host_value_i64((int64_t)(uintptr_t)value);
}

static AblaValue host_value_array_create(
    const AblaValue* values,
    size_t count) {
    AblaArray* array = (AblaArray*)abla_platform_alloc(sizeof(AblaArray));
    abla_platform_memory_set_layout(array, 4);
    array->length = count;
    array->capacity = count;
    array->values = count == 0
        ? (AblaValue*)0
        : (AblaValue*)abla_platform_alloc(sizeof(AblaValue) * count);
    if (array->values != NULL) {
        abla_platform_memory_set_layout(array->values, 2);
    }
    if (count != 0) memcpy(array->values, values, sizeof(AblaValue) * count);
    return (AblaValue){.tag = ABLA_ARRAY, .as.array = array};
}

static AblaArray* host_value_as_array(AblaValue value) {
    if (value.tag != ABLA_ARRAY) abla_platform_panic("expected array", 14);
    return value.as.array;
}

static AblaValue host_value_array_length(AblaValue value) {
    const size_t length = host_value_as_array(value)->length;
    if (length > (size_t)INT64_MAX) {
        abla_platform_panic("array length does not fit in i64", 33);
    }
    return host_value_i64((int64_t)length);
}

static AblaValue host_value_array_append(AblaValue value, AblaValue element) {
    AblaArray* array = host_value_as_array(value);
    if (array->length == array->capacity) {
        if (array->capacity > SIZE_MAX / 2) {
            abla_platform_panic("array capacity overflow", 23);
        }
        const size_t next_capacity = array->capacity == 0
            ? 4
            : array->capacity * 2;
        if (next_capacity > SIZE_MAX / sizeof(AblaValue)) {
            abla_platform_panic("array capacity overflow", 23);
        }
        AblaValue* next = (AblaValue*)abla_platform_alloc(
            sizeof(AblaValue) * next_capacity);
        abla_platform_memory_set_layout(next, 2);
        if (array->length != 0) {
            memcpy(next, array->values, sizeof(AblaValue) * array->length);
        }
        abla_platform_free(array->values);
        array->values = next;
        array->capacity = next_capacity;
    }
    array->values[array->length++] = element;
    return value;
}

static AblaValue host_value_array_get(AblaValue value, AblaValue index_value) {
    AblaArray* array = host_value_as_array(value);
    const int64_t index = host_value_as_i64(index_value);
    if (index < 0 || (uint64_t)index >= array->length) {
        abla_platform_panic("array index out of bounds", 25);
    }
    return array->values[(size_t)index];
}

static void host_request_shutdown(int signal_number) {
    (void)signal_number;
    host_shutdown_requested = 1;
}

static AblaValue host_owned_string(const char* data, size_t length) {
    char* copy = (char*)abla_platform_alloc(length + 1);
    memcpy(copy, data, length);
    copy[length] = '\0';
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = copy,
            .length = length,
            .owned = true,
            .rope = (AblaStringRope*)0}};
}

void* abla_platform_alloc(size_t size) {
    const size_t measured = size == 0 ? 1 : size;
    if (measured > SIZE_MAX - sizeof(AblaAllocationHeader) ||
        host_allocation_generation >= (uint64_t)INT64_MAX ||
        measured > SIZE_MAX - host_allocation_live_bytes) {
        abla_platform_panic("allocation size overflow", 24);
    }
    if (host_allocation_live_bytes > host_allocation_limit ||
        measured > host_allocation_limit - host_allocation_live_bytes) {
        abla_platform_panic("memory limit exceeded", 21);
    }
    AblaAllocationHeader* header = (AblaAllocationHeader*)malloc(
        sizeof(AblaAllocationHeader) + measured);
    if (header == NULL) abla_platform_panic("out of memory", 13);
    header->allocation.previous = host_allocation_tail;
    header->allocation.next = NULL;
    header->allocation.generation = ++host_allocation_generation;
    header->allocation.size = measured;
    header->allocation.scan_size = measured;
    // Platform allocations are native bytes unless the caller publishes a
    // managed layout immediately after allocation.
    header->allocation.scan_layout = 1;
    if (host_allocation_tail != NULL) {
        host_allocation_tail->allocation.next = header;
    } else {
        host_allocation_head = header;
    }
    host_allocation_tail = header;
    host_allocation_live_bytes += measured;
    memset((void*)(header + 1), 0, measured);
    return (void*)(header + 1);
}

void abla_platform_free(void* pointer) {
    if (pointer == NULL) return;
    AblaAllocationHeader* header = ((AblaAllocationHeader*)pointer) - 1;
    if (header->allocation.previous != NULL) {
        header->allocation.previous->allocation.next = header->allocation.next;
    } else {
        host_allocation_head = header->allocation.next;
    }
    if (header->allocation.next != NULL) {
        header->allocation.next->allocation.previous =
            header->allocation.previous;
    } else {
        host_allocation_tail = header->allocation.previous;
    }
    host_allocation_live_bytes -= header->allocation.size;
    free(header);
}

void abla_platform_memory_set_scan(void* pointer, int64_t scan_size) {
    if (pointer == NULL || scan_size < 0) {
        abla_platform_panic("invalid memory scan size", 24);
    }
    AblaAllocationHeader* header = ((AblaAllocationHeader*)pointer) - 1;
    if ((uint64_t)scan_size > header->allocation.size) {
        abla_platform_panic("invalid memory scan size", 24);
    }
    header->allocation.scan_size = (size_t)scan_size;
}

void abla_platform_memory_set_layout(void* pointer, int64_t layout) {
    if (pointer == NULL || layout < 0 || layout > 10) {
        abla_platform_panic("invalid memory scan layout", 26);
    }
    AblaAllocationHeader* header = ((AblaAllocationHeader*)pointer) - 1;
    header->allocation.scan_layout = (uint8_t)layout;
}

_Noreturn void abla_platform_panic(const char* message, size_t length) {
    fputs("abla panic: ", stderr);
    fwrite(message, 1, length, stderr);
    fputc('\n', stderr);
    abort();
}

void abla_host_set_arguments(int argc, char** argv) {
    host_argc = argc;
    host_argv = argv;
    host_envp = argv == NULL ? NULL : argv + (size_t)argc + 1;
}

AblaValue ablaUnsafeAllocate(AblaValue size_value) {
    const int64_t size = host_value_as_i64(size_value);
    if (size < 0) abla_platform_panic("negative allocation size", 24);
    return host_value_pointer(abla_platform_alloc((size_t)size));
}

AblaValue ablaUnsafeFree(AblaValue pointer) {
    abla_platform_free(host_value_as_pointer(pointer));
    return host_value_void();
}

AblaValue ablaUnsafeLoadI64(AblaValue address) {
    int64_t value = 0;
    memcpy(&value, host_value_as_pointer(address), sizeof(value));
    return host_value_i64(value);
}

AblaValue ablaUnsafeStoreI64(AblaValue address, AblaValue value) {
    const int64_t stored = host_value_as_i64(value);
    memcpy(host_value_as_pointer(address), &stored, sizeof(stored));
    return host_value_void();
}

AblaValue ablaUnsafeLoadPointer(AblaValue address) {
    void* value = NULL;
    memcpy(&value, host_value_as_pointer(address), sizeof(value));
    return host_value_pointer(value);
}

AblaValue ablaUnsafeStorePointer(AblaValue address, AblaValue value) {
    void* stored = host_value_as_pointer(value);
    memcpy(host_value_as_pointer(address), &stored, sizeof(stored));
    return host_value_void();
}

AblaValue ablaUnsafeNullPointer(void) {
    return host_value_i64(INT64_C(0));
}

AblaValue ablaUnsafePointerIsNull(AblaValue value) {
    return host_value_bool(host_value_as_i64(value) == 0);
}

AblaValue ablaUnsafeCallMain(AblaValue address) {
    typedef int (*AblaNativeMain)(int, char**);
    const uintptr_t bits = (uintptr_t)(uint64_t)host_value_as_i64(address);
    AblaNativeMain entry = NULL;
    _Static_assert(sizeof(entry) == sizeof(bits), "function pointer size");
    memcpy(&entry, &bits, sizeof(entry));
    return host_value_i64((int64_t)entry(0, NULL));
}

AblaValue ablaUnsafeCStringAddress(AblaValue value) {
    return host_value_i64(
        (int64_t)(uintptr_t)host_value_as_cstring(value));
}

AblaValue ablaUnsafePointerAddress(AblaValue value) {
    (void)host_value_as_pointer(value);
    return value;
}

AblaValue ablaUnsafePointerOffset(AblaValue value, AblaValue offset) {
    const uint64_t base = (uint64_t)host_value_as_i64(value);
    const int64_t displacement = host_value_as_i64(offset);
    return host_value_i64((int64_t)(base + (uint64_t)displacement));
}

AblaValue ablaUnsafeLoadU8(AblaValue address) {
    const uint8_t value = *(const uint8_t*)host_value_as_pointer(address);
    return host_value_i64((int64_t)value);
}

AblaValue ablaUnsafeStoreU8(AblaValue address, AblaValue value) {
    *(uint8_t*)host_value_as_pointer(address) =
        (uint8_t)host_value_as_i64(value);
    return host_value_void();
}

AblaValue ablaUnsafeAdoptString(AblaValue address, AblaValue length_value) {
    const int64_t length = host_value_as_i64(length_value);
    if (length < 0) abla_platform_panic("negative string length", 22);
    char* data = (char*)host_value_as_pointer(address);
    data[(size_t)length] = '\0';
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = data,
            .length = (size_t)length,
            .owned = true,
            .rope = (AblaStringRope*)0}};
}

AblaValue ablaUnsafeBorrowCString(AblaValue address) {
    const char* text = (const char*)host_value_as_pointer(address);
    return host_value_string_static(text, strlen(text));
}

AblaValue ablaLinuxSyscall(
    AblaValue number,
    AblaValue argument0,
    AblaValue argument1,
    AblaValue argument2,
    AblaValue argument3,
    AblaValue argument4,
    AblaValue argument5) {
    const long result = syscall(
        (long)host_value_as_i64(number),
        (long)host_value_as_i64(argument0),
        (long)host_value_as_i64(argument1),
        (long)host_value_as_i64(argument2),
        (long)host_value_as_i64(argument3),
        (long)host_value_as_i64(argument4),
        (long)host_value_as_i64(argument5));
    if (result == -1) return host_value_i64(-(int64_t)errno);
    return host_value_i64((int64_t)result);
}

AblaValue ablaLinuxArgumentCount(void) {
    return host_value_i64(host_argc > 0 ? (int64_t)(host_argc - 1) : 0);
}

AblaValue ablaLinuxArgument(AblaValue index_value) {
    const int64_t index = host_value_as_i64(index_value);
    const int64_t count = host_argc > 0 ? (int64_t)(host_argc - 1) : 0;
    if (index < 0 || index >= count) {
        abla_platform_panic("argument index out of bounds", 28);
    }
    const char* value = host_argv[(size_t)index + 1];
    return host_value_string_static(value, strlen(value));
}

AblaValue ablaLinuxEnvironmentPointer(void) {
    return host_value_pointer(host_envp);
}

AblaValue ablaHostArgumentCount(void) {
    return host_value_i64(host_argc > 0 ? (int64_t)(host_argc - 1) : INT64_C(0));
}

AblaValue ablaHostArgument(AblaValue index_value) {
    const int64_t index = host_value_as_i64(index_value);
    if (index < 0 || index >= (int64_t)(host_argc > 0 ? host_argc - 1 : 0)) {
        abla_platform_panic("argument index out of bounds", 28);
    }
    const char* value = host_argv[(size_t)index + 1];
    return host_value_string_static(value, strlen(value));
}

AblaValue ablaHostReadStdinLine(void) {
    char* line = NULL;
    size_t capacity = 0;
    const ssize_t measured = getline(&line, &capacity, stdin);
    if (measured < 0) {
        free(line);
        host_stdin_line_available = false;
        return host_value_string_static("", 0);
    }
    size_t length = (size_t)measured;
    if (length > 0 && line[length - 1] == '\n') --length;
    if (length > 0 && line[length - 1] == '\r') --length;
    const AblaValue result = host_owned_string(line, length);
    free(line);
    host_stdin_line_available = true;
    return result;
}

AblaValue ablaHostStdinLineAvailable(void) {
    return host_value_bool(host_stdin_line_available);
}

AblaValue ablaHostReadFile(AblaValue path_value) {
    const char* path = host_value_as_cstring(path_value);
    FILE* stream = fopen(path, "rb");
    if (stream == NULL) abla_platform_panic("cannot open input file", 22);
    if (fseek(stream, 0, SEEK_END) != 0) {
        fclose(stream);
        abla_platform_panic("cannot seek input file", 22);
    }
    const long measured = ftell(stream);
    if (measured < 0 || fseek(stream, 0, SEEK_SET) != 0) {
        fclose(stream);
        abla_platform_panic("cannot measure input file", 25);
    }
    const size_t length = (size_t)measured;
    char* text = (char*)abla_platform_alloc(length + 1);
    if (fread(text, 1, length, stream) != length) {
        fclose(stream);
        abla_platform_free(text);
        abla_platform_panic("cannot read input file", 22);
    }
    fclose(stream);
    text[length] = '\0';
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = text,
            .length = length,
            .owned = true,
            .rope = (AblaStringRope*)0}};
}

AblaValue ablaHostWriteFile(AblaValue path_value, AblaValue contents) {
    if (path_value.tag != ABLA_STRING || contents.tag != ABLA_STRING) {
        abla_platform_panic("expected path and contents", 26);
    }
    const char* path = host_value_as_cstring(path_value);
    FILE* stream = fopen(path, "wb");
    if (stream == NULL) abla_platform_panic("cannot open output file", 23);
    const char* data = host_value_string_data(contents);
    if (fwrite(data, 1, contents.as.string.length, stream) !=
        contents.as.string.length || fclose(stream) != 0) {
        abla_platform_panic("cannot write output file", 24);
    }
    return host_value_void();
}

AblaValue ablaHostWriteFileAtomic(AblaValue path_value, AblaValue contents) {
    if (path_value.tag != ABLA_STRING || contents.tag != ABLA_STRING) {
        abla_platform_panic("expected path and contents", 26);
    }
    const char* path = host_value_as_cstring(path_value);
    const size_t path_length = path_value.as.string.length;
    static const char suffix[] = ".tmp.XXXXXX";
    char* temporary = (char*)abla_platform_alloc(path_length + sizeof(suffix));
    memcpy(temporary, path, path_length);
    memcpy(temporary + path_length, suffix, sizeof(suffix));
    const int descriptor = mkstemp(temporary);
    if (descriptor < 0) {
        abla_platform_free(temporary);
        return host_value_bool(false);
    }
    const char* data = host_value_string_data(contents);
    size_t written = 0;
    bool success = true;
    while (written < contents.as.string.length) {
        const ssize_t amount = write(
            descriptor,
            data + written,
            contents.as.string.length - written);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) {
            success = false;
            break;
        }
        written += (size_t)amount;
    }
    if (success && fsync(descriptor) != 0) success = false;
    if (close(descriptor) != 0) success = false;
    if (success && rename(temporary, path) != 0) success = false;
    if (!success) unlink(temporary);
    abla_platform_free(temporary);
    return host_value_bool(success);
}

static bool host_create_directories(const char* path, size_t length) {
    char* scratch = (char*)abla_platform_alloc(length + 1);
    memcpy(scratch, path, length);
    scratch[length] = '\0';
    for (size_t index = 1; index <= length; ++index) {
        if (index < length && scratch[index] != '/') continue;
        const char saved = scratch[index];
        scratch[index] = '\0';
        if (scratch[0] != '\0' && mkdir(scratch, 0777) != 0 && errno != EEXIST) {
            abla_platform_free(scratch);
            return false;
        }
        scratch[index] = saved;
    }
    abla_platform_free(scratch);
    return true;
}

AblaValue ablaHostCreateParentDirectories(AblaValue path_value) {
    if (path_value.tag != ABLA_STRING) {
        abla_platform_panic("expected path", 13);
    }
    const char* path = host_value_as_cstring(path_value);
    const size_t length = path_value.as.string.length;
    char* scratch = (char*)abla_platform_alloc(length + 1);
    memcpy(scratch, path, length + 1);
    for (size_t index = 1; index < length; ++index) {
        if (scratch[index] != '/') continue;
        scratch[index] = '\0';
        if (mkdir(scratch, 0777) != 0 && errno != EEXIST) {
            abla_platform_free(scratch);
            abla_platform_panic("cannot create output directory", 30);
        }
        scratch[index] = '/';
    }
    abla_platform_free(scratch);
    return host_value_void();
}

AblaValue ablaHostCreateDirectories(AblaValue path_value) {
    if (path_value.tag != ABLA_STRING) {
        abla_platform_panic("expected path", 13);
    }
    return host_value_bool(host_create_directories(
        host_value_as_cstring(path_value), path_value.as.string.length));
}

AblaValue ablaHostFileKind(AblaValue path_value) {
    if (path_value.tag != ABLA_STRING) abla_platform_panic("expected path", 13);
    struct stat status;
    if (stat(host_value_as_cstring(path_value), &status) != 0) return host_value_i64(0);
    if (S_ISREG(status.st_mode)) return host_value_i64(1);
    if (S_ISDIR(status.st_mode)) return host_value_i64(2);
    return host_value_i64(3);
}

AblaValue ablaHostFileSize(AblaValue path_value) {
    if (path_value.tag != ABLA_STRING) abla_platform_panic("expected path", 13);
    struct stat status;
    if (stat(host_value_as_cstring(path_value), &status) != 0) return host_value_i64(-1);
    return host_value_i64((int64_t)status.st_size);
}

AblaValue ablaHostListDirectory(AblaValue path_value) {
    if (path_value.tag != ABLA_STRING) abla_platform_panic("expected path", 13);
    DIR* directory = opendir(host_value_as_cstring(path_value));
    if (directory == NULL) abla_platform_panic("cannot list directory", 21);
    AblaValue entries = host_value_array_create(NULL, 0);
    struct dirent* entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        (void)host_value_array_append(
            entries,
            host_owned_string(entry->d_name, strlen(entry->d_name)));
    }
    closedir(directory);
    return entries;
}

AblaValue ablaHostMoveFile(AblaValue source, AblaValue destination) {
    if (source.tag != ABLA_STRING || destination.tag != ABLA_STRING) {
        abla_platform_panic("expected paths", 14);
    }
    return host_value_bool(rename(
        host_value_as_cstring(source), host_value_as_cstring(destination)) == 0);
}

AblaValue ablaHostRemoveFile(AblaValue path_value) {
    if (path_value.tag != ABLA_STRING) abla_platform_panic("expected path", 13);
    const char* path = host_value_as_cstring(path_value);
    if (unlink(path) == 0) return host_value_bool(true);
    if ((errno == EISDIR || errno == EPERM) && rmdir(path) == 0) {
        return host_value_bool(true);
    }
    return host_value_bool(false);
}

AblaValue ablaHostCurrentDirectory(void) {
    size_t capacity = 256;
    while (capacity <= 1024 * 1024) {
        char* buffer = (char*)abla_platform_alloc(capacity);
        if (getcwd(buffer, capacity) != NULL) {
            const AblaValue result = host_owned_string(buffer, strlen(buffer));
            abla_platform_free(buffer);
            return result;
        }
        abla_platform_free(buffer);
        if (errno != ERANGE) break;
        capacity *= 2;
    }
    abla_platform_panic("cannot read current directory", 29);
}

static char** host_process_arguments(AblaValue arguments, size_t* count) {
    if (arguments.tag != ABLA_ARRAY) {
        abla_platform_panic("expected process arguments", 26);
    }
    const int64_t measured = host_value_as_i64(host_value_array_length(arguments));
    if (measured <= 0) {
        abla_platform_panic("process arguments are empty", 27);
    }
    *count = (size_t)measured;
    char** values = (char**)abla_platform_alloc((*count + 1) * sizeof(char*));
    for (size_t index = 0; index < *count; ++index) {
        AblaValue value = host_value_array_get(arguments, host_value_i64((int64_t)index));
        if (value.tag != ABLA_STRING) {
            abla_platform_free(values);
            abla_platform_panic("process argument is not a string", 32);
        }
        values[index] = (char*)host_value_as_cstring(value);
    }
    values[*count] = NULL;
    return values;
}

static int64_t host_wait_process(pid_t process) {
    int status = 0;
    while (waitpid(process, &status, 0) < 0) {
        if (errno != EINTR) return 127;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 127;
}

static int64_t host_decode_process_status(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 127;
}

AblaValue ablaHostStartProcess(AblaValue arguments) {
    size_t count = 0;
    char** values = host_process_arguments(arguments, &count);
    (void)count;
    const pid_t process = fork();
    if (process < 0) {
        abla_platform_free(values);
        abla_platform_panic("cannot start process", 20);
    }
    if (process == 0) {
        execvp(values[0], values);
        _exit(127);
    }
    abla_platform_free(values);
    return host_value_i64((int64_t)process);
}

AblaValue ablaHostRunProcess(AblaValue arguments) {
    const AblaValue process = ablaHostStartProcess(arguments);
    return host_value_i64(host_wait_process((pid_t)host_value_as_i64(process)));
}

AblaValue ablaHostCaptureProcess(AblaValue arguments) {
    size_t count = 0;
    char** values = host_process_arguments(arguments, &count);
    (void)count;
    int descriptors[2];
    if (pipe(descriptors) != 0) {
        abla_platform_free(values);
        abla_platform_panic("cannot create process pipe", 27);
    }
    const pid_t process = fork();
    if (process < 0) {
        close(descriptors[0]);
        close(descriptors[1]);
        abla_platform_free(values);
        abla_platform_panic("cannot start captured process", 30);
    }
    if (process == 0) {
        close(descriptors[0]);
        if (dup2(descriptors[1], STDOUT_FILENO) < 0) _exit(127);
        close(descriptors[1]);
        execvp(values[0], values);
        _exit(127);
    }
    close(descriptors[1]);
    abla_platform_free(values);

    size_t length = 0;
    size_t capacity = 4096;
    char* buffer = (char*)abla_platform_alloc(capacity);
    for (;;) {
        if (length == capacity) {
            if (capacity > SIZE_MAX / 2) {
                close(descriptors[0]);
                abla_platform_free(buffer);
                abla_platform_panic("captured process output is too large", 37);
            }
            const size_t next_capacity = capacity * 2;
            char* next = (char*)abla_platform_alloc(next_capacity);
            memcpy(next, buffer, length);
            abla_platform_free(buffer);
            buffer = next;
            capacity = next_capacity;
        }
        const ssize_t measured = read(
            descriptors[0], buffer + length, capacity - length);
        if (measured < 0 && errno == EINTR) continue;
        if (measured < 0) {
            close(descriptors[0]);
            abla_platform_free(buffer);
            (void)host_wait_process(process);
            abla_platform_panic("cannot read captured process", 29);
        }
        if (measured == 0) break;
        length += (size_t)measured;
    }
    close(descriptors[0]);
    if (host_wait_process(process) != 0) {
        abla_platform_free(buffer);
        abla_platform_panic("captured process failed", 23);
    }
    const AblaValue result = host_owned_string(buffer, length);
    abla_platform_free(buffer);
    return result;
}

AblaValue ablaHostStopProcess(AblaValue process_value) {
    return ablaHostStopProcessGracefully(process_value, host_value_i64(5000));
}

AblaValue ablaHostStopProcessGracefully(
    AblaValue process_value,
    AblaValue grace_value) {
    const int64_t raw = host_value_as_i64(process_value);
    if (raw <= 0) return host_value_i64(0);
    const int64_t grace_milliseconds = host_value_as_i64(grace_value);
    if (grace_milliseconds < 0 || grace_milliseconds > 60000) {
        abla_platform_panic("invalid process stop grace period", 33);
    }
    const pid_t process = (pid_t)raw;
    if (kill(process, SIGTERM) != 0 && errno != ESRCH) return host_value_i64(127);
    int status = 0;
    int64_t elapsed = 0;
    while (elapsed < grace_milliseconds) {
        const pid_t waited = waitpid(process, &status, WNOHANG);
        if (waited == process) return host_value_i64(host_decode_process_status(status));
        if (waited < 0 && errno == ECHILD) return host_value_i64(0);
        if (waited < 0 && errno != EINTR) return host_value_i64(127);
        struct timespec duration = {.tv_sec = 0, .tv_nsec = 10000000};
        while (nanosleep(&duration, &duration) != 0 && errno == EINTR) {}
        elapsed += 10;
    }
    if (kill(process, SIGKILL) != 0 && errno != ESRCH) return host_value_i64(127);
    return host_value_i64(host_wait_process(process));
}

AblaValue ablaHostFileRevision(AblaValue path_value) {
    if (path_value.tag != ABLA_STRING) {
        abla_platform_panic("expected path", 13);
    }
    FILE* stream = fopen(host_value_as_cstring(path_value), "rb");
    if (stream == NULL) return host_value_i64(-1);
    uint64_t hash = UINT64_C(1469598103934665603);
    unsigned char buffer[4096];
    size_t measured = 0;
    while ((measured = fread(buffer, 1, sizeof(buffer), stream)) > 0) {
        for (size_t index = 0; index < measured; ++index) {
            hash ^= buffer[index];
            hash *= UINT64_C(1099511628211);
        }
    }
    if (ferror(stream) != 0 || fclose(stream) != 0) return host_value_i64(-1);
    return host_value_i64((int64_t)hash);
}

AblaValue ablaHostSleep(AblaValue milliseconds_value) {
    const int64_t milliseconds = host_value_as_i64(milliseconds_value);
    if (milliseconds < 0) abla_platform_panic("negative sleep duration", 23);
    struct timespec duration = {
        .tv_sec = (time_t)(milliseconds / 1000),
        .tv_nsec = (long)((milliseconds % 1000) * 1000000)};
    while (nanosleep(&duration, &duration) != 0 && errno == EINTR) {}
    return host_value_void();
}

AblaValue ablaHostTcpListen(AblaValue port_value, AblaValue backlog_value) {
    const int64_t port = host_value_as_i64(port_value);
    const int64_t backlog = host_value_as_i64(backlog_value);
    if (port < 0 || port > 65535 || backlog < 1 || backlog > INT32_MAX) {
        abla_platform_panic("invalid TCP listener options", 28);
    }
    const int descriptor = socket(AF_INET, SOCK_STREAM, 0);
    if (descriptor < 0) abla_platform_panic("cannot create TCP socket", 24);
    const int enabled = 1;
    if (setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &enabled,
            sizeof(enabled)) != 0) {
        close(descriptor);
        abla_platform_panic("cannot configure TCP socket", 27);
    }
    const struct sockaddr_in address = {
        .sin_family = AF_INET,
        .sin_port = htons((uint16_t)port),
        .sin_addr = {.s_addr = htonl(INADDR_ANY)},
        .sin_zero = {0}};
    if (bind(
            descriptor,
            (const struct sockaddr*)&address,
            sizeof(address)) != 0 ||
        listen(descriptor, (int)backlog) != 0) {
        close(descriptor);
        abla_platform_panic("cannot bind TCP listener", 25);
    }
    return host_value_i64(descriptor);
}

AblaValue ablaHostTcpAccept(AblaValue listener_value) {
    const int listener = (int)host_value_as_i64(listener_value);
    int connection = -1;
    do {
        connection = accept(listener, NULL, NULL);
    } while (connection < 0 && errno == EINTR && !host_shutdown_requested);
    if (connection < 0 && errno == EINTR && host_shutdown_requested) {
        return host_value_i64(-1);
    }
    if (connection < 0) abla_platform_panic("cannot accept TCP connection", 29);
    return host_value_i64(connection);
}

AblaValue ablaHostTcpLocalPort(AblaValue listener_value) {
    const int listener = (int)host_value_as_i64(listener_value);
    struct sockaddr_in address;
    socklen_t length = sizeof(address);
    if (getsockname(listener, (struct sockaddr*)&address, &length) != 0 ||
        length < sizeof(address)) {
        abla_platform_panic("cannot inspect TCP listener", 27);
    }
    return host_value_i64((int64_t)ntohs(address.sin_port));
}

AblaValue ablaHostTcpRead(AblaValue connection_value, AblaValue maximum_value) {
    const int connection = (int)host_value_as_i64(connection_value);
    const int64_t maximum = host_value_as_i64(maximum_value);
    if (maximum < 1 || maximum > 16 * 1024 * 1024) {
        abla_platform_panic("invalid TCP read size", 21);
    }
    char* buffer = (char*)abla_platform_alloc((size_t)maximum + 1);
    ssize_t measured = -1;
    do {
        measured = read(connection, buffer, (size_t)maximum);
    } while (measured < 0 && errno == EINTR);
    if (measured < 0) {
        abla_platform_free(buffer);
        abla_platform_panic("cannot read TCP connection", 27);
    }
    buffer[(size_t)measured] = '\0';
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = buffer,
            .length = (size_t)measured,
            .owned = true,
            .rope = (AblaStringRope*)0}};
}

AblaValue ablaHostTcpWrite(AblaValue connection_value, AblaValue contents) {
    const int connection = (int)host_value_as_i64(connection_value);
    if (contents.tag != ABLA_STRING) abla_platform_panic("expected string", 15);
    const char* data = host_value_string_data(contents);
    size_t written = 0;
    while (written < contents.as.string.length) {
        const ssize_t amount = write(
            connection,
            data + written,
            contents.as.string.length - written);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) return host_value_i64((int64_t)written);
        written += (size_t)amount;
    }
    return host_value_i64((int64_t)written);
}

AblaValue ablaHostTcpClose(AblaValue descriptor_value) {
    const int descriptor = (int)host_value_as_i64(descriptor_value);
    return host_value_bool(close(descriptor) == 0);
}

AblaValue ablaHostEnableGracefulShutdown(void) {
    host_shutdown_requested = 0;
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = host_request_shutdown;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0) {
        abla_platform_panic("cannot configure graceful shutdown", 34);
    }
    return host_value_void();
}

AblaValue ablaHostShutdownRequested(void) {
    return host_value_bool(host_shutdown_requested != 0);
}

AblaValue ablaHostMemoryCheckpoint(void) {
    return host_value_i64((int64_t)host_allocation_generation);
}

AblaValue ablaHostMemoryReset(AblaValue checkpoint_value) {
    const int64_t checkpoint = host_value_as_i64(checkpoint_value);
    if (checkpoint < 0 || (uint64_t)checkpoint > host_allocation_generation) {
        abla_platform_panic("invalid memory checkpoint", 25);
    }
    while (host_allocation_tail != NULL &&
        host_allocation_tail->allocation.generation > (uint64_t)checkpoint) {
        abla_platform_free((void*)(host_allocation_tail + 1));
    }
    return host_value_void();
}

AblaValue ablaHostMemoryLiveBytes(void) {
    if (host_allocation_live_bytes > (size_t)INT64_MAX) {
        abla_platform_panic("live allocation count overflow", 30);
    }
    return host_value_i64((int64_t)host_allocation_live_bytes);
}

AblaValue ablaHostMemoryLimit(void) {
    if (host_allocation_limit > (size_t)INT64_MAX) {
        abla_platform_panic("memory limit overflow", 21);
    }
    return host_value_i64((int64_t)host_allocation_limit);
}

AblaValue ablaHostMemorySetLimit(AblaValue limit_value) {
    const int64_t limit = host_value_as_i64(limit_value);
    if (limit < 0 || (uint64_t)limit < host_allocation_live_bytes) {
        abla_platform_panic("invalid memory limit", 20);
    }
    host_allocation_limit = (size_t)limit;
    return host_value_void();
}

AblaValue ablaRuntimeMemoryCheckpoint(void) {
    return ablaHostMemoryCheckpoint();
}

AblaValue ablaRuntimeMemoryReset(AblaValue checkpoint) {
    return ablaHostMemoryReset(checkpoint);
}

AblaValue ablaRuntimeMemoryLiveBytes(void) {
    return ablaHostMemoryLiveBytes();
}

AblaValue ablaRuntimeMemoryLimit(void) {
    return ablaHostMemoryLimit();
}

AblaValue ablaRuntimeMemorySetLimit(AblaValue limit) {
    return ablaHostMemorySetLimit(limit);
}

int64_t abla_platform_memory_checkpoint(void) {
    return (int64_t)host_allocation_generation;
}

void abla_platform_memory_reset(int64_t checkpoint) {
    (void)ablaHostMemoryReset(host_value_i64(checkpoint));
}

int64_t abla_platform_memory_live_bytes(void) {
    return (int64_t)host_allocation_live_bytes;
}

typedef struct AblaRuntimeRootFrame AblaRuntimeRootFrame;
struct AblaRuntimeRootFrame {
    AblaRuntimeRootFrame* previous;
    void** roots;
    uint64_t count;
};

static bool host_mark_pointer(uintptr_t candidate) {
    AblaAllocationHeader* header = host_allocation_tail;
    while (header != NULL) {
        if ((uintptr_t)(header + 1) == candidate) {
            if ((header->allocation.generation >> 63) != 0) return false;
            header->allocation.generation |= UINT64_C(1) << 63;
            return true;
        }
        header = header->allocation.previous;
    }
    return false;
}

static bool host_mark_words(const void* bytes, size_t size) {
    bool changed = false;
    size_t offset = 0;
    while (offset <= size && sizeof(uintptr_t) <= size - offset) {
        uintptr_t candidate = 0;
        memcpy(&candidate, (const unsigned char*)bytes + offset,
            sizeof(candidate));
        if (host_mark_pointer(candidate)) changed = true;
        offset += sizeof(uintptr_t);
    }
    return changed;
}

static bool host_mark_value(const AblaValue* value) {
    bool changed = false;
    if (value->tag == ABLA_STRING) {
        if (host_mark_pointer((uintptr_t)value->as.string.data)) changed = true;
        if (host_mark_pointer((uintptr_t)value->as.string.rope)) changed = true;
    } else if (value->tag == ABLA_FUNCTION) {
        changed = host_mark_pointer((uintptr_t)value->as.function.captures);
    } else if (value->tag == ABLA_CELL) {
        changed = host_mark_pointer((uintptr_t)value->as.cell);
    } else if (value->tag == ABLA_ARRAY) {
        changed = host_mark_pointer((uintptr_t)value->as.array);
    } else if (value->tag == ABLA_OBJECT) {
        changed = host_mark_pointer((uintptr_t)value->as.object);
    } else if (value->tag == ABLA_SHARED) {
        changed = host_mark_pointer((uintptr_t)value->as.shared);
    } else if (value->tag == ABLA_WEAK) {
        changed = host_mark_pointer((uintptr_t)value->as.weak);
    }
    return changed;
}

static bool host_mark_pointer_slot(const unsigned char* bytes, size_t offset) {
    uintptr_t candidate = 0;
    memcpy(&candidate, bytes + offset, sizeof(candidate));
    return host_mark_pointer(candidate);
}

static bool host_mark_allocation(const AblaAllocationHeader* header) {
    const unsigned char* payload = (const unsigned char*)(header + 1);
    const size_t size = header->allocation.scan_size;
    const uint8_t layout = header->allocation.scan_layout;
    bool changed = false;
    if (layout == 1) return false;
    if (layout == 2) {
        for (size_t offset = 0; offset + sizeof(AblaValue) <= size;
             offset += sizeof(AblaValue)) {
            if (host_mark_value((const AblaValue*)(payload + offset))) {
                changed = true;
            }
        }
        return changed;
    }
    if (layout == 3) {
        for (size_t offset = 0; offset + 48 <= size; offset += 48) {
            if (host_mark_value((const AblaValue*)(payload + offset + 8))) {
                changed = true;
            }
        }
        return changed;
    }
    if (layout == 4 && size >= 24) return host_mark_pointer_slot(payload, 16);
    if (layout == 5 && size >= 32) return host_mark_pointer_slot(payload, 24);
    if (layout == 6 && size >= 72) {
        const size_t offsets[] = {0, 24, 32, 56, 64};
        for (size_t index = 0; index < sizeof(offsets) / sizeof(offsets[0]);
             ++index) {
            if (host_mark_pointer_slot(payload, offsets[index])) changed = true;
        }
        return changed;
    }
    if (layout == 7 && size >= 56) {
        return host_mark_value((const AblaValue*)(payload + 16));
    }
    if (layout == 8 && size >= sizeof(AblaValue)) {
        return host_mark_value((const AblaValue*)payload);
    }
    if (layout == 9) {
        for (size_t offset = 0; offset + 32 <= size; offset += 32) {
            if (host_mark_pointer_slot(payload, offset)) changed = true;
            if (host_mark_pointer_slot(payload, offset + 24)) changed = true;
        }
        return changed;
    }
    return host_mark_words(payload, size);
}

int64_t abla_platform_memory_collect(void* opaque_frames) {
    const size_t before = host_allocation_live_bytes;
    AblaRuntimeRootFrame* frame = (AblaRuntimeRootFrame*)opaque_frames;
    while (frame != NULL) {
        for (uint64_t root = 0; root < frame->count; ++root) {
            host_mark_value((const AblaValue*)frame->roots[root]);
        }
        frame = frame->previous;
    }
    bool changed = true;
    while (changed) {
        changed = false;
        AblaAllocationHeader* header = host_allocation_tail;
        while (header != NULL) {
            if ((header->allocation.generation >> 63) != 0 &&
                host_mark_allocation(header)) {
                changed = true;
            }
            header = header->allocation.previous;
        }
    }
    AblaAllocationHeader* header = host_allocation_tail;
    while (header != NULL) {
        AblaAllocationHeader* previous = header->allocation.previous;
        if ((header->allocation.generation >> 63) != 0 ||
            header->allocation.scan_layout == 10) {
            header->allocation.generation &= INT64_MAX;
        } else {
            abla_platform_free((void*)(header + 1));
        }
        header = previous;
    }
    const size_t freed = before - host_allocation_live_bytes;
    if (freed > (size_t)INT64_MAX) {
        abla_platform_panic("collection size overflow", 24);
    }
    return (int64_t)freed;
}

int64_t abla_platform_memory_limit(void) {
    return (int64_t)host_allocation_limit;
}

void abla_platform_memory_set_limit(int64_t limit) {
    (void)ablaHostMemorySetLimit(host_value_i64(limit));
}

AblaValue ablaRuntimeMemoryCollect(void) {
    // Seed-C calls have no compiler-emitted root frame. They are used only at
    // explicit test/evaluator boundaries where generation regions remain the
    // reclamation mechanism; native LLVM lowers this intrinsic directly.
    return host_value_i64(0);
}

AblaValue ablaHostWriteStdout(AblaValue text) {
    if (text.tag != ABLA_STRING) {
        abla_platform_panic("expected string", 15);
    }
    if (fwrite(host_value_string_data(text), 1, text.as.string.length, stdout) !=
        text.as.string.length) {
        abla_platform_panic("cannot write standard output", 28);
    }
    if (fflush(stdout) != 0) {
        abla_platform_panic("cannot flush standard output", 28);
    }
    return host_value_void();
}

AblaValue ablaHostWriteStderr(AblaValue text) {
    if (text.tag != ABLA_STRING) {
        abla_platform_panic("expected string", 15);
    }
    if (fwrite(host_value_string_data(text), 1, text.as.string.length, stderr) !=
        text.as.string.length) {
        abla_platform_panic("cannot write standard error", 27);
    }
    return host_value_void();
}
