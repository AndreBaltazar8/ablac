// Also `oracle gen <fn> <count> <lo> <hi>`: prints "xbits resultbits" for count arguments spread over [lo, hi] by a fixed generator, with the
// correctly rounded result (the vectors of tests/cases/libc-correct-rounding).
// Reads "xbits resultbits" lines (u64 bit patterns of a double argument and of the result under test) on stdin and compares the result
// with MPFR's correctly rounded one. Usage: oracle <expm1|log1p|log10|log2|asin|acos|sinh|cosh|tanh|erf|erfc>
#include <mpfr.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
typedef int (*fn_t)(mpfr_t, const mpfr_t, mpfr_rnd_t);
int main(int argc, char **argv) {
  static const struct { const char *name; fn_t f; } table[] = {
    {"expm1", mpfr_expm1}, {"log1p", mpfr_log1p}, {"log10", mpfr_log10}, {"log2", mpfr_log2}, {"asin", mpfr_asin}, {"acos", mpfr_acos},
    {"sinh", mpfr_sinh}, {"cosh", mpfr_cosh}, {"tanh", mpfr_tanh}, {"erf", mpfr_erf}, {"erfc", mpfr_erfc}};
  fn_t f = 0;
  for (unsigned i = 0; i < sizeof table / sizeof table[0]; i++) if (argc > 1 && !strcmp(argv[1], table[i].name)) f = table[i].f;
  if (!f && !(argc > 1 && !strcmp(argv[1], "gen"))) { fprintf(stderr, "unknown function\n"); return 2; }
  mpfr_set_emin(-1073); mpfr_set_emax(1024);
  if (argc > 5 && !strcmp(argv[1], "gen")) {
    fn_t g = 0;
    for (unsigned i = 0; i < sizeof table / sizeof table[0]; i++) if (!strcmp(argv[2], table[i].name)) g = table[i].f;
    if (!g) return 2;
    long count = atol(argv[3]); double lo = atof(argv[4]), hi = atof(argv[5]);
    mpfr_t gx, gy; mpfr_init2(gx, 53); mpfr_init2(gy, 53);
    uint64_t s = 0x9e3779b97f4a7c15ULL;
    for (long k = 0; k < count; k++) {
      s ^= s << 13; s ^= s >> 7; s ^= s << 17;
      double u = (double)(s >> 11) / 9007199254740992.0, xd = lo + (hi - lo) * u;
      mpfr_set_d(gx, xd, MPFR_RNDN); int tv = g(gy, gx, MPFR_RNDN); mpfr_subnormalize(gy, tv, MPFR_RNDN);
      double r = mpfr_get_d(gy, MPFR_RNDN); uint64_t xb, rb; memcpy(&xb, &xd, 8); memcpy(&rb, &r, 8);
      printf("%llu %llu\n", (unsigned long long)xb, (unsigned long long)rb);
    }
    return 0;
  }
  mpfr_t x, y; mpfr_init2(x, 53); mpfr_init2(y, 53);
  unsigned long long xb, yb; long n = 0, bad = 0;
  while (scanf("%llu %llu", &xb, &yb) == 2) {
    double xd, yd; memcpy(&xd, &xb, 8); memcpy(&yd, &yb, 8);
    mpfr_set_d(x, xd, MPFR_RNDN);
    int t = f(y, x, MPFR_RNDN);
    mpfr_subnormalize(y, t, MPFR_RNDN);
    double r = mpfr_get_d(y, MPFR_RNDN);
    uint64_t rb; memcpy(&rb, &r, 8);
    n++;
    int same = (rb == yb) || (isnan(r) && isnan(yd));
    if (!same) { bad++; if (bad <= 10) printf("x=%a mine=%a mpfr=%a\n", xd, yd, r); }
  }
  printf("%ld samples, %ld differ\n", n, bad);
  return bad != 0;
}
