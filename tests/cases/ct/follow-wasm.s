// Calls between functions of one Wasm module, for the checker's --follow-calls (linked with wasm-ld, so a call is
// `call <function index>`). Parameter 0 is the secret unless a spec says otherwise:
//   follow_clean:0       passes it to a callee that adds one and returns it
//   follow_branch:0      passes it to a callee that branches on it: found, "in function"
//   follow_stale:0       the second argument is secret but the callee ignores it
//   follow_result:0      the callee returns its argument and the caller branches on the result: found
//   follow_public:0      the callee returns a constant: the caller's branch on its result is public
//   follow_drop:0        the secret is passed but the call's result is dropped and a constant is branched on: clean
//   follow_store:0       the callee stores the secret to memory (fine); the caller then loads and branches: found
//   follow_recursive:0   a call into itself: refused
//   follow_indirect:0    call_indirect: refused
	.text
	.functype	callee_add (i64) -> (i64)
	.functype	callee_branch (i64) -> (i64)
	.functype	callee_constant () -> (i64)
	.functype	callee_ignore (i64, i64) -> (i64)
	.functype	callee_store (i64, i32) -> ()
	.functype	follow_recursive (i64) -> (i64)

	.globl	callee_add
callee_add:
	.functype	callee_add (i64) -> (i64)
	local.get	0
	i64.const	1
	i64.add
	end_function

	.globl	callee_branch
callee_branch:
	.functype	callee_branch (i64) -> (i64)
	local.get	0
	i64.eqz
	if		i64
	i64.const	2
	else
	i64.const	1
	end_if
	end_function

	.globl	callee_constant
callee_constant:
	.functype	callee_constant () -> (i64)
	i64.const	7
	end_function

	.globl	callee_ignore
callee_ignore:
	.functype	callee_ignore (i64, i64) -> (i64)
	local.get	0
	end_function

	.globl	callee_store
callee_store:
	.functype	callee_store (i64, i32) -> ()
	local.get	1
	local.get	0
	i64.store	0
	end_function

	.globl	follow_clean
follow_clean:
	.functype	follow_clean (i64) -> (i64)
	local.get	0
	call		callee_add
	end_function

	.globl	follow_branch
follow_branch:
	.functype	follow_branch (i64) -> (i64)
	local.get	0
	call		callee_branch
	end_function

	.globl	follow_stale
follow_stale:
	.functype	follow_stale (i64, i64) -> (i64)
	local.get	0
	local.get	1
	call		callee_ignore
	i64.eqz
	if		i64
	i64.const	2
	else
	i64.const	1
	end_if
	end_function

	.globl	follow_result
follow_result:
	.functype	follow_result (i64) -> (i64)
	local.get	0
	call		callee_add
	i64.eqz
	if		i64
	i64.const	2
	else
	i64.const	1
	end_if
	end_function

	.globl	follow_public
follow_public:
	.functype	follow_public (i64) -> (i64)
	local.get	0
	drop
	call		callee_constant
	i64.eqz
	if		i64
	i64.const	2
	else
	i64.const	1
	end_if
	end_function

	.globl	follow_drop
follow_drop:
	.functype	follow_drop (i64) -> (i64)
	local.get	0
	call		callee_add
	drop
	i64.const	0
	i64.eqz
	if		i64
	i64.const	2
	else
	i64.const	1
	end_if
	end_function

	.globl	follow_store
follow_store:
	.functype	follow_store (i64, i32) -> (i64)
	local.get	0
	local.get	1
	call		callee_store
	local.get	1
	i64.load	0
	i64.eqz
	if		i64
	i64.const	2
	else
	i64.const	1
	end_if
	end_function

	.globl	follow_recursive
follow_recursive:
	.functype	follow_recursive (i64) -> (i64)
	local.get	0
	call		follow_recursive
	end_function

	.globl	follow_indirect
follow_indirect:
	.functype	follow_indirect (i64, i32) -> (i64)
	local.get	0
	local.get	1
	call_indirect	(i64) -> (i64)
	end_function

// Ways a function returns other than falling off its end: the checker must take the result's taint from each.
//   follow_return_block:0   `return` inside a block hands back the secret: the caller's branch on it is found
//   follow_br_return:0      `br 0` to the function's outermost label returns the secret: found
	.globl	callee_return_block
callee_return_block:
	.functype	callee_return_block (i64) -> (i64)
	block
	local.get	0
	return
	end_block
	i64.const	0
	end_function

	.globl	callee_br_return
callee_br_return:
	.functype	callee_br_return (i64) -> (i64)
	local.get	0
	br		0
	end_function

	.globl	follow_return_block
follow_return_block:
	.functype	follow_return_block (i64) -> (i64)
	local.get	0
	call		callee_return_block
	i64.eqz
	if		i64
	i64.const	2
	else
	i64.const	1
	end_if
	end_function

	.globl	follow_br_return
follow_br_return:
	.functype	follow_br_return (i64) -> (i64)
	local.get	0
	call		callee_br_return
	i64.eqz
	if		i64
	i64.const	2
	else
	i64.const	1
	end_if
	end_function

//   follow_br_table:0   `br_table` whose targets are the outermost label returns the secret: found
	.globl	callee_br_table
callee_br_table:
	.functype	callee_br_table (i64, i32) -> (i64)
	local.get	0
	local.get	1
	br_table	{0, 0}
	end_function

	.globl	follow_br_table
follow_br_table:
	.functype	follow_br_table (i64) -> (i64)
	local.get	0
	i32.const	0
	call		callee_br_table
	i64.eqz
	if		i64
	i64.const	2
	else
	i64.const	1
	end_if
	end_function
