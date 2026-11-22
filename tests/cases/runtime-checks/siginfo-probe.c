// macOS: what a SIGSEGV handler is given (si_code, si_addr, the machine context's exception syndrome and fault
// address) for a SIGSEGV the program raises, one it sends itself by kill, and a bad store, printed for the CI log by
// tools/test-runtime-checks.sh: the facts the stack guard's handler tells a fault from a sent signal by
// (bootstrapLlvmFaultRaised).
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ucontext.h>
#include <unistd.h>

static void report(int signal, siginfo_t *info, void *context) {
    ucontext_t *machine = context;
    unsigned syndrome = 0;
    unsigned long address = 0;
#if defined(__arm64__)
    syndrome = machine->uc_mcontext->__es.__esr;
    address = machine->uc_mcontext->__es.__far;
#elif defined(__x86_64__)
    syndrome = machine->uc_mcontext->__es.__err;
    address = machine->uc_mcontext->__es.__faultvaddr;
#endif
    char line[200];
    int length = snprintf(line, sizeof line,
        "signal %d si_code 0x%x si_addr %p si_pid %d esr 0x%x (class 0x%x) far 0x%lx\n",
        signal, info->si_code, info->si_addr, (int)info->si_pid, syndrome, syndrome >> 26, address);
    write(2, line, length);
    _exit(0);
}

int main(int count, char **arguments) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = report;
    action.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &action, 0);
    sigaction(SIGBUS, &action, 0);
    const char *mode = count > 1 ? arguments[1] : "raise";
    if (strcmp(mode, "store") == 0) *(volatile char *)16 = 1;
    else if (strcmp(mode, "kill") == 0) kill(getpid(), SIGSEGV);
    else raise(SIGSEGV);
    return 1;
}
