#!/usr/bin/env bash
# `@kernel` functions (#1233, docs/language.md#gpu-kernels):
#   - abla-grad's NVFP4 matvec as a kernel on the CPU backend agrees with an independent f64 reference (nvfp4-cpu.ab);
#   - the half-precision conversions (bf16, f16, FP8 E4M3, f16x2 fma, rounded ints) give CUDA C's bits on the CPU (half-cpu.ab);
#   - a kernel outside the subset is refused when the program is built, naming the rule: a string (kernel.operation), a
#     recursive call (kernel.recursion), a result (kernel.signature), native code (kernel.call);
#   - on CUDA (tests/cases/kernel-cuda, the compiler's PTX through abla/kernel/cuda): vadd equals the CPU's result and the
#     NVFP4 matvec agrees with it, where the machine has the CUDA driver (libcuda) and a GPU; skipped with a message
#     otherwise. The GPU run takes abla-grad's GPU lock (/tmp/abla-grad-gpu.lock), which its model runs share.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=$root/build/kernels
rm -rf "$out"
mkdir -p "$out"
fail() { echo "kernels: $1" >&2; exit 1; }
cases=tests/cases/kernel

"$compiler" build "$cases/nvfp4-cpu.ab" -o "$out/nvfp4-cpu" --fast --no-cache > "$out/nvfp4-cpu.log" 2>&1 ||
    fail "nvfp4-cpu did not build: $(head -4 "$out/nvfp4-cpu.log")"
"$out/nvfp4-cpu" > "$out/nvfp4-cpu.out" 2>&1 || fail "nvfp4-cpu: $(cat "$out/nvfp4-cpu.out")"

# Tensor cores on the CPU backend (#1304): kernelMmaF16 stops the program and says it needs a GPU subgroup.
"$compiler" build "$cases/mma-cpu.ab" -o "$out/mma-cpu" --fast --no-cache > "$out/mma-cpu.log" 2>&1 ||
    fail "mma-cpu did not build: $(head -4 "$out/mma-cpu.log")"
if "$out/mma-cpu" > "$out/mma-cpu.out" 2>&1 || ! grep -q "kernelMmaF16 needs a GPU subgroup of 32 lanes" "$out/mma-cpu.out"; then
    fail "mma-cpu: $(cat "$out/mma-cpu.out")"
fi

# Dynamic shared memory kept past its launch (#1139 K1): writes through the kept buffers change no live array.
"$compiler" build "$cases/shared-kept.ab" -o "$out/shared-kept" --fast --no-cache > "$out/shared-kept.log" 2>&1 ||
    fail "shared-kept did not build: $(head -4 "$out/shared-kept.log")"
"$out/shared-kept" > "$out/shared-kept.out" 2>&1 && grep -qx "words changed in live arrays: 0" "$out/shared-kept.out" &&
    grep -qx "read back: 1094795585" "$out/shared-kept.out" || fail "shared-kept: $(cat "$out/shared-kept.out")"

# The half-precision conversions (#1302) on the CPU backend give CUDA C's bits on the 4090 for every input of the set
# (tools/probe-kernel-half.cu printed the hashes half-cpu.ab records).
"$compiler" build "$cases/half-cpu.ab" -o "$out/half-cpu" --fast --no-cache > "$out/half-cpu.log" 2>&1 ||
    fail "half-cpu did not build: $(head -4 "$out/half-cpu.log")"
"$out/half-cpu" > "$out/half-cpu.out" 2>&1 || fail "half-cpu: $(cat "$out/half-cpu.out")"

for refused in string:operation:string recursion:recursion:depth result:signature native:call:ablaLinuxSyscall launch-target:launch-bounds:helper launch-range:launch-bounds:wide array-index:array-index:index array-size:array-size:count buffers-index:buffers-index:2; do
    IFS=: read -r name rule detail <<< "$refused"
    status=0
    "$compiler" build "$cases/refused-$name.ab" -o "$out/refused-$name" --fast --no-cache > "$out/refused-$name.log" 2>&1 ||
        status=$?
    [[ $status != 0 ]] || fail "refused-$name built"
    grep -q "error\[E_SEMANTIC\]: kernel\.$rule:" "$out/refused-$name.log" ||
        fail "refused-$name: no kernel.$rule: $(head -3 "$out/refused-$name.log")"
    [[ $rule == signature ]] || grep -q "kernel\.$rule:[^ ]*$detail" "$out/refused-$name.log" ||
        fail "refused-$name: kernel.$rule does not name $detail: $(head -3 "$out/refused-$name.log")"
done

# The CUDA host types (#1139 area 13): a device and device memory made by hand are refused outside trusted code.
status=0
"$compiler" build "$cases/refused-cuda-forge.ab" -o "$out/refused-cuda-forge" --fast --no-cache > "$out/refused-cuda-forge.log" 2>&1 || status=$?
[[ $status != 0 ]] || fail "refused-cuda-forge built"
for name in CudaKernelDevice CudaKernelMemory; do
    grep -q "error\[E_SEMANTIC\]: native\.trust:.*$name" "$out/refused-cuda-forge.log" ||
        fail "refused-cuda-forge: no native.trust error naming $name: $(head -3 "$out/refused-cuda-forge.log")"
done

# The CPU backend's launch state (shared-memory slot addresses) is private to abla/kernel.
status=0
"$compiler" build "$cases/refused-cpu-state.ab" -o "$out/refused-cpu-state" --fast --no-cache > "$out/refused-cpu-state.log" 2>&1 || status=$?
[[ $status != 0 ]] || fail "refused-cpu-state built"
grep -q "error\[E_SEMANTIC\]: name\.private:kernelCpuState" "$out/refused-cpu-state.log" ||
    fail "refused-cpu-state: no name.private error naming kernelCpuState: $(head -3 "$out/refused-cpu-state.log")"

# A shared-memory count that wraps when multiplied by the element size stops the CPU backend (it gave a 4-byte buffer claiming 2^62 + 1 elements).
"$compiler" build "$cases/shared-count.ab" -o "$out/shared-count" --fast --no-cache > "$out/shared-count.log" 2>&1 ||
    fail "shared-count did not build: $(head -4 "$out/shared-count.log")"
status=0
"$out/shared-count" > "$out/shared-count.out" 2>&1 || status=$?
[[ $status != 0 ]] && grep -q "shared-count: in range ok" "$out/shared-count.out" &&
    grep -q "kernelShared: a group's shared memory has 0 to 1048576 elements" "$out/shared-count.out" &&
    ! grep -q "was accepted" "$out/shared-count.out" ||
    fail "shared-count: the huge count was not stopped (exit $status): $(head -4 "$out/shared-count.out")"

# The unchecked fast path (#143): refused outside trusted code, and stopped on the CPU backend past the end.
status=0
"$compiler" build "$cases/refused-unchecked.ab" -o "$out/refused-unchecked" --fast --no-cache > "$out/refused-unchecked.log" 2>&1 ||
    status=$?
[[ $status != 0 ]] || fail "refused-unchecked built"
grep -q "error\[E_SEMANTIC\]: native\.trust:.*loadUnchecked" "$out/refused-unchecked.log" ||
    fail "refused-unchecked: no native.trust error naming loadUnchecked: $(head -3 "$out/refused-unchecked.log")"
status=0
"$compiler" build "$cases/refused-unchecked-wide.ab" -o "$out/refused-unchecked-wide" --fast --no-cache > "$out/refused-unchecked-wide.log" 2>&1 ||
    status=$?
[[ $status != 0 ]] || fail "refused-unchecked-wide built"
grep -q "error\[E_SEMANTIC\]: native\.trust:.*loadU32x4Aligned" "$out/refused-unchecked-wide.log" ||
    fail "refused-unchecked-wide: no native.trust error naming loadU32x4Aligned: $(head -3 "$out/refused-unchecked-wide.log")"
"$compiler" build "$cases/unchecked-cpu.ab" -o "$out/unchecked-cpu" --fast --no-cache > "$out/unchecked-cpu.log" 2>&1 ||
    fail "unchecked-cpu did not build: $(head -4 "$out/unchecked-cpu.log")"
status=0
"$out/unchecked-cpu" > "$out/unchecked-cpu.out" 2>&1 || status=$?
[[ $status != 0 ]] && grep -q "unchecked-cpu: in bounds ran" "$out/unchecked-cpu.out" &&
    grep -q "loadUnchecked: index 8 outside a buffer of 8" "$out/unchecked-cpu.out" &&
    ! grep -q "past the end ran" "$out/unchecked-cpu.out" ||
    fail "unchecked-cpu: the CPU backend did not stop past the end (exit $status): $(cat "$out/unchecked-cpu.out")"
# An index near 2^63 stops each one-load form with its panic, not a fault at a wrapped address (64's review).
"$compiler" build "$cases/aligned-wrap.ab" -o "$out/aligned-wrap" --fast --no-cache > "$out/aligned-wrap.log" 2>&1 ||
    fail "aligned-wrap did not build: $(head -4 "$out/aligned-wrap.log")"
for load in load4Aligned loadU32x4Aligned-words loadU16Aligned loadU32Aligned loadU32x4Aligned; do
    status=0
    "$out/aligned-wrap" "$load" > "$out/aligned-wrap-$load.out" 2>&1 || status=$?
    [[ $status == 101 ]] && grep -q "${load%-words}: index 922337203685477580[0-9] outside a buffer" "$out/aligned-wrap-$load.out" ||
        fail "aligned-wrap $load: no panic for an index near 2^63 (exit $status): $(head -3 "$out/aligned-wrap-$load.out")"
done

# The CUDA program as an object on every machine (no libcuda needed): its PTX, a long text that more than one function
# holds, must survive the backend's per-function memory reset (#1306: the root plan read it after the reset had freed it).
"$compiler" build --project tests/cases/kernel-cuda --emit object -o "$out/kernel-cuda.o" --fast --no-cache \
    > "$out/kernel-cuda-object.log" 2>&1 || fail "kernel-cuda did not build as an object: $(tail -4 "$out/kernel-cuda-object.log")"

cuda="skipped (no libcuda.so on this machine)"
library=""
for directory in /run/opengl-driver/lib /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
    [[ -z $library && -e $directory/libcuda.so ]] && library=$directory
done
if [[ -n $library ]]; then
    LIBRARY_PATH=$library${LIBRARY_PATH:+:$LIBRARY_PATH} "$compiler" build --project tests/cases/kernel-cuda \
        -o "$out/kernel-cuda" --fast --no-cache > "$out/kernel-cuda.log" 2>&1 ||
        fail "kernel-cuda did not build: $(head -4 "$out/kernel-cuda.log")"
    status=0
    LD_LIBRARY_PATH=$library flock /tmp/abla-grad-gpu.lock timeout 120 "$out/kernel-cuda" > "$out/kernel-cuda.out" 2>&1 ||
        status=$?
    [[ $status == 0 ]] || fail "kernel-cuda exited $status: $(cat "$out/kernel-cuda.out")"
    if grep -q 'skipped' "$out/kernel-cuda.out"; then
        cuda=$(cat "$out/kernel-cuda.out")
    else
        grep -q "GPU equal to CPU true" "$out/kernel-cuda.out" && grep -q "within 1e-5 of CPU true" "$out/kernel-cuda.out" &&
            grep -q "on the GPU and the CPU true" "$out/kernel-cuda.out" &&
            grep -q "within 1e-5 of the CPU true" "$out/kernel-cuda.out" && grep -q "matvecQ8: .* true" "$out/kernel-cuda.out" &&
            grep -q "kernelExp: .*: true" "$out/kernel-cuda.out" && grep -q "kernelTanh: .*: true" "$out/kernel-cuda.out" && grep -q "kernelSigmoid: .*: true" "$out/kernel-cuda.out" && grep -q "pick4: .* true" "$out/kernel-cuda.out" && grep -q "quad4: .* true" "$out/kernel-cuda.out" && grep -q "words4: .* true" "$out/kernel-cuda.out" && grep -q "pairs2: .* true" "$out/kernel-cuda.out" &&
            grep -q "matvecQ8Fast: .* true" "$out/kernel-cuda.out" && grep -q "atomics: .* true" "$out/kernel-cuda.out" && grep -q "shuffle: .* true" "$out/kernel-cuda.out" && grep -q "subgroups: .* true" "$out/kernel-cuda.out" && grep -q "arrays: .* true, in registers true" "$out/kernel-cuda.out" && grep -q "launch: .* true" "$out/kernel-cuda.out" && grep -q "intrinsics: .* true" "$out/kernel-cuda.out" && grep -q "streams: .* true" "$out/kernel-cuda.out" && grep -q "mma: .* true $" "$out/kernel-cuda.out" &&
            grep -q "launch guards: .* true" "$out/kernel-cuda.out" && grep -q "edge indices: .* true" "$out/kernel-cuda.out" &&
            grep -q "half: .* the same bits: true" "$out/kernel-cuda.out" ||
            fail "kernel-cuda: $(cat "$out/kernel-cuda.out")"
        cuda="vadd, the NVFP4 and Q8_0 matvecs (and Q8_0 on the unchecked fast path), rmsnorm (shared memory, barriers), kernelExp, kernelTanh, kernelSigmoid, the buffer edges and the half-precision conversions agree on the GPU and the CPU"
    fi
fi
echo "kernels: the NVFP4 matvec kernel matches its reference on the CPU; the half-precision conversions give CUDA C's bits on the CPU; a string, recursion, a result, native code and an untrusted unchecked load are refused; the CPU backend stops an unchecked load past the end and keeps dynamic shared memory alive past its launch; CUDA: $cuda"
