// Calls the checked exports of library.ab: results, contained panics (status 1,
// the message copied and its full length reported, a prefix when the buffer is
// short), invalid output pointers (status 2), and calls after a panic.
#include <stdint.h>
#include <stdio.h>
#include <string.h>

int32_t abla_checked_quotient(int64_t value, int64_t *result, char *message,
                              uint64_t capacity, uint64_t *length);
int32_t abla_checked_element(int64_t index, int64_t *result, char *message,
                             uint64_t capacity, uint64_t *length);
int32_t abla_checked_limited(int64_t value, int64_t *result, char *message,
                             uint64_t capacity, uint64_t *length);

static int failures = 0;

static void expect(int condition, const char *what) {
    if (!condition) {
        fprintf(stderr, "checked export: %s\n", what);
        failures = failures + 1;
    }
}

int main(void) {
    int64_t result = 0;
    char message[128];
    uint64_t length = 0;

    expect(abla_checked_quotient(2, &result, message, sizeof message, &length) == 0 &&
               result == 42, "quotient(2) returns 42");

    memset(message, 0, sizeof message);
    expect(abla_checked_quotient(0, &result, message, sizeof message, &length) == 1,
           "quotient(0) reports a panic");
    expect(length == strlen("division by zero") &&
               memcmp(message, "division by zero", length) == 0,
           "the panic's message is copied");

    expect(abla_checked_quotient(4, &result, message, sizeof message, &length) == 0 &&
               result == 21 && length == 0, "a call after a panic clears the error length");

    memset(message, 0, sizeof message);
    expect(abla_checked_element(7, &result, message, 5, &length) == 1,
           "element(7) reports a panic");
    expect(length > 5 && memcmp(message, "index", 5) == 0 && message[5] == 0,
           "a short buffer holds the message's prefix, the length is the whole message's");

    expect(abla_checked_element(2, &result, message, sizeof message, &length) == 0 &&
               result == 42, "element(2) returns 42");

    memset(message, 0, sizeof message);
    expect(abla_checked_limited(11, &result, message, sizeof message, &length) == 1 &&
               strcmp(message, "value 11 is over the limit") == 0 &&
               length == strlen("value 11 is over the limit"),
           "a `panic` is contained with its message");
    expect(abla_checked_limited(21, &result, message, sizeof message, &length) == 1 &&
               abla_checked_limited(5, &result, message, sizeof message, &length) == 0 &&
               result == 10, "repeated panics, then a result");

    expect(abla_checked_quotient(2, NULL, message, sizeof message, &length) == 2,
           "a null result pointer is invalid");

    if (failures == 0) printf("checked export: results, contained runtime and `panic` panics, prefixes, invalid pointers\n");
    return failures == 0 ? 42 : 1;
}
