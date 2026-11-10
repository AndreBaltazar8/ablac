# Frame views (what an unoptimised build does: box a value in a slot, a public type tag at 0 and the secret payload at
# 8, and pass the slot's address). Each caller boxes its secret argument at -0x18(%rbp) and calls one callee with the
# box's address. Clean: view_tag reads the tag through the address and the caller branches on what it returns and on
# the tag slot; view_spill does the same after the callee spills the address to its own frame and reloads it. Found:
# view_payload (the callee branches on the payload), view_result (the callee writes the secret over the tag, the caller
# branches on the tag slot), view_escape (the callee returns the address, and the caller writes the secret through what
# it got back before branching on the tag slot),
# view_above (the callee writes the secret into the caller's frame through its own rbp, above its return address),
# view_stash (the callee stores the address in a global, so a later write through it can't be seen), view_passon (the
# callee passes the address on to one that writes the secret over the tag), view_indirect (the callee calls through a
# register: refused), view_far_read and view_far_write (a secret 72 bytes behind the address, past the 64-byte view:
# read and branched on, or written there, then the caller branches on its slot), view_secret_tag (the box's tag is the
# secret itself), view_stos_above (a callee's rep stos of the secret into its caller's frame, above its own stack
# pointer, after the caller made a frame address and dropped it). And with no call:
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

.globl pass_on
.hidden pass_on
pass_on:
 pushq %rbp
 movq %rsp,%rbp
 callq result_secret
 popq %rbp
 retq
.globl call_indirect
.hidden call_indirect
call_indirect:
 pushq %rbp
 movq %rsp,%rbp
 leaq tag_of(%rip),%rax
 callq *%rax
 popq %rbp
 retq
.globl far_read
.hidden far_read
far_read:
 pushq %rbp
 movq %rsp,%rbp
 movl $2,%eax
 cmpq $0,72(%rdi)
 je 1f
 movl $2,%eax
1:
 popq %rbp
 retq
.globl far_write
.hidden far_write
far_write:
 pushq %rbp
 movq %rsp,%rbp
 movq %rsi,72(%rdi)
 movl $2,%eax
 popq %rbp
 retq
.globl stos_above
.hidden stos_above
stos_above:
 leaq 0x40(%rsp),%rdi
 movq %rsi,%rax
 movl $1,%ecx
 rep stosq
 movl $2,%eax
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

.globl view_passon
view_passon:
 box pass_on
.globl view_indirect
view_indirect:
 box call_indirect
.globl view_far_read
view_far_read:
 box far_read
.globl view_secret_tag
view_secret_tag:
 pushq %rbp
 movq %rsp,%rbp
 subq $32,%rsp
 movl %edi,-0x18(%rbp)
 movl $0,-0x14(%rbp)
 movq %rdi,-0x10(%rbp)
 movq $0,-0x8(%rbp)
 leaq -0x18(%rbp),%rdi
 callq tag_of
 cmpl $2,%eax
 jne 9f
 addq $32,%rsp
 popq %rbp
 retq
9:
 ud2
.globl view_far_write
view_far_write:
 pushq %rbp
 movq %rsp,%rbp
 subq $128,%rsp
 movl $2,-0x58(%rbp)
 movl $0,-0x54(%rbp)
 movq %rdi,-0x50(%rbp)
 movq $0,-0x48(%rbp)
 movq $0,-0x10(%rbp)
 movq %rdi,%rsi
 leaq -0x58(%rbp),%rdi
 callq far_write
 cmpq $0,-0x10(%rbp)
 jne 9f
 addq $128,%rsp
 popq %rbp
 retq
9:
 ud2
.globl view_stos_above
view_stos_above:
 subq $0x48,%rsp
 movq %rdi,%rsi
 leaq 0x10(%rsp),%rcx
 xorl %ecx,%ecx
 callq stos_above
 cmpq $0,0x38(%rsp)
 jne 9f
 addq $0x48,%rsp
 retq
9:
 ud2

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
