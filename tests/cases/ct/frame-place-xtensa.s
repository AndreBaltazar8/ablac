// Frame slots an unoptimised Xtensa function reaches through a computed address (a7 is a1's copy; offsets above 1020
// need movi/addmi plus add). Argument 0 (a2) is secret, argument 1 (a4) a public pointer to secret memory. Specs `:0,@1`.
//   place_addmi:0,@1        a secret stored at a7+296 (movi 40, addmi +256) and branched on there: found
//   place_addmi_other:0,@1  the same store, then a branch on a7+40 (a public zero): clean (addmi's +256 is read)
//   place_reload_keeps:0,@1 a secret at a7+1284, then the register that addressed it reloaded with the heap pointer and
//                           a public zero stored through it; the branch on a7+1284 is found (the slot keeps its secret)
//   place_reload_heap:0,@1  a7+1284 public, the secret stored through the reloaded heap pointer: clean
	.macro	frame
	entry	a1, 2048
	mov.n	a7, a1
	movi	a9, 1288
	add.n	a9, a7, a9
	s32i.n	a4, a9, 0
	movi	a9, 0
	s32i	a9, a7, 40
	.endm

	.section	.text.place_addmi,"ax",@progbits
	.align	4
	.global	place_addmi
	.type	place_addmi,@function
place_addmi:
	frame
	movi	a8, 40
	addmi	a8, a8, 256
	add.n	a8, a7, a8
	s32i.n	a2, a8, 0
	movi	a10, 296
	add.n	a10, a7, a10
	l32i.n	a11, a10, 0
	beqz	a11, 1f
1:
	retw.n
	.size	place_addmi, .-place_addmi

	.section	.text.place_addmi_other,"ax",@progbits
	.align	4
	.global	place_addmi_other
	.type	place_addmi_other,@function
place_addmi_other:
	frame
	movi	a8, 40
	addmi	a8, a8, 256
	add.n	a8, a7, a8
	s32i.n	a2, a8, 0
	l32i	a11, a7, 40
	beqz	a11, 1f
1:
	retw.n
	.size	place_addmi_other, .-place_addmi_other

	.section	.text.place_reload_keeps,"ax",@progbits
	.align	4
	.global	place_reload_keeps
	.type	place_reload_keeps,@function
place_reload_keeps:
	frame
	movi	a8, 1284
	add.n	a8, a7, a8
	s32i.n	a2, a8, 0
	movi	a9, 1288
	add.n	a9, a7, a9
	l32i.n	a8, a9, 0
	movi	a10, 0
	s32i.n	a10, a8, 0
	movi	a12, 1284
	add.n	a12, a7, a12
	l32i.n	a11, a12, 0
	beqz	a11, 1f
1:
	retw.n
	.size	place_reload_keeps, .-place_reload_keeps

	.section	.text.place_reload_heap,"ax",@progbits
	.align	4
	.global	place_reload_heap
	.type	place_reload_heap,@function
place_reload_heap:
	frame
	movi	a8, 1284
	add.n	a8, a7, a8
	movi	a10, 0
	s32i.n	a10, a8, 0
	movi	a9, 1288
	add.n	a9, a7, a9
	l32i.n	a8, a9, 0
	s32i.n	a2, a8, 0
	movi	a12, 1284
	add.n	a12, a7, a12
	l32i.n	a11, a12, 0
	beqz	a11, 1f
1:
	retw.n
	.size	place_reload_heap, .-place_reload_heap
