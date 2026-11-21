// The host C library's side of tools/test-libc-float-format.sh: `format.c gen` writes the cases ("conversion precision alternate bits"), and
// `format.c` with no argument reads them from stdin and prints each as printf formats it.
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t state = 0x9e3779b97f4a7c15ull;
static uint64_t next(void) {
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    return state;
}

static uint64_t bits_of(double value) {
    uint64_t bits;
    memcpy(&bits, &value, 8);
    return bits;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "gen") == 0) {
        double tricky[] = {0.0, -0.0, 1.0, -1.0, 0.5, 1.5, 2.5, 0.125, 0.375, 1e21, 1e22, 1e23, 123456789.0, 0.1, 0.2, 0.3, 1.0 / 3, 2.0 / 3, 9.5, 99.5, 999.5,
            9.9999, 9.99995, 99999.5, 0.00009999, 0.0001, 0.00001, 1e-5, 123456.5, 1234567.5, 4503599627370496.5, 5e-324, 2.2250738585072014e-308,
            2.225073858507201e-308, 1.7976931348623157e308, 4.9406564584124654e-324, 1e100, 1e-100, 1e300, 1e-300, 8.5, 0.05, 0.15, 0.25, 0.35, 5e-5,
            0.9999999, 9.999999e5, 999999.5, 100.0, 1000000.0, 12345.678, 3.141592653589793, 2.718281828459045, 1.0000000000000002, 0.30000000000000004,
            (double)INFINITY, (double)-INFINITY, (double)NAN};
        size_t count = sizeof tricky / sizeof tricky[0];
        const char conversions[] = "feEgGaAF";
        for (size_t i = 0; i < count; i++)
            for (size_t c = 0; conversions[c]; c++) {
                int precisions[] = {-1, 0, 1, 2, 3, 5, 6, 10, 15, 16, 17, 20};
                for (size_t p = 0; p < sizeof precisions / sizeof precisions[0]; p++)
                    for (int alt = 0; alt < 2; alt++)
                        printf("%c %d %d %lld\n", conversions[c], precisions[p], alt, (long long)bits_of(tricky[i]));
            }
        // Random bit patterns (every exponent, subnormals included) with random precisions.
        for (int i = 0; i < 4000; i++) {
            uint64_t bits = next();
            if ((bits & 0x7ff0000000000000ull) == 0x7ff0000000000000ull) bits &= ~0x0010000000000000ull;
            printf("%c %d %d %lld\n", conversions[next() % 7], (int)(next() % 19) - 1, (int)(next() % 2), (long long)bits);
        }
        // Halfway cases: x.5, x.25, x.125 ... at precisions that land on the tie.
        for (int i = 0; i < 400; i++) {
            double value = (double)(next() % 100000) + (double)(1 << (next() % 6)) / (double)(1 << (next() % 6 + 1)) * 0.5;
            printf("f %d 0 %lld\n", (int)(next() % 6), (long long)bits_of(value));
            printf("e %d 0 %lld\n", (int)(next() % 8), (long long)bits_of(value));
            printf("g %d %d %lld\n", (int)(next() % 8), (int)(next() % 2), (long long)bits_of(value));
        }
        // Values just below and at a power of ten: roundings that carry into a new digit (glibc's # quirk is here).
        for (int k = 1; k < 16; k++) {
            double power = pow(10.0, k);
            double nearby[] = {power - 0.5, power - 0.05, power - 0.4999, power - 0.0001, power - 0.5 / 10, power * 0.99999, power / 10 * 9.9999};
            for (size_t i = 0; i < sizeof nearby / sizeof nearby[0]; i++)
                for (int precision = -1; precision < 10; precision++)
                    for (int alt = 0; alt < 2; alt++) {
                        printf("g %d %d %lld\n", precision, alt, (long long)bits_of(nearby[i]));
                        printf("e %d %d %lld\n", precision, alt, (long long)bits_of(nearby[i]));
                        printf("f %d %d %lld\n", precision, alt, (long long)bits_of(nearby[i]));
                    }
        }
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "strtof-gen") == 0) {
        const char *fixed[] = {"0.1", "1e-46", "1.4e-45", "7e-46", "7.006492321624085e-46", "7.0064923216240854e-46", "3.4028235e38", "3.4028236e38",
            "3.40282357e38", "3.4028235677973366e38", "3.4028235677973362e38", "1e39", "16777217", "16777216.5", "16777216.50000001", "33554433",
            "8388608.5", "8388609.5", "1.00000005960464477539", "1.000000059604644775390625", "1.00000005960464477539063", "0.99999997019767761230",
            "1.17549435e-38", "1.1754942e-38", "1.17549421069244108e-38", "5.8774717541114375e-39", "2.9387358770557188e-39", "-0.0", "-1.5e-45", "123456789",
            "1e-7", "0x1p-149", "inf", "-inf", "nan", "  12.5abc", "1e", "1e+", ".5", "5.", "0000.0000", "000123.4560e0002"};
        for (size_t i = 0; i < sizeof fixed / sizeof fixed[0]; i++)
            if (fixed[i][0] != ' ' && strncmp(fixed[i], "0x", 2) != 0) printf("%s\n", fixed[i]);
        for (int i = 0; i < 6000; i++) {
            uint32_t raw = (uint32_t)next();
            if (((raw >> 23) & 255) == 255) raw &= ~(1u << 23);
            float a;
            memcpy(&a, &raw, 4);
            a = fabsf(a);
            printf("%.9g\n%.20e\n", (double)a, (double)a);
            float b = nextafterf(a, INFINITY);
            if (isinf(b)) continue;
            double mid = ((double)a + (double)b) / 2;
            printf("%.120e\n", mid);
            printf("%.120e\n", nextafter(mid, INFINITY));
            printf("%.120e\n", nextafter(mid, 0.0));
            printf("%.40e\n", mid);
        }
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "strtof") == 0) {
        char text[512];
        while (fgets(text, sizeof text, stdin)) {
            text[strcspn(text, "\n")] = 0;
            float value = strtof(text, NULL);
            uint32_t bits;
            memcpy(&bits, &value, 4);
            printf("%u\n", bits);
        }
        return 0;
    }
    char conversion;
    int precision, alternate;
    long long bits;
    while (scanf(" %c %d %d %lld", &conversion, &precision, &alternate, &bits) == 4) {
        double value;
        uint64_t raw = (uint64_t)bits;
        memcpy(&value, &raw, 8);
        char format[16];
        char *at = format;
        *at++ = '%';
        if (alternate) *at++ = '#';
        if (precision >= 0) {
            *at++ = '.';
            *at++ = '*';
        }
        *at++ = conversion;
        *at = 0;
        if (precision >= 0) printf(format, precision, value);
        else printf(format, value);
        printf("\n");
    }
    return 0;
}
