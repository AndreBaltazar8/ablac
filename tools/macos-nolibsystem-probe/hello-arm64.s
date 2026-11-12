// write and exit by direct BSD system calls, no libSystem (arm64 macOS):
// x16 = number, svc #0x80. Entry is _start (LC_MAIN or LC_UNIXTHREAD, as linked)
// or _main when libSystem is linked and nothing is imported.
    .text
    .p2align 2
    .globl _start
    .globl _main
_start:
_main:
    mov x0, #1
    adrp x1, message@PAGE
    add x1, x1, message@PAGEOFF
    mov x2, #28
    mov x16, #4
    svc #0x80
    mov x0, #0
    mov x16, #1
    svc #0x80
    brk #1
    .section __TEXT,__cstring
message:
    .asciz "nolibsystem: write+exit ok\n\n"
