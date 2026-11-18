#!/usr/bin/env bash
# Import remaps: the root abla.toml's `[imports]` maps abla/math to
# abla/math/v8 for every module of the build, a linked library's (with its own
# strict manifest) included, so the lib sees V8's pow too; without the remap each module
# keeps the one it imports. A target
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

# Without it, each module keeps the abla/math it imports (#830): the lib's pow is abla/math's
# (pow(1, NaN) is 1), the program's V8's.
variant plain 'name = "import-remap-test"'
"$compiler" build "$output_directory/plain/app/main.ab" -o "$output_directory/plain-built" --no-cache
set +e
output=$("$output_directory/plain-built")
status=$?
set -e
[[ $status == 42 && $output == "number NaN 2 number" ]] ||
    { echo "import-remap: the unremapped program exited $status and printed:"; echo "$output"; exit 1; }

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

# A module that imports the remapped module sees the target: the extensions and functions it declares
# against the target's types (a class and an alias) are the program's, wherever the program is started
# from (a path relative to the working directory names the modules relative too), strict or flat.
extension_cases="$project_root/tests/cases/import-remap-extension"
compiler_path=$(realpath "$compiler")
remapped_extension() { # $1 = label, $2 = directory of the case, $3 = how the program is named
    local label=$1 directory=$2 entry=$3
    (cd "$directory/app" && "$compiler_path" build "$entry" -o "$output_directory/ext-$label" --no-cache) \
        > "$output_directory/ext-$label.err" 2>&1 ||
        { echo "import-remap: the extension case ($label) didn't build"; cat "$output_directory/ext-$label.err"; exit 1; }
    set +e
    output=$("$output_directory/ext-$label")
    status=$?
    set -e
    [[ $status == 42 && $output == "82 12 84" ]] ||
        { echo "import-remap: the extension case ($label) exited $status and printed:"; echo "$output"; exit 1; }
}
cp -R "$extension_cases" "$output_directory/ext-strict"
cp -R "$extension_cases" "$output_directory/ext-flat"
rm "$output_directory/ext-flat/shared/abla.toml"
remapped_extension strict-relative "$output_directory/ext-strict" main.ab
remapped_extension strict-absolute "$output_directory/ext-strict" "$output_directory/ext-strict/app/main.ab"
remapped_extension flat-relative "$output_directory/ext-flat" main.ab
(cd "$output_directory/ext-strict" && "$compiler_path" build app/main.ab -o "$output_directory/ext-above" --no-cache) \
    > "$output_directory/ext-above.err" 2>&1 ||
    { echo "import-remap: the extension case didn't build from its parent directory"; cat "$output_directory/ext-above.err"; exit 1; }
[[ $("$output_directory/ext-above") == "82 12 84" ]] || { echo "import-remap: the case built from its parent printed otherwise"; exit 1; }

echo "import remap: ok"
