#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static pcre2_code *compile(const char *p) {
  int e;
  PCRE2_SIZE at;
  pcre2_code *c =
      pcre2_compile((PCRE2_SPTR)p, PCRE2_ZERO_TERMINATED, 0, &e, &at, NULL);
  if (!c)
    exit(2);
  return c;
}
static char *replace(char *s, const char *pattern, const char *rep) {
  pcre2_code *c = compile(pattern);
  pcre2_match_data *md = pcre2_match_data_create_from_pattern(c, NULL);
  size_t len = strlen(s), cap = len * 4 + 1024, at = 0, end = 0;
  char *out = malloc(cap);
  while (pcre2_match(c, (PCRE2_SPTR)s, len, at, 0, md, NULL) >= 0) {
    PCRE2_SIZE *v = pcre2_get_ovector_pointer(md);
    size_t add = v[0] - at + strlen(rep);
    if (end + add + len + 1 > cap) {
      cap = (end + add + len + 1) * 2;
      out = realloc(out, cap);
    }
    memcpy(out + end, s + at, v[0] - at);
    end += v[0] - at;
    memcpy(out + end, rep, strlen(rep));
    end += strlen(rep);
    at = v[1];
  }
  memcpy(out + end, s + at, len - at + 1);
  pcre2_match_data_free(md);
  pcre2_code_free(c);
  return out;
}
int main(int argc, char **argv) {
  if (argc != 3)
    return 2;
  FILE *f = fopen(argv[2], "rb");
  if (!f)
    return 2;
  fseek(f, 0, SEEK_END);
  long initial = ftell(f);
  rewind(f);
  char *input = calloc(initial + 1, 1);
  if (fread(input, 1, initial, f) != (size_t)initial)
    return 2;
  fclose(f);
  char *s = replace(input, ">[^\n]*\n|\n", "");
  long cleaned = strlen(s);
  const char *patterns[] = {
      "agggtaaa|tttaccct",         "[cgt]gggtaaa|tttaccc[acg]",
      "a[act]ggtaaa|tttacc[agt]t", "ag[act]gtaaa|tttac[agt]ct",
      "agg[act]taaa|ttta[agt]cct", "aggg[acg]aaa|ttt[cgt]ccct",
      "agggt[cgt]aa|tt[acg]accct", "agggta[cgt]a|t[acg]taccct",
      "agggtaa[cgt]|[acg]ttaccct"};
  for (int i = 0; i < 9; i++) {
    pcre2_code *c = compile(patterns[i]);
    pcre2_match_data *md = pcre2_match_data_create_from_pattern(c, NULL);
    size_t at = 0;
    long count = 0;
    while (pcre2_match(c, (PCRE2_SPTR)s, cleaned, at, 0, md, NULL) >= 0) {
      count++;
      at = pcre2_get_ovector_pointer(md)[1];
    }
    printf("%s %ld\n", patterns[i], count);
    pcre2_match_data_free(md);
    pcre2_code_free(c);
  }
  const char *p[] = {"tHa[Nt]", "aND|caN|Ha[DS]|WaS", "a[NSt]|BY", "<[^>]*>",
                     "\\|[^|][^|]*\\|"};
  const char *r[] = {"<4>", "<3>", "<2>", "|", "-"};
  for (int i = 0; i < 5; i++) {
    char *next = replace(s, p[i], r[i]);
    free(s);
    s = next;
  }
  printf("\n%ld\n%ld\n%zu\n", initial, cleaned, strlen(s));
  free(input);
  free(s);
  return 0;
}
