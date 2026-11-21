#include <json-c/json.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  if (argc != 3)
    return 2;
  FILE *f = fopen(argv[2], "rb");
  if (!f)
    return 2;
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  rewind(f);
  char *s = calloc(len + 1, 1);
  if (fread(s, 1, len, f) != (size_t)len)
    return 2;
  fclose(f);
  for (int i = 0; i < atoi(argv[1]); i++) {
    struct json_object *v = json_tokener_parse(s);
    if (!v)
      return 2;
    const char *out = json_object_to_json_string_ext(v, JSON_C_TO_STRING_PLAIN);
    if (i == atoi(argv[1]) - 1)
      puts(out);
    json_object_put(v);
  }
  free(s);
  return 0;
}
