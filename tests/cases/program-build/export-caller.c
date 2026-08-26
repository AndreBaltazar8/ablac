#include <stdint.h>
#include <stddef.h>
#include <string.h>

extern int64_t abla_app_answer(void);
extern int64_t abla_app_next(void);
extern int64_t abla_app_resource_next(void);
extern int64_t abla_app_add(int64_t value, int64_t delta);
extern uint8_t abla_app_bool_identity(uint8_t value);
extern int8_t abla_app_i8_identity(int8_t value);
extern uint8_t abla_app_u8_identity(uint8_t value);
extern uint8_t abla_app_char_identity(uint8_t value);
extern int16_t abla_app_i16_identity(int16_t value);
extern uint16_t abla_app_u16_identity(uint16_t value);
extern int32_t abla_app_i32_identity(int32_t value);
extern uint32_t abla_app_u32_identity(uint32_t value);
extern int64_t abla_app_i64_identity(int64_t value);
extern uint64_t abla_app_u64_identity(uint64_t value);
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
    return valid && abla_app_next() == 41 && abla_app_next() == 42 &&
        abla_app_resource_next() == 51 &&
        abla_app_resource_next() == 52 &&
        abla_app_answer() == 42 &&
        abla_app_add(19, 23) == 42 &&
        abla_app_bool_identity(1) == 1 &&
        abla_app_i8_identity(-100) == -100 &&
        abla_app_u8_identity(250) == 250 &&
        abla_app_char_identity(200) == 200 &&
        abla_app_i16_identity(-30000) == -30000 &&
        abla_app_u16_identity(60000) == 60000 &&
        abla_app_i32_identity(-2000000000) == -2000000000 &&
        abla_app_u32_identity(UINT32_C(4000000000)) ==
            UINT32_C(4000000000) &&
        abla_app_i64_identity(INT64_C(-9000000000000000000)) ==
            INT64_C(-9000000000000000000) &&
        abla_app_u64_identity(UINT64_C(18000000000000000000)) ==
            UINT64_C(18000000000000000000) &&
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
