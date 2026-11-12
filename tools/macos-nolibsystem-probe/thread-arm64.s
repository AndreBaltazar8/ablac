// A thread without libpthread (arm64 macOS): mmap a stack, bsdthread_register
// (366) with our own thread start, bsdthread_create (360), wait for a flag the
// thread sets. Exit status: 0 the thread ran, 2 mmap failed, 3 register failed,
// 4 create failed, 5 the thread never ran. The failing errno is written as a
// digit pair after the message.
    .text
    .p2align 2
    .globl _start
    .globl _main
_start:
_main:
    // mmap(0, 0x20000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0)
    mov x0, #0
    mov x1, #0x20000
    mov x2, #3
    mov x3, #0x1002
    mov x4, #-1
    mov x5, #0
    mov x16, #197
    svc #0x80
    b.cs fail_mmap
    mov x19, x0
    // bsdthread_register(threadstart, wqthread=0, flags=0, 0, 0, 0)
    adrp x0, thread_start@PAGE
    add x0, x0, thread_start@PAGEOFF
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x5, #0
    mov x16, #366
    svc #0x80
    b.cs fail_register
    // bsdthread_create(func, arg, stack, pthread, flags)
    mov x20, #0x1f000
    add x20, x19, x20
    adrp x0, thread_main@PAGE
    add x0, x0, thread_main@PAGEOFF
    mov x1, #77
    mov x2, x20
    mov x3, x20
    mov x4, #0
    mov x16, #360
    svc #0x80
    b.cs fail_create
    // wait for the flag
    adrp x21, flag@PAGE
    add x21, x21, flag@PAGEOFF
    movz x22, #0x9680
    movk x22, #0x98, lsl #16
wait:
    ldar x0, [x21]
    cbnz x0, ran
    subs x22, x22, #1
    b.ne wait
    mov x23, #5
    adrp x1, m_never@PAGE
    add x1, x1, m_never@PAGEOFF
    mov x2, #32
    b report
ran:
    mov x23, #0
    adrp x1, m_ran@PAGE
    add x1, x1, m_ran@PAGEOFF
    mov x2, #32
    b report
fail_mmap:
    mov x24, x0
    mov x23, #2
    adrp x1, m_mmap@PAGE
    add x1, x1, m_mmap@PAGEOFF
    mov x2, #32
    b report_errno
fail_register:
    mov x24, x0
    mov x23, #3
    adrp x1, m_register@PAGE
    add x1, x1, m_register@PAGEOFF
    mov x2, #32
    b report_errno
fail_create:
    mov x24, x0
    mov x23, #4
    adrp x1, m_create@PAGE
    add x1, x1, m_create@PAGEOFF
    mov x2, #32
    b report_errno
report_errno:
    mov x0, #1
    mov x16, #4
    svc #0x80
    // errno as two decimal digits and a newline
    mov x9, #10
    udiv x10, x24, x9
    msub x11, x10, x9, x24
    add x10, x10, #48
    add x11, x11, #48
    adrp x12, digits@PAGE
    add x12, x12, digits@PAGEOFF
    strb w10, [x12]
    strb w11, [x12, #1]
    mov x0, #1
    mov x1, x12
    mov x2, #3
    mov x16, #4
    svc #0x80
    b leave
report:
    mov x0, #1
    mov x16, #4
    svc #0x80
leave:
    mov x0, x23
    mov x16, #1
    svc #0x80
    brk #1

// Registered thread start: x0 pthread, x1 kernel port, x2 function, x3 argument.
    .p2align 2
thread_start:
    mov x19, x1
    mov x0, x3
    blr x2
    // bsdthread_terminate(stackaddr=0, freesize=0, port, sem=0)
    mov x0, #0
    mov x1, #0
    mov x2, x19
    mov x3, #0
    mov x16, #361
    svc #0x80
    brk #1

    .p2align 2
thread_main:
    adrp x1, m_thread@PAGE
    add x1, x1, m_thread@PAGEOFF
    mov x2, #18
    mov x0, #1
    mov x16, #4
    svc #0x80
    adrp x1, flag@PAGE
    add x1, x1, flag@PAGEOFF
    mov x2, #1
    stlr x2, [x1]
    ret

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
