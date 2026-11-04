.text
.globl frame_leak
frame_leak:
 pushq %rbp
 movq %rdi,%rbp
 movl (%rbp),%eax
 testl %eax,%eax
 je .Ldone
 nop
.Ldone:
 popq %rbp
 retq
