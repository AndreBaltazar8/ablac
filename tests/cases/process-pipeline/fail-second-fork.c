#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <sys/types.h>
#include <unistd.h>

pid_t fork(void) {
    static int calls;
    if (++calls == 2) { errno = EAGAIN; return -1; }
    pid_t (*actual)(void) = dlsym(RTLD_NEXT, "fork");
    return actual();
}
