#!/usr/bin/env bash
# The lowered-code cache across builds in one process: a function whose `#`
# code asked whether a class conforms is not reused once only an `extend`
# changes the answer (a rebuild with the cache equals one without).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
program="$project_root/build/conformance-ir-cache-test"

"$compiler" build "$project_root/tests/cases/modules/conformance-ir-cache.ab" \
    -o "$program" --fast --no-cache
set +e
ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=120 \
    "$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]] || { echo "conformance IR cache: exited $status" >&2; exit 1; }

printf '%s\n' 'conformance IR cache: a conformance change reaches the code its # queries built'
