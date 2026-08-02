#include <stdint.h>
#include <stddef.h>

extern int64_t abla_app_answer(void);
extern int64_t abla_app_add(int64_t value, int64_t delta);
extern int64_t abla_app_bytes_score(const uint8_t *data, uint64_t length);
extern int64_t abla_app_bytes_length(const uint8_t *data, uint64_t length);

int main(void) {
    const uint8_t bytes[] = {39, 0, 255};
    return abla_app_answer() == 42 &&
        abla_app_add(19, 23) == 42 &&
        abla_app_bytes_score(bytes, 3) == 42 &&
        abla_app_bytes_length(NULL, 0) == 0 ? 0 : 1;
}
