// Loads libabla_app.so with bionic's linker, as an app's System.loadLibrary would, and calls its exports.
//   driver <library> <export> <expected>|nonzero ...        each export once, on the main thread
//   driver <library> -b <milliseconds>                      an export blocked in the host (abla_test_host_block) on one
//                                                           pthread while another calls abla_run_churn: collections must
//                                                           stop it (abla_run_stops) and abandon nothing (abla_run_abandoned)
//   driver <library> -t <threads> <export> <expected>       one export from <threads> pthreads the library did not
//                                                           start (JNI-style), each passing its own number 1..N
// The driver is linked with --export-dynamic: the library's undefined abla_test_host_hook is this file's.
// Each call prints "<name> <result>"; the program exits 0 only when every result is the expected one.
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

static void *run_job(void *argument) {
    struct job *job = argument;
    job->result = job->function(job->number);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    void *library = dlopen(argv[1], RTLD_NOW);
    if (!library) { printf("dlopen: %s\n", dlerror()); return 3; }
    nested_function = (export_function)dlsym(library, "abla_run_nested");
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
        for (int index = 0; index < count; index++) {
            jobs[index].function = function;
            jobs[index].number = index + 1;
            if (pthread_create(&threads[index], 0, run_job, &jobs[index]) != 0) { printf("pthread_create failed\n"); return 4; }
        }
        for (int index = 0; index < count; index++) {
            pthread_join(threads[index], 0);
            if (jobs[index].result != expected) failed = 1;
        }
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
