#!/usr/bin/env bash
# Decision #107 (option B): a release (not --fast) hosted Linux executable gets the collection with background freeing, and the adaptive collection threads, without asking.
# The trace of plain.ab shows background freeing on both heap sizes and a parallel mark only for the wide heap. The opt-outs: ABLA_GC_BACKGROUND=0 (no background collector), ABLA_GC_WORKERS=0 (background collector, no threads),
# memorySetBackgroundFree(false) (off.ab), memorySetGcWorkers(0) (serial.ab), and memorySetManualCollection() (manual.ab: no background collector).
# Every variant prints the same result.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'gc default: x86-64 Linux only'; exit 0; }
out=build/gc-default
rm -rf "$out"
mkdir -p "$out"
fail() { echo "gc default: $1" >&2; exit 1; }
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    # Option B of decision #107: a --fast build keeps its plain collection; a release build has the default.
    programs=(plain off serial manual scoped)
    [[ $mode == fast ]] && programs=(plain)
    for program in "${programs[@]}"; do
        "$compiler" build "tests/cases/gc-default/$program.ab" -o "$out/$program.$mode" "${flags[@]}" > "$out/$program.$mode.build" 2>&1 ||
            { cat "$out/$program.$mode.build" >&2; fail "$program ($mode) did not build"; }
    done
    run() { # label, then env assignments and the program
        local label=$1 result
        shift
        result=$(env ABLA_GC_TRACE=1 "$@" 2>&1 | tr -d '\0') || fail "$label ($mode) failed: ${result: -200}"
        [[ $result == *"default gc ok:"* ]] || fail "$label ($mode): ${result: -200}"
        printf '%s\n' "$result"
    }
    expected=$(run "plain" "$root/tools/run-limited.sh" "$out/plain.$mode" | grep -a 'default gc ok')
    plain=$(run "plain" "$root/tools/run-limited.sh" "$out/plain.$mode")
    if [[ $mode == fast ]]; then
        [[ $plain != *"gc: phases us"* && $plain != *"gc: parallel"* ]] || fail "plain (fast): the background collector ran by default"
        echo "gc default (fast): a --fast build keeps the plain collection (no helper, no threads) unless the program asks"
        continue
    fi
    [[ $plain == *"gc: phases us"* ]] || fail "plain ($mode): no background collection by default"
    [[ $plain != *"gc: parallel mark"* ]] || fail "plain ($mode): a small live heap used collection threads"
    wide=$(run "wide" "$root/tools/run-limited.sh" "$out/plain.$mode" wide)
    [[ $wide == *"gc: parallel mark"* ]] || fail "wide ($mode): no collection threads on a large live heap"
    wide_off=$(run "wide opt-out" env ABLA_GC_BACKGROUND=0 "$root/tools/run-limited.sh" "$out/plain.$mode" wide | grep -a "default gc ok")
    [[ $wide == *"$wide_off"* ]] || fail "wide ($mode): parallel collection changed the result"
    forced=$(run "ABLA_GC_WORKERS=2" env ABLA_GC_WORKERS=2 "$root/tools/run-limited.sh" "$out/plain.$mode")
    [[ $forced == *"gc: parallel mark"* ]] || fail "ABLA_GC_WORKERS=2 ($mode): worker override was ignored"
    # Under ABLA_GC_STRESS=1 a default program stays serial and synchronous (thousands of collections would each pay the helper and the workers).
    stressed=$(run "ABLA_GC_STRESS=1" env ABLA_GC_STRESS=1 "$root/tools/run-limited.sh" "$out/plain.$mode")
    [[ $stressed != *"gc: phases us"* && $stressed != *"gc: parallel"* ]] || fail "ABLA_GC_STRESS=1 ($mode): the default background collector ran"
    scoped=$(run "scoped stress" "$root/tools/run-limited.sh" "$out/scoped.$mode")
    [[ $scoped == *"gc: phases us"* && $scoped != *"gc: parallel"* &&
        $scoped == *"default gc ok: scoped"* ]] ||
        fail "scoped stress ($mode): a small heap used parallel collection"
    scoped_wide=$(run "wide scoped stress" "$root/tools/run-limited.sh" "$out/scoped.$mode" wide)
    [[ $scoped_wide == *"gc: adaptive, parallel 1"* &&
        $scoped_wide != *"gc: parallel sweep"* && $scoped_wide == *"default gc ok: scoped"* ]] ||
        fail "wide scoped stress ($mode): expected adaptive marking and serial sweeping"
    scoped_forced=$(run "scoped stress with forced workers" env ABLA_GC_WORKERS=2 "$root/tools/run-limited.sh" "$out/scoped.$mode")
    [[ $scoped_forced == *"gc: parallel mark"* && $scoped_forced == *"default gc ok: scoped"* ]] ||
        fail "scoped stress ($mode): the explicit worker override was ignored"
    off=$(run "ABLA_GC_BACKGROUND=0" env ABLA_GC_BACKGROUND=0 "$root/tools/run-limited.sh" "$out/plain.$mode")
    [[ $off != *"gc: phases us"* && $off != *"gc: parallel"* ]] || fail "ABLA_GC_BACKGROUND=0 ($mode): the background collector ran"
    workers=$(run "ABLA_GC_WORKERS=0" env ABLA_GC_WORKERS=0 "$root/tools/run-limited.sh" "$out/plain.$mode")
    [[ $workers == *"gc: phases us"* && $workers != *"gc: parallel"* ]] || fail "ABLA_GC_WORKERS=0 ($mode): wanted the background collector without threads"
    offprogram=$(run "off.ab" "$root/tools/run-limited.sh" "$out/off.$mode")
    [[ $offprogram != *"gc: phases us"* && $offprogram != *"gc: parallel"* ]] || fail "memorySetBackgroundFree(false) ($mode): the background collector ran"
    serial=$(run "serial.ab" "$root/tools/run-limited.sh" "$out/serial.$mode")
    [[ $serial == *"gc: phases us"* && $serial != *"gc: parallel"* ]] || fail "memorySetGcWorkers(0) ($mode): wanted the background collector without threads"
    manual=$(run "manual.ab" "$root/tools/run-limited.sh" "$out/manual.$mode")
    [[ $manual != *"gc: phases us"* && $manual != *"gc: parallel"* ]] || fail "memorySetManualCollection ($mode): the background collector ran"
    for variant in "$forced" "$stressed" "$off" "$workers" "$offprogram" "$serial" "$manual"; do
        [[ $variant == *"$expected"* ]] || fail "($mode) a variant printed another result: ${variant: -120}"
    done
    echo "gc default ($mode): background freeing and collection threads by default; ABLA_GC_BACKGROUND=0, ABLA_GC_WORKERS=0, memorySetBackgroundFree(false), memorySetGcWorkers(0) and manual collection opt out"
done
