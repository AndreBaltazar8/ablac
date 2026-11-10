// Hand-written controls for the header-public pointer (`%0`) on AArch64; see header-x86.s. x0 holds the pointer, x1 is
// public unless the spec makes it secret (`%0,1`).
        .text
        .globl  hdr_branch, hdr_loop, payload_branch, payload_index, header_indexed, header_overwritten
        .globl  header_merge, header_call, header_store_secret, header_store_other, header_offset, helper
helper: ret

hdr_branch:
        ldr     x2, [x0, #8]
        cmp     x2, #16
        b.lo    1f
1:      ret

hdr_loop:
        ldr     x2, [x0, #24]
        ldr     x3, [x0, #16]
2:      cmp     x2, x3
        b.hs    3f
        add     x2, x2, #1
        b       2b
3:      ret

payload_branch:
        ldr     x2, [x0, #32]
        cbnz    x2, 1f
1:      ret

payload_index:
        ldr     x2, [x0, #40]
        ldr     x3, [x0, x2, lsl #3]
        ret

header_indexed:
        ldr     x2, [x0, x1]
        cbnz    x2, 1f
1:      ret

header_overwritten:
        add     x0, x0, #32
        ldr     x2, [x0]
        cbnz    x2, 1f
1:      ret

header_merge:
        cbz     x1, 1f
        mov     x0, x2
1:      ldr     x3, [x0, #8]
        cbnz    x3, 2f
2:      ret

header_call:
        str     x30, [sp, #-16]!
        bl      helper
        ldr     x30, [sp], #16
        ldr     x2, [x0, #8]
        cbnz    x2, 1f
1:      ret

header_store_secret:
        str     x1, [x0, #8]
        ldr     x2, [x0, #8]
        cbnz    x2, 1f
1:      ret

header_store_other:
        mov     x3, x0
        str     x1, [x3, #8]
        ldr     x2, [x0, #8]
        cbnz    x2, 1f
1:      ret

header_offset:
        ldr     x2, [x0, #32]
        cbnz    x2, 1f
1:      ret

// Reads that leave the header although they start in it, a bitfield insert that writes x0, and a store into static
// memory the object may be.
        .globl  straddle, bfi_move, globstore
straddle:                       // bytes 28 to 35 (ldur takes an unscaled offset)
        ldur    x2, [x0, #28]
        cbnz    x2, 1f
1:      ret

bfi_move:                       // bfi writes x0
        bfi     x0, x1, #5, #1
        ldr     x2, [x0]
        cbnz    x2, 1f
1:      ret

globstore:                      // x1 is secret
        adrp    x3, glob
        str     x1, [x3, :lo12:glob]
        ldr     x2, [x0, #8]
        cbnz    x2, 1f
1:      ret

        .data
glob:   .quad   0
