; vector add as the Abla kernel lowering would emit it for Vulkan: three storage buffers (set 0, bindings 0..2), 64 threads.
target triple = "spirv1.6-unknown-vulkan1.3-compute"
@na = private unnamed_addr constant [2 x i8] c"a\00"
@nb = private unnamed_addr constant [2 x i8] c"b\00"
@nc = private unnamed_addr constant [2 x i8] c"c\00"

define void @vadd() #0 {
entry:
  %a = call target("spirv.VulkanBuffer", [0 x float], 12, 0) @llvm.spv.resource.handlefrombinding.tspirv.VulkanBuffer_a0f32_12_0t(i32 0, i32 0, i32 1, i32 0, ptr @na)
  %b = call target("spirv.VulkanBuffer", [0 x float], 12, 0) @llvm.spv.resource.handlefrombinding.tspirv.VulkanBuffer_a0f32_12_0t(i32 0, i32 1, i32 1, i32 0, ptr @nb)
  %c = call target("spirv.VulkanBuffer", [0 x float], 12, 1) @llvm.spv.resource.handlefrombinding.tspirv.VulkanBuffer_a0f32_12_1t(i32 0, i32 2, i32 1, i32 0, ptr @nc)
  %id = call i32 @llvm.spv.thread.id.i32(i32 0)
  %pa = call ptr addrspace(11) @llvm.spv.resource.getpointer.p11.tspirv.VulkanBuffer_a0f32_12_0t(target("spirv.VulkanBuffer", [0 x float], 12, 0) %a, i32 %id)
  %pb = call ptr addrspace(11) @llvm.spv.resource.getpointer.p11.tspirv.VulkanBuffer_a0f32_12_0t(target("spirv.VulkanBuffer", [0 x float], 12, 0) %b, i32 %id)
  %pc = call ptr addrspace(11) @llvm.spv.resource.getpointer.p11.tspirv.VulkanBuffer_a0f32_12_1t(target("spirv.VulkanBuffer", [0 x float], 12, 1) %c, i32 %id)
  %x = load float, ptr addrspace(11) %pa
  %y = load float, ptr addrspace(11) %pb
  %s = fadd float %x, %y
  store float %s, ptr addrspace(11) %pc
  ret void
}

declare target("spirv.VulkanBuffer", [0 x float], 12, 0) @llvm.spv.resource.handlefrombinding.tspirv.VulkanBuffer_a0f32_12_0t(i32, i32, i32, i32, ptr)
declare target("spirv.VulkanBuffer", [0 x float], 12, 1) @llvm.spv.resource.handlefrombinding.tspirv.VulkanBuffer_a0f32_12_1t(i32, i32, i32, i32, ptr)
declare ptr addrspace(11) @llvm.spv.resource.getpointer.p11.tspirv.VulkanBuffer_a0f32_12_0t(target("spirv.VulkanBuffer", [0 x float], 12, 0), i32)
declare ptr addrspace(11) @llvm.spv.resource.getpointer.p11.tspirv.VulkanBuffer_a0f32_12_1t(target("spirv.VulkanBuffer", [0 x float], 12, 1), i32)
declare i32 @llvm.spv.thread.id.i32(i32)

attributes #0 = { "hlsl.shader"="compute" "hlsl.numthreads"="64,1,1" }
