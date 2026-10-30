// Calls the export many times without running the library's main; each call
// collects. A freed global shows up as a wrong checksum or a crash.
#include <stdint.h>
#include <stdio.h>

int64_t export_roots_touch(int64_t round);

int main(void) {
    for (int64_t round = 0; round < 50; round++) {
        int64_t value = export_roots_touch(round);
        if (value != 2651) {
            fprintf(stderr, "round %lld: checksum %lld, expected 2651\n", (long long)round, (long long)value);
            return 1;
        }
    }
    puts("export globals survive collection");
    return 0;
}
