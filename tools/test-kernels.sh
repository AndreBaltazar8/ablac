#!/usr/bin/env bash
# `@kernel` functions (#1233, docs/language.md#gpu-kernels):
#   - abla-grad's NVFP4 matvec as a kernel on the CPU backend agrees with an independent f64 reference (nvfp4-cpu.ab);
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

for refused in string:operation:string recursion:recursion:depth result:signature native:call:ablaLinuxSyscall; do
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
            grep -q "within 1e-5 of the CPU true" "$out/kernel-cuda.out" && grep -q "matvecQ8: .* true" "$out/kernel-cuda.out" ||
            fail "kernel-cuda: $(cat "$out/kernel-cuda.out")"
        cuda="vadd, the NVFP4 and Q8_0 matvecs, rmsnorm (shared memory, barriers) and the buffer edges agree on the GPU and the CPU"
    fi
fi
echo "kernels: the NVFP4 matvec kernel matches its reference on the CPU; a string, recursion, a result and native code are refused; CUDA: $cuda"
