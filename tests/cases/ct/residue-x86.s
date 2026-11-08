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
