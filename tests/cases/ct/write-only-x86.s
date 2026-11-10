# Controls for a write-only pointer (`@0!`): wipe_only zeroes the rdi[0..rsi) bytes with stores alone (clean);
# wipe_reads loads each byte before storing zero over it, as a drop that compares what it wipes would (found).
.text
.globl wipe_only
wipe_only:
 xorl %eax,%eax
 testq %rsi,%rsi
 je 2f
1:
 movb $0,(%rdi,%rax)
 incq %rax
 cmpq %rsi,%rax
 jne 1b
2:
 retq
.globl wipe_reads
wipe_reads:
 xorl %eax,%eax
 testq %rsi,%rsi
 je 2f
1:
 movzbl (%rdi,%rax),%ecx
 movb $0,(%rdi,%rax)
 incq %rax
 cmpq %rsi,%rax
 jne 1b
2:
 retq
# wipe_xadd stores zero with a lock xadd, which also reads the old byte into al (found).
.globl wipe_xadd
wipe_xadd:
 xorl %eax,%eax
 lock xaddb %al,(%rdi)
 retq
