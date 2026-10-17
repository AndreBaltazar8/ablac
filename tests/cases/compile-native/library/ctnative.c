/* A small shared library a compile-time evaluation loads and calls. */
#include <stdint.h>

static int64_t calls;

int64_t ctnative_mix(int64_t left, int32_t right) {
    calls = calls + 1;
    return left * 1000 + right;
}

double ctnative_scale(double value, float factor) {
    return value * (double)factor;
}

int64_t ctnative_calls(void) {
    return calls;
}
