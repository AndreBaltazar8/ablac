; One subgroup computes C (16x16 f32) = A (16x16 f16) * B (16x16 f16) with a cooperative-matrix multiply-add.
target triple = "spirv1.6-unknown-vulkan1.3-compute"
@na = private unnamed_addr constant [2 x i8] c"a\00"
@nb = private unnamed_addr constant [2 x i8] c"b\00"
@nc = private unnamed_addr constant [2 x i8] c"c\00"

%A = type target("spirv.CooperativeMatrixKHR", half, 3, 16, 16, 0)
%B = type target("spirv.CooperativeMatrixKHR", half, 3, 16, 16, 1)
%C = type target("spirv.CooperativeMatrixKHR", float, 3, 16, 16, 2)

define void @mm() #0 {
entry:
  %ha = call target("spirv.VulkanBuffer", [0 x half], 12, 0) @llvm.spv.resource.handlefrombinding.a(i32 0, i32 0, i32 1, i32 0, ptr @na)
  %hb = call target("spirv.VulkanBuffer", [0 x half], 12, 0) @llvm.spv.resource.handlefrombinding.a(i32 0, i32 1, i32 1, i32 0, ptr @nb)
  %hc = call target("spirv.VulkanBuffer", [0 x float], 12, 1) @llvm.spv.resource.handlefrombinding.c(i32 0, i32 2, i32 1, i32 0, ptr @nc)
  %pa = call ptr addrspace(11) @llvm.spv.resource.getpointer.a(target("spirv.VulkanBuffer", [0 x half], 12, 0) %ha, i32 0)
  %pb = call ptr addrspace(11) @llvm.spv.resource.getpointer.a(target("spirv.VulkanBuffer", [0 x half], 12, 0) %hb, i32 0)
  %pc = call ptr addrspace(11) @llvm.spv.resource.getpointer.c(target("spirv.VulkanBuffer", [0 x float], 12, 1) %hc, i32 0)
  %ma = call spir_func %A @__spirv_CooperativeMatrixLoadKHR(ptr addrspace(11) %pa, i32 0, i32 16)
  %mb = call spir_func %B @__spirv_CooperativeMatrixLoadKHR(ptr addrspace(11) %pb, i32 0, i32 16)
  %mc0 = call spir_func %C @__spirv_CooperativeMatrixLoadKHR(ptr addrspace(11) %pc, i32 0, i32 16)
  %mc = call spir_func %C @__spirv_CooperativeMatrixMulAddKHR(%A %ma, %B %mb, %C %mc0, i32 0)
  call spir_func void @__spirv_CooperativeMatrixStoreKHR(ptr addrspace(11) %pc, %C %mc, i32 0, i32 16)
  ret void
}

declare target("spirv.VulkanBuffer", [0 x half], 12, 0) @llvm.spv.resource.handlefrombinding.a(i32, i32, i32, i32, ptr)
declare target("spirv.VulkanBuffer", [0 x float], 12, 1) @llvm.spv.resource.handlefrombinding.c(i32, i32, i32, i32, ptr)
declare ptr addrspace(11) @llvm.spv.resource.getpointer.a(target("spirv.VulkanBuffer", [0 x half], 12, 0), i32)
declare ptr addrspace(11) @llvm.spv.resource.getpointer.c(target("spirv.VulkanBuffer", [0 x float], 12, 1), i32)
declare spir_func %A @__spirv_CooperativeMatrixLoadKHR(ptr addrspace(11), i32, i32)
declare spir_func %C @__spirv_CooperativeMatrixMulAddKHR(%A, %B, %C, i32)
declare spir_func void @__spirv_CooperativeMatrixStoreKHR(ptr addrspace(11), %C, i32, i32)

attributes #0 = { "hlsl.shader"="compute" "hlsl.numthreads"="32,1,1" }
