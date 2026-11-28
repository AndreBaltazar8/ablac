#!/usr/bin/env bash
# The gate for one worktree: stage 1 from the bootstrap compiler the tree pins (tools/bootstrap-compiler.sh: the pinned release,
# checksum-verified, kept as build/gate/seed.bin), stage 2 == stage 3 (tools/bootstrap-stages.sh when the tree has it: stage 3 is only
# the compiler run, compared by bitcode; else three builds and a cmp), the self-rebuild's checks (tools/test-pure-self-rebuild.sh
# on the stage that bootstrap-stages built and compared, not a further build; `make self-rebuild` in an older tree), then the
# suite. Two chunks (the stage
# builds and the self-rebuild; the suite) each queue for the shared full-test slot and then the build slot (fair-flock), so no
# slot is held for more than one chunk. The progress is in <worktree>/build/gate/gate.log: the line `stage2 == stage3`, the
# suite's `N passed, M failed in Xs`, and last `exit=<status>`. Run it through systemd-run (never nohup: it ignores SIGHUP and
# breaks the signal-watch test).
#
#   tools/gate.sh <worktree> [slot] [--release] [--dry-run]
#
# The slot (default 2) picks the cores (all gates used to share cores 0-7):
#   1: 0-7   2: 8-15   3: 16-23   4: 24-31   5: 20-27 (overlaps 3 and 4)
# The suite runs one job more than the slot has cores: some tests wait (on their servers, child processes, timeouts) for a
# good part of their wall time, and the extra job keeps the cores busy meanwhile (a 6-core gate spent 167 s of its 2331 s
# suite with cores idle that way).
# Core types (ablac-4e's measurements): cpus 0-15 are the performance cores, cpus 16-31 the efficiency cores.
# Slots 1 and 2 are P-cores; slots 3, 4 and 5 are E-cores, about 1.5x slower per test (37 s against 25 s for the same job), so a
# timing-sensitive test sees slower cores there.
# GATE_CPUS and GATE_JOBS override them; FAIR_FLOCK names the fair-flock script (default: novakind/tools/fair-flock beside the
# projects directory).
#
# --release is the release gate (a release's Prepare commit): stage 3 is built whole and compared as an executable too, the suite
# is the full one (RUN_TESTS_FULL=1), and the reproducible-elsewhere check runs on the finished compiler (tools/gate-release.sh
# calls it so). --dry-run prints what each chunk would run, writes nothing and runs nothing.
# Linux x86_64 gates use CI's pinned Android NDK and bionic inputs for the suite.
# Set ABLA_NIX_ANDROID_TESTS=0 to omit those inputs (about 1.47 GB of source downloads).
set -u
dry=0
release=0
args=()
for argument in "$@"; do
    case $argument in
        --dry-run) dry=1 ;;
        --release) release=1 ;;
        -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
        *) args+=("$argument") ;;
    esac
done
((${#args[@]} >= 1 && ${#args[@]} <= 2)) || { echo "usage: tools/gate.sh <worktree> [slot] [--release] [--dry-run]" >&2; exit 2; }
tree=${args[0]}
n=${args[1]:-2}
[[ -d $tree && -x $tree/tools/bootstrap-compiler.sh ]] || { echo "gate: $tree is not an ablac worktree" >&2; exit 2; }
[[ $n =~ ^[0-9]+$ ]] || { echo "gate: the slot must be a number, got $n" >&2; exit 2; }
tree=$(cd "$tree" && pwd)
case $n in
    1) cpus=0-7 ;;
    2) cpus=8-15 ;;
    3) cpus=16-23 ;;
    4) cpus=24-31 ;;
    5) cpus=20-27 ;;
    *) cpus=0-7 ;;
esac
cpus=${GATE_CPUS:-$cpus}
# The cores in a cpuset list (0-7,14-15 is 10), and one job more.
cores=0
IFS=, read -r -a ranges <<< "$cpus"
for range in "${ranges[@]}"; do
    [[ $range =~ ^([0-9]+)(-([0-9]+))?$ ]] || { echo "gate: cannot read the cpuset $cpus" >&2; exit 2; }
    cores=$((cores + ${BASH_REMATCH[3]:-${BASH_REMATCH[1]}} - ${BASH_REMATCH[1]} + 1))
done
jobs=${GATE_JOBS:-$((cores + 1))}
common=$(git -C "$tree" rev-parse --path-format=absolute --git-common-dir 2> /dev/null || echo "$tree/.git")   # <projects>/ablac/.git
slot=${FAIR_FLOCK:-$(dirname -- "$(dirname -- "$common")")/novakind/tools/fair-flock}
[[ -x $slot || $dry == 1 ]] || { echo "gate: no fair-flock at $slot (set FAIR_FLOCK)" >&2; exit 2; }
log=$tree/build/gate/gate.log
android_tests=false
if [[ $(uname -s)/$(uname -m) == Linux/x86_64 && ${ABLA_NIX_ANDROID_TESTS:-1} != 0 &&
      -f $tree/nix/android-tests.nix ]]; then
    android_tests=true
fi
if ((dry)); then
    log=/dev/null
else
    mkdir -p "$tree/build/gate"
    [[ -e $tree/build/ablac ]] || ln -s ../tools/run-limited-compiler.sh "$tree/build/ablac"
    echo "queued $(date -u +%FT%TZ) slot $n cpus $cpus jobs $jobs" > "$log"
    if [[ $android_tests == true ]]; then
        # Realize the large inputs before taking a shared test/build slot.
        echo "Preparing pinned Android test inputs" >> "$log"
        nix-build --no-out-link "$tree/nix/android-tests.nix" >> "$log" 2>&1 ||
            { echo "gate: Android test inputs failed (see $log)" >&2; echo "exit=1" >> "$log"; exit 1; }
    fi
    # The seed: what the tree pins, checksum-verified; a seed left by an older pin is replaced.
    seed=$tree/build/gate/seed.bin
    if ! "$tree/tools/bootstrap-compiler.sh" "$seed" >> "$log" 2>&1; then
        rm -f -- "$seed"
        "$tree/tools/bootstrap-compiler.sh" "$seed" >> "$log" 2>&1 || { echo "gate: no bootstrap compiler (see $log)" >&2; echo "exit=1" >> "$log"; exit 1; }
    fi
fi

# One chunk inside both slots, in the worktree's shell.
step() { # name commands
    local android_args=()
    if [[ $1 == suite && $android_tests == true ]]; then
        android_args=(--arg androidTests true)
    fi
    if ((dry)); then
        printf '== %s (slot %s, cpus %s, jobs %s, fair-flock %s)\n' "$1" "$n" "$cpus" "$jobs" "$slot"
        [[ ${#android_args[@]} == 0 ]] || printf 'nix-shell --arg androidTests true\n'
        printf '%s\n' "$2"
        return 0
    fi
    "$slot" --close /tmp/novakind-full-test.slot$n \
        "$slot" --close /tmp/novakind-build.slot$n \
        nix-shell "$tree/shell.nix" "${android_args[@]}" --run "
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

seed_step='tools/bootstrap-compiler.sh build/gate/seed.bin'   # (a no-op when the seed there is the pinned one)
if [[ -x $tree/tools/bootstrap-stages.sh ]]; then
    stages="time taskset -c $cpus tools/bootstrap-stages.sh build/gate/seed.bin build/gate$( ((release)) && echo ' --full')"
    # The self-rebuild is the last whole stage, built by the one before it, whose bitcode bootstrap-stages compared.
    if ((release)); then
        rebuilt='build/gate/stage2 build/gate/stage3'
    else
        rebuilt='build/gate/stage1 build/gate/stage2'
    fi
    self_rebuild="make ablac
        time taskset -c $cpus tools/test-pure-self-rebuild.sh $rebuilt"
else
    stages="$(build build/gate/seed.bin build/gate/stage1)
        $(build build/gate/stage1 build/gate/stage2)
        $(build build/gate/stage2 build/gate/stage3)
        cmp build/gate/stage2 build/gate/stage3 && echo 'stage2 == stage3'"
    self_rebuild='make self-rebuild'
fi
if ((release)); then
    suite_env='RUN_TESTS_FULL=1 '
else
    suite_env=
fi
suite="${suite_env}JOBS=$jobs taskset -c $cpus tools/run-tests.sh"
# The regular gate checks stage 3 beside the suite, which needs only stage 2: the stage-3 run is a single thread on the
# slot's cores (13 s of the builds chunk), so the suite starts that much sooner. Its verdict goes into the log after the
# suite's, and either failing fails the gate. (The release gate builds stage 3 whole and its self-rebuild checks it, so
# it keeps the three stages before the suite.)
if ((!release)) && [[ -x $tree/tools/bootstrap-stages.sh ]] && grep -q -- '--stage-3' "$tree/tools/bootstrap-stages.sh"; then
    stages="time taskset -c $cpus tools/bootstrap-stages.sh build/gate/seed.bin build/gate --stages-1-2"
    suite="taskset -c $cpus tools/bootstrap-stages.sh build/gate/seed.bin build/gate --stage-3 > build/gate/stage3.log 2>&1 &
        stage3=\$!
        status=0
        $suite || status=\$?
        stage3_status=0
        wait \$stage3 || stage3_status=\$?
        grep -v '^warning\\|^source\\[\\|^  -->' build/gate/stage3.log || true
        [[ \$stage3_status == 0 ]] || { echo 'gate: the stage-3 check failed (build/gate/stage3.log)'; status=1; }
        [[ \$status == 0 ]]"
fi

step builds "$seed_step
        $stages
        cp build/gate/stage2 build/ablac.bin
        $self_rebuild" &&
    step suite "rm -f build/test-logs/*.log 2>/dev/null || true
        $suite" &&
    if ((release)); then
        step repro "time taskset -c $cpus tools/test-reproducible-elsewhere.sh --self build/ablac.bin
        sha256sum build/gate/stage2
        build/gate/stage2 --version"
    fi
rc=$?
((dry)) || echo "exit=$rc" >> "$log"
exit $rc
