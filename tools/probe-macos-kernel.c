// A reporting-only probe of Darwin kernel interfaces for #811(b), run by tools/probe-macos-linker.sh on the macOS CI
// runners (arm64 and Intel). It prints "probe: ..." lines and always exits 0. Questions: ablac-e8's G1 (clock, fork) and G2
// (stack bounds and the stack-overflow fault without pthread_self / pthread_get_stack*_np). libSystem is linked only to give
// the reference values, to run the threads, and to print.
//
// Raw system calls: arm64 `svc #0x80` with x16 = the BSD number (a Mach trap is a negative number there), x86-64 `syscall`
// with rax = 0x2000000 | number. The carry flag says the call failed, and the result registers (x0/x1, rax/rdx) are shown.
#define _DARWIN_C_SOURCE
#include <mach/mach_time.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <sys/ucontext.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__x86_64__)
#include <x86intrin.h>
#endif

struct raw { long r0; long r1; int carry; };

static struct raw raw_call(long number, long a0, long a1, long a2, long a3, long a4, long a5) {
    struct raw result;
#if defined(__aarch64__)
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    register long x4 __asm__("x4") = a4;
    register long x5 __asm__("x5") = a5;
    register long x16 __asm__("x16") = number;
    int carry;
    __asm__ volatile("svc #0x80\n\tcset %w[c], cs"
                     : "+r"(x0), "+r"(x1), [c] "=r"(carry)
                     : "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x16)
                     : "memory", "cc");
    result.r0 = x0;
    result.r1 = x1;
    result.carry = carry;
#else
    register long r10 __asm__("r10") = a3;
    register long r8 __asm__("r8") = a4;
    register long r9 __asm__("r9") = a5;
    long rax = (number < 0) ? number : (0x2000000L | number);
    long rdx = a2;
    unsigned char carry;
    __asm__ volatile("syscall\n\tsetc %[c]"
                     : "+a"(rax), "+d"(rdx), [c] "=q"(carry)
                     : "D"(a0), "S"(a1), "r"(r10), "r"(r8), "r"(r9)
                     : "rcx", "r11", "memory", "cc");
    result.r0 = rax;
    result.r1 = rdx;
    result.carry = carry;
#endif
    return result;
}

static void show(const char *what, struct raw r) {
    printf("probe: %s: r0=%ld (0x%lx) r1=%ld (0x%lx) carry=%d\n", what, r.r0, (unsigned long)r.r0, r.r1,
           (unsigned long)r.r1, r.carry);
}

static const char *arch_name(void) {
#if defined(__aarch64__)
    return "arm64";
#else
    return "x86-64";
#endif
}

#if !defined(SECTION) || SECTION == 2 || SECTION == 3
// ---- faults while probing: a read that traps must be reported, not end the run -------------------------------------------
static sigjmp_buf probe_jump;
static volatile int probe_signal;
static void probe_handler(int number) { probe_signal = number; siglongjmp(probe_jump, 1); }
static void guard_signals(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = probe_handler;
    sigemptyset(&action.sa_mask);
    sigaction(SIGILL, &action, NULL);
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);
}

#endif
#if !defined(SECTION) || SECTION == 1
// ---- 1. gettimeofday, BSD 116 -------------------------------------------------------------------------------------------------
static void probe_gettimeofday(void) {
    struct timeval tv = {-1, -1};
    uint64_t absolute = 0xFEEDFACEFEEDFACEull;
    uint64_t before = mach_absolute_time();
    struct raw r = raw_call(116, (long)&tv, 0, (long)&absolute, 0, 0, 0);
    uint64_t after = mach_absolute_time();
    show("G1 gettimeofday raw (tp, NULL, &abs)", r);
    printf("probe: G1 *tp = {sec %lld, usec %lld} (-1 if untouched); *abs = %llu (untouched = 0xfeedfacefeedface)\n",
           (long long)tv.tv_sec, (long long)tv.tv_usec, (unsigned long long)absolute);
    printf("probe: G1 mach_absolute_time before=%llu after=%llu; abs-before=%lld after-abs=%lld\n",
           (unsigned long long)before, (unsigned long long)after, (long long)(absolute - before),
           (long long)(after - absolute));
    struct timeval libc_tv;
    gettimeofday(&libc_tv, NULL);
    printf("probe: G1 libSystem gettimeofday = {sec %lld, usec %lld}\n", (long long)libc_tv.tv_sec,
           (long long)libc_tv.tv_usec);
}

#endif
#if !defined(SECTION) || SECTION == 2
// ---- 2. arm64: the timebase trap and the counter registers ---------------------------------------------------------------
static void probe_arm64_time(void) {
#if defined(__aarch64__)
    mach_timebase_info_data_t info = {0, 0};
    mach_timebase_info(&info);
    uint32_t trap_info[2] = {0xFFFFFFFFu, 0xFFFFFFFFu};
    struct raw r = raw_call(-89, (long)trap_info, 0, 0, 0, 0, 0);
    show("G1 mach_timebase_info trap (x16 = -89)", r);
    printf("probe: G1 trap numer/denom = %u/%u; libSystem mach_timebase_info = %u/%u\n", trap_info[0], trap_info[1],
           info.numer, info.denom);
    guard_signals();
    uint64_t value = 0;
    probe_signal = 0;
    if (sigsetjmp(probe_jump, 1) == 0) {
        __asm__ volatile("mrs %0, cntvct_el0" : "=r"(value));
        printf("probe: G1 mrs cntvct_el0 from EL0 returns %llu\n", (unsigned long long)value);
    } else {
        printf("probe: G1 mrs cntvct_el0 from EL0 raised signal %d\n", (int)probe_signal);
    }
    probe_signal = 0;
    if (sigsetjmp(probe_jump, 1) == 0) {
        __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(value));
        printf("probe: G1 mrs cntfrq_el0 from EL0 returns %llu\n", (unsigned long long)value);
    } else {
        printf("probe: G1 mrs cntfrq_el0 from EL0 raised signal %d\n", (int)probe_signal);
    }
    for (int round = 0; round < 5; round++) {
        uint64_t counter = 0;
        uint64_t absolute;
        uint64_t continuous;
        uint64_t counter2;
        probe_signal = 0;
        if (sigsetjmp(probe_jump, 1) != 0) { printf("probe: G1 readings: counter register raised %d\n", (int)probe_signal); break; }
        __asm__ volatile("mrs %0, cntvct_el0" : "=r"(counter));
        absolute = mach_absolute_time();
        continuous = mach_continuous_time();
        __asm__ volatile("mrs %0, cntvct_el0" : "=r"(counter2));
        printf("probe: G1 reading %d: cntvct=%llu absolute=%llu continuous=%llu cntvct(after)=%llu | counter-absolute=%lld counter-continuous=%lld\n",
               round, (unsigned long long)counter, (unsigned long long)absolute, (unsigned long long)continuous,
               (unsigned long long)counter2, (long long)(counter - absolute), (long long)(counter - continuous));
    }
#endif
}

#endif
#if !defined(SECTION) || SECTION == 3
// ---- 3. Intel: the commpage's time data -------------------------------------------------------------------------------------------
static void probe_intel_commpage(void) {
#if defined(__x86_64__)
    guard_signals();
    volatile uint8_t *page = (volatile uint8_t *)0x7fffffe00000ull;
    probe_signal = 0;
    if (sigsetjmp(probe_jump, 1) != 0) {
        printf("probe: G1 commpage read raised signal %d\n", (int)probe_signal);
        return;
    }
    uint16_t version = *(volatile uint16_t *)(page + 0x1E);
    uint64_t tsc_base = *(volatile uint64_t *)(page + 0x50);
    uint32_t scale = *(volatile uint32_t *)(page + 0x58);
    uint32_t shift = *(volatile uint32_t *)(page + 0x5C);
    uint64_t ns_base = *(volatile uint64_t *)(page + 0x60);
    uint32_t generation = *(volatile uint32_t *)(page + 0x68);
    printf("probe: G1 commpage: version(+0x1E)=%u nt_tsc_base(+0x50)=%llu nt_scale(+0x58)=%u nt_shift(+0x5C)=%u nt_ns_base(+0x60)=%llu nt_generation(+0x68)=%u\n",
           version, (unsigned long long)tsc_base, scale, shift, (unsigned long long)ns_base, generation);
    uint64_t ns = 0;
    int tries = 0;
    uint32_t seen;
    do {
        seen = *(volatile uint32_t *)(page + 0x68);
        tries++;
        if (seen == 0) continue;
        uint64_t tsc = __rdtsc();
        uint64_t base = *(volatile uint64_t *)(page + 0x50);
        uint32_t s = *(volatile uint32_t *)(page + 0x58);
        uint32_t sh = *(volatile uint32_t *)(page + 0x5C);
        uint64_t nb = *(volatile uint64_t *)(page + 0x60);
        uint64_t delta = (tsc - base) << sh;
        ns = (uint64_t)(((unsigned __int128)delta * s) >> 32) + nb;
    } while (seen == 0 || seen != *(volatile uint32_t *)(page + 0x68));
    uint64_t absolute = mach_absolute_time();
    mach_timebase_info_data_t info = {0, 0};
    mach_timebase_info(&info);
    printf("probe: G1 commpage formula ns=%llu, mach_absolute_time right after=%llu, difference=%lld (tries %d); libSystem timebase %u/%u\n",
           (unsigned long long)ns, (unsigned long long)absolute, (long long)(absolute - ns), tries, info.numer,
           info.denom);
#endif
}

#endif
#if !defined(SECTION) || SECTION == 4
// ---- 4. raw fork ---------------------------------------------------------------------------------------------------------------------
static volatile int spinner_stop;
static void *spin_plain(void *argument) { (void)argument; while (!spinner_stop) {} return NULL; }
static void *spin_malloc(void *argument) {
    (void)argument;
    while (!spinner_stop) { void *block = malloc(64 + (size_t)(rand() & 1023)); free(block); }
    return NULL;
}

static __thread long never_touched_before_fork = 5;

// What the raw child does, by kind: 0 write and exit, 1 first read a thread-local it never touched.
static void run_fork(const char *label, int kind, void *(*spinner)(void *)) {
    pthread_t thread;
    spinner_stop = 0;
    int spinning = 0;
    if (spinner != NULL && pthread_create(&thread, NULL, spinner, NULL) == 0) spinning = 1;
    usleep(20000);
    struct raw f = raw_call(2, 0, 0, 0, 0, 0, 0);
    if (f.r1 == 1 && !f.carry) {
        // The child, on raw system calls only (a read of the thread-local may call into libSystem's TLV bootstrap).
        if (kind == 1) {
            long value = never_touched_before_fork;
            if (value != 5) raw_call(1, 99, 0, 0, 0, 0, 0);
        }
        raw_call(4, 1, (long)"child\n", 6, 0, 0, 0);
        raw_call(1, 7, 0, 0, 0, 0, 0);
        for (;;) {}
    }
    char text[160];
    snprintf(text, sizeof(text), "G1 fork %s: parent got", label);
    show(text, f);
    int status = -1;
    int waited = 0;
    for (int waits = 0; waits < 1000 && !waited; waits++) {
        struct raw w = raw_call(7, f.r0, (long)&status, 1 /* WNOHANG */, 0, 0, 0);
        if (w.r0 == f.r0) waited = 1;
        else usleep(10000);
    }
    if (waited) {
        printf("probe: G1 fork %s: child reaped, wait status 0x%x (exit code %d, signal %d)\n", label, status,
               (status >> 8) & 255, status & 127);
    } else {
        printf("probe: G1 fork %s: the child did not finish within 10 s (hang); it is killed\n", label);
        kill((pid_t)f.r0, SIGKILL);
        int ignored;
        waitpid((pid_t)f.r0, &ignored, 0);
    }
    if (spinning) { spinner_stop = 1; pthread_join(thread, NULL); }
}

static void probe_fork(void) {
    fflush(stdout);
    run_fork("alone", 0, NULL);
    fflush(stdout);
    run_fork("with a spinning thread", 0, spin_plain);
    fflush(stdout);
    run_fork("with a thread in malloc and free", 0, spin_malloc);
    fflush(stdout);
    run_fork("alone, child reads a fresh thread-local", 1, NULL);
    fflush(stdout);
    run_fork("with a thread in malloc and free, child reads a fresh thread-local", 1, spin_malloc);
    fflush(stdout);
}

#endif
#if !defined(SECTION) || SECTION == 5
// ---- 5. stack bounds ---------------------------------------------------------------------------------------------------------------------
static uintptr_t current_sp(void) {
    uintptr_t value;
#if defined(__aarch64__)
    __asm__ volatile("mov %0, sp" : "=r"(value));
#else
    __asm__ volatile("movq %%rsp, %0" : "=r"(value));
#endif
    return value;
}

static void report_bounds(const char *who, uintptr_t sp) {
    pthread_t self = pthread_self();
    uintptr_t addr = (uintptr_t)pthread_get_stackaddr_np(self);
    size_t size = pthread_get_stacksize_np(self);
    printf("probe: G2 %s: sp=0x%llx pthread_get_stackaddr_np=0x%llx pthread_get_stacksize_np=%zu (%zu KiB); stackaddr-sp=%lld\n",
           who, (unsigned long long)sp, (unsigned long long)addr, size, size / 1024, (long long)(addr - sp));
    struct rlimit limit;
    getrlimit(RLIMIT_STACK, &limit);
    printf("probe: G2 %s: RLIMIT_STACK cur=%llu max=%llu; (stackaddr-stacksize) == (stackaddr-rlimit.cur): %s\n", who,
           (unsigned long long)limit.rlim_cur, (unsigned long long)limit.rlim_max,
           (size == (size_t)limit.rlim_cur) ? "yes" : "no");
}

static void *bounds_thread(void *argument) {
    (void)argument;
    report_bounds("secondary pthread (NULL attr), at its start routine", current_sp());
    return NULL;
}

static void probe_bounds(void) {
    report_bounds("main thread, in main's callee", current_sp());
    pthread_t thread;
    pthread_create(&thread, NULL, bounds_thread, NULL);
    pthread_join(thread, NULL);
}

#endif
#if !defined(SECTION) || SECTION == 6
// ---- 6. the stack-overflow fault -----------------------------------------------------------------------------------------------
static sigjmp_buf overflow_jump;
static volatile int overflow_signal;
static volatile uintptr_t overflow_si_addr, overflow_sp, overflow_field_offset, overflow_stack_low;

static void overflow_handler(int number, siginfo_t *info, void *context) {
    ucontext_t *uc = (ucontext_t *)context;
    overflow_signal = number;
    overflow_si_addr = (uintptr_t)info->si_addr;
#if defined(__aarch64__)
    overflow_sp = (uintptr_t)uc->uc_mcontext->__ss.__sp;
    overflow_field_offset = (uintptr_t)&uc->uc_mcontext->__ss.__sp - (uintptr_t)uc->uc_mcontext;
#else
    overflow_sp = (uintptr_t)uc->uc_mcontext->__ss.__rsp;
    overflow_field_offset = (uintptr_t)&uc->uc_mcontext->__ss.__rsp - (uintptr_t)uc->uc_mcontext;
#endif
    siglongjmp(overflow_jump, 1);
}

static int __attribute__((noinline, optnone)) recurse(int depth) {
    volatile char pad[256];
    pad[0] = (char)depth;
    pad[255] = (char)depth;
    return recurse(depth + 1) + pad[0] + pad[255];
}

static void overflow_here(const char *who) {
    pthread_t self = pthread_self();
    uintptr_t addr = (uintptr_t)pthread_get_stackaddr_np(self);
    size_t size = pthread_get_stacksize_np(self);
    overflow_stack_low = addr - size;
    stack_t alternate;
    alternate.ss_sp = malloc(1 << 16);
    alternate.ss_size = 1 << 16;
    alternate.ss_flags = 0;
    sigaltstack(&alternate, NULL);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = overflow_handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigemptyset(&action.sa_mask);
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);
    overflow_signal = 0;
    if (sigsetjmp(overflow_jump, 1) == 0) {
        recurse(0);
        printf("probe: G2 overflow %s: recursion returned (not possible)\n", who);
        return;
    }
    printf("probe: G2 overflow %s: signal %d (%s), si_addr=0x%llx, sp in ucontext=0x%llx, offset of the sp field in *uc_mcontext=%llu\n",
           who, (int)overflow_signal, overflow_signal == SIGSEGV ? "SIGSEGV" : overflow_signal == SIGBUS ? "SIGBUS" : "other",
           (unsigned long long)overflow_si_addr, (unsigned long long)overflow_sp,
           (unsigned long long)overflow_field_offset);
    printf("probe: G2 overflow %s: stack low end (stackaddr-stacksize)=0x%llx; si_addr - low = %lld; sp - si_addr = %lld\n",
           who, (unsigned long long)overflow_stack_low, (long long)(overflow_si_addr - overflow_stack_low),
           (long long)(overflow_sp - overflow_si_addr));
}

static void *overflow_thread(void *argument) {
    (void)argument;
    overflow_here("secondary pthread");
    return NULL;
}

static void probe_overflow(void) {
    fflush(stdout);
    // Each in a child process: the overflow leaves the stack's pages touched and its handlers installed.
    pid_t child = fork();
    if (child == 0) {
        overflow_here("main thread");
        fflush(stdout);
        _exit(0);
    }
    int status = 0;
    waitpid(child, &status, 0);
    printf("probe: G2 overflow main thread: child status 0x%x\n", status);
    fflush(stdout);
    child = fork();
    if (child == 0) {
        pthread_t thread;
        pthread_create(&thread, NULL, overflow_thread, NULL);
        pthread_join(thread, NULL);
        fflush(stdout);
        _exit(0);
    }
    waitpid(child, &status, 0);
    printf("probe: G2 overflow secondary pthread: child status 0x%x\n", status);
}

#endif
#if !defined(SECTION) || SECTION == 7
// ---- 7. hw.tbfrequency by the raw sysctlbyname (BSD 274) ------------------------------------------------------------------------
#include <sys/sysctl.h>
static void probe_tbfrequency(void) {
    const char *name = "hw.tbfrequency";
    uint64_t value = 0xFEEDFACEFEEDFACEull;
    uint64_t length = 8;
    struct raw r = raw_call(274, (long)name, (long)strlen(name), (long)&value, (long)&length, 0, 0);
    show("G1 sysctlbyname raw (\"hw.tbfrequency\", 14, &u64, &8, NULL, 0)", r);
    printf("probe: G1 raw hw.tbfrequency = %llu, oldlen after = %llu\n", (unsigned long long)value,
           (unsigned long long)length);
    uint64_t libc_value = 0;
    size_t libc_length = sizeof(libc_value);
    int status = sysctlbyname(name, &libc_value, &libc_length, NULL, 0);
    mach_timebase_info_data_t info = {0, 0};
    mach_timebase_info(&info);
    uint64_t before = mach_absolute_time();
    uint64_t absolute = 0xFEEDFACEFEEDFACEull;
    struct timeval tv;
    struct raw g = raw_call(116, (long)&tv, 0, (long)&absolute, 0, 0, 0);
    uint64_t after = mach_absolute_time();
    printf("probe: G1 libSystem sysctlbyname = %d, hw.tbfrequency = %llu; mach_timebase_info = %u/%u; gettimeofday raw r0=%ld *abs=%llu (between %llu and %llu)\n",
           status, (unsigned long long)libc_value, info.numer, info.denom, g.r0, (unsigned long long)absolute,
           (unsigned long long)before, (unsigned long long)after);
    if (value != 0 && value != 0xFEEDFACEFEEDFACEull) {
        printf("probe: G1 ns = abs * 1e9 / tbfrequency: %llu (mach_absolute_time * numer / denom = %llu)\n",
               (unsigned long long)((unsigned __int128)after * 1000000000u / value),
               (unsigned long long)((unsigned __int128)after * info.numer / info.denom));
    }
#if defined(__x86_64__)
    int translated = 0;
    size_t translated_length = sizeof(translated);
    int rosetta = sysctlbyname("sysctl.proc_translated", &translated, &translated_length, NULL, 0);
    printf("probe: G1 sysctl.proc_translated = %d (call returned %d)\n", translated, rosetta);
#endif
}
#endif
int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("probe: kernel probe on %s\n", arch_name());
#if !defined(SECTION) || SECTION == 1
    probe_gettimeofday();
#endif
#if !defined(SECTION) || SECTION == 2
    probe_arm64_time();
#endif
#if !defined(SECTION) || SECTION == 3
    probe_intel_commpage();
#endif
#if !defined(SECTION) || SECTION == 5
    probe_bounds();
#endif
#if !defined(SECTION) || SECTION == 4
    probe_fork();
#endif
#if !defined(SECTION) || SECTION == 6
    probe_overflow();
#endif
#if !defined(SECTION) || SECTION == 7
    probe_tbfrequency();
#endif
    printf("probe: kernel probe done\n");
    return 0;
}
