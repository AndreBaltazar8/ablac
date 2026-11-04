.text
.globl frame_leak
frame_leak:
 mov x29,x0
 ldr w1,[x29]
 cbz w1,done
 nop
done:
 ret
