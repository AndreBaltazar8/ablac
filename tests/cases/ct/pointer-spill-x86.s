.text
.globl spill_leak
spill_leak:
 movq %rdi,-8(%rsp)
 movq -8(%rsp),%rax
 movl (%rax),%eax
 testl %eax,%eax
 je .Ldone
 nop
.Ldone:
 retq
