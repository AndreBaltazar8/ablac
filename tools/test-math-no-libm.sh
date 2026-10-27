#!/usr/bin/env bash
# abla/math needs no C math library: built for every target, a program using
# each of its functions (and the rounding builtins) leaves no libm function
# undefined. Baseline x86-64 has no FMA3 or SSE4.1 instruction, so fma, floor,
# ceil, trunc and roundeven must not become library calls there.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/math-no-libm-test"
mkdir -p "$output_directory"
source="$project_root/tests/cases/math-no-libm/everything.ab"
libm='^_?(fma|fmaf|floor|ceil|trunc|round|roundeven|rint|nearbyint|fmin|fmax|fminimum|fmaximum|sqrt|fabs|sin|cos|tan|atan|atan2|exp|log|pow|hypot|fmod|copysign)$'

targets=(x86_64-linux x86_64-macos arm64-macos)
if [[ $(uname -s) != Darwin && -z ${ABLA_MACOS_SDK:-} ]]; then
    # Hosted Mach-O objects also compile the Darwin adapter, which needs SDK
    # headers. Release CI runs this check on macOS for both Mach-O targets.
    echo 'math no-libm: Mach-O requires ABLA_MACOS_SDK; checking ELF here'
    targets=(x86_64-linux)
fi
for target in "${targets[@]}"; do
    object="$output_directory/everything-$target.o"
    "$compiler" build "$source" --target "$target" --emit object -o "$object" --no-cache
    calls=$(nm -u "$object" | awk '{print $NF}' | grep -E "$libm" || true)
    if [[ -n $calls ]]; then
        echo "math no-libm: $target calls the C math library: $calls" >&2
        exit 1
    fi
done
echo "math no-libm: ok"
