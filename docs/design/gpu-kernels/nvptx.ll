; CUDA entry shims: kernel parameters in the global address space, the index from the grid registers.
target triple = "nvptx64-nvidia-cuda"

define internal i32 @global.id() alwaysinline {
  %t = call i32 @llvm.nvvm.read.ptx.sreg.tid.x()
  %c = call i32 @llvm.nvvm.read.ptx.sreg.ctaid.x()
  %n = call i32 @llvm.nvvm.read.ptx.sreg.ntid.x()
  %cn = mul i32 %c, %n
  %id = add i32 %cn, %t
  ret i32 %id
}

define ptx_kernel void @vadd(ptr addrspace(1) %a, ptr addrspace(1) %b, ptr addrspace(1) %c, i32 %n) {
  %ga = addrspacecast ptr addrspace(1) %a to ptr
  %gb = addrspacecast ptr addrspace(1) %b to ptr
  %gc = addrspacecast ptr addrspace(1) %c to ptr
  %i = call i32 @global.id()
  call void @vadd.body(ptr %ga, ptr %gb, ptr %gc, i32 %n, i32 %i)
  ret void
}

define ptx_kernel void @nvfp4dot(ptr addrspace(1) %w, ptr addrspace(1) %s, ptr addrspace(1) %x, ptr addrspace(1) %out, i32 %rows, i32 %k, float %g) {
  %gw = addrspacecast ptr addrspace(1) %w to ptr
  %gs = addrspacecast ptr addrspace(1) %s to ptr
  %gx = addrspacecast ptr addrspace(1) %x to ptr
  %go = addrspacecast ptr addrspace(1) %out to ptr
  %row = call i32 @global.id()
  call void @nvfp4dot.body(ptr %gw, ptr %gs, ptr %gx, ptr %go, i32 %rows, i32 %k, float %g, i32 %row)
  ret void
}

declare i32 @llvm.nvvm.read.ptx.sreg.tid.x()
declare i32 @llvm.nvvm.read.ptx.sreg.ctaid.x()
declare i32 @llvm.nvvm.read.ptx.sreg.ntid.x()

declare void @vadd.body(ptr, ptr, ptr, i32, i32)
declare void @nvfp4dot.body(ptr, ptr, ptr, ptr, i32, i32, float, i32)

; Subgroup = warp: the lane from tid.x & 31, the sum by butterfly shuffles.
define float @kernel_subgroup_sum(float %v) alwaysinline {
  %a = call float @llvm.nvvm.shfl.sync.bfly.f32(i32 -1, float %v, i32 16, i32 31)
  %s1 = fadd float %v, %a
  %b = call float @llvm.nvvm.shfl.sync.bfly.f32(i32 -1, float %s1, i32 8, i32 31)
  %s2 = fadd float %s1, %b
  %c = call float @llvm.nvvm.shfl.sync.bfly.f32(i32 -1, float %s2, i32 4, i32 31)
  %s3 = fadd float %s2, %c
  %d = call float @llvm.nvvm.shfl.sync.bfly.f32(i32 -1, float %s3, i32 2, i32 31)
  %s4 = fadd float %s3, %d
  %e = call float @llvm.nvvm.shfl.sync.bfly.f32(i32 -1, float %s4, i32 1, i32 31)
  %s5 = fadd float %s4, %e
  ret float %s5
}

define ptx_kernel void @nvfp4dotSub(ptr addrspace(1) %w, ptr addrspace(1) %s, ptr addrspace(1) %x, ptr addrspace(1) %out, i32 %rows, i32 %k, float %g) {
  %gw = addrspacecast ptr addrspace(1) %w to ptr
  %gs = addrspacecast ptr addrspace(1) %s to ptr
  %gx = addrspacecast ptr addrspace(1) %x to ptr
  %go = addrspacecast ptr addrspace(1) %out to ptr
  %id = call i32 @global.id()
  %row = lshr i32 %id, 5
  %lane = and i32 %id, 31
  call void @nvfp4dotSub.body(ptr %gw, ptr %gs, ptr %gx, ptr %go, i32 %rows, i32 %k, float %g, i32 %row, i32 %lane, i32 32)
  ret void
}

declare float @llvm.nvvm.shfl.sync.bfly.f32(i32, float, i32, i32)
declare void @nvfp4dotSub.body(ptr, ptr, ptr, ptr, i32, i32, float, i32, i32, i32)
