// Loads libabla_app.so with bionic's linker, as an app's System.loadLibrary would, and calls its exports.
//   driver <library> <export> <expected>|nonzero ...        each export once, on the main thread
//   driver <library> -b <milliseconds>                      an export blocked in the host (abla_test_host_block) on one
//                                                           pthread while another calls abla_run_churn: collections must
//                                                           stop it (abla_run_stops) and abandon nothing (abla_run_abandoned)
//   driver <library> -t <threads> <export> <expected>       one export from <threads> pthreads the library did not
//                                                           start (JNI-style), each passing its own number 1..N
//   driver <library> -n <export> <expected>                 without installing the host table first (a plain dlopen): the
//                                                           export must end the process with status 70 and a message
//   driver <library> -j <libabla_jni.so> ...                the table installed by the generated libabla_jni.so's JNI_OnLoad
//                                                           (linked against the library, as the app's CMake links it),
//                                                           then any of the modes above
// Before any export it installs the table of bionic functions the library calls through (abla-app.h, generated with the
// library), as the app's libabla_jni.so does in JNI_OnLoad, and checks what abla_android_host_install answers.
// The driver is linked with --export-dynamic: the library's undefined abla_test_host_hook is this file's.
// Each call prints "<name> <result>"; the program exits 0 only when every result is the expected one.
#ifdef TEST_DELAY_KEY
#define _GNU_SOURCE
#include <errno.h>
#endif
#include "abla-app.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef int64_t (*export_function)(int64_t);

static export_function nested_function;

// The library calls this while its globals initialize (tests/cases/foreign-threads/shared.ab); it calls an export again.
__attribute__((visibility("default"))) int64_t abla_test_host_hook(void) {
    return nested_function ? nested_function(0) + 1 : -1;
}

// What abla_run_block calls (tests/cases/foreign-threads/blocking.ab): blocks this thread inside the library's export, then
// calls an export of the library again from there (abla_run_nested: 77), as a JNI callback may; 1 when that answered.
__attribute__((visibility("default"))) int64_t abla_test_host_block(int64_t milliseconds) {
    struct timespec request = { milliseconds / 1000, (milliseconds % 1000) * 1000000 };
    nanosleep(&request, 0);
    return nested_function && nested_function(0) == 77 ? 1 : 0;
}

struct job {
    export_function function;
    int64_t number;
    int64_t result;
};

#ifdef TEST_DELAY_KEY
static pthread_barrier_t start_jobs;

// Widen the window between the library claiming initialization and publishing its bionic TLS key.
int pthread_key_create(pthread_key_t *key, void (*destroy)(void *)) {
    int (*create)(pthread_key_t *, void (*)(void *)) = dlsym(RTLD_NEXT, "pthread_key_create");
    if (!create) return ENOSYS;
    fputs("android test: delayed pthread_key_create\n", stderr);
    struct timespec delay = { .tv_nsec = 125000000 };
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
    return create(key, destroy);
}
#endif

static void *run_job(void *argument) {
    struct job *job = argument;
#ifdef TEST_DELAY_KEY
    int status = pthread_barrier_wait(&start_jobs);
    if (status != 0 && status != PTHREAD_BARRIER_SERIAL_THREAD) _Exit(4);
#endif
    job->result = job->function(job->number);
    return 0;
}

int main(int argc, char **argv) {
    int install = 1;
    if (argc > 3 && strcmp(argv[2], "-n") == 0) {
        install = 0;
        for (int index = 2; index + 1 < argc; index++) argv[index] = argv[index + 1];
        argc--;
    }
    const char *jni = 0;
    if (install && argc > 4 && strcmp(argv[2], "-j") == 0) {
        jni = argv[3];
        for (int index = 2; index + 2 < argc; index++) argv[index] = argv[index + 2];
        argc -= 2;
    }
    if (argc < 3) return 2;
    void *library = dlopen(argv[1], RTLD_NOW);
    if (!library) { printf("dlopen: %s\n", dlerror()); return 3; }
    if (jni) {
        void *adapter = dlopen(jni, RTLD_NOW);
        if (!adapter) { printf("dlopen %s: %s\n", jni, dlerror()); return 3; }
        int32_t (*on_load)(void *, void *) = (int32_t (*)(void *, void *))dlsym(adapter, "JNI_OnLoad");
        if (!on_load) { printf("dlsym JNI_OnLoad: %s\n", dlerror()); return 3; }
        // JNI_VERSION_1_6; the generated JNI_OnLoad uses neither argument.
        int32_t version = on_load(0, 0);
        fprintf(stderr, "JNI_OnLoad 0x%x\n", (unsigned)version);
        if (version != 0x10006) return 3;
    } else if (install) {
        int64_t (*install_host)(const struct abla_android_host *) =
            (int64_t (*)(const struct abla_android_host *))dlsym(library, "abla_android_host_install");
        if (!install_host) { printf("dlsym abla_android_host_install: %s\n", dlerror()); return 3; }
        static const struct abla_android_host host = { ABLA_ANDROID_HOST_VERSION, ABLA_ANDROID_HOST_COUNT,
            pthread_key_create, pthread_getspecific, pthread_setspecific, pthread_create, pthread_join };
        struct abla_android_host other = host, newer = host;
        newer.version = 2;
        // The first table stays: installing it again answers 0, another one 1, one of a version the library does not know -1.
        int64_t first = install_host(&host), again = install_host(&host), second = install_host(&other),
            unknown = install_host(&newer);
        fprintf(stderr, "host table: %lld %lld %lld %lld\n", (long long)first, (long long)again, (long long)second,
            (long long)unknown);
        if (first != 0 || again != 0 || second != 1 || unknown != -1) return 3;
    }
    nested_function = (export_function)dlsym(library, "abla_run_nested");
    // A library has no process environment to read ABLA_GC_STRESS and ABLA_GC_TRACE from: pass them on as calls.
    const char *stress = getenv("ABLA_GC_STRESS"), *trace = getenv("ABLA_GC_TRACE");
    export_function set_stress = (export_function)dlsym(library, "abla_run_stress");
    export_function set_trace = (export_function)dlsym(library, "abla_run_trace");
    if (trace && strcmp(trace, "1") == 0 && set_trace) set_trace(1);
    if (stress && strcmp(stress, "1") == 0 && set_stress) set_stress(1);
    int failed = 0;
    if (strcmp(argv[2], "-b") == 0) {
        if (argc != 4) return 2;
        export_function block = (export_function)dlsym(library, "abla_run_block");
        export_function churn = (export_function)dlsym(library, "abla_run_churn");
        export_function stops = (export_function)dlsym(library, "abla_run_stops");
        export_function abandoned = (export_function)dlsym(library, "abla_run_abandoned");
        export_function enable = (export_function)dlsym(library, "abla_run_enable");
        if (!block || !churn || !stops || !abandoned || !enable) { printf("dlsym: %s\n", dlerror()); return 3; }
        enable(0);
        struct job job = { block, atoll(argv[3]), 0 };
        pthread_t thread;
        if (pthread_create(&thread, 0, run_job, &job) != 0) { printf("pthread_create failed\n"); return 4; }
        // The other thread is in the host's sleep by now.
        struct timespec wait = { 0, 300 * 1000000 };
        nanosleep(&wait, 0);
        int64_t stops_before = stops(0), abandoned_before = abandoned(0);
        for (int round = 0; round < 20; round++) if (churn(1) != 1) failed = 1;
        int64_t stopped = stops(0) - stops_before, gave_up = abandoned(0) - abandoned_before;
        pthread_join(thread, 0);
        if (job.result != 1) failed = 1;
        if (stopped < 1 || gave_up != 0) failed = 1;
        printf("blocked in the host: %lld collections stopped it, %lld abandoned %s\n",
               (long long)stopped, (long long)gave_up, failed ? "failed" : "ok");
        return failed;
    }
    if (strcmp(argv[2], "-t") == 0) {
        if (argc != 6) return 2;
        int count = atoi(argv[3]);
        export_function function = (export_function)dlsym(library, argv[4]);
        if (!function) { printf("dlsym %s: %s\n", argv[4], dlerror()); return 3; }
        int64_t expected = strtoll(argv[5], 0, 10);
        struct job *jobs = calloc(count, sizeof *jobs);
        pthread_t *threads = calloc(count, sizeof *threads);
#ifdef TEST_DELAY_KEY
        if (pthread_barrier_init(&start_jobs, 0, count) != 0) return 4;
#endif
        for (int index = 0; index < count; index++) {
            jobs[index].function = function;
            jobs[index].number = index + 1;
            if (pthread_create(&threads[index], 0, run_job, &jobs[index]) != 0) { printf("pthread_create failed\n"); return 4; }
        }
        for (int index = 0; index < count; index++) {
            pthread_join(threads[index], 0);
            if (jobs[index].result != expected) failed = 1;
        }
#ifdef TEST_DELAY_KEY
        pthread_barrier_destroy(&start_jobs);
#endif
        printf("%s x%d %s\n", argv[4], count, failed ? "failed" : "ok");
        return failed;
    }
    for (int index = 2; index + 1 < argc; index += 2) {
        export_function function = (export_function)dlsym(library, argv[index]);
        if (!function) { printf("dlsym %s: %s\n", argv[index], dlerror()); failed = 1; continue; }
        int64_t result = function(0);
        printf("%s %lld\n", argv[index], (long long)result);
        if (strcmp(argv[index + 1], "nonzero") == 0 ? result <= 0 : result != strtoll(argv[index + 1], 0, 10)) failed = 1;
    }
    return failed;
}
