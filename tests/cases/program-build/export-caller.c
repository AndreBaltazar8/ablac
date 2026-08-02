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
typedef int64_t (*abla_i64_callback)(void *context, int64_t value);
extern int64_t abla_app_invoke(
    abla_i64_callback callback,
    void *context,
    int64_t value
);
extern int32_t abla_app_checked_divide(
    int64_t value,
    int64_t *result,
    uint8_t *error_data,
    uint64_t error_capacity,
    uint64_t *error_length
);

static int64_t add_context(void *context, int64_t value) {
    return *(const int64_t *)context + value;
}

int main(void) {
    const uint8_t bytes[] = {39, 0, 255};
    const int64_t context = 19;
    int64_t checked_result = -1;
    uint8_t checked_error[32] = {0};
    uint64_t checked_error_length = 0;
    int32_t panic_status = abla_app_checked_divide(
        0,
        &checked_result,
        checked_error,
        4,
        &checked_error_length
    );
    uint64_t panic_error_length = checked_error_length;
    int32_t invalid_status = abla_app_checked_divide(
        1,
        NULL,
        checked_error,
        sizeof(checked_error),
        &checked_error_length
    );
    int32_t success_status = abla_app_checked_divide(
        1,
        &checked_result,
        checked_error,
        sizeof(checked_error),
        &checked_error_length
    );
    void *echo = abla_app_echo_bytes(bytes, 3);
    int valid = echo != NULL &&
        abla_owned_bytes_length(echo) == 3 &&
        memcmp(abla_owned_bytes_data(echo), bytes, 3) == 0;
    abla_owned_bytes_release(echo);
    return valid && abla_app_answer() == 42 &&
        abla_app_add(19, 23) == 42 &&
        abla_app_bytes_score(bytes, 3) == 42 &&
        abla_app_bytes_length(NULL, 0) == 0 &&
        abla_app_invoke(add_context, (void *)&context, 23) == 42 &&
        panic_status == 1 &&
        panic_error_length == 16 &&
        memcmp(checked_error, "divi", 4) == 0 &&
        invalid_status == 2 &&
        success_status == 0 && checked_error_length == 0 &&
        checked_result == 42 ? 0 : 1;
}
