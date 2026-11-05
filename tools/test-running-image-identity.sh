#!/usr/bin/env bash
# The cached executable prefix and a changing backend suffix must hash exactly
# as the full image did, including executable files with trailing bytes.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/running-image-identity"
mkdir -p "$out"
program=$("$root/tools/compiler-api-test-program.py" "$compiler")
# Mutate separate executable copies, never the shared cached harness image.
for tail in 0 1 2 3; do
    cp "$program" "$out/tail-$tail"
    python3 - "$out/tail-$tail" "$tail" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_bytes(p.read_bytes() + bytes([0, 255, 128][:int(sys.argv[2])]))
PY
    set +e
    ABLA_COMPILER_API_CASE=running-image-identity ABLA_MAX_MEMORY_MB=4096 "$root/tools/run-limited.sh" "$out/tail-$tail"
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "running image identity: tail $tail returned $status" >&2; exit 1; }
done
echo 'running image identity: cached prefix matches full-image hashes with 0-3 trailing bytes and changing backend suffixes'
