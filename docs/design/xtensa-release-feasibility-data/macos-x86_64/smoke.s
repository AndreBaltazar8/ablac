	.file	"patches.ll"
	.text
	.global	target                          # -- Begin function target
	.p2align	2
	.type	target,@function
target:                                 # @target
	.cfi_startproc
# %bb.0:
	entry	a1, 32
	.cfi_def_cfa_offset 32
	retw.n
.Lfunc_end0:
	.size	target, .Lfunc_end0-target
	.cfi_endproc
                                        # -- End function
	.global	direct                          # -- Begin function direct
	.p2align	2
	.type	direct,@function
direct:                                 # @direct
	.cfi_startproc
# %bb.0:
	entry	a1, 32
	.cfi_def_cfa_offset 32
	call8	target
	retw.n
.Lfunc_end1:
	.size	direct, .Lfunc_end1-direct
	.cfi_endproc
                                        # -- End function
	.global	mask                            # -- Begin function mask
	.p2align	2
	.type	mask,@function
mask:                                   # @mask
	.cfi_startproc
# %bb.0:
	entry	a1, 32
	.cfi_def_cfa_offset 32
	extui	a2, a2, 0, 8
	retw.n
.Lfunc_end2:
	.size	mask, .Lfunc_end2-mask
	.cfi_endproc
                                        # -- End function
	.literal_position
	.literal .LCPI3_0, external
	.text
	.global	bit                             # -- Begin function bit
	.p2align	2
	.type	bit,@function
bit:                                    # @bit
	.cfi_startproc
# %bb.0:
	entry	a1, 32
	.cfi_def_cfa_offset 32
	bbsi	a2, 2, .LBB3_2
# %bb.1:                                # %a
	l32r	a8, .LCPI3_0
	callx8	a8
	or	a2, a3, a3
	retw.n
.LBB3_2:                                # %b
	movi	a2, 2
	retw.n
.Lfunc_end3:
	.size	bit, .Lfunc_end3-bit
	.cfi_endproc
                                        # -- End function
	.literal_position
	.literal .LCPI4_0, external
	.text
	.global	zero                            # -- Begin function zero
	.p2align	2
	.type	zero,@function
zero:                                   # @zero
	.cfi_startproc
# %bb.0:
	entry	a1, 32
	.cfi_def_cfa_offset 32
	beqz.n	a2, .LBB4_2
# %bb.1:                                # %b
	movi	a2, 2
	retw.n
.LBB4_2:                                # %a
	l32r	a8, .LCPI4_0
	callx8	a8
	movi	a2, 1
	retw.n
.Lfunc_end4:
	.size	zero, .Lfunc_end4-zero
	.cfi_endproc
                                        # -- End function
	.section	".note.GNU-stack","",@progbits
