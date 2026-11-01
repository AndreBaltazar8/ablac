#!/usr/bin/env bash
# abla/ct: what its operations compute, and what they compile to. The check that matters reads the
# generated code of each fixture (tests/cases/ct/fixture.ab) on each target with tools/ct/check-asm.py:
# no conditional branch, memory index or division from a secret, and the deliberate leaks must be
# caught, on each target too.
#   run and read: x86-64 (release) and Wasm (the final module, under Node).
#   run under qemu and read: AArch64.
#   read only: Xtensa, which nothing here runs.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases=tests/cases/ct
out=build/ct
check="python3 -I tools/ct/check-asm.py"
cd "$project_root"
rm -rf "$out"
mkdir -p "$out"

fixtures=(
    ct_fix_select_u32:0,1,2 ct_fix_select_u64:0,1,2 ct_fix_select_u8:0,1,2
    ct_fix_eq_u32:0,1 ct_fix_eq_u64:0,1 ct_fix_lt_u32:0,1 ct_fix_lt_u64:0,1 ct_fix_max_u32:0,1
    ct_fix_arithmetic_u32:0,1 ct_fix_add_u64:0,1 ct_fix_sub_u64:0,1 ct_fix_mul_u64:0,1 ct_fix_nonzero_u64:0
    ct_fix_mul_wide_u32:0,1
    ct_fix_equals:@0,@1
    ct_fix_aes_encrypt:@0,@1 ct_fix_aes_decrypt:@0,@1 ct_fix_aes_padding:@0 ct_fix_ghash:@0,@1
    ct_fix_montgomery:@0,@1,@2,@3 ct_fix_add_multiple:0,@1,@2 ct_fix_lookup:0,@1,@2
    ct_fix_base64:0
)
leaks=(ct_leak_branch:0 ct_leak_index:0 ct_leak_compare:@0,@1 ct_leak_divide:0,1)

read_target() { # arch, object
    local arch=$1 object=$2
    $check "$arch" "$object" "${fixtures[@]}" > "$out/$arch.log" 2>&1 || {
        cat "$out/$arch.log" >&2; echo "ct: a secret reached a branch or an address on $arch" >&2; exit 1
    }
    for leak in "${leaks[@]}"; do
        if $check "$arch" "$object" "$leak" > "$out/$arch-leak.log" 2>&1; then
            echo "ct: the checker missed $leak on $arch" >&2; exit 1
        fi
        grep -q '^LEAK' "$out/$arch-leak.log" || { cat "$out/$arch-leak.log" >&2; exit 1; }
    done
    echo "ok   $arch: ${#fixtures[@]} fixtures clean in the assembly, ${#leaks[@]} leaks caught"
}

# --- x86-64 ---------------------------------------------------------------------------
for mode in "" --fast; do
    "$compiler" build "$cases/native.ab" -o "$out/native" $mode
    "$out/native" || { echo "ct native ${mode:-release}: check $? failed" >&2; exit 1; }
done
"$compiler" build "$cases/object-x86.ab" -o "$out/x86.o" --emit object
read_target x86_64 "$out/x86.o"

# --- AArch64 --------------------------------------------------------------------------
"$compiler" build "$cases/aarch64-build.ab" -o "$out/aarch64-driver"
llvm-mc -triple aarch64-linux-gnu -filetype=obj tests/cases/simd/aarch64-start.s -o "$out/aarch64-start.o"
ld.lld -static --no-pie -z notext "$out/aarch64.o" "$out/aarch64-start.o" -o "$out/aarch64"
qemu-aarch64 -cpu max "$out/aarch64" || { echo "ct aarch64: check $? failed" >&2; exit 1; }
read_target aarch64 "$out/aarch64.o"

# --- Wasm: the final module ----------------------------------------------------------
"$compiler" build "$cases/build.ab" -o "$out/wasm-driver" 2> "$out/wasm.log" || { cat "$out/wasm.log" >&2; exit 1; }
"$out/wasm-driver"
node "$cases/run.mjs" "$out/ct.wasm"
read_target wasm "$out/ct.wasm"

# --- Xtensa: read, not run ------------------------------------------------------------
tools_directory="$out/xtensa-tools"
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
PATH="$tools_directory:$PATH" "$compiler" build "$cases/object.ab" -o "$out/xtensa.o" \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
read_target xtensa "$out/xtensa.o"

# --- What the compiler refuses ----------------------------------------------------------
for invalid in "$cases"/invalid-*.ab; do
    expected=$(sed -n '1s|^// *||p' "$invalid")
    set +e
    "$compiler" build "$invalid" -o "$out/invalid" --fast > "$out/invalid.out" 2>&1
    status=$?
    set -e
    if [[ $status -eq 0 ]] || ! grep -qF "$expected" "$out/invalid.out"; then
        echo "$(basename "$invalid"): expected an error with: $expected" >&2
        cat "$out/invalid.out" >&2
        exit 1
    fi
done
echo "ok   refusals: $(ls "$cases"/invalid-*.ab | wc -l)"
echo "ct: ok"
