#!/usr/bin/env bash
# The release gate for one worktree (a release's Prepare commit): stages 1-3 from the pinned bootstrap compiler
# (stage 2 == stage 3), make self-rebuild, the FULL suite (RUN_TESTS_FULL=1), then the reproducible-elsewhere check
# on the finished compiler. Each chunk queues for the shared full-test slot and then the build slot (fair-flock), so no
# slot is held for more than one chunk. The progress is in <worktree>/build/gate/gate.log; the last line is
# `exit=<status>`. Run it through systemd-run (never nohup: it ignores SIGHUP and breaks the signal-watch test).
#
#   tools/gate-release.sh <worktree> [slot] [--dry-run]
#
# The slot (default 2) picks the cores and jobs, as the regular gate does (all slots used to share cores 0-7):
#   1: 0-7 (8 jobs)   2: 8-11,14-15 (6 jobs; cpus 12 and 13 are offline)   3: 16-23   4: 24-31   5: 20-27 (overlaps 3 and 4)
# GATE_CPUS and GATE_JOBS override them; FAIR_FLOCK names the fair-flock script (default: novakind/tools/fair-flock
# beside the projects directory). --dry-run prints what each chunk would run and runs nothing.
set -u
dry=0
args=()
for argument in "$@"; do
    case $argument in
        --dry-run) dry=1 ;;
        -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
        *) args+=("$argument") ;;
    esac
done
((${#args[@]} >= 1 && ${#args[@]} <= 2)) || { echo "usage: tools/gate-release.sh <worktree> [slot] [--dry-run]" >&2; exit 2; }
tree=${args[0]}
n=${args[1]:-2}
[[ -d $tree && -x $tree/tools/bootstrap-compiler.sh ]] || { echo "gate-release: $tree is not an ablac worktree" >&2; exit 2; }
[[ $n =~ ^[0-9]+$ ]] || { echo "gate-release: the slot must be a number, got $n" >&2; exit 2; }
tree=$(cd "$tree" && pwd)
case $n in
    1) cpus=0-7 jobs=8 ;;
    2) cpus=8-11,14-15 jobs=6 ;;
    3) cpus=16-23 jobs=8 ;;
    4) cpus=24-31 jobs=8 ;;
    5) cpus=20-27 jobs=8 ;;
    *) cpus=0-7 jobs=8 ;;
esac
cpus=${GATE_CPUS:-$cpus}
jobs=${GATE_JOBS:-$jobs}
common=$(git -C "$tree" rev-parse --path-format=absolute --git-common-dir 2> /dev/null || echo "$tree/.git")   # <projects>/ablac/.git
slot=${FAIR_FLOCK:-$(dirname -- "$(dirname -- "$common")")/novakind/tools/fair-flock}
[[ -x $slot || $dry == 1 ]] || { echo "gate-release: no fair-flock at $slot (set FAIR_FLOCK)" >&2; exit 2; }
log=$tree/build/gate/gate.log
if ((dry)); then
    log=/dev/null
else
    mkdir -p "$tree/build/gate"
    [[ -e $tree/build/ablac ]] || ln -s ../tools/run-limited-compiler.sh "$tree/build/ablac"
    echo "queued $(date -u +%FT%TZ) slot $n cpus $cpus jobs $jobs" > "$log"
fi

# One chunk inside both slots, in the worktree's shell.
step() { # name commands
    if ((dry)); then
        printf '== %s (slot %s, cpus %s, jobs %s, fair-flock %s)\n%s\n' "$1" "$n" "$cpus" "$jobs" "$slot" "$2"
        return 0
    fi
    "$slot" --close /tmp/novakind-full-test.slot$n \
        "$slot" --close /tmp/novakind-build.slot$n \
        nix-shell "$tree/shell.nix" --run "
        set -e
        echo \"granted \$(date -u +%FT%TZ): $1\"
        cd $tree
        ulimit -Ss 8192
        TIMEFORMAT='%R s'
        $2
        echo \"released \$(date -u +%FT%TZ): $1\"
      " >> "$log" 2>&1
}

build() { echo "time taskset -c $cpus tools/build-self-hosted-release.sh $1 $2 src/orc_main.ab"; }

step builds "[[ -x build/gate/seed.bin ]] || tools/bootstrap-compiler.sh build/gate/seed.bin
        $(build build/gate/seed.bin build/gate/stage1)
        $(build build/gate/stage1 build/gate/stage2)
        $(build build/gate/stage2 build/gate/stage3)
        cmp build/gate/stage2 build/gate/stage3 && echo 'stage2 == stage3'
        cp build/gate/stage2 build/ablac.bin
        make self-rebuild" &&
    step suite "rm -f build/test-logs/*.log 2>/dev/null || true; RUN_TESTS_FULL=1 JOBS=$jobs taskset -c $cpus tools/run-tests.sh" &&
    step repro "time taskset -c $cpus tools/test-reproducible-elsewhere.sh --self build/ablac.bin
        sha256sum build/gate/stage2
        build/gate/stage2 --version"
rc=$?
((dry)) || echo "exit=$rc" >> "$log"
exit $rc
