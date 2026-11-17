// Waves of short-lived pthreads call one export of a library that uses abla/runtime/emutls (foreign-lib.ab), and the
// library's live heap bytes are read before and after (tools/test-emutls.sh, #826):
//   foreign-driver <library> <waves> <threads per wave> [report]
// Every thread ends before the next wave starts and the main thread joins it, so the system has run each thread's key
// destructor by then. The first wave warms the library up (the key, the counters); the bytes live after the others must be
// the bytes live before them. Exits 0 only when every call answered 1 and no byte was left; with "report" the bytes left are
// printed and do not decide (Linux: the runtime has no thread-end notice for a thread it did not start without libc, #806).
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

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

static int wave(export_function touch, int threads, int64_t first) {
    struct job *jobs = calloc(threads, sizeof *jobs);
    pthread_t *handles = calloc(threads, sizeof *handles);
    int failed = 0;
    for (int index = 0; index < threads; index++) {
        jobs[index].function = touch;
        jobs[index].number = first + index;
        if (pthread_create(&handles[index], 0, run_job, &jobs[index]) != 0) { printf("pthread_create failed\n"); return 1; }
    }
    for (int index = 0; index < threads; index++) {
        pthread_join(handles[index], 0);
        if (jobs[index].result != 1) failed = 1;
    }
    free(jobs);
    free(handles);
    return failed;
}

int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) return 2;
    int report = argc == 5;
    void *library = dlopen(argv[1], RTLD_NOW);
    if (!library) { printf("dlopen: %s\n", dlerror()); return 3; }
    export_function setup = (export_function)dlsym(library, "abla_emutls_setup");
    export_function touch = (export_function)dlsym(library, "abla_emutls_touch");
    export_function live = (export_function)dlsym(library, "abla_emutls_live");
    if (!setup || !touch || !live) { printf("dlsym: %s\n", dlerror()); return 3; }
    int waves = atoi(argv[2]), threads = atoi(argv[3]);
    setup(0);
    int failed = wave(touch, threads, 1);
    int64_t before = live(0);
    for (int round = 0; round < waves; round++) failed |= wave(touch, threads, 1 + round);
    int64_t after = live(0);
    int64_t left = after - before;
    printf("emutls foreign threads: %d threads, %lld bytes left (%lld before, %lld after)%s\n", waves * threads, (long long)left,
           (long long)before, (long long)after, failed ? ", a call failed" : "");
    return failed || (!report && left != 0);
}
