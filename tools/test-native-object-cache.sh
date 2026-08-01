#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

compiler=$1
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/native-object-cache-test"
output="$output_directory/program"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/bootstrap/cache-grant-text.ab" \
    -o "$output" --fast
[[ ! -e $output.host.o ]]

# A cache hit must not regenerate LLVM. Keeping this marker also avoids using
# timing as a correctness assertion on slower or heavily loaded machines.
printf '%s\n' 'native-object-cache-hit' > "$output.ll"
begin=$(date +%s%N)
"$compiler" build \
    "$project_root/tests/cases/bootstrap/cache-grant-text.ab" \
    -o "$output" --fast
[[ ! -e $output.host.o ]]
end=$(date +%s%N)
elapsed_ms=$(((end - begin) / 1000000))
rg -q '^native-object-cache-hit$' "$output.ll"

set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$output"
cached_status=$?
set -e
[[ $cached_status -eq 42 ]]

# A byte-distinct compiler must not reuse an object made by another compiler,
# even for identical program source. Add an inert ELF section so behavior is
# unchanged while /proc/self/exe identity is observably different.
compiler_variant="$output_directory/compiler-variant"
compiler_identity="$output_directory/compiler-identity"
cp -- "$compiler" "$compiler_variant"
printf '%s-%s\n' "$$" "$(date +%s%N)" > "$compiler_identity"
llvm-objcopy \
    --add-section \
    ".abla-cache-identity=$compiler_identity" \
    "$compiler_variant"
printf '%s\n' 'compiler-identity-must-miss' > "$output.ll"
"$compiler_variant" build \
    "$project_root/tests/cases/bootstrap/cache-grant-text.ab" \
    -o "$output" --fast
if rg -q '^compiler-identity-must-miss$' "$output.ll"; then
    echo 'native object cache reused an object from a different compiler' >&2
    exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$output"
variant_status=$?
set -e
[[ $variant_status -eq 42 ]]

# Exact bundled source, not merely the output path, selects an object.
"$compiler" build \
    "$project_root/tests/cases/modules/types-valid.ab" \
    -o "$output" --fast
[[ ! -e $output.host.o ]]
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$output"
changed_status=$?
set -e
[[ $changed_status -eq 7 ]]

printf 'native object cache: parsed capability eligibility + exact-source hit in %s ms; compiler/source identity invalidated\n' \
    "$elapsed_ms"
