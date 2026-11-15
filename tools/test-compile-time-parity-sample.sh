#!/usr/bin/env bash
# Compile-time parity of tests/cases/modules programs, sampled (#829): the full run (every module program, run time
# against `#`, in interp and jit) takes about half an hour, so it ran outside the suite and expected-pass.txt rows rotted
# unseen. This step runs, in both modes, a fixed set of rows that guard past fixes and a rotating sample of the listed
# module rows: the sample starts at the number of commits times its size, so consecutive commits walk through every row.
# Every selected row must keep its expected status (tools/test-compile-time-parity.sh fails otherwise).
#
#   PARITY_SAMPLE_SIZE    rotating rows per run (default 12)
#   PARITY_SAMPLE_OFFSET  where the rotation starts (default: commits * size); the step prints it, to rerun one sample
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
expect=tests/cases/parity/expected-pass.txt
size=${PARITY_SAMPLE_SIZE:-12}

# Always run: rows that guard fixes. In jit: #828 jwt and lambda-inferred-result, #829 http-event and a stale-row status;
# in interp and jit: #829 thread-local-bytes, process-capture and linux-process (the children's exec strings), and the
# cases whose own checks were wrong (generator-nested-*, the compilation's one value of a global; compile-time-f32-parity,
# a NaN's unspecified bits); thread-heap-mutex (the runtime's atomics) and runtime-memory-global-container (a collection
# is a no-op) in the interpreter.
fixed=(http-event jwt lambda-inferred-result scoped-region)
fixedBoth=(thread-local-bytes generator-nested-borrowed generator-nested-index compile-time-f32-parity process-capture
    linux-process thread-heap-mutex runtime-memory-global-container)
# Never sampled: rows whose expected status never finishes (they take their known timeout, as tls and websocket-live
# do), and rows that depend on the machine's loopback networking and signals.
skip=" http-server signal-watch network-advanced "
# Never sampled either: rows whose interpreted side runs to the evaluator's step limit (minutes each).
skip="$skip jwt jwt-remote http-async dns-async http-event "

candidates=()
while read -r mode name status; do
    [[ -z $mode || $mode == \#* ]] && continue
    [[ $name == module/* ]] || continue
    case ${status:-pass} in timeout|interp-threads|runtime-skipped) continue ;; esac
    row=${name#module/}
    [[ $skip == *" $row "* ]] && continue
    [[ " ${candidates[*]} " == *" $row "* ]] || candidates+=("$row")
done <"$expect"
count=${#candidates[@]}
(( count > 0 )) || { echo "parity sample: no module rows in $expect" >&2; exit 1; }
if [[ -n ${PARITY_SAMPLE_OFFSET:-} ]]; then
    offset=$PARITY_SAMPLE_OFFSET
else
    commits=$(git rev-list --count HEAD 2>/dev/null || echo 0)
    offset=$(( commits * size ))
fi
selected=()
for (( index = 0; index < size && index < count; index++ )); do
    row=${candidates[$(( (offset + index) % count ))]}
    [[ " ${selected[*]} ${fixed[*]} ${fixedBoth[*]} " == *" $row "* ]] || selected+=("$row")
done
run() { # modes output names...
    local modes=$1 output=$2
    shift 2
    local pattern
    pattern=$(IFS='|'; echo "$*")
    PARITY_MODES="$modes" PARITY_SET=modules PARITY_FILTER="^module/($pattern)\$" PARITY_OUTPUT="$output" \
        tools/test-compile-time-parity.sh "$compiler"
}
echo "parity sample: fixed (jit): ${fixed[*]}"
run jit build/compile-time-parity-sample-fixed "${fixed[@]}"
echo "parity sample: offset $offset of $count rows (PARITY_SAMPLE_OFFSET=$offset reruns it), interp and jit: ${fixedBoth[*]} ${selected[*]}"
run "interp jit" build/compile-time-parity-sample "${fixedBoth[@]}" "${selected[@]}"
