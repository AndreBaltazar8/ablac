#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

// A host that forks while one of its own threads allocates in the library (tools/test-fork-heap.sh, #812): the
// child allocates in the library and must not wait for ever on a heap lock the other thread held at the fork.
static int64_t (*churn)(void);

static void *churner(void *unused) {
    (void)unused;
    churn();
    return NULL;
}

int main(int argc, char **argv) {
    void *handle = dlopen(argv[1], RTLD_NOW);
    if (!handle) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    int64_t (*enable)(void) = dlsym(handle, "abla_fork_enable");
    int64_t (*stop)(void) = dlsym(handle, "abla_fork_stop");
    int64_t (*child)(void) = dlsym(handle, "abla_fork_child");
    churn = dlsym(handle, "abla_fork_churn");
    if (!enable || !stop || !child || !churn) { fprintf(stderr, "dlsym: %s\n", dlerror()); return 1; }
    if (enable() != 42) { fprintf(stderr, "enable failed\n"); return 1; }
    pthread_t thread;
    pthread_create(&thread, NULL, churner, NULL);
    int failures = 0;
    for (int fork_count = 0; fork_count < 300; fork_count++) {
        pid_t process = fork();
        if (process == 0) {
            alarm(20);
            _exit((int)child());
        }
        int status = 0;
        if (process < 0 || waitpid(process, &status, 0) != process || status != 0) failures++;
    }
    stop();
    pthread_join(thread, NULL);
    if (failures) { printf("fork heap library: %d children failed\n", failures); return 1; }
    printf("fork heap library ok\n");
    return 0;
}
