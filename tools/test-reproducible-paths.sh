#!/usr/bin/env bash
# #1090: the same source built from different working directories, by a relative or an absolute path, or from a copy of the project, gives the same bytes (every file the build writes: release, --fast, -g, --backtrace, AArch64 and hosted Windows), and
# the debug information names a project's sources relative to the entry source's directory (--fast and -g builds carry it; a release build without -g has none).
# --path-prefix-map OLD=NEW rewrites the absolute names of files outside the project (the standard library's).
set -euo pipefail
# It reads the debug information, which tools/run-tests.sh (ABLA_DEBUG=0) builds without.
export ABLA_DEBUG=1
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sysroot=${ABLA_SYSROOT:-$project_root}
work=$project_root/build/reproducible-paths
rm -rf "$work"
mkdir -p "$work/p/sub"
cat > "$work/p/sub/helper.ab" <<'AB'
fun pick(xs: array<int>, index: int): int = xs[index]
AB
cat > "$work/p/main.ab" <<'AB'
import "abla/io"
import "sub/helper.ab"

fun main: int {
    val xs = [1, 2, 3]
    println("v=${pick(xs, 1)}")
    0
}
AB
cp -r "$work/p" "$work/q"
fail() { echo "reproducible paths: $*" >&2; exit 1; }
build() { # DIRECTORY SOURCE OUTPUT FLAGS...: runs the compiler in DIRECTORY on SOURCE
    local directory=$1 source=$2 output=$3
    shift 3
    (cd "$directory" && ABLA_SYSROOT="$sysroot" "$compiler" build "$source" -o "$output" --no-cache "$@") > "$output.log" 2>&1 ||
        { tail -5 "$output.log" >&2; fail "the build of $source in $directory failed"; }
}
for flags in "--fast" "-g"; do
    name=${flags//-/}
    build "$work" p/main.ab "$work/$name-relative" $flags
    build "$work/p" main.ab "$work/$name-inside" $flags
    build "$work" "$work/p/main.ab" "$work/$name-absolute" $flags
    build "$work/q" main.ab "$work/$name-copy" $flags
    build "$work/p/sub" ../main.ab "$work/$name-parent" $flags
    for other in inside absolute copy parent; do
        cmp -s "$work/$name-relative" "$work/$name-$other" ||
            fail "$flags: a build from $other differs from the one by a relative path from the project's parent"
    done
    # the debug information names the sources below the entry's directory, and the standard library's by absolute path
    lines=$(llvm-dwarfdump --debug-line "$work/$name-relative" | grep -v "file format")
    grep -q '"main.ab"' <<< "$lines" || fail "$flags: the entry source is not named main.ab: $(grep -m3 'name:' <<< "$lines")"
    grep -q 'include_directories\[ *[0-9]*\] = "sub"' <<< "$lines" || fail "$flags: helper.ab is not in the directory sub"
    ! grep -q "$work" <<< "$lines" || fail "$flags: the working or project directory is in the debug information"
done
# --path-prefix-map rewrites what is outside the project
build "$work" p/main.ab "$work/mapped" --fast --path-prefix-map "$sysroot=/abla"
mapped=$(llvm-dwarfdump --debug-line "$work/mapped" | grep -v "file format")
! grep -q "$sysroot" <<< "$mapped" || fail "--path-prefix-map left the sysroot in the debug information"
grep -q '"/abla/stdlib/' <<< "$mapped" || fail "--path-prefix-map did not name the standard library under /abla"
# Every file a build writes, for the same output path, is the same from any working directory, by a relative or an
# absolute path, and from a copy: the program and what it writes beside it (the --backtrace .debug, a cross build's
# object). Release and --backtrace builds, an AArch64 cross build, and a hosted Windows one (whose CodeView names the
# object file as llc was given it: written under its published name, not the build's temporary one).
whole() { # NAME FLAGS...: builds into $work/whole/<from>/ under one output name, compares the files
    local name=$1 from
    shift
    for from in relative inside absolute copy; do rm -rf "$work/whole/$from"; mkdir -p "$work/whole/$from"; done
    build "$work" p/main.ab "$work/whole/relative/prog" "$@"
    build "$work/p" main.ab "$work/whole/inside/prog" "$@"
    build "$work" "$work/p/main.ab" "$work/whole/absolute/prog" "$@"
    build "$work/q" main.ab "$work/whole/copy/prog" "$@"
    local files
    files=$(cd "$work/whole/relative" && find . -type f ! -name '*.log' | sort)
    [[ -n $files ]] || fail "$name: the build wrote nothing"
    for from in inside absolute copy; do
        [[ $(cd "$work/whole/$from" && find . -type f ! -name '*.log' | sort) == "$files" ]] ||
            fail "$name: the build from $from wrote other files than the one by a relative path"
        for file in $files; do
            cmp -s "$work/whole/relative/$file" "$work/whole/$from/$file" ||
                fail "$name: $file built from $from differs from the one by a relative path"
        done
    done
    echo "$name: $(wc -l <<< "$files") files the same"
}
whole release
whole backtrace --backtrace
whole aarch64-backtrace --target aarch64-linux --backtrace
whole windows-fast --target x86_64-windows --fast
whole windows-debug --target x86_64-windows -g
echo "reproducible paths: --fast and -g builds are the same from any working directory, by a relative or absolute path, and in a copy; so is every file of release, --backtrace, AArch64 and hosted Windows builds; --path-prefix-map works"
