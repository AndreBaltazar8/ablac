#!/usr/bin/env bash
# The downstream check: the sibling repositories (tools/siblings.txt) against a candidate compiler, in two layers.
#
#   tools/test-siblings.sh <candidate-tree> [--baseline <compiler>] [--only a,b,...] [--programs-only | --tests-only]
#                          [--jobs N] [--out DIR] [--keep] [--list FILE] [--projects DIR] [--expected-fail FILE]
#
# (--list and --projects, for tools/test-siblings-tool.sh: another list than tools/siblings.txt, and another
# directory of repositories than the one beside ablac.)
#
# <candidate-tree> is an ablac tree with build/ablac built (a worktree at the candidate, or a release candidate's
# source). Its build/ablac.bin must be the candidate's stage 2 (tools/gate.sh's build/gate/stage2, or a release
# binary), not one step from an older seed: a stage 1 is other code, and a difference it shows is not the candidate's.
# The check builds a layout in DIR (default build/siblings): each listed repository as a detached worktree
# of its default branch head (origin's, or the local branch for one without a remote), never anyone's checkout; an
# `ablac` that is the candidate tree; every other directory beside ablac as a symlink (repositories built by path
# reach them), and the symbolic links a repository's own checkout keeps to another project (game-pandatrails' engine)
# remade to point into the layout.
#
# Programs: every file with a `fun main` in a listed repository (not under build/, vendor/, .abla/ or .claude/),
# built with the candidate and, with --baseline, with that compiler (--fast --no-cache, `jobs` at a time). A program
# the baseline builds and the candidate does not is a regression; its first errors are kept.
# A repository with a shell.nix of its own builds its programs inside it (its system libraries, e.g. abla-graphics' vulkan-loader and libX11).
# tools/siblings-expected-fail.txt names, by hand, the programs a repository's tests expect NOT to build: they are no regression, show in the
# summary's xfail column (failed as expected / listed), and one that builds is an unexpected pass that fails the run.
# Tests: the repository's command from siblings.txt, run in its worktree (each in turn), its exit status kept.
#
# Unused imports: the candidate's W_UNUSED_IMPORT warnings from both layers (a test file is a root of its own, which
# `fix-imports --project` never reaches), each warning once, in DIR/unused.txt; files under a build/ directory (generated
# by a test) are left out.
# DIR/summary.txt has one line a repository: programs built / total, regressions, unused imports, the test status and log. Exit 1 when
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
expected_fail_file=
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
        --expected-fail) expected_fail_file=$2; shift ;;
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
expected_fail_file=${expected_fail_file:-$project_root/tools/siblings-expected-fail.txt}
# The programs a repository's own tests expect NOT to build (negative tests), one `<repository><TAB><file>` a line: named by hand, never inferred.
expected_fail=
[[ ! -f $expected_fail_file ]] || expected_fail=$(grep -vE '^[[:space:]]*(#|$)' "$expected_fail_file" | tr '\t' ' ' || true)
out=${out:-$project_root/build/siblings}
[[ -x $candidate/build/ablac ]] || { echo "test-siblings: $candidate/build/ablac is not built" >&2; exit 2; }
case $out in /*) ;; *) out=$PWD/$out ;; esac
[[ ! -e $out/layout || -f $out/.test-siblings ]] || { echo "test-siblings: $out exists and is not this tool's" >&2; exit 2; }
layout=$out/layout
repos=()
commands=()
services=()
while IFS=$'\t' read -r name command service; do
    [[ -z $name || $name == \#* ]] && continue
    [[ -z $only || $only == *,$name,* ]] || continue
    [[ -d $projects/$name ]] || { echo "test-siblings: $name is listed but not beside ablac; skipped" >&2; continue; }
    repos+=("$name")
    commands+=("$command")
    services+=("${service:-}")
done < "$list"

# A throwaway PostgreSQL for a repository whose list line has a third column `postgres=<database>`: nix's postgresql (the candidate's pinned nixpkgs),
# its own temporary data and socket directory, a free port on 127.0.0.1 and trust authentication; the repository's tests get POSTGRES_HOST, POSTGRES_PORT,
# POSTGRES_DB and POSTGRES_USER (what abla-postgres reads). It is stopped and removed when the repository's tests end (and on an interrupt); no system
# service is touched.
pg_dir=
pg_bin=
pg_port=
pg_free_port() {
    local port attempt
    for attempt in $(seq 100); do
        port=$((20000 + RANDOM % 20000))
        (exec 3<>"/dev/tcp/127.0.0.1/$port") 2> /dev/null || { echo "$port"; return 0; }
    done
    return 1
}
pg_stop() {
    [[ -z $pg_dir ]] && return 0
    "$pg_bin/pg_ctl" -D "$pg_dir/data" -m immediate -w stop > /dev/null 2>&1 || true
    rm -rf -- "$pg_dir"
    pg_dir=
}
pg_start() { # database -> 0, with pg_dir, pg_bin and pg_port set; a message on stderr and 1 when it cannot
    local database=$1 package
    command -v nix-build > /dev/null 2>&1 || { echo "test-siblings: a throwaway PostgreSQL needs nix" >&2; return 1; }
    package=$(nix-build --no-out-link -E "(import $candidate/nix/nixpkgs.nix).postgresql" 2> /dev/null | tail -n 1)
    [[ -x $package/bin/pg_ctl ]] || { echo "test-siblings: no postgresql from nix ($candidate/nix/nixpkgs.nix)" >&2; return 1; }
    pg_bin=$package/bin
    pg_dir=$(mktemp -d /tmp/siblings-pg.XXXXXX)
    "$pg_bin/initdb" -D "$pg_dir/data" -U postgres --auth=trust -E UTF8 > "$pg_dir/initdb.log" 2>&1 || { cat "$pg_dir/initdb.log" >&2; pg_stop; return 1; }
    pg_port=$(pg_free_port) || { echo "test-siblings: no free port for PostgreSQL" >&2; pg_stop; return 1; }
    "$pg_bin/pg_ctl" -D "$pg_dir/data" -l "$pg_dir/server.log" -w -t 60 \
        -o "-p $pg_port -k $pg_dir -c listen_addresses=127.0.0.1 -c fsync=off -c synchronous_commit=off" start > "$pg_dir/start.log" 2>&1 ||
        { cat "$pg_dir/start.log" "$pg_dir/server.log" >&2; pg_stop; return 1; }
    "$pg_bin/createdb" -h 127.0.0.1 -p "$pg_port" -U postgres "$database" || { pg_stop; return 1; }
}
trap pg_stop EXIT
trap 'pg_stop; exit 130' INT TERM

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
: > "$out/unused-raw.txt"
if ((programs)); then
    for name in "${repos[@]}"; do
        (cd "$layout/$name" && grep -rlE --include='*.ab' '^((trusted|inline) )*fun main\b' . 2>/dev/null |
            grep -vE '/(build|vendor|\.abla|\.claude|node_modules)/' | sed "s#^\./#$name #") >> "$programs_file" || true
    done
    # A repository with a shell.nix of its own (its system libraries: vulkan-loader, libX11, ...) builds inside it; the compilers' paths are absolute.
    in_repo_shell() { # name command... : run it in the repository's directory, inside its shell.nix when it has one
        local repo=$1; shift
        if [[ -f $layout/$repo/shell.nix ]] && command -v nix-shell >/dev/null 2>&1; then
            (cd "$layout/$repo" && nix-shell shell.nix --run "$(printf '%q ' "$@")")
        else
            (cd "$layout/$repo" && "$@")
        fi
    }
    build_one() { # name file -> "<name> <file> base=<rc|-> cand=<rc> expect=<pass|fail>"
        local name=$1 file=$2 work expect=pass
        grep -qxF "$name $file" <<< "$expected_fail" && expect=fail
        work=$(mktemp -d "$out/program.XXXXXX")
        local base=-
        if [[ -n $baseline ]]; then
            in_repo_shell "$name" env ABLA_MAX_MEMORY_MB=$memory timeout 600 "$baseline" build "$file" -o "$work/base" --fast --no-cache > "$work/base.log" 2>&1 && base=0 || base=$?
        fi
        local cand=0
        in_repo_shell "$name" env ABLA_MAX_MEMORY_MB=$memory ABLA_SYSROOT=$candidate timeout 600 "$candidate/build/ablac" build "$file" -o "$work/cand" --fast --no-cache > "$work/cand.log" 2>&1 || cand=$?
        echo "$name $file base=$base cand=$cand expect=$expect"
        grep -a 'W_UNUSED_IMPORT' "$work/cand.log" | sed "s#^#$name #" >> "$out/unused-raw.txt" || true
        if [[ $expect == pass && $cand != 0 && ( $base == 0 || $base == - ) ]]; then
            { echo "### $name $file (base=$base cand=$cand)"; grep -a -m3 -E 'error\[|error:' "$work/cand.log" | cut -c1-240; } > "$work/regression"
            cat "$work/regression" >> "$out/regressions.txt"
        fi
        rm -rf -- "$work"
    }
    export -f in_repo_shell build_one
    # One memory cap for both compilers, above what any sibling program needs: abla-graphics' generated
    # tests/raw_registry.ab needs more than 4096 MB of address space with v0.2.63 and master alike (at 2048 or 4096
    # both run out of memory alone, about 965 MB resident; at 6144 it builds), so a lower cap flips it by chance.
    memory=${ABLA_MAX_MEMORY_MB:-8192}
    export out layout baseline candidate memory expected_fail
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
        service_env=()
        if [[ ${services[$i]} == postgres=* ]]; then
            if pg_start "${services[$i]#postgres=}" > "$log" 2>&1; then
                service_env=(POSTGRES_HOST=127.0.0.1 "POSTGRES_PORT=$pg_port" "POSTGRES_DB=${services[$i]#postgres=}" POSTGRES_USER=postgres)
            else
                echo "test-siblings: $name: the throwaway PostgreSQL did not start (see $log)" >&2
                echo "$name 125" >> "$out/tests.txt"
                continue
            fi
        fi
        (cd "$layout/$name" && env ${service_env[@]+"${service_env[@]}"} PATH="$out/bin:$PATH" ABLA_DEBUG=0 timeout 2400 bash -c "$command") >> "$log" 2>&1 || status=$?
        pg_stop
        [[ -z ${service_env[*]:-} ]] || { echo "test-siblings: $name: ran against a throwaway PostgreSQL on 127.0.0.1:${service_env[1]#POSTGRES_PORT=} (stopped)" >> "$log"; }
        echo "$name $status" >> "$out/tests.txt"
        grep -a 'W_UNUSED_IMPORT' "$log" | sed "s#^#$name #" >> "$out/unused-raw.txt" || true
    done
fi

# Unused imports, once each: "<repository> <file>: <message>", the file relative to the repository.
while read -r name warning; do
    warning=${warning#*W_UNUSED_IMPORT]: }
    warning=${warning#"$layout/$name/"}
    [[ $warning == build/* || $warning == */build/* ]] && continue
    echo "$name $warning"
done < "$out/unused-raw.txt" | sort -u > "$out/unused.txt"

# The summary. Programs: built / listed, not counting the expected-fail ones (tools/siblings-expected-fail.txt: negative tests that must NOT build);
# those are a column of their own, "failed as expected / listed", and one that builds is an unexpected pass (it fails the run, so a newly passing one shows).
failed=0
: > "$out/unexpected-pass.txt"
{
    printf '%-18s %-14s %-11s %-7s %-9s %s\n' repository programs regressions unused xfail tests
    for name in "${repos[@]}"; do
        total=$(grep -c "^$name .* expect=pass$" "$out/programs-result.txt" 2>/dev/null || true)
        built=$(grep "^$name " "$out/programs-result.txt" 2>/dev/null | grep -c ' cand=0 expect=pass$' || true)
        listed=$(grep -c "^$name .* expect=fail$" "$out/programs-result.txt" 2>/dev/null || true)
        xfailed=$(( ${listed:-0} - $(grep "^$name " "$out/programs-result.txt" 2>/dev/null | grep -c ' cand=0 expect=fail$' || true) ))
        grep "^$name .* cand=0 expect=fail$" "$out/programs-result.txt" 2>/dev/null >> "$out/unexpected-pass.txt" || true
        regressed=$(grep -c "^### $name " "$out/regressions.txt" 2>/dev/null || true)
        status=$(awk -v n="$name" '$1 == n {print $2}' "$out/tests.txt")
        test_text=${status:--}
        [[ $test_text == 0 ]] && test_text="pass"
        [[ $test_text != pass && $test_text != - ]] && test_text="FAIL ($status, test-$name.log)"
        [[ ${regressed:-0} != 0 || $test_text == FAIL* || $xfailed != "${listed:-0}" ]] && failed=1
        unused=$(grep -c "^$name " "$out/unused.txt" || true)
        printf '%-18s %-14s %-11s %-7s %-9s %s\n' "$name" "${built:-0}/${total:-0}" "${regressed:-0}" "${unused:-0}" "${xfailed}/${listed:-0}" "$test_text"
    done
} > "$out/summary.txt"
cat "$out/summary.txt"
[[ -s $out/regressions.txt ]] && { echo; cat "$out/regressions.txt"; }
[[ -s $out/unexpected-pass.txt ]] && { echo; echo "unexpected pass (listed in $(basename "$expected_fail_file") as must-fail, but it builds):"; cat "$out/unexpected-pass.txt"; }
((keep)) || { remove_layout; rm -rf -- "$layout"; }
exit $failed
