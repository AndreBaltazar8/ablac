#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <string.h>

// An LD_PRELOADed allocator and memcpy that count their calls (tools/test-x64-library.sh): the count is read from the
// host through dlsym(RTLD_DEFAULT, "preload_calls").
unsigned long preload_calls;

static void *(*real_malloc)(size_t);
static void (*real_free)(void *);
static void *(*real_realloc)(void *, size_t);
static void *(*real_memcpy)(void *, const void *, size_t);

void *malloc(size_t size) {
    if (!real_malloc) real_malloc = dlsym(RTLD_NEXT, "malloc");
    preload_calls++;
    return real_malloc(size);
}
void free(void *pointer) {
    if (!real_free) real_free = dlsym(RTLD_NEXT, "free");
    preload_calls++;
    real_free(pointer);
}
void *realloc(void *pointer, size_t size) {
    if (!real_realloc) real_realloc = dlsym(RTLD_NEXT, "realloc");
    preload_calls++;
    return real_realloc(pointer, size);
}
void *memcpy(void *destination, const void *source, size_t size) {
    if (!real_memcpy) real_memcpy = dlsym(RTLD_NEXT, "memcpy");
    preload_calls++;
    return real_memcpy(destination, source, size);
}
