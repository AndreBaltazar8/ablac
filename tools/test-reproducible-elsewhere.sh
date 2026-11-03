#!/usr/bin/env bash
set -euo pipefail
# The same sources give the same executable, byte for byte, wherever they are built: another
# directory, HOME, temporary directory, time zone or locale, and any number of processors.
# (ELF: Mach-O's path has no split to depend on them, and is not compared here.)
#
#   tools/test-reproducible-elsewhere.sh [compiler]
#       Builds a generated program twice, with one worker and with seven, and compares the
#       executables and their sidecar objects: over 8 MiB of IR, the release path that splits
#       the module makes the object (and the executable of a program linking LLVM).
#   tools/test-reproducible-elsewhere.sh --self <compiler>
#       `compiler` must be the fixed point of the sources here (stage 2): rebuilds them from a
#       copy elsewhere with three workers, and compares the result with `compiler`. What a
#       release's rebuild on another machine must match. One compiler build.

self=false
if [[ ${1:-} == --self ]]; then
    self=true
    shift
fi
compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then compiler=$project_root/$compiler; fi
fail() {
    echo "reproducible build: $1" >&2
    exit 1
}

if [[ $(uname -s) == Darwin ]]; then
    echo 'reproducible build: skipped (ELF only)'
    exit 0
fi
# HOME changes below, and nix-shell's fetches are cached under it.
if [[ -z ${IN_NIX_SHELL:-} ]]; then
    arguments=("$compiler")
    if $self; then arguments=(--self "$compiler"); fi
    printf -v self_command '%q ' "${BASH_SOURCE[0]}" "${arguments[@]}"
    exec nix-shell "$project_root/shell.nix" --run "$self_command"
fi

work=$project_root/build/reproducible-elsewhere
if $self; then work=$work-self; fi
rm -rf "$work"
one=$work/one
two=$work/a/much/longer/way/to/two
mkdir -p "$one/home" "$one/tmp" "$two/home" "$two/tmp"

# build <directory> <workers> <time zone> <locale> <command...>: in `directory`, with its own
# HOME and temporary directory.
build() {
    local directory=$1 workers=$2 zone=$3 locale=$4
    shift 4
    (
        cd "$directory"
        HOME=$directory/home TMPDIR=$directory/tmp TZ=$zone LC_ALL=$locale \
            ABLA_NATIVE_JOBS=$workers "$@"
    )
}

if $self; then
    (cd "$project_root" && git ls-files -z -- src stdlib tools runtime nix shell.nix |
        tar --null -T - -cf -) | tar -xf - -C "$two"
    # (Unset: the copy's own sources, not the ones of whoever called this.)
    unset ABLA_SYSROOT ABLA_STDLIB
    build "$two" 3 Asia/Tokyo C "$two/tools/build-self-hosted-release.sh" \
        "$compiler" "$two/build/ablac" src/orc_main.ab
    cmp "$compiler" "$two/build/ablac" ||
        fail "the compiler rebuilt elsewhere differs from $compiler"
    echo 'reproducible build: the compiler rebuilt elsewhere is byte-identical'
    exit 0
fi

export ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root}
# Each function's own arithmetic keeps LLVM from folding them into one another.
generate() {
    # Unused boxed wrappers are omitted; keep enough live bodies for the
    # release module to exceed the parallel-codegen threshold.
    local count=1400 index
    for ((index = 0; index < count; index++)); do
        printf 'fun step%d(value: int, names: array<string>): int {\n' "$index"
        printf '    var total = value + %d\n' "$index"
        printf '    for (name in names) total = total + name.size * %d\n' "$((index % 97 + 2))"
        printf '    if (total %% %d == 0) total = total + names.size\n' "$((index % 89 + 3))"
        printf '    total\n}\n'
    done
    printf 'fun main: int {\n    val names: array<string> = ["a"]\n    var total = 0\n'
    for ((index = 0; index < count; index++)); do
        printf '    total = step%d(total, names) %% 1000\n' "$index"
    done
    printf '    if (total >= 0) 42 else 0\n}\n'
}
generate > "$one/main.ab"
cp "$one/main.ab" "$two/main.ab"

build "$one" 1 UTC C.UTF-8 "$compiler" build main.ab -o program --no-cache --sidecar &
first=$!
build "$two" 7 Asia/Tokyo C "$compiler" build main.ab -o program --no-cache --sidecar &
second=$!
status=0
wait "$first" || status=$?
wait "$second" || status=$?
[[ $status -eq 0 ]] || fail "a build exits with $status"
size=$(wc -c < "$one/program.ll")
[[ $size -gt 8388608 ]] || fail "the module is $size bytes of IR, too small to be split"
cmp "$one/program.o" "$two/program.o" ||
    fail "the same program's object differs with another directory, environment or worker count"
cmp "$one/program" "$two/program" ||
    fail "the same program differs with another directory, environment or worker count"
status=0
"$one/program" || status=$?
[[ $status -eq 42 ]] || fail "the program exits with $status"
echo 'reproducible build: the same program is byte-identical across directories, environments and worker counts'
