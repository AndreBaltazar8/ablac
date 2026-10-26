#!/usr/bin/env bash
# Import remaps: the root abla.toml's `[imports]` maps abla/math to
# abla/math/v8 for every module of the build, a linked library's (with its own
# strict manifest) included, so the two don't clash; without the remap they
# do, and the clash names the imports that brought each module in. A target
# that doesn't declare what its source does publicly is
# E_IMPORT_REMAP_MISMATCH, a remap in a dependency's manifest is
# E_IMPORT_REMAP_NOT_ROOT, and a remap that no import reaches leaves the IR
# byte-identical.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/import-remap"
output_directory="$project_root/build/import-remap"
rm -rf "$output_directory"
mkdir -p "$output_directory"

export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}

# A copy of the case whose app/abla.toml is $2 (the lib's stays), in $1.
variant() {
    cp -R "$cases" "$output_directory/$1"
    printf '%s\n' "$2" > "$output_directory/$1/app/abla.toml"
}

rejected() { # $1 = source, then the texts its diagnostics must contain
    local source=$1; shift
    if "$compiler" build "$source" -o "$output_directory/invalid" --no-cache \
        > "$output_directory/rejected.err" 2>&1; then
        echo "import-remap: $source compiled"; exit 1
    fi
    for text in "$@"; do
        grep -qF -- "$text" "$output_directory/rejected.err" ||
            { echo "import-remap: $source lacks '$text'"; cat "$output_directory/rejected.err"; exit 1; }
    done
}

# The remap: the lib's pow is V8's too.
"$compiler" build "$cases/app/main.ab" -o "$output_directory/remapped" --no-cache
set +e
output=$("$output_directory/remapped")
status=$?
set -e
[[ $status == 42 && $output == "NaN NaN 2 NaN" ]] ||
    { echo "import-remap: the remapped program exited $status and printed:"; echo "$output"; exit 1; }
# `ablac run` (the JIT) loads the same graph.
set +e
output=$("$compiler" run "$cases/app/main.ab")
status=$?
set -e
[[ $status == 42 && $output == "NaN NaN 2 NaN" ]] ||
    { echo "import-remap: run exited $status and printed:"; echo "$output"; exit 1; }

# Without it, abla/math and abla/math/v8 clash.
variant plain 'name = "import-remap-test"'
rejected "$output_directory/plain/app/main.ab" "symbol.duplicate:sqrt@" \
    '/abla/math/entry.ab` is imported by `' "plain/lib/lib.ab:2:1" \
    '/abla/math/v8/entry.ab` is imported by `' "plain/app/main.ab:6:1" \
    "help: both modules' names are program-wide"
[[ $(grep -c "help: both modules' names" "$output_directory/rejected.err") == 1 ]] ||
    { echo "import-remap: the clash is explained more than once"; cat "$output_directory/rejected.err"; exit 1; }

# A target that lacks a declaration, or declares it otherwise.
variant mismatch '[imports]
"abla/math" = "./mismatch.ab"'
rejected "$output_directory/mismatch/app/main.ab" \
    'error[E_IMPORT_REMAP_MISMATCH]: `./mismatch.ab` can'"'"'t stand in for `abla/math`' \
    "/mismatch/app/abla.toml:2:1" \
    'note: `fun floor(f64): f64` differs in `./mismatch.ab`: `fun floor(int): f64`' \
    'note: `fun ceil(f64): f64` is missing from `./mismatch.ab`'

# Only the root manifest remaps.
variant nested 'name = "import-remap-test"'
printf '[imports]\n"abla/float" = "abla/float"\n' >> "$output_directory/nested/lib/abla.toml"
rejected "$output_directory/nested/app/main.ab" \
    'error[E_IMPORT_REMAP_NOT_ROOT]: only the root abla.toml may remap imports' \
    "/nested/lib/abla.toml:4:1"

# A remap no import reaches, and an empty table, change no byte.
variant same 'name = "import-remap-test"'
"$compiler" --emit-llvm "$output_directory/same/app/alone.ab" > "$output_directory/plain.ll"
cp "$cases/app/abla.toml" "$output_directory/same/app/abla.toml"
"$compiler" --emit-llvm "$output_directory/same/app/alone.ab" > "$output_directory/remapped.ll"
printf '[imports]\n' > "$output_directory/same/app/abla.toml"
"$compiler" --emit-llvm "$output_directory/same/app/alone.ab" > "$output_directory/empty.ll"
cmp "$output_directory/plain.ll" "$output_directory/remapped.ll" ||
    { echo "import-remap: an unused remap changed the IR"; exit 1; }
cmp "$output_directory/plain.ll" "$output_directory/empty.ll" ||
    { echo "import-remap: an empty [imports] changed the IR"; exit 1; }

echo "import remap: ok"
