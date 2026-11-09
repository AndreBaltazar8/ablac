// Calls between functions of one AArch64 object, for the checker's --follow-calls: x0 to x7 and v0 to v7 carry the
// arguments, x0, x1 and v0 the results. Specs (argument 0 secret, 1 secret, @0 a pointer to secrets):
//   follow_clean:0       passes x0 to a callee that only adds to it and returns it
//   follow_branch:0      passes it to a callee that branches on it: found, "in callee_branch"
//   follow_stale:0       x1 is secret but the callee reads only x0 (stale argument registers don't count)
//   follow_result:0      what the callee returns in x0 is secret: the caller then branches on it
//   follow_public:0      the callee returns a constant, so the caller's branch on x0 afterwards is public
//   follow_clobber:0     the secret in x9 does not survive the call (caller-saved), the branch afterwards is public
//   follow_saved:0       the secret in x19 does survive it: the branch afterwards is found
//   follow_stack:0       the callee writes the secret through a stack address the caller made: reading the slot is secret
//   follow_tail:0        a tail call to a callee that branches on x0: found
//   follow_recursive:0   a call into itself: refused
//   follow_indirect:0    blr: refused
	.text
	.globl callee_add
	.type callee_add,@function
callee_add:
	add	x0, x0, #1
	ret
	.size callee_add, .-callee_add

	.globl callee_branch
	.type callee_branch,@function
callee_branch:
	cbz	x0, 1f
	mov	x0, #1
	ret
1:	mov	x0, #2
	ret
	.size callee_branch, .-callee_branch

	.globl callee_constant
	.type callee_constant,@function
callee_constant:
	mov	x0, #7
	ret
	.size callee_constant, .-callee_constant

	.globl callee_store
	.type callee_store,@function
callee_store:
	str	x0, [x1]
	ret
	.size callee_store, .-callee_store

	.globl follow_clean
	.type follow_clean,@function
follow_clean:
	stp	x29, x30, [sp, #-16]!
	bl	callee_add
	ldp	x29, x30, [sp], #16
	ret
	.size follow_clean, .-follow_clean

	.globl follow_branch
	.type follow_branch,@function
follow_branch:
	stp	x29, x30, [sp, #-16]!
	bl	callee_branch
	ldp	x29, x30, [sp], #16
	ret
	.size follow_branch, .-follow_branch

	.globl follow_stale
	.type follow_stale,@function
follow_stale:
	stp	x29, x30, [sp, #-16]!
	mov	x1, x0
	mov	x0, #3
	bl	callee_branch
	ldp	x29, x30, [sp], #16
	ret
	.size follow_stale, .-follow_stale

	.globl follow_result
	.type follow_result,@function
follow_result:
	stp	x29, x30, [sp, #-16]!
	bl	callee_add
	cbz	x0, 1f
	mov	x0, #1
1:	ldp	x29, x30, [sp], #16
	ret
	.size follow_result, .-follow_result

	.globl follow_public
	.type follow_public,@function
follow_public:
	stp	x29, x30, [sp, #-16]!
	bl	callee_constant
	cbz	x0, 1f
	mov	x0, #1
1:	ldp	x29, x30, [sp], #16
	ret
	.size follow_public, .-follow_public

	.globl follow_clobber
	.type follow_clobber,@function
follow_clobber:
	stp	x29, x30, [sp, #-16]!
	mov	x9, x0
	bl	callee_constant
	cbz	x9, 1f
	mov	x0, #1
1:	ldp	x29, x30, [sp], #16
	ret
	.size follow_clobber, .-follow_clobber

	.globl follow_saved
	.type follow_saved,@function
follow_saved:
	stp	x29, x30, [sp, #-32]!
	str	x19, [sp, #16]
	mov	x19, x0
	bl	callee_constant
	cbz	x19, 1f
	mov	x0, #1
1:	ldr	x19, [sp, #16]
	ldp	x29, x30, [sp], #32
	ret
	.size follow_saved, .-follow_saved

	.globl follow_stack
	.type follow_stack,@function
follow_stack:
	stp	x29, x30, [sp, #-32]!
	add	x1, sp, #16
	bl	callee_store
	ldr	x2, [sp, #16]
	cbz	x2, 1f
	mov	x0, #1
1:	ldp	x29, x30, [sp], #32
	ret
	.size follow_stack, .-follow_stack

	.globl follow_tail
	.type follow_tail,@function
follow_tail:
	b	callee_branch
	.size follow_tail, .-follow_tail

	.globl follow_recursive
	.type follow_recursive,@function
follow_recursive:
	stp	x29, x30, [sp, #-16]!
	bl	follow_recursive
	ldp	x29, x30, [sp], #16
	ret
	.size follow_recursive, .-follow_recursive

	.globl follow_indirect
	.type follow_indirect,@function
follow_indirect:
	stp	x29, x30, [sp, #-16]!
	adrp	x2, callee_add
	add	x2, x2, :lo12:callee_add
	blr	x2
	ldp	x29, x30, [sp], #16
	ret
	.size follow_indirect, .-follow_indirect

// A frame reached through sp and through x29 (x29 = sp after the prologue): the secret is stored at sp+16.
//   alias_public:0   a public index stored at sp+8 and loaded through x29+8 is used as an address: clean
//   alias_secret:0   the secret slot loaded through x29+16 is used as an address: found
	.globl alias_public
	.type alias_public,@function
alias_public:
	stp	x29, x30, [sp, #-32]!
	mov	x29, sp
	str	x0, [sp, #16]
	mov	x2, #3
	str	x2, [sp, #8]
	ldr	x3, [x29, #8]
	ldrb	w0, [x1, x3]
	ldp	x29, x30, [sp], #32
	ret
	.size alias_public, .-alias_public

	.globl alias_secret
	.type alias_secret,@function
alias_secret:
	stp	x29, x30, [sp, #-32]!
	mov	x29, sp
	str	x0, [sp, #16]
	ldr	x3, [x29, #16]
	ldrb	w0, [x1, x3]
	ldp	x29, x30, [sp], #32
	ret
	.size alias_secret, .-alias_secret
