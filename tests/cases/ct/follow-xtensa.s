// Calls between functions of one Xtensa object (windowed ABI: call8 rotates the window by 8, so the callee's a2 is our
// a10, and its result comes back in our a10). The checker reads the relocation that names the callee. Specs (argument
// 0 is a2, secret unless said):
//   follow_clean:0        passes a2 to a callee that adds one and returns it
//   follow_branch:0       the callee branches on it: found, "in callee_branch"
//   follow_stale:1        a3 is secret, the callee reads only a2: clean
//   follow_result:0       the caller branches on the result of callee_add: found
//   follow_public:0       the caller branches on the result of callee_constant: clean
//   follow_clobber:0      the secret in our a12 is in the callee's window and dead after the call: clean
//   follow_saved:0        the secret in our a4 (below the window) survives the call: found
//   follow_stack:0        the callee writes the secret through a frame address: reading the slot is secret: found
//   follow_recursive:0    a call into itself: refused
//   follow_indirect:0     callx8: refused
	.text
	.align	4
	.global	callee_add
	.type	callee_add,@function
callee_add:
	entry	a1, 16
	addi	a2, a2, 1
	retw.n
	.size	callee_add, .-callee_add

	.align	4
	.global	callee_branch
	.type	callee_branch,@function
callee_branch:
	entry	a1, 16
	beqz	a2, 1f
	movi.n	a2, 1
	retw.n
1:	movi.n	a2, 2
	retw.n
	.size	callee_branch, .-callee_branch

	.align	4
	.global	callee_constant
	.type	callee_constant,@function
callee_constant:
	entry	a1, 16
	movi.n	a2, 7
	retw.n
	.size	callee_constant, .-callee_constant

	.align	4
	.global	callee_ignore
	.type	callee_ignore,@function
callee_ignore:
	entry	a1, 16
	retw.n
	.size	callee_ignore, .-callee_ignore

	.align	4
	.global	callee_store
	.type	callee_store,@function
callee_store:
	entry	a1, 16
	s32i.n	a2, a3, 0
	retw.n
	.size	callee_store, .-callee_store

	.align	4
	.global	follow_clean
	.type	follow_clean,@function
follow_clean:
	entry	a1, 32
	mov.n	a10, a2
	call8	callee_add
	mov.n	a2, a10
	retw.n
	.size	follow_clean, .-follow_clean

	.align	4
	.global	follow_branch
	.type	follow_branch,@function
follow_branch:
	entry	a1, 32
	mov.n	a10, a2
	call8	callee_branch
	mov.n	a2, a10
	retw.n
	.size	follow_branch, .-follow_branch

	.align	4
	.global	follow_stale
	.type	follow_stale,@function
follow_stale:
	entry	a1, 32
	mov.n	a11, a3
	movi.n	a10, 3
	call8	callee_ignore
	beqz	a10, 1f
	movi.n	a2, 1
1:	retw.n
	.size	follow_stale, .-follow_stale

	.align	4
	.global	follow_result
	.type	follow_result,@function
follow_result:
	entry	a1, 32
	mov.n	a10, a2
	call8	callee_add
	beqz	a10, 1f
	movi.n	a2, 1
1:	retw.n
	.size	follow_result, .-follow_result

	.align	4
	.global	follow_public
	.type	follow_public,@function
follow_public:
	entry	a1, 32
	mov.n	a10, a2
	call8	callee_constant
	beqz	a10, 1f
	movi.n	a2, 1
1:	retw.n
	.size	follow_public, .-follow_public

	.align	4
	.global	follow_clobber
	.type	follow_clobber,@function
follow_clobber:
	entry	a1, 32
	mov.n	a12, a2
	call8	callee_constant
	beqz	a12, 1f
	movi.n	a2, 1
1:	retw.n
	.size	follow_clobber, .-follow_clobber

	.align	4
	.global	follow_saved
	.type	follow_saved,@function
follow_saved:
	entry	a1, 32
	mov.n	a4, a2
	call8	callee_constant
	beqz	a4, 1f
	movi.n	a2, 1
1:	retw.n
	.size	follow_saved, .-follow_saved

	.align	4
	.global	follow_stack
	.type	follow_stack,@function
follow_stack:
	entry	a1, 32
	mov.n	a10, a2
	addi	a11, a1, 8
	call8	callee_store
	l32i.n	a3, a1, 8
	beqz	a3, 1f
	movi.n	a2, 1
1:	retw.n
	.size	follow_stack, .-follow_stack

	.align	4
	.global	follow_recursive
	.type	follow_recursive,@function
follow_recursive:
	entry	a1, 32
	mov.n	a10, a2
	call8	follow_recursive
	retw.n
	.size	follow_recursive, .-follow_recursive

	.align	4
	.global	follow_indirect
	.type	follow_indirect,@function
follow_indirect:
	entry	a1, 32
	mov.n	a10, a2
	movi.n	a8, 0
	callx8	a8
	retw.n
	.size	follow_indirect, .-follow_indirect
