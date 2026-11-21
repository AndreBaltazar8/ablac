#!/usr/bin/env bash
# The build-file-relative paths axis of the differential fuzzer (ABLA_FUZZ_BUILD_PATHS=1; decision #91 A). One program is made
# the child of a build file in a generated project; the build file's relative entry and output are chosen from the program's
# checksum (depth of the build file below the project root, the entry's form, the output's form), and the same build is run
# from the project root, from the build file's own directory, from a directory with a decoy of the entry and from the
# directory above the project. The four must give an artifact at the same place, no warning, and artifacts that behave alike
# (the same output and exit status; not the same bytes: an executable names its source file as the build was given it, so
# the same program built from two working directories differs in that string, as a plain `ablac build` does); the artifact is
# a program whose output is the axis's result, which the fuzzer compares with every other mode's. Two more cases per program:
# the old working-directory reading (W_BUILD_PATH_CWD, an error under ABLA_BUILD_PATH_CWD=error, nothing from elsewhere)
# and paths that leave the project (E_BUILD_PATH_OUTSIDE, nothing written).
#
#   build-paths.sh <compiler> <program.ab> <workdir>
#
# Writes <workdir>/result.out (the artifact's standard output, or `BUILD-PATHS-VIOLATION: what` and the log) and
# <workdir>/result.status (the artifact's exit status, 99 for a violation). Exits 0 whenever it got that far.
set -u
compiler=$1
program=$2
work=$3
case $compiler in /*) ;; *) compiler=$PWD/$compiler ;; esac
case $program in /*) ;; *) program=$PWD/$program ;; esac
case $work in /*) ;; *) work=$PWD/$work ;; esac
rm -rf "$work"
mkdir -p "$work"
log=$work/log
behaviour() { "$1" 2>&1; echo "exit status $?"; }
: > "$log"

violation() {
    { printf 'BUILD-PATHS-VIOLATION: %s\n' "$1"; tail -n 12 "$log"; } > "$work/result.out"
    echo 99 > "$work/result.status"
    exit 0
}

sum=$(cksum < "$program" | cut -d' ' -f1)
depth=$((sum % 4))
entry_form=$(((sum / 4) % 4))
output_form=$(((sum / 16) % 3))
[[ $depth == 0 && $entry_form == 2 ]] && entry_form=1

proj=$work/proj
mkdir -p "$proj"
printf 'name = "bpproj"\nversion = "0.1.0"\nentry = "main.ab"\n' > "$proj/abla.toml"
builddir=$proj
ups=
for part in $(seq 1 "$depth"); do
    builddir=$builddir/d$part
    ups=../$ups
done
mkdir -p "$builddir"

case $entry_form in
    0) entry=child.ab ;;
    1) entry=src/child.ab ;;
    2) entry=../child.ab ;;
    3) entry=./child.ab ;;
esac
case $output_form in
    0) output=out/x; artifact=$builddir/out/x ;;
    1) output=${ups}bin/x; artifact=$proj/bin/x ;;
    2) output=x; artifact=$builddir/x ;;
esac
child_source=$(cd "$builddir" && mkdir -p "$(dirname "$entry")" && cd "$(dirname "$entry")" && pwd)/$(basename "$entry")
mkdir -p "$(dirname "$child_source")"
cp "$program" "$child_source"
buildfile=$builddir/build.ab

driver() { # $1 = entry, $2 = output
    printf 'import "abla/compiler"\n\nval built = #compilerBuildProgram("bp", "%s", "%s", "host", "executable", true, false)\n\nfun main: int = if (built) 0 else 1\n' "$1" "$2"
}
driver "$entry" "$output" > "$buildfile"

# The decoy: the same relative entry, from a directory that is not the build file's, with another program.
mkdir -p "$work/elsewhere/$(dirname "$entry")"
echo 'fun main: int = 9' > "$work/elsewhere/$entry"

from_names=(root own decoy above)
from_dirs=("$proj" "$builddir" "$work/elsewhere" "$work")
from_files=("${buildfile#"$proj"/}" build.ab "$buildfile" "proj/${buildfile#"$proj"/}")
for index in 0 1 2 3; do
    rm -rf "$proj/bin" "$builddir/out" "$builddir/x"
    if ! (cd "${from_dirs[$index]}" && ABLA_BUILD_PATH_CWD=error "$compiler" build "${from_files[$index]}" -o "$work/rootbin.$index" --fast --no-cache) \
        > "$work/build.$index.log" 2>&1; then
        cat "$work/build.$index.log" >> "$log"
        violation "the build from ${from_names[$index]} failed (entry $entry, output $output, depth $depth)"
    fi
    [[ -x $artifact ]] || { cat "$work/build.$index.log" >> "$log"; violation "no artifact at $artifact from ${from_names[$index]} (entry $entry, output $output, depth $depth)"; }
    grep -q 'W_BUILD_PATH_CWD' "$work/build.$index.log" && violation "a W_BUILD_PATH_CWD warning from ${from_names[$index]}"
    behaviour "$artifact" > "$work/behaviour.$index"
    # The control (tools/test-fuzz-abla.sh): a planted difference between the builds must be reported.
    [[ ${ABLA_FUZZ_BUILD_PATHS_PLANT:-} == behaviour && $index == 2 ]] && echo planted >> "$work/behaviour.$index"
done
for index in 1 2 3; do
    cmp -s "$work/behaviour.0" "$work/behaviour.$index" ||
        violation "the artifact built from ${from_names[$index]} behaves differently from the one built from the root (entry $entry, output $output, depth $depth)"
done

# The old reading: an entry that is not next to the build file but is there from the working directory (the project root).
mkdir -p "$proj/d1" "$proj/legacy"
cp "$program" "$proj/legacy/child.ab"
legacy=$proj/d1/legacy.ab
driver legacy/child.ab legacyout/x > "$legacy"
rm -rf "$proj/legacyout"
if ! (cd "$proj" && env -u ABLA_BUILD_PATH_CWD "$compiler" build d1/legacy.ab -o "$work/legacy-root" --fast --no-cache) > "$work/legacy.log" 2>&1; then
    cat "$work/legacy.log" >> "$log"; violation "the working-directory reading no longer builds"
fi
grep -q 'warning\[W_BUILD_PATH_CWD\]' "$work/legacy.log" || { cat "$work/legacy.log" >> "$log"; violation "the old reading gave no W_BUILD_PATH_CWD"; }
[[ -x $proj/legacyout/x ]] || violation "the old reading's artifact is not at the working directory's legacyout/x"
[[ $(behaviour "$proj/legacyout/x") == "$(cat "$work/behaviour.0")" ]] || violation "the old reading's artifact behaves differently from the new reading's"
rm -rf "$proj/legacyout"
if (cd "$proj" && ABLA_BUILD_PATH_CWD=error "$compiler" build d1/legacy.ab -o "$work/legacy-strict" --fast --no-cache) > "$work/strict.log" 2>&1; then
    violation "ABLA_BUILD_PATH_CWD=error let the old reading build"
fi
grep -q 'E_BUILD_PATH_CWD' "$work/strict.log" || { cat "$work/strict.log" >> "$log"; violation "no E_BUILD_PATH_CWD under ABLA_BUILD_PATH_CWD=error"; }
[[ ! -e $proj/legacyout ]] || violation "the refused old reading wrote its artifact"
if (cd "$work" && env -u ABLA_BUILD_PATH_CWD "$compiler" build proj/d1/legacy.ab -o "$work/legacy-above" --fast --no-cache) > "$work/above.log" 2>&1; then
    violation "the old reading built from a directory it does not name"
fi
[[ ! -e $work/legacyout && ! -e $proj/legacyout ]] || violation "the old reading from elsewhere wrote an artifact"

# Paths that leave the project: refused with E_BUILD_PATH_OUTSIDE, nothing written.
mkdir -p "$work/outside"
cp "$program" "$work/outside/child.ab"
refused() { # $1 = label, $2 = entry, $3 = output, $4 = a path that must stay absent
    driver "$2" "$3" > "$proj/d1/refuse.ab"
    if (cd "$proj" && ABLA_BUILD_PATH_CWD=error "$compiler" build d1/refuse.ab -o "$work/refused" --fast --no-cache) > "$work/refused.log" 2>&1; then
        cat "$work/refused.log" >> "$log"; violation "$1 built"
    fi
    grep -q 'E_BUILD_PATH_OUTSIDE' "$work/refused.log" || { cat "$work/refused.log" >> "$log"; violation "$1 was refused without E_BUILD_PATH_OUTSIDE"; }
    [[ ! -e $4 ]] || violation "$1 wrote $4"
}
cp "$program" "$proj/d1/child.ab"
refused "an output above the project" child.ab "../../escaped-relative" "$work/escaped-relative"
refused "an absolute output outside the project" child.ab "$work/escaped-absolute" "$work/escaped-absolute"
refused "an entry above the project" ../../outside/child.ab "out/refused-x" "$proj/d1/out/refused-x"
refused "an absolute entry outside the project" "$work/outside/child.ab" "out/refused-y" "$proj/d1/out/refused-y"

"$artifact" > "$work/result.out" 2> "$work/result.err"
echo $? > "$work/result.status"
exit 0
