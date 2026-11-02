// What a test object needs to run under qemu with no C library: a start, a bump allocator that
// never reuses, and exit(99) for what it should never reach. It runs one export and exits with
// its result. Built for AArch64, RISC-V and Xtensa by tools/test-uint256.sh.
typedef __SIZE_TYPE__ size_t;

long long uint256_checks(void);

static char heap[1 << 28] __attribute__((aligned(16)));
static size_t used;
static char tls[4096] __attribute__((aligned(16)));
static int errno_word;

static void leave(long code) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = 93;
    register long x0 __asm__("x0") = code;
    __asm__ volatile("svc #0" : : "r"(x8), "r"(x0));
#elif defined(__riscv)
    register long a7 __asm__("a7") = 93;
    register long a0 __asm__("a0") = code;
    __asm__ volatile("ecall" : : "r"(a7), "r"(a0));
#elif defined(__XTENSA__)
    register long a2 __asm__("a2") = 118; // exit, Xtensa's number
    register long a6 __asm__("a6") = code;
    __asm__ volatile("syscall" : : "r"(a2), "r"(a6));
#endif
    for (;;) {}
}

void begin(void) {
#if defined(__aarch64__)
    __asm__ volatile("msr tpidr_el0, %0" : : "r"(tls));
#elif defined(__riscv)
    __asm__ volatile("mv tp, %0" : : "r"(tls));
#endif
    leave((long)uint256_checks());
}

#if defined(__XTENSA__)
__asm__(".text\n.globl _start\n.align 4\n_start:\n  movi a0, 0\n  movi a4, begin\n  callx4 a4\n");
#elif defined(__riscv)
__asm__(".text\n.globl _start\n_start:\n  .option push\n  .option norelax\n  la gp, __global_pointer$\n  .option pop\n  call begin\n");
#else
__asm__(".text\n.globl _start\n_start:\n  bl begin\n");
#endif

void *malloc(size_t size) {
    size_t *block = (size_t *)(heap + used);
    used += (size + 16 + 15) & ~(size_t)15;
    if (used > sizeof heap) leave(98);
    block[0] = size;
    return (char *)block + 16;
}
void *memset(void *to, int value, size_t count) {
    volatile char *out = to;
    while (count--) *out++ = (char)value;
    return to;
}
void *calloc(size_t count, size_t size) { return memset(malloc(count * size), 0, count * size); }
void *memcpy(void *to, const void *from, size_t count) {
    volatile char *out = to;
    const volatile char *in = from;
    while (count--) *out++ = *in++;
    return to;
}
void *memmove(void *to, const void *from, size_t count) {
    volatile char *out = to;
    const volatile char *in = from;
    if (out <= in) return memcpy(to, from, count);
    while (count--) out[count] = in[count];
    return to;
}
void *realloc(void *old, size_t size) {
    void *fresh = malloc(size);
    if (old) {
        size_t had = *(size_t *)((char *)old - 16);
        memcpy(fresh, old, had < size ? had : size);
    }
    return fresh;
}
void free(void *block) { (void)block; }
int memcmp(const void *a, const void *b, size_t count) {
    const unsigned char *x = a, *y = b;
    for (; count--; x++, y++) if (*x != *y) return *x - *y;
    return 0;
}
size_t strlen(const char *text) {
    size_t size = 0;
    while (text[size]) size++;
    return size;
}
int *__errno_location(void) { return &errno_word; }
void *__tls_get_addr(size_t *entry) { return tls + entry[1]; }
char *getenv(const char *name) { (void)name; return 0; }
int pthread_mutex_lock(void *m) { (void)m; return 0; }
int pthread_mutex_unlock(void *m) { (void)m; return 0; }
int pthread_mutex_init(void *m, void *a) { (void)m; (void)a; return 0; }
int pthread_mutex_destroy(void *m) { (void)m; return 0; }
long write(int fd, const void *from, size_t count) { (void)fd; (void)from; return (long)count; }
void _exit(int code) { leave(code); }

// A microcontroller's heap: Wasm's memory calls, in whole pages.
size_t abla_host_memory_base(void) { return (size_t)heap; }
size_t abla_host_memory_size(void) { return sizeof heap / 65536; }
size_t abla_host_memory_grow(size_t pages) { (void)pages; return (size_t)-1; }

#define NEVER(name) void name(void) { leave(99); }
NEVER(_longjmp) NEVER(backtrace) NEVER(backtrace_symbols_fd) NEVER(getrlimit) NEVER(pthread_join)
NEVER(raise) NEVER(sigaction) NEVER(sigaltstack) NEVER(signal) NEVER(syscall)

#if !defined(__x86_64__) && !defined(__aarch64__)
unsigned long long __muldi3(unsigned long long a, unsigned long long b) {
    unsigned long long out = 0;
    while (b) {
        if (b & 1) out += a;
        a <<= 1;
        b >>= 1;
    }
    return out;
}
// libgcc's 64-bit division, which the runtime calls for an `int`'s text on any target below 64 bits or
// without M. Written from shifts and a compare.
static unsigned long long dividing64(unsigned long long a, unsigned long long b, unsigned long long *rest) {
    unsigned long long quotient = 0, remainder = 0;
    for (int bit = 63; bit >= 0; bit--) {
        unsigned long long place = 1;
        for (int at = 0; at < bit; at++) place += place;
        remainder += remainder;
        if (a >= place) { a -= place; remainder += 1; }
        if (remainder >= b) { remainder -= b; quotient += place; }
    }
    *rest = remainder;
    return quotient;
}
unsigned long long __udivdi3(unsigned long long a, unsigned long long b) { unsigned long long r; return dividing64(a, b, &r); }
unsigned long long __umoddi3(unsigned long long a, unsigned long long b) { unsigned long long r; dividing64(a, b, &r); return r; }
long long __divdi3(long long a, long long b) {
    unsigned long long r, q = dividing64(a < 0 ? -(unsigned long long)a : (unsigned long long)a, b < 0 ? -(unsigned long long)b : (unsigned long long)b, &r);
    return (a < 0) != (b < 0) ? -(long long)q : (long long)q;
}
long long __moddi3(long long a, long long b) {
    unsigned long long r;
    dividing64(a < 0 ? -(unsigned long long)a : (unsigned long long)a, b < 0 ? -(unsigned long long)b : (unsigned long long)b, &r);
    return a < 0 ? -(long long)r : (long long)r;
}
#endif

#if defined(__riscv)
// ablac's RISC-V code has no M extension, so any `*` calls one of these, as it would libgcc's.
#if __riscv_xlen == 64
unsigned __int128 __multi3(unsigned __int128 a, unsigned __int128 b) {
    unsigned __int128 out = 0;
    while (b) {
        if (b & 1) out += a;
        a <<= 1;
        b >>= 1;
    }
    return out;
}
#else
unsigned __mulsi3(unsigned a, unsigned b) {
    unsigned out = 0;
    while (b) {
        if (b & 1) out += a;
        a <<= 1;
        b >>= 1;
    }
    return out;
}
static unsigned long long dividing(unsigned a, unsigned b) {
    unsigned quotient = 0, remainder = 0;
    for (int bit = 31; bit >= 0; bit--) {
        remainder = (remainder << 1) | ((a >> bit) & 1);
        if (remainder >= b) {
            remainder -= b;
            quotient |= 1u << bit;
        }
    }
    return ((unsigned long long)remainder << 32) | quotient;
}
unsigned __udivsi3(unsigned a, unsigned b) { return (unsigned)dividing(a, b); }
unsigned __umodsi3(unsigned a, unsigned b) { return (unsigned)(dividing(a, b) >> 32); }
union halves { unsigned long long whole; unsigned word[2]; };
unsigned long long __ashldi3(unsigned long long value, int count) {
    union halves in = {value}, out;
    if (count == 0) return value;
    out.word[0] = count >= 32 ? 0 : in.word[0] << count;
    out.word[1] = count >= 32 ? in.word[0] << (count - 32) : (in.word[1] << count) | (in.word[0] >> (32 - count));
    return out.whole;
}
unsigned long long __lshrdi3(unsigned long long value, int count) {
    union halves in = {value}, out;
    if (count == 0) return value;
    out.word[1] = count >= 32 ? 0 : in.word[1] >> count;
    out.word[0] = count >= 32 ? in.word[1] >> (count - 32) : (in.word[0] >> count) | (in.word[1] << (32 - count));
    return out.whole;
}
#endif
#endif
