#!/usr/bin/env bash
# The downstream check: the sibling repositories (tools/siblings.txt) against a candidate compiler, in two layers.
#
#   tools/test-siblings.sh <candidate-tree> [--baseline <compiler>] [--only a,b,...] [--programs-only | --tests-only]
#                          [--jobs N] [--out DIR] [--keep] [--list FILE] [--projects DIR]
#
# (--list and --projects, for tools/test-siblings-tool.sh: another list than tools/siblings.txt, and another
# directory of repositories than the one beside ablac.)
#
# <candidate-tree> is an ablac tree with build/ablac built (a worktree at the candidate, or a release candidate's
# source). The check builds a layout in DIR (default build/siblings): each listed repository as a detached worktree
# of its default branch head (origin's, or the local branch for one without a remote), never anyone's checkout; an
# `ablac` that is the candidate tree; every other directory beside ablac as a symlink (repositories built by path
# reach them), and the symbolic links a repository's own checkout keeps to another project (game-pandatrails' engine)
# remade to point into the layout.
#
# Programs: every file with a `fun main` in a listed repository (not under build/, vendor/, .abla/ or .claude/),
# built with the candidate and, with --baseline, with that compiler (--fast --no-cache, `jobs` at a time). A program
# the baseline builds and the candidate does not is a regression; its first errors are kept.
# Tests: the repository's command from siblings.txt, run in its worktree (each in turn), its exit status kept.
#
# DIR/summary.txt has one line a repository: programs built / total, regressions, the test status and log. Exit 1 when
# a program regressed or a test failed, 0 otherwise. Heavy: run it in a slot (tools/fair-flock), never on every push.
# The layout's worktrees are removed at the end unless --keep.
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}
[[ $# -ge 1 ]] || usage
candidate=$(cd -- "$1" && pwd)
shift
baseline=
only=
programs=1
tests=1
jobs=4
out=
keep=0
list=
projects_override=
while [[ $# -gt 0 ]]; do
    case $1 in
        --baseline) baseline=$2; shift ;;
        --only) only=,$2,; shift ;;
        --programs-only) tests=0 ;;
        --tests-only) programs=0 ;;
        --jobs) jobs=$2; shift ;;
        --out) out=$2; shift ;;
        --keep) keep=1 ;;
        --list) list=$2; shift ;;
        --projects) projects_override=$2; shift ;;
        *) usage ;;
    esac
    shift
done
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
projects=$(cd -- "$project_root/.." && pwd)
# A worktree of ablac sits under .claude/worktrees: its siblings are the main checkout's.
[[ -d $projects/abla-xml || ! -d $project_root/../../../../abla-xml ]] || projects=$(cd -- "$project_root/../../../.." && pwd)
[[ -z $projects_override ]] || projects=$(cd -- "$projects_override" && pwd)
list=${list:-$project_root/tools/siblings.txt}
out=${out:-$project_root/build/siblings}
[[ -x $candidate/build/ablac ]] || { echo "test-siblings: $candidate/build/ablac is not built" >&2; exit 2; }
case $out in /*) ;; *) out=$PWD/$out ;; esac
[[ ! -e $out/layout || -f $out/.test-siblings ]] || { echo "test-siblings: $out exists and is not this tool's" >&2; exit 2; }
layout=$out/layout
repos=()
commands=()
while IFS=$'\t' read -r name command; do
    [[ -z $name || $name == \#* ]] && continue
    [[ -z $only || $only == *,$name,* ]] || continue
    [[ -d $projects/$name ]] || { echo "test-siblings: $name is listed but not beside ablac; skipped" >&2; continue; }
    repos+=("$name")
    commands+=("$command")
done < "$list"

# The layout.
remove_layout() {
    for name in "${repos[@]}"; do
        [[ -d $layout/$name/.git || -f $layout/$name/.git ]] && git -C "$projects/$name" worktree remove --force "$layout/$name" 2>/dev/null || true
    done
}
if [[ -d $layout ]]; then remove_layout; rm -rf -- "$layout"; fi
mkdir -p "$layout"
touch "$out/.test-siblings"
for entry in "$projects"/*/; do
    name=$(basename "$entry")
    [[ $name == *' '* ]] && continue
    ln -s "$projects/$name" "$layout/$name"
done
rm -f -- "$layout/ablac"
ln -s "$candidate" "$layout/ablac"
for name in "${repos[@]}"; do
    rm -f -- "$layout/$name"
    git -C "$projects/$name" fetch -q origin 2>/dev/null || true
    head=$(git -C "$projects/$name" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || git -C "$projects/$name" rev-parse --abbrev-ref HEAD)
    git -C "$projects/$name" worktree add -q --detach "$layout/$name" "$head"
    # The checkout's links to other projects (untracked), pointed into the layout.
    while IFS= read -r link; do
        target=$(readlink "$link")
        case $target in "$projects"/*) ;; *) continue ;; esac
        relative=${link#"$projects/$name/"}
        [[ -e $layout/$name/$relative || -L $layout/$name/$relative ]] && continue
        mkdir -p "$(dirname "$layout/$name/$relative")"
        ln -s "$layout/${target#"$projects/"}" "$layout/$name/$relative"
    done < <(find "$projects/$name" -path "$projects/$name/.git" -prune -o -path "*/.claude" -prune -o -type l -print 2>/dev/null)
    # Each committed lock's packages at their locked revisions (decision #85), before anything builds: `package
    # vendor` never moves a lock, and every compiler has it (a baseline may predate builds installing them).
    while IFS= read -r lock; do
        (cd "$(dirname "$lock")" && ABLA_SYSROOT=$candidate "$candidate/build/ablac" package vendor --project .) \
            >> "$out/vendor-$name.log" 2>&1 || echo "test-siblings: $name: package vendor failed in $(dirname "${lock#"$layout/"}") (vendor-$name.log)" >&2
    done < <(find "$layout/$name" \( -name .abla -o -name vendor -o -name build -o -name .claude -o -name .git \) -prune -o -name abla.lock -print)
done

# A test command that runs `ablac` from PATH (a Makefile's `COMPILER ?= ablac`) gets the candidate, not whatever is
# installed.
mkdir -p "$out/bin"
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$candidate/build/ablac" > "$out/bin/ablac"
chmod +x "$out/bin/ablac"

# Programs.
programs_file=$out/programs.txt
: > "$programs_file"
if ((programs)); then
    for name in "${repos[@]}"; do
        (cd "$layout/$name" && grep -rlE --include='*.ab' '^((trusted|inline) )*fun main\b' . 2>/dev/null |
            grep -vE '/(build|vendor|\.abla|\.claude|node_modules)/' | sed "s#^\./#$name #") >> "$programs_file" || true
    done
    build_one() { # name file -> "<name> <file> base=<rc|-> cand=<rc>"
        local name=$1 file=$2 work
        work=$(mktemp -d "$out/program.XXXXXX")
        local base=-
        if [[ -n $baseline ]]; then
            (cd "$layout/$name" && ABLA_MAX_MEMORY_MB=$memory timeout 600 "$baseline" build "$file" -o "$work/base" --fast --no-cache) > "$work/base.log" 2>&1 && base=0 || base=$?
        fi
        local cand=0
        (cd "$layout/$name" && ABLA_MAX_MEMORY_MB=$memory ABLA_SYSROOT=$candidate timeout 600 "$candidate/build/ablac" build "$file" -o "$work/cand" --fast --no-cache) > "$work/cand.log" 2>&1 || cand=$?
        echo "$name $file base=$base cand=$cand"
        if [[ $cand != 0 && ( $base == 0 || $base == - ) ]]; then
            { echo "### $name $file (base=$base cand=$cand)"; grep -a -m3 -E 'error\[|error:' "$work/cand.log" | cut -c1-240; } > "$work/regression"
            cat "$work/regression" >> "$out/regressions.txt"
        fi
        rm -rf -- "$work"
    }
    export -f build_one
    # One memory cap for both compilers (the launcher's default, 2048 MB of address space, is at the edge for some
    # generated programs such as abla-graphics' raw_registry, so it failed or passed by allocation pattern).
    memory=${ABLA_MAX_MEMORY_MB:-4096}
    export out layout baseline candidate memory
    : > "$out/regressions.txt"
    # `jobs` at a time; each line's output is whole (one echo). (Paths with spaces aren't sibling sources.)
    xargs -P "$jobs" -L 1 bash -c 'build_one "$0" "$1"' < "$programs_file" > "$out/programs-result.txt" 2>&1 || true
fi

# Tests.
: > "$out/tests.txt"
if ((tests)); then
    for i in "${!repos[@]}"; do
        name=${repos[$i]}
        command=${commands[$i]}
        [[ $command == - ]] && { echo "$name -" >> "$out/tests.txt"; continue; }
        log=$out/test-$name.log
        status=0
        (cd "$layout/$name" && PATH="$out/bin:$PATH" ABLA_DEBUG=0 timeout 2400 bash -c "$command") > "$log" 2>&1 || status=$?
        echo "$name $status" >> "$out/tests.txt"
    done
fi

# The summary.
failed=0
{
    printf '%-18s %-14s %-11s %s\n' repository programs regressions tests
    for name in "${repos[@]}"; do
        total=$(grep -c "^$name " "$out/programs-result.txt" 2>/dev/null || true)
        built=$(grep "^$name " "$out/programs-result.txt" 2>/dev/null | grep -c ' cand=0$' || true)
        regressed=$(grep -c "^### $name " "$out/regressions.txt" 2>/dev/null || true)
        status=$(awk -v n="$name" '$1 == n {print $2}' "$out/tests.txt")
        test_text=${status:--}
        [[ $test_text == 0 ]] && test_text="pass"
        [[ $test_text != pass && $test_text != - ]] && test_text="FAIL ($status, test-$name.log)"
        [[ ${regressed:-0} != 0 || $test_text == FAIL* ]] && failed=1
        printf '%-18s %-14s %-11s %s\n' "$name" "${built:-0}/${total:-0}" "${regressed:-0}" "$test_text"
    done
} > "$out/summary.txt"
cat "$out/summary.txt"
[[ -s $out/regressions.txt ]] && { echo; cat "$out/regressions.txt"; }
((keep)) || { remove_layout; rm -rf -- "$layout"; }
exit $failed
