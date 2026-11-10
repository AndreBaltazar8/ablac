# Hand-written controls for the header-public pointer (`%0`): the first 32 bytes of the object are public, the rest is
# secret. The clean entries read header words and branch on them; every other entry must be reported. Run by
# tools/test-ct.sh (header_read) with the spec `entry:%0` (and `entry:%0,1` where rsi is a secret).
        .text
        .globl  hdr_branch, hdr_loop, payload_branch, payload_index, header_indexed, header_overwritten
        .globl  header_merge, header_call, header_store_secret, header_store_other, header_offset, helper

helper: ret

hdr_branch:                     # the size word steers a branch
        cmpq    $16, 8(%rdi)
        jb      1f
1:      ret

hdr_loop:                       # a loop bounded by header words
        movq    24(%rdi), %rax
        movq    16(%rdi), %rcx
2:      cmpq    %rcx, %rax
        jae     3f
        incq    %rax
        jmp     2b
3:      ret

payload_branch:                 # the first payload word is secret
        cmpq    $0, 32(%rdi)
        jne     1f
1:      ret

payload_index:                  # a secret loaded from the payload used as an index
        movq    40(%rdi), %rax
        movq    (%rdi,%rax,8), %rcx
        ret

header_indexed:                 # a variable offset can reach the payload
        movq    (%rdi,%rsi), %rax
        cmpq    $0, %rax
        jne     1f
1:      ret

header_overwritten:             # the register is advanced past the header
        leaq    32(%rdi), %rdi
        cmpq    $0, (%rdi)
        jne     1f
1:      ret

header_merge:                   # the register is replaced on one path only
        testq   %rsi, %rsi
        je      1f
        movq    %rdx, %rdi
1:      cmpq    $0, 8(%rdi)
        jne     2f
2:      ret

header_call:                    # a call may return with another value in rdi
        callq   helper
        cmpq    $0, 8(%rdi)
        jne     1f
1:      ret

header_store_secret:            # rsi is secret: a header word written from it is not public afterwards
        movq    %rsi, 8(%rdi)
        cmpq    $0, 8(%rdi)
        jne     1f
1:      ret

header_store_other:             # the same through a copy of the pointer
        movq    %rdi, %rax
        movq    %rsi, 8(%rax)
        cmpq    $0, 8(%rdi)
        jne     1f
1:      ret

header_offset:                  # the first byte past the header
        cmpq    $0, 32(%rdi)
        jne     1f
1:      ret

# Reads that leave the header although they start in it, a string operation that advances rdi, and a store into static
# memory that the object may be.
        .globl  straddle8, straddle16, repstos, globstore
straddle8:                      # bytes 28 to 35
        movq    28(%rdi), %rax
        cmpq    $0, %rax
        jne     1f
1:      ret

straddle16:                     # bytes 24 to 39, as LLVM merges two words into one vector load
        movups  24(%rdi), %xmm0
        movhlps %xmm0, %xmm1
        movq    %xmm1, %rax
        cmpq    $0, %rax
        jne     1f
1:      ret

repstos:                        # rep stosb advances rdi past the header
        xorl    %eax, %eax
        movq    $40, %rcx
        rep stosb
        cmpq    $0, (%rdi)
        jne     1f
1:      ret

globstore:                      # rsi is secret: a store to static memory, which the object could be
        movq    %rsi, glob(%rip)
        cmpq    $0, 8(%rdi)
        jne     1f
1:      ret

        .data
glob:   .quad   0
