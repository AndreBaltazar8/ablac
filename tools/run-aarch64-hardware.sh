#!/usr/bin/env bash
# Compare the same AArch64 checks in QEMU and on hardware. Run inside the
# project's usual build shell, with ABLA_AARCH64_HOSTS set to the board pool.
# Usage: tools/run-aarch64-hardware.sh <compiler> <static-aarch64-artifact> <version> [compare|hardware|qemu]
set -euo pipefail
compiler=${1:?path to stage 2 compiler}
artifact=${2:?path to static AArch64 compiler artifact}
version=${3:?expected version of the static compiler}
mode=${4:-compare}
[[ $mode == compare || $mode == hardware || $mode == qemu ]] || { echo "invalid AArch64 run mode: $mode" >&2; exit 2; }
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
[[ $artifact == /* ]] || artifact="$PWD/$artifact"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s)/$(uname -m) == Linux/x86_64 ]] || { echo 'the hardware comparison needs an x86-64 Linux build host' >&2; exit 2; }
[[ -n ${ABLA_AARCH64_HOSTS:-} || $mode == qemu ]] || { echo 'set ABLA_AARCH64_HOSTS to the SSH board pool' >&2; exit 2; }
machine=$(readelf -hW "$artifact" | awk '/Machine:/ { print $2 }')
[[ $machine == AArch64 ]] || { echo "expected an AArch64 artifact: $artifact" >&2; exit 2; }
mkdir -p build
out=$(mktemp -d "$PWD/build/aarch64-hardware.XXXXXX")
echo "AArch64 comparison logs: $out"

run_lane() (
    backend=$1
    mkdir "$out/$backend"
    if [[ $backend == hardware ]]; then
        export ABLA_AARCH64_RUN="$root/tools/aarch64-remote-run.sh"
        export ABLA_AARCH64_REQUIRE_REMOTE=1 ABLA_AARCH64_RUN_LOG="$out/$backend/backends.tsv"
    else
        unset ABLA_AARCH64_RUN ABLA_AARCH64_REQUIRE_REMOTE ABLA_AARCH64_RUN_LOG
    fi
    export RUN_TESTS_FILTER='tools/test-(aarch64-linux|simd|memmove)\.sh'
    export RUN_TESTS_OUTPUT="$out/$backend/suite"
    tools/run-tests.sh "$compiler" 2>&1 | tee "$out/$backend/suite.log"
    awk -F '\t' 'NF < 4 || $2 != "0" { failed=1 } END { exit failed || NR != 3 }' "$RUN_TESTS_OUTPUT/results.tsv"
    STATIC_ARTIFACT_OUTPUT="$out/$backend/static-artifact" \
        tools/test-static-artifact.sh "$artifact" "$version" --no-fixpoint 2>&1 | tee "$out/$backend/static-artifact.log"
    if [[ $backend == hardware ]]; then
        test -s "$ABLA_AARCH64_RUN_LOG"
        ! grep -q '^qemu[[:space:]]' "$ABLA_AARCH64_RUN_LOG"
    fi
)
if [[ $mode != hardware ]]; then run_lane qemu; fi
if [[ $mode != qemu ]]; then run_lane hardware; fi
if [[ $mode == compare ]]; then
    cut -f 1,2,4 "$out/qemu/suite/results.tsv" > "$out/qemu/results.txt"
    cut -f 1,2,4 "$out/hardware/suite/results.tsv" > "$out/hardware/results.txt"
    cmp "$out/qemu/results.txt" "$out/hardware/results.txt"
    cmp "$out/qemu/static-artifact.log" "$out/hardware/static-artifact.log"
fi
echo "AArch64 $mode: all checks passed"
