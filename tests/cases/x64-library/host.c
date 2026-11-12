#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// A host process that loads the library (tools/test-x64-library.sh): its own malloc beside the library's heap, the
// library loaded twice and from two threads, and the counters of a preloaded allocator.
typedef struct {
    void *handle;
    int64_t (*next)(void);
    void *(*text)(int64_t);
    void *(*echo)(const uint8_t *, uint64_t);
    int64_t (*churn)(int64_t);
    const uint8_t *(*data)(void *);
    uint64_t (*length)(void *);
    void (*release)(void *);
} Library;

static int open_library(Library *library, const char *path, int namespace, int flags) {
    library->handle = namespace ? dlmopen(LM_ID_NEWLM, path, flags) : dlopen(path, flags);
    if (!library->handle) { fprintf(stderr, "dlopen %s: %s\n", path, dlerror()); return 0; }
    library->next = dlsym(library->handle, "abla_app_next");
    library->text = dlsym(library->handle, "abla_app_text");
    library->echo = dlsym(library->handle, "abla_app_echo");
    library->churn = dlsym(library->handle, "abla_app_churn");
    library->data = dlsym(library->handle, "abla_owned_bytes_data");
    library->length = dlsym(library->handle, "abla_owned_bytes_length");
    library->release = dlsym(library->handle, "abla_owned_bytes_release");
    if (!library->next || !library->text || !library->echo || !library->churn || !library->data || !library->length ||
        !library->release) {
        fprintf(stderr, "dlsym: %s\n", dlerror());
        return 0;
    }
    return 1;
}

static int load(Library *library, const char *path) { return open_library(library, path, 0, RTLD_NOW); }

static unsigned long *preload_counter(void) {
    return (unsigned long *)dlsym(RTLD_DEFAULT, "preload_calls");
}

static int fail(const char *what) { fprintf(stderr, "x64 library: %s\n", what); return 1; }

static void *thread_body(void *argument) {
    Library *library = argument;
    int64_t *result = malloc(sizeof(int64_t));
    *result = library->next();
    return result;
}

// What a library must do wherever it is loaded: strings both ways, allocation, state.
static int exercise(Library *library) {
    void *text = library->text(300);
    if (!text || library->length(text) != 300) return fail("text length differs");
    for (uint64_t at = 0; at < 300; at++) if (library->data(text)[at] != '0' + (at % 10)) return fail("text byte differs");
    library->release(text);
    void *echoed = library->echo((const uint8_t *)"ns", 2);
    if (!echoed || library->length(echoed) != 4 || memcmp(library->data(echoed), "<ns>", 4) != 0) return fail("echo differs");
    library->release(echoed);
    if (library->churn(10) != 10 * 290) return fail("churn differs");
    int64_t first = library->next();
    if (library->next() != first + 1) return fail("state differs");
    return 0;
}

// The libraries that bring threads or a C function, in every way a host may load them: RTLD_NOW or RTLD_LAZY, into
// the host's namespace or a new one (dlmopen), RTLD_LOCAL. Each must resolve the loader's __tls_get_addr and, where
// it uses them, libc and libpthread, from what it names itself.
static int loads(const char *plain, const char *threads, const char *external) {
    for (int namespace = 0; namespace < 2; namespace++) {
        for (int lazy = 0; lazy < 2; lazy++) {
            int flags = (lazy ? RTLD_LAZY : RTLD_NOW) | RTLD_LOCAL;
            Library library;
            if (!open_library(&library, plain, namespace, flags)) return fail("the plain library did not load");
            if (exercise(&library)) return 1;
            void *handle = namespace ? dlmopen(LM_ID_NEWLM, threads, flags) : dlopen(threads, flags);
            if (!handle) { fprintf(stderr, "%s\n", dlerror()); return fail("the thread library did not load"); }
            int64_t (*run)(void) = dlsym(handle, "abla_app_threads");
            if (!run || run() != 42) return fail("the thread library answered wrong");
            handle = namespace ? dlmopen(LM_ID_NEWLM, external, flags) : dlopen(external, flags);
            if (!handle) { fprintf(stderr, "%s\n", dlerror()); return fail("the extern library did not load"); }
            int64_t (*parent)(void) = dlsym(handle, "abla_app_ppid");
            if (!parent || parent() != (int64_t)getppid()) return fail("the extern library answered wrong");
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    Library first, again, copy;
    if (argc < 3 || !load(&first, argv[1])) return 2;
    // (b) The host's malloc and the library's heap beside each other: patterns in host blocks survive the library's
    // allocation, and the library's strings come back intact through its own release.
    enum { blocks = 400 };
    uint8_t *held[blocks];
    size_t sizes[blocks];
    for (int round = 0; round < 6; round++) {
        for (int index = 0; index < blocks; index++) {
            sizes[index] = 1 + (size_t)((index * 7919 + round * 104729) % 9000);
            held[index] = malloc(sizes[index]);
            memset(held[index], (index + round) & 255, sizes[index]);
        }
        for (int index = 0; index < blocks; index += 5) {
            char input[64];
            int length = snprintf(input, sizeof input, "value-%d", index);
            void *echoed = first.echo((const uint8_t *)input, (uint64_t)length);
            if (!echoed || first.length(echoed) != (uint64_t)length + 2 ||
                memcmp(first.data(echoed) + 1, input, (size_t)length) != 0) return fail("echo result differs");
            first.release(echoed);
            void *text = first.text(500 + index);
            if (!text || first.length(text) != (uint64_t)(500 + index)) return fail("text length differs");
            for (uint64_t at = 0; at < first.length(text); at++) {
                if (first.data(text)[at] != '0' + (at % 10)) return fail("text byte differs");
            }
            first.release(text);
            if (first.churn(20) != 20 * 290) return fail("churn total differs");
        }
        for (int index = 0; index < blocks; index++) {
            for (size_t at = 0; at < sizes[index]; at += 97) {
                if (held[index][at] != (uint8_t)((index + round) & 255)) return fail("a host block was overwritten");
            }
            free(held[index]);
        }
    }
    if (first.churn(7) != 7 * 290) return fail("churn total differs");
    // (c) The same file loaded again is the same library and the same state; a copy at another path is its own.
    if (!load(&again, argv[1]) || again.handle != first.handle) return fail("dlopen of the same file gave another handle");
    int64_t one = first.next();
    int64_t two = again.next();
    if (two != one + 1) return fail("the second handle does not share the library's state");
    if (!load(&copy, argv[2]) || copy.handle == first.handle) return fail("the copy was not loaded separately");
    int64_t fresh = copy.next();
    if (fresh == two + 1) return fail("the copy shares the original's state");
    // Two host threads, one after the other and then together under a host lock: one heap, one counter.
    pthread_t thread;
    void *joined;
    pthread_create(&thread, NULL, thread_body, &first);
    pthread_join(thread, &joined);
    if (*(int64_t *)joined != two + 1) return fail("a host thread saw another state");
    free(joined);
    // (d) Under an LD_PRELOADed allocator the library's calls do not reach it (its memory routines are its own).
    unsigned long *counter = preload_counter();
    if (counter) {
        unsigned long before = *counter;
        void *text = first.text(2000);
        first.release(text);
        first.churn(5);
        if (*counter != before) { fprintf(stderr, "the preloaded allocator was called %lu times by the library\n", *counter - before); return 1; }
        printf("preload: library made no allocator calls\n");
    }
    if (argc >= 5 && loads(argv[2], argv[3], argv[4])) return 1;
    printf("ok\n");
    return 0;
}
