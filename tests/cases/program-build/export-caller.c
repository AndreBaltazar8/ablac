#include <stdint.h>

extern int64_t abla_app_answer(void);
extern int64_t abla_app_add(int64_t value, int64_t delta);

int main(void) {
    return abla_app_answer() == 42 && abla_app_add(19, 23) == 42 ? 0 : 1;
}
