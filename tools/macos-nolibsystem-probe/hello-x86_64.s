// write and exit by direct BSD system calls, no libSystem (x86-64 macOS):
// rax = 0x2000000 | number, syscall.
    .text
    .globl _start
    .globl _main
_start:
_main:
    movq $0x2000004, %rax
    movq $1, %rdi
    leaq message(%rip), %rsi
    movq $28, %rdx
    syscall
    movq $0x2000001, %rax
    xorl %edi, %edi
    syscall
    ud2
    .section __TEXT,__cstring
message:
    .asciz "nolibsystem: write+exit ok\n\n"
