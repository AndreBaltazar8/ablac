.text
.globl spill_leak
spill_leak:
 sub sp,sp,#16
 str x0,[sp]
 ldr x1,[sp]
 ldr w1,[x1]
 cbz w1,done
 nop
done:
 add sp,sp,#16
 ret
