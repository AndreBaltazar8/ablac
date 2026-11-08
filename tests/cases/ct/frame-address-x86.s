# A callee stores its secret argument through the address of the caller's own frame; the caller then branches on that
# slot. caller_lea passes the address with lea, caller_mov with mov from rsp; both must be found.
# caller_spill and caller_push lose the address through memory and the stack; caller_calleesaved keeps it in rbx
# across two calls. caller_stackarg passes the secret in a stack slot to a callee that branches on it.
.text
.globl callee
.hidden callee
callee:
 movq %rsi,(%rdi)
 retq
.globl caller_lea
caller_lea:
 subq $24,%rsp
 movq %rdi,%rsi
 leaq 8(%rsp),%rdi
 callq callee
 cmpq $0,8(%rsp)
 je 1f
 movb $1,0(%rdx)
1:
 addq $24,%rsp
 retq
.globl caller_mov
caller_mov:
 subq $24,%rsp
 movq %rdi,%rsi
 movq %rsp,%rdi
 callq callee
 cmpq $0,(%rsp)
 je 1f
 movb $1,0(%rdx)
1:
 addq $24,%rsp
 retq
.globl callee_stack
.hidden callee_stack
callee_stack:
 movq 8(%rsp),%rax
 cmpq $0,%rax
 je 1f
 movb $1,0(%rdi)
1:
 retq
.globl caller_stackarg
caller_stackarg:
 pushq %rdi
 callq callee_stack
 popq %rdi
 retq
.globl caller_spill
caller_spill:
 subq $40,%rsp
 movq %rdi,%rsi
 leaq 8(%rsp),%rax
 movq %rax,24(%rsp)
 movq 24(%rsp),%rdi
 callq callee
 cmpq $0,8(%rsp)
 je 1f
 movb $1,0(%rdx)
1:
 addq $40,%rsp
 retq
.globl caller_push
caller_push:
 subq $40,%rsp
 movq %rdi,%rsi
 leaq 8(%rsp),%rax
 pushq %rax
 popq %rdi
 callq callee
 cmpq $0,8(%rsp)
 je 1f
 movb $1,0(%rdx)
1:
 addq $40,%rsp
 retq
.globl caller_calleesaved
caller_calleesaved:
 pushq %rbx
 subq $32,%rsp
 movq %rdi,%rsi
 leaq 8(%rsp),%rbx
 movq %rbx,%rdi
 callq callee
 callq callee
 cmpq $0,8(%rsp)
 je 1f
 movb $1,0(%rdx)
1:
 addq $32,%rsp
 popq %rbx
 retq
