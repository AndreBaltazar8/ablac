target triple = "spirv64-unknown-unknown"
%A = type target("spirv.CooperativeMatrixKHR", half, 3, 16, 16, 0)
%B = type target("spirv.CooperativeMatrixKHR", half, 3, 16, 16, 1)
%C = type target("spirv.CooperativeMatrixKHR", float, 3, 16, 16, 2)
define spir_kernel void @mm(ptr addrspace(1) %pa, ptr addrspace(1) %pb, ptr addrspace(1) %pc) {
  %ma = call spir_func %A @__spirv_CooperativeMatrixLoadKHR(ptr addrspace(1) %pa, i32 0, i32 16)
  %mb = call spir_func %B @__spirv_CooperativeMatrixLoadKHR(ptr addrspace(1) %pb, i32 0, i32 16)
  %mc0 = call spir_func %C @__spirv_CooperativeMatrixLoadKHR(ptr addrspace(1) %pc, i32 0, i32 16)
  %mc = call spir_func %C @__spirv_CooperativeMatrixMulAddKHR(%A %ma, %B %mb, %C %mc0, i32 0)
  call spir_func void @__spirv_CooperativeMatrixStoreKHR(ptr addrspace(1) %pc, %C %mc, i32 0, i32 16)
  ret void
}
declare spir_func %A @__spirv_CooperativeMatrixLoadKHR(ptr addrspace(1), i32, i32)
declare spir_func %C @__spirv_CooperativeMatrixMulAddKHR(%A, %B, %C, i32)
declare spir_func void @__spirv_CooperativeMatrixStoreKHR(ptr addrspace(1), %C, i32, i32)
