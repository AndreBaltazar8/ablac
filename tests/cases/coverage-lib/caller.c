#include <stdio.h>
extern long coverage_entry(void);
extern void abla_coverage_write(const char *path);
int main(int argc, char **argv) {
    long value = coverage_entry();
    if (argc > 1) abla_coverage_write(argv[1]);
    return value == 42 ? 0 : 1;
}
