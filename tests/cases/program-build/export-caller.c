#include <stdint.h>

extern int64_t abla_app_answer(void);

int main(void) {
    return abla_app_answer() == 42 ? 0 : 1;
}
