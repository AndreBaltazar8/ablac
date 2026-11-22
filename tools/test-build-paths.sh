#!/usr/bin/env bash
# Decision #91 A: the entry and output of a compile-time build call (compilerBuildProgram, buildProgram,
# wasmBuildModule) are read against the build file's directory, like imports: the same program, at the same place,
# whether the build runs from the repository root, from the file's own directory, or from a directory with a decoy of
# the entry (the file's own wins, no warning). An entry found only from the working directory fails
# (the v0.2.65 fallback is gone, #1044).
set -euo pipefail
compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
cases=$project_root/tests/cases/build-paths/sub
out=$project_root/build/build-paths
fail() { echo "build-paths: $1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }
rm -rf "$out"; mkdir -p "$out/decoy"
built() { # $1 = directory to run from, $2 = build file, $3 = log
    rm -f "$out/child"
    (cd "$1" && "$compiler" build "$2" -o "$out/root" --fast --no-cache) > "$3" 2>&1 || fail "the build from $1 failed" "$3"
    [[ -x $out/child ]] || fail "no build/build-paths/child from $1" "$3"
    set +e; "$out/child"; local status=$?; set -e
    [[ $status == 7 ]] || fail "the child built from $1 exited $status, not 7 (wrong entry)"
}
built "$project_root" tests/cases/build-paths/sub/build.ab "$out/root.log"
built "$cases" build.ab "$out/own.log"
echo 'fun main: int = 9' > "$out/decoy/child.ab"
built "$out/decoy" "$cases/build.ab" "$out/decoy.log"
# The old working-directory reading is gone (#1044): from the root, an entry spelled from the root is not found beside
# the build file, and the build fails, whatever ABLA_BUILD_PATH_CWD says.
rm -f "$out/legacy-child"
if (cd "$project_root" && ABLA_BUILD_PATH_CWD=warn "$compiler" build tests/cases/build-paths/sub/legacy.ab -o "$out/legacy-root" \
    --fast --no-cache) > "$out/legacy.log" 2>&1; then fail "an entry spelled from the working directory built" "$out/legacy.log"; fi
[[ ! -e $out/legacy-child ]] || fail "the old reading wrote the output at the root's build/" "$out/legacy.log"
! grep -q 'BUILD_PATH_CWD' "$out/legacy.log" || fail "a working-directory diagnostic" "$out/legacy.log"
# Containment (the compile-time effect boundary): a build file's paths stay inside its project, the nearest abla.toml
# above it, else the repository root, else the working directory. ../../../../build above is inside; an escape above
# the repository is refused; an absolute path is allowed inside and refused outside; a dependency's build file, below
# its own abla.toml, cannot write into its consumer.
refused() { # $1 = build file, $2 = log
    if (cd "$project_root" && "$compiler" build "$1" -o "$out/refused" --fast --no-cache) > "$2" 2>&1; then
        fail "$1 built" "$2"
    fi
    grep -q 'error\[E_BUILD_PATH_OUTSIDE\]' "$2" || fail "$1 was refused without E_BUILD_PATH_OUTSIDE" "$2"
}
refused tests/cases/build-paths/sub/escape.ab "$out/escape.log"
[[ ! -e $project_root/../build-paths-escape ]] || fail "the escaping output was written"
call() { # $1 = entry, $2 = output: a build file's text
    printf 'import "abla/compiler"\nval built = #compilerBuildProgram("build-paths-generated", "%s", "%s", "host", "executable", true, false)\nfun main: int = if (built) 0 else 1\n' "$1" "$2"
}
call "$cases/child.ab" "$out/absolute-child" > "$out/absolute-inside.ab"
rm -f "$out/absolute-child"
(cd "$project_root" && "$compiler" build "$out/absolute-inside.ab" -o "$out/absolute-root" --fast --no-cache) > "$out/absolute-inside.log" 2>&1 ||
    fail "an absolute path inside the project was refused" "$out/absolute-inside.log"
[[ -x $out/absolute-child ]] || fail "no absolute-child" "$out/absolute-inside.log"
call "$cases/child.ab" "/nonexistent-build-paths-outside/child" > "$out/absolute-outside.ab"
refused "$out/absolute-outside.ab" "$out/absolute-outside.log"
mkdir -p "$out/consumer/.abla/packages/dependency"
printf 'name = "consumer"\nversion = "0.1.0"\nentry = "main.ab"\n' > "$out/consumer/abla.toml"
printf 'name = "dependency"\nversion = "0.1.0"\nentry = "build.ab"\n' > "$out/consumer/.abla/packages/dependency/abla.toml"
cp "$cases/child.ab" "$out/consumer/.abla/packages/dependency/child.ab"
call child.ab ../../../consumer-owned > "$out/consumer/.abla/packages/dependency/build.ab"
refused "$out/consumer/.abla/packages/dependency/build.ab" "$out/dependency.log"
[[ ! -e $out/consumer/consumer-owned ]] || fail "the dependency wrote into its consumer"
# A manifest that only grants capabilities (no `name`) bounds nothing: inside a named project, a build file below such a
# manifest may write elsewhere in the project.
mkdir -p "$out/named/caps"
printf 'name = "named"\nversion = "0.1.0"\nentry = "main.ab"\n' > "$out/named/abla.toml"
printf 'compileCapabilities = ["filesystem.write"]\n' > "$out/named/caps/abla.toml"
cp "$cases/child.ab" "$out/named/caps/child.ab"
call child.ab ../made > "$out/named/caps/build.ab"
rm -f "$out/named/made"
(cd "$project_root" && "$compiler" build "$out/named/caps/build.ab" -o "$out/named-root" --fast --no-cache) > "$out/named.log" 2>&1 ||
    fail "a capabilities-only manifest narrowed the boundary" "$out/named.log"
[[ -x $out/named/made ]] || fail "no named/made" "$out/named.log"
echo "build paths: read against the build file from the root, its directory and a decoy's; an entry spelled from the working directory fails; paths stay inside the build file's project (an escape, an absolute path outside, a dependency into its consumer: refused)"
