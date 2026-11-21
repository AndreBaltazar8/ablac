#!/usr/bin/env bash
# Decision #95 A: every path compile-time code names (abla/fs reads and writes, compilerWriteFile, ...) is read against
# its source file's directory, inside its project, in both tiers alike (a native slice's file operations reach the
# same providers through the bridge). The same site, built from the
# repository root, from its own directory and from a decoy's (with a data.txt of its own), in ABLA_COMPILE_EVAL=interp
# and =jit: the same program and the same files. A write above the package is refused (E_BUILD_PATH_OUTSIDE); the
# working-directory reading builds with W_BUILD_PATH_CWD and fails under ABLA_BUILD_PATH_CWD=error.
# A library's writes for a transform or a subparser go where the file using them says, not beside the library.
set -euo pipefail
compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
tracked=$project_root/tests/cases/compile-paths
out=$project_root/build/compile-paths
fail() { echo "compile-paths: $1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }
# The builds write beside the site, so they run on a copy of the case under build/ (the tracked case is never touched).
rm -rf "$out"; mkdir -p "$out/decoy" "$out/package"
cp -R "$tracked/sub" "$out/package/sub"
package=$out/package
relative=build/compile-paths/package
printf 'decoy-data-file' > "$out/decoy/data.txt"
unset ABLA_BUILD_PATH_CWD

site() { # $1 = tier, $2 = directory to run from, $3 = the site as named from there
    local log=$out/$1-$(basename "$2").log
    rm -rf "$package/sub/out"
    (cd "$2" && ABLA_COMPILE_EVAL=$1 "$compiler" build "$3" -o "$out/site" --no-cache) > "$log" 2>&1 ||
        fail "$1 from $2 didn't build" "$log"
    set +e; "$out/site"; local status=$?; set -e
    [[ $status == 5 ]] || fail "$1 from $2: the site read $status bytes, not data.txt's 5 (another data.txt?)" "$log"
    for written in copy api; do
        [[ $(cat "$package/sub/out/$written.txt" 2>/dev/null) == hello ]] ||
            fail "$1 from $2: no sub/out/$written.txt beside the site" "$log"
    done
    [[ ! -e $2/out ]] || [[ $2 == "$package/sub" ]] || fail "$1 from $2: a write landed in the working directory" "$log"
    ! grep -q 'W_BUILD_PATH_CWD' "$log" || fail "$1 from $2: a warning" "$log"
}
for tier in interp jit; do
    site "$tier" "$project_root" $relative/sub/site.ab
    site "$tier" "$package/sub" site.ab
    site "$tier" "$out/decoy" "$package/sub/site.ab"
done

# A library's writes for a transform and a subparser are read against the file using them (sub/), not the library's.
for tier in interp jit; do
    for from in "$project_root" "$out/decoy"; do
        rm -rf "$package/sub/out" "$package/sub/lib/out"
        log=$out/library-$tier-$(basename "$from").log
        (cd "$from" && ABLA_COMPILE_EVAL=$tier "$compiler" build "$package/sub/library.ab" -o "$out/library" --no-cache) \
            > "$log" 2>&1 || fail "library under $tier from $from didn't build" "$log"
        set +e; "$out/library"; status=$?; set -e
        [[ $status == 1 ]] || fail "library under $tier from $from: the subparser's write gave $status" "$log"
        for written in transform subparser; do
            [[ $(cat "$package/sub/out/$written.txt" 2>/dev/null) == hello ]] ||
                fail "library under $tier from $from: no sub/out/$written.txt" "$log"
        done
        [[ ! -e $package/sub/lib/out ]] || fail "library under $tier from $from: a write landed beside the library" "$log"
        ! grep -q 'W_BUILD_PATH_CWD' "$log" || fail "library under $tier from $from: a warning" "$log"
    done
done

for tier in interp jit; do
    if (cd "$project_root" && ABLA_COMPILE_EVAL=$tier "$compiler" build "$relative/sub/escape.ab" \
        -o "$out/escape" --no-cache) > "$out/escape-$tier.log" 2>&1; then
        fail "$tier: a write above the package built" "$out/escape-$tier.log"
    fi
    grep -q 'E_BUILD_PATH_OUTSIDE' "$out/escape-$tier.log" || fail "$tier: no E_BUILD_PATH_OUTSIDE" "$out/escape-$tier.log"
    [[ ! -e $out/compile-paths-escape.txt ]] || fail "$tier: the escaping write happened"

    (cd "$package" && ABLA_COMPILE_EVAL=$tier "$compiler" build sub/legacy.ab -o "$out/legacy" --no-cache) \
        > "$out/legacy-$tier.log" 2>&1 || fail "$tier: the working-directory reading didn't build" "$out/legacy-$tier.log"
    set +e; "$out/legacy"; status=$?; set -e
    [[ $status == 5 ]] || fail "$tier: the legacy read gave $status" "$out/legacy-$tier.log"
    grep -q 'warning\[W_BUILD_PATH_CWD\]' "$out/legacy-$tier.log" || fail "$tier: no W_BUILD_PATH_CWD" "$out/legacy-$tier.log"
    if (cd "$package" && ABLA_BUILD_PATH_CWD=error ABLA_COMPILE_EVAL=$tier "$compiler" build sub/legacy.ab \
        -o "$out/legacy-strict" --no-cache) > "$out/strict-$tier.log" 2>&1; then
        fail "$tier: ABLA_BUILD_PATH_CWD=error let the old reading build" "$out/strict-$tier.log"
    fi
done
echo "compile paths: reads and writes against the source file from the root, its directory and a decoy's, in both tiers; an escape refused; the working-directory reading warns, and fails under the error setting"
