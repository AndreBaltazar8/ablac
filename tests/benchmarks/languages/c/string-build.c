#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    size_t count = strtoul(argv[1], NULL, 10);
    size_t size = 0, capacity = 0;
    char *text = NULL;
    for (size_t i = 0; i < count; ++i) {
        const char *chunk = i % 2 == 0 ? "alpha: 01234567\n" : "bravo: 76543210\n";
        const size_t length = 16;
        if (size + length > capacity) {
            capacity = capacity ? 2 * capacity : length;
            char *next = realloc(text, capacity);
            if (!next) {
                free(text);
                return 1;
            }
            text = next;
        }
        memcpy(text + size, chunk, length);
        size += length;
    }
    int status = size == 0 || fwrite(text, 1, size, stdout) == size ? 0 : 1;
    free(text);
    return status;
}
