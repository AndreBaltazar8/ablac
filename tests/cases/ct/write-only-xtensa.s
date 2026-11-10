// Controls for a write-only pointer (`@0!`) on Xtensa: wipe_only stores zero over a2[0..a3) (clean); wipe_reads
// loads each byte first (found).
	.section	.text.wipe_only,"ax",@progbits
	.align	4
	.global	wipe_only
	.type	wipe_only,@function
wipe_only:
	entry	a1, 32
	movi	a8, 0
	beqz	a3, 2f
1:
	s8i	a8, a2, 0
	addi	a2, a2, 1
	addi	a3, a3, -1
	bnez	a3, 1b
2:
	retw.n
	.size	wipe_only, .-wipe_only

	.section	.text.wipe_reads,"ax",@progbits
	.align	4
	.global	wipe_reads
	.type	wipe_reads,@function
wipe_reads:
	entry	a1, 32
	movi	a8, 0
	beqz	a3, 2f
1:
	l8ui	a9, a2, 0
	s8i	a8, a2, 0
	addi	a2, a2, 1
	addi	a3, a3, -1
	bnez	a3, 1b
2:
	retw.n
	.size	wipe_reads, .-wipe_reads
