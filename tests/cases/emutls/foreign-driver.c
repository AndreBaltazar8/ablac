// Waves of short-lived pthreads call one export of a library that uses abla/runtime/emutls (foreign-lib.ab), and the
// library's live heap bytes are read before and after (tools/test-emutls.sh, #826):
//   foreign-driver <library> <waves> <threads per wave> <bytes allowed before a reclaim>
// Every thread ends before the next wave starts and the main thread joins it. The first wave warms the library up (the
// key, the counters); the bytes live after the others must be the bytes live before them, once abla_emutls_reclaim has
// swept: on macOS a pthread key's destructor has freed each thread's table as the thread ended (allowed 0 before the sweep);
// on Linux a later thread's registration finds the ended threads by tgkill and frees them, lazily, so a bounded few
// are still there before the sweep. Exits 0 only when every call answered 1, no byte is left after the sweep and no
// more than the allowed bytes before it.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <string.h>
#include <ucontext.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef int64_t (*export_function)(int64_t);

// A trap in the library ends the process with SIGILL and no word (master CI, Intel macOS, 2026-11-19: "exit 132:"). The handler says
// where: the faulting address and the calls above it, each as an offset into its image (tools/test-emutls.sh turns the
// offsets of the library into symbols with nm), and then lets the signal take its course.
static void *fault_pc(void *context) {
    ucontext_t *uc = context;
#if defined(__APPLE__) && defined(__x86_64__)
    return (void *)uc->uc_mcontext->__ss.__rip;
#elif defined(__APPLE__) && defined(__aarch64__)
    return (void *)uc->uc_mcontext->__ss.__pc;
#elif defined(__linux__) && defined(__x86_64__)
    return (void *)uc->uc_mcontext.gregs[REG_RIP];
#else
    (void)uc;
    return 0;
#endif
}

static void say_address(const char *label, void *address) {
    Dl_info info;
    if (address && dladdr(address, &info) && info.dli_fname) {
        fprintf(stderr, "emutls-trap: %s offset 0x%lx in %s (%s)\n", label, (unsigned long)((char *)address - (char *)info.dli_fbase),
                info.dli_fname, info.dli_sname ? info.dli_sname : "?");
    } else fprintf(stderr, "emutls-trap: %s address %p\n", label, address);
}

static volatile int trapped;

static void on_trap(int signal_number, siginfo_t *info, void *context) {
    (void)info;
    if (__sync_lock_test_and_set(&trapped, 1)) { sleep(30); return; }
    fprintf(stderr, "emutls-trap: signal %d\n", signal_number);
    say_address("at", fault_pc(context));
    void *frames[24];
    int count = backtrace(frames, 24);
    for (int index = 0; index < count; index++) say_address("frame", frames[index]);
    fflush(stderr);
    signal(signal_number, SIG_DFL);
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
    struct sigaction trap;
    memset(&trap, 0, sizeof trap);
    trap.sa_sigaction = on_trap;
    trap.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGILL, &trap, 0);
    sigaction(SIGSEGV, &trap, 0);
    sigaction(SIGBUS, &trap, 0);
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
    // A joined thread can still answer tgkill for a moment (the kernel wakes the joiner before it is gone for good): a sweep
    // leaves that one for the next, so the sweeps repeat, a few milliseconds apart, until the bytes live stop falling.
    reclaim(0); // the warm-up wave's ended threads: the baseline is what is live with none waiting
    usleep(50000);
    reclaim(0);
    int64_t before = live(0);
    for (int round = 0; round < waves; round++) failed |= wave(touch, threads, 1 + round);
    int64_t pending = live(0) - before;
    int64_t found = reclaim(0);
    int64_t left = live(0) - before;
    for (int again = 0; again < 200 && left != 0; again++) {
        usleep(5000);
        found += reclaim(0);
        left = live(0) - before;
    }
    printf("emutls foreign threads: %d threads, %lld bytes waiting before a reclaim (%lld threads found), %lld bytes left after (%lld live before)%s\n",
           waves * threads, (long long)pending, (long long)found, (long long)left, (long long)before, failed ? ", a call failed" : "");
    return failed || left != 0 || pending > allowed;
}
