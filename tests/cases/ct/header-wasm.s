// Hand-written controls for the header-public pointer (`%0`) on Wasm; see header-x86.s. Parameter 0 is the pointer to
// the object (a linear-memory address), parameter 1 is public unless the spec makes it secret (`%0,1`).
	.text
	.functype	helper () -> ()

	.globl	helper
helper:
	.functype	helper () -> ()
	end_function

	.globl	hdr_branch
hdr_branch:
	.functype	hdr_branch (i32, i32) -> ()
	local.get	0
	i32.load	8
	i32.const	16
	i32.lt_u
	if
	end_if
	end_function

	.globl	hdr_loop
hdr_loop:
	.functype	hdr_loop (i32, i32) -> ()
	.local	i32
	local.get	0
	i32.load	24
	local.set	2
	block
	loop
	local.get	2
	local.get	0
	i32.load	16
	i32.ge_u
	br_if	1
	local.get	2
	i32.const	1
	i32.add
	local.set	2
	br	0
	end_loop
	end_block
	end_function

	.globl	payload_branch
payload_branch:
	.functype	payload_branch (i32, i32) -> ()
	local.get	0
	i32.load	32
	if
	end_if
	end_function

	.globl	payload_index
payload_index:
	.functype	payload_index (i32, i32) -> ()
	local.get	0
	local.get	0
	i32.load	40
	i32.add
	i32.load	0
	if
	end_if
	end_function

	.globl	header_indexed
header_indexed:
	.functype	header_indexed (i32, i32) -> ()
	local.get	0
	local.get	1
	i32.add
	i32.load	0
	if
	end_if
	end_function

	.globl	header_overwritten
header_overwritten:
	.functype	header_overwritten (i32, i32) -> ()
	local.get	0
	i32.const	32
	i32.add
	local.set	0
	local.get	0
	i32.load	0
	if
	end_if
	end_function

	.globl	header_merge
header_merge:
	.functype	header_merge (i32, i32) -> ()
	local.get	1
	if
	local.get	1
	local.set	0
	end_if
	local.get	0
	i32.load	8
	if
	end_if
	end_function

	.globl	header_call
header_call:
	.functype	header_call (i32, i32) -> ()
	call	helper
	local.get	0
	i32.load	8
	if
	end_if
	end_function

	.globl	header_store_secret
header_store_secret:
	.functype	header_store_secret (i32, i32) -> ()
	local.get	0
	local.get	1
	i32.store	8
	local.get	0
	i32.load	8
	if
	end_if
	end_function

	.globl	header_store_other
header_store_other:
	.functype	header_store_other (i32, i32) -> ()
	.local	i32
	local.get	0
	local.set	2
	local.get	2
	local.get	1
	i32.store	8
	local.get	0
	i32.load	8
	if
	end_if
	end_function

	.globl	header_offset
header_offset:
	.functype	header_offset (i32, i32) -> ()
	local.get	0
	i32.load	32
	if
	end_if
	end_function

	.globl	straddle
straddle:
	.functype	straddle (i32, i32) -> ()
	local.get	0
	i64.load	28
	i32.wrap_i64
	if
	end_if
	end_function

	.globl	globstore
globstore:
	.functype	globstore (i32, i32) -> ()
	i32.const	1024
	local.get	1
	i32.store	0
	local.get	0
	i32.load	8
	if
	end_if
	end_function
