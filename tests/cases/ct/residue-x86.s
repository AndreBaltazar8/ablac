# residue_left spills its secret argument to the stack and returns; residue_wiped does the same and clears the slot.
.text
.globl residue_left
residue_left:
 pushq %rbp
 movq %rsp,%rbp
 subq $16,%rsp
 movq %rdi,-8(%rbp)
 movq -8(%rbp),%rax
 addq $16,%rsp
 popq %rbp
 retq
.globl residue_wiped
residue_wiped:
 pushq %rbp
 movq %rsp,%rbp
 subq $16,%rsp
 movq %rdi,-8(%rbp)
 movq -8(%rbp),%rax
 movq $0,-8(%rbp)
 addq $16,%rsp
 popq %rbp
 retq
# A callee that uses 200 bytes of frame and spills a secret into it; the entries below call it with the secret,
# with no wipe, a wipe of 128 bytes (short of its depth) and a wipe of 512 bytes (reaching it).
.globl residue_callee
.hidden residue_callee
residue_callee:
 subq $200,%rsp
 movq %rdi,(%rsp)
 movq %rdi,8(%rsp)
 addq $200,%rsp
 retq
# The same with the secret in the second argument, for the control that sets rdi up for a wipe.
.globl residue_callee2
.hidden residue_callee2
residue_callee2:
 subq $200,%rsp
 movq %rsi,(%rsp)
 movq %rsi,8(%rsp)
 addq $200,%rsp
 retq
.globl residue_unwiped
residue_unwiped:
 subq $8,%rsp
 callq residue_callee
 addq $8,%rsp
 retq
.globl residue_short
residue_short:
 subq $8,%rsp
 callq residue_callee
 leaq -128(%rsp),%rdi
 movl $16,%ecx
 xorl %eax,%eax
 rep stosq
 addq $8,%rsp
 retq
.globl residue_covered
residue_covered:
 subq $8,%rsp
 callq residue_callee
 leaq -512(%rsp),%rdi
 movl $64,%ecx
 xorl %eax,%eax
 rep stosq
 addq $8,%rsp
 retq
# residue_above wipes 560 bytes from 512 below rsp: 48 of them are the entry's own live frame.
.globl residue_above
residue_above:
 subq $8,%rsp
 callq residue_callee
 leaq -512(%rsp),%rdi
 movl $70,%ecx
 xorl %eax,%eax
 rep stosq
 addq $8,%rsp
 retq
# residue_pushed pushes twice after the call, so the wipe is taken 16 bytes lower and misses the top of the callee's frames.
.globl residue_pushed
residue_pushed:
 subq $8,%rsp
 callq residue_callee
 pushq %rax
 pushq %rax
 leaq -208(%rsp),%rdi
 movl $26,%ecx
 xorl %eax,%eax
 rep stosq
 popq %rax
 popq %rax
 addq $8,%rsp
 retq
# residue_clobbered sets up the wipe, then calls the callee, which may clobber rdi, rcx and rax: it is not a wipe.
.globl residue_clobbered
residue_clobbered:
 subq $8,%rsp
 leaq -512(%rsp),%rdi
 movl $64,%ecx
 xorl %eax,%eax
 callq residue_callee2
 rep stosq
 addq $8,%rsp
 retq
# residue_wipe is the shape of ctScrubStack: a function that wipes the 512 bytes below itself. Called after the callee,
# it covers the callee's frames (residue_called); called under a condition it covers them on one path only
# (residue_conditional), and a short one (residue_wipe_short) stops before the depth (residue_called_short).
.globl residue_wipe
.hidden residue_wipe
residue_wipe:
 leaq -512(%rsp),%rdi
 movl $64,%ecx
 xorl %eax,%eax
 rep stosq
 retq
.globl residue_wipe_short
.hidden residue_wipe_short
residue_wipe_short:
 leaq -128(%rsp),%rdi
 movl $16,%ecx
 xorl %eax,%eax
 rep stosq
 retq
.globl residue_wipe_maybe
.hidden residue_wipe_maybe
residue_wipe_maybe:
 testq %rsi,%rsi
 je 1f
 leaq -512(%rsp),%rdi
 movl $64,%ecx
 xorl %eax,%eax
 rep stosq
1:
 retq
.globl residue_called
residue_called:
 subq $8,%rsp
 callq residue_callee
 callq residue_wipe
 addq $8,%rsp
 retq
.globl residue_called_short
residue_called_short:
 subq $8,%rsp
 callq residue_callee
 callq residue_wipe_short
 addq $8,%rsp
 retq
.globl residue_conditional
residue_conditional:
 subq $8,%rsp
 callq residue_callee
 callq residue_wipe_maybe
 addq $8,%rsp
 retq
# The --fast shape of ctScrubStack: it pushes the caller's rbp, then wipes the 512 bytes below that, so the wipe
# ends 8 bytes under its return address. Those 8 bytes hold what the push wrote: the caller's rbp, public in
# residue_frame_wiped (clean) and the secret in residue_frame_secret (the push puts it there: found).
.globl residue_wipe_frame
.hidden residue_wipe_frame
residue_wipe_frame:
 pushq %rbp
 movq %rsp,%rbp
 leaq -512(%rsp),%rdi
 movl $64,%ecx
 xorl %eax,%eax
 rep stosq
 popq %rbp
 retq
.globl residue_frame_wiped
residue_frame_wiped:
 pushq %rbp
 movq %rsp,%rbp
 callq residue_callee
 callq residue_wipe_frame
 popq %rbp
 retq
.globl residue_frame_secret
residue_frame_secret:
 pushq %rbp
 movq %rdi,%rbp
 callq residue_callee
 callq residue_wipe_frame
 xorl %ebp,%ebp
 popq %rbp
 retq
