# AArch64 controls for the residue read. residue_left spills its secret argument to the stack and returns;
# residue_wiped clears the slot. residue_callee has 208 bytes of frame and spills the secret into it; the entries
# after it call it with the secret: with no wipe, with a wipe of 128 bytes (short of the frame) and of 512 (reaching it),
# and with the wipe called before the callee (it must come after).
.text
.globl residue_left
residue_left:
 stp x29, x30, [sp, #-32]!
 mov x29, sp
 str x0, [sp, #16]
 ldr x0, [sp, #16]
 ldp x29, x30, [sp], #32
 ret
.globl residue_wiped
residue_wiped:
 stp x29, x30, [sp, #-32]!
 mov x29, sp
 str x0, [sp, #16]
 ldr x0, [sp, #16]
 str xzr, [sp, #16]
 ldp x29, x30, [sp], #32
 ret
.globl residue_callee
.hidden residue_callee
residue_callee:
 sub sp, sp, #208
 str x0, [sp]
 str x0, [sp, #8]
 add sp, sp, #208
 ret
.globl scrub128
.hidden scrub128
scrub128:
 sub x9, sp, #128
 mov x10, sp
1:
 stp xzr, xzr, [x9], #16
 cmp x9, x10
 b.ne 1b
 ret
.globl scrub512
.hidden scrub512
scrub512:
 sub x9, sp, #512
 mov x10, sp
1:
 stp xzr, xzr, [x9], #16
 cmp x9, x10
 b.ne 1b
 ret
.globl residue_unwiped
residue_unwiped:
 stp x29, x30, [sp, #-16]!
 mov x29, sp
 bl residue_callee
 ldp x29, x30, [sp], #16
 ret
.globl residue_short
residue_short:
 stp x29, x30, [sp, #-16]!
 mov x29, sp
 bl residue_callee
 bl scrub128
 ldp x29, x30, [sp], #16
 ret
.globl residue_covered
residue_covered:
 stp x29, x30, [sp, #-16]!
 mov x29, sp
 bl residue_callee
 bl scrub512
 ldp x29, x30, [sp], #16
 ret
.globl residue_early
residue_early:
 stp x29, x30, [sp, #-16]!
 mov x29, sp
 mov x1, x0
 bl scrub512
 mov x0, x1
 bl residue_callee
 ldp x29, x30, [sp], #16
 ret
