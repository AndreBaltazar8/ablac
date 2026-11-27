// The glibc host of tools/test-aarch64-linux-library.sh: calls the exports of the AArch64 library, loaded by dlopen
// from argv[1], or (built with -DABLA_STATIC) linked in from the static library. No headers, so that only the target
// glibc's runtime files are needed (no development package).
typedef long long (*abla_export)(void);
extern int printf(const char *format, ...);

#ifdef ABLA_STATIC
extern long long abla_app_answer(void);
extern long long abla_app_threaded(void);
#else
extern void *dlopen(const char *path, int flags);
extern void *dlsym(void *library, const char *name);
extern char *dlerror(void);
#endif

int main(int argc, char **argv) {
#ifdef ABLA_STATIC
    abla_export answer = abla_app_answer;
    abla_export threaded = abla_app_threaded;
#else
    if (argc < 2) return 2;
    void *library = dlopen(argv[1], 2); // RTLD_NOW
    if (!library) { printf("dlopen: %s\n", dlerror()); return 3; }
    abla_export answer = (abla_export)dlsym(library, "abla_app_answer");
    abla_export threaded = (abla_export)dlsym(library, "abla_app_threaded");
    if (!answer || !threaded) { printf("dlsym: %s\n", dlerror()); return 4; }
#endif
    printf("answer %lld\n", answer());
    printf("threaded %lld\n", threaded());
    return 0;
}
