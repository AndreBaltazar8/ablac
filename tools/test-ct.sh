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
# The AES functions that touch a key, as written (their allocating wrappers stay outside, see the generator).
sed -n '/^\/\/ BEGIN AES KEY EXPANSION$/,/^\/\/ END AES KEY EXPANSION$/p' stdlib/abla/crypto/aes/entry.ab >> "$cases/fixture.ab"
python3 "$cases/crypto-source-fixtures.py" "$cases/crypto-generated.ab"
cat "$cases/crypto-generated.ab" >> "$cases/fixture.ab"
# Every fixture also gets a residue entry: a @noinline copy as a worker, and an export that calls it and then
# wipes the stack below it (abla/ct/scrub), the shape of a public entry point. They are read for residue below.
mkdir -p "$out/residue-cases"
cp "$cases"/*.ab "$cases"/abla.toml "$out/residue-cases/" 2>/dev/null || true
sed -i 's|^import "abla/ct"$|import "abla/ct"\nimport "abla/ct/scrub"|' "$out/residue-cases/fixture.ab"
python3 "$cases/residue-entries.py" "$out/residue-cases/fixture.ab" ctScrubStack1024 "$out/residue-cases/fixture.ab" \
    "$cases/crypto-generated.follow" > "$out/residue-entries.txt"
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

# The two bignum routines the generated twins cut at their first call (bnClear) are read whole, with that
# call followed. Without following, the same objects must be refused: the call is what is being covered.
orchestration_read() { # object
    local object=$1 specs=(ct_orch_bn_from_bytes:@2 ct_orch_bn_residue_square:@1)
    $check --follow-calls x86_64 "$object" "${specs[@]}" > "$out/x86_64-orchestration.log" 2>&1 || {
        cat "$out/x86_64-orchestration.log" >&2; echo "ct: a bignum routine and its calls" >&2; exit 1
    }
    if $check x86_64 "$object" "${specs[@]}" > "$out/x86_64-orchestration-nofollow.log" 2>&1; then
        echo "ct: the orchestration fixtures didn't need following their calls" >&2; exit 1
    fi
    echo "ok   x86_64 orchestration: bnFromBytes and bnResidueSquare read whole, their calls followed"
}

# The key-handling functions of AES (the schedule, the hardware decryption keys, the hardware block loops), which are
# functions of plain integers that stay calls. They are read whole with their calls followed: x86-64 only. The same
# specs must be refused without following (the calls are what is covered), and each has a twin with a secret-indexed
# store after the call, which has to be found for a secret address and not for a refused call.
worker_read() { # object
    local object=$1 specs=() leaks_follow=() spec
    while IFS= read -r spec; do specs+=("$spec"); done < "$cases/crypto-generated.follow"
    while IFS= read -r spec; do leaks_follow+=("$spec"); done < "$cases/crypto-generated.followleaks"
    $check --follow-calls x86_64 "$object" "${specs[@]}" > "$out/x86_64-workers.log" 2>&1 || {
        cat "$out/x86_64-workers.log" >&2; echo "ct: a secret reached a branch or an address in a key-handling function" >&2; exit 1
    }
    # Every read really went into a callee: the ok line names how many functions it followed.
    [[ $(grep -c '^ok.*following [1-9]' "$out/x86_64-workers.log") == "${#specs[@]}" ]] || {
        cat "$out/x86_64-workers.log" >&2; echo "ct: a key-handling read followed no call" >&2; exit 1
    }
    if $check x86_64 "$object" "${specs[@]}" > "$out/x86_64-workers-nofollow.log" 2>&1; then
        echo "ct: the key-handling fixtures didn't need following their calls" >&2; exit 1
    fi
    for spec in "${leaks_follow[@]}"; do
        if $check --follow-calls x86_64 "$object" "$spec" > "$out/x86_64-worker-leak.log" 2>&1; then
            echo "ct: the checker missed $spec after following the call" >&2; exit 1
        fi
        grep -Eq 'secret (address|memory|index)' "$out/x86_64-worker-leak.log" || {
            cat "$out/x86_64-worker-leak.log" >&2; echo "ct: expected secret-index detection for $spec" >&2; exit 1
        }
    done
    echo "ok   x86_64 key functions: ${#specs[@]} read with their calls followed, ${#leaks_follow[@]} leaks after them caught, refused without following"
}

# Two rules of the checker, with hand-written controls: cqto defines rdx from rax (a secret left in rdx is not a secret
# divisor), and a panic is not read but must be given nothing secret. The secret forms are found, the public ones pass.
division_read() {
    llvm-mc -triple x86_64-linux-gnu -filetype=obj "$cases/division-x86.s" -o "$out/division-x86.o"
    ld.lld -static -e div_public_rdx "$out/division-x86.o" -o "$out/division-x86"
    local entry
    for entry in div_public_rdx panic_public; do
        $check --follow-calls x86_64 "$out/division-x86" "$entry:@0" > "$out/division-$entry.log" 2>&1 || {
            cat "$out/division-$entry.log" >&2; echo "ct: $entry was reported" >&2; exit 1
        }
    done
    for entry in div_secret_rax panic_secret panic_branch; do
        if $check --follow-calls x86_64 "$out/division-x86" "$entry:@0" > "$out/division-$entry.log" 2>&1; then
            echo "ct: missed $entry" >&2; exit 1
        fi
        grep -q '^LEAK' "$out/division-$entry.log" || { cat "$out/division-$entry.log" >&2; exit 1; }
    done
    echo "ok   x86_64 checker: cqto redefines rdx, a panic takes nothing secret and is not reached by a secret branch (five controls)"
}

# Secret residue: what a secret-handling call leaves in memory that nothing wipes. The register allocator spills
# into the red zone and frames the compiler can't name, so the entry that called the work wipes the stack below
# it afterwards (abla/ct/scrub), and the checker (--residue, with --follow-calls) requires that: a slot of the
# entry's own frame that holds a secret at return, or the frames of a callee given a secret that no wipe up to
# the stack pointer reached, fail. Controls, hand-written assembly: a spill that stays, a spill that is cleared,
# a callee with no wipe after it, a wipe shorter than the callee's depth, and one that reaches it. Then every
# fixture's residue entry is read. tests/cases/ct/residue-known.txt lists what stays unwiped, with a reason;
# it is empty on x86-64. Wasm has no addressable native stack, AArch64 is wiped but not read, and Xtensa is
# compiled, not run: the wipe is a no-op there.
residue_read() {
    local entry object="$out/x86-residue.o"
    "$compiler" build "$out/residue-cases/object-x86.ab" -o "$object" --emit object --no-cache
    llvm-mc -triple x86_64-linux-gnu -filetype=obj "$cases/residue-x86.s" -o "$out/residue-x86.o"
    ld.lld -static -e residue_left "$out/residue-x86.o" -o "$out/residue-x86"
    for entry in residue_left:0 residue_unwiped:0 residue_short:0 residue_pushed:0 residue_clobbered:1 residue_above:0 \
        residue_called_short:0 residue_conditional:0; do
        if $check --follow-calls --residue x86_64 "$out/residue-x86" "$entry" > "$out/${entry%%:*}.log" 2>&1; then
            echo "ct: missed ${entry%%:*}" >&2; exit 1
        fi
        grep -Eq 'secret residue|reaches above' "$out/${entry%%:*}.log" || { cat "$out/${entry%%:*}.log" >&2; exit 1; }
    done
    for entry in residue_wiped residue_covered residue_called; do
        $check --follow-calls --residue x86_64 "$out/residue-x86" "$entry:0" > "$out/$entry.log" 2>&1 || {
            cat "$out/$entry.log" >&2; echo "ct: $entry was reported" >&2; exit 1
        }
    done
    local specs=() spec name
    for spec in "${fixtures[@]}" "${host_fixtures[@]}"; do
        name=${spec%%:*}
        grep -qx "ct_res_${name#ct_}" "$out/residue-entries.txt" || { echo "ct: no residue entry for $name" >&2; exit 1; }
        specs+=("ct_res_${name#ct_}:${spec#*:}")
    done
    $check --follow-calls --residue x86_64 "$object" "${specs[@]}" > "$out/x86_64-residue.log" 2>&1 || true
    if { grep '^LEAK' "$out/x86_64-residue.log" || true; } | grep -v 'secret residue'; then
        echo "ct: a finding other than residue" >&2; exit 1
    fi
    { grep '^LEAK' "$out/x86_64-residue.log" || true; } | awk '{sub(":", "", $3); print $3}' | sort > "$out/x86_64-residue.found"
    if ! diff -u <(grep -v '^#' "$cases/residue-known.txt" | sort) "$out/x86_64-residue.found" > "$out/x86_64-residue.diff"; then
        cat "$out/x86_64-residue.diff" >&2; echo "ct: the residue findings changed (tests/cases/ct/residue-known.txt)" >&2; exit 1
    fi
    echo "ok   x86_64 residue: ${#specs[@]} entries wipe what their work used, $(wc -l < "$out/x86_64-residue.found") unwiped, the eleven controls told apart"
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

# The real entry points, run: the 16 KiB below the stack pointer is zeroed, each public AES (every key size, and a
# 64 KiB input) and RSA private entry (2048, 3072 and 4096 bits) is called from a helper that returns, and the region
# must still be zero beneath the entry's own frame. A worker that outgrows its wipe (ctScrubStack2048 in abla/crypto/aes,
# ctScrubStack4096 in abla/crypto/rsa) fails this; the fixtures' static depth check can't reach the allocator and runtime
# frames these workers use. Three plain runs and one with a collection at every safe point (ABLA_GC_STRESS=1), the
# deterministic worst case, since a collection in the middle of an entry makes it deeper. Controls: a byte left in the
# red zone is found, and gone after ctScrubStack1024.
real_entries_run() {
    "$compiler" build "$cases/residue-run.ab" -o "$out/residue-run" --no-cache
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$out/keys-3072.pem" 2> /dev/null
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$out/keys-4096.pem" 2> /dev/null
    local run
    for run in 1 2 3; do
        "$out/residue-run" "$out/keys-3072.pem" "$out/keys-4096.pem" > "$out/residue-run.log" 2>&1 || {
            "$out/residue-run" v "$out/keys-3072.pem" "$out/keys-4096.pem" >&2
            echo "ct: a real entry point left bytes below itself (check $?)" >&2; exit 1
        }
    done
    ABLA_GC_STRESS=1 "$out/residue-run" "$out/keys-3072.pem" "$out/keys-4096.pem" > "$out/residue-run-stress.log" 2>&1 || {
        ABLA_GC_STRESS=1 "$out/residue-run" v "$out/keys-3072.pem" "$out/keys-4096.pem" >&2
        echo "ct: a real entry point left bytes below itself with a collection at every safe point" >&2; exit 1
    }
    rm -f "$out"/keys-*.pem
    echo "ok   x86_64 real entry points: AES at 128, 192 and 256 bits with a 64 KiB input, RSA at 2048, 3072 and 4096, key generation: nothing below their own frame in 16 KiB, three runs and one under GC stress"
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
            *__ablaRuntimeRequire*|*"secret branch (to trap)"*) class=tag-check ;;
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
    grep -Eq 'ct_leak_callee: in [^:]+: secret branch' <($check --follow-calls "$arch" "$object" ct_leak_callee:0 2>&1) || {
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
# -g: the object is read for secret branches, and without debug information (tools/run-tests.sh builds
# without it) the fast code differs and ct_fix_arithmetic_u32 reports a branch.
"$compiler" build "$cases/object-x86.ab" -o "$out/x86-fast.o" --emit object --no-cache --fast -g
fast_read x86_64 "$out/x86-fast.o"
frame_address_read
residue_read
real_entries_run
orchestration_read "$out/x86.o"
worker_read "$out/x86.o"
division_read

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
