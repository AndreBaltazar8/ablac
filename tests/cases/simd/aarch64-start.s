// What an AArch64 test object needs to run under qemu-aarch64 with no C library: a start,
// a bump allocator that never reuses, and exit(99) for the libc calls it should never
// reach. It runs one export and exits with its result.
    .text
    .globl _start
_start:
    adrp x0, tls_block
    add x0, x0, :lo12:tls_block
    msr tpidr_el0, x0
    bl simd_checks
    mov w8, #93
    svc #0

    .globl malloc
malloc:
    add x0, x0, #31
    and x0, x0, #-16
    adrp x1, heap_next
    add x1, x1, :lo12:heap_next
    ldr x2, [x1]
    cbnz x2, 1f
    adrp x2, heap
    add x2, x2, :lo12:heap
1:  add x3, x2, x0
    str x3, [x1]
    str x0, [x2]
    add x0, x2, #16
    ret

    .globl calloc
calloc:
    mul x0, x0, x1
    b malloc

    .globl realloc
realloc:
    stp x29, x30, [sp, #-32]!
    stp x0, x1, [sp, #16]
    mov x0, x1
    bl malloc
    ldp x1, x2, [sp, #16]
    cbz x1, 2f
    ldur x3, [x1, #-16]
    sub x3, x3, #16
    cmp x3, x2
    csel x3, x3, x2, lo
    mov x4, x0
1:  cbz x3, 2f
    ldrb w5, [x1], #1
    strb w5, [x4], #1
    sub x3, x3, #1
    b 1b
2:  ldp x29, x30, [sp], #32
    ret

    .globl free
free:
    ret

    .globl memcpy
    .globl memmove
memcpy:
memmove:
    cmp x0, x1
    b.hi 2f
    mov x3, x0
1:  cbz x2, 3f
    ldrb w4, [x1], #1
    strb w4, [x3], #1
    sub x2, x2, #1
    b 1b
2:  cbz x2, 3f
    sub x2, x2, #1
    ldrb w4, [x1, x2]
    strb w4, [x0, x2]
    b 2b
3:  ret

    .globl memset
memset:
    mov x3, x0
1:  cbz x2, 2f
    strb w1, [x3], #1
    sub x2, x2, #1
    b 1b
2:  ret

    .globl memcmp
memcmp:
1:  cbz x2, 2f
    ldrb w3, [x0], #1
    ldrb w4, [x1], #1
    sub w5, w3, w4
    cbnz w5, 3f
    sub x2, x2, #1
    b 1b
2:  mov w5, #0
3:  mov w0, w5
    ret

    .globl strlen
strlen:
    mov x1, x0
1:  ldrb w2, [x1], #1
    cbnz w2, 1b
    sub x0, x1, x0
    sub x0, x0, #1
    ret

    .globl __errno_location
__errno_location:
    adrp x0, errno_word
    add x0, x0, :lo12:errno_word
    ret

    .globl getenv
    .globl pthread_mutex_lock
    .globl pthread_mutex_unlock
    .globl pthread_mutex_init
    .globl pthread_mutex_destroy
getenv:
pthread_mutex_lock:
pthread_mutex_unlock:
pthread_mutex_init:
pthread_mutex_destroy:
    mov x0, #0
    ret

    .globl write
write:
    mov w8, #64
    svc #0
    ret

    .globl _exit
_exit:
    mov w8, #93
    svc #0

    .globl syscall
syscall:
    mov x8, x0
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    mov x4, x5
    mov x5, x6
    svc #0
    ret

    .macro never name
    .globl \name
\name:
    mov w0, #99
    mov w8, #93
    svc #0
    .endm
    never _longjmp
    never backtrace
    never backtrace_symbols_fd
    never getrlimit
    never pthread_join
    never raise
    never sigaction
    never sigaltstack
    never signal
    never __tls_get_addr

    .bss
    .balign 16
tls_block: .space 4096
errno_word: .space 8
heap_next: .space 8
    .balign 16
heap: .space 67108864
