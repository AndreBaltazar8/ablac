#!/usr/bin/env bash
# Flat imports are deprecated (decision #66, step 4): a build that has a module flat because of `--flat-imports` or a
# manifest's `visibility = "flat"` (or `"program"`) prints one W_FLAT_IMPORTS_DEPRECATED warning per place flat came
# from, however many modules it covers, naming the flag or the manifest; the program builds and runs as before.
# ABLA_ALLOW_FLAT_IMPORTS=1 silences it. A strict build and `--strict-imports=warn` (the migration aid) print none.
set -euo pipefail

compiler=${1:-build/ablac.bin}
# (Absolute: `ablac test` below runs in the output directory.)
[[ $compiler == */* && $compiler != /* ]] && compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/strict-imports"
output_directory="$project_root/build/flat-imports-deprecated"
rm -rf "$output_directory"
mkdir -p "$output_directory"

export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
unset ABLA_ALLOW_FLAT_IMPORTS
err="$output_directory/build.err"

fail() { echo "flat-imports-deprecated: $1"; cat "$err"; exit 1; }
warnings() { grep -c '^warning\[W_FLAT_IMPORTS_DEPRECATED\]' "$err" || true; }
runs() { # $1 = program; the flat case prints "81 x/y" and exits 42
    set +e
    output=$("$1")
    status=$?
    set -e
    [[ $status == 42 && $output == "81 x/y" ]] || fail "$1 exited with $status and printed: $output"
}

# The flag: the flat case has three modules, all flat, and one warning names the flag.
"$compiler" build "$cases/flat/main.ab" -o "$output_directory/flag" --no-cache --flat-imports > "$err" 2>&1 ||
    fail "flat/main.ab did not build with --flat-imports"
[[ $(warnings) == 1 ]] || fail "--flat-imports did not warn once"
grep -qF 'warning[W_FLAT_IMPORTS_DEPRECATED]: flat imports (--flat-imports) are deprecated and will be removed' "$err" ||
    fail "the warning does not name --flat-imports"
grep -qF 'tools/fix-imports.ab' "$err" && grep -qF 'docs/packages.md' "$err" && grep -qF 'ABLA_ALLOW_FLAT_IMPORTS=1' "$err" ||
    fail "the warning does not say how to migrate or silence it"
grep -q '^error' "$err" && fail "--flat-imports gave an error"
runs "$output_directory/flag"

# Silenced.
ABLA_ALLOW_FLAT_IMPORTS=1 "$compiler" build "$cases/flat/main.ab" -o "$output_directory/silenced" --no-cache \
    --flat-imports > "$err" 2>&1 || fail "flat/main.ab did not build silenced"
[[ $(warnings) == 0 ]] || fail "ABLA_ALLOW_FLAT_IMPORTS=1 did not silence the warning"
runs "$output_directory/silenced"

# A manifest, both spellings: one warning naming that abla.toml.
for visibility in flat program; do
    package="$output_directory/manifest-$visibility"
    cp -R "$cases/flat" "$package"
    printf 'name = "flat-%s"\nversion = "0.1.0"\nvisibility = "%s"\n' "$visibility" "$visibility" > "$package/abla.toml"
    "$compiler" build "$package/main.ab" -o "$package/program" --no-cache > "$err" 2>&1 ||
        fail "visibility = \"$visibility\" did not build"
    [[ $(warnings) == 1 ]] || fail "visibility = \"$visibility\" did not warn once"
    grep -qF "flat imports (visibility = \"$visibility\" in $package/abla.toml) are deprecated" "$err" ||
        fail "the warning does not name $package/abla.toml"
    runs "$package/program"
done

# `ablac test` of a flat program: still one.
(cd "$output_directory" && "$compiler" test --flat-imports "$cases/flat/main.ab" > "$err" 2>&1 || true)
[[ $(warnings) == 1 ]] || fail "test --flat-imports did not warn once"

# The flag warns when the build comes from the cache too (the front end doesn't run).
for round in first cached; do
    ABLA_CACHE_DIR="$output_directory/cache" "$compiler" build "$cases/flat/main.ab" -o "$output_directory/cached" \
        --flat-imports > "$err" 2>&1 || fail "flat/main.ab did not build ($round)"
    [[ $(warnings) == 1 ]] || fail "--flat-imports did not warn once ($round build)"
done

# None: strict by default, and --strict-imports=warn.
"$compiler" build "$cases/pkg/main.ab" -o "$output_directory/strict" --no-cache > "$err" 2>&1 ||
    fail "pkg/main.ab did not build"
[[ $(warnings) == 0 ]] || fail "a strict build warned"
"$compiler" build "$cases/flat/main.ab" -o "$output_directory/warn" --no-cache --strict-imports=warn > "$err" 2>&1 ||
    fail "flat/main.ab did not build with --strict-imports=warn"
[[ $(warnings) == 0 ]] || fail "--strict-imports=warn warned that flat is deprecated"

echo "flat-imports-deprecated: --flat-imports and visibility = \"flat\"/\"program\" warn once per build, ABLA_ALLOW_FLAT_IMPORTS=1 silences; strict builds and --strict-imports=warn do not"
