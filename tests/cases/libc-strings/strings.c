// The host side of tools/test-libc-strings.sh (#1139 area 14): `strings gen SEED COUNT` writes cases, one a line: "function<TAB>a hex<TAB>b hex<TAB>
// count<TAB>byte"; `strings` (no arguments) reads them and prints what this C library's function makes of each, one value a line: a comparison's
// sign, an offset into a (-1 for NULL), a length, or the hex of a result string. The strings are short, drawn from a few letters of both cases,
// punctuation and bytes past 127 (C compares them as unsigned char); a count is 0 to past the string's end or -1, SIZE_MAX, which the static
// libc's bounded functions used to take as no bound at all (memchr's only where the byte is in the string, as C needs).
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>

static uint64_t state;
static uint64_t next(void) { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state; }
static int below(int n) { return (int)(next() % (uint64_t)n); }
static void hex(const unsigned char *b, size_t n) { for (size_t i = 0; i < n; i++) printf("%02x", b[i]); }
static const char *names[] = { "strlen", "strcmp", "strncmp", "strcasecmp", "strncasecmp", "strchr", "strrchr", "memchr", "memrchr", "strnlen",
    "strspn", "strcspn", "strpbrk", "strstr", "strcoll", "strncat", "strndup" };
enum { FUNCTIONS = sizeof names / sizeof names[0] };

static int byte(void) {
    static const char pool[] = "aAbBcC.-";
    int k = below(10);
    return k < 8 ? pool[below(8)] : 128 + below(128);
}

static int sign(int v) { return v < 0 ? -1 : v > 0 ? 1 : 0; }

static void unhex(const char *h, char *out) { size_t n = strlen(h) / 2; for (size_t i = 0; i < n; i++) sscanf(h + 2 * i, "%2hhx", (unsigned char *)&out[i]); out[n] = 0; }

int main(int argc, char **argv) {
    static char line[4096];
    if (argc >= 4 && strcmp(argv[1], "gen") == 0) {
        state = 0x9e3779b97f4a7c15ULL ^ (uint64_t)atoll(argv[2]) * 0x2545f4914f6cdd1dULL;
        long count = atol(argv[3]);
        for (long n = 0; n < count; n++) {
            int f = below(FUNCTIONS);
            char a[40], b[40];
            int la = below(12), lb = below(12);
            for (int i = 0; i < la; i++) a[i] = (char)byte();
            a[la] = 0;
            // b is often a prefix or a variant of a, so comparisons go past the first byte.
            if (below(2)) { lb = la < lb ? la : lb; memcpy(b, a, (size_t)lb); if (lb > 0 && below(2)) b[below(lb)] = (char)byte(); }
            else for (int i = 0; i < lb; i++) b[i] = (char)byte();
            b[lb] = 0;
            int c = below(3) == 0 ? 0 : (unsigned char)(below(2) && la > 0 ? a[below(la)] : byte());
            long k = below(4) == 0 ? -1 : below(la + 4);
            if (strcmp(names[f], "memchr") == 0 && (k < 0 || k > la + 1)) k = (k < 0 && memchr(a, c, (size_t)la + 1)) ? -1 : below(la + 2);
            if (strcmp(names[f], "memrchr") == 0 && (k < 0 || k > la + 1)) k = below(la + 2);
            printf("%s\t", names[f]);
            hex((unsigned char *)a, (size_t)la);
            printf("\t");
            hex((unsigned char *)b, (size_t)lb);
            printf("\t%ld\t%d\n", k, c);
        }
        return 0;
    }
    while (fgets(line, sizeof line, stdin)) {
        char *fields[5];
        char *p = line;
        for (int i = 0; i < 5; i++) { fields[i] = p; p = strchr(p, i < 4 ? '\t' : '\n'); if (p) *p++ = 0; }
        char a[64], b[64], d[160];
        unhex(fields[1], a);
        unhex(fields[2], b);
        size_t k = (size_t)atol(fields[3]);
        int c = atoi(fields[4]);
        const char *f = fields[0];
        if (!strcmp(f, "strlen")) printf("%zu\n", strlen(a));
        else if (!strcmp(f, "strcmp")) printf("%d\n", sign(strcmp(a, b)));
        else if (!strcmp(f, "strncmp")) printf("%d\n", sign(strncmp(a, b, k)));
        else if (!strcmp(f, "strcasecmp")) printf("%d\n", sign(strcasecmp(a, b)));
        else if (!strcmp(f, "strncasecmp")) printf("%d\n", sign(strncasecmp(a, b, k)));
        else if (!strcmp(f, "strcoll")) printf("%d\n", sign(strcoll(a, b)));
        else if (!strcmp(f, "strchr")) { char *r = strchr(a, c); printf("%ld\n", r ? (long)(r - a) : -1L); }
        else if (!strcmp(f, "strrchr")) { char *r = strrchr(a, c); printf("%ld\n", r ? (long)(r - a) : -1L); }
        else if (!strcmp(f, "memchr")) { char *r = memchr(a, c, k); printf("%ld\n", r ? (long)(r - a) : -1L); }
        else if (!strcmp(f, "memrchr")) { char *r = memrchr(a, c, k); printf("%ld\n", r ? (long)(r - a) : -1L); }
        else if (!strcmp(f, "strnlen")) printf("%zu\n", strnlen(a, k));
        else if (!strcmp(f, "strspn")) printf("%zu\n", strspn(a, b));
        else if (!strcmp(f, "strcspn")) printf("%zu\n", strcspn(a, b));
        else if (!strcmp(f, "strpbrk")) { char *r = strpbrk(a, b); printf("%ld\n", r ? (long)(r - a) : -1L); }
        else if (!strcmp(f, "strstr")) { char *r = strstr(a, b); printf("%ld\n", r ? (long)(r - a) : -1L); }
        else if (!strcmp(f, "strncat")) { strcpy(d, b); strncat(d, a, k); hex((unsigned char *)d, strlen(d)); printf("\n"); }
        else if (!strcmp(f, "strndup")) { char *r = strndup(a, k); hex((unsigned char *)r, strlen(r)); free(r); printf("\n"); }
        else printf("?\n");
    }
    return 0;
}
