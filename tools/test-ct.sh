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
cases=build/ct/cases
out=build/ct
check="python3 -I tools/ct/check-asm.py"
cd "$project_root"
rm -rf "$out"
mkdir -p "$out"
cp -R tests/cases/ct "$cases"
# Keep the private implementation private: test the exact production source in
# the generated fixture's own module, never through a public test hook.
sed -n '/^\/\/ BEGIN RSA SECRET BIGNUM PRIMITIVES$/,/^\/\/ END RSA SECRET BIGNUM PRIMITIVES$/p' stdlib/abla/crypto/rsa/entry.ab >> "$cases/fixture.ab"
sed -n '/^\/\/ BEGIN PBE SECRET CORES$/,/^\/\/ END PBE SECRET CORES$/p' stdlib/abla/crypto/pbe/entry.ab >> "$cases/fixture.ab"
# Source-generated coverage for loops around the previously checked primitives.
# No production edits or call exemptions: see generator's scope guards.
python3 "$cases/crypto-source-fixtures.py" "$cases/crypto-generated.ab"
cat "$cases/crypto-generated.ab" >> "$cases/fixture.ab"
# Staged build drivers need the scratch fixture paths as well.
sed -i 's@tests/cases/ct/@build/ct/cases/@g' "$cases/build.ab" "$cases/aarch64-build.ab"
python3 -I tools/ct/test-check-asm.py
python3 -I tools/ct/test-source-fixtures.py

fixtures=(
    ct_fix_select_u32:0,1,2 ct_fix_select_u64:0,1,2 ct_fix_select_u8:0,1,2
    ct_fix_eq_u32:0,1 ct_fix_eq_u64:0,1 ct_fix_lt_u32:0,1 ct_fix_lt_u64:0,1 ct_fix_max_u32:0,1
    ct_fix_arithmetic_u32:0,1 ct_fix_add_u64:0,1 ct_fix_sub_u64:0,1 ct_fix_mul_u64:0,1 ct_fix_nonzero_u64:0
    ct_fix_mul_wide_u32:0,1
    ct_fix_equals:@0,@1
    ct_fix_aes_encrypt:@0,@1 ct_fix_aes_decrypt:@0,@1 ct_fix_aes_padding:@0 ct_fix_ghash:@0,@1
    ct_fix_montgomery:@0,@1,@2,@3 ct_fix_add_multiple:0,@1,@2 ct_fix_lookup:0,@1,@2
    ct_fix_rsa_pkcs1:@0 ct_fix_rsa_oaep:@0,@2
    ct_fix_rsa_implicit_length:@0 ct_fix_rsa_implicit_select:@1,@2
    ct_fix_secret_division:@0,@1 ct_fix_secret_exact:@0,@1 ct_fix_secret_reduce:@0,@1 ct_fix_secret_divsteps:@0,@1 ct_fix_secret_gcd:@0,@1 ct_fix_secret_inverse:@0,@1
    ct_fix_rsa_subtract_one:@1 ct_fix_rsa_greater:@0,@1
    ct_fix_base64:0
    ct_pbe_sha1:@0,@1,@2 ct_pbe_sha256:@0,@1,@2
    ct_pbe_hmac1:@0 ct_pbe_hmac256:@0 ct_pbe_xor1:@0 ct_pbe_xor256:@0
    ct_pbe_password_pad:@0,@1 ct_pbe_mac_compare:@0,@1
)
for width in 1 3 128; do
    fixtures+=("ct_fix_inverse_$width:@0,@1" "ct_fix_gcd_$width:@0,@1"
               "ct_fix_divsteps_$width:@0,@1" "ct_fix_wide_$width:@0,@1")
done
while IFS= read -r spec; do fixtures+=("$spec"); done < "$cases/crypto-generated.good"
# Xtensa passes later pointer parameters on the stack; its checker cannot yet
# taint those parameters, so this separate-pointer shape is read on these ABIs.
host_fixtures=(ct_fix_wide_separate:@0,@1,@2,@3,@5)
leaks=(ct_leak_branch:0 ct_leak_index:0 ct_leak_compare:@0,@1 ct_leak_divide:0,1 ct_pbe_leak:@0)
while IFS= read -r spec; do leaks+=("$spec"); done < "$cases/crypto-generated.leaks"

# Hand-written spill regressions ensure the test includes the actual assembly pattern.
llvm-mc -triple x86_64-linux-gnu -filetype=obj "$cases/pointer-spill-x86.s" -o "$out/pointer-spill-x86.o"
llvm-mc -triple aarch64-linux-gnu -filetype=obj "$cases/pointer-spill-a64.s" -o "$out/pointer-spill-a64.o"
for entry in x86_64:pointer-spill-x86 aarch64:pointer-spill-a64; do
    arch=${entry%%:*}
    object=${entry#*:}
    if $check "$arch" "$out/$object.o" spill_leak:@0 > "$out/$object.log" 2>&1; then
        echo "ct: missed $arch secret-pointer spill" >&2
        exit 1
    fi
    grep -q '^LEAK' "$out/$object.log" || { cat "$out/$object.log" >&2; exit 1; }
done
echo "ok   x86-64 and AArch64 secret-pointer spill leaks caught"

llvm-mc -triple x86_64-linux-gnu -filetype=obj "$cases/pointer-frame-x86.s" -o "$out/pointer-frame-x86.o"
llvm-mc -triple aarch64-linux-gnu -filetype=obj "$cases/pointer-frame-a64.s" -o "$out/pointer-frame-a64.o"
for entry in x86_64:pointer-frame-x86 aarch64:pointer-frame-a64; do
    arch=${entry%%:*}
    object=${entry#*:}
    if $check "$arch" "$out/$object.o" frame_leak:@0 > "$out/$object.log" 2>&1; then
        echo "ct: missed $arch general-purpose frame-register leak" >&2
        exit 1
    fi
    grep -q '^LEAK' "$out/$object.log" || { cat "$out/$object.log" >&2; exit 1; }
done
echo "ok   x86-64 and AArch64 frame-register leaks caught"

read_target() { # arch, object
    local arch=$1 object=$2
    local target_fixtures=("${fixtures[@]}")
    if [[ $arch == x86_64 || $arch == aarch64 ]]; then target_fixtures+=("${host_fixtures[@]}"); fi
    $check "$arch" "$object" "${target_fixtures[@]}" > "$out/$arch.log" 2>&1 || {
        cat "$out/$arch.log" >&2; echo "ct: a secret reached a branch or an address on $arch" >&2; exit 1
    }
    for leak in "${leaks[@]}"; do
        if $check "$arch" "$object" "$leak" > "$out/$arch-leak.log" 2>&1; then
            echo "ct: the checker missed $leak on $arch" >&2; exit 1
        fi
        grep -q '^LEAK' "$out/$arch-leak.log" || { cat "$out/$arch-leak.log" >&2; exit 1; }
        # A rejected call/unknown instruction is not evidence that our generated
        # twin's deliberate secret-index store was detected.
        if grep -qF "$leak" "$cases/crypto-generated.leaks"; then
            grep -Eq 'secret (address|memory|index)' "$out/$arch-leak.log" || {
                cat "$out/$arch-leak.log" >&2; echo "ct: expected secret-index detection for $leak" >&2; exit 1;
            }
        fi
    done
    echo "ok   $arch: ${#target_fixtures[@]} fixtures clean in the assembly, ${#leaks[@]} leaks caught"
}

# --- x86-64 ---------------------------------------------------------------------------
for mode in "" --fast; do
    "$compiler" build "$cases/native.ab" -o "$out/native" --no-cache $mode
    "$out/native" || { echo "ct native ${mode:-release}: check $? failed" >&2; exit 1; }
done
"$compiler" build "$cases/object-x86.ab" -o "$out/x86.o" --emit object --no-cache
read_target x86_64 "$out/x86.o"

# --- AArch64 --------------------------------------------------------------------------
"$compiler" build "$cases/aarch64-build.ab" -o "$out/aarch64-driver" --no-cache
llvm-mc -triple aarch64-linux-gnu -filetype=obj tests/cases/simd/aarch64-start.s -o "$out/aarch64-start.o"
ld.lld -static --no-pie -z notext "$out/aarch64.o" "$out/aarch64-start.o" -o "$out/aarch64"
qemu-aarch64 -cpu max "$out/aarch64" || { echo "ct aarch64: check $? failed" >&2; exit 1; }
read_target aarch64 "$out/aarch64.o"

# --- Wasm: the final module ----------------------------------------------------------
"$compiler" build "$cases/build.ab" -o "$out/wasm-driver" --no-cache 2> "$out/wasm.log" || { cat "$out/wasm.log" >&2; exit 1; }
"$out/wasm-driver"
node "$cases/run.mjs" "$out/ct.wasm"
read_target wasm "$out/ct.wasm"

# --- Xtensa: read, not run ------------------------------------------------------------
tools_directory="$out/xtensa-tools"
. "$project_root/tools/xtensa-test-tools.sh"
abla_xtensa_test_prepare "$tools_directory"
abla_xtensa_test_build "$compiler" "$tools_directory" build "$cases/object.ab" -o "$out/xtensa.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
read_target xtensa "$out/xtensa.o"

# --- What the compiler refuses ----------------------------------------------------------
for invalid in "$cases"/invalid-*.ab; do
    expected=$(sed -n '1s|^// *||p' "$invalid")
    set +e
    "$compiler" build "$invalid" -o "$out/invalid" --no-cache --fast > "$out/invalid.out" 2>&1
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
