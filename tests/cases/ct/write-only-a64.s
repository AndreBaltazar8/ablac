// Controls for a write-only pointer (`@0!`) on AArch64: wipe_only stores zero over x0[0..x1) (clean); wipe_reads
// loads each byte first (found).
.text
.globl wipe_only
wipe_only:
 cbz x1, 2f
 mov x2, #0
1:
 strb wzr, [x0, x2]
 add x2, x2, #1
 cmp x2, x1
 b.ne 1b
2:
 ret
.globl wipe_reads
wipe_reads:
 cbz x1, 2f
 mov x2, #0
1:
 ldrb w3, [x0, x2]
 strb wzr, [x0, x2]
 add x2, x2, #1
 cmp x2, x1
 b.ne 1b
2:
 ret
