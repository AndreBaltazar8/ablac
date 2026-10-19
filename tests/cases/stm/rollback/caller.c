// Calls the checked exports of library.ab: a transfer that panics leaves both
// balances as they were, run directly and logged.
#include <stdint.h>
#include <stdio.h>

int32_t stm_transfer(int64_t amount, int64_t *result, char *message,
                     uint64_t capacity, uint64_t *length);
int32_t stm_balances(int64_t logged, int64_t *result, char *message,
                     uint64_t capacity, uint64_t *length);

static int failures = 0;

static void expect(int condition, const char *what) {
    if (!condition) {
        fprintf(stderr, "stm rollback: %s\n", what);
        failures = failures + 1;
    }
}

int main(void) {
    int64_t result = 0;
    char message[128];
    uint64_t length = 0;
    for (int64_t logged = 0; logged < 2; logged = logged + 1) {
        int64_t before = 100000 - logged * 5 * 999;
        expect(stm_balances(logged, &result, message, sizeof message, &length) == 0 &&
                   result == before, "the balances before");
        expect(stm_transfer(20, &result, message, sizeof message, &length) == 1,
               "a transfer over the limit panics");
        expect(stm_balances(logged, &result, message, sizeof message, &length) == 0 &&
                   result == before, "its writes are rolled back");
        expect(stm_transfer(5, &result, message, sizeof message, &length) == 0 &&
                   result == before / 1000 - 5, "the next transfer commits");
        expect(stm_balances(logged, &result, message, sizeof message, &length) == 0 &&
                   result == before - 5 * 999, "with its writes");
    }
    return failures == 0 ? 42 : 1;
}
