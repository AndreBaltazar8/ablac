// Loads libabla_app.so with bionic's linker, as an app's System.loadLibrary would, and calls its exports.
// Each prints "<name> <result>" and the program exits 0 only when every result is the expected one.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    void *library = dlopen(argv[1], RTLD_NOW);
    if (!library) { printf("dlopen: %s\n", dlerror()); return 3; }
    int failed = 0;
    for (int index = 2; index + 1 < argc; index += 2) {
        int64_t (*function)(void) = (int64_t (*)(void))dlsym(library, argv[index]);
        if (!function) { printf("dlsym %s: %s\n", argv[index], dlerror()); failed = 1; continue; }
        int64_t result = function();
        printf("%s %lld\n", argv[index], (long long)result);
        if (strcmp(argv[index + 1], "nonzero") == 0 ? result <= 0 : result != strtoll(argv[index + 1], 0, 10)) failed = 1;
    }
    return failed;
}
