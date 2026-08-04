#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
original=${ABLA_ORIGINAL:-../abla-original}
examples="$original/runner/src/test/resources/examples"

if [[ ! -d "$examples" ]]; then
    echo "original example directory not found: $examples" >&2
    exit 2
fi

count=0
while IFS= read -r -d '' source; do
    "$compiler" parse "$source" >/dev/null
    count=$((count + 1))
done < <(find "$examples" -type f -name '*.ab' -print0 | sort -z)

echo "$count original syntax examples passed"
