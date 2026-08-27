#include <stdint.h>

extern int64_t abla_scalar_next(void);
extern uint32_t abla_scalar_add_u32(uint32_t left, uint32_t right);

int main(void) {
    return abla_scalar_next() == 41 && abla_scalar_next() == 42 &&
        abla_scalar_add_u32(UINT32_C(4000000000), UINT32_C(7)) ==
            UINT32_C(4000000007) ? 0 : 1;
}
