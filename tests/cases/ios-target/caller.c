#include "runtime-deadline.h"
#include "abla_app.h"
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static mach_task_basic_info_data_t memory_info(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) {
        fputs("cannot measure Simulator task memory\n", stderr);
        exit(1);
    }
    return info;
}

int main(void) {
    ios_test_runtime_deadline();
    fputs("ios-caller: entered C main\n", stderr);
    /* Prime libc's own allocation zones before attributing new mappings to
       the managed runtime. This is not a physical-device memory-limit test. */
    void *small = malloc(16);
    void *large = malloc(4096);
    if (!small || !large) return 1;
    *(volatile unsigned char *)small = 1;
    *(volatile unsigned char *)large = 1;
    free(small);
    free(large);
    const mach_task_basic_info_data_t before = memory_info();
    fputs("ios-caller: before scalar export\n", stderr);
    const int64_t result = abla_ios_answer();
    fputs("ios-caller: before managed export\n", stderr);
    const int64_t managed = abla_ios_managed_answer(41);
    fputs("ios-caller: managed export returned\n", stderr);
    const mach_task_basic_info_data_t after = memory_info();
    if (result != 42 || managed != 126) {
        fprintf(stderr, "iOS exports returned %lld/%lld, expected 42/126\n",
                (long long)result, (long long)managed);
        return 1;
    }
    const int64_t limit = abla_ios_memory_limit();
    const int64_t live = abla_ios_memory_live();
    if (limit != 16 * 1024 * 1024 || live < 0 || live >= limit) return 1;
    const uint64_t growth = after.virtual_size > before.virtual_size
                              ? after.virtual_size - before.virtual_size : 0;
    printf("ios-runtime vm_before=%llu vm_after=%llu vm_growth=%llu "
           "rss_before=%llu rss_after=%llu managed_limit=%lld managed_live=%lld\n",
           (unsigned long long)before.virtual_size,
           (unsigned long long)after.virtual_size, (unsigned long long)growth,
           (unsigned long long)before.resident_size,
           (unsigned long long)after.resident_size,
           (long long)limit, (long long)live);
    if (growth > 128ULL * 1024 * 1024) {
        fputs("managed startup mapped more than the 128 MiB test budget\n", stderr);
        return 1;
    }
    puts("iOS Simulator: Abla C export returned 42; managed collection returned 126");
    return 0;
}
