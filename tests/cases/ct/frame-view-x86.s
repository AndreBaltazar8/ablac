# Frame views (what an unoptimised build does: box a value in a slot, a public type tag at 0 and the secret payload at
# 8, and pass the slot's address). Each caller boxes its secret argument at -0x18(%rbp) and calls one callee with the
# box's address. Clean: view_tag reads the tag through the address and the caller branches on what it returns and on
# the tag slot; view_spill does the same after the callee spills the address to its own frame and reloads it. Found:
# view_payload (the callee branches on the payload), view_result (the callee writes the secret over the tag, the caller
# branches on the tag slot), view_escape (the callee returns the address, and the caller writes the secret through what
# it got back before branching on the tag slot),
# view_above (the callee writes the secret into the caller's frame through its own rbp, above its return address),
# view_stash (the callee stores the address in a global, so a later write through it can't be seen). And with no call:
# self_write stores the secret through a register copy of its own slot's address (lea), then branches on the slot.
.text
.macro box callee
 pushq %rbp
 movq %rsp,%rbp
 subq $32,%rsp
 movl $2,-0x18(%rbp)
 movl $0,-0x14(%rbp)
 movq %rdi,-0x10(%rbp)
 movq $0,-0x8(%rbp)
 movq %rdi,%rsi
 leaq -0x18(%rbp),%rdi
 callq \callee
 cmpl $2,%eax
 jne 9f
 cmpl $2,-0x18(%rbp)
 jne 9f
 addq $32,%rsp
 popq %rbp
 retq
9:
 ud2
.endm

.globl tag_of
.hidden tag_of
tag_of:
 pushq %rbp
 movq %rsp,%rbp
 movl (%rdi),%eax
 popq %rbp
 retq
.globl tag_spill
.hidden tag_spill
tag_spill:
 pushq %rbp
 movq %rsp,%rbp
 subq $16,%rsp
 movq %rdi,-0x8(%rbp)
 movq -0x8(%rbp),%rcx
 movl (%rcx),%eax
 addq $16,%rsp
 popq %rbp
 retq
.globl payload_branch
.hidden payload_branch
payload_branch:
 pushq %rbp
 movq %rsp,%rbp
 movl $2,%eax
 cmpq $0,8(%rdi)
 je 1f
 movl $2,%eax
1:
 popq %rbp
 retq
.globl result_secret
.hidden result_secret
result_secret:
 pushq %rbp
 movq %rsp,%rbp
 movl %esi,(%rdi)
 movl $2,%eax
 popq %rbp
 retq
.globl escape_address
.hidden escape_address
escape_address:
 pushq %rbp
 movq %rsp,%rbp
 movq %rdi,%rax
 popq %rbp
 retq
.globl write_above
.hidden write_above
write_above:
 pushq %rbp
 movq %rsp,%rbp
 movq %rsi,-0x8(%rbp)
 movl %esi,16(%rbp)
 movl $2,%eax
 popq %rbp
 retq

.globl stash_address
.hidden stash_address
stash_address:
 pushq %rbp
 movq %rsp,%rbp
 movq %rdi,stash(%rip)
 movl $2,%eax
 popq %rbp
 retq

.globl view_tag
view_tag:
 box tag_of
.globl view_spill
view_spill:
 box tag_spill
.globl view_payload
view_payload:
 box payload_branch
.globl view_result
view_result:
 box result_secret
.globl view_escape
view_escape:
 pushq %rbp
 movq %rsp,%rbp
 subq $32,%rsp
 movl $2,-0x18(%rbp)
 movl $0,-0x14(%rbp)
 movq %rdi,-0x10(%rbp)
 movq $0,-0x8(%rbp)
 movq %rdi,%rsi
 leaq -0x18(%rbp),%rdi
 callq escape_address
 movq -0x10(%rbp),%rcx
 movl %ecx,(%rax)
 cmpl $2,-0x18(%rbp)
 jne 9f
 addq $32,%rsp
 popq %rbp
 retq
9:
 ud2
.globl view_above
view_above:
 box write_above
.globl view_stash
view_stash:
 box stash_address

.globl self_write
self_write:
 pushq %rbp
 movq %rsp,%rbp
 subq $32,%rsp
 movl $2,-0x18(%rbp)
 leaq -0x18(%rbp),%rax
 movl %edi,(%rax)
 cmpl $2,-0x18(%rbp)
 jne 9f
 addq $32,%rsp
 popq %rbp
 retq
9:
 ud2

.data
stash:
 .quad 0
