// Xtensa controls for the residue read (windowed ABI; a1 is the stack pointer, a function's frame is its `entry a1, N`
// and lies under its caller's a1; a window overflow keeps a frame's a0-a3 in the 16 bytes under its callee's a1 and its
// a4-a7 in the 16 above those, at the bottom of its caller's callee area). Specs (argument 0 is a2, secret):
//   residue_left:0        stores its secret in its own frame and returns: found
//   residue_wiped:0       the same, then stores zero over it: clean
//   residue_unwiped:0     gives the secret to residue_callee (a 64-byte frame it spills it into), no wipe: found
//   residue_short:0       the same, then a wipe of 16 bytes (short of the callee's depth) and the tail: found
//   residue_covered:0     the same, then the 512-byte wipe and the tail: clean
//   residue_no_tail:0     the 512-byte wipe without the tail: the 32 bytes the wipe can't reach stay: found
//   residue_before:0      the wipe and tail first, then the callee: found
//   residue_fake:0        a wipe that stores a2 (not zero) and isn't the exact loop: found
//   residue_kept:0        keeps the secret in a3 over a call of a public callee, whose save area takes it: found
//   residue_kept_wiped:0  the same, then the wipe and the tail: clean
//   residue_secret_tail:0 a tail that writes the secret under a1: found
//   residue_covered48:0   the 512-byte wipe from a function with a 48-byte frame, then the tail: the tail reaches only
//                         32 bytes, so 16 under the wipe's frame stay (the wipe needs a frame of at most 32): found
//   residue_unbounded:0   a wipe without the stack limit (it would cross the stack's end on a small task): found
//   residue_tail_deep:0   a store under a1 deeper than the 16 bytes under the wipe's frame: refused
//   residue_tail_first:0  the tail before any call (no stack is guaranteed under a1 yet): refused
//   residue_constant:0    a wipe that asks for the limit and then sets it to a constant of its own (a wipe that never
//                         wipes): found
// The wipes ask .Labla.ct.stack.low for the stack limit, as the real one does (which asks the image's
// abla_ct_stack_low); read with --no-stack-low (an image without it, where the wipe does nothing), residue_covered is
// found too.
	.text

	.section	.text.residue_callee,"ax",@progbits
	.align	4
	.global	residue_callee
	.type	residue_callee,@function
residue_callee:
	entry	a1, 64
	s32i	a2, a1, 0
	s32i	a2, a1, 4
	retw.n
	.size	residue_callee, .-residue_callee

	.section	.text.residue_public,"ax",@progbits
	.align	4
	.global	residue_public
	.type	residue_public,@function
residue_public:
	entry	a1, 32
	movi	a2, 7
	retw.n
	.size	residue_public, .-residue_public

	.macro	wipe words, store=a9, constant=0
	call8	.Labla.ct.stack.low
	.if	\constant
	movi	a12, -1
	.else
	mov.n	a12, a10
	.endif
	addi	a8, a1, -16
	movi	a9, 0
	movi	a10, \words
	beqz	a12, 2f
	bgeu	a12, a8, 2f
	sub	a11, a8, a12
	srli	a11, a11, 2
	beqz	a11, 2f
	bgeu	a11, a10, 1f
	mov.n	a10, a11
1:
	addi	a8, a8, -4
	s32i	\store, a8, 0
	addi	a10, a10, -1
	bnez	a10, 1b
2:
	movi	a8, 0
	retw.n
	.endm

	.section	.text..Labla.ct.stack.low,"ax",@progbits
	.align	4
.Labla.ct.stack.low:
	entry	a1, 32
	movi	a2, 4096
	retw.n

	.section	.text.residue_wipe,"ax",@progbits
	.align	4
	.global	residue_wipe
	.type	residue_wipe,@function
residue_wipe:
	entry	a1, 32
	wipe	128
	.size	residue_wipe, .-residue_wipe

	.section	.text.residue_wipe_short,"ax",@progbits
	.align	4
	.global	residue_wipe_short
	.type	residue_wipe_short,@function
residue_wipe_short:
	entry	a1, 32
	wipe	4
	.size	residue_wipe_short, .-residue_wipe_short

	.section	.text.residue_wipe_fake,"ax",@progbits
	.align	4
	.global	residue_wipe_fake
	.type	residue_wipe_fake,@function
residue_wipe_fake:
	entry	a1, 32
	wipe	128, a2
	.size	residue_wipe_fake, .-residue_wipe_fake

	.section	.text.residue_wipe48,"ax",@progbits
	.align	4
	.global	residue_wipe48
	.type	residue_wipe48,@function
residue_wipe48:
	entry	a1, 48
	wipe	128
	.size	residue_wipe48, .-residue_wipe48

	.section	.text.residue_wipe_constant,"ax",@progbits
	.align	4
	.global	residue_wipe_constant
	.type	residue_wipe_constant,@function
residue_wipe_constant:
	entry	a1, 32
	wipe	128, a9, 1
	.size	residue_wipe_constant, .-residue_wipe_constant

	.section	.text.residue_wipe_unbounded,"ax",@progbits
	.align	4
	.global	residue_wipe_unbounded
	.type	residue_wipe_unbounded,@function
residue_wipe_unbounded:
	entry	a1, 32
	addi	a8, a1, -16
	movi	a9, 0
	movi	a10, 128
1:
	addi	a8, a8, -4
	s32i	a9, a8, 0
	addi	a10, a10, -1
	bnez	a10, 1b
	movi	a8, 0
	retw.n
	.size	residue_wipe_unbounded, .-residue_wipe_unbounded

	.macro	tail
	addi	a9, a1, -48
	movi	a8, 0
	s32i	a8, a9, 0
	s32i	a8, a9, 4
	s32i	a8, a9, 8
	s32i	a8, a9, 12
	s32i	a8, a9, 16
	s32i	a8, a9, 20
	s32i	a8, a9, 24
	s32i	a8, a9, 28
	movi	a9, 0
	.endm

	.section	.text.residue_left,"ax",@progbits
	.align	4
	.global	residue_left
	.type	residue_left,@function
residue_left:
	entry	a1, 32
	s32i	a2, a1, 0
	retw.n
	.size	residue_left, .-residue_left

	.section	.text.residue_wiped,"ax",@progbits
	.align	4
	.global	residue_wiped
	.type	residue_wiped,@function
residue_wiped:
	entry	a1, 32
	s32i	a2, a1, 0
	movi	a8, 0
	s32i	a8, a1, 0
	retw.n
	.size	residue_wiped, .-residue_wiped

	.section	.text.residue_unwiped,"ax",@progbits
	.align	4
	.global	residue_unwiped
	.type	residue_unwiped,@function
residue_unwiped:
	entry	a1, 32
	mov.n	a10, a2
	movi	a2, 0
	call8	residue_callee
	retw.n
	.size	residue_unwiped, .-residue_unwiped

	.section	.text.residue_short,"ax",@progbits
	.align	4
	.global	residue_short
	.type	residue_short,@function
residue_short:
	entry	a1, 32
	mov.n	a10, a2
	movi	a2, 0
	call8	residue_callee
	call8	residue_wipe_short
	tail
	retw.n
	.size	residue_short, .-residue_short

	.section	.text.residue_covered,"ax",@progbits
	.align	4
	.global	residue_covered
	.type	residue_covered,@function
residue_covered:
	entry	a1, 32
	mov.n	a10, a2
	movi	a2, 0
	call8	residue_callee
	call8	residue_wipe
	tail
	retw.n
	.size	residue_covered, .-residue_covered

	.section	.text.residue_no_tail,"ax",@progbits
	.align	4
	.global	residue_no_tail
	.type	residue_no_tail,@function
residue_no_tail:
	entry	a1, 32
	mov.n	a10, a2
	movi	a2, 0
	call8	residue_callee
	call8	residue_wipe
	retw.n
	.size	residue_no_tail, .-residue_no_tail

	.section	.text.residue_before,"ax",@progbits
	.align	4
	.global	residue_before
	.type	residue_before,@function
residue_before:
	entry	a1, 32
	call8	residue_wipe
	tail
	mov.n	a10, a2
	movi	a2, 0
	call8	residue_callee
	retw.n
	.size	residue_before, .-residue_before

	.section	.text.residue_fake,"ax",@progbits
	.align	4
	.global	residue_fake
	.type	residue_fake,@function
residue_fake:
	entry	a1, 32
	mov.n	a10, a2
	movi	a2, 0
	call8	residue_callee
	call8	residue_wipe_fake
	tail
	retw.n
	.size	residue_fake, .-residue_fake

	.section	.text.residue_kept,"ax",@progbits
	.align	4
	.global	residue_kept
	.type	residue_kept,@function
residue_kept:
	entry	a1, 32
	mov.n	a3, a2
	movi	a2, 0
	call8	residue_public
	movi	a3, 0
	retw.n
	.size	residue_kept, .-residue_kept

	.section	.text.residue_kept_wiped,"ax",@progbits
	.align	4
	.global	residue_kept_wiped
	.type	residue_kept_wiped,@function
residue_kept_wiped:
	entry	a1, 32
	mov.n	a3, a2
	movi	a2, 0
	call8	residue_public
	movi	a3, 0
	call8	residue_wipe
	tail
	retw.n
	.size	residue_kept_wiped, .-residue_kept_wiped

	.section	.text.residue_secret_tail,"ax",@progbits
	.align	4
	.global	residue_secret_tail
	.type	residue_secret_tail,@function
residue_secret_tail:
	entry	a1, 32
	call8	residue_public
	addi	a9, a1, -48
	s32i	a2, a9, 0
	movi	a2, 0
	retw.n
	.size	residue_secret_tail, .-residue_secret_tail

	.section	.text.residue_covered48,"ax",@progbits
	.align	4
	.global	residue_covered48
	.type	residue_covered48,@function
residue_covered48:
	entry	a1, 32
	mov.n	a10, a2
	movi	a2, 0
	call8	residue_callee
	call8	residue_wipe48
	tail
	retw.n
	.size	residue_covered48, .-residue_covered48

	.section	.text.residue_unbounded,"ax",@progbits
	.align	4
	.global	residue_unbounded
	.type	residue_unbounded,@function
residue_unbounded:
	entry	a1, 32
	mov.n	a10, a2
	movi	a2, 0
	call8	residue_callee
	call8	residue_wipe_unbounded
	tail
	retw.n
	.size	residue_unbounded, .-residue_unbounded

	.section	.text.residue_tail_deep,"ax",@progbits
	.align	4
	.global	residue_tail_deep
	.type	residue_tail_deep,@function
residue_tail_deep:
	entry	a1, 32
	mov.n	a10, a2
	movi	a2, 0
	call8	residue_callee
	call8	residue_wipe
	tail
	addi	a9, a1, -96
	movi	a8, 0
	s32i	a8, a9, 0
	retw.n
	.size	residue_tail_deep, .-residue_tail_deep

	.section	.text.residue_tail_first,"ax",@progbits
	.align	4
	.global	residue_tail_first
	.type	residue_tail_first,@function
residue_tail_first:
	entry	a1, 32
	tail
	retw.n
	.size	residue_tail_first, .-residue_tail_first

	.section	.text.residue_constant,"ax",@progbits
	.align	4
	.global	residue_constant
	.type	residue_constant,@function
residue_constant:
	entry	a1, 32
	mov.n	a10, a2
	movi	a2, 0
	call8	residue_callee
	call8	residue_wipe_constant
	tail
	retw.n
	.size	residue_constant, .-residue_constant
