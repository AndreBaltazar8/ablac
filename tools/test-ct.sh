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
leaks=(ct_leak_branch:0 ct_leak_callee:0 ct_leak_callee_store:0 ct_leak_index:0 ct_leak_compare:@0,@1 ct_leak_divide:0,1 ct_pbe_leak:@0)
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

read_target() { # arch, object, label (default the arch), then flags for the checker
    local arch=$1 object=$2 label=${3:-$1}
    local check="$check ${*:4}"
    local target_fixtures=("${fixtures[@]}")
    if [[ $arch == x86_64 || $arch == aarch64 ]]; then target_fixtures+=("${host_fixtures[@]}"); fi
    $check "$arch" "$object" "${target_fixtures[@]}" > "$out/$label.log" 2>&1 || {
        cat "$out/$label.log" >&2; echo "ct: a secret reached a branch or an address on $arch" >&2; exit 1
    }
    for leak in "${leaks[@]}"; do
        if $check "$arch" "$object" "$leak" > "$out/$label-leak.log" 2>&1; then
            echo "ct: the checker missed $leak on $arch" >&2; exit 1
        fi
        grep -q '^LEAK' "$out/$label-leak.log" || { cat "$out/$label-leak.log" >&2; exit 1; }
        # A rejected call/unknown instruction is not evidence that our generated
        # twin's deliberate secret-index store was detected.
        if grep -qF "$leak" "$cases/crypto-generated.leaks"; then
            grep -Eq 'secret (address|memory|index)' "$out/$label-leak.log" || {
                cat "$out/$label-leak.log" >&2; echo "ct: expected secret-index detection for $leak" >&2; exit 1;
            }
        fi
    done
    echo "ok   $label: ${#target_fixtures[@]} fixtures clean in the assembly, ${#leaks[@]} leaks caught"
}

# Secret residue: a secret a function leaves in a stack slot of its frame is a copy in memory that nothing
# wipes. Registers aren't counted. The control pair is hand-written assembly: one function spills and
# returns, the other clears its slot. Then the release fixtures are read, and tests/cases/ct/residue-known.txt
# lists the ones that leave a slot (work for the code, not the checker). Any other finding fails, and so does
# a listed fixture that comes out clean (shrink the list).
residue_read() { # object
    local object=$1
    llvm-mc -triple x86_64-linux-gnu -filetype=obj "$cases/residue-x86.s" -o "$out/residue-x86.o"
    if $check --residue x86_64 "$out/residue-x86.o" residue_left:0 > "$out/residue-left.log" 2>&1; then
        echo "ct: missed a secret left in a stack slot" >&2; exit 1
    fi
    grep -q 'secret residue' "$out/residue-left.log" || { cat "$out/residue-left.log" >&2; exit 1; }
    $check --residue x86_64 "$out/residue-x86.o" residue_wiped:0 > "$out/residue-wiped.log" 2>&1 || {
        cat "$out/residue-wiped.log" >&2; echo "ct: a wiped slot was reported" >&2; exit 1
    }
    $check --residue x86_64 "$object" "${fixtures[@]}" "${host_fixtures[@]}" > "$out/x86_64-residue.log" 2>&1 || true
    if grep '^LEAK' "$out/x86_64-residue.log" | grep -v 'secret residue'; then
        echo "ct: a finding other than residue" >&2; exit 1
    fi
    grep '^LEAK' "$out/x86_64-residue.log" | awk '{sub(":", "", $3); print $3}' | sort > "$out/x86_64-residue.found"
    if ! diff -u <(sort "$cases/residue-known.txt") "$out/x86_64-residue.found" > "$out/x86_64-residue.diff"; then
        cat "$out/x86_64-residue.diff" >&2; echo "ct: the residue findings changed (tests/cases/ct/residue-known.txt)" >&2; exit 1
    fi
    echo "ok   x86_64 residue: $(grep -c '^ok' "$out/x86_64-residue.log") fixtures leave no secret in a slot, $(wc -l < "$out/x86_64-residue.found") listed in residue-known.txt, the control pair told apart"
}

# A callee that writes a secret through an address of the caller's own frame (made by lea or by mov from rsp)
# makes the caller's slots secret; a secret passed in a stack slot is found inside the callee. Hand-written assembly,
# linked so that the calls resolve.
frame_address_read() {
    llvm-mc -triple x86_64-linux-gnu -filetype=obj "$cases/frame-address-x86.s" -o "$out/frame-address-x86.o"
    ld.lld -static -e caller_lea "$out/frame-address-x86.o" -o "$out/frame-address-x86"
    local entry
    for entry in caller_lea caller_mov caller_spill caller_push caller_calleesaved caller_stackarg; do
        if $check --follow-calls x86_64 "$out/frame-address-x86" "$entry:0" > "$out/frame-address-$entry.log" 2>&1; then
            echo "ct: missed $entry" >&2; exit 1
        fi
        grep -q '^LEAK' "$out/frame-address-$entry.log" || { cat "$out/frame-address-$entry.log" >&2; exit 1; }
    done
    echo "ok   x86_64 following calls: a secret written through a frame address, and one passed on the stack, found"
}

# A --fast build doesn't optimise, so it keeps what release builds remove: the type-tag check of every
# erased scalar conversion branches on a value copied from a secret's box, and a division by a secret
# stays a division. The checker can't tell those from payload, and they are not what the fast fixtures
# are for, so tests/cases/ct/fast-known.txt lists the fixtures that fail and the class of finding. Any other
# finding fails here, and so does a listed fixture that comes out clean (shrink the list), or one that fails
# differently. The leaks must be caught as in release, the one a call down by following that call.
# Only the x86-64 checker follows calls, and --fast builds are read for the host only (TODO.md).
fast_read() { # arch, object
    local arch=$1 object=$2 label=$1-fast
    local target_fixtures=("${fixtures[@]}" "${host_fixtures[@]}")
    $check --follow-calls "$arch" "$object" "${target_fixtures[@]}" > "$out/$label.log" 2>&1 || true
    local found=0 clean=0 name rest class
    : > "$out/$label.found"
    while read -r _ _ name rest; do
        name=${name%:}
        case $rest in
            *__ablaRuntimeRequire*) class=tag-check ;;
            "secret division"*|*"in "*": secret division"*) class=division ;;
            *) class=other ;;
        esac
        echo "$name $class" >> "$out/$label.found"
        [[ $class != other ]] || { echo "ct: $name on $label: $rest" >&2; exit 1; }
    done < <(grep '^LEAK' "$out/$label.log")
    clean=$(grep -c '^ok' "$out/$label.log" || true)
    sort -o "$out/$label.found" "$out/$label.found"
    if ! diff -u <(sort "$cases/fast-known.txt") "$out/$label.found" > "$out/$label.diff"; then
        cat "$out/$label.diff" >&2; echo "ct: the fast build's findings changed (tests/cases/ct/fast-known.txt)" >&2; exit 1
    fi
    for leak in "${leaks[@]}"; do
        if $check --follow-calls "$arch" "$object" "$leak" > "$out/$label-leak.log" 2>&1; then
            echo "ct: the checker missed $leak on $label" >&2; exit 1
        fi
        grep -q '^LEAK' "$out/$label-leak.log" || { cat "$out/$label-leak.log" >&2; exit 1; }
    done
    grep -Eq 'in [A-Za-z.]*leakBranchCallee: secret branch' <($check --follow-calls "$arch" "$object" ct_leak_callee:0 2>&1) || {
        echo "ct: the leak inside a callee wasn't found by following the call" >&2; exit 1
    }
    echo "ok   $label: $clean fixtures clean, $(wc -l < "$out/$label.found") listed in fast-known.txt, ${#leaks[@]} leaks caught, the callee leak found by following the call"
}

# --- x86-64 ---------------------------------------------------------------------------
for mode in "" --fast; do
    "$compiler" build "$cases/native.ab" -o "$out/native" --no-cache $mode
    "$out/native" || { echo "ct native ${mode:-release}: check $? failed" >&2; exit 1; }
done
"$compiler" build "$cases/object-x86.ab" -o "$out/x86.o" --emit object --no-cache
read_target x86_64 "$out/x86.o"
# A --fast build keeps every Abla call as a call. The checker follows each one into its callee, which is
# defined in the same object, with the argument secrecy the caller passes.
"$compiler" build "$cases/object-x86.ab" -o "$out/x86-fast.o" --emit object --no-cache --fast
fast_read x86_64 "$out/x86-fast.o"
frame_address_read
residue_read "$out/x86.o"

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
