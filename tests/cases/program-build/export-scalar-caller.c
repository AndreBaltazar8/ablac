#include <stdint.h>

extern int64_t abla_scalar_next(void);

int main(void) {
    return abla_scalar_next() == 41 && abla_scalar_next() == 42 ? 0 : 1;
}
