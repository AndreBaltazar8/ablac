#include <stdint.h>
#include <stddef.h>
#include <string.h>

extern int64_t abla_app_answer(void);
extern int64_t abla_app_add(int64_t value, int64_t delta);
extern int64_t abla_app_bytes_score(const uint8_t *data, uint64_t length);
extern int64_t abla_app_bytes_length(const uint8_t *data, uint64_t length);
extern void *abla_app_echo_bytes(const uint8_t *data, uint64_t length);
extern const uint8_t *abla_owned_bytes_data(void *handle);
extern uint64_t abla_owned_bytes_length(void *handle);
extern void abla_owned_bytes_release(void *handle);

int main(void) {
    const uint8_t bytes[] = {39, 0, 255};
    void *echo = abla_app_echo_bytes(bytes, 3);
    int valid = echo != NULL &&
        abla_owned_bytes_length(echo) == 3 &&
        memcmp(abla_owned_bytes_data(echo), bytes, 3) == 0;
    abla_owned_bytes_release(echo);
    return valid && abla_app_answer() == 42 &&
        abla_app_add(19, 23) == 42 &&
        abla_app_bytes_score(bytes, 3) == 42 &&
        abla_app_bytes_length(NULL, 0) == 0 ? 0 : 1;
}
