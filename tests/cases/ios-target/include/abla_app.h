#ifndef ABLA_IOS_TEST_APP_H
#define ABLA_IOS_TEST_APP_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int64_t abla_ios_answer(void);
int64_t abla_ios_target_check(void);
int64_t abla_ios_managed_paths(int64_t seed);
int64_t abla_ios_native_address(void);
int64_t abla_ios_managed_answer(int64_t seed);
int64_t abla_ios_memory_limit(void);
int64_t abla_ios_memory_live(void);
#ifdef __cplusplus
}
#endif
#endif
