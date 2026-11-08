# Controls for the checker's division and panic rules (tools/test-ct.sh division_read).
# div_public_rdx: rdx holds a secret, then cqto overwrites it from a public rax: a division of public values.
# div_secret_rax: the same with a secret rax, which cqto copies into rdx: a division of a secret, found.
# panic_public / panic_secret: a call to the panic with and without a secret in its one argument.
# panic_branch: a panic reached by a branch on a secret, which is the leak, not the panic.
.text
.globl abla_platform_panic
abla_platform_panic:
 ud2
.globl div_public_rdx
div_public_rdx:
 movq (%rdi), %rdx
 movq %rsi, %rax
 cqto
 idivq %rcx
 retq
.globl div_secret_rax
div_secret_rax:
 movq (%rdi), %rax
 cqto
 idivq %rcx
 retq
.globl panic_public
panic_public:
 subq $8, %rsp
 xorl %edi, %edi
 callq abla_platform_panic
.globl panic_secret
panic_secret:
 subq $8, %rsp
 movq (%rdi), %rdi
 callq abla_platform_panic
.globl panic_branch
panic_branch:
 subq $8, %rsp
 cmpq $0, (%rdi)
 je 1f
 xorl %edi, %edi
 callq abla_platform_panic
1:
 addq $8, %rsp
 retq
