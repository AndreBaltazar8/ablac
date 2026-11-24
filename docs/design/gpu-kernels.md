# GPU kernels written in Abla (#1233)

Status: design note for André's decision. Nothing here is implemented in the compiler. The prototype in
[gpu-kernels/](gpu-kernels/) is hand-written LLVM IR in the shape the compiler would emit, run on the 4090 and the CPU
(`docs/design/gpu-kernels/build.sh`).

## Goal

abla-grad wants its kernels (matrix-vector products over quantized weights, NVFP4 for Inkling's experts, attention,
norms) written once in Abla and run on:

- the CPU (native code, the reference and the fallback);
- CUDA first (André's choice), through PTX and the driver API;
- Vulkan (SPIR-V);
- later Metal;

all behind one interface. Model code never names a backend.

## What was checked, and how

| Fact | Checked how | Result |
|---|---|---|
| Our LLVM (23.1.3, `shell.nix`) emits PTX | `llc -mcpu=sm_89 -mattr=+ptx85` on `nvptx.ll` + `body.ll` | yes |
| The driver loads that PTX with no CUDA toolkit installed | `cuModuleLoadData` (driver 580.95, its PTX JIT) on the 4090 | yes |
| Our LLVM emits Vulkan SPIR-V | `llc` on `vadd-vulkan.ll` (triple `spirv1.6-unknown-vulkan1.3-compute`); `spirv-val --target-env vulkan1.3` | valid |
| The 4090 runs that SPIR-V | `vkCreateShaderModule` + compute pipeline + `vkCmdDispatch` | `c = a + b` correct |
| One kernel body serves CUDA and CPU | `body.ll` linked under `nvptx.ll` or `cpu.ll`; outputs compared to an independent C reference | vadd exact; NVFP4 dot max error 8.6e-06 against outputs up to 14.8 |
| Subgroup ops lower per backend | `kernel_subgroup_sum`: warp butterfly shuffles on CUDA, the value itself on the CPU | correct, 2.3x faster than one thread per row |
| Tensor cores reachable from CUDA in our LLVM | the intrinsic names in libLLVM.so.23.1 | `llvm.nvvm.mma.m16n8k16` f16/bf16 and `m16n8k32 ... e4m3` (sm_89 FP8) are present, as are Blackwell's block-scaled `mxf8f6f4` e2m1 forms |
| NVFP4 decode in hardware on the 4090 | the PTX conversions in LLVM (`cvt ... e2m1x2`) | only on sm_100a/sm_120a, not Ada: on the 4090 the decode is arithmetic (as in the prototype) |
| Vulkan cooperative matrix on the 4090 | `vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR` | `VK_KHR_cooperative_matrix`: f16×f16→f16/f32, bf16×bf16→f32, s8/u8→s32/u32 tiles (16×16×16, 16×8×16, 16×16×32 ...). No FP8. The Intel iGPU in this machine reports 8×8×16 and 8×8×32 tiles |
| SPIR-V cooperative matrix in our LLVM | a 16×16×16 f16→f32 `__spirv_CooperativeMatrix{Load,MulAdd,Store}KHR` module (`--spirv-ext=+SPV_KHR_cooperative_matrix`) under both triples | lowered to `OpCooperativeMatrix*KHR` for OpenCL (`spirv64-unknown-unknown`). For Vulkan (`spirv1.6-unknown-vulkan1.3-compute`) the types are emitted but the calls stay function calls, and spirv-val rejects the module (`Linkage`). LLVM 23 has no Vulkan path for tiles |
| abla-graphics can run our SPIR-V | read its source | it has the Vulkan compute driver (`computePipelineNative`, `dispatch`), but the public layer takes GLSL only, the entry point is fixed to `main`, and it waits with `vkQueueWaitIdle` |
| ablac today | read its source | runs `opt`/`llc` as separate processes for cross targets (`bootstrapExternalEmitObjectForTargetWithTools`); SPIRV is deliberately left out of the static compiler's LLVM; no f16/bf16; never emits an address space other than 0 |

Not checked (no hardware or not tried): anything on Metal (no Mac here; the CI Macs could), barriers on the CPU,
performance tuning beyond the two NVFP4 mappings.

## Prototype results (4090, driver 580.95)

| Kernel | Backend | Result | Time |
|---|---|---|---|
| vadd, 1M floats | CUDA (PTX) | exact | |
| vadd | CPU (same body) | exact | |
| vadd, 1024 floats | Vulkan (SPIR-V) | exact | |
| NVFP4 row dot, 8192×4096, one thread per row | CUDA | max error 8.6e-06 | 147 µs (128 GB/s) |
| same | CPU, one thread | max error 8.6e-06 | 143–187 ms |
| NVFP4 row dot, one subgroup per row | CUDA | max error 1.9e-06 | 58–65 µs (290–320 GB/s) |
| same | CPU (subgroup of 1) | max error 8.6e-06 | |

The NVFP4 layout is the standard one: two E2M1 elements per byte (low nibble first), one E4M3 scale per 16 elements, one
f32 scale per tensor. The 290–320 GB/s are a first mapping with no tuning: no vector loads wider than 8 bytes, x not
staged in shared memory, one row per warp. A tuned GEMV should get near the 4090's ~1 TB/s. That tuning is
abla-grad's work, not the language's.

## Options for the source form

All three describe the same kernel. Here is vector add in each.

### A. A kernel annotation on an ordinary function (recommended)

```abla
import "abla/kernel"

@kernel
fun vadd(a: KernelBuffer<f32>, b: KernelBuffer<f32>, out: KernelMutableBuffer<f32>, n: u32) {
    val i = kernelGlobalId()
    if (i < n) out[i] = a[i] + b[i]
}
```

- The language change is small. `@kernel` is a new annotation, like `@naked`. `abla/kernel` is a stdlib module with
  buffer types, ids, barriers and subgroup ops. f16/bf16 are two new scalar types (needed anyway; see below).
- The kernel is ordinary Abla to the parser, the type checker, the LSP and the formatter. The CPU backend compiles the
  same function. Helpers a kernel calls are ordinary functions that pass the same check.
- Checked like `@naked` and `compile fun`: sema walks the kernel and everything it calls (as the compile-effect summary
  does) and reports `kernel.<rule>` at the offending expression.

### B. A `kernel fun` keyword

The same as A, but the kind is in the grammar (`kernel fun vadd(...)`). It reads better and leaves room for kernel-only
syntax later (for example a launch-shape clause). Its cost is a keyword and a parser change. A can be promoted to B
later without changing a kernel's body.

### C. A `$kernel { ... }` subparser

A small separate language, registered by a library like abla-graphics' `$glsl`. It needs no core-language change. But it
is not Abla: no shared types or helpers with the host, no LSP beyond `W_SUBPARSER_NOT_EXPANDED`, and a second compiler to
keep in step. Running the same source on the CPU would also need the subparser to emit Abla code. I don't recommend it.

## The subset

Allowed in a kernel and in what it calls:

- Scalars: `bool`, `i32`, `u32`, `i64`, `u64`, `f32`, and the new `f16` and `bf16`; `u8`/`i8` in buffers.
- Fixed-size local arrays.
- Structs passed by value.
- Arithmetic, `if`/`when`, loops, calls (inlined; no recursion).
- Compile-time constants and `compile fun` results.
- Buffers as typed, indexed parameters: `KernelBuffer<T>` (read) and `KernelMutableBuffer<T>` (read/write).
- Scalar parameters (push constants on Vulkan, kernel parameters on CUDA).
- `kernelGlobalId`, `kernelLocalId`, `kernelGroupId`, `kernelGroupSize`.
- Workgroup shared memory (`kernelShared<T>(count)`) and `kernelBarrier()`.
- Subgroup ops: `kernelSubgroupSum`, `Max`, `Shuffle`, `Broadcast`, `Ballot`.
- Atomics on buffers and shared memory.
- Math (`sqrt`, `exp`, `fma`, ...).
- Later, cooperative-matrix tiles (`kernelMatrixMultiplyAdd` on tile values).

Forbidden, each with its own diagnostic:

- Anything that allocates on the GC heap: strings, `array<T>`, class instances, closures, string templates.
- Interfaces and virtual calls.
- Recursion and exceptions.
- I/O, syscalls, `extern` calls and `trusted` code.
- Raw addresses and `abla/unsafe`.
- Writing a module `var`.

**Typed, indexed buffers, not pointers.** Vulkan's SPIR-V uses logical addressing. A kernel cannot do pointer arithmetic
or load a `u64` from a byte buffer (confirmed while writing the Vulkan form: a storage buffer is a typed runtime array
reached through a resource handle). A kernel therefore indexes typed buffers: `w[i]` on a `KernelBuffer<u32>`. CUDA and
the CPU lower the same index to a GEP. This also keeps kernels inside Abla's memory safety.

**Bounds checks.** Indexes are checked by default, so kernels stay safe Abla. A failed check stores the kernel's id and
the index in a per-launch status word and returns. The host turns the status into an error after the launch: no fault,
no silent garbage. One compare and a predicted branch per access is noise against memory-bound kernels. A
`@kernel(unchecked)` form for measured hot loops is left for later and would need `trusted`.

**f16 and bf16.** These are new scalar types for the whole language, not only kernels: storage, conversion, arithmetic
(promoted to f32 on CPUs without it). They are a separate language decision; kernels can start with f32 and `u16` bit
patterns.

## The backend interface

### Compiler side: one kernel IR, one lowering per backend

ablac compiles each `@kernel` once to backend-neutral LLVM IR. The prototype's `body.ll` has this shape: buffers are
pointers, and the ids and subgroup ops are calls to a fixed set of `abla.kernel.*` functions (`kernel_subgroup_sum` in
the prototype). Each backend is a small lowering of that set plus an entry shim:

| abla.kernel op | CUDA (NVPTX) | Vulkan (SPIR-V) | CPU |
|---|---|---|---|
| kernel entry | `ptx_kernel` function, parameters in addrspace(1) | `hlsl.shader="compute"` with `hlsl.numthreads` | a function over a range of groups |
| buffer `b[i]` | GEP on a global pointer | `llvm.spv.resource.getpointer(handle, i)` | GEP |
| global/local/group id | `llvm.nvvm.read.ptx.sreg.*` | `llvm.spv.thread.id` and friends | loop counters |
| shared memory | addrspace(3) global | Workgroup storage | a per-group stack array |
| barrier | `llvm.nvvm.barrier0` | `llvm.spv.group.memory.barrier.with.group.sync` | the group's threads run as a loop split at each barrier (see below) |
| subgroup sum/shuffle | `shfl.sync` | wave intrinsics (`OpGroupNonUniform*`) | identity, or SIMD lanes |
| f16/bf16 | native | `shaderFloat16` / `SPV_KHR_bfloat16` | promote to f32 |

The artifacts go into the program, one per enabled backend: PTX text, SPIR-V words, and CPU code linked in as ordinary
functions. A manifest goes with them (parameter order and types, which buffers are written, the workgroup size), so no
host code hand-writes bindings. Building PTX and SPIR-V uses the external `opt`/`llc` path that cross targets already use.
Only the triple, `-mcpu`, and the lowering differ.

**The CPU and barriers.** A kernel with no barrier runs each group as a loop over its threads, split across Abla threads
by group. A kernel with barriers needs its body cut at each barrier into phases that run for all threads of the group in
turn, with live values kept per thread (the standard "loop fission" lowering CPU OpenCL uses). That is the hardest part
of the CPU backend. A first version could refuse barriers on the CPU, run such kernels with a group size of 1 where the
algorithm allows it, and add fission after.

### Host side (Abla, `abla/kernel`)

```abla
interface KernelBackend {
    fun name(): string
    fun buffer(bytes: int, usage: KernelBufferUsage): KernelDeviceBuffer
    fun upload(target: KernelDeviceBuffer, data: ByteView, offset: int = 0): KernelResult
    fun download(source: KernelDeviceBuffer, offset: int, bytes: int): KernelBytesResult
    fun load(kernel: KernelArtifact): KernelProgramResult       // the backend's artifact from the manifest
    fun launch(program: KernelProgram, groups: KernelGrid, arguments: KernelArguments): KernelLaunch
    fun wait(launch: KernelLaunch): KernelResult                 // also reads the bounds-check status word
}

fun kernelBackends(): array<KernelBackend>                       // what this machine has: CUDA, Vulkan, CPU, in that order
```

abla-grad calls `backend.launch(vadd, grid, kernelArguments(a, b, out, n))` and never a CUDA or Vulkan function. Each
backend implements the interface over its driver:

- **CUDA:** about 15 driver functions (`cuInit`, `cuCtxCreate`, `cuModuleLoadData`, `cuModuleGetFunction`,
  `cuMemAlloc`, `cuMemcpy*`, `cuLaunchKernel`, `cuStreamSynchronize`, `cuGetErrorString`). They are declared by hand
  as the prototype does, with `libcuda` loaded at run time so a program without NVIDIA hardware still starts. No CUDA
  toolkit is needed: the driver JIT-compiles the PTX.
- **Vulkan:** abla-graphics' compute driver. It needs a public path for a SPIR-V module with a named entry, bindings and
  push constants from our manifest instead of GLSL reflection, and fences instead of `vkQueueWaitIdle`.
- **CPU:** calls the linked kernel functions over a thread pool.

### What a new backend costs

1. A lowering of the `abla.kernel.*` ops and the entry shim for its LLVM target. For CUDA and Vulkan the prototype's
   shims are about 60 lines of IR each. In the compiler that is one module per backend.
2. Building the artifact: one more `llc` triple through the existing external-tool path, or, for a target LLVM cannot
   emit, a text emitter (see Metal).
3. A host implementation of `KernelBackend` over the driver: buffers, load, launch, wait.
4. Running the shared kernel conformance suite: vadd, reductions, shared memory and barriers, subgroup ops, atomics,
   bounds-check status, NVFP4/q4 dots against the CPU result. A backend is done when the suite passes.

## The other backends

**CUDA (NVPTX), first.** Verified end to end above. The PTX targets `sm_89`/PTX 8.5 and the driver JITs it; for a range
of GPUs, emit for the oldest supported `sm` (the driver JITs forward). Tensor cores: LLVM 23 has the `mma.sync`
intrinsics for f16/bf16 (all of sm_80+) and FP8 e4m3/e5m2 (sm_89). Blackwell's block-scaled FP4 MMA (`mxf8f6f4`, e2m1
with e4m3/ue8m0 scales) is also present for sm_100+/sm_120. So NVFP4 experts can use FP8 tensor cores on the 4090 after
a decode to e4m3, and native FP4 MMA on Blackwell. Exposing tiles is a later step of the subset.

**Vulkan (SPIR-V), second.** Verified for vadd. It needs the typed-buffer lowering (handles in place of pointers),
push-constant parameters, and abla-graphics' public SPIR-V path. Tensor cores go through `VK_KHR_cooperative_matrix`:
present on the 4090 (f16, bf16, int8 tiles; no FP8) and on the Intel iGPU. LLVM 23 lowers the cooperative-matrix
builtins only for OpenCL SPIR-V, not for Vulkan shaders (checked above). Tiles on Vulkan therefore need one of two
things: a patch to our LLVM (we already carry patches) that enables the builtin lowering in the shader path, or ablac
writing those five instructions into the SPIR-V itself after llc. Either is bounded, but neither comes for free.
Scalar and subgroup kernels on Vulkan are unaffected.

**Metal, third.** LLVM cannot emit Apple's AIR, so there are two routes:

- (a) SPIR-V through MoltenVK. It runs the Vulkan backend unchanged on Apple devices. MoltenVK translates with
  SPIRV-Cross at pipeline creation. It's the cheapest route, but adds a C++ library to every Apple program that uses
  kernels, and subgroup and cooperative-matrix support follows what MoltenVK maps.
- (b) Our own MSL emitter. The kernel subset is small: scalars, typed buffers, ids, barriers, subgroup ops. A text
  emitter from the kernel IR to Metal Shading Language, compiled at run time with `newLibraryWithSource`, needs no Xcode
  toolchain at build time and no C++ at run time. It costs a real backend (the emitter plus a Metal `KernelBackend` over
  the Objective-C runtime via `objc_msgSend`, which ablac does not call anywhere yet), but it keeps Metal native, and
  simdgroup matrices are reachable later.

  I recommend (b) when Metal matters, and (a) as a stopgap if a Mac user needs kernels before then. Neither is verified
  here.

## Recommended order

1. `@kernel` (option A), the checker, f32-only buffers, the CPU backend without barriers, and the CUDA backend. This is
   abla-grad's first need and its path is verified. Use the conformance suite from the start.
2. Barriers and shared memory on CUDA, then CPU fission. Subgroup ops everywhere. Bounds-check status.
3. f16/bf16 as language types (a separate decision). FP8/NVFP4 helpers in `abla/kernel/quant`.
4. The Vulkan backend: typed-buffer lowering, push constants, and the abla-graphics SPIR-V path. Check cooperative
   matrix through LLVM's Vulkan path.
5. Tensor-core tiles: `mma.sync` on CUDA first, cooperative matrix on Vulkan.
6. Metal through an MSL emitter.

## Decisions for André

1. The source form: A (`@kernel` annotation, recommended), B (`kernel fun` keyword), or C (`$kernel` subparser).
2. Bounds checks in kernels on by default, with a status word, as above. Yes or no.
3. f16 and bf16 as language-wide scalar types, decided separately.
4. Metal: (b) our own MSL emitter, or (a) MoltenVK first.
