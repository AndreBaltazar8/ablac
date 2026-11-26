// The host side of tools/test-libc-format.sh (#1139 area 14): `format gen SEED COUNT` writes cases, one a line: "size<TAB>formathex<TAB>args", the args
// space-separated, each i:<decimal int64>, s:<hex bytes> (a string), or n (a NULL string); `format` (no arguments) reads them and prints what this C
// library's snprintf makes of each: "return<TAB>hex of the buffer up to its NUL". Only conversions with defined behaviour are generated.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static uint64_t state;
static uint64_t next(void) { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state; }
static int below(int n) { return (int)(next() % (uint64_t)n); }
static void hex(const unsigned char *b, size_t n) { for (size_t i = 0; i < n; i++) printf("%02x", b[i]); }

static void spec(char *f, size_t *at, char *args, size_t *aat) {
    static const char *lengths[] = { "", "hh", "h", "l", "ll", "z", "j", "t" };
    static const char conversions[] = "diuxXocsp%";
    char c = conversions[below(10)];
    f[(*at)++] = '%';
    if (c == '%') { f[(*at)++] = '%'; return; }
    int integer = strchr("diuxXo", c) != NULL;
    if (below(2)) f[(*at)++] = '-';
    if (integer && below(3) == 0) f[(*at)++] = '0';
    if ((c == 'd' || c == 'i') && below(3) == 0) f[(*at)++] = below(2) ? '+' : ' ';
    if (strchr("oxX", c) && below(3) == 0) f[(*at)++] = '#';
    int w = below(4);
    if (w == 1) *at += sprintf(f + *at, "%d", below(30));
    else if (w == 2) { f[(*at)++] = '*'; *aat += sprintf(args + *aat, "i:%d ", below(81) - 40); }
    if ((integer || c == 's') && below(2)) {
        f[(*at)++] = '.';
        int p = below(3);
        if (p == 1) *at += sprintf(f + *at, "%d", below(30));
        else if (p == 2) { f[(*at)++] = '*'; *aat += sprintf(args + *aat, "i:%d ", below(81) - 40); }
    }
    if (integer) *at += sprintf(f + *at, "%s", lengths[below(8)]);
    f[(*at)++] = c;
    if (c == 's') {
        if (below(10) == 0) { *aat += sprintf(args + *aat, "n "); return; }
        int n = below(40);
        *aat += sprintf(args + *aat, "s:");
        for (int i = 0; i < n; i++) { int b = below(5) == 0 ? 128 + below(128) : 32 + below(95); *aat += sprintf(args + *aat, "%02x", b); }
        args[(*aat)++] = ' ';
    } else if (c == 'c') *aat += sprintf(args + *aat, "i:%d ", 1 + below(255));
    else if (c == 'p') *aat += sprintf(args + *aat, "i:%lld ", below(4) == 0 ? 0LL : (long long)(next() >> below(64)));
    else {
        int64_t v = (int64_t)next();
        int k = below(5);
        if (k == 0) v = 0; else if (k == 1) v = (int64_t)(next() % 1000) - 500; else if (k == 2) v = INT64_MIN; else if (k == 3) v = INT32_MIN;
        *aat += sprintf(args + *aat, "i:%lld ", (long long)v);
    }
}

int main(int argc, char **argv) {
    static char line[1 << 16], formatted[1 << 14];
    if (argc >= 4 && strcmp(argv[1], "gen") == 0) {
        state = 0x9e3779b97f4a7c15ULL ^ (uint64_t)atoll(argv[2]) * 0x2545f4914f6cdd1dULL;
        long count = atol(argv[3]);
        for (long n = 0; n < count; n++) {
            char f[512], args[4096];
            size_t at = 0, aat = 0;
            int parts = 1 + below(3);
            for (int p = 0; p < parts; p++) {
                if (below(2)) { int t = below(6); for (int i = 0; i < t; i++) f[at++] = 'a' + below(26); }
                if (aat < 3000) spec(f, &at, args, &aat);
            }
            int sizes[] = { 0, 1, 2, 5, 16, 64, 4096 };
            printf("%d\t", sizes[below(7)]);
            hex((unsigned char *)f, at);
            printf("\t%.*s\n", (int)aat, args);
        }
        return 0;
    }
    while (fgets(line, sizeof line, stdin)) {
        char *tab = strchr(line, '\t'); if (!tab) continue;
        int size = atoi(line);
        char *fhex = tab + 1, *tab2 = strchr(fhex, '\t'); *tab2 = 0;
        char f[1024]; size_t fl = strlen(fhex) / 2;
        for (size_t i = 0; i < fl; i++) sscanf(fhex + 2 * i, "%2hhx", (unsigned char *)&f[i]);
        f[fl] = 0;
        uint64_t a[12] = { 0 }; int na = 0;
        static char strings[12][128];
        char *tok = strtok(tab2 + 1, " \n");
        while (tok && na < 12) {
            if (tok[0] == 'i') a[na++] = (uint64_t)atoll(tok + 2);
            else if (tok[0] == 'n') a[na++] = 0;
            else { size_t n = strlen(tok + 2) / 2; for (size_t i = 0; i < n; i++) sscanf(tok + 2 + 2 * i, "%2hhx", (unsigned char *)&strings[na][i]); strings[na][n] = 0; a[na] = (uint64_t)(uintptr_t)strings[na]; na++; }
            tok = strtok(NULL, " \n");
        }
        memset(formatted, 0, sizeof formatted);
        int r = snprintf(size ? formatted : NULL, (size_t)size, f, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11]);
        printf("%d\t", r);
        hex((unsigned char *)formatted, strlen(formatted));
        printf("\n");
    }
    return 0;
}
