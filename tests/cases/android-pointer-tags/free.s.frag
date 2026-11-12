    .globl free
free:
    cbz x0, 2f
    lsr x2, x0, #56
    ldur x3, [x0, #-8]
    cmp x2, x3
    b.ne tagged_bad_pointer
    // Remember release, so double free and realloc-after-free are rejected.
    orr x2, x2, #0x100
    stur x2, [x0, #-8]
    adrp x2, tagged_freed
    add x2, x2, :lo12:tagged_freed
    ldr x3, [x2]
    add x3, x3, #1
    str x3, [x2]
    // A bump allocator alone would leave wrongly collected live values usable.
    // Poison the actual allocation after its prefix, making lost roots fail.
    ldur x3, [x0, #-16]
    sub x3, x3, #16
    mov x4, x0
    mov w5, #0xdd
1:  cbz x3, 2f
    strb w5, [x4], #1
    sub x3, x3, #1
    b 1b
2:  ret

tagged_check_pointer:
    cbz x0, 2f
    lsr x2, x0, #56
    ldur x3, [x0, #-8]
    cmp x2, x3
    b.ne tagged_bad_pointer
2:  ret

tagged_bad_pointer:
    mov w0, #66
    mov w8, #93
    svc #0

    // Custom call names keep the invalid-tag controls out of malloc/free
    // builtin folding; production runtime calls still use the actual ABI.
    .globl tagged_probe_free
tagged_probe_free:
    b free
    .globl tagged_probe_realloc
tagged_probe_realloc:
    b realloc

    .globl tagged_set_mode
tagged_set_mode:
    adrp x1, tagged_mode
    add x1, x1, :lo12:tagged_mode
    str x0, [x1]
    ret

    .globl tagged_free_count
tagged_free_count:
    adrp x1, tagged_freed
    add x1, x1, :lo12:tagged_freed
    ldr x0, [x1]
    ret

    .globl getpid
getpid:
    mov x0, #1
    ret
