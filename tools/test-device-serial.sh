#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/device-serial-test"
mkdir -p "$out"
"$compiler" build "$root/tests/cases/device-serial/main.ab" -o "$out/main" --fast --no-cache
if [[ $(uname -s) == Linux ]]; then
    [[ ! -e $out/main.host.o ]]
    if nm -u "$out/main" | grep -E '(__error|tcgetattr|tcsetattr|cfmakeraw|cfsetispeed|cfsetospeed)' >/dev/null; then
        echo 'device/serial: Linux binary references Darwin termios functions' >&2
        exit 1
    fi
fi
python3 "$root/tests/cases/device-serial/session.py" "$out/main"
# The same client, driven by an Abla program on raw system calls (own termios constants, own flag decoding), on Linux and
# on macOS (where the runtime translates the Linux-numbered calls to BSD ones).
"$compiler" build "$root/tests/cases/device-serial/driver.ab" -o "$out/driver" --fast --no-cache
rm -rf "$out/driver-scratch"
mkdir -p "$out/driver-scratch"
"$out/driver" "$out/main" "$out/driver-scratch"
# Device handles are native runtime effects, not implicit compile-time I/O.
for evaluator in interp jit; do
    status=0
    ABLA_COMPILE_EVAL=$evaluator "$compiler" build \
        "$root/tests/cases/device-serial/compile-denied.ab" \
        -o "$out/denied-$evaluator" --fast --no-cache > "$out/denied-$evaluator.log" 2>&1 || status=$?
    [[ $status -ne 0 ]]
    grep -q 'compile.effect-denied:trusted.native:' "$out/denied-$evaluator.log"
done
echo 'device/serial: compile-time native effects denied in interpreter and JIT modes'
