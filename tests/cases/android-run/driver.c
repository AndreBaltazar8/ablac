// Loads libabla_app.so with bionic's linker, as an app's System.loadLibrary would, and calls its exports.
//   driver <library> <export> <expected>|nonzero ...        each export once, on the main thread
//   driver <library> -t <threads> <export> <expected>       one export from <threads> pthreads the library did not
//                                                           start (JNI-style), each passing its own number 1..N
// Each call prints "<name> <result>"; the program exits 0 only when every result is the expected one.
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int64_t (*export_function)(int64_t);

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
    int failed = 0;
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
