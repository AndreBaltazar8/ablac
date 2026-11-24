#!/usr/bin/env bash
# The #1233 prototype (docs/design/gpu-kernels.md): builds the kernels for each backend from the shared bodies and runs them.
#   - body.ll: the backend-neutral kernel bodies (vadd, nvfp4dot, nvfp4dotSub), what the kernel lowering would emit once;
#   - nvptx.ll / cpu.ll: each backend's entry shims (index registers or a loop, the subgroup sum), linked around the bodies;
#   - vadd-vulkan.ll: vadd as the SPIR-V (Vulkan) lowering would emit it, with resource handles in place of pointers;
#   - cuda-host.c / vulkan-host.c: throwaway hosts (the real ones would be Abla, behind the kernel backend interface).
# Needs the 4090's driver (libcuda, the Vulkan ICD) and nix; writes into build/gpu-kernels. Run from the repository root.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
here=$root/docs/design/gpu-kernels
out=$root/build/gpu-kernels
mkdir -p "$out"
cd "$out"
nix-shell "$root/shell.nix" --run "
    set -euo pipefail
    llvm-link $here/nvptx.ll $here/body.ll -S -o k-nvptx.ll 2> /dev/null
    opt -O3 k-nvptx.ll -S -o k-nvptx.opt.ll
    llc -O3 -mcpu=sm_89 -mattr=+ptx85 k-nvptx.opt.ll -o kernels.ptx
    llvm-link $here/cpu.ll $here/body.ll -o k-cpu.bc 2> /dev/null
    opt -O3 k-cpu.bc -o k-cpu.opt.bc
    llc -O3 -mcpu=native -filetype=obj -relocation-model=pic k-cpu.opt.bc -o kernels-cpu.o
    llc -O2 -filetype=obj $here/vadd-vulkan.ll -o vadd.spv
"
nix-shell -p spirv-tools --run "spirv-val --target-env vulkan1.3 vadd.spv"
echo "vadd.spv: valid SPIR-V for Vulkan 1.3"
nix-shell -p gcc vulkan-loader vulkan-headers --run "
    set -euo pipefail
    gcc -O2 -w -o cuda-host $here/cuda-host.c kernels-cpu.o -L/run/opengl-driver/lib -lcuda -lm -Wl,-rpath,/run/opengl-driver/lib
    gcc -O2 -w -o vulkan-host $here/vulkan-host.c -lvulkan
    ./cuda-host
    echo 'vulkan vadd (c = a + b with a[i] = i, b[i] = 2i):'
    ./vulkan-host vadd.spv vadd 16 3 1024
"
