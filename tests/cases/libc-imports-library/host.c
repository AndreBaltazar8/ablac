#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

// Loads the library and calls its exported function (tools/test-libc-imports.sh).
int main(int argc, char **argv) {
    void *library = dlopen(argv[1], RTLD_NOW);
    if (!library) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    int64_t (*answer)(void) = (int64_t (*)(void))dlsym(library, "abla_app_answer");
    if (!answer) { fprintf(stderr, "dlsym: %s\n", dlerror()); return 3; }
    printf("%lld\n", (long long)answer());
    return 0;
}
