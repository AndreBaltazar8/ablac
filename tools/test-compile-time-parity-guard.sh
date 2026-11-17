#!/usr/bin/env bash
# The compile-time parity set can't rot unseen (tools/test-compile-time-parity.sh; it builds nothing, so it runs in
# seconds):
#   - every case (probe or module program) has an expectation line in tests/cases/parity/expected-pass.txt for each
#     mode, interp, jit and auto (the default tier), and every line names a case: a case without one could fail
#     without anyone seeing it;
#   - every line of tests/cases/parity/negative.txt (programs whose run-time build is meant to fail, not run) names a
#     tests/cases/modules program that is still there;
#   - every standard-library module (stdlib/abla/**/entry.ab) is reached by some case, through its imports, directly or
#     not, or has a line in tests/cases/parity/uncovered-modules.txt with the reason. A line there for a module a case
#     reaches now is stale and fails, and so does a line the branch adds (against its merge base with origin/master,
#     when there is one): the list only shrinks, so a new module comes with a case that reaches it.
#
#   tools/test-compile-time-parity-guard.sh
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
expect=${PARITY_EXPECT:-tests/cases/parity/expected-pass.txt}
negative=${PARITY_NEGATIVE:-tests/cases/parity/negative.txt}
uncovered=${PARITY_UNCOVERED:-tests/cases/parity/uncovered-modules.txt}
stdlib=${PARITY_STDLIB:-stdlib}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "parity guard: $*"; failed=1; }

# The cases, as the harness lists them (negative ones left out).
PARITY_LIST_ONLY=1 PARITY_NEGATIVE="$negative" tools/test-compile-time-parity.sh >"$work/cases"
[[ -s $work/cases ]] || { echo "parity guard: the harness lists no cases"; exit 1; }

# 1. An expectation line per case and mode, and no line for anything else.
sed 's/#.*//' "$expect" | awk '$1 != "" { print $1, $2 }' | sort >"$work/lines"
for mode in interp jit auto; do awk -v m="$mode" '{ print m, $2 }' "$work/cases"; done | sort >"$work/wanted"
while read -r line; do fail "no expectation line: $line (add \"$line [<status>]\" to $expect)"; done \
    < <(comm -23 "$work/wanted" "$work/lines")
while read -r line; do fail "$expect has a line for no case: $line"; done \
    < <(comm -13 "$work/wanted" <(sort -u "$work/lines"))
while read -r line; do fail "$expect lists twice: $line"; done < <(uniq -d "$work/lines")

# 2. The negative cases are still there.
while read -r name _; do
    [[ -f tests/cases/modules/${name#module/}.ab ]] || fail "$negative names $name, which is gone"
done < <(sed 's/#.*//' "$negative" | awk '$1 != ""')

# 3. The standard-library modules the cases reach: from each case's source (and a probe's directory), every import,
# followed through the files it names; with the runtime every program has, and abla/io, which the harness's probe
# programs import. A module is its entry.ab.
resolve() { # file spec: prints the file an import names, if it exists
    local file=$1 spec=$2 target
    case $spec in
        abla/*) target=$stdlib/$spec/entry.ab ;;
        *) target=$(dirname "$file")/$spec ;;
    esac
    [[ -f $target ]] && realpath -m "$target"
    return 0
}
pending=("$(realpath -m "$stdlib/abla/runtime/self/entry.ab")" "$(realpath -m "$stdlib/abla/io/entry.ab")")
while read -r kind _ source; do
    pending+=("$(realpath -m "$source")")
    if [[ $kind == probe && $(basename "$source") == main.ab ]]; then
        for file in "$(dirname "$source")"/*.ab; do pending+=("$(realpath -m "$file")"); done
    fi
done <"$work/cases"
declare -A seen=()
while ((${#pending[@]} > 0)); do
    file=${pending[-1]}
    unset 'pending[-1]'
    [[ -n $file && -z ${seen[$file]:-} ]] || continue
    seen[$file]=1
    # A program that names TVar or Transactional gets abla/stm without importing it (src/module.ab).
    if [[ $file != "$(realpath -m "$stdlib")"/* ]] && grep -qE '\b(TVar|Transactional)\b' "$file"; then
        pending+=("$(realpath -m "$stdlib/abla/stm/entry.ab")")
    fi
    while IFS= read -r spec; do
        target=$(resolve "$file" "$spec")
        [[ -n $target && -z ${seen[$target]:-} ]] && pending+=("$target")
    done < <(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?import[[:space:]]+"([^"]+)".*/\2/p' "$file")
done
root=$(realpath -m "$stdlib")
for file in "${!seen[@]}"; do
    [[ $file == "$root"/abla/*/entry.ab ]] || continue
    name=${file#"$root"/}
    echo "${name%/entry.ab}"
done | sort -u >"$work/reached"
find "$stdlib/abla" -name entry.ab | sed -E "s|^$stdlib/||; s|/entry.ab$||" | sort >"$work/modules"
sed 's/#.*//' "$uncovered" | awk '$1 != "" { print $1 }' | sort >"$work/exempt"
while read -r module; do
    fail "no parity case reaches $module: add a case under tests/cases/parity or tests/cases/modules that imports it (or a line \"$module <reason>\" to $uncovered)"
done < <(comm -23 "$work/modules" <(sort -u "$work/reached" "$work/exempt"))
while read -r module; do
    fail "$uncovered lists $module, which a case reaches now: remove its line"
done < <(comm -12 "$work/exempt" "$work/reached")
while read -r module; do
    fail "$uncovered lists $module, which isn't a module"
done < <(comm -13 "$work/modules" "$work/exempt")
# The list only shrinks: no line the merge base doesn't have.
if base=$(git merge-base HEAD origin/master 2>/dev/null) && git cat-file -e "$base:$uncovered" 2>/dev/null; then
    while read -r module; do
        fail "$uncovered gains $module (the list only shrinks: a module needs a parity case that reaches it)"
    done < <(comm -13 <(git show "$base:$uncovered" | sed 's/#.*//' | awk '$1 != "" { print $1 }' | sort) "$work/exempt")
fi

(( failed == 0 )) || exit 1
echo "parity guard: $(wc -l <"$work/cases") cases with a line for interp, jit and auto, $(grep -c . "$work/reached") of $(wc -l <"$work/modules") standard-library modules reached, $(grep -c . "$work/exempt" || true) uncovered with a reason"
