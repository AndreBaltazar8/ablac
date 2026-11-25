// The host C library's side of tools/test-libc-parse.sh (#1139 area 4): `parse.c gen SEED COUNT` writes cases, `parse.c` reads them from stdin and prints what the host's
// strtod, strtol, strtoll, strtoul and strtoull make of each: a case is "kind base hextext" (kind d, l, L, u or U; the text is hex so any byte can be in it), a result line
// "value end errno" (value: the double's bits for d, the integer otherwise; end: the byte offset of endptr; errno 0 or 34 (ERANGE) or 22).
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t state;
static uint64_t next(void) {
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    return state;
}
static unsigned below(unsigned n) { return (unsigned)(next() % n); }

static const char *pieces[] = {" ", "  ", "\t", "\n", "\v", "\f", "\r", "+", "-", "--", "+-", "0", "00", "1", "7", "8", "9", "9999999999999999999", "18446744073709551615", "18446744073709551616",
    "9223372036854775807", "9223372036854775808", "9223372036854775809", "-9223372036854775808", "0x", "0X", "0x1", "0xff", "0XFFFFFFFFFFFFFFFF", "0x10000000000000000", "0b", "0b1", "0B101", "0o7", "0b2",
    ".", ".5", "5.", "1.5", "0.1", "e", "E", "e5", "e-5", "e+", "e999", "e-999", "e99999999999999999999", "1e308", "1e309", "1e-324", "1e-400", "4.9e-324", "2.2250738585072014e-308",
    "inf", "INF", "Infinity", "infinit", "infin", "nan", "NAN", "nan(", "nan(abc)", "nan(a b)", "-nan", "0x1p3", "0x.8", "0x1.8p1", "0xp1", "0x1p", "p", "P-3", "a", "z", "Z", "g", "_", "1_0", ",", "\x7f", "\x80", "\xff",
    "123456789012345678901234567890", "0.000000000000000000000000000001", "1234567890123456789012345678901234567890e-30", "17976931348623157e292", "17976931348623159e292", "2.4703282292062327e-324", "2.4703282292062328e-324"};

static void emit(char kind, int base, const char *text, size_t length) {
    printf("%c %d ", kind, base);
    for (size_t i = 0; i < length; i++) printf("%02x", (unsigned char)text[i]);
    printf("\n");
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "gen") == 0) {
        state = 0x9e3779b97f4a7c15ull ^ (argc > 2 ? strtoull(argv[2], NULL, 10) * 0x100000001b3ull : 0);
        unsigned count = argc > 3 ? (unsigned)atoi(argv[3]) : 20000;
        size_t npieces = sizeof pieces / sizeof pieces[0];
        for (unsigned c = 0; c < count; c++) {
            char text[256];
            size_t length = 0;
            unsigned parts = 1 + below(5);
            for (unsigned p = 0; p < parts; p++) {
                if (below(8) == 0) {
                    // random bytes of the number alphabet
                    unsigned run = 1 + below(12);
                    for (unsigned i = 0; i < run && length < 200; i++) text[length++] = "0123456789abcdefABCDEFxXpPeE.+- _"[below(34)];
                } else {
                    const char *piece = pieces[below((unsigned)npieces)];
                    size_t n = strlen(piece);
                    if (length + n < 200) { memcpy(text + length, piece, n); length += n; }
                }
            }
            if (below(40) == 0) while (length < 190) text[length++] = (char)('0' + below(10));
            if (below(5) == 0) {
                // a hex float near a rounding tie: 53 significant bits, then 7, 8 or 9 (below, at, above half an ulp), zeros, and sometimes a nonzero digit past the 16th (the sticky bit),
                // with an exponent at the edges of the normal and subnormal ranges
                static const int exponents[] = {0, 1, -1, -1021, -1022, -1023, -1073, -1074, -1075, -1076, 1022, 1023, 1024, -52, 52, 5, -5};
                length = (size_t)sprintf(text, "%s0x%x.", below(4) == 0 ? "-" : "", 1 + below(15));
                for (int i = 0; i < 12 + (int)below(3); i++) length += (size_t)sprintf(text + length, "%x", below(16));
                length += (size_t)sprintf(text + length, "%x", 7 + below(3));
                for (unsigned zeros = below(6); zeros > 0; zeros--) text[length++] = '0';
                if (below(2)) text[length++] = (char)('1' + below(9));
                if (below(6) != 0) length += (size_t)sprintf(text + length, "p%d", exponents[below(17)]);
                text[length] = 0;
            }
            static const char kinds[] = "dlLuU";
            char kind = kinds[below(5)];
            static const int bases[] = {0, 0, 0, 10, 10, 16, 2, 8, 36, 3, 35, 1, 37, 11, 24, -1};
            int base = kind == 'd' ? 0 : bases[below(16)];
            emit(kind, base, text, length);
        }
        return 0;
    }
    char line[1024];
    while (fgets(line, sizeof line, stdin)) {
        char kind = line[0];
        int base = atoi(line + 2);
        const char *hex = strchr(line + 2, ' ') + 1;
        char text[512];
        size_t length = 0;
        while (hex[0] && hex[1] && hex[0] != '\n') {
            unsigned byte;
            sscanf(hex, "%2x", &byte);
            text[length++] = (char)byte;
            hex += 2;
        }
        text[length] = 0;
        char *end = text;
        errno = 0;
        if (kind == 'd') {
            double value = strtod(text, &end);
            uint64_t bits;
            memcpy(&bits, &value, 8);
            if (value != value) bits = 0x7ff8000000000000ull;  // the sign and payload of a NaN are not compared
            printf("%llu %ld %d\n", (unsigned long long)bits, (long)(end - text), errno == ERANGE ? 34 : 0);
        } else {
            long long value = kind == 'l' ? strtol(text, &end, base) : kind == 'L' ? strtoll(text, &end, base)
                : kind == 'u' ? (long long)strtoul(text, &end, base) : (long long)strtoull(text, &end, base);
            printf("%lld %ld %d\n", value, (long)(end - text), errno);
        }
    }
    return 0;
}
