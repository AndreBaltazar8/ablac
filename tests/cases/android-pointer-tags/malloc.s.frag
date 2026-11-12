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
    adrp x4, tagged_mode
    add x4, x4, :lo12:tagged_mode
    ldr x4, [x4]
    cbnz x4, 2f
    adrp x5, tagged_count
    add x5, x5, :lo12:tagged_count
    ldr x4, [x5]
    add x6, x4, #1
    str x6, [x5]
    and x4, x4, #3
    adrp x5, tagged_bytes
    add x5, x5, :lo12:tagged_bytes
    ldrb w4, [x5, x4]
    b 3f
2:  mov x4, #0xb4
3:  str x4, [x2, #8]
    add x0, x2, #16
    orr x0, x0, x4, lsl #56
    ret

