// A thread without libpthread (x86-64 macOS): mmap a stack, bsdthread_register
// (366) with our own thread start, bsdthread_create (360), wait for a flag the
// thread sets. Exit status: 0 the thread ran, 2 mmap failed, 3 register failed,
// 4 create failed, 5 the thread never ran (errno follows a failure message).
    .text
    .globl _start
    .globl _main
_start:
_main:
    andq $-16, %rsp
    // mmap(0, 0x20000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0)
    movq $0x20000c5, %rax
    xorl %edi, %edi
    movq $0x20000, %rsi
    movq $3, %rdx
    movq $0x1002, %r10
    movq $-1, %r8
    xorl %r9d, %r9d
    syscall
    jc fail_mmap
    movq %rax, %r12
    // bsdthread_register(threadstart, wqthread=0, flags=0, 0, 0, 0)
    movq $0x2000172, %rax
    leaq thread_start(%rip), %rdi
    xorl %esi, %esi
    xorl %edx, %edx
    xorl %r10d, %r10d
    xorl %r8d, %r8d
    xorl %r9d, %r9d
    syscall
    jc fail_register
    // bsdthread_create(func, arg, stack, pthread, flags)
    leaq 0x1f000(%r12), %r13
    movq $0x2000168, %rax
    leaq thread_main(%rip), %rdi
    movq $77, %rsi
    movq %r13, %rdx
    movq %r13, %r10
    xorl %r8d, %r8d
    syscall
    jc fail_create
    movq $10000000, %rcx
wait:
    movq flag(%rip), %rax
    testq %rax, %rax
    jnz ran
    decq %rcx
    jnz wait
    movl $5, %r14d
    leaq m_never(%rip), %rsi
    jmp report
ran:
    xorl %r14d, %r14d
    leaq m_ran(%rip), %rsi
    jmp report
fail_mmap:
    movl $2, %r14d
    leaq m_mmap(%rip), %rsi
    jmp report_errno
fail_register:
    movl $3, %r14d
    leaq m_register(%rip), %rsi
    jmp report_errno
fail_create:
    movl $4, %r14d
    leaq m_create(%rip), %rsi
    jmp report_errno
report_errno:
    movq %rax, %r15
    movq $0x2000004, %rax
    movq $1, %rdi
    movq $32, %rdx
    syscall
    movq %r15, %rax
    xorl %edx, %edx
    movq $10, %rcx
    divq %rcx
    addb $48, %al
    addb $48, %dl
    leaq digits(%rip), %rsi
    movb %al, (%rsi)
    movb %dl, 1(%rsi)
    movb $10, 2(%rsi)
    movq $0x2000004, %rax
    movq $1, %rdi
    movq $3, %rdx
    syscall
    jmp leave
report:
    movq $0x2000004, %rax
    movq $1, %rdi
    movq $32, %rdx
    syscall
leave:
    movq $0x2000001, %rax
    movl %r14d, %edi
    syscall
    ud2

// Registered thread start: rdi pthread, rsi kernel port, rdx function, rcx argument.
    .p2align 4
thread_start:
    movq %rsi, %r12
    movq %rcx, %rdi
    andq $-16, %rsp
    callq *%rdx
    // bsdthread_terminate(stackaddr=0, freesize=0, port, sem=0)
    movq $0x2000169, %rax
    xorl %edi, %edi
    xorl %esi, %esi
    movq %r12, %rdx
    xorl %r10d, %r10d
    syscall
    ud2

    .p2align 4
thread_main:
    movq $0x2000004, %rax
    movq $1, %rdi
    leaq m_thread(%rip), %rsi
    movq $18, %rdx
    syscall
    movq $1, flag(%rip)
    retq

    .section __TEXT,__cstring
m_ran:      .ascii "thread: ran and wrote ok       \n"
m_never:    .ascii "thread: created, never ran     \n"
m_mmap:     .ascii "thread: mmap failed, errno=    \n"
m_register: .ascii "thread: register failed, errno=\n"
m_create:   .ascii "thread: create failed, errno=  \n"
m_thread:   .ascii "hello from thread\n\0\0"
    .data
    .p2align 3
flag:   .quad 0
digits: .space 8
