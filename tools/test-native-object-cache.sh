#!/usr/bin/env bash
# The native object cache reuses an object only for the same program built by
# the same compiler against the same standard library: a byte-distinct
# compiler, an edited standard library or another sysroot must miss.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

compiler=$1
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/native-object-cache-test"
output="$output_directory/program"
source_file="$project_root/tests/cases/bootstrap/cache-grant-text.ab"
mkdir -p "$output_directory" || exit 1
host_os=$(uname -s)

milliseconds() {
    perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
}

# Mach-O programs link the Darwin syscall adapter as their host object.
no_host_object() {
    [[ $host_os == Darwin || ! -e $output.host.o ]]
}

run_program() {
    local status
    set +e
    ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
        "$project_root/tools/run-limited.sh" "$output"
    status=$?
    set -e
    [[ $status -eq $1 ]]
}

# A hit does not regenerate LLVM: a marker left in the .ll survives it.
expect_hit() {
    rg -q '^native-object-cache-hit$' "$output.ll"
}

expect_miss() {
    if rg -q '^native-object-cache-hit$' "$output.ll"; then
        printf 'native object cache reused an object across %s\n' "$1" >&2
        return 1
    fi
}

"$compiler" build "$source_file" -o "$output" --fast || exit 1
no_host_object || exit 1

printf '%s\n' 'native-object-cache-hit' > "$output.ll"
begin=$(milliseconds)
"$compiler" build "$source_file" -o "$output" --fast || exit 1
end=$(milliseconds)
elapsed_ms=$((end - begin))
no_host_object || exit 1
expect_hit || exit 1
run_program 42 || exit 1

# A byte-distinct compiler must not reuse an object made by another compiler,
# even for identical program source. The variant behaves the same; only its
# image (an inert ELF section, or a Mach-O signature identifier) differs.
compiler_payload=$compiler
if [[ -x $compiler.bin ]]; then compiler_payload=$compiler.bin; fi
# `make_variant <path> <identity>`: a copy of the compiler whose image differs.
make_variant() {
    cp -- "$compiler_payload" "$1" || return 1
    if [[ $host_os == Darwin ]]; then
        codesign --force --sign - --identifier "$2" "$1" 2>/dev/null ||
            return 1
    else
        printf '%s\n' "$2" > "$output_directory/compiler-identity" || return 1
        llvm-objcopy --add-section \
            ".abla-cache-identity=$output_directory/compiler-identity" \
            "$1" || return 1
    fi
    if cmp -s -- "$compiler_payload" "$1"; then return 1; fi
}
compiler_variant="$output_directory/compiler-variant"
make_variant "$compiler_variant" "abla-cache-variant-$$-$RANDOM" || exit 1
printf '%s\n' 'native-object-cache-hit' > "$output.ll"
ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root} \
    "$compiler_variant" build "$source_file" -o "$output" --fast || exit 1
expect_miss 'compilers' || exit 1
run_program 42 || exit 1

# An install renames another compiler over the same path. The next build from
# that path must miss, and renaming the first compiler back must hit again: the
# key is the image, never the path it runs from.
installed="$output_directory/installed-compiler"
cp -- "$compiler_payload" "$installed.next" || exit 1
mv -f -- "$installed.next" "$installed" || exit 1
ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root} \
    "$installed" build "$source_file" -o "$output" --fast || exit 1
# (A variant no build has run yet: its image has no entries of its own.)
make_variant "$installed.next" "abla-cache-installed-$$-$RANDOM" || exit 1
mv -f -- "$installed.next" "$installed" || exit 1
printf '%s\n' 'native-object-cache-hit' > "$output.ll"
ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root} \
    "$installed" build "$source_file" -o "$output" --fast || exit 1
expect_miss 'an install over the same path' || exit 1
run_program 42 || exit 1
cp -- "$compiler_payload" "$installed.next" || exit 1
mv -f -- "$installed.next" "$installed" || exit 1
printf '%s\n' 'native-object-cache-hit' > "$output.ll"
ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root} \
    "$installed" build "$source_file" -o "$output" --fast || exit 1
expect_hit || exit 1
run_program 42 || exit 1

# The program imports nothing, but every hosted program compiles the standard
# library's runtime modules: editing one in another sysroot must miss, and so
# must the unedited copy (another sysroot's modules are other files).
sysroot="$output_directory/sysroot"
rm -rf -- "$sysroot" || exit 1
mkdir -p -- "$sysroot" || exit 1
cp -R -- "$project_root/stdlib" "$project_root/runtime" "$sysroot/" || exit 1
printf '%s\n' 'native-object-cache-hit' > "$output.ll"
ABLA_SYSROOT=$sysroot "$compiler" build "$source_file" -o "$output" --fast ||
    exit 1
expect_miss 'sysroots' || exit 1
printf '%s\n' 'native-object-cache-hit' > "$output.ll"
ABLA_SYSROOT=$sysroot "$compiler" build "$source_file" -o "$output" --fast ||
    exit 1
expect_hit || exit 1
printf '\n// An edit that changes no behavior.\n' \
    >> "$sysroot/stdlib/abla/runtime/self/entry.ab" || exit 1
printf '%s\n' 'native-object-cache-hit' > "$output.ll"
ABLA_SYSROOT=$sysroot "$compiler" build "$source_file" -o "$output" --fast ||
    exit 1
expect_miss 'standard library edits' || exit 1
run_program 42 || exit 1

# Exact bundled source, not merely the output path, selects an object.
"$compiler" build \
    "$project_root/tests/cases/modules/types-valid.ab" \
    -o "$output" --fast || exit 1
no_host_object || exit 1
run_program 7 || exit 1

printf 'native object cache: exact-source hit in %s ms; compiler, sysroot, standard library and source identity invalidated\n' \
    "$elapsed_ms"
