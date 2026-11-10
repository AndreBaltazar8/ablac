// Hand-written controls for the header-public pointer (`%0`) on Xtensa; see header-x86.s. a2 holds the pointer, a4 (the
// second parameter's pair) is public unless the spec makes it secret (`%0,1`).
	.text
	.align	4
	.global	helper
	.type	helper,@function
helper:
	entry	a1, 16
	retw.n
	.size	helper, .-helper

	.align	4
	.global	hdr_branch
	.type	hdr_branch,@function
hdr_branch:
	entry	a1, 32
	l32i	a3, a2, 8
	bltui	a3, 16, 1f
1:	retw.n
	.size	hdr_branch, .-hdr_branch

	.align	4
	.global	hdr_loop
	.type	hdr_loop,@function
hdr_loop:
	entry	a1, 32
	l32i	a3, a2, 24
	l32i	a5, a2, 16
2:	bgeu	a3, a5, 3f
	addi	a3, a3, 1
	j	2b
3:	retw.n
	.size	hdr_loop, .-hdr_loop

	.align	4
	.global	payload_branch
	.type	payload_branch,@function
payload_branch:
	entry	a1, 32
	l32i	a3, a2, 32
	beqz	a3, 1f
1:	retw.n
	.size	payload_branch, .-payload_branch

	.align	4
	.global	payload_index
	.type	payload_index,@function
payload_index:
	entry	a1, 32
	l32i	a3, a2, 40
	add	a3, a2, a3
	l32i	a3, a3, 0
	beqz	a3, 1f
1:	retw.n
	.size	payload_index, .-payload_index

	.align	4
	.global	header_indexed
	.type	header_indexed,@function
header_indexed:
	entry	a1, 32
	add	a3, a2, a4
	l32i	a3, a3, 0
	beqz	a3, 1f
1:	retw.n
	.size	header_indexed, .-header_indexed

	.align	4
	.global	header_overwritten
	.type	header_overwritten,@function
header_overwritten:
	entry	a1, 32
	addi	a2, a2, 32
	l32i	a3, a2, 0
	beqz	a3, 1f
1:	retw.n
	.size	header_overwritten, .-header_overwritten

	.align	4
	.global	header_merge
	.type	header_merge,@function
header_merge:
	entry	a1, 32
	beqz	a4, 1f
	mov.n	a2, a6
1:	l32i	a3, a2, 8
	beqz	a3, 2f
2:	retw.n
	.size	header_merge, .-header_merge

	.align	4
	.global	header_call
	.type	header_call,@function
header_call:
	entry	a1, 32
	call8	helper
	l32i	a3, a2, 8
	beqz	a3, 1f
1:	retw.n
	.size	header_call, .-header_call

	.align	4
	.global	header_store_secret
	.type	header_store_secret,@function
header_store_secret:
	entry	a1, 32
	s32i	a4, a2, 8
	l32i	a3, a2, 8
	beqz	a3, 1f
1:	retw.n
	.size	header_store_secret, .-header_store_secret

	.align	4
	.global	header_store_other
	.type	header_store_other,@function
header_store_other:
	entry	a1, 32
	mov.n	a3, a2
	s32i	a4, a3, 8
	l32i	a5, a2, 8
	beqz	a5, 1f
1:	retw.n
	.size	header_store_other, .-header_store_other

	.align	4
	.global	header_offset
	.type	header_offset,@function
header_offset:
	entry	a1, 32
	l32i	a3, a2, 32
	beqz	a3, 1f
1:	retw.n
	.size	header_offset, .-header_offset

	.align	4
	.global	globstore
	.type	globstore,@function
globstore:
	entry	a1, 32
	l32r	a3, glob_address
	s32i	a4, a3, 0
	l32i	a5, a2, 8
	beqz	a5, 1f
1:	retw.n
	.size	globstore, .-globstore

	.literal_position
	.literal glob_address, glob
	.data
glob:	.long	0

# The crypto allocation entry: exported as abla_ct_allocate and called by that name. The size is the callee's first
# argument (a pair: call8 passes it in a10 and a11), the pointer comes back in a10, to secret memory (the block's own
# header sits below it).
	.text
	.align	4
	.global	abla_ct_allocate
	.type	abla_ct_allocate,@function
abla_ct_allocate:
	entry	a1, 16
	retw.n
	.size	abla_ct_allocate, .-abla_ct_allocate

	.align	4
	.global	alloc_fill
	.type	alloc_fill,@function
alloc_fill:
	entry	a1, 32
	mov.n	a6, a4
	movi.n	a10, 64
	movi.n	a11, 0
	call8	abla_ct_allocate
	s32i	a6, a10, 8
	retw.n
	.size	alloc_fill, .-alloc_fill

	.align	4
	.global	alloc_read
	.type	alloc_read,@function
alloc_read:
	entry	a1, 32
	movi.n	a10, 64
	movi.n	a11, 0
	call8	abla_ct_allocate
	l32i	a3, a10, 8
	beqz	a3, 1f
1:	retw.n
	.size	alloc_read, .-alloc_read

	.align	4
	.global	alloc_secret_size
	.type	alloc_secret_size,@function
alloc_secret_size:
	entry	a1, 32
	mov.n	a10, a2
	mov.n	a11, a3
	call8	abla_ct_allocate
	retw.n
	.size	alloc_secret_size, .-alloc_secret_size
