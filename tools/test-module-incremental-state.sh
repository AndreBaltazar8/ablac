#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
output=build/module-incremental-state-test

"$compiler" build tests/cases/modules/module-incremental-state.ab \
    -o "$output" --fast --no-cache

set +e
ABLA_MAX_MEMORY_MB=256 ABLA_MAX_SECONDS=30 \
    tools/run-limited.sh "$output"
status=$?
set -e

test "$status" -eq 42
# The host object is the syscall layer on macOS only (see
# test-native-platform-boundary.sh).
[[ $(uname -s) == Darwin || ! -e $output.host.o ]]
# These two platform entries are emitted in Abla's LLVM module, as checked
# by test-native-platform-boundary.sh; they are not linked C adapters.
if nm "$output" | awk '{sub(/^_/, "", $3); print $3}' | \
    rg '^(ablaHost|abla_host_|abla_platform_)' | \
    rg -v '^(abla_platform_free|abla_platform_panic)$' >/dev/null; then
    echo "module incremental state unexpectedly linked project C symbols" >&2
    exit 1
fi

echo "module incremental state: stable interfaces retain downstream staged frontends; signature/import edges invalidate"
