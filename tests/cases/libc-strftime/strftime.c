// The host side of tools/test-libc-strftime.sh (#1139 area 14): `strftime gen SEED COUNT` writes cases, one a line: "size<TAB>formathex<TAB>sec min
// hour mday mon year wday yday"; `strftime` (no arguments) reads them and prints what this C library's strftime makes of each: "return<TAB>hex of the
// buffer". The formats use the conversions the static libc knows except %Z and %z (the zone: the static libc's is UTC), literal text, %% and,
// now and then, a % that ends the format. The fields are in range except tm_wday and tm_mon, which are sometimes not (glibc writes "?" for the name).
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

static uint64_t state;
static uint64_t next(void) { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state; }
static int below(int n) { return (int)(next() % (uint64_t)n); }
static void hex(const unsigned char *b, size_t n) { for (size_t i = 0; i < n; i++) printf("%02x", b[i]); }

int main(int argc, char **argv) {
    static char line[4096], out[4096];
    if (argc >= 4 && strcmp(argv[1], "gen") == 0) {
        static const char codes[] = "YmdeHMSyjaAbhBpFTD%";
        state = 0x9e3779b97f4a7c15ULL ^ (uint64_t)atoll(argv[2]) * 0x2545f4914f6cdd1dULL;
        long count = atol(argv[3]);
        for (long n = 0; n < count; n++) {
            char f[256];
            size_t at = 0;
            int parts = below(6);
            for (int p = 0; p < parts; p++) {
                if (below(3) == 0) { int t = 1 + below(4); for (int i = 0; i < t; i++) f[at++] = below(4) ? 'a' + below(26) : ' ' + below(5); }
                f[at++] = '%';
                f[at++] = codes[below(sizeof codes - 1)];
            }
            if (below(5) == 0) f[at++] = '%';
            int sizes[] = { 0, 1, 3, 8, 20, 64, 256 };
            printf("%d\t", sizes[below(7)]);
            hex((unsigned char *)f, at);
            int wday = below(8) == 0 ? below(40) - 20 : below(7), mon = below(8) == 0 ? below(40) - 20 : below(12);
            printf("\t%d %d %d %d %d %d %d %d\n", below(60), below(60), below(24), 1 + below(31), mon, below(300), wday, below(366));
        }
        return 0;
    }
    while (fgets(line, sizeof line, stdin)) {
        int size = atoi(line);
        char *fhex = strchr(line, '\t') + 1, *tab = strchr(fhex, '\t');
        *tab = 0;
        char f[256];
        size_t fl = strlen(fhex) / 2;
        for (size_t i = 0; i < fl; i++) sscanf(fhex + 2 * i, "%2hhx", (unsigned char *)&f[i]);
        f[fl] = 0;
        struct tm t = { 0 };
        sscanf(tab + 1, "%d %d %d %d %d %d %d %d", &t.tm_sec, &t.tm_min, &t.tm_hour, &t.tm_mday, &t.tm_mon, &t.tm_year, &t.tm_wday, &t.tm_yday);
        memset(out, 0, sizeof out);
        size_t r = strftime(out, (size_t)size, f, &t);
        printf("%zu\t", r);
        hex((unsigned char *)out, r);
        printf("\n");
    }
    return 0;
}
