#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "abla_runtime.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <setjmp.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <crt_externs.h>
#include <sys/event.h>
#else
#include <sys/epoll.h>
#endif

#if defined(__GNUC__) || defined(__clang__)
#define ABLA_HOST_FALLBACK __attribute__((weak))
#else
#define ABLA_HOST_FALLBACK
#endif

static int host_argc;
static char** host_argv;
static char** host_envp;
static bool host_stdin_line_available;
static volatile sig_atomic_t host_shutdown_requested;

typedef struct ssl_ctx_st HostSslContext;
typedef struct ssl_st HostSsl;
typedef const void HostSslMethod;

typedef struct AblaHostTlsConnection {
    HostSslContext* context;
    HostSsl* ssl;
    int descriptor;
    bool owns_context;
} AblaHostTlsConnection;

typedef struct AblaHostTlsListener {
    HostSslContext* context;
    int descriptor;
} AblaHostTlsListener;

static void* host_ssl_library;
static const HostSslMethod* (*host_TLS_client_method)(void);
static const HostSslMethod* (*host_TLS_server_method)(void);
static HostSslContext* (*host_SSL_CTX_new)(const HostSslMethod*);
static void (*host_SSL_CTX_free)(HostSslContext*);
static int (*host_SSL_CTX_set_default_verify_paths)(HostSslContext*);
static int (*host_SSL_CTX_load_verify_locations)(
    HostSslContext*, const char*, const char*);
static int (*host_SSL_CTX_use_certificate_chain_file)(
    HostSslContext*, const char*);
static int (*host_SSL_CTX_use_PrivateKey_file)(
    HostSslContext*, const char*, int);
static int (*host_SSL_CTX_check_private_key)(const HostSslContext*);
static void (*host_SSL_CTX_set_verify)(HostSslContext*, int, void*);
static HostSsl* (*host_SSL_new)(HostSslContext*);
static void (*host_SSL_free)(HostSsl*);
static long (*host_SSL_ctrl)(HostSsl*, int, long, void*);
static int (*host_SSL_set1_host)(HostSsl*, const char*);
static int (*host_SSL_set_fd)(HostSsl*, int);
static int (*host_SSL_connect)(HostSsl*);
static int (*host_SSL_accept)(HostSsl*);
static int (*host_SSL_read)(HostSsl*, void*, int);
static int (*host_SSL_write)(HostSsl*, const void*, int);
static int (*host_SSL_shutdown)(HostSsl*);
static long (*host_SSL_get_verify_result)(const HostSsl*);
static char host_tls_error[256];
static _Thread_local int host_net_status;
static _Thread_local int host_net_error;
static _Thread_local char host_net_source[INET6_ADDRSTRLEN];
static _Thread_local int host_net_source_port;

static void host_set_tls_error(const char* message) {
    (void)snprintf(host_tls_error, sizeof(host_tls_error), "%s", message);
}

typedef struct AblaHostRegion AblaHostRegion;
typedef union AblaAllocationHeader AblaAllocationHeader;
union AblaAllocationHeader {
    struct {
        AblaAllocationHeader* previous;
        AblaAllocationHeader* next;
        AblaHostRegion* region;
        uint64_t generation;
        size_t size;
        size_t scan_size;
        uint8_t scan_layout;
        AblaStringRope* cache_owner;
    } allocation;
    max_align_t alignment;
};

typedef struct AblaHostRegionPage {
    struct AblaHostRegionPage* next;
    size_t used;
    size_t capacity;
    unsigned char* data;
} AblaHostRegionPage;

struct AblaHostRegion {
    uint64_t checkpoint;
    AblaAllocationHeader* head;
    AblaAllocationHeader* tail;
    AblaHostRegionPage* pages;
    size_t live_bytes;
};

static AblaAllocationHeader* host_allocation_head;
static AblaAllocationHeader* host_allocation_tail;
static uint64_t host_allocation_generation;
static size_t host_allocation_live_bytes;
// The standalone default remains one GiB. The guarded compiler launcher may
// publish a stricter or larger process budget through ABLA_MAX_MEMORY_MB; use
// the same value for the tracked heap so native pressure decisions agree with
// the enforced address-space envelope.
static size_t host_allocation_limit = (size_t)1024 * 1024 * 1024;
static bool host_allocation_limit_initialized;
static _Thread_local AblaRuntimeRootFrame* host_root_frame;
// Keep young short-lived allocation batches small. Large 256 MiB batches made
// request-heavy services spend disproportionate time sorting and returning a
// huge fragmented heap to malloc during each pressure collection.
static size_t host_collection_threshold = (size_t)32 * 1024 * 1024;
#define HOST_REGION_MAXIMUM_DEPTH 64
#define HOST_REGION_PAGE_BYTES ((size_t)1024 * 1024)
#define HOST_REGION_CACHED_PAGES 32
static _Thread_local AblaHostRegion
    host_regions[HOST_REGION_MAXIMUM_DEPTH];
static _Thread_local size_t host_region_depth;
static _Thread_local AblaHostRegionPage* host_region_page_cache;
static _Thread_local size_t host_region_page_cache_count;
static _Thread_local bool host_region_override_active;
static _Thread_local AblaHostRegion* host_region_override;
static pthread_mutex_t host_heap_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_size_t host_active_threads;
typedef struct AblaCheckedFrame {
    jmp_buf jump;
    struct AblaCheckedFrame* previous;
    const char* message;
    size_t length;
} AblaCheckedFrame;
static _Thread_local AblaCheckedFrame* host_checked_frame;
static AblaAllocationHeader** host_collection_index;
static size_t host_collection_index_count;
static size_t host_collection_index_capacity;
static AblaAllocationHeader** host_mark_worklist;
static size_t host_mark_worklist_count;

static bool host_heap_lock_if_shared(void) {
    if (atomic_load_explicit(
            &host_active_threads, memory_order_acquire) == 0) return false;
    (void)pthread_mutex_lock(&host_heap_lock);
    return true;
}

static void host_heap_unlock_if_shared(bool locked) {
    if (locked) (void)pthread_mutex_unlock(&host_heap_lock);
}

typedef enum AblaHostCoroutineState {
    ABLA_COROUTINE_CREATED,
    ABLA_COROUTINE_RUNNING,
    ABLA_COROUTINE_SUSPENDED,
    ABLA_COROUTINE_DONE
} AblaHostCoroutineState;

typedef struct AblaHostCoroutine {
    AblaValue closure;
    AblaValue current;
    AblaValue result;
    AblaDispatch dispatch;
    AblaClosureCleanup release;
    AblaClosureCleanup drop;
    AblaRuntimeRootFrame* roots;
    AblaRuntimeRootFrame* caller_roots;
    void* stack;
    size_t stack_size;
    AblaHostCoroutineState state;
    bool generator;
    bool cancelled;
    ucontext_t context;
    ucontext_t caller;
} AblaHostCoroutine;

typedef struct AblaHostThread {
    AblaValue closure;
    AblaValue result;
    AblaDispatch dispatch;
    AblaClosureCleanup release;
    AblaClosureCleanup drop;
    pthread_t native;
    bool joined;
} AblaHostThread;

static _Thread_local AblaHostCoroutine* host_current_coroutine;

static void host_initialize_allocation_limit(void) {
    if (host_allocation_limit_initialized) return;
    host_allocation_limit_initialized = true;
    const char* configured = getenv("ABLA_MAX_MEMORY_MB");
    if (configured == NULL || configured[0] == '\0') return;
    size_t megabytes = 0;
    size_t index = 0;
    while (configured[index] != '\0') {
        const unsigned char byte = (unsigned char)configured[index];
        if (byte < (unsigned char)'0' || byte > (unsigned char)'9') {
            abla_platform_panic("invalid ABLA_MAX_MEMORY_MB", 26);
        }
        const size_t digit = (size_t)(byte - (unsigned char)'0');
        if (megabytes > (SIZE_MAX - digit) / 10) {
            abla_platform_panic("ABLA_MAX_MEMORY_MB overflow", 27);
        }
        megabytes = megabytes * 10 + digit;
        ++index;
    }
    if (megabytes == 0 || megabytes > SIZE_MAX / ((size_t)1024 * 1024)) {
        abla_platform_panic("invalid ABLA_MAX_MEMORY_MB", 26);
    }
    host_allocation_limit = megabytes * (size_t)1024 * 1024;
}

// Private value-ABI helpers used only by the C platform adapter. Production
// LLVM modules provide their own Abla-authored value runtime; keeping this
// bridge private lets native links omit the legacy abla_runtime.c object.
struct AblaArray {
    size_t length;
    size_t capacity;
    AblaValue* values;
};

typedef struct AblaField {
    uint32_t symbol;
    AblaValue value;
} AblaField;

struct AblaObject {
    uint32_t type_symbol;
    size_t count;
    size_t capacity;
    AblaField* fields;
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
            .storage.owner = NULL}};
}

static int64_t host_value_as_i64(AblaValue value) {
    if (value.tag != ABLA_I64) abla_platform_panic("expected i64", 12);
    return value.as.i64;
}

static const char* host_string_storage(AblaString value) {
    if (value.data != (const char*)0) return value.data;
    if (ABLA_STRING_ROPE(value) == (AblaStringRope*)0) {
        abla_platform_panic("invalid string storage", 22);
    }
    if (ABLA_STRING_ROPE(value)->flattened != (char*)0) {
        return ABLA_STRING_ROPE(value)->flattened;
    }

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
        if (data == (const char*)0 &&
            ABLA_STRING_ROPE(current) != (AblaStringRope*)0) {
            data = ABLA_STRING_ROPE(current)->flattened;
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
        if (ABLA_STRING_ROPE(current) == (AblaStringRope*)0) {
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
        pending[count++] = ABLA_STRING_ROPE(current)->right;
        pending[count++] = ABLA_STRING_ROPE(current)->left;
    }
    abla_platform_free(pending);
    if (output != value.length) {
        abla_platform_free(flattened);
        abla_platform_panic("invalid string rope", 19);
    }
    flattened[value.length] = '\0';
    ABLA_STRING_ROPE(value)->flattened = flattened;
    abla_platform_memory_set_cache_owner(flattened, ABLA_STRING_ROPE(value));
    return flattened;
}

static const char* host_value_string_data(AblaValue value) {
    if (value.tag != ABLA_STRING) abla_platform_panic("expected string", 15);
    return host_string_storage(value.as.string);
}

static const char* host_value_as_cstring(AblaValue value) {
    const char* data = host_value_string_data(value);
    if (data[value.as.string.length] == '\0') return data;
    char* terminated = (char*)abla_platform_alloc(value.as.string.length + 1);
    memcpy(terminated, data, value.as.string.length);
    terminated[value.as.string.length] = '\0';
    return terminated;
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
    if (count > (SIZE_MAX - sizeof(AblaArray)) / sizeof(AblaValue)) {
        abla_platform_panic("array allocation overflow", 25);
    }
    AblaArray* array = (AblaArray*)abla_platform_alloc(
        sizeof(AblaArray) + count * sizeof(AblaValue));
    abla_platform_memory_set_layout(array, 4);
    array->length = count;
    array->capacity = count;
    array->values = count == 0 ? NULL : (AblaValue*)(array + 1);
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
        if (array->values != (AblaValue*)(array + 1)) {
            abla_platform_free(array->values);
        }
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
            .storage.owner = copy}};
}

static AblaHostRegionPage* host_region_page_acquire(size_t minimum) {
    AblaHostRegionPage* page = NULL;
    size_t capacity = HOST_REGION_PAGE_BYTES;
    if (minimum <= HOST_REGION_PAGE_BYTES &&
        host_region_page_cache != NULL) {
        page = host_region_page_cache;
        host_region_page_cache = page->next;
        --host_region_page_cache_count;
    } else {
        if (capacity < minimum) capacity = minimum;
        const size_t alignment = _Alignof(max_align_t);
        if (capacity > SIZE_MAX - sizeof(*page) - alignment) {
            abla_platform_panic("region allocation overflow", 26);
        }
        page = (AblaHostRegionPage*)malloc(
            sizeof(*page) + capacity + alignment - 1);
        if (page == NULL) abla_platform_panic("out of memory", 13);
        const uintptr_t bytes = (uintptr_t)(page + 1);
        page->data = (unsigned char*)(
            (bytes + alignment - 1) & ~(uintptr_t)(alignment - 1));
        page->capacity = capacity;
    }
    page->next = NULL;
    page->used = 0;
    return page;
}

static void host_region_pages_release(AblaHostRegionPage* page) {
    while (page != NULL) {
        AblaHostRegionPage* next = page->next;
        if (page->capacity == HOST_REGION_PAGE_BYTES &&
            host_region_page_cache_count < HOST_REGION_CACHED_PAGES) {
            page->used = 0;
            page->next = host_region_page_cache;
            host_region_page_cache = page;
            ++host_region_page_cache_count;
        } else {
            free(page);
        }
        page = next;
    }
}

static AblaAllocationHeader* host_region_allocate(
    AblaHostRegion* region,
    size_t measured) {
    const size_t alignment = _Alignof(max_align_t);
    if (measured > SIZE_MAX - sizeof(AblaAllocationHeader) - alignment) {
        abla_platform_panic("region allocation overflow", 26);
    }
    const size_t required = sizeof(AblaAllocationHeader) + measured;
    AblaHostRegionPage* page = region->pages;
    size_t offset = 0;
    if (page != NULL) {
        offset = (page->used + alignment - 1) & ~(alignment - 1);
    }
    if (page == NULL || offset > page->capacity ||
        required > page->capacity - offset) {
        page = host_region_page_acquire(required + alignment - 1);
        page->next = region->pages;
        region->pages = page;
        offset = 0;
    }
    AblaAllocationHeader* header =
        (AblaAllocationHeader*)(void*)(page->data + offset);
    page->used = offset + required;
    return header;
}

static int64_t host_region_begin(void) {
    if (host_region_depth >= HOST_REGION_MAXIMUM_DEPTH) {
        abla_platform_panic("region nesting limit exceeded", 29);
    }
    AblaHostRegion* region = &host_regions[host_region_depth++];
    memset(region, 0, sizeof(*region));
    region->checkpoint = host_allocation_generation;
    return (int64_t)region->checkpoint;
}

static bool host_region_reset(uint64_t checkpoint) {
    if (host_region_depth == 0) return false;
    AblaHostRegion* region = &host_regions[host_region_depth - 1];
    if (region->checkpoint != checkpoint) {
        abla_platform_panic("regions must reset in LIFO order", 32);
    }
    if (host_allocation_live_bytes < region->live_bytes) {
        abla_platform_panic("region accounting underflow", 27);
    }
    host_allocation_live_bytes -= region->live_bytes;
    host_region_pages_release(region->pages);
    memset(region, 0, sizeof(*region));
    --host_region_depth;
    return true;
}

void* abla_platform_alloc(size_t size) {
    const bool heap_locked = host_heap_lock_if_shared();
    host_initialize_allocation_limit();
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
    AblaHostRegion* region = host_region_override_active
        ? host_region_override
        : (host_region_depth == 0
            ? NULL
            : &host_regions[host_region_depth - 1]);
    AblaAllocationHeader* header = region == NULL
        ? (AblaAllocationHeader*)malloc(
            sizeof(AblaAllocationHeader) + measured)
        : host_region_allocate(region, measured);
    if (header == NULL) abla_platform_panic("out of memory", 13);
    header->allocation.previous = region == NULL
        ? host_allocation_tail
        : region->tail;
    header->allocation.next = NULL;
    header->allocation.region = region;
    header->allocation.generation = ++host_allocation_generation;
    header->allocation.size = measured;
    header->allocation.scan_size = measured;
    // Platform allocations are native bytes unless the caller publishes a
    // managed layout immediately after allocation.
    header->allocation.scan_layout = 1;
    header->allocation.cache_owner = NULL;
    if (region != NULL) {
        if (region->tail != NULL) {
            region->tail->allocation.next = header;
        } else region->head = header;
        region->tail = header;
        region->live_bytes += measured;
    } else if (host_allocation_tail != NULL) {
        host_allocation_tail->allocation.next = header;
    } else {
        host_allocation_head = header;
    }
    if (region == NULL) host_allocation_tail = header;
    host_allocation_live_bytes += measured;
    memset((void*)(header + 1), 0, measured);
    void* result = (void*)(header + 1);
    host_heap_unlock_if_shared(heap_locked);
    return result;
}

static void host_platform_free_unlocked(void* pointer) {
    if (pointer == NULL) return;
    AblaAllocationHeader* header = ((AblaAllocationHeader*)pointer) - 1;
    AblaHostRegion* region = header->allocation.region;
    if (header->allocation.previous != NULL) {
        header->allocation.previous->allocation.next = header->allocation.next;
    } else {
        if (region == NULL) host_allocation_head = header->allocation.next;
        else region->head = header->allocation.next;
    }
    if (header->allocation.next != NULL) {
        header->allocation.next->allocation.previous =
            header->allocation.previous;
    } else {
        if (region == NULL) host_allocation_tail =
            header->allocation.previous;
        else region->tail = header->allocation.previous;
    }
    host_allocation_live_bytes -= header->allocation.size;
    if (region == NULL) free(header);
    else {
        region->live_bytes -= header->allocation.size;
        header->allocation.size = 0;
    }
}

void abla_platform_free(void* pointer) {
    if (pointer == NULL) return;
    const bool heap_locked = host_heap_lock_if_shared();
    host_platform_free_unlocked(pointer);
    host_heap_unlock_if_shared(heap_locked);
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
    if (pointer == NULL || layout < 0 || layout > 12) {
        abla_platform_panic("invalid memory scan layout", 26);
    }
    AblaAllocationHeader* header = ((AblaAllocationHeader*)pointer) - 1;
    header->allocation.scan_layout = (uint8_t)layout;
}

void abla_platform_memory_set_cache_owner(void* pointer, void* owner) {
    if (pointer == NULL || owner == NULL) {
        abla_platform_panic("invalid cache owner", 19);
    }
    AblaAllocationHeader* header = ((AblaAllocationHeader*)pointer) - 1;
    header->allocation.cache_owner = (AblaStringRope*)owner;
}

_Noreturn void abla_platform_panic(const char* message, uint64_t length) {
    if (host_checked_frame != NULL) {
        host_checked_frame->message = message;
        host_checked_frame->length = length;
        longjmp(host_checked_frame->jump, 1);
    }
    fputs("abla panic: ", stderr);
    fwrite(message, 1, length, stderr);
    fputc('\n', stderr);
    abort();
}

int32_t abla_checked_invoke(
    void* opaque_function,
    const AblaValue* arguments,
    uint64_t count,
    AblaValue* result,
    uint8_t* error_data,
    uint64_t error_capacity,
    uint64_t* error_length) {
    if (result == NULL || error_length == NULL ||
        (error_data == NULL && error_capacity != 0)) return 2;
    typedef void (*AblaGeneratedFunction)(
        AblaValue*, const AblaValue*, uint64_t);
    AblaCheckedFrame frame = {
        .previous = host_checked_frame,
        .message = NULL,
        .length = 0
    };
    host_checked_frame = &frame;
    if (setjmp(frame.jump) == 0) {
        ((AblaGeneratedFunction)opaque_function)(
            result, arguments, count);
        host_checked_frame = frame.previous;
        *error_length = 0;
        return 0;
    }
    host_checked_frame = frame.previous;
    *error_length = (uint64_t)frame.length;
    const size_t copied = error_capacity < frame.length
        ? (size_t)error_capacity
        : frame.length;
    if (copied != 0) memcpy(error_data, frame.message, copied);
    return 1;
}

void abla_runtime_set_arguments(int argc, char** argv) {
    host_argc = argc;
    host_argv = argv;
#if defined(__APPLE__)
    host_envp = *_NSGetEnviron();
#else
    host_envp = argv == NULL ? NULL : argv + (size_t)argc + 1;
#endif
}

AblaValue ablaUnsafeAllocate(AblaValue size_value) {
    const int64_t size = host_value_as_i64(size_value);
    if (size < 0) abla_platform_panic("negative allocation size", 24);
    void* pointer = abla_platform_alloc((size_t)size);
    // Unsafe pointers are represented as integers and therefore cannot be
    // discovered by the managed-value marker. Their lifetime is explicitly
    // controlled by unsafeFree/adoption, so keep them out of GC sweeping.
    abla_platform_memory_set_layout(pointer, 10);
    return host_value_pointer(pointer);
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
    // ablaUnsafeAllocate pins native buffers because an integer pointer is not
    // visible to the managed marker. Adoption transfers that allocation into
    // a normal string value, so it must become collectible once the string is
    // unreachable. Leaving layout 10 here leaked every adopted socket read.
    abla_platform_memory_set_layout(data, 1);
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = data,
            .length = (size_t)length,
            .storage.owner = data}};
}

AblaValue ablaUnsafeBorrowCString(AblaValue address) {
    const char* text = (const char*)host_value_as_pointer(address);
    return host_value_string_static(text, strlen(text));
}

AblaValue ablaLinuxTcpReadCompact(
    AblaValue descriptor_value,
    AblaValue maximum_value) {
    const int descriptor = (int)host_value_as_i64(descriptor_value);
    const int64_t maximum = host_value_as_i64(maximum_value);
    if (descriptor < 0 || maximum <= 0 || maximum > 16384) {
        return host_value_string_static("", 0);
    }
    char buffer[16384];
    ssize_t measured = -1;
    do {
        measured = read(descriptor, buffer, (size_t)maximum);
    } while (measured < 0 && errno == EINTR);
    if (measured <= 0) return host_value_string_static("", 0);
    return host_owned_string(buffer, (size_t)measured);
}

static void host_compact_store_u32(
    char* output,
    size_t offset,
    uint32_t value) {
    output[offset] = (char)(value & 255);
    output[offset + 1] = (char)((value >> 8) & 255);
    output[offset + 2] = (char)((value >> 16) & 255);
    output[offset + 3] = (char)((value >> 24) & 255);
}

AblaValue ablaLinuxPollWaitCompact(
    AblaValue descriptor_value,
    AblaValue maximum_value,
    AblaValue timeout_value) {
    const int descriptor = (int)host_value_as_i64(descriptor_value);
    const int64_t maximum = host_value_as_i64(maximum_value);
    const int64_t timeout = host_value_as_i64(timeout_value);
    if (descriptor < 0 || maximum <= 0 || maximum > 1024 ||
        timeout < 0 || timeout > 600000) {
        return host_value_string_static("", 0);
    }
    char encoded[1024 * 12];
    int measured = -1;
#if defined(__APPLE__)
    struct kevent events[1024];
    const struct timespec duration = {
        .tv_sec = timeout / 1000,
        .tv_nsec = (timeout % 1000) * 1000000};
    do {
        measured = kevent(
            descriptor, NULL, 0, events, (int)maximum, &duration);
    } while (measured < 0 && errno == EINTR);
    for (int index = 0; index < measured; ++index) {
        uint32_t flags = 0;
        if (events[index].filter == EVFILT_READ) flags |= 1;
        if (events[index].filter == EVFILT_WRITE) flags |= 4;
        if ((events[index].flags & EV_EOF) != 0) flags |= 16;
        if ((events[index].flags & EV_ERROR) != 0) flags |= 8;
        host_compact_store_u32(encoded, (size_t)index * 12, flags);
        host_compact_store_u32(
            encoded, (size_t)index * 12 + 4,
            (uint32_t)events[index].ident);
        host_compact_store_u32(encoded, (size_t)index * 12 + 8, 0);
    }
#else
    struct epoll_event events[1024];
    do {
        measured = epoll_wait(
            descriptor, events, (int)maximum, (int)timeout);
    } while (measured < 0 && errno == EINTR);
    for (int index = 0; index < measured; ++index) {
        uint32_t flags = 0;
        if ((events[index].events & EPOLLIN) != 0) flags |= 1;
        if ((events[index].events & EPOLLOUT) != 0) flags |= 4;
        if ((events[index].events & (EPOLLHUP | EPOLLRDHUP)) != 0) flags |= 16;
        if ((events[index].events & EPOLLERR) != 0) flags |= 8;
        host_compact_store_u32(encoded, (size_t)index * 12, flags);
        host_compact_store_u32(
            encoded, (size_t)index * 12 + 4,
            (uint32_t)events[index].data.fd);
        host_compact_store_u32(encoded, (size_t)index * 12 + 8, 0);
    }
#endif
    if (measured <= 0) return host_value_string_static("", 0);
    return host_owned_string(encoded, (size_t)measured * 12);
}

#if defined(__APPLE__)
static int host_linux_errno(int value) {
    if (value == EINPROGRESS) return 115;
    if (value == EAGAIN) return 11;
    if (value == ENOSYS) return 38;
    return value;
}

static int host_macos_open_flags(int64_t flags) {
    int result = 0;
    if ((flags & 3) == 1) result |= O_WRONLY;
    if ((flags & 3) == 2) result |= O_RDWR;
    if ((flags & 64) != 0) result |= O_CREAT;
    if ((flags & 128) != 0) result |= O_EXCL;
    if ((flags & 512) != 0) result |= O_TRUNC;
    if ((flags & 1024) != 0) result |= O_APPEND;
    if ((flags & 2048) != 0) result |= O_NONBLOCK;
    if ((flags & 65536) != 0) result |= O_DIRECTORY;
    if ((flags & 524288) != 0) result |= O_CLOEXEC;
    return result;
}

static int host_macos_socket_type(int64_t type) {
    int result = (int)(type & 15);
    if (result == 1) result = SOCK_STREAM;
    return result;
}

static void host_macos_configure_descriptor(int descriptor, int64_t flags) {
    if (descriptor < 0) return;
    if ((flags & 524288) != 0) {
        (void)fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    }
    if ((flags & 2048) != 0) {
        const int current = fcntl(descriptor, F_GETFL, 0);
        if (current >= 0) (void)fcntl(descriptor, F_SETFL, current | O_NONBLOCK);
    }
}

static void host_store_i64(unsigned char* output, size_t offset, int64_t value) {
    memcpy(output + offset, &value, sizeof(value));
}

static void host_store_u32(unsigned char* output, size_t offset, uint32_t value) {
    memcpy(output + offset, &value, sizeof(value));
}

static void host_store_u16(unsigned char* output, size_t offset, uint16_t value) {
    memcpy(output + offset, &value, sizeof(value));
}

static int host_macos_sockaddr(
    const void* linux_address,
    size_t linux_length,
    struct sockaddr_in* output) {
    if (linux_address == NULL || linux_length < 8) {
        errno = EINVAL;
        return -1;
    }
    const unsigned char* input = (const unsigned char*)linux_address;
    if (input[0] != 2 || input[1] != 0) {
        errno = EAFNOSUPPORT;
        return -1;
    }
    memset(output, 0, sizeof(*output));
    output->sin_len = (uint8_t)sizeof(*output);
    output->sin_family = AF_INET;
    memcpy(&output->sin_port, input + 2, 2);
    memcpy(&output->sin_addr, input + 4, 4);
    return 0;
}

static long host_macos_getdents(
    int descriptor,
    unsigned char* output,
    size_t capacity) {
    if (output == NULL || capacity < 24) {
        errno = EINVAL;
        return -1;
    }
    unsigned char* native = (unsigned char*)malloc(capacity);
    if (native == NULL) {
        errno = ENOMEM;
        return -1;
    }
    off_t base = 0;
    const long measured = syscall(
        SYS_getdirentries64, descriptor, native, capacity, &base);
    if (measured <= 0) {
        free(native);
        return (long)measured;
    }
    size_t input_offset = 0;
    size_t output_offset = 0;
    while (input_offset < (size_t)measured) {
        const struct dirent* entry =
            (const struct dirent*)(native + input_offset);
        if (entry->d_reclen == 0 ||
            input_offset + entry->d_reclen > (size_t)measured) {
            free(native);
            errno = EIO;
            return -1;
        }
        const size_t name_length = strlen(entry->d_name);
        const size_t record_length = (19 + name_length + 1 + 7) & ~(size_t)7;
        if (record_length > UINT16_MAX ||
            output_offset + record_length > capacity) {
            free(native);
            errno = EOVERFLOW;
            return -1;
        }
        memset(output + output_offset, 0, record_length);
        host_store_i64(
            output, output_offset, (int64_t)entry->d_ino);
        host_store_i64(output, output_offset + 8, (int64_t)base);
        host_store_u16(
            output, output_offset + 16, (uint16_t)record_length);
        output[output_offset + 18] = entry->d_type;
        memcpy(output + output_offset + 19, entry->d_name, name_length + 1);
        output_offset += record_length;
        input_offset += entry->d_reclen;
    }
    free(native);
    return (long)output_offset;
}

static long host_macos_linux_syscall(
    int64_t number,
    int64_t argument0,
    int64_t argument1,
    int64_t argument2,
    int64_t argument3,
    int64_t argument4,
    int64_t argument5) {
    (void)argument5;
    long result = -1;
    switch (number) {
        case 0:
            result = (long)read(
                (int)argument0, (void*)(uintptr_t)argument1, (size_t)argument2);
            break;
        case 1:
            result = (long)write(
                (int)argument0,
                (const void*)(uintptr_t)argument1,
                (size_t)argument2);
            break;
        case 3:
            result = close((int)argument0);
            break;
        case 7:
            result = poll(
                (struct pollfd*)(uintptr_t)argument0,
                (nfds_t)argument1,
                (int)argument2);
            break;
        case 14:
        case 289:
            errno = ENOSYS;
            break;
        case 21:
            result = access(
                (const char*)(uintptr_t)argument0, (int)argument1);
            break;
        case 33:
            result = dup2((int)argument0, (int)argument1);
            break;
        case 35:
            result = nanosleep(
                (const struct timespec*)(uintptr_t)argument0,
                (struct timespec*)(uintptr_t)argument1);
            break;
        case 39:
            result = (long)getpid();
            break;
        case 41: {
            const int descriptor = socket(
                (int)argument0, host_macos_socket_type(argument1),
                (int)argument2);
            host_macos_configure_descriptor(descriptor, argument1);
            result = descriptor;
            break;
        }
        case 42:
        case 49: {
            struct sockaddr_in address;
            if (host_macos_sockaddr(
                    (const void*)(uintptr_t)argument1,
                    (size_t)argument2,
                    &address) == 0) {
                if (number == 42) {
                    result = connect(
                        (int)argument0,
                        (const struct sockaddr*)&address,
                        (socklen_t)sizeof(address));
                } else {
                    result = bind(
                        (int)argument0,
                        (const struct sockaddr*)&address,
                        (socklen_t)sizeof(address));
                }
            }
            break;
        }
        case 44:
            result = (long)send(
                (int)argument0,
                (const void*)(uintptr_t)argument1,
                (size_t)argument2,
                (int)argument3);
            break;
        case 50:
            result = listen((int)argument0, (int)argument1);
            break;
        case 51: {
            struct sockaddr_in address;
            socklen_t length = (socklen_t)sizeof(address);
            result = getsockname(
                (int)argument0, (struct sockaddr*)&address, &length);
            if (result == 0 && argument1 != 0 && argument2 != 0) {
                unsigned char* output = (unsigned char*)(uintptr_t)argument1;
                uint32_t* output_length = (uint32_t*)(uintptr_t)argument2;
                if (*output_length < 16) {
                    errno = EINVAL;
                    result = -1;
                } else {
                    memset(output, 0, 16);
                    output[0] = 2;
                    memcpy(output + 2, &address.sin_port, 2);
                    memcpy(output + 4, &address.sin_addr, 4);
                    *output_length = 16;
                }
            }
            break;
        }
        case 54: {
            int level = (int)argument1;
            int option = (int)argument2;
            if (level == 1) level = SOL_SOCKET;
            if (level == SOL_SOCKET && option == 2) option = SO_REUSEADDR;
            result = setsockopt(
                (int)argument0,
                level,
                option,
                (const void*)(uintptr_t)argument3,
                (socklen_t)argument4);
            break;
        }
        case 57:
            result = (long)fork();
            break;
        case 59:
            result = execve(
                (const char*)(uintptr_t)argument0,
                (char* const*)(uintptr_t)argument1,
                (char* const*)(uintptr_t)argument2);
            break;
        case 60:
            _exit((int)argument0);
        case 61:
            result = (long)waitpid(
                (pid_t)argument0,
                (int*)(uintptr_t)argument1,
                (int)argument2);
            break;
        case 62:
            result = kill((pid_t)argument0, (int)argument1);
            break;
        case 72:
            result = fcntl(
                (int)argument0, (int)argument1,
                argument1 == F_SETFL
                    ? host_macos_open_flags(argument2)
                    : (int)argument2);
            break;
        case 74:
            result = fsync((int)argument0);
            break;
        case 79: {
            char* output = (char*)(uintptr_t)argument0;
            if (getcwd(output, (size_t)argument1) != NULL) {
                result = (long)(strlen(output) + 1);
            }
            break;
        }
        case 82:
            result = rename(
                (const char*)(uintptr_t)argument0,
                (const char*)(uintptr_t)argument1);
            break;
        case 83:
            result = mkdir(
                (const char*)(uintptr_t)argument0, (mode_t)argument1);
            break;
        case 84:
            result = rmdir((const char*)(uintptr_t)argument0);
            break;
        case 87:
            result = unlink((const char*)(uintptr_t)argument0);
            break;
        case 217:
            result = host_macos_getdents(
                (int)argument0,
                (unsigned char*)(uintptr_t)argument1,
                (size_t)argument2);
            break;
        case 228:
            result = clock_gettime(
                argument0 == 1 ? CLOCK_MONOTONIC : CLOCK_REALTIME,
                (struct timespec*)(uintptr_t)argument1);
            break;
        case 257: {
            const int directory = argument0 == -100 ? AT_FDCWD : (int)argument0;
            result = openat(
                directory,
                (const char*)(uintptr_t)argument1,
                host_macos_open_flags(argument2),
                (mode_t)argument3);
            break;
        }
        case 262: {
            struct stat information;
            const int directory = argument0 == -100 ? AT_FDCWD : (int)argument0;
            result = fstatat(
                directory,
                (const char*)(uintptr_t)argument1,
                &information,
                (int)argument3);
            if (result == 0) {
                unsigned char* output =
                    (unsigned char*)(uintptr_t)argument2;
                memset(output, 0, 144);
                host_store_u32(output, 24, (uint32_t)information.st_mode);
                host_store_i64(output, 48, (int64_t)information.st_size);
                host_store_i64(
                    output, 88, (int64_t)information.st_mtimespec.tv_sec);
                host_store_i64(
                    output, 96, (int64_t)information.st_mtimespec.tv_nsec);
            }
            break;
        }
        case 288: {
            const int descriptor = accept((int)argument0, NULL, NULL);
            host_macos_configure_descriptor(descriptor, argument3);
            result = descriptor;
            break;
        }
        case 293: {
            int* descriptors = (int*)(uintptr_t)argument0;
            result = pipe(descriptors);
            if (result == 0) {
                host_macos_configure_descriptor(descriptors[0], argument1);
                host_macos_configure_descriptor(descriptors[1], argument1);
            }
            break;
        }
        case 318:
            arc4random_buf((void*)(uintptr_t)argument0, (size_t)argument1);
            result = argument1;
            break;
        default:
            errno = ENOSYS;
            break;
    }
    if (result == -1) return -(long)host_linux_errno(errno);
    return result;
}
#endif

AblaValue ablaLinuxSyscall(
    AblaValue number,
    AblaValue argument0,
    AblaValue argument1,
    AblaValue argument2,
    AblaValue argument3,
    AblaValue argument4,
    AblaValue argument5) {
#if defined(__APPLE__)
    const long result = host_macos_linux_syscall(
        host_value_as_i64(number),
        host_value_as_i64(argument0),
        host_value_as_i64(argument1),
        host_value_as_i64(argument2),
        host_value_as_i64(argument3),
        host_value_as_i64(argument4),
        host_value_as_i64(argument5));
    return host_value_i64((int64_t)result);
#else
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
#endif
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

AblaValue ablaHostIsMacOS(void) {
#if defined(__APPLE__)
    return host_value_bool(true);
#else
    return host_value_bool(false);
#endif
}

AblaValue ablaHostValueArgumentsIndirect(void) {
#if defined(__APPLE__) && defined(__aarch64__)
    return host_value_bool(true);
#else
    return host_value_bool(false);
#endif
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
            .storage.owner = text}};
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

AblaValue ablaHostStartProcessConfigured(
    AblaValue directory_value,
    AblaValue arguments,
    AblaValue environment_names,
    AblaValue environment_values,
    AblaValue output_path_value) {
    if (directory_value.tag != ABLA_STRING ||
        output_path_value.tag != ABLA_STRING ||
        environment_names.tag != ABLA_ARRAY ||
        environment_values.tag != ABLA_ARRAY) {
        abla_platform_panic("invalid configured process values", 33);
    }
    size_t count = 0;
    char** values = host_process_arguments(arguments, &count);
    (void)count;
    const int64_t environment_count = host_value_as_i64(
        host_value_array_length(environment_names));
    const int64_t value_count = host_value_as_i64(
        host_value_array_length(environment_values));
    if (environment_count < 0 || environment_count != value_count) {
        abla_platform_free(values);
        abla_platform_panic("process environment sizes differ", 32);
    }
    for (int64_t index = 0; index < environment_count; ++index) {
        const AblaValue name = host_value_array_get(
            environment_names, host_value_i64(index));
        const AblaValue value = host_value_array_get(
            environment_values, host_value_i64(index));
        if (name.tag != ABLA_STRING || value.tag != ABLA_STRING ||
            name.as.string.length == 0) {
            abla_platform_free(values);
            abla_platform_panic("invalid process environment entry", 33);
        }
        const char* name_text = host_value_as_cstring(name);
        for (size_t byte = 0; byte < name.as.string.length; ++byte) {
            if (name_text[byte] == '=') {
                abla_platform_free(values);
                abla_platform_panic("invalid process environment name", 32);
            }
        }
    }
    const char* directory = host_value_as_cstring(directory_value);
    const char* output_path = host_value_as_cstring(output_path_value);
    const pid_t process = fork();
    if (process < 0) {
        abla_platform_free(values);
        abla_platform_panic("cannot start configured process", 31);
    }
    if (process == 0) {
        (void)setpgid(0, 0);
        if (directory_value.as.string.length > 0 && chdir(directory) != 0) {
            _exit(126);
        }
        if (output_path_value.as.string.length > 0) {
            const int output = open(
                output_path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
            if (output < 0 || dup2(output, STDOUT_FILENO) < 0 ||
                dup2(output, STDERR_FILENO) < 0) {
                if (output >= 0) close(output);
                _exit(126);
            }
            close(output);
        }
        for (int64_t index = 0; index < environment_count; ++index) {
            const AblaValue name = host_value_array_get(
                environment_names, host_value_i64(index));
            const AblaValue value = host_value_array_get(
                environment_values, host_value_i64(index));
            if (setenv(
                    host_value_as_cstring(name),
                    host_value_as_cstring(value),
                    1) != 0) {
                _exit(126);
            }
        }
        execvp(values[0], values);
        _exit(127);
    }
    (void)setpgid(process, process);
    abla_platform_free(values);
    return host_value_i64((int64_t)process);
}

AblaValue ablaHostPollProcess(AblaValue process_value) {
    const int64_t raw = host_value_as_i64(process_value);
    if (raw <= 0) return host_value_i64(127);
    int status = 0;
    pid_t waited = -1;
    do {
        waited = waitpid((pid_t)raw, &status, WNOHANG);
    } while (waited < 0 && errno == EINTR);
    if (waited == 0) return host_value_i64(-1);
    if (waited == (pid_t)raw) {
        return host_value_i64(host_decode_process_status(status));
    }
    return host_value_i64(127);
}

AblaValue ablaHostStopProcessTree(
    AblaValue process_value,
    AblaValue grace_value) {
    const int64_t raw = host_value_as_i64(process_value);
    const int64_t grace_milliseconds = host_value_as_i64(grace_value);
    if (raw <= 0) return host_value_i64(0);
    if (grace_milliseconds < 0 || grace_milliseconds > 60000) {
        abla_platform_panic("invalid process stop grace period", 33);
    }
    const pid_t process = (pid_t)raw;
    if (kill(-process, SIGTERM) != 0 && errno != ESRCH &&
        kill(process, SIGTERM) != 0 && errno != ESRCH) {
        return host_value_i64(127);
    }
    int status = 0;
    int64_t elapsed = 0;
    while (elapsed < grace_milliseconds) {
        const pid_t waited = waitpid(process, &status, WNOHANG);
        if (waited == process) {
            return host_value_i64(host_decode_process_status(status));
        }
        if (waited < 0 && errno == ECHILD) return host_value_i64(0);
        if (waited < 0 && errno != EINTR) return host_value_i64(127);
        struct timespec duration = {.tv_sec = 0, .tv_nsec = 10000000};
        while (nanosleep(&duration, &duration) != 0 && errno == EINTR) {}
        elapsed += 10;
    }
    if (kill(-process, SIGKILL) != 0 && errno != ESRCH) {
        (void)kill(process, SIGKILL);
    }
    return host_value_i64(host_wait_process(process));
}

AblaValue ablaHostMonotonicMilliseconds(void) {
    struct timespec timestamp = {.tv_sec = 0, .tv_nsec = 0};
    if (clock_gettime(CLOCK_MONOTONIC, &timestamp) != 0) {
        return host_value_i64(0);
    }
    return host_value_i64(
        (int64_t)timestamp.tv_sec * INT64_C(1000) +
        (int64_t)timestamp.tv_nsec / INT64_C(1000000));
}

AblaValue ablaHostProcessorCount(void) {
    const long count = sysconf(_SC_NPROCESSORS_ONLN);
    return host_value_i64(count > 0 ? (int64_t)count : INT64_C(1));
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

AblaValue ablaHostSecureRandom(AblaValue count_value) {
    const int64_t count = host_value_as_i64(count_value);
    if (count < 1 || count > 1024 * 1024) return host_value_string_static("", 0);
    const int descriptor = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) return host_value_string_static("", 0);
    char* bytes = (char*)abla_platform_alloc((size_t)count + 1);
    size_t offset = 0;
    while (offset < (size_t)count) {
        const ssize_t measured = read(
            descriptor, bytes + offset, (size_t)count - offset);
        if (measured < 0 && errno == EINTR) continue;
        if (measured <= 0) break;
        offset += (size_t)measured;
    }
    (void)close(descriptor);
    if (offset != (size_t)count) {
        abla_platform_free(bytes);
        return host_value_string_static("", 0);
    }
    bytes[offset] = '\0';
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = bytes,
            .length = offset,
            .storage.owner = bytes}};
}

static bool host_load_ssl_symbol(void* destination, size_t size, const char* name) {
    void* symbol = dlsym(host_ssl_library, name);
    if (symbol == NULL || size != sizeof(symbol)) return false;
    memcpy(destination, &symbol, size);
    return true;
}

static bool host_initialize_ssl(void) {
    if (host_ssl_library != NULL) return true;
    const char* configured = getenv("ABLA_OPENSSL_LIBRARY");
    if (configured != NULL && configured[0] != '\0') {
        host_ssl_library = dlopen(configured, RTLD_NOW | RTLD_LOCAL);
    }
    static const char* candidates[] = {
#if defined(__APPLE__)
        "libssl.3.dylib", "libssl.dylib",
        "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib",
        "/usr/local/opt/openssl@3/lib/libssl.3.dylib",
#else
        "libssl.so.3", "libssl.so.1.1", "libssl.so",
#endif
        NULL};
    for (size_t index = 0;
         host_ssl_library == NULL && candidates[index] != NULL;
         ++index) {
        host_ssl_library = dlopen(candidates[index], RTLD_NOW | RTLD_LOCAL);
    }
    if (host_ssl_library == NULL) {
        const char* path = getenv("PATH");
        size_t begin = 0;
        const size_t path_length = path == NULL ? 0 : strlen(path);
        while (host_ssl_library == NULL && begin <= path_length) {
            size_t end = begin;
            while (end < path_length && path[end] != ':') ++end;
            const size_t directory_length = end - begin;
            if (directory_length > 0 && directory_length < PATH_MAX - 16) {
                char executable[PATH_MAX];
                memcpy(executable, path + begin, directory_length);
                memcpy(executable + directory_length, "/openssl", 9);
                executable[directory_length + 8] = '\0';
                char resolved[PATH_MAX];
                if (realpath(executable, resolved) != NULL) {
                    char* suffix = strstr(resolved, "/bin/openssl");
                    if (suffix != NULL && suffix[12] == '\0') {
                        *suffix = '\0';
                        char library[PATH_MAX];
                        const int measured = snprintf(
                            library, sizeof(library),
#if defined(__APPLE__)
                            "%s/lib/libssl.3.dylib",
#else
                            "%s/lib/libssl.so.3",
#endif
                            resolved);
                        if (measured > 0 &&
                            (size_t)measured < sizeof(library)) {
                            host_ssl_library = dlopen(
                                library, RTLD_NOW | RTLD_LOCAL);
                        }
                    }
                }
            }
            begin = end + 1;
        }
    }
    if (host_ssl_library == NULL) {
        FILE* probe = popen("openssl version -d 2>/dev/null", "r");
        if (probe != NULL) {
            char output[PATH_MAX];
            if (fgets(output, sizeof(output), probe) != NULL) {
                char* begin = strchr(output, '"');
                char* end = begin == NULL ? NULL : strchr(begin + 1, '"');
                if (begin != NULL && end != NULL) {
                    *end = '\0';
                    char* suffix = strstr(begin + 1, "/etc/ssl");
                    if (suffix != NULL && suffix[8] == '\0') {
                        *suffix = '\0';
                        char library[PATH_MAX];
                        const int measured = snprintf(
                            library, sizeof(library),
#if defined(__APPLE__)
                            "%s/lib/libssl.3.dylib",
#else
                            "%s/lib/libssl.so.3",
#endif
                            begin + 1);
                        if (measured > 0 &&
                            (size_t)measured < sizeof(library)) {
                            host_ssl_library = dlopen(
                                library, RTLD_NOW | RTLD_LOCAL);
                        }
                    }
                }
            }
            (void)pclose(probe);
        }
    }
    if (host_ssl_library == NULL) return false;
#define ABLA_SSL_LOAD(name) \
    if (!host_load_ssl_symbol(&host_##name, sizeof(host_##name), #name)) \
        goto failed
    ABLA_SSL_LOAD(TLS_client_method);
    ABLA_SSL_LOAD(TLS_server_method);
    ABLA_SSL_LOAD(SSL_CTX_new);
    ABLA_SSL_LOAD(SSL_CTX_free);
    ABLA_SSL_LOAD(SSL_CTX_set_default_verify_paths);
    ABLA_SSL_LOAD(SSL_CTX_load_verify_locations);
    ABLA_SSL_LOAD(SSL_CTX_use_certificate_chain_file);
    ABLA_SSL_LOAD(SSL_CTX_use_PrivateKey_file);
    ABLA_SSL_LOAD(SSL_CTX_check_private_key);
    ABLA_SSL_LOAD(SSL_CTX_set_verify);
    ABLA_SSL_LOAD(SSL_new);
    ABLA_SSL_LOAD(SSL_free);
    ABLA_SSL_LOAD(SSL_ctrl);
    ABLA_SSL_LOAD(SSL_set1_host);
    ABLA_SSL_LOAD(SSL_set_fd);
    ABLA_SSL_LOAD(SSL_connect);
    ABLA_SSL_LOAD(SSL_accept);
    ABLA_SSL_LOAD(SSL_read);
    ABLA_SSL_LOAD(SSL_write);
    ABLA_SSL_LOAD(SSL_shutdown);
    ABLA_SSL_LOAD(SSL_get_verify_result);
#undef ABLA_SSL_LOAD
    return true;
failed:
    (void)dlclose(host_ssl_library);
    host_ssl_library = NULL;
    return false;
}

static int host_tcp_connect_name(
    const char* host,
    int port,
    int timeout_milliseconds) {
    char service[16];
    (void)snprintf(service, sizeof(service), "%d", port);
    const struct addrinfo hints = {
        .ai_flags = AI_ADDRCONFIG,
        .ai_family = AF_UNSPEC,
        .ai_socktype = SOCK_STREAM,
        .ai_protocol = IPPROTO_TCP};
    struct addrinfo* addresses = NULL;
    if (getaddrinfo(host, service, &hints, &addresses) != 0) return -1;
    int descriptor = -1;
    for (struct addrinfo* address = addresses;
         descriptor < 0 && address != NULL;
         address = address->ai_next) {
        const int candidate = socket(
            address->ai_family,
            address->ai_socktype,
            address->ai_protocol);
        if (candidate < 0) continue;
        const int flags = fcntl(candidate, F_GETFL, 0);
        if (flags < 0 || fcntl(candidate, F_SETFL, flags | O_NONBLOCK) != 0) {
            (void)close(candidate);
            continue;
        }
        int connected = connect(
            candidate, address->ai_addr, address->ai_addrlen);
        if (connected != 0 && errno == EINPROGRESS) {
            struct pollfd readiness = {.fd = candidate, .events = POLLOUT};
            do {
                connected = poll(&readiness, 1, timeout_milliseconds);
            } while (connected < 0 && errno == EINTR);
            if (connected > 0) {
                int socket_error = 0;
                socklen_t socket_error_size = sizeof(socket_error);
                if (getsockopt(
                        candidate, SOL_SOCKET, SO_ERROR,
                        &socket_error, &socket_error_size) != 0 ||
                    socket_error != 0) connected = -1;
                else connected = 0;
            } else connected = -1;
        }
        if (connected == 0) {
            (void)fcntl(candidate, F_SETFL, flags);
            const struct timeval timeout = {
                .tv_sec = timeout_milliseconds / 1000,
                .tv_usec =
                    (timeout_milliseconds % 1000) * 1000};
            (void)setsockopt(
                candidate, SOL_SOCKET, SO_RCVTIMEO,
                &timeout, sizeof(timeout));
            (void)setsockopt(
                candidate, SOL_SOCKET, SO_SNDTIMEO,
                &timeout, sizeof(timeout));
            descriptor = candidate;
        } else (void)close(candidate);
    }
    freeaddrinfo(addresses);
    return descriptor;
}

static bool host_set_nonblocking(int descriptor, bool enabled) {
    const int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0) return false;
    const int next = enabled ? flags | O_NONBLOCK : flags & ~O_NONBLOCK;
    return fcntl(descriptor, F_SETFL, next) == 0;
}

static int host_bind_socket(
    const char* host,
    int port,
    int socket_type,
    int protocol,
    int backlog,
    bool dual_stack) {
    char service[16];
    (void)snprintf(service, sizeof(service), "%d", port);
    const struct addrinfo hints = {
        .ai_flags = AI_PASSIVE,
        .ai_family = AF_UNSPEC,
        .ai_socktype = socket_type,
        .ai_protocol = protocol};
    struct addrinfo* addresses = NULL;
    const char* bind_host = host[0] == '\0' ? NULL : host;
    if (getaddrinfo(bind_host, service, &hints, &addresses) != 0) return -1;
    int descriptor = -1;
    for (struct addrinfo* address = addresses;
         descriptor < 0 && address != NULL;
         address = address->ai_next) {
        const int candidate = socket(
            address->ai_family, address->ai_socktype, address->ai_protocol);
        if (candidate < 0) continue;
        const int enabled = 1;
        (void)setsockopt(
            candidate, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
        if (address->ai_family == AF_INET6) {
            const int only = dual_stack ? 0 : 1;
            (void)setsockopt(
                candidate, IPPROTO_IPV6, IPV6_V6ONLY, &only, sizeof(only));
        }
        if (bind(candidate, address->ai_addr, address->ai_addrlen) == 0 &&
            (socket_type != SOCK_STREAM || listen(candidate, backlog) == 0)) {
            (void)fcntl(candidate, F_SETFD, FD_CLOEXEC);
            descriptor = candidate;
        } else (void)close(candidate);
    }
    freeaddrinfo(addresses);
    return descriptor;
}

AblaValue ablaHostNetConnect(
    AblaValue host_value,
    AblaValue port_value,
    AblaValue timeout_value) {
    const int64_t port = host_value_as_i64(port_value);
    const int64_t timeout = host_value_as_i64(timeout_value);
    if (port < 1 || port > 65535 || timeout < 1 || timeout > 600000) {
        return host_value_i64(-EINVAL);
    }
    const int descriptor = host_tcp_connect_name(
        host_value_as_cstring(host_value), (int)port, (int)timeout);
    const int failure = errno == 0 ? EHOSTUNREACH : errno;
    return host_value_i64(descriptor < 0 ? -failure : descriptor);
}

AblaValue ablaHostNetListen(
    AblaValue host_value,
    AblaValue port_value,
    AblaValue backlog_value,
    AblaValue dual_stack_value) {
    const int64_t port = host_value_as_i64(port_value);
    const int64_t backlog = host_value_as_i64(backlog_value);
    if (port < 0 || port > 65535 || backlog < 1 || backlog > 4096 ||
        dual_stack_value.tag != ABLA_BOOL) return host_value_i64(-EINVAL);
    const int descriptor = host_bind_socket(
        host_value_as_cstring(host_value), (int)port,
        SOCK_STREAM, IPPROTO_TCP, (int)backlog,
        dual_stack_value.as.boolean);
    const int failure = errno == 0 ? EADDRNOTAVAIL : errno;
    return host_value_i64(descriptor < 0 ? -failure : descriptor);
}

AblaValue ablaHostNetAccept(AblaValue listener_value) {
    const int listener = (int)host_value_as_i64(listener_value);
    int descriptor;
    do descriptor = accept(listener, NULL, NULL);
    while (descriptor < 0 && errno == EINTR);
    if (descriptor < 0) return host_value_i64(-errno);
    (void)fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    return host_value_i64(descriptor);
}

AblaValue ablaHostNetSetNonblocking(
    AblaValue descriptor_value,
    AblaValue enabled_value) {
    if (enabled_value.tag != ABLA_BOOL) return host_value_bool(false);
    return host_value_bool(host_set_nonblocking(
        (int)host_value_as_i64(descriptor_value),
        enabled_value.as.boolean));
}

AblaValue ablaHostNetLocalPort(AblaValue descriptor_value) {
    const int descriptor = (int)host_value_as_i64(descriptor_value);
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    if (getsockname(descriptor, (struct sockaddr*)&address, &length) != 0) {
        return host_value_i64(-errno);
    }
    if (address.ss_family == AF_INET) return host_value_i64(ntohs(
        ((const struct sockaddr_in*)&address)->sin_port));
    if (address.ss_family == AF_INET6) return host_value_i64(ntohs(
        ((const struct sockaddr_in6*)&address)->sin6_port));
    return host_value_i64(-EAFNOSUPPORT);
}

AblaValue ablaHostNetRead(
    AblaValue descriptor_value,
    AblaValue maximum_value) {
    const int descriptor = (int)host_value_as_i64(descriptor_value);
    const int64_t maximum = host_value_as_i64(maximum_value);
    host_net_status = 3;
    host_net_error = EINVAL;
    if (maximum < 1 || maximum > 16 * 1024 * 1024) {
        return host_value_string_static("", 0);
    }
    char* bytes = (char*)abla_platform_alloc((size_t)maximum + 1);
    ssize_t measured;
    do measured = recv(descriptor, bytes, (size_t)maximum, 0);
    while (measured < 0 && errno == EINTR);
    if (measured < 0) {
        host_net_error = errno;
        host_net_status = errno == EAGAIN || errno == EWOULDBLOCK ? 2 : 3;
        abla_platform_free(bytes);
        return host_value_string_static("", 0);
    }
    host_net_error = 0;
    host_net_status = measured == 0 ? 1 : 0;
    bytes[measured] = '\0';
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = bytes,
            .length = (size_t)measured,
            .storage.owner = bytes}};
}

AblaValue ablaHostNetWrite(AblaValue descriptor_value, AblaValue contents) {
    const int descriptor = (int)host_value_as_i64(descriptor_value);
    if (contents.tag != ABLA_STRING) return host_value_i64(-EINVAL);
    ssize_t written;
    do written = send(
        descriptor, host_value_string_data(contents),
        contents.as.string.length,
#if defined(MSG_NOSIGNAL)
        MSG_NOSIGNAL
#else
        0
#endif
    ); while (written < 0 && errno == EINTR);
    return host_value_i64(written < 0 ? -errno : written);
}

AblaValue ablaHostNetStatus(void) {
    return host_value_i64(host_net_status);
}

AblaValue ablaHostNetError(void) {
    return host_value_i64(host_net_error);
}

AblaValue ablaHostNetClose(AblaValue descriptor_value) {
    const int descriptor = (int)host_value_as_i64(descriptor_value);
    return host_value_bool(descriptor < 0 || close(descriptor) == 0);
}

AblaValue ablaHostNetUdpBind(
    AblaValue host_value,
    AblaValue port_value,
    AblaValue dual_stack_value) {
    const int64_t port = host_value_as_i64(port_value);
    if (port < 0 || port > 65535 || dual_stack_value.tag != ABLA_BOOL) {
        return host_value_i64(-EINVAL);
    }
    const int descriptor = host_bind_socket(
        host_value_as_cstring(host_value), (int)port,
        SOCK_DGRAM, IPPROTO_UDP, 0, dual_stack_value.as.boolean);
    const int failure = errno == 0 ? EADDRNOTAVAIL : errno;
    return host_value_i64(descriptor < 0 ? -failure : descriptor);
}

AblaValue ablaHostNetUdpSend(
    AblaValue descriptor_value,
    AblaValue host_value,
    AblaValue port_value,
    AblaValue contents) {
    const int descriptor = (int)host_value_as_i64(descriptor_value);
    const int64_t port = host_value_as_i64(port_value);
    if (contents.tag != ABLA_STRING || port < 1 || port > 65535) {
        return host_value_i64(-EINVAL);
    }
    char service[16];
    (void)snprintf(service, sizeof(service), "%d", (int)port);
    const struct addrinfo hints = {
        .ai_family = AF_UNSPEC,
        .ai_socktype = SOCK_DGRAM,
        .ai_protocol = IPPROTO_UDP};
    struct addrinfo* addresses = NULL;
    if (getaddrinfo(
            host_value_as_cstring(host_value), service,
            &hints, &addresses) != 0) return host_value_i64(-EINVAL);
    ssize_t written = -1;
    for (struct addrinfo* address = addresses;
         written < 0 && address != NULL;
         address = address->ai_next) {
        do written = sendto(
            descriptor, host_value_string_data(contents),
            contents.as.string.length, 0,
            address->ai_addr, address->ai_addrlen);
        while (written < 0 && errno == EINTR);
    }
    const int saved_error = errno;
    freeaddrinfo(addresses);
    return host_value_i64(written < 0 ? -saved_error : written);
}

AblaValue ablaHostNetUdpReceive(
    AblaValue descriptor_value,
    AblaValue maximum_value) {
    const int descriptor = (int)host_value_as_i64(descriptor_value);
    const int64_t maximum = host_value_as_i64(maximum_value);
    host_net_status = 3;
    host_net_error = EINVAL;
    host_net_source[0] = '\0';
    host_net_source_port = 0;
    if (maximum < 1 || maximum > 65535) {
        return host_value_string_static("", 0);
    }
    char* bytes = (char*)abla_platform_alloc((size_t)maximum + 1);
    struct sockaddr_storage source;
    socklen_t source_length = sizeof(source);
    ssize_t measured;
    do measured = recvfrom(
        descriptor, bytes, (size_t)maximum, 0,
        (struct sockaddr*)&source, &source_length);
    while (measured < 0 && errno == EINTR);
    if (measured < 0) {
        host_net_error = errno;
        host_net_status = errno == EAGAIN || errno == EWOULDBLOCK ? 2 : 3;
        abla_platform_free(bytes);
        return host_value_string_static("", 0);
    }
    const void* address = NULL;
    if (source.ss_family == AF_INET) {
        const struct sockaddr_in* ipv4 = (const struct sockaddr_in*)&source;
        address = &ipv4->sin_addr;
        host_net_source_port = ntohs(ipv4->sin_port);
    } else if (source.ss_family == AF_INET6) {
        const struct sockaddr_in6* ipv6 = (const struct sockaddr_in6*)&source;
        address = &ipv6->sin6_addr;
        host_net_source_port = ntohs(ipv6->sin6_port);
    }
    if (address != NULL) (void)inet_ntop(
        source.ss_family, address, host_net_source, sizeof(host_net_source));
    host_net_status = 0;
    host_net_error = 0;
    bytes[measured] = '\0';
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = bytes,
            .length = (size_t)measured,
            .storage.owner = bytes}};
}

AblaValue ablaHostNetSourceAddress(void) {
    return host_owned_string(host_net_source, strlen(host_net_source));
}

AblaValue ablaHostNetSourcePort(void) {
    return host_value_i64(host_net_source_port);
}

AblaValue ablaHostNetPollerCreate(void) {
#if defined(__APPLE__)
    return host_value_i64(kqueue());
#else
    return host_value_i64(epoll_create1(EPOLL_CLOEXEC));
#endif
}

static bool host_poller_control(
    int poller,
    int descriptor,
    bool readable,
    bool writable,
    bool modify,
    bool remove) {
#if defined(__APPLE__)
    struct kevent changes[4];
    int count = 0;
    if (modify || remove) {
        EV_SET(&changes[count++], descriptor, EVFILT_READ, EV_DELETE, 0, 0, NULL);
        EV_SET(&changes[count++], descriptor, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
        (void)kevent(poller, changes, count, NULL, 0, NULL);
        count = 0;
    }
    if (!remove && readable) EV_SET(
        &changes[count++], descriptor, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
    if (!remove && writable) EV_SET(
        &changes[count++], descriptor, EVFILT_WRITE, EV_ADD | EV_ENABLE, 0, 0, NULL);
    return count == 0 || kevent(poller, changes, count, NULL, 0, NULL) == 0;
#else
    struct epoll_event event;
    memset(&event, 0, sizeof(event));
    event.events = EPOLLRDHUP |
        (readable ? EPOLLIN : 0) | (writable ? EPOLLOUT : 0);
    event.data.fd = descriptor;
    const int operation = remove ? EPOLL_CTL_DEL :
        (modify ? EPOLL_CTL_MOD : EPOLL_CTL_ADD);
    return epoll_ctl(poller, operation, descriptor, remove ? NULL : &event) == 0;
#endif
}

AblaValue ablaHostNetPollerControl(
    AblaValue poller_value,
    AblaValue descriptor_value,
    AblaValue readable_value,
    AblaValue writable_value,
    AblaValue operation_value) {
    if (readable_value.tag != ABLA_BOOL || writable_value.tag != ABLA_BOOL) {
        return host_value_bool(false);
    }
    const int operation = (int)host_value_as_i64(operation_value);
    return host_value_bool(host_poller_control(
        (int)host_value_as_i64(poller_value),
        (int)host_value_as_i64(descriptor_value),
        readable_value.as.boolean, writable_value.as.boolean,
        operation == 1, operation == 2));
}

static void host_store_u32(char* output, size_t offset, uint32_t value) {
    output[offset] = (char)(value & 255);
    output[offset + 1] = (char)((value >> 8) & 255);
    output[offset + 2] = (char)((value >> 16) & 255);
    output[offset + 3] = (char)((value >> 24) & 255);
}

AblaValue ablaHostNetPollerWait(
    AblaValue poller_value,
    AblaValue maximum_value,
    AblaValue timeout_value) {
    const int poller = (int)host_value_as_i64(poller_value);
    const int64_t maximum = host_value_as_i64(maximum_value);
    const int64_t timeout = host_value_as_i64(timeout_value);
    host_net_error = 0;
    if (maximum < 1 || maximum > 1024 || timeout < 0 || timeout > 600000) {
        host_net_error = EINVAL;
        return host_value_string_static("", 0);
    }
    char* encoded = (char*)malloc((size_t)maximum * 8);
    if (encoded == NULL) {
        host_net_error = ENOMEM;
        return host_value_string_static("", 0);
    }
    int measured;
#if defined(__APPLE__)
    struct kevent* events = (struct kevent*)calloc(
        (size_t)maximum, sizeof(struct kevent));
    if (events == NULL) {
        free(encoded);
        host_net_error = ENOMEM;
        return host_value_string_static("", 0);
    }
    const struct timespec duration = {
        .tv_sec = timeout / 1000,
        .tv_nsec = (timeout % 1000) * 1000000};
    do measured = kevent(
        poller, NULL, 0, events, (int)maximum, &duration);
    while (measured < 0 && errno == EINTR);
    for (int index = 0; index < measured; ++index) {
        uint32_t flags = 0;
        if (events[index].filter == EVFILT_READ) flags |= 1;
        if (events[index].filter == EVFILT_WRITE) flags |= 2;
        if ((events[index].flags & EV_EOF) != 0) flags |= 4;
        if ((events[index].flags & EV_ERROR) != 0) flags |= 8;
        host_store_u32(encoded, (size_t)index * 8, (uint32_t)events[index].ident);
        host_store_u32(encoded, (size_t)index * 8 + 4, flags);
    }
    free(events);
#else
    struct epoll_event* events = (struct epoll_event*)calloc(
        (size_t)maximum, sizeof(struct epoll_event));
    if (events == NULL) {
        free(encoded);
        host_net_error = ENOMEM;
        return host_value_string_static("", 0);
    }
    do measured = epoll_wait(
        poller, events, (int)maximum, (int)timeout);
    while (measured < 0 && errno == EINTR);
    for (int index = 0; index < measured; ++index) {
        uint32_t flags = 0;
        if ((events[index].events & EPOLLIN) != 0) flags |= 1;
        if ((events[index].events & EPOLLOUT) != 0) flags |= 2;
        if ((events[index].events & (EPOLLHUP | EPOLLRDHUP)) != 0) flags |= 4;
        if ((events[index].events & EPOLLERR) != 0) flags |= 8;
        host_store_u32(encoded, (size_t)index * 8, (uint32_t)events[index].data.fd);
        host_store_u32(encoded, (size_t)index * 8 + 4, flags);
    }
    free(events);
#endif
    if (measured < 0) {
        host_net_error = errno;
        free(encoded);
        return host_value_string_static("", 0);
    }
    const AblaValue result = host_owned_string(encoded, (size_t)measured * 8);
    free(encoded);
    return result;
}

AblaValue ablaHostTlsAvailable(void) {
    return host_value_bool(host_initialize_ssl());
}

static AblaValue host_tls_open(
    const char* host,
    int64_t port,
    int64_t timeout,
    const char* ca_path) {
    if (port < 1 || port > 65535 || timeout < 1 || timeout > 600000 ||
        !host_initialize_ssl()) {
        host_set_tls_error("TLS runtime is unavailable");
        return host_value_i64(-1);
    }
    const int descriptor = host_tcp_connect_name(
        host, (int)port, (int)timeout);
    if (descriptor < 0) {
        host_set_tls_error("TCP connection failed");
        return host_value_i64(-1);
    }
    AblaHostTlsConnection* connection =
        (AblaHostTlsConnection*)calloc(1, sizeof(*connection));
    if (connection == NULL) {
        (void)close(descriptor);
        return host_value_i64(-1);
    }
    connection->descriptor = descriptor;
    connection->owns_context = true;
    connection->context = host_SSL_CTX_new(host_TLS_client_method());
    if (connection->context != NULL) {
        host_SSL_CTX_set_verify(connection->context, 1, NULL);
        const bool default_trust =
            host_SSL_CTX_set_default_verify_paths(connection->context) == 1;
        const bool system_trust = host_SSL_CTX_load_verify_locations(
            connection->context,
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/ssl/certs") == 1;
        const bool explicit_trust = ca_path != NULL && ca_path[0] != '\0' &&
            host_SSL_CTX_load_verify_locations(
                connection->context, ca_path, NULL) == 1;
        const bool trust_loaded = default_trust || system_trust || explicit_trust;
        if (trust_loaded) {
            connection->ssl = host_SSL_new(connection->context);
        }
    }
    bool connected = connection->ssl != NULL;
    if (connected) connected =
        host_SSL_ctrl(connection->ssl, 55, 0, (void*)host) == 1;
    if (connected) connected =
        host_SSL_set1_host(connection->ssl, host) == 1;
    if (connected) connected =
        host_SSL_set_fd(connection->ssl, descriptor) == 1;
    if (connected) connected = host_SSL_connect(connection->ssl) == 1;
    if (connected) connected =
        host_SSL_get_verify_result(connection->ssl) == 0;
    if (!connected) {
        if (connection->context == NULL) host_set_tls_error("TLS context failed");
        else if (connection->ssl == NULL) host_set_tls_error("TLS trust or session failed");
        else host_set_tls_error("TLS handshake or certificate verification failed");
        if (connection->ssl != NULL) host_SSL_free(connection->ssl);
        if (connection->context != NULL) {
            host_SSL_CTX_free(connection->context);
        }
        (void)close(descriptor);
        free(connection);
        return host_value_i64(-1);
    }
    host_tls_error[0] = '\0';
    return host_value_i64((int64_t)(intptr_t)connection);
}

AblaValue ablaHostTlsOpen(
    AblaValue host_value,
    AblaValue port_value,
    AblaValue timeout_value) {
    return host_tls_open(
        host_value_as_cstring(host_value),
        host_value_as_i64(port_value),
        host_value_as_i64(timeout_value),
        NULL);
}

AblaValue ablaHostTlsOpenWithCa(
    AblaValue host_value,
    AblaValue port_value,
    AblaValue timeout_value,
    AblaValue ca_path_value) {
    return host_tls_open(
        host_value_as_cstring(host_value),
        host_value_as_i64(port_value),
        host_value_as_i64(timeout_value),
        host_value_as_cstring(ca_path_value));
}

AblaValue ablaHostTlsError(void) {
    return host_owned_string(host_tls_error, strlen(host_tls_error));
}

AblaValue ablaHostTlsRead(AblaValue handle_value, AblaValue maximum_value) {
    AblaHostTlsConnection* connection = (AblaHostTlsConnection*)(intptr_t)
        host_value_as_i64(handle_value);
    const int64_t maximum = host_value_as_i64(maximum_value);
    if (connection == NULL || maximum < 1 || maximum > 16 * 1024 * 1024) {
        return host_value_string_static("", 0);
    }
    char* bytes = (char*)abla_platform_alloc((size_t)maximum + 1);
    const int measured = host_SSL_read(
        connection->ssl, bytes, (int)maximum);
    if (measured <= 0) {
        abla_platform_free(bytes);
        return host_value_string_static("", 0);
    }
    bytes[measured] = '\0';
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = bytes,
            .length = (size_t)measured,
            .storage.owner = bytes}};
}

AblaValue ablaHostTlsWrite(AblaValue handle_value, AblaValue contents) {
    AblaHostTlsConnection* connection = (AblaHostTlsConnection*)(intptr_t)
        host_value_as_i64(handle_value);
    if (connection == NULL || contents.tag != ABLA_STRING) {
        return host_value_i64(-1);
    }
    const char* bytes = host_value_string_data(contents);
    size_t offset = 0;
    while (offset < contents.as.string.length) {
        size_t remaining = contents.as.string.length - offset;
        if (remaining > INT32_MAX) remaining = INT32_MAX;
        const int written = host_SSL_write(
            connection->ssl, bytes + offset, (int)remaining);
        if (written <= 0) return host_value_i64(-1);
        offset += (size_t)written;
    }
    return host_value_i64((int64_t)offset);
}

AblaValue ablaHostTlsClose(AblaValue handle_value) {
    AblaHostTlsConnection* connection = (AblaHostTlsConnection*)(intptr_t)
        host_value_as_i64(handle_value);
    if (connection == NULL) return host_value_bool(true);
    (void)host_SSL_shutdown(connection->ssl);
    host_SSL_free(connection->ssl);
    if (connection->owns_context) host_SSL_CTX_free(connection->context);
    const bool closed = close(connection->descriptor) == 0;
    free(connection);
    return host_value_bool(closed);
}

AblaValue ablaHostTlsListen(
    AblaValue host_value,
    AblaValue port_value,
    AblaValue backlog_value,
    AblaValue dual_stack_value,
    AblaValue certificate_value,
    AblaValue private_key_value) {
    const int64_t port = host_value_as_i64(port_value);
    const int64_t backlog = host_value_as_i64(backlog_value);
    if (port < 0 || port > 65535 || backlog < 1 || backlog > 4096 ||
        dual_stack_value.tag != ABLA_BOOL || !host_initialize_ssl()) {
        host_set_tls_error("invalid or unavailable TLS listener");
        return host_value_i64(-1);
    }
    AblaHostTlsListener* listener =
        (AblaHostTlsListener*)calloc(1, sizeof(*listener));
    if (listener == NULL) return host_value_i64(-1);
    listener->descriptor = -1;
    listener->context = host_SSL_CTX_new(host_TLS_server_method());
    bool ready = listener->context != NULL;
    if (ready) ready = host_SSL_CTX_use_certificate_chain_file(
        listener->context, host_value_as_cstring(certificate_value)) == 1;
    if (ready) ready = host_SSL_CTX_use_PrivateKey_file(
        listener->context, host_value_as_cstring(private_key_value), 1) == 1;
    if (ready) ready = host_SSL_CTX_check_private_key(listener->context) == 1;
    if (ready) {
        listener->descriptor = host_bind_socket(
            host_value_as_cstring(host_value), (int)port,
            SOCK_STREAM, IPPROTO_TCP, (int)backlog,
            dual_stack_value.as.boolean);
        ready = listener->descriptor >= 0;
    }
    if (!ready) {
        host_set_tls_error("TLS certificate, private key, or listener failed");
        if (listener->descriptor >= 0) (void)close(listener->descriptor);
        if (listener->context != NULL) host_SSL_CTX_free(listener->context);
        free(listener);
        return host_value_i64(-1);
    }
    host_tls_error[0] = '\0';
    return host_value_i64((int64_t)(intptr_t)listener);
}

AblaValue ablaHostTlsListenerPort(AblaValue handle_value) {
    AblaHostTlsListener* listener = (AblaHostTlsListener*)(intptr_t)
        host_value_as_i64(handle_value);
    if (listener == NULL) return host_value_i64(-1);
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    if (getsockname(
            listener->descriptor, (struct sockaddr*)&address, &length) != 0) {
        return host_value_i64(-1);
    }
    if (address.ss_family == AF_INET) return host_value_i64(ntohs(
        ((const struct sockaddr_in*)&address)->sin_port));
    if (address.ss_family == AF_INET6) return host_value_i64(ntohs(
        ((const struct sockaddr_in6*)&address)->sin6_port));
    return host_value_i64(-1);
}

AblaValue ablaHostTlsAccept(AblaValue handle_value) {
    AblaHostTlsListener* listener = (AblaHostTlsListener*)(intptr_t)
        host_value_as_i64(handle_value);
    if (listener == NULL) return host_value_i64(-1);
    int descriptor;
    do descriptor = accept(listener->descriptor, NULL, NULL);
    while (descriptor < 0 && errno == EINTR);
    if (descriptor < 0) return host_value_i64(-1);
    AblaHostTlsConnection* connection =
        (AblaHostTlsConnection*)calloc(1, sizeof(*connection));
    if (connection == NULL) {
        (void)close(descriptor);
        return host_value_i64(-1);
    }
    connection->context = listener->context;
    connection->descriptor = descriptor;
    connection->ssl = host_SSL_new(listener->context);
    bool accepted = connection->ssl != NULL;
    if (accepted) accepted = host_SSL_set_fd(connection->ssl, descriptor) == 1;
    if (accepted) accepted = host_SSL_accept(connection->ssl) == 1;
    if (!accepted) {
        host_set_tls_error("TLS server handshake failed");
        if (connection->ssl != NULL) host_SSL_free(connection->ssl);
        (void)close(descriptor);
        free(connection);
        return host_value_i64(-1);
    }
    return host_value_i64((int64_t)(intptr_t)connection);
}

AblaValue ablaHostTlsListenerClose(AblaValue handle_value) {
    AblaHostTlsListener* listener = (AblaHostTlsListener*)(intptr_t)
        host_value_as_i64(handle_value);
    if (listener == NULL) return host_value_bool(true);
    const bool closed = close(listener->descriptor) == 0;
    host_SSL_CTX_free(listener->context);
    free(listener);
    return host_value_bool(closed);
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
            .storage.owner = buffer}};
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
        AblaAllocationHeader* released = host_allocation_tail;
        if (released->allocation.cache_owner != NULL &&
            released->allocation.cache_owner->flattened ==
                (char*)(released + 1)) {
            released->allocation.cache_owner->flattened = NULL;
        }
        abla_platform_free((void*)(host_allocation_tail + 1));
    }
    return host_value_void();
}

AblaValue ablaHostMemoryLiveBytes(void) {
    host_initialize_allocation_limit();
    if (host_allocation_live_bytes > (size_t)INT64_MAX) {
        abla_platform_panic("live allocation count overflow", 30);
    }
    return host_value_i64((int64_t)host_allocation_live_bytes);
}

AblaValue ablaHostMemoryLimit(void) {
    host_initialize_allocation_limit();
    if (host_allocation_limit > (size_t)INT64_MAX) {
        abla_platform_panic("memory limit overflow", 21);
    }
    return host_value_i64((int64_t)host_allocation_limit);
}

AblaValue ablaHostMemorySetLimit(AblaValue limit_value) {
    host_initialize_allocation_limit();
    const int64_t limit = host_value_as_i64(limit_value);
    if (limit < 0 || (uint64_t)limit < host_allocation_live_bytes) {
        abla_platform_panic("invalid memory limit", 20);
    }
    host_allocation_limit = (size_t)limit;
    const size_t reserve = host_allocation_limit / 4;
    const size_t latest = host_allocation_limit - reserve;
    if (host_collection_threshold > latest) {
        host_collection_threshold = latest;
    }
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
    host_initialize_allocation_limit();
    return (int64_t)host_allocation_live_bytes;
}

static bool host_mark_pointer(uintptr_t candidate) {
    if (host_collection_index != NULL) {
        const size_t mask = host_collection_index_capacity - 1;
        size_t slot = (size_t)((candidate >> 4) *
            UINT64_C(11400714819323198485)) & mask;
        AblaAllocationHeader* header = host_collection_index[slot];
        while (header != NULL && (uintptr_t)(header + 1) != candidate) {
            slot = (slot + 1) & mask;
            header = host_collection_index[slot];
        }
        if (header == NULL) return false;
        if ((header->allocation.generation >> 63) != 0) return false;
        header->allocation.generation |= UINT64_C(1) << 63;
        if (host_mark_worklist_count >= host_collection_index_count) {
            abla_platform_panic("collection worklist overflow", 28);
        }
        host_mark_worklist[host_mark_worklist_count++] = header;
        return true;
    }
    AblaAllocationHeader* header = host_allocation_tail;
    while (header != NULL) {
        const uintptr_t payload = (uintptr_t)(header + 1);
        if (payload == candidate) {
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

static bool host_mark_string(const AblaString* string) {
    bool changed = false;
    if (string->data == NULL) {
        if (host_mark_pointer(
            (uintptr_t)ABLA_STRING_ROPE(*string))) changed = true;
    } else {
        const char* allocation = ABLA_STRING_OWNER(*string) != NULL
            ? ABLA_STRING_OWNER(*string)
            : string->data;
        if (host_mark_pointer((uintptr_t)allocation)) changed = true;
    }
    return changed;
}

static bool host_mark_value(const AblaValue* value) {
    bool changed = false;
    if (value->tag == ABLA_STRING) {
        changed = host_mark_string(&value->as.string);
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
    } else if (value->tag == ABLA_GENERATOR || value->tag == ABLA_TASK ||
               value->tag == ABLA_THREAD) {
        changed = host_mark_pointer((uintptr_t)value->as.concurrent);
    }
    return changed;
}

static bool host_mark_root_frames(AblaRuntimeRootFrame* frame) {
    bool changed = false;
    while (frame != NULL) {
        for (uint64_t root = 0; root < frame->count; ++root) {
            if (host_mark_value((const AblaValue*)frame->roots[root])) {
                changed = true;
            }
        }
        frame = frame->previous;
    }
    return changed;
}

static bool host_mark_allocation(const AblaAllocationHeader* header) {
    const unsigned char* payload = (const unsigned char*)(header + 1);
    const size_t size = header->allocation.scan_size;
    const uint8_t layout = header->allocation.scan_layout;
    bool changed = false;
    if (host_mark_pointer((uintptr_t)header->allocation.cache_owner)) {
        changed = true;
    }
    if (layout == 1) return changed;
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
        for (size_t offset = 0; offset + sizeof(AblaField) <= size;
             offset += sizeof(AblaField)) {
            if (host_mark_value((const AblaValue*)(
                payload + offset + offsetof(AblaField, value)))) {
                changed = true;
            }
        }
        return changed;
    }
    if (layout == 4 && size >= sizeof(AblaArray)) {
        const AblaArray* array = (const AblaArray*)payload;
        if (array->values == (const AblaValue*)(array + 1)) {
            for (size_t index = 0; index < array->length; ++index) {
                if (host_mark_value(&array->values[index])) changed = true;
            }
        } else if (host_mark_pointer((uintptr_t)array->values)) {
            changed = true;
        }
    }
    if (layout == 4) return changed;
    if (layout == 5 && size >= sizeof(AblaObject)) {
        const AblaObject* object = (const AblaObject*)payload;
        if (object->fields == (const AblaField*)(object + 1)) {
            for (size_t index = 0; index < object->count; ++index) {
                if (host_mark_value(&object->fields[index].value)) {
                    changed = true;
                }
            }
        } else if (host_mark_pointer((uintptr_t)object->fields)) {
            changed = true;
        }
    }
    if (layout == 5) return changed;
    if (layout == 6 && size >= sizeof(AblaStringRope)) {
        const AblaStringRope* rope = (const AblaStringRope*)payload;
        if (host_mark_string(&rope->left)) changed = true;
        if (host_mark_string(&rope->right)) changed = true;
        if (host_mark_pointer((uintptr_t)rope->flattened)) changed = true;
        return changed;
    }
    if (layout == 7 && size >= 16 + sizeof(AblaValue)) {
        if (host_mark_value((const AblaValue*)(
            payload + 16))) changed = true;
        return changed;
    }
    if (layout == 8 && size >= sizeof(AblaValue)) {
        if (host_mark_value((const AblaValue*)payload)) changed = true;
        return changed;
    }
    if (layout == 9) {
        for (size_t offset = 0; offset + sizeof(AblaString) <= size;
             offset += sizeof(AblaString)) {
            if (host_mark_string((const AblaString*)(payload + offset))) {
                changed = true;
            }
        }
        return changed;
    }
    if (layout == 11 && size >= sizeof(AblaHostCoroutine)) {
        const AblaHostCoroutine* coroutine =
            (const AblaHostCoroutine*)payload;
        if (host_mark_value(&coroutine->closure)) changed = true;
        if (host_mark_value(&coroutine->current)) changed = true;
        if (host_mark_value(&coroutine->result)) changed = true;
        if (host_mark_root_frames(coroutine->roots)) changed = true;
        return changed;
    }
    if (layout == 12 && size >= sizeof(AblaHostThread)) {
        const AblaHostThread* thread = (const AblaHostThread*)payload;
        if (host_mark_value(&thread->closure)) changed = true;
        if (host_mark_value(&thread->result)) changed = true;
        return changed;
    }
    return host_mark_words(payload, size);
}

static void host_collection_index_add(AblaAllocationHeader* header) {
    const uintptr_t payload = (uintptr_t)(header + 1);
    const size_t mask = host_collection_index_capacity - 1;
    size_t slot = (size_t)((payload >> 4) *
        UINT64_C(11400714819323198485)) & mask;
    while (host_collection_index[slot] != NULL) {
        slot = (slot + 1) & mask;
    }
    host_collection_index[slot] = header;
}

int64_t abla_platform_memory_collect(void* opaque_frames) {
    if (atomic_load_explicit(
            &host_active_threads, memory_order_acquire) != 0) return 0;
    const size_t before = host_allocation_live_bytes;
    size_t allocation_count = 0;
    for (AblaAllocationHeader* header = host_allocation_tail;
         header != NULL; header = header->allocation.previous) {
        ++allocation_count;
    }
    for (size_t depth = 0; depth < host_region_depth; ++depth) {
        for (AblaAllocationHeader* header = host_regions[depth].tail;
             header != NULL; header = header->allocation.previous) {
            ++allocation_count;
        }
    }
    if (allocation_count > SIZE_MAX / 2) {
        abla_platform_panic("collection index overflow", 25);
    }
    host_collection_index_capacity = allocation_count == 0 ? 0 : 16;
    while (host_collection_index_capacity < allocation_count * 2) {
        if (host_collection_index_capacity > SIZE_MAX / 2) {
            abla_platform_panic("collection index overflow", 25);
        }
        host_collection_index_capacity *= 2;
    }
    if (host_collection_index_capacity >
        SIZE_MAX / sizeof(*host_collection_index)) {
        abla_platform_panic("collection index overflow", 25);
    }
    host_collection_index = host_collection_index_capacity == 0
        ? NULL
        : (AblaAllocationHeader**)calloc(
            host_collection_index_capacity,
            sizeof(*host_collection_index));
    if (allocation_count != 0 && host_collection_index == NULL) {
        abla_platform_panic("out of memory", 13);
    }
    host_collection_index_count = allocation_count;
    host_mark_worklist = allocation_count == 0
        ? NULL
        : (AblaAllocationHeader**)malloc(
            allocation_count * sizeof(*host_mark_worklist));
    if (allocation_count != 0 && host_mark_worklist == NULL) {
        free(host_collection_index);
        host_collection_index = NULL;
        host_collection_index_count = 0;
        host_collection_index_capacity = 0;
        abla_platform_panic("out of memory", 13);
    }
    host_mark_worklist_count = 0;
    for (AblaAllocationHeader* header = host_allocation_tail;
         header != NULL; header = header->allocation.previous) {
        host_collection_index_add(header);
    }
    for (size_t depth = 0; depth < host_region_depth; ++depth) {
        for (AblaAllocationHeader* header = host_regions[depth].tail;
             header != NULL; header = header->allocation.previous) {
            host_collection_index_add(header);
        }
    }
    (void)host_mark_root_frames((AblaRuntimeRootFrame*)opaque_frames);
    if (host_current_coroutine != NULL) {
        (void)host_mark_pointer((uintptr_t)host_current_coroutine);
        (void)host_mark_root_frames(host_current_coroutine->caller_roots);
    }
    while (host_mark_worklist_count != 0) {
        const AblaAllocationHeader* marked =
            host_mark_worklist[--host_mark_worklist_count];
        (void)host_mark_allocation(marked);
    }
    AblaAllocationHeader* header = host_allocation_tail;
    while (header != NULL) {
        AblaAllocationHeader* previous = header->allocation.previous;
        if ((header->allocation.generation >> 63) != 0 ||
            header->allocation.scan_layout == 10) {
            header->allocation.generation &= INT64_MAX;
        } else {
            host_platform_free_unlocked((void*)(header + 1));
        }
        header = previous;
    }
    for (size_t depth = 0; depth < host_region_depth; ++depth) {
        for (AblaAllocationHeader* region_header = host_regions[depth].tail;
             region_header != NULL;
             region_header = region_header->allocation.previous) {
            region_header->allocation.generation &= INT64_MAX;
        }
    }
    free(host_collection_index);
    host_collection_index = NULL;
    host_collection_index_count = 0;
    host_collection_index_capacity = 0;
    free(host_mark_worklist);
    host_mark_worklist = NULL;
    const size_t freed = before - host_allocation_live_bytes;
    if (freed > (size_t)INT64_MAX) {
        abla_platform_panic("collection size overflow", 24);
    }
    return (int64_t)freed;
}

int64_t abla_platform_memory_limit(void) {
    host_initialize_allocation_limit();
    return (int64_t)host_allocation_limit;
}

void abla_platform_memory_set_limit(int64_t limit) {
    (void)ablaHostMemorySetLimit(host_value_i64(limit));
}

static AblaHostCoroutine* host_as_coroutine(
    AblaValue value,
    AblaTag expected) {
    if (value.tag != expected || value.as.concurrent == NULL) {
        abla_platform_panic("invalid coroutine handle", 24);
    }
    return (AblaHostCoroutine*)value.as.concurrent;
}

static void host_coroutine_entry(uint32_t low, uint32_t high) {
    const uintptr_t bits = (uintptr_t)low |
        ((uintptr_t)high << 32);
    AblaHostCoroutine* coroutine = (AblaHostCoroutine*)bits;
    AblaValue result = coroutine->dispatch(
        &coroutine->closure, NULL, 0);
    coroutine->result = result;
    coroutine->release(&coroutine->closure);
    coroutine->closure = (AblaValue){.tag = ABLA_NULL};
    coroutine->roots = host_root_frame;
    coroutine->state = ABLA_COROUTINE_DONE;
    host_root_frame = coroutine->caller_roots;
    if (swapcontext(&coroutine->context, &coroutine->caller) != 0) {
        abla_platform_panic("cannot finish coroutine", 23);
    }
    abla_platform_panic("resumed completed coroutine", 27);
}

static AblaHostCoroutine* host_coroutine_create(
    AblaValue closure,
    AblaDispatch dispatch,
    AblaClosureCleanup release,
    AblaClosureCleanup drop,
    bool generator) {
    if (dispatch == NULL || release == NULL || drop == NULL) {
        abla_platform_panic("invalid coroutine callbacks", 27);
    }
    AblaHostCoroutine* coroutine =
        (AblaHostCoroutine*)abla_platform_alloc(sizeof(*coroutine));
    abla_platform_memory_set_layout(coroutine, 11);
    coroutine->closure = closure;
    coroutine->current = (AblaValue){.tag = ABLA_NULL};
    coroutine->result = host_value_void();
    coroutine->dispatch = dispatch;
    coroutine->release = release;
    coroutine->drop = drop;
    coroutine->stack_size = (size_t)1024 * 1024;
    coroutine->stack = malloc(coroutine->stack_size);
    if (coroutine->stack == NULL) abla_platform_panic("out of memory", 13);
    coroutine->state = ABLA_COROUTINE_CREATED;
    coroutine->generator = generator;
    coroutine->cancelled = false;
    if (getcontext(&coroutine->context) != 0) {
        abla_platform_panic("cannot create coroutine", 23);
    }
    coroutine->context.uc_stack.ss_sp = coroutine->stack;
    coroutine->context.uc_stack.ss_size = coroutine->stack_size;
    coroutine->context.uc_link = NULL;
    const uintptr_t bits = (uintptr_t)coroutine;
    makecontext(
        &coroutine->context,
        (void (*)(void))host_coroutine_entry,
        2,
        (uint32_t)bits,
        (uint32_t)(bits >> 32));
    return coroutine;
}

static void host_coroutine_resume(AblaHostCoroutine* coroutine) {
    if (coroutine->state != ABLA_COROUTINE_CREATED &&
        coroutine->state != ABLA_COROUTINE_SUSPENDED) return;
    AblaHostCoroutine* previous = host_current_coroutine;
    coroutine->caller_roots = host_root_frame;
    host_root_frame = coroutine->roots;
    host_current_coroutine = coroutine;
    coroutine->state = ABLA_COROUTINE_RUNNING;
    if (swapcontext(&coroutine->caller, &coroutine->context) != 0) {
        abla_platform_panic("cannot resume coroutine", 23);
    }
    host_current_coroutine = previous;
    host_root_frame = coroutine->caller_roots;
}

static void host_coroutine_free(AblaHostCoroutine* coroutine) {
    free(coroutine->stack);
    coroutine->stack = NULL;
    abla_platform_free(coroutine);
}

AblaValue abla_generator_create(
    AblaValue closure,
    AblaDispatch dispatch,
    AblaClosureCleanup release,
    AblaClosureCleanup drop) {
    AblaHostCoroutine* coroutine = host_coroutine_create(
        closure, dispatch, release, drop, true);
    return (AblaValue){
        .tag = ABLA_GENERATOR,
        .as.concurrent = coroutine};
}

AblaValue abla_generator_next(AblaValue generator) {
    AblaHostCoroutine* coroutine = host_as_coroutine(
        generator, ABLA_GENERATOR);
    coroutine->current = (AblaValue){.tag = ABLA_NULL};
    host_coroutine_resume(coroutine);
    return host_value_bool(coroutine->state == ABLA_COROUTINE_SUSPENDED);
}

AblaValue abla_generator_value(AblaValue generator) {
    AblaHostCoroutine* coroutine = host_as_coroutine(
        generator, ABLA_GENERATOR);
    if (coroutine->state != ABLA_COROUTINE_SUSPENDED) {
        abla_platform_panic("generator has no current value", 30);
    }
    return coroutine->current;
}

AblaValue abla_generator_yield(AblaValue value) {
    AblaHostCoroutine* coroutine = host_current_coroutine;
    if (coroutine == NULL || !coroutine->generator) {
        abla_platform_panic("yield outside generator", 23);
    }
    coroutine->current = value;
    coroutine->roots = host_root_frame;
    coroutine->state = ABLA_COROUTINE_SUSPENDED;
    host_root_frame = coroutine->caller_roots;
    if (swapcontext(&coroutine->context, &coroutine->caller) != 0) {
        abla_platform_panic("cannot suspend generator", 24);
    }
    host_root_frame = coroutine->roots;
    coroutine->state = ABLA_COROUTINE_RUNNING;
    return host_value_bool(!coroutine->cancelled);
}

AblaValue abla_generator_drop(AblaValue generator) {
    AblaHostCoroutine* coroutine = host_as_coroutine(
        generator, ABLA_GENERATOR);
    if (coroutine->state == ABLA_COROUTINE_CREATED) {
        coroutine->drop(&coroutine->closure);
        coroutine->closure = (AblaValue){.tag = ABLA_NULL};
    } else if (coroutine->state == ABLA_COROUTINE_SUSPENDED) {
        coroutine->cancelled = true;
        host_coroutine_resume(coroutine);
    }
    host_coroutine_free(coroutine);
    return host_value_void();
}

AblaValue abla_task_create(
    AblaValue closure,
    AblaDispatch dispatch,
    AblaClosureCleanup release,
    AblaClosureCleanup drop) {
    AblaHostCoroutine* coroutine = host_coroutine_create(
        closure, dispatch, release, drop, false);
    return (AblaValue){.tag = ABLA_TASK, .as.concurrent = coroutine};
}

AblaValue abla_task_drop(AblaValue task) {
    AblaHostCoroutine* coroutine = host_as_coroutine(task, ABLA_TASK);
    if (coroutine->state == ABLA_COROUTINE_CREATED) {
        coroutine->drop(&coroutine->closure);
        coroutine->closure = (AblaValue){.tag = ABLA_NULL};
    }
    host_coroutine_free(coroutine);
    return host_value_void();
}

static AblaHostThread* host_as_thread(AblaValue value) {
    if (value.tag != ABLA_THREAD || value.as.concurrent == NULL) {
        abla_platform_panic("invalid thread handle", 21);
    }
    return (AblaHostThread*)value.as.concurrent;
}

static void* host_thread_entry(void* opaque) {
    AblaHostThread* thread = (AblaHostThread*)opaque;
    AblaValue result = thread->dispatch(&thread->closure, NULL, 0);
    thread->result = result;
    thread->release(&thread->closure);
    thread->closure = (AblaValue){.tag = ABLA_NULL};
    (void)atomic_fetch_sub_explicit(
        &host_active_threads, 1, memory_order_release);
    return NULL;
}

AblaValue abla_thread_create(
    AblaValue closure,
    AblaDispatch dispatch,
    AblaClosureCleanup release,
    AblaClosureCleanup drop) {
    if (dispatch == NULL || release == NULL || drop == NULL) {
        abla_platform_panic("invalid thread callbacks", 24);
    }
    AblaHostThread* thread =
        (AblaHostThread*)abla_platform_alloc(sizeof(*thread));
    abla_platform_memory_set_layout(thread, 12);
    thread->closure = closure;
    thread->result = host_value_void();
    thread->dispatch = dispatch;
    thread->release = release;
    thread->drop = drop;
    thread->joined = false;
    (void)atomic_fetch_add_explicit(
        &host_active_threads, 1, memory_order_release);
    if (pthread_create(&thread->native, NULL, host_thread_entry, thread) != 0) {
        (void)atomic_fetch_sub_explicit(
            &host_active_threads, 1, memory_order_release);
        thread->drop(&thread->closure);
        abla_platform_free(thread);
        abla_platform_panic("cannot create thread", 20);
    }
    return (AblaValue){.tag = ABLA_THREAD, .as.concurrent = thread};
}

static void host_thread_join(AblaHostThread* thread) {
    if (!thread->joined) {
        if (pthread_join(thread->native, NULL) != 0) {
            abla_platform_panic("cannot join thread", 18);
        }
        thread->joined = true;
    }
}

AblaValue abla_thread_drop(AblaValue value) {
    AblaHostThread* thread = host_as_thread(value);
    host_thread_join(thread);
    abla_platform_free(thread);
    return host_value_void();
}

AblaValue abla_await(AblaValue operation) {
    if (operation.tag == ABLA_TASK) {
        AblaHostCoroutine* coroutine = host_as_coroutine(
            operation, ABLA_TASK);
        host_coroutine_resume(coroutine);
        if (coroutine->state != ABLA_COROUTINE_DONE) {
            abla_platform_panic("task did not complete", 21);
        }
        const AblaValue result = coroutine->result;
        host_coroutine_free(coroutine);
        return result;
    }
    if (operation.tag == ABLA_THREAD) {
        AblaHostThread* thread = host_as_thread(operation);
        host_thread_join(thread);
        const AblaValue result = thread->result;
        abla_platform_free(thread);
        return result;
    }
    abla_platform_panic("await expects task or thread", 28);
}

AblaValue ablaRuntimeMemoryCollect(void) {
    return host_value_i64(abla_platform_memory_collect(host_root_frame));
}

AblaValue ablaRuntimeMemoryPromoteString(AblaValue value) {
    if (value.tag != ABLA_STRING) {
        abla_platform_panic("expected string", 15);
    }
    const char* data = host_value_string_data(value);
    const bool previous_active = host_region_override_active;
    AblaHostRegion* previous_region = host_region_override;
    host_region_override_active = true;
    host_region_override = host_region_depth < 2
        ? NULL
        : &host_regions[host_region_depth - 2];
    AblaValue promoted = host_owned_string(data, value.as.string.length);
    host_region_override = previous_region;
    host_region_override_active = previous_active;
    return promoted;
}

AblaValue ablaRuntimeRegionBegin(void) {
    return host_value_i64(host_region_begin());
}

AblaValue ablaRuntimeRegionEnd(AblaValue checkpoint_value) {
    const int64_t checkpoint = host_value_as_i64(checkpoint_value);
    if (checkpoint < 0 ||
        !host_region_reset((uint64_t)checkpoint)) {
        abla_platform_panic("invalid region checkpoint", 25);
    }
    return host_value_void();
}

ABLA_HOST_FALLBACK void abla_runtime_roots_push(
    AblaRuntimeRootFrame* frame,
    void** roots,
    uint64_t count) {
    frame->previous = host_root_frame;
    frame->roots = roots;
    frame->count = count;
    host_root_frame = frame;
}

ABLA_HOST_FALLBACK void abla_runtime_roots_pop(AblaRuntimeRootFrame* frame) {
    if (host_root_frame != frame) {
        abla_platform_panic("unbalanced root frame", 21);
    }
    host_root_frame = frame->previous;
}

ABLA_HOST_FALLBACK void abla_runtime_memory_pressure(void) {
    host_initialize_allocation_limit();
    const size_t maximum_reserve = (size_t)64 * 1024 * 1024;
    const size_t proportional_reserve = host_allocation_limit / 4;
    const size_t reserve = proportional_reserve < maximum_reserve
        ? proportional_reserve
        : maximum_reserve;
    const size_t latest = host_allocation_limit - reserve;
    size_t trigger = host_collection_threshold;
    if (trigger > latest) trigger = latest;
    if (host_allocation_live_bytes < trigger) return;
    (void)abla_platform_memory_collect(host_root_frame);
    const size_t live = host_allocation_live_bytes;
    const size_t growth = live / 2 > reserve ? live / 2 : reserve;
    size_t next = live > SIZE_MAX - growth
        ? latest
        : live + growth;
    if (next < host_collection_threshold) next = host_collection_threshold;
    host_collection_threshold = next > latest ? latest : next;
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
