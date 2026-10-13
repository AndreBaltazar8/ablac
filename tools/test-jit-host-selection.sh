#!/usr/bin/env bash
# `ablac run` (the in-process JIT) runs a pure program, a portable raw-syscall
# one and one that selects a host capability. The JIT resolves host functions
# from the compiler process itself; no host adapter library is built for it
# (the C adapter went with the C runtime).
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
cd "$project_root"

for program in bootstrap/block modules/filesystem modules/host-runtime; do
    before=$(find build -maxdepth 1 \( -name '*.so' -o -name '*.dylib' \) 2>/dev/null | sort)
    set +e
    ABLA_MAX_MEMORY_MB=768 ABLA_MAX_SECONDS=60 \
        "$project_root/tools/run-limited.sh" "$compiler" run --jit \
        "$project_root/tests/cases/$program.ab"
    status=$?
    set -e
    [[ $status -eq 42 ]] || {
        printf 'run --jit %s: exit %s\n' "$program" "$status" >&2
        exit 1
    }
    after=$(find build -maxdepth 1 \( -name '*.so' -o -name '*.dylib' \) 2>/dev/null | sort)
    [[ $after == "$before" ]] || exit 1
done
printf '%s\n' \
    'JIT host resolution: pure, portable-raw and host-capability programs ran in process, no adapter built'
