#ifndef ABLA_RUNTIME_H
#define ABLA_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum AblaTag {
    ABLA_VOID,
    ABLA_NULL,
    ABLA_I64,
    ABLA_BOOL,
    ABLA_STRING,
    ABLA_FUNCTION,
    ABLA_CELL,
    ABLA_ARRAY,
    ABLA_OBJECT,
    ABLA_SHARED,
    ABLA_WEAK,
    ABLA_GENERATOR,
    ABLA_TASK,
    ABLA_THREAD
} AblaTag;

typedef struct AblaValue AblaValue;
typedef struct AblaArray AblaArray;
typedef struct AblaObject AblaObject;
typedef struct AblaStringRope AblaStringRope;
typedef struct AblaSharedControl AblaSharedControl;
typedef struct AblaRuntimeRootFrame AblaRuntimeRootFrame;

typedef struct AblaString {
    const char* data;
#ifdef ABLA_WASM32
    uint32_t data_padding;
#endif
#if defined(ABLA_VALUE_ABI32)
    size_t length;
#ifdef ABLA_WASM32
    uint32_t length_padding;
#endif
    union {
        const char* owner;
        AblaStringRope* rope;
        uint64_t abi_word;
    };
#elif defined(ABLA_VALUE_ABI40)
    size_t length;
#ifdef ABLA_WASM32
    uint32_t length_padding;
#endif
    const char* owner;
#ifdef ABLA_WASM32
    uint32_t owner_padding;
#endif
    AblaStringRope* rope;
#ifdef ABLA_WASM32
    uint32_t rope_padding;
#endif
#else
    union {
        size_t length;
        AblaStringRope* rope;
        uint64_t abi_word;
    };
#endif
} AblaString;

#define ABLA_STRING_ROPE(value) ((value).rope)

struct AblaStringRope {
    size_t length;
    AblaString left;
    AblaString right;
    char* flattened;
};

#if defined(ABLA_VALUE_ABI32) || defined(ABLA_VALUE_ABI40)
#define ABLA_STRING_LENGTH(value) ((value).length)
#define ABLA_STRING_ROPE_INITIALIZER(length_value, rope_value) \
    .data = (const char*)0, .length = (length_value), .rope = (rope_value)
#else
#define ABLA_STRING_LENGTH(value) \
    ((value).data == (const char*)0 \
        ? ABLA_STRING_ROPE(value)->length \
        : (value).length)
#define ABLA_STRING_ROPE_INITIALIZER(length_value, rope_value) \
    .data = (const char*)0, .rope = (rope_value)
#endif

struct AblaValue {
    AblaTag tag;
#if !defined(ABLA_VALUE_ABI32) && !defined(ABLA_VALUE_ABI40)
    uint32_t auxiliary;
#endif
    union {
        int64_t i64;
        bool boolean;
        struct {
#if defined(ABLA_VALUE_ABI32) || defined(ABLA_VALUE_ABI40)
            uint32_t id;
#ifdef ABLA_WASM32
            uint32_t id_padding;
#endif
#endif
            size_t capture_count;
#ifdef ABLA_WASM32
            uint32_t capture_count_padding;
#endif
            AblaValue* captures;
#ifdef ABLA_WASM32
            uint32_t captures_padding;
#endif
        } function;
        AblaValue* cell;
        AblaString string;
        AblaArray* array;
        AblaObject* object;
        AblaSharedControl* shared;
        AblaSharedControl* weak;
        void* concurrent;
    } as;
};

#if defined(ABLA_VALUE_ABI32) || defined(ABLA_VALUE_ABI40)
#define ABLA_FUNCTION_ID(value) ((value).as.function.id)
#define ABLA_VALUE_FUNCTION_INITIALIZER(function) \
    .as.function = {.id = (function),
#else
#define ABLA_FUNCTION_ID(value) ((value).auxiliary)
#define ABLA_VALUE_FUNCTION_INITIALIZER(function) \
    .auxiliary = (function), .as.function = {
#endif

#ifdef ABLA_WASM32
#ifdef ABLA_VALUE_ABI40
_Static_assert(sizeof(AblaString) == 32, "Wasm ABI40 string must be 32 bytes");
_Static_assert(sizeof(AblaValue) == 40, "Wasm ABI40 value must be 40 bytes");
#elif defined(ABLA_VALUE_ABI32)
_Static_assert(sizeof(AblaString) == 24, "Wasm ABI32 string must be 24 bytes");
_Static_assert(sizeof(AblaValue) == 32, "Wasm ABI32 value must be 32 bytes");
#else
_Static_assert(sizeof(AblaString) == 16, "Wasm string ABI must be 16 bytes");
_Static_assert(sizeof(AblaValue) == 24, "Wasm value ABI must be 24 bytes");
#endif
#else
#ifdef ABLA_VALUE_ABI40
_Static_assert(sizeof(AblaString) == 32, "Native ABI40 string must be 32 bytes");
_Static_assert(sizeof(AblaValue) == 40, "Native ABI40 value must be 40 bytes");
#elif defined(ABLA_VALUE_ABI32)
_Static_assert(sizeof(AblaString) == 24, "Native ABI32 string must be 24 bytes");
_Static_assert(sizeof(AblaValue) == 32, "Native ABI32 value must be 32 bytes");
#else
_Static_assert(sizeof(AblaString) == 16, "Native string ABI must be 16 bytes");
_Static_assert(sizeof(AblaValue) == 24, "Native value ABI must be 24 bytes");
#endif
#endif

typedef AblaValue (*AblaDispatch)(
    const AblaValue* closure,
    const AblaValue* arguments,
    uint64_t count);
typedef void (*AblaClosureCleanup)(const AblaValue* closure);

struct AblaRuntimeRootFrame {
    AblaRuntimeRootFrame* previous;
    void** roots;
    uint64_t count;
};

void* abla_platform_alloc(size_t size);
void abla_platform_free(void* pointer);
_Noreturn void abla_platform_panic(const char* message, uint64_t length);

AblaValue abla_void(void);
AblaValue abla_null(void);
AblaValue abla_i64(int64_t value);
AblaValue abla_bool(bool value);
AblaValue abla_string_static(const char* data, size_t length);
AblaValue abla_function(uint32_t function);
AblaValue abla_closure(
    uint32_t function,
    const AblaValue* captures,
    uint64_t capture_count);

void abla_runtime_set_arguments(int argc, char** argv);
AblaValue ablaHostIsMacOS(void);
AblaValue ablaHostValueArgumentsIndirect(void);
AblaValue ablaHostArgumentCount(void);
AblaValue ablaHostArgument(AblaValue index);
AblaValue ablaHostReadFile(AblaValue path);
AblaValue ablaHostWriteFile(AblaValue path, AblaValue contents);
AblaValue ablaHostWriteFileAtomic(AblaValue path, AblaValue contents);
AblaValue ablaHostCreateParentDirectories(AblaValue path);
AblaValue ablaHostCreateDirectories(AblaValue path);
AblaValue ablaHostFileKind(AblaValue path);
AblaValue ablaHostFileSize(AblaValue path);
AblaValue ablaHostListDirectory(AblaValue path);
AblaValue ablaHostMoveFile(AblaValue source, AblaValue destination);
AblaValue ablaHostRemoveFile(AblaValue path);
AblaValue ablaHostCurrentDirectory(void);
AblaValue ablaHostReadStdinLine(void);
AblaValue ablaHostStdinLineAvailable(void);
AblaValue ablaHostWriteStdout(AblaValue text);
AblaValue ablaHostWriteStderr(AblaValue text);
AblaValue ablaHostRunProcess(AblaValue arguments);
AblaValue ablaHostCaptureProcess(AblaValue arguments);
AblaValue ablaHostStartProcess(AblaValue arguments);
AblaValue ablaHostStartProcessConfigured(
    AblaValue directory,
    AblaValue arguments,
    AblaValue environment_names,
    AblaValue environment_values,
    AblaValue output_path);
AblaValue ablaHostPollProcess(AblaValue process);
AblaValue ablaHostStopProcessTree(
    AblaValue process,
    AblaValue grace_milliseconds);
AblaValue ablaHostMonotonicMilliseconds(void);
AblaValue ablaHostProcessorCount(void);
AblaValue ablaHostStopProcess(AblaValue process);
AblaValue ablaHostStopProcessGracefully(
    AblaValue process,
    AblaValue grace_milliseconds);
AblaValue ablaHostSleep(AblaValue milliseconds);
AblaValue ablaHostFileRevision(AblaValue path);
AblaValue ablaHostTcpListen(AblaValue port, AblaValue backlog);
AblaValue ablaHostTcpAccept(AblaValue listener);
AblaValue ablaHostTcpLocalPort(AblaValue listener);
AblaValue ablaHostTcpRead(AblaValue connection, AblaValue maximum);
AblaValue ablaHostTcpWrite(AblaValue connection, AblaValue contents);
AblaValue ablaHostTcpClose(AblaValue descriptor);
AblaValue ablaHostNetConnect(AblaValue host, AblaValue port, AblaValue timeout);
AblaValue ablaHostNetListen(
    AblaValue host, AblaValue port, AblaValue backlog, AblaValue dual_stack);
AblaValue ablaHostNetAccept(AblaValue listener);
AblaValue ablaHostNetSetNonblocking(AblaValue descriptor, AblaValue enabled);
AblaValue ablaHostNetLocalPort(AblaValue descriptor);
AblaValue ablaHostNetRead(AblaValue descriptor, AblaValue maximum);
AblaValue ablaHostNetWrite(AblaValue descriptor, AblaValue contents);
AblaValue ablaHostNetStatus(void);
AblaValue ablaHostNetError(void);
AblaValue ablaHostNetClose(AblaValue descriptor);
AblaValue ablaHostNetUdpBind(
    AblaValue host, AblaValue port, AblaValue dual_stack);
AblaValue ablaHostNetUdpSend(
    AblaValue descriptor, AblaValue host, AblaValue port, AblaValue contents);
AblaValue ablaHostNetUdpReceive(AblaValue descriptor, AblaValue maximum);
AblaValue ablaHostNetSourceAddress(void);
AblaValue ablaHostNetSourcePort(void);
AblaValue ablaHostNetPollerCreate(void);
AblaValue ablaHostNetPollerControl(
    AblaValue poller, AblaValue descriptor, AblaValue readable,
    AblaValue writable, AblaValue operation);
AblaValue ablaHostNetPollerWait(
    AblaValue poller, AblaValue maximum, AblaValue timeout);
AblaValue ablaHostTlsAvailable(void);
AblaValue ablaHostTlsOpen(AblaValue host, AblaValue port, AblaValue timeout);
AblaValue ablaHostTlsOpenWithCa(
    AblaValue host, AblaValue port, AblaValue timeout, AblaValue ca_path);
AblaValue ablaHostTlsRead(AblaValue handle, AblaValue maximum);
AblaValue ablaHostTlsWrite(AblaValue handle, AblaValue contents);
AblaValue ablaHostTlsClose(AblaValue handle);
AblaValue ablaHostTlsError(void);
AblaValue ablaHostTlsListen(
    AblaValue host, AblaValue port, AblaValue backlog, AblaValue dual_stack,
    AblaValue certificate_path, AblaValue private_key_path);
AblaValue ablaHostTlsListenerPort(AblaValue handle);
AblaValue ablaHostTlsAccept(AblaValue handle);
AblaValue ablaHostTlsListenerClose(AblaValue handle);
AblaValue ablaHostEnableGracefulShutdown(void);
AblaValue ablaHostShutdownRequested(void);
AblaValue ablaHostMemoryCheckpoint(void);
AblaValue ablaHostMemoryReset(AblaValue checkpoint);
AblaValue ablaHostMemoryLiveBytes(void);
AblaValue ablaHostMemoryLimit(void);
AblaValue ablaHostMemorySetLimit(AblaValue limit);

// Runtime adapters for Abla's unsafe-memory and raw-Linux intrinsics. The
// direct LLVM backend calls this stable ABI on both hosted and raw targets.
AblaValue ablaUnsafeAllocate(AblaValue size);
AblaValue ablaUnsafeFree(AblaValue pointer);
AblaValue ablaUnsafeLoadI64(AblaValue address);
AblaValue ablaUnsafeStoreI64(AblaValue address, AblaValue value);
AblaValue ablaUnsafeLoadPointer(AblaValue address);
AblaValue ablaUnsafeStorePointer(AblaValue address, AblaValue value);
AblaValue ablaUnsafeNullPointer(void);
AblaValue ablaUnsafePointerIsNull(AblaValue value);
AblaValue ablaUnsafeCallMain(AblaValue address);
AblaValue ablaUnsafeCStringAddress(AblaValue value);
AblaValue ablaUnsafePointerAddress(AblaValue value);
AblaValue ablaUnsafePointerOffset(AblaValue value, AblaValue offset);
AblaValue ablaUnsafeLoadU8(AblaValue address);
AblaValue ablaUnsafeStoreU8(AblaValue address, AblaValue value);
AblaValue ablaUnsafeAdoptString(AblaValue address, AblaValue length);
AblaValue ablaUnsafeBorrowCString(AblaValue address);
AblaValue ablaLinuxTcpReadCompact(AblaValue descriptor, AblaValue maximum);
AblaValue ablaLinuxPollWaitCompact(
    AblaValue descriptor,
    AblaValue maximum,
    AblaValue timeout);
AblaValue ablaBitAnd(AblaValue left, AblaValue right);
AblaValue ablaBitOr(AblaValue left, AblaValue right);
AblaValue ablaBitXor(AblaValue left, AblaValue right);
AblaValue ablaBitNot(AblaValue value);
AblaValue ablaBitShiftLeft(AblaValue value, AblaValue count);
AblaValue ablaBitShiftRight(AblaValue value, AblaValue count);
AblaValue ablaBitShiftRightUnsigned(AblaValue value, AblaValue count);
AblaValue ablaByteEncode(AblaValue value);
AblaValue ablaLinuxSyscall(
    AblaValue number,
    AblaValue argument0,
    AblaValue argument1,
    AblaValue argument2,
    AblaValue argument3,
    AblaValue argument4,
    AblaValue argument5);
AblaValue ablaLinuxArgumentCount(void);
AblaValue ablaLinuxArgument(AblaValue index);
AblaValue ablaLinuxEnvironmentPointer(void);
AblaValue ablaRuntimeMemoryCheckpoint(void);
AblaValue ablaRuntimeMemoryReset(AblaValue checkpoint);
AblaValue ablaRuntimeMemoryLiveBytes(void);
AblaValue ablaRuntimeMemoryLimit(void);
AblaValue ablaRuntimeMemorySetLimit(AblaValue limit);
AblaValue ablaRuntimeMemoryCollect(void);
AblaValue ablaRuntimeMemoryPromoteString(AblaValue value);
AblaValue ablaRuntimeRegionBegin(void);
AblaValue ablaRuntimeRegionEnd(AblaValue checkpoint);
int64_t abla_platform_memory_checkpoint(void);
void abla_platform_memory_reset(int64_t checkpoint);
int64_t abla_platform_memory_live_bytes(void);
int64_t abla_platform_memory_limit(void);
void abla_platform_memory_set_limit(int64_t limit);
void abla_platform_memory_set_scan(void* pointer, int64_t scan_size);
void abla_platform_memory_set_layout(void* pointer, int64_t layout);
void abla_platform_memory_set_cache_owner(void* pointer, void* owner);
int8_t ablaCompilerTypeNeedsNormalization(
    const char* type,
    int64_t length
);
int64_t abla_platform_memory_collect(void* root_frames);
void abla_runtime_roots_push(
    AblaRuntimeRootFrame* frame,
    void** roots,
    uint64_t count);
void abla_runtime_roots_pop(AblaRuntimeRootFrame* frame);
void abla_runtime_memory_pressure(void);

AblaValue abla_generator_create(
    AblaValue closure,
    AblaDispatch dispatch,
    AblaClosureCleanup release,
    AblaClosureCleanup drop);
AblaValue abla_generator_next(AblaValue generator);
AblaValue abla_generator_value(AblaValue generator);
AblaValue abla_generator_yield(AblaValue value);
AblaValue abla_generator_drop(AblaValue generator);
AblaValue abla_task_create(
    AblaValue closure,
    AblaDispatch dispatch,
    AblaClosureCleanup release,
    AblaClosureCleanup drop);
AblaValue abla_task_drop(AblaValue task);
AblaValue abla_thread_create(
    AblaValue closure,
    AblaDispatch dispatch,
    AblaClosureCleanup release,
    AblaClosureCleanup drop);
AblaValue abla_thread_drop(AblaValue thread);
AblaValue abla_await(AblaValue operation);

int64_t abla_as_i64(AblaValue value);
bool abla_as_bool(AblaValue value);
const char* abla_as_cstring(AblaValue value);
const char* abla_string_data(AblaValue value);
uint32_t abla_as_function(AblaValue value);
uint64_t abla_function_capture_count(AblaValue value);
AblaValue* abla_function_capture_pointer(AblaValue value);
AblaValue abla_function_capture(AblaValue value, uint64_t index);
void abla_closure_release(AblaValue value);
void* abla_owned_bytes_from_value(AblaValue value);
const uint8_t* abla_owned_bytes_data(void* handle);
uint64_t abla_owned_bytes_length(void* handle);
void abla_owned_bytes_release(void* handle);
int32_t abla_checked_invoke(
    void* function,
    const AblaValue* arguments,
    uint64_t count,
    AblaValue* result,
    uint8_t* error_data,
    uint64_t error_capacity,
    uint64_t* error_length);
AblaValue abla_cell_create(AblaValue value);
AblaValue abla_cell_get(AblaValue cell);
AblaValue abla_cell_set(AblaValue cell, AblaValue value);
AblaValue abla_shared_create(AblaValue value);
AblaValue abla_shared_clone(AblaValue value);
AblaValue abla_shared_get(AblaValue value);
AblaValue abla_shared_lock(AblaValue value);
void abla_shared_unlock(AblaValue value);
AblaValue abla_shared_release(AblaValue value);
AblaValue abla_weak_create(AblaValue value);
AblaValue abla_weak_clone(AblaValue value);
AblaValue abla_weak_upgrade(AblaValue value);
AblaValue abla_weak_alive(AblaValue value);
AblaValue abla_weak_release(AblaValue value);

AblaValue abla_negate(AblaValue value);
AblaValue abla_not(AblaValue value);
AblaValue abla_add(AblaValue left, AblaValue right);
AblaValue abla_subtract(AblaValue left, AblaValue right);
AblaValue abla_multiply(AblaValue left, AblaValue right);
AblaValue abla_divide(AblaValue left, AblaValue right);
AblaValue abla_equal(AblaValue left, AblaValue right);
AblaValue abla_not_equal(AblaValue left, AblaValue right);
AblaValue abla_string_equal(AblaValue left, AblaValue right);
AblaValue abla_string_not_equal(AblaValue left, AblaValue right);
bool abla_string_equal_bool(AblaValue left, AblaValue right);
bool abla_string_not_equal_bool(AblaValue left, AblaValue right);
AblaValue abla_less(AblaValue left, AblaValue right);
AblaValue abla_less_equal(AblaValue left, AblaValue right);
AblaValue abla_greater(AblaValue left, AblaValue right);
AblaValue abla_greater_equal(AblaValue left, AblaValue right);

AblaValue abla_to_string(AblaValue value);
AblaValue abla_string_concat(AblaValue left, AblaValue right);
AblaValue abla_string_length(AblaValue value);
AblaValue abla_string_get(AblaValue value, AblaValue index);
int64_t abla_string_length_i64(AblaValue value);
int64_t abla_string_get_i64(AblaValue value, int64_t index);
AblaValue abla_string_slice(AblaValue value, AblaValue begin, AblaValue end);
AblaValue ablaUtf8EncodeScalar(AblaValue value);
AblaValue ablaTextFindSequence(
    AblaValue text,
    AblaValue sequence,
    AblaValue begin,
    AblaValue end);
AblaValue ablaTextFindByte(
    AblaValue text,
    AblaValue byte,
    AblaValue begin,
    AblaValue end);
AblaValue ablaTextAsciiEqualInsensitive(AblaValue left, AblaValue right);
AblaValue ablaTextReadU32LittleEndian(AblaValue text, AblaValue offset);
AblaValue ablaTextIsValidUtf8(AblaValue text);
AblaValue abla_length(AblaValue value);
AblaValue abla_index_get(AblaValue value, AblaValue index);
AblaValue abla_array_create(const AblaValue* values, size_t count);
AblaValue abla_array_length(AblaValue value);
int64_t abla_array_length_i64(AblaValue value);
AblaValue abla_array_append(AblaValue value, AblaValue element);
AblaValue abla_array_get(AblaValue array, AblaValue index);
int64_t abla_array_get_i64(AblaValue array, int64_t index);
bool abla_array_get_bool(AblaValue array, int64_t index);
void abla_array_set(AblaValue array, AblaValue index, AblaValue value);
AblaValue abla_object_create(uint32_t type_symbol, size_t field_count);
AblaValue abla_field_get(AblaValue object, uint32_t field_symbol);
AblaValue abla_field_get_indexed(
    AblaValue object,
    uint32_t field_symbol,
    size_t field_index);
int64_t abla_field_get_indexed_i64(
    AblaValue object,
    uint32_t field_symbol,
    size_t field_index);
bool abla_field_get_indexed_bool(
    AblaValue object,
    uint32_t field_symbol,
    size_t field_index);
void abla_field_initialize(
    AblaValue object,
    uint32_t field_symbol,
    AblaValue value);
void abla_field_set(AblaValue object, uint32_t field_symbol, AblaValue value);
void abla_field_set_indexed(
    AblaValue object,
    uint32_t field_symbol,
    size_t field_index,
    AblaValue value);

#endif
