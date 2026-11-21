// Reads "xbits resultbits" lines (u64 bit patterns of a double argument and of the result under test) on stdin and compares the result
// with MPFR's correctly rounded one. Usage: oracle <expm1|log1p|log10|log2|asin|acos|sinh|cosh|tanh|erf|erfc>
#include <mpfr.h>
#include <stdio.h>
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
  if (!f) { fprintf(stderr, "unknown function\n"); return 2; }
  mpfr_set_emin(-1073); mpfr_set_emax(1024);
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
