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
test ! -e "$output.host.o"
if nm "$output" | awk '{print $3}' | \
    rg '^(ablaHost|abla_host_|abla_platform_)' >/dev/null; then
    echo "module incremental state unexpectedly linked project C symbols" >&2
    exit 1
fi

echo "module incremental state: stable interfaces retain downstream staged frontends; signature/import edges invalidate"
