/*
 * Minimal x86-64 Linux process/runtime boundary for --target
 * x86_64-linux-raw.  This object is linked without CRT objects or libc.
 *
 * The generated Abla module owns its higher-level allocation accounting.
 * malloc/free here are deliberately tiny target hooks backed by one mmap per
 * allocation.  Keeping these compatibility symbol names also prevents LLVM
 * from introducing an unresolved libc dependency when it lowers intrinsics.
 */

    .text
    .globl _start
    .type _start,@function
_start:
    xorl %ebp, %ebp
    movl (%rsp), %edi
    leaq 8(%rsp), %rsi
    andq $-16, %rsp
    call main
    movslq %eax, %rdi
    movl $231, %eax                 /* exit_group */
    syscall
    ud2
    .size _start, .-_start

    .globl abla_platform_alloc
    .type abla_platform_alloc,@function
abla_platform_alloc:
    jmp malloc
    .size abla_platform_alloc, .-abla_platform_alloc

    .globl abla_platform_free
    .type abla_platform_free,@function
abla_platform_free:
    jmp free
    .size abla_platform_free, .-abla_platform_free

    .globl abla_platform_panic
    .type abla_platform_panic,@function
abla_platform_panic:
    movl $127, %edi
    movl $231, %eax
    syscall
    ud2
    .size abla_platform_panic, .-abla_platform_panic

    .globl abla_platform_memory_checkpoint
abla_platform_memory_checkpoint:
    xorl %eax, %eax
    ret
    .globl abla_platform_memory_reset
abla_platform_memory_reset:
    ret
    .globl abla_platform_memory_live_bytes
abla_platform_memory_live_bytes:
    xorl %eax, %eax
    ret
    .globl abla_platform_memory_limit
abla_platform_memory_limit:
    movabsq $9223372036854775807, %rax
    ret
    .globl abla_platform_memory_set_limit
abla_platform_memory_set_limit:
    ret
    .globl abla_platform_memory_set_scan
abla_platform_memory_set_scan:
    ret
    .globl abla_platform_memory_set_layout
abla_platform_memory_set_layout:
    ret
    .globl abla_platform_memory_collect
abla_platform_memory_collect:
    /* A collection pass completed. The raw allocator returns one when no
       tracked byte count is available so callers can distinguish the pass
       from an unsupported operation. */
    movl $1, %eax
    ret
    .globl abla_runtime_roots_push
abla_runtime_roots_push:
    ret
    .globl abla_runtime_roots_pop
abla_runtime_roots_pop:
    ret
    .globl abla_runtime_memory_pressure
abla_runtime_memory_pressure:
    ret

    .globl malloc
    .type malloc,@function
malloc:
    testq %rdi, %rdi
    jne .Lmalloc_nonzero
    movl $1, %edi
.Lmalloc_nonzero:
    addq $16, %rdi
    jc .Lmalloc_failed
    movq %rdi, %rsi                 /* mmap length */
    xorl %edi, %edi                 /* address */
    movl $3, %edx                   /* PROT_READ | PROT_WRITE */
    movl $34, %r10d                 /* MAP_PRIVATE | MAP_ANONYMOUS */
    movq $-1, %r8
    xorl %r9d, %r9d
    movl $9, %eax                   /* mmap */
    syscall
    cmpq $-4095, %rax
    jae .Lmalloc_failed
    movq %rsi, (%rax)
    movabsq $0x41424c4152415731, %rcx
    movq %rcx, 8(%rax)
    addq $16, %rax
    ret
.Lmalloc_failed:
    xorl %eax, %eax
    ret
    .size malloc, .-malloc

    .globl free
    .type free,@function
free:
    testq %rdi, %rdi
    je .Lfree_done
    subq $16, %rdi
    movq (%rdi), %rsi
    movl $11, %eax                  /* munmap */
    syscall
.Lfree_done:
    ret
    .size free, .-free

    .globl memcpy
    .type memcpy,@function
memcpy:
    movq %rdi, %rax
    movq %rdx, %rcx
    rep movsb
    ret
    .size memcpy, .-memcpy

    .globl memmove
    .type memmove,@function
memmove:
    movq %rdi, %rax
    cmpq %rsi, %rdi
    jbe .Lmemmove_forward
    leaq -1(%rsi,%rdx), %rsi
    leaq -1(%rdi,%rdx), %rdi
    movq %rdx, %rcx
    std
    rep movsb
    cld
    ret
.Lmemmove_forward:
    movq %rdx, %rcx
    rep movsb
    ret
    .size memmove, .-memmove

    .globl memset
    .type memset,@function
memset:
    movq %rdi, %r9
    movl %esi, %eax
    movq %rdx, %rcx
    rep stosb
    movq %r9, %rax
    ret
    .size memset, .-memset

    .globl memcmp
    .type memcmp,@function
memcmp:
    xorl %eax, %eax
    testq %rdx, %rdx
    je .Lmemcmp_done
.Lmemcmp_loop:
    movzbl (%rdi), %eax
    movzbl (%rsi), %ecx
    subl %ecx, %eax
    jne .Lmemcmp_done
    incq %rdi
    incq %rsi
    decq %rdx
    jne .Lmemcmp_loop
.Lmemcmp_done:
    ret
    .size memcmp, .-memcmp

    .globl strlen
    .type strlen,@function
strlen:
    xorl %eax, %eax
.Lstrlen_loop:
    cmpb $0, (%rdi,%rax)
    je .Lstrlen_done
    incq %rax
    jmp .Lstrlen_loop
.Lstrlen_done:
    ret
    .size strlen, .-strlen

    .section .note.GNU-stack,"",@progbits
