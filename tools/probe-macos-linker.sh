#!/usr/bin/env bash
# A reporting-only probe of the Mac's linker and thread registers for #811(b) (macOS without libSystem). It never fails:
# it prints "probe: ..." lines that the CI log keeps, and the people who plan the work read them. It answers what no
# earlier run did:
#   G5  Does ld64 at -mmacosx-version-min=11.0 accept -fixup_chains (x86-64 and arm64)? Does the image then have an
#       LC_DYLD_CHAINED_FIXUPS and no dyld_stub_binder import? Does it run?
#   G6  Is TPIDR_EL0 (arm64) kept per thread across context switches for a value a thread writes? Where does the
#       thread's TSD sit (TPIDRRO_EL0 on arm64, %gs on x86-64), and is a pthread key's slot at key * 8 from it?
#   G1/G2 (ablac-e8's questions, tools/probe-macos-kernel.c): gettimeofday and the timebase trap, the counter
#       registers, the commpage time data (Intel), raw fork (BSD 2) with and without other threads, stack bounds and the
#       stack-overflow fault of the main thread and of a pthread. One compile and run per section, so a failing one costs only itself.
# Usage: tools/probe-macos-linker.sh   (Darwin only; the output directory is build/macos-probe)
set -uo pipefail
if [[ $(uname -s) != Darwin ]]; then
    echo 'probe: Darwin only'
    exit 0
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/macos-probe"
rm -rf "$out"
mkdir -p "$out"
say() { printf 'probe: %s\n' "$*"; }
# Runs a program for at most $1 seconds (macOS has no timeout): its status, 124 when it was killed.
guarded() {
    local limit=$1
    shift
    "$@" &
    local pid=$! seconds=0
    while kill -0 "$pid" 2> /dev/null && (( seconds < limit )); do
        sleep 1
        seconds=$((seconds + 1))
    done
    if kill -0 "$pid" 2> /dev/null; then
        kill -9 "$pid" 2> /dev/null
        wait "$pid" 2> /dev/null
        return 124
    fi
    wait "$pid"
}
machine=$(uname -m)
say "host $machine, macOS $(sw_vers -productVersion 2>/dev/null || echo '?'), $(xcrun ld -v 2>&1 | head -n 1 || true)"

# ---- G5: -fixup_chains at -mmacosx-version-min=11.0 --------------------------------------------------------------------
cat > "$out/hello.c" <<'C'
#include <unistd.h>
int main(void) { write(1, "hi\n", 3); return 42; }
C
for arch in arm64 x86_64; do
    for chains in default fixup_chains no_fixup_chains; do
        flags=()
        case $chains in
            fixup_chains) flags=(-Wl,-fixup_chains) ;;
            no_fixup_chains) flags=(-Wl,-no_fixup_chains) ;;
        esac
        name="hello-$arch-$chains"
        if ! xcrun clang -arch "$arch" -mmacosx-version-min=11.0 -O1 ${flags[@]+"${flags[@]}"} \
            -o "$out/$name" "$out/hello.c" > "$out/$name.log" 2>&1; then
            say "G5 $arch $chains: link failed: $(tr '\n' ' ' < "$out/$name.log" | cut -c1-300)"
            continue
        fi
        loads=$(otool -l "$out/$name" 2>/dev/null)
        chained=no
        [[ $loads == *LC_DYLD_CHAINED_FIXUPS* ]] && chained=yes
        classic=no
        [[ $loads == *LC_DYLD_INFO* ]] && classic=yes
        binder=no
        nm -u "$out/$name" 2>/dev/null | grep dyld_stub_binder > /dev/null && binder=yes
        main_command=none
        [[ $loads == *LC_MAIN* ]] && main_command=LC_MAIN
        [[ $loads == *LC_UNIXTHREAD* ]] && main_command=LC_UNIXTHREAD
        minos=$(printf '%s\n' "$loads" | awk '/LC_BUILD_VERSION/ {f=1} f && /minos/ {print $2; exit}')
        runs="not run"
        if [[ $arch == "$machine" || ( $arch == x86_64 && $machine == arm64 ) ]]; then
            status=0
            "$out/$name" > "$out/$name.out" 2>&1 || status=$?
            runs="exit $status ($(tr -d '\n' < "$out/$name.out" | cut -c1-40))"
            [[ $arch == x86_64 && $machine == arm64 ]] && runs="$runs under Rosetta"
        fi
        say "G5 $arch $chains: LC_DYLD_CHAINED_FIXUPS=$chained LC_DYLD_INFO=$classic dyld_stub_binder import=$binder entry=$main_command minos=$minos run=$runs"
    done
done
say "G5 libraries of the default arm64 image: $(otool -L "$out/hello-arm64-default" 2>/dev/null | tail -n +2 | tr -d '\t' | tr '\n' ';')"

# ---- G6: thread registers -----------------------------------------------------------------------------------------------
cat > "$out/threads.c" <<'C'
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

#if defined(__aarch64__)
static inline uint64_t read_rw(void) { uint64_t v; __asm__ volatile("mrs %0, tpidr_el0" : "=r"(v)); return v; }
static inline void write_rw(uint64_t v) { __asm__ volatile("msr tpidr_el0, %0" : : "r"(v)); }
static inline uint64_t read_tsd_base(void) { uint64_t v; __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(v)); return v; }
#else
static inline uint64_t read_rw(void) { return 0; }
static inline void write_rw(uint64_t v) { (void)v; }
static inline uint64_t read_tsd_base(void) { uint64_t v; __asm__ volatile("movq %%gs:0, %0" : "=r"(v)); return v; }
#endif

struct report { uint64_t first; uint64_t pattern; long mismatches; long reads; };

static void *worker(void *argument) {
    struct report *report = argument;
    report->first = read_rw();
    write_rw(report->pattern);
    for (long round = 0; round < 200000; round++) {
        if (round % 50 == 0) sched_yield();
        if (round % 5000 == 0) { struct timespec pause = {0, 200000}; nanosleep(&pause, NULL); }
        report->reads++;
        if (read_rw() != report->pattern) report->mismatches++;
    }
    return NULL;
}

int main(void) {
#if defined(__aarch64__)
    printf("probe: G6 arm64: main thread TPIDR_EL0 at start = 0x%llx, TPIDRRO_EL0 = 0x%llx\n",
           (unsigned long long)read_rw(), (unsigned long long)read_tsd_base());
    struct report reports[4];
    pthread_t threads[4];
    for (int i = 0; i < 4; i++) {
        reports[i] = (struct report){0, 0xA5A5000000000000ull + (uint64_t)(i + 1) * 0x1111, 0, 0};
        pthread_create(&threads[i], NULL, worker, &reports[i]);
    }
    for (int i = 0; i < 4; i++) {
        pthread_join(threads[i], NULL);
        printf("probe: G6 arm64 thread %d: TPIDR_EL0 at start = 0x%llx, wrote 0x%llx, %ld reads, %ld differ\n",
               i, (unsigned long long)reports[i].first, (unsigned long long)reports[i].pattern,
               reports[i].reads, reports[i].mismatches);
    }
    // Does the main thread's value survive a pthread_create/join cycle, and a fork?
    write_rw(0x1234567800000001ull);
    pthread_t again;
    struct report side = {0, 0x77, 0, 0};
    pthread_create(&again, NULL, worker, &side);
    pthread_join(again, NULL);
    printf("probe: G6 arm64 main thread after a thread ran: TPIDR_EL0 = 0x%llx (wrote 0x1234567800000001)\n",
           (unsigned long long)read_rw());
    pid_t child = fork();
    if (child == 0) { _exit(read_rw() == 0x1234567800000001ull ? 0 : 1); }
    int status = 0;
    waitpid(child, &status, 0);
    printf("probe: G6 arm64 value in a forked child: %s\n", WIFEXITED(status) && WEXITSTATUS(status) == 0 ? "kept" : "changed");
#endif
    // The thread's TSD block: the keys' slots.
    pthread_key_t keys[3];
    for (int i = 0; i < 3; i++) { pthread_key_create(&keys[i], NULL); pthread_setspecific(keys[i], (void *)(uintptr_t)(0xBEEF0000u + (unsigned)i)); }
    uint64_t base = read_tsd_base();
    printf("probe: G6 %s TSD base = 0x%llx, pthread_self = %p\n",
#if defined(__aarch64__)
           "arm64 (TPIDRRO_EL0)",
#else
           "x86-64 (%gs:0)",
#endif
           (unsigned long long)base, (void *)pthread_self());
    for (int i = 0; i < 3; i++) {
#if defined(__aarch64__)
        uint64_t slot = *(volatile uint64_t *)(base + (uint64_t)keys[i] * 8);
#else
        uint64_t slot;
        switch (i) {
        case 0: __asm__ volatile("movq %%gs:(,%1,8), %0" : "=r"(slot) : "r"((uint64_t)keys[0])); break;
        case 1: __asm__ volatile("movq %%gs:(,%1,8), %0" : "=r"(slot) : "r"((uint64_t)keys[1])); break;
        default: __asm__ volatile("movq %%gs:(,%1,8), %0" : "=r"(slot) : "r"((uint64_t)keys[2])); break;
        }
#endif
        printf("probe: G6 key %lu: pthread_getspecific = 0x%llx, TSD slot key*8 = 0x%llx\n", (unsigned long)keys[i],
               (unsigned long long)(uintptr_t)pthread_getspecific(keys[i]), (unsigned long long)slot);
    }
    // The first 16 words of the block, as a layout dump.
    printf("probe: G6 TSD words 0..15:");
    for (int i = 0; i < 16; i++) {
#if defined(__aarch64__)
        printf(" %llx", (unsigned long long)*(volatile uint64_t *)(base + (uint64_t)i * 8));
#else
        uint64_t word;
        switch (i) {
        default: word = 0; break;
        case 0: __asm__ volatile("movq %%gs:0, %0" : "=r"(word)); break;
        case 1: __asm__ volatile("movq %%gs:8, %0" : "=r"(word)); break;
        case 2: __asm__ volatile("movq %%gs:16, %0" : "=r"(word)); break;
        case 3: __asm__ volatile("movq %%gs:24, %0" : "=r"(word)); break;
        case 4: __asm__ volatile("movq %%gs:32, %0" : "=r"(word)); break;
        case 5: __asm__ volatile("movq %%gs:40, %0" : "=r"(word)); break;
        case 6: __asm__ volatile("movq %%gs:48, %0" : "=r"(word)); break;
        case 7: __asm__ volatile("movq %%gs:56, %0" : "=r"(word)); break;
        }
        printf(" %llx", (unsigned long long)word);
#endif
    }
    printf("\n");
    return 0;
}
C
if xcrun clang -mmacosx-version-min=11.0 -O1 -o "$out/threads" "$out/threads.c" > "$out/threads.log" 2>&1; then
    status=0
    guarded 120 "$out/threads" || status=$?
    say "G6 program exit $status"
else
    say "G6 build failed: $(tr '\n' ' ' < "$out/threads.log" | cut -c1-400)"
fi
# ---- G1, G2: the kernel probe, one section at a time -------------------------------------------------------------------
for section in 1 2 3 4 5 6 7; do
    if xcrun clang -mmacosx-version-min=11.0 -O0 -DSECTION=$section -o "$out/kernel-$section" "$root/tools/probe-macos-kernel.c" > "$out/kernel-$section.log" 2>&1; then
        status=0
        guarded 90 "$out/kernel-$section" || status=$?
        say "kernel section $section: exit $status"
    else
        say "kernel section $section: build failed: $(tr '\n' ' ' < "$out/kernel-$section.log" | cut -c1-500)"
    fi
done
# ---- the x86-64 build under Rosetta, on an Apple Silicon runner (one time formula for translated processes) ----------------
if [[ $machine == arm64 ]] && arch -x86_64 /usr/bin/true > /dev/null 2>&1; then
    for section in 1 3 7; do
        if xcrun clang -arch x86_64 -mmacosx-version-min=11.0 -O0 -DSECTION=$section -o "$out/kernel-x86-$section" "$root/tools/probe-macos-kernel.c" > "$out/kernel-x86-$section.log" 2>&1; then
            status=0
            guarded 90 arch -x86_64 "$out/kernel-x86-$section" || status=$?
            say "kernel section $section (x86-64 under Rosetta): exit $status"
        else
            say "kernel section $section (x86-64 under Rosetta): build failed: $(tr '\n' ' ' < "$out/kernel-x86-$section.log" | cut -c1-500)"
        fi
    done
else
    say "no Rosetta here (or an Intel runner): no translated run"
fi
exit 0
