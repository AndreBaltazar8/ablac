// Waves of short-lived pthreads call one export of a library that uses abla/runtime/emutls (foreign-lib.ab), and the
// library's live heap bytes are read before and after (tools/test-emutls.sh, #826):
//   foreign-driver <library> <waves> <threads per wave> <bytes allowed before a reclaim>
// Every thread ends before the next wave starts and the main thread joins it. The first wave warms the library up (the
// key, the counters); the bytes live after the others must be the bytes live before them, once abla_emutls_reclaim has
// swept: on macOS a pthread key's destructor has freed each thread's table as the thread ended (allowed 0 before the sweep);
// on Linux a later thread's registration finds the ended threads by tgkill and frees them, lazily, so a bounded few
// are still there before the sweep. Exits 0 only when every call answered 1, no byte is left after the sweep and no
// more than the allowed bytes before it.
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
    if (argc != 5) return 2;
    long long allowed = atoll(argv[4]);
    void *library = dlopen(argv[1], RTLD_NOW);
    if (!library) { printf("dlopen: %s\n", dlerror()); return 3; }
    export_function setup = (export_function)dlsym(library, "abla_emutls_setup");
    export_function touch = (export_function)dlsym(library, "abla_emutls_touch");
    export_function live = (export_function)dlsym(library, "abla_emutls_live");
    export_function reclaim = (export_function)dlsym(library, "abla_emutls_reclaim");
    if (!setup || !touch || !live || !reclaim) { printf("dlsym: %s\n", dlerror()); return 3; }
    int waves = atoi(argv[2]), threads = atoi(argv[3]);
    setup(0);
    int failed = wave(touch, threads, 1);
    reclaim(0); // the warm-up wave's ended threads: the baseline is what is live with none waiting
    int64_t before = live(0);
    for (int round = 0; round < waves; round++) failed |= wave(touch, threads, 1 + round);
    int64_t pending = live(0) - before;
    int64_t found = reclaim(0);
    int64_t left = live(0) - before;
    printf("emutls foreign threads: %d threads, %lld bytes waiting before a reclaim (%lld threads found), %lld bytes left after (%lld live before)%s\n",
           waves * threads, (long long)pending, (long long)found, (long long)left, (long long)before, failed ? ", a call failed" : "");
    return failed || left != 0 || pending > allowed;
}
