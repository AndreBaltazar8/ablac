#ifndef ABLA_IOS_TEST_RUNTIME_DEADLINE_H
#define ABLA_IOS_TEST_RUNTIME_DEADLINE_H
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

/* Test supervisor only: the Abla archive does not contain this code. Start
   the execution budget after Simulator launch/dyld has entered C main. */
static void ios_test_runtime_deadline(void) {
    signal(SIGALRM, SIG_DFL);
#ifdef ABLA_IOS_DEADLINE_NEGATIVE
    alarm(2);
    fputs("ios-deadline-control: waiting for SIGALRM\n", stderr);
    for (;;) pause();
#else
    alarm(15);
#endif
}
#endif
