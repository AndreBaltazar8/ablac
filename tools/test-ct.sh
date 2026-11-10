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
sed -i 's@tests/cases/ct/@build/ct/cases/@g' "$cases/build.ab" "$cases/build-fast.ab" "$cases/aarch64-build.ab"
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
leaks=(ct_leak_branch:0 ct_leak_callee:0 ct_leak_callee_store:0 ct_leak_index:0 ct_leak_trap:0 ct_leak_compare:@0,@1 ct_leak_divide:0,1 ct_pbe_leak:@0)
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
orchestration_read() { # object, architecture (default x86_64)
    local object=$1 arch=${2:-x86_64} specs=(ct_orch_bn_from_bytes:@2 ct_orch_bn_residue_square:@1)
    $check --follow-calls "$arch" "$object" "${specs[@]}" > "$out/$arch-orchestration.log" 2>&1 || {
        cat "$out/$arch-orchestration.log" >&2; echo "ct: a bignum routine and its calls" >&2; exit 1
    }
    if $check "$arch" "$object" "${specs[@]}" > "$out/$arch-orchestration-nofollow.log" 2>&1; then
        echo "ct: the orchestration fixtures didn't need following their calls" >&2; exit 1
    fi
    echo "ok   $arch orchestration: bnFromBytes and bnResidueSquare read whole, their calls followed"
}

# The key-handling functions of AES (the schedule, the hardware decryption keys, the hardware block loops), which are
# functions of plain integers that stay calls. They are read whole with their calls followed: x86-64 only. The same
# specs must be refused without following (the calls are what is covered), and each has a twin with a secret-indexed
# store after the call, which has to be found for a secret address and not for a refused call.
worker_read() { # object, architecture (default x86_64), how many of the reads must follow a call (default all)
    local object=$1 arch=${2:-x86_64} specs=() leaks_follow=() spec
    while IFS= read -r spec; do specs+=("$spec"); done < "$cases/crypto-generated.follow"
    while IFS= read -r spec; do leaks_follow+=("$spec"); done < "$cases/crypto-generated.followleaks"
    $check --follow-calls "$arch" "$object" "${specs[@]}" > "$out/$arch-workers.log" 2>&1 || {
        cat "$out/$arch-workers.log" >&2; echo "ct: a secret reached a branch or an address in a key-handling function" >&2; exit 1
    }
    # Every read really went into a callee: the ok line names how many functions it followed.
    [[ $(grep -c '^ok.*following [1-9]' "$out/$arch-workers.log") == "${3:-${#specs[@]}}" ]] || {
        cat "$out/$arch-workers.log" >&2; echo "ct: a key-handling read followed no call" >&2; exit 1
    }
    if $check "$arch" "$object" "${specs[@]}" > "$out/$arch-workers-nofollow.log" 2>&1; then
        echo "ct: the key-handling fixtures didn't need following their calls" >&2; exit 1
    fi
    for spec in "${leaks_follow[@]}"; do
        if $check --follow-calls "$arch" "$object" "$spec" > "$out/$arch-worker-leak.log" 2>&1; then
            echo "ct: the checker missed $spec after following the call" >&2; exit 1
        fi
        grep -Eq 'secret (address|memory|index)' "$out/$arch-worker-leak.log" || {
            cat "$out/$arch-worker-leak.log" >&2; echo "ct: expected secret-index detection for $spec" >&2; exit 1
        }
    done
    echo "ok   $arch key functions: ${#specs[@]} read with their calls followed, ${#leaks_follow[@]} leaks after them caught, refused without following"
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

# The header-public pointer (`%n`): the first 32 bytes of the object it points to are public, the rest is secret. The
# clean entries read the header; the rest (payload read, a variable offset, the register overwritten, replaced on one
# path, clobbered by a call, a secret stored through it or a copy of it) must be reported. x86-64, AArch64, Wasm and Xtensa (hand
# fixtures).
header_read() {
    local arch=$1 triple=$2 file=$3 extra_reads=${4:-} extra_stores=${5:-} entry binary="$out/$3"
    [ "$arch" = xtensa ] || llvm-mc -triple "$triple" -filetype=obj "$cases/$file.s" -o "$out/$file.o"
    if [ "$arch" = xtensa ]; then
        binary="$out/$file.o"
        llvm-mc -triple xtensa -mcpu=esp32 -filetype=obj "$cases/$file.s" -o "$binary"
    elif [ "$arch" = wasm ]; then
        binary="$out/$file.wasm"
        wasm-ld --no-entry --export-all --allow-undefined -o "$binary" "$out/$file.o"
    else
        ld.lld -static -e hdr_branch "$out/$file.o" -o "$binary"
    fi
    for entry in hdr_branch hdr_loop; do
        $check "$arch" "$binary" "$entry:%0" > "$out/$file-$entry.log" 2>&1 || {
            cat "$out/$file-$entry.log" >&2; echo "ct: header entry $entry was reported on $arch" >&2; exit 1
        }
    done
    for entry in payload_branch payload_index header_indexed header_overwritten header_merge header_call header_offset $extra_reads; do
        # The call is followed, so what is reported is the header read after it, not the call.
        if $check --follow-calls "$arch" "$binary" "$entry:%0" > "$out/$file-$entry.log" 2>&1; then
            echo "ct: missed header control $entry on $arch" >&2; exit 1
        fi
        grep -q '^LEAK' "$out/$file-$entry.log" || { cat "$out/$file-$entry.log" >&2; exit 1; }
        ! grep -q ': call: ' "$out/$file-$entry.log" || { cat "$out/$file-$entry.log" >&2; exit 1; }
    done
    for entry in header_store_secret header_store_other $extra_stores; do
        if $check "$arch" "$binary" "$entry:%0,1" > "$out/$file-$entry.log" 2>&1; then
            echo "ct: missed header control $entry on $arch" >&2; exit 1
        fi
        grep -q 'LEAK.*secret stored through an object pointer' "$out/$file-$entry.log" || { cat "$out/$file-$entry.log" >&2; exit 1; }
    done
    echo "ok   $arch checker: header words of an object pointer are public (2 clean, $((9 + $(wc -w <<< "$extra_reads $extra_stores"))) controls)"
}

# The allocation entry (x86-64, AArch64, Wasm and Xtensa): a call to `abla_ct_allocate`, by whichever symbol the compiler gave its address, is not
# read, takes nothing secret, and returns a pointer to secret memory.
header_allocator() {
    local arch=$1 file=$2 secret=${3:-1}
    $check "$arch" "$out/$file" "alloc_fill:$secret" > "$out/$file-alloc_fill.log" 2>&1 || {
        cat "$out/$file-alloc_fill.log" >&2; echo "ct: filling an allocated block with a secret was reported on $arch" >&2; exit 1
    }
    if $check "$arch" "$out/$file" alloc_read: > "$out/$file-alloc_read.log" 2>&1; then
        echo "ct: a read of an allocated block was taken for public on $arch" >&2; exit 1
    fi
    grep -q '^LEAK' "$out/$file-alloc_read.log" || { cat "$out/$file-alloc_read.log" >&2; exit 1; }
    if $check "$arch" "$out/$file" alloc_secret_size:0 > "$out/$file-alloc_secret_size.log" 2>&1; then
        echo "ct: missed a secret allocation size on $arch" >&2; exit 1
    fi
    grep -q 'the allocation entry is given a secret' "$out/$file-alloc_secret_size.log" || { cat "$out/$file-alloc_secret_size.log" >&2; exit 1; }
    echo "ok   $arch checker: the allocation entry takes a public size and returns secret memory (1 clean, 2 controls)"
    # Two names at one address in one check (the entry and the symbol the compiler gave it): a dump that lists
    # them together prints the body under the last, and each must still be read.
    if [[ $arch == x86_64 ]]; then
        $check "$arch" "$out/$file" abla_ct_allocate: abla_fn_1234_5678_direct: > "$out/$file-aliases.log" 2>&1 || {
            cat "$out/$file-aliases.log" >&2; echo "ct: two names at one address were not both read on $arch" >&2; exit 1
        }
        [[ $(grep -c '^ok' "$out/$file-aliases.log") -eq 2 ]] || { cat "$out/$file-aliases.log" >&2; exit 1; }
    fi
}

# Secret residue: what a secret-handling call leaves in memory that nothing wipes. The register allocator spills
# into the red zone and frames the compiler can't name, so the entry that called the work wipes the stack below
# it afterwards (abla/ct/scrub), and the checker (--residue, with --follow-calls) requires that: a slot of the
# entry's own frame that holds a secret at return, or the frames of a callee given a secret that no wipe up to
# the stack pointer reached, fail. Controls, hand-written assembly: a spill that stays, a spill that is cleared,
# a callee with no wipe after it, a wipe shorter than the callee's depth, and one that reaches it. Then every
# fixture's residue entry is read. tests/cases/ct/residue-known.txt lists what stays unwiped, with a reason;
# it is empty on x86-64. Wasm has no addressable native stack; AArch64 (residue_a64_read) and Xtensa
# (xtensa_residue_read) are read too.
residue_read() {
    local entry object="$out/x86-residue.o"
    "$compiler" build "$out/residue-cases/object-x86.ab" -o "$object" --emit object --no-cache
    llvm-mc -triple x86_64-linux-gnu -filetype=obj "$cases/residue-x86.s" -o "$out/residue-x86.o"
    ld.lld -static -e residue_left "$out/residue-x86.o" -o "$out/residue-x86"
    for entry in residue_left:0 residue_unwiped:0 residue_short:0 residue_pushed:0 residue_clobbered:1 residue_above:0 residue_frame_secret:0 \
        residue_called_short:0 residue_conditional:0; do
        if $check --follow-calls --residue x86_64 "$out/residue-x86" "$entry" > "$out/${entry%%:*}.log" 2>&1; then
            echo "ct: missed ${entry%%:*}" >&2; exit 1
        fi
        grep -Eq 'secret residue|reaches above' "$out/${entry%%:*}.log" || { cat "$out/${entry%%:*}.log" >&2; exit 1; }
    done
    for entry in residue_wiped residue_covered residue_called residue_frame_wiped; do
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
    echo "ok   x86_64 residue: ${#specs[@]} entries wipe what their work used, $(wc -l < "$out/x86_64-residue.found") unwiped, the thirteen controls told apart"
}

# The same read on AArch64: hand-written controls (a secret left in a slot, a callee's frame unwiped, wiped short, wiped
# after the call it should cover, and wiped enough), then every fixture's residue entry from an object of the target.
residue_a64_read() {
    llvm-mc -triple aarch64-linux-gnu -filetype=obj "$cases/residue-a64.s" -o "$out/residue-a64.o"
    ld.lld -static -e residue_left "$out/residue-a64.o" -o "$out/residue-a64"
    local entry
    for entry in residue_left residue_unwiped residue_short residue_early residue_fake; do
        if $check --follow-calls --residue aarch64 "$out/residue-a64" "$entry:0" > "$out/a64-$entry.log" 2>&1; then
            echo "ct: missed $entry on aarch64" >&2; exit 1
        fi
        grep -q 'secret residue' "$out/a64-$entry.log" || { cat "$out/a64-$entry.log" >&2; exit 1; }
    done
    if $check --follow-calls --residue aarch64 "$out/residue-a64" residue_dynamic:0 > "$out/a64-residue_dynamic.log" 2>&1; then
        echo "ct: missed residue_dynamic on aarch64" >&2; exit 1
    fi
    grep -q "can't be evaluated" "$out/a64-residue_dynamic.log" || { cat "$out/a64-residue_dynamic.log" >&2; exit 1; }
    for entry in residue_wiped residue_covered; do
        $check --follow-calls --residue aarch64 "$out/residue-a64" "$entry:0" > "$out/a64-$entry.log" 2>&1 || {
            cat "$out/a64-$entry.log" >&2; echo "ct: $entry was reported on aarch64" >&2; exit 1
        }
    done
    local specs=() spec name
    for spec in "${fixtures[@]}" "${host_fixtures[@]}"; do
        name=${spec%%:*}
        specs+=("ct_res_${name#ct_}:${spec#*:}")
    done
    $check --follow-calls --residue aarch64 "$out/aarch64-residue.o" "${specs[@]}" > "$out/aarch64-residue.log" 2>&1 || true
    if { grep '^LEAK' "$out/aarch64-residue.log" || true; } | grep -v 'secret residue'; then
        echo "ct: a finding other than residue on aarch64" >&2; exit 1
    fi
    { grep '^LEAK' "$out/aarch64-residue.log" || true; } | awk '{sub(":", "", $3); print $3}' | sort > "$out/aarch64-residue.found"
    if ! diff -u <(grep -v '^#' "$cases/residue-known-aarch64.txt" | sort) "$out/aarch64-residue.found" > "$out/aarch64-residue.diff"; then
        cat "$out/aarch64-residue.diff" >&2; echo "ct: the aarch64 residue findings changed (tests/cases/ct/residue-known-aarch64.txt)" >&2; exit 1
    fi
    echo "ok   aarch64 residue: ${#specs[@]} entries wipe what their work used, $(wc -l < "$out/aarch64-residue.found") unwiped, the eight controls told apart"
}

# Secret residue on Xtensa (windowed ABI), read, not run. An Xtensa stack has no guard page, so the wipe stops at the
# limit the image's abla_ct_stack_low() gives, and does nothing in an image without it. It stores zeros from a1-16 down
# (the 16 bytes under its a1 are its caller's a0-a3 on a window overflow), and the public wipe, inlined into the entry,
# then clears the 32 bytes above that from the entry itself (ablaCtScrubSaveAreas). Hand controls first
# (residue-xtensa.s), then every fixture's residue entry from a release object and from a --fast one, each read twice:
# as an image that defines abla_ct_stack_low (what stays is listed in residue-known-xtensa*.txt) and as one that
# doesn't (--no-stack-low: what stays then is listed in residue-known-xtensa*-no-low.txt, so a clean read above can't
# be taken for coverage the image doesn't have; an entry clean in both used no more than the 32 bytes it clears
# itself). The --fast fixtures this build can't place
# (fast-known-xtensa.txt) are left out.
xtensa_residue_read() {
    local entry mode
    llvm-mc -triple xtensa -mcpu=esp32 -filetype=obj "$cases/residue-xtensa.s" -o "$out/residue-xtensa.o"
    for entry in residue_left residue_unwiped residue_short residue_no_tail residue_before residue_fake residue_kept \
        residue_secret_tail residue_covered48 residue_unbounded residue_tail_deep residue_tail_first residue_constant; do
        if $check --follow-calls --residue xtensa "$out/residue-xtensa.o" "$entry:0" > "$out/xt-$entry.log" 2>&1; then
            echo "ct: missed $entry on xtensa" >&2; exit 1
        fi
        grep -Eq 'secret residue|below the stack a call guarantees|call: ' "$out/xt-$entry.log" || {
            cat "$out/xt-$entry.log" >&2; exit 1
        }
    done
    for entry in residue_wiped residue_covered residue_kept_wiped; do
        $check --follow-calls --residue xtensa "$out/residue-xtensa.o" "$entry:0" > "$out/xt-$entry.log" 2>&1 || {
            cat "$out/xt-$entry.log" >&2; echo "ct: $entry was reported on xtensa" >&2; exit 1
        }
    done
    if $check --no-stack-low --follow-calls --residue xtensa "$out/residue-xtensa.o" residue_covered:0 \
        > "$out/xt-residue_covered-no-low.log" 2>&1; then
        echo "ct: residue_covered passed on xtensa without abla_ct_stack_low" >&2; exit 1
    fi
    local specs=() fast_specs=() spec name
    for spec in "${fixtures[@]}"; do
        name=${spec%%:*}
        specs+=("ct_res_${name#ct_}:${spec#*:}")
        grep -q "^$name " "$cases/fast-known-xtensa.txt" || fast_specs+=("ct_res_${name#ct_}:${spec#*:}")
    done
    for mode in release fast; do
        local extra=() known="$cases/residue-known-xtensa.txt" read_specs=("${specs[@]}")
        if [[ $mode == fast ]]; then
            extra=(--fast); known="$cases/residue-known-xtensa-fast.txt"; read_specs=("${fast_specs[@]}")
        fi
        abla_xtensa_test_build "$compiler" "$tools_directory" build "$out/residue-cases/object.ab" \
            -o "$out/xtensa-residue-$mode.o" --no-cache --target-triple xtensa-esp-unknown-elf --object-format elf \
            --emit object "${extra[@]}"
        $check --follow-calls --residue xtensa "$out/xtensa-residue-$mode.o" "${read_specs[@]}" \
            > "$out/xtensa-residue-$mode.log" 2>&1 || true
        if { grep '^LEAK' "$out/xtensa-residue-$mode.log" || true; } | grep -v 'secret residue'; then
            echo "ct: a finding other than residue on xtensa ($mode)" >&2; exit 1
        fi
        { grep '^LEAK' "$out/xtensa-residue-$mode.log" || true; } | awk '{sub(":", "", $3); print $3}' | sort \
            > "$out/xtensa-residue-$mode.found"
        if ! diff -u <(grep -v '^#' "$known" | sort) "$out/xtensa-residue-$mode.found" > "$out/xtensa-residue-$mode.diff"; then
            cat "$out/xtensa-residue-$mode.diff" >&2
            echo "ct: the xtensa $mode residue findings changed (${known#"$cases"/})" >&2; exit 1
        fi
        local no_low="${known%.txt}-no-low.txt"
        $check --no-stack-low --follow-calls --residue xtensa "$out/xtensa-residue-$mode.o" "${read_specs[@]}" \
            > "$out/xtensa-residue-$mode-no-low.log" 2>&1 || true
        { grep '^LEAK' "$out/xtensa-residue-$mode-no-low.log" || true; } | awk '{sub(":", "", $3); print $3}' | sort \
            > "$out/xtensa-residue-$mode-no-low.found"
        if ! diff -u <(grep -v '^#' "$no_low" | sort) "$out/xtensa-residue-$mode-no-low.found" \
            > "$out/xtensa-residue-$mode-no-low.diff"; then
            cat "$out/xtensa-residue-$mode-no-low.diff" >&2
            echo "ct: the xtensa $mode residue findings without abla_ct_stack_low changed (${no_low#"$cases"/})" >&2; exit 1
        fi
        echo "ok   xtensa residue ($mode): with abla_ct_stack_low, ${#read_specs[@]} entries read," \
            "$(wc -l < "$out/xtensa-residue-$mode.found") listed unwiped; without it," \
            "$(wc -l < "$out/xtensa-residue-$mode-no-low.found") unwiped (listed), the rest's work within the 32 bytes" \
            "the entry clears itself"
    done
    echo "ok   xtensa residue: the sixteen controls told apart, and the wipe credited only with abla_ct_stack_low"
}

# ctScrubAvailable(): true on the host (release and --fast); on Xtensa a test of the weak abla_ct_stack_low, read both
# ways: an object that doesn't define it keeps the symbol weak and undefined and compares its address at run time, and
# one that defines it folds the answer to true.
scrub_available_read() {
    local mode
    for mode in release fast; do
        local extra=()
        [[ $mode == fast ]] && extra=(--fast)
        "$compiler" build "$cases/scrub-available.ab" -o "$out/scrub-available-$mode" --no-cache "${extra[@]}"
        [[ $("$out/scrub-available-$mode") == "scrub available: true" ]] || {
            echo "ct: ctScrubAvailable() isn't true on the host ($mode)" >&2; exit 1
        }
    done
    local variant
    for variant in xtensa xtensa-defined; do
        abla_xtensa_test_build "$compiler" "$tools_directory" build "$cases/scrub-available-$variant.ab" \
            -o "$out/scrub-available-$variant.o" --no-cache --target-triple xtensa-esp-unknown-elf --object-format elf \
            --emit object
        llvm-readelf -s "$out/scrub-available-$variant.o" > "$out/scrub-available-$variant.symbols"
        llvm-objdump -d --no-show-raw-insn --mcpu=esp32 --disassemble-symbols=scrub_available \
            "$out/scrub-available-$variant.o" > "$out/scrub-available-$variant.s"
    done
    grep -Eq 'WEAK +DEFAULT +UND abla_ct_stack_low$' "$out/scrub-available-xtensa.symbols" &&
        grep -Eq '\bl32r\b' "$out/scrub-available-xtensa.s" && grep -Eq '\bbne\b' "$out/scrub-available-xtensa.s" || {
        cat "$out/scrub-available-xtensa.symbols" "$out/scrub-available-xtensa.s" >&2
        echo "ct: ctScrubAvailable() on Xtensa doesn't test the weak abla_ct_stack_low" >&2; exit 1
    }
    grep -Eq 'FUNC +GLOBAL +DEFAULT +[0-9]+ abla_ct_stack_low$' "$out/scrub-available-xtensa-defined.symbols" &&
        grep -Eq 'movi(\.n)?\s+a2, 1$' "$out/scrub-available-xtensa-defined.s" &&
        ! grep -Eq '\b(l32r|bne|beq)\b' "$out/scrub-available-xtensa-defined.s" || {
        cat "$out/scrub-available-xtensa-defined.symbols" "$out/scrub-available-xtensa-defined.s" >&2
        echo "ct: ctScrubAvailable() isn't true where the Xtensa program defines abla_ct_stack_low" >&2; exit 1
    }
    echo "ok   ctScrubAvailable: true on the host; on Xtensa the weak abla_ct_stack_low, tested without it, true with it"
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

# Frame views (tests/cases/ct/frame-view-x86.s): an unoptimised build boxes a value in a slot, its type tag public and
# its payload secret, and passes the slot's address; the checker follows what the callee reads and writes through that
# address, so the tag reads as public. Clean: the tag read, also after the callee spills and reloads the address. Found:
# a branch on the payload, a secret written over the tag, the address returned (and written through), stored in a
# global, passed on to a callee that writes, called through a register, a secret past the 64-byte view (read or
# written), a box whose tag is the secret, the caller's frame written above the callee's return address (by a mov or a
# rep stos); and a function's own store through a register copy of its slot's address.
frame_view_read() {
    llvm-mc -triple x86_64-linux-gnu -filetype=obj "$cases/frame-view-x86.s" -o "$out/frame-view-x86.o"
    ld.lld -static -e view_tag "$out/frame-view-x86.o" -o "$out/frame-view-x86"
    local entry
    for entry in view_tag view_spill; do
        $check --follow-calls x86_64 "$out/frame-view-x86" "$entry:0" > "$out/frame-view-$entry.log" 2>&1 || {
            cat "$out/frame-view-$entry.log" >&2; echo "ct: $entry was reported" >&2; exit 1
        }
    done
    for entry in view_payload view_result view_escape view_stash view_above view_passon view_indirect view_far_read \
        view_far_write view_secret_tag view_stos_above self_write; do
        if $check --follow-calls x86_64 "$out/frame-view-x86" "$entry:0" > "$out/frame-view-$entry.log" 2>&1; then
            echo "ct: missed $entry" >&2; exit 1
        fi
        grep -q '^LEAK' "$out/frame-view-$entry.log" || { cat "$out/frame-view-$entry.log" >&2; exit 1; }
    done
    echo "ok   x86_64 frame views: a boxed value's tag read as public through its slot's address, the twelve ways a secret could hide found"
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
    # Every supported shape of the password-based entries: PBES2 with a SHA-256 and a SHA-1 PRF, AES-128 and AES-256, an
    # RSA key of 2048 and of 4096 bits inside, and a PKCS#12 with a SHA-256 and a SHA-1 MAC.
    local pbe_files=() prf cipher keys
    for keys in 3072 4096; do
        for prf in hmacWithSHA256 hmacWithSHA1; do
            for cipher in aes-128-cbc aes-256-cbc; do
                openssl pkcs8 -topk8 -v2 $cipher -v2prf $prf -iter 2000 -in "$out/keys-$keys.pem" -outform DER \
                    -out "$out/keys-$keys-$prf-$cipher.p8" -passout pass:PASSWORD-MARKER-0123456789 2> /dev/null
                pbe_files+=("$out/keys-$keys-$prf-$cipher.p8")
            done
        done
        for prf in sha256 sha1; do
            openssl pkcs12 -export -inkey "$out/keys-$keys.pem" -nocerts -out "$out/keys-$keys-$prf.p12" -macalg $prf \
                -iter 2000 -certpbe AES-256-CBC -keypbe AES-256-CBC -passout pass:PASSWORD-MARKER-0123456789 2> /dev/null
            pbe_files+=("$out/keys-$keys-$prf.p12")
        done
    done
    local run files=("$out/keys-3072.pem" "$out/keys-4096.pem" "${pbe_files[@]}")
    for run in 1 2 3; do
        "$out/residue-run" "${files[@]}" > "$out/residue-run.log" 2>&1 || {
            "$out/residue-run" v "${files[@]}" >&2
            echo "ct: a real entry point left bytes below itself (check $?)" >&2; exit 1
        }
    done
    ABLA_GC_STRESS=1 "$out/residue-run" "${files[@]}" > "$out/residue-run-stress.log" 2>&1 || {
        ABLA_GC_STRESS=1 "$out/residue-run" v "${files[@]}" >&2
        echo "ct: a real entry point left bytes below itself with a collection at every safe point" >&2; exit 1
    }
    rm -f "$out"/keys-*.pem "$out"/keys-*.p8 "$out"/keys-*.p12
    echo "ok   x86_64 real entry points: AES at 128, 192 and 256 bits with a 64 KiB input, RSA at 2048, 3072 and 4096, key generation, the password entries of PBE over PKCS#8 and PKCS#12: nothing below their own frame in 16 KiB, three runs and one under GC stress"
}
# A --fast build doesn't optimise, so it keeps what release builds remove: the type-tag check of every
# erased scalar conversion branches on the tag of a secret's box, and a division by a secret stays a
# division. On x86-64 the checker reads the box through the slot's address (frame views: the tag was
# written as a constant, so it is public), and no fixture fails there; a fixture that does is listed in
# tests/cases/ct/fast-known.txt with the class of finding (empty now). Any other
# finding fails here, and so does a listed fixture that comes out clean (shrink the list), or one that fails
# differently. The leaks must be caught as in release, the one a call down by following that call.
# The x86-64 and AArch64 checkers follow calls; Wasm and Xtensa don't (TODO.md).
# How a finding of a fast build is classed. A trap is not a tag check by being a trap (ablaRuntimeTrap, unreachable
# and the no-FMA fallback emit ud2 too): the build with debug info names the function and classes by it, and a
# build without it, whose symbols are hashed, is held to the findings that build has (fast_read's third argument).
fast_class() { # finding text, whether a branch to a trap counts as a tag check, the architecture
    local arch=${3:-}
    case $1 in
        *__ablaRuntimeRequire*) echo tag-check ;;
        *"secret branch (to trap)"*) [[ $2 == trap ]] && echo tag-check || echo other ;;
        "secret division"*|*"in "*": secret division"*) echo division ;;
        # Unoptimised Xtensa code indexes arrays in its frame at offsets the checker can't place (an address
        # that is a1 plus a register), so a load or a branch after it reads as secret. Pinned per fixture by
        # fast-known-xtensa.txt, like the other classes; the leak controls below still have to be caught.
        "secret branch"*|"secret address"*) [[ $arch == xtensa ]] && echo unplaced || echo other ;;
        *) echo other ;;
    esac
}
fast_read() { # arch, object, label suffix, "trap" to class a branch to a trap as a tag check, known findings (fast-known.txt)
    local arch=$1 object=$2 label=$1-fast${3:-} trap=${4:-} known=${5:-$cases/fast-known.txt}
    local target_fixtures=("${fixtures[@]}")
    if [[ $arch == x86_64 || $arch == aarch64 ]]; then target_fixtures+=("${host_fixtures[@]}"); fi
    $check --follow-calls "$arch" "$object" "${target_fixtures[@]}" > "$out/$label.log" 2>&1 || true
    local found=0 clean=0 name rest class
    : > "$out/$label.found"
    while read -r _ _ name rest; do
        name=${name%:}
        class=$(fast_class "$rest" "$trap" "$arch")
        echo "$name $class" >> "$out/$label.found"
        [[ $class != other ]] || { echo "ct: $name on $label: $rest" >&2; exit 1; }
    done < <(grep '^LEAK' "$out/$label.log")
    clean=$(grep -c '^ok' "$out/$label.log" || true)
    sort -o "$out/$label.found" "$out/$label.found"
    if ! diff -u <(sort "$known") "$out/$label.found" > "$out/$label.diff"; then
        cat "$out/$label.diff" >&2; echo "ct: the fast build's findings changed ($known)" >&2; exit 1
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
    # A trap that is not a tag check is a finding of its own, so it can't hide in a listed fixture's class. The build
    # with debug info owns this assertion (the build without it classes any trap as a tag check and is held to the
    # findings of that one). The limit: classification is per fixture and the checker stops at its first violation, so
    # a trap-shaped leak after the tag check inside an already listed fixture hides in both builds, as it did when
    # the class came from the function's name.
    local trap_finding
    trap_finding=$($check --follow-calls "$arch" "$object" ct_leak_trap:0 2>&1 | grep '^LEAK' || true)
    [[ -n $trap_finding ]] || { echo "ct: the checker missed ct_leak_trap on $label" >&2; exit 1; }
    [[ -n $trap || $(fast_class "${trap_finding#LEAK * * }" "" "$arch") != tag-check ]] || {
        echo "ct: a secret branch to a non-tag trap was classed as a tag check on $label: $trap_finding" >&2; exit 1
    }
    echo "ok   $label: $clean fixtures clean, $(wc -l < "$out/$label.found") listed in fast-known.txt, ${#leaks[@]} leaks caught, the callee leak found by following the call"
}

# The AArch64 checker follows calls too (bl to a function of the same object, a tail call): hand-written assembly,
# with the specs listed in tests/cases/ct/follow-a64.s. The clean ones must pass; a branch, a result, a callee-saved
# register or a stack slot that holds a secret after the call must be found (the first two in the callee itself);
# recursion and an indirect call are refused; and without following the calls are refused.
a64_follow_read() {
    llvm-mc -triple aarch64-linux-gnu -filetype=obj "$cases/follow-a64.s" -o "$out/follow-a64.o"
    ld.lld -static -e follow_clean "$out/follow-a64.o" -o "$out/follow-a64"
    local spec
    for spec in follow_clean:0 follow_stale:0 follow_public:0 follow_clobber:0; do
        $check --follow-calls aarch64 "$out/follow-a64" "$spec" > "$out/follow-a64-clean.log" 2>&1 || {
            cat "$out/follow-a64-clean.log" >&2; echo "ct: $spec was reported on aarch64" >&2; exit 1
        }
        grep -q 'following [1-9]' "$out/follow-a64-clean.log" || {
            cat "$out/follow-a64-clean.log" >&2; echo "ct: $spec didn't follow its call on aarch64" >&2; exit 1
        }
        if $check aarch64 "$out/follow-a64" "$spec" > "$out/follow-a64-nofollow.log" 2>&1; then
            echo "ct: $spec passed on aarch64 without following its call" >&2; exit 1
        fi
        grep -q 'LEAK.*call:' "$out/follow-a64-nofollow.log" || { cat "$out/follow-a64-nofollow.log" >&2; exit 1; }
    done
    local expected
    for spec in follow_branch:0:'in callee_branch: secret branch' follow_tail:0:'in callee_branch: secret branch' \
        follow_result:0:'secret branch' follow_saved:0:'secret branch' follow_stack:0:'secret branch' \
        follow_stnp:0:'in callee_stnp: secret branch' \
        follow_recursive:0:'recursion into follow_recursive' follow_indirect:0:'call: blr'; do
        expected=${spec#*:*:}
        spec=${spec%:"$expected"}
        if $check --follow-calls aarch64 "$out/follow-a64" "$spec" > "$out/follow-a64-leak.log" 2>&1; then
            echo "ct: the checker missed $spec on aarch64 after following its call" >&2; exit 1
        fi
        grep -qF "$expected" "$out/follow-a64-leak.log" || {
            cat "$out/follow-a64-leak.log" >&2; echo "ct: $spec on aarch64: expected '$expected'" >&2; exit 1
        }
    done
    # One frame reached through sp and through x29 (a public slot beside the secret one is not the secret).
    for spec in alias_public:0 frame_restore:0; do
        $check aarch64 "$out/follow-a64" "$spec" > "$out/follow-a64-alias.log" 2>&1 || {
            cat "$out/follow-a64-alias.log" >&2; echo "ct: a public slot beside the secret one was reported on aarch64: $spec" >&2; exit 1
        }
    done
    # The secret slot read through x29, after an sp restored from x29, and after an sp that is no longer a known
    # distance from its entry value (which fails closed): all found.
    for spec in alias_secret:0 frame_restore_secret:0 alias_unknown_sp:0,1; do
        if $check aarch64 "$out/follow-a64" "$spec" > "$out/follow-a64-alias.log" 2>&1; then
            echo "ct: the secret slot was missed on aarch64: $spec" >&2; exit 1
        fi
        grep -q 'secret address' "$out/follow-a64-alias.log" || { cat "$out/follow-a64-alias.log" >&2; exit 1; }
    done
    echo "ok   aarch64 call following: four clean calls read, eight leaks and refusals found, the calls refused without following, sp and x29 name one frame"
}

# The Wasm checker follows calls too (`call <function index>` to a function of the same module; the arguments come off
# the operand stack with their taint, the results go back on it). Hand-written module (tests/cases/ct/follow-wasm.s,
# linked with wasm-ld), with the same shape of controls as the AArch64 ones.
wasm_follow_read() {
    llvm-mc -triple wasm32 -filetype=obj "$cases/follow-wasm.s" -o "$out/follow-wasm.o"
    wasm-ld --no-entry --export-all --allow-undefined -o "$out/follow-wasm.wasm" "$out/follow-wasm.o"
    local spec expected
    for spec in follow_clean:0 follow_stale:1 follow_public:0 follow_drop:0; do
        $check --follow-calls wasm "$out/follow-wasm.wasm" "$spec" > "$out/follow-wasm-clean.log" 2>&1 || {
            cat "$out/follow-wasm-clean.log" >&2; echo "ct: $spec was reported on wasm" >&2; exit 1
        }
        grep -q 'following [1-9]' "$out/follow-wasm-clean.log" || {
            cat "$out/follow-wasm-clean.log" >&2; echo "ct: $spec didn't follow its call on wasm" >&2; exit 1
        }
        if $check wasm "$out/follow-wasm.wasm" "$spec" > "$out/follow-wasm-nofollow.log" 2>&1; then
            echo "ct: $spec passed on wasm without following its call" >&2; exit 1
        fi
        grep -q 'LEAK.*call:' "$out/follow-wasm-nofollow.log" || { cat "$out/follow-wasm-nofollow.log" >&2; exit 1; }
    done
    for spec in follow_branch:0:'in function [0-9]*: secret branch' follow_result:0:'secret branch' \
        follow_store:0:'secret branch' follow_return_block:0:'secret branch' follow_br_return:0:'secret branch' \
        follow_br_table:0:'secret branch' \
        follow_recursive:0:'recursion into function' follow_indirect:0,1:'call: call_indirect'; do
        expected=${spec#*:*:}
        spec=${spec%:"$expected"}
        if $check --follow-calls wasm "$out/follow-wasm.wasm" "$spec" > "$out/follow-wasm-leak.log" 2>&1; then
            echo "ct: the checker missed $spec on wasm after following its call" >&2; exit 1
        fi
        grep -q "$expected" "$out/follow-wasm-leak.log" || {
            cat "$out/follow-wasm-leak.log" >&2; echo "ct: $spec on wasm: expected '$expected'" >&2; exit 1
        }
    done
    echo "ok   wasm call following: four clean calls read, eight leaks and refusals found (a result handed back by return, br or br_table included), the calls refused without following"
}

# The Xtensa checker follows calls too (windowed: `call8` rotates the window by eight, so the callee's a2 is our a10 and
# its result comes back in a10; an unlinked object names the callee in a relocation, which the checker reads, and a
# long call loads its address from a literal). tests/cases/ct/follow-xtensa.s, the same shapes as the other targets.
xtensa_follow_read() {
    llvm-mc -triple xtensa -mcpu=esp32 -filetype=obj "$cases/follow-xtensa.s" -o "$out/follow-xtensa.o"
    local spec expected
    for spec in follow_clean:0 follow_stale:1 follow_public:0 follow_clobber:0; do
        $check --follow-calls xtensa "$out/follow-xtensa.o" "$spec" > "$out/follow-xtensa-clean.log" 2>&1 || {
            cat "$out/follow-xtensa-clean.log" >&2; echo "ct: $spec was reported on xtensa" >&2; exit 1
        }
        grep -q 'following [1-9]' "$out/follow-xtensa-clean.log" || {
            cat "$out/follow-xtensa-clean.log" >&2; echo "ct: $spec didn't follow its call on xtensa" >&2; exit 1
        }
        if $check xtensa "$out/follow-xtensa.o" "$spec" > "$out/follow-xtensa-nofollow.log" 2>&1; then
            echo "ct: $spec passed on xtensa without following its call" >&2; exit 1
        fi
        grep -q 'LEAK.*call:' "$out/follow-xtensa-nofollow.log" || { cat "$out/follow-xtensa-nofollow.log" >&2; exit 1; }
    done
    for spec in follow_branch:0:'in callee_branch: secret branch' follow_result:0:'secret branch' \
        follow_saved:0:'secret branch' follow_stack:0:'secret branch' follow_shift_secret:0:'secret shift count' \
        follow_recursive:0:'recursion into follow_recursive' follow_indirect:0:'call: callx8'; do
        expected=${spec#*:*:}
        spec=${spec%:"$expected"}
        if $check --follow-calls xtensa "$out/follow-xtensa.o" "$spec" > "$out/follow-xtensa-leak.log" 2>&1; then
            echo "ct: the checker missed $spec on xtensa after following its call" >&2; exit 1
        fi
        grep -qF "$expected" "$out/follow-xtensa-leak.log" || {
            cat "$out/follow-xtensa-leak.log" >&2; echo "ct: $spec on xtensa: expected '$expected'" >&2; exit 1
        }
    done
    # A secret value shifted by a public count through the compiler-rt helper is fine.
    $check --follow-calls xtensa "$out/follow-xtensa.o" follow_shift_public:0 > "$out/follow-xtensa-clean.log" 2>&1 || {
        cat "$out/follow-xtensa-clean.log" >&2; echo "ct: a secret shifted by a public count was reported on xtensa" >&2; exit 1
    }
    echo "ok   xtensa call following: five clean calls read, seven leaks and refusals found, the calls refused without following"
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
# Without debug info the symbols are hashed. Its findings may only be renamed, never added: each one of a branch
# to a trap must be a finding the build with debug names as a tag check.
"$compiler" build "$cases/object-x86.ab" -o "$out/x86-fast-nodebug.o" --emit object --no-cache --fast --no-debug
fast_read x86_64 "$out/x86-fast-nodebug.o" -nodebug trap
cmp "$out/x86_64-fast.found" "$out/x86_64-fast-nodebug.found" || {
    echo "ct: the fast build without debug info has other findings than the one with" >&2; exit 1
}
frame_address_read
frame_view_read
residue_read
real_entries_run
orchestration_read "$out/x86.o"
worker_read "$out/x86.o"
division_read
# The crypto allocation entry stays out of line in a release object: each export of the probe module, which reaches
# the key and big-number allocations, calls the function in the section .text.abla_ct_allocate. (A function that
# reaches no allocation must not pass, so the control is `main`.) x86-64, AArch64 and Xtensa (below); an unlinked Wasm
# module has no section to mark the entry.
"$compiler" build "$cases/alloc-probe.ab" -o "$out/alloc-probe.o" --emit object --no-cache
$check --expect-allocator x86_64 "$out/alloc-probe.o" probe_bignum_allocate: probe_aes_expand: > "$out/alloc-probe.log" 2>&1 || {
    cat "$out/alloc-probe.log" >&2; echo "ct: the allocation entry is inlined or not called in a release object" >&2; exit 1
}
if $check --expect-allocator x86_64 "$out/alloc-probe.o" main: > "$out/alloc-probe-control.log" 2>&1 || ! grep -q 'main: no call to the allocation entry' "$out/alloc-probe-control.log"; then
    cat "$out/alloc-probe-control.log" >&2; echo "ct: the allocation-free control did not fail for the right reason" >&2; exit 1
fi
grep -q 'direct call sites to the entry in [2-9]' "$out/alloc-probe.log" || { cat "$out/alloc-probe.log" >&2; echo "ct: fewer than two functions call the allocation entry" >&2; exit 1; }
echo "ok   x86_64 release object: the crypto allocation entry is called out of line by the key and big-number paths (1 control)"
header_read x86_64 x86_64-linux-gnu header-x86 "straddle8 straddle16 repstos" globstore
header_read aarch64 aarch64-linux-gnu header-a64 "straddle bfi_move" globstore
header_read wasm wasm32 header-wasm straddle globstore
header_read xtensa xtensa header-xtensa "" globstore
header_allocator x86_64 header-x86
header_allocator aarch64 header-a64
header_allocator wasm header-wasm.wasm 0
header_allocator xtensa header-xtensa.o 4

# --- AArch64 --------------------------------------------------------------------------
"$compiler" build "$cases/aarch64-build.ab" -o "$out/aarch64-driver" --no-cache
llvm-mc -triple aarch64-linux-gnu -filetype=obj tests/cases/simd/aarch64-start.s -o "$out/aarch64-start.o"
ld.lld -static --no-pie -z notext "$out/aarch64.o" "$out/aarch64-start.o" -o "$out/aarch64"
qemu-aarch64 -cpu max "$out/aarch64" || { echo "ct aarch64: check $? failed" >&2; exit 1; }
read_target aarch64 "$out/aarch64.o"
# The allocation probe as an AArch64 object (built by the driver above): the same out-of-line check as x86-64.
$check --expect-allocator aarch64 "$out/aarch64-alloc-probe.o" probe_bignum_allocate: probe_aes_expand: > "$out/alloc-probe-aarch64.log" 2>&1 || {
    cat "$out/alloc-probe-aarch64.log" >&2; echo "ct: the allocation entry is inlined or not called in an AArch64 object" >&2; exit 1
}
if $check --expect-allocator aarch64 "$out/aarch64-alloc-probe.o" main: > "$out/alloc-probe-aarch64-control.log" 2>&1 || ! grep -q 'main: no call to the allocation entry' "$out/alloc-probe-aarch64-control.log"; then
    cat "$out/alloc-probe-aarch64-control.log" >&2; echo "ct: the allocation-free control did not fail for the right reason on AArch64" >&2; exit 1
fi
grep -q 'direct call sites to the entry in [2-9]' "$out/alloc-probe-aarch64.log" || { cat "$out/alloc-probe-aarch64.log" >&2; echo "ct: fewer than two functions call the allocation entry on AArch64" >&2; exit 1; }
echo "ok   aarch64 release object: the crypto allocation entry is called out of line by the key and big-number paths (1 control)"
a64_follow_read
residue_a64_read
# The bignum routines and the AES key functions, read whole on AArch64 with their calls followed.
orchestration_read "$out/aarch64.o" aarch64
worker_read "$out/aarch64.o" aarch64
# A --fast build keeps every call: the checker follows each into its callee, defined in the same object.
fast_read aarch64 "$out/aarch64-fast.o" "" "" "$cases/fast-known-aarch64.txt"

# --- Wasm: the final module ----------------------------------------------------------
"$compiler" build "$cases/build.ab" -o "$out/wasm-driver" --no-cache 2> "$out/wasm.log" || { cat "$out/wasm.log" >&2; exit 1; }
"$out/wasm-driver"
node "$cases/run.mjs" "$out/ct.wasm"
read_target wasm "$out/ct.wasm"
wasm_follow_read
# The bignum routines and the AES key functions with their calls followed (two of the seven key reads need no call
# in this module: the hardware paths have no body to call on Wasm).
orchestration_read "$out/ct.wasm" wasm
worker_read "$out/ct.wasm" wasm 5
# The --fast module keeps every call. Its inline assembly (the barrier of the constant-time primitives) builds on the
# default in-process route since the WebAssembly asm parser is registered there (tools/test-wasm-ct-barrier.sh);
# ABLA_KEEP_LLVM_TEXT is unset so that a developer shell with it set cannot hide a regression.
env -u ABLA_KEEP_LLVM_TEXT "$compiler" build "$cases/build-fast.ab" -o "$out/wasm-fast-driver" --no-cache 2> "$out/wasm-fast.log" || {
    cat "$out/wasm-fast.log" >&2; exit 1
}
fast_read wasm "$out/ct-fast.wasm" "" "" "$cases/fast-known-wasm.txt"

# --- Xtensa: read, not run ------------------------------------------------------------
tools_directory="$out/xtensa-tools"
. "$project_root/tools/xtensa-test-tools.sh"
abla_xtensa_test_prepare "$tools_directory"
abla_xtensa_test_build "$compiler" "$tools_directory" build "$cases/object.ab" -o "$out/xtensa.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
read_target xtensa "$out/xtensa.o"
# The same probe for Xtensa, whose calls name the entry by relocation against its section.
abla_xtensa_test_build "$compiler" "$tools_directory" build "$cases/alloc-probe.ab" -o "$out/alloc-probe-xtensa.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
$check --expect-allocator xtensa "$out/alloc-probe-xtensa.o" probe_bignum_allocate: probe_aes_expand: > "$out/alloc-probe-xtensa.log" 2>&1 || {
    cat "$out/alloc-probe-xtensa.log" >&2; echo "ct: the allocation entry is inlined or not called in an Xtensa object" >&2; exit 1
}
if $check --expect-allocator xtensa "$out/alloc-probe-xtensa.o" main: > "$out/alloc-probe-xtensa-control.log" 2>&1 || ! grep -q 'main: no call to the allocation entry' "$out/alloc-probe-xtensa-control.log"; then
    cat "$out/alloc-probe-xtensa-control.log" >&2; echo "ct: the allocation-free control did not fail for the right reason on Xtensa" >&2; exit 1
fi
grep -q 'direct call sites to the entry in [2-9]' "$out/alloc-probe-xtensa.log" || { cat "$out/alloc-probe-xtensa.log" >&2; echo "ct: fewer than two functions call the allocation entry on Xtensa" >&2; exit 1; }
echo "ok   xtensa release object: the crypto allocation entry is called out of line by the key and big-number paths (1 control)"
xtensa_follow_read
orchestration_read "$out/xtensa.o" xtensa
worker_read "$out/xtensa.o" xtensa
# The --fast object keeps every call, which the checker follows. 47 fixtures come out clean; the rest are in
# fast-known-xtensa.txt (class unplaced, see fast_class). Those 16 are blind in this build: the real check of the same
# source is the release read of the same fixtures above, and the 16 leak controls prove a leak is still found in
# unoptimised code wherever the frame can be placed.
abla_xtensa_test_build "$compiler" "$tools_directory" build "$cases/object.ab" -o "$out/xtensa-fast.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object --fast
fast_read xtensa "$out/xtensa-fast.o" "" "" "$cases/fast-known-xtensa.txt"
xtensa_residue_read
scrub_available_read

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
