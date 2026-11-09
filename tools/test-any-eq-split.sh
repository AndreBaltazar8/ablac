#!/usr/bin/env bash
set -euo pipefail
# `==` through `any` compares erased floats by kind only in a whole program that erases a float.
# A program without one leaves the float comparison out; a program with one keeps it; a library
# object is always float-aware, since its callers are not in view.
export ABLA_KEEP_LLVM_TEXT=1

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/any-eq-split"
rm -rf "$out"
mkdir -p "$out"

# The kept LLVM text is unoptimised, so the dead float branch is still in it; what the build
# decides is the value of the policy function `__ablaRuntimeEqualFloatKinds`.
floatKinds() {
    local group
    group=$(sed -n 's/^attributes #\([0-9]*\) = .*abla.source"="__ablaRuntimeEqualFloatKinds".*/\1/p' "$1")
    awk -v group="#$group" '$0 ~ "^define .* " group " \\{" { found = 1; next } found && /ret i1/ { print $3; exit }' "$1"
}
expect() {
    local kinds
    kinds=$(floatKinds "$2")
    if [[ $kinds != "$1" ]]; then
        echo "$2: erased floats compared by kind is '$kinds', expected '$1': $3" >&2
        exit 1
    fi
}

# A no-float program: native executable and Wasm module both lack the float comparison.
"$compiler" build "$project_root/tests/cases/any-equality-split/no-floats.ab" -o "$out/plain" --no-cache
"$out/plain"
expect false "$out/plain.ll" "a program that erases no float still compares erased floats"
# Each module is built by its own driver: one build graph defines the Wasm target once.
buildModule() {
    cat > "$out/build-$1.ab" <<WASM
import "abla/wasm/build"
val built = #wasmBuildModule("any-eq-$1", "$2", "build/any-eq-split/$1.wasm", false, false)
fun main: int = if (built) 0 else 1
WASM
    (cd "$project_root" && "$compiler" build "$out/build-$1.ab" -o "$out/build-$1" --fast --no-cache &&
        "$out/build-$1")
}
buildModule plain tests/cases/any-equality-split/no-floats.ab
buildModule floats tests/cases/any-equality/floats.ab
expect false "$out/plain.wasm.ll" "a Wasm module that erases no float still compares erased floats"
expect true "$out/floats.wasm.ll" "a Wasm module that erases floats lost the float comparison"
for module in plain floats; do
    node -e '
const bytes = require("fs").readFileSync(process.argv[1]);
let memory;
const abla_host = {
    write: (fd, data, length) => length,
    exit: (code) => { throw new Error("exit " + code); },
    clock_ns: () => 0n,
    random: (data, length) => length,
};
const { exports } = new WebAssembly.Instance(new WebAssembly.Module(bytes), { abla_host });
memory = exports.memory;
const status = Number(exports.main());
if (status !== 0) { console.error(process.argv[1] + " exited " + status); process.exit(1); }
' "$out/$module.wasm"
done

# A float-erasing program keeps the comparison and runs it (tests/cases/any-equality/floats.ab
# checks the results in every mode).
"$compiler" build "$project_root/tests/cases/any-equality/floats.ab" -o "$out/floats" --no-cache
expect true "$out/floats.ll" "a program that erases floats lost the float comparison"
set +e
"$out/floats"
status=$?
set -e
test "$status" -eq 0 || { echo "floats.ab exited $status" >&2; exit 1; }

# A float that only a `#` computation erases still keeps the comparison.
"$compiler" build "$project_root/tests/cases/any-equality-split/computed-float.ab" -o "$out/computed" --no-cache
expect true "$out/computed.ll" "a program whose compile-time code erases a float lost the float comparison"
"$out/computed"

# An object stays float-aware.
"$compiler" build "$project_root/tests/cases/any-equality-split/no-floats.ab" -o "$out/plain.o" \
    --emit object --no-cache
expect true "$out/plain.o.ll" "an object build dropped the float comparison"
echo "any-eq-split ok"
