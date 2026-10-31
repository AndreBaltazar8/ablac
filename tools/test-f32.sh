#!/usr/bin/env bash
# f32 literals, conversions and math give the same bits natively (release and
# --fast), on Wasm and at compile time; a float literal takes f32 only from its
# context, and everything else that mixes the widths stays an error.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/f32"
output_directory="$project_root/build/f32"
rm -rf "$output_directory"
mkdir -p "$output_directory"
cd "$project_root"

for mode in "" --fast; do
    "$compiler" build "$cases/native.ab" -o "$output_directory/native" --no-cache $mode
    "$output_directory/native" || {
        echo "f32 native ${mode:-release}: check $? failed" >&2
        exit 1
    }
done

"$compiler" build "$cases/compile-time.ab" -o "$output_directory/compile-time" --no-cache
"$output_directory/compile-time" || {
    echo "f32 compile time: check $? failed" >&2
    exit 1
}

"$compiler" build "$cases/build.ab" -o "$output_directory/build-driver" --no-cache
"$output_directory/build-driver"
node "$cases/run.mjs" "$output_directory/f32.wasm"

# Xtensa is compiled only: nothing here runs it. The firmware toolchain's llc is
# a wrapper that selects the static model and the CPU, as this one does.
tools_directory="$output_directory/xtensa-tools"
mkdir -p "$tools_directory"
real_llc=$(command -v llc)
cat > "$tools_directory/llc" <<EOF
#!/usr/bin/env bash
arguments=()
for argument in "\$@"; do
    [[ \$argument == -relocation-model=pic ]] && argument=-relocation-model=static
    arguments+=("\$argument")
done
exec "$real_llc" -mcpu=esp32 "\${arguments[@]}"
EOF
chmod +x "$tools_directory/llc"
PATH="$tools_directory:$PATH" "$compiler" build "$cases/xtensa.ab" \
    -o "$output_directory/xtensa.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
grep -q 'Machine: EM_XTENSA' <<<"$(llvm-readobj --file-headers "$output_directory/xtensa.o")"
# 3.14159 as the nearest f32, 0x40490FD0, little endian: the literal is in the
# object at that width, whichever way the target then multiplies it.
LC_ALL=C grep -aqP '\xD0\x0F\x49\x40' "$output_directory/xtensa.o"

# Each of these must be refused with the error named after its `//` first line.
for invalid in "$cases"/invalid-*.ab; do
    expected=$(sed -n '1s|^// *||p' "$invalid")
    set +e
    "$compiler" build "$invalid" -o "$output_directory/invalid" --no-cache --fast \
        > "$output_directory/invalid.out" 2>&1
    status=$?
    set -e
    if [[ $status -eq 0 ]] || ! grep -qF "$expected" "$output_directory/invalid.out"; then
        echo "$(basename "$invalid"): expected an error with: $expected" >&2
        cat "$output_directory/invalid.out" >&2
        exit 1
    fi
done

echo "f32: native, Wasm and compile time agree; mixed widths stay errors"
