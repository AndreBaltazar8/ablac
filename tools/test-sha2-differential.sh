#!/usr/bin/env bash
# abla/crypto's SHA-256/384/512 and HMAC against Node's crypto (tests/cases/sha2-differential): random data up to 512 KB,
# streamed in random chunks (partial blocks, empty updates), one-shot over ropes and over slices at an offset, in threads
# and a task, release and --fast. SHA2_SEEDS sets how many seeds (default 60).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/sha2-differential
rm -rf "$out"
mkdir -p "$out"
seeds=${SHA2_SEEDS:-60}
command -v node > /dev/null || { echo "sha2-differential: needs node (the oracle)" >&2; exit 1; }
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/sha2-differential/streams.ab -o "$out/streams-$mode" "${flags[@]}" > "$out/build-$mode.log" 2>&1 ||
        { cat "$out/build-$mode.log" >&2; exit 1; }
    "$root/tools/run-limited.sh" "$out/streams-$mode" 1 "$seeds" 524288 > "$out/digests-$mode.txt" ||
        { echo "sha2-differential ($mode): the program failed (threads or the task disagreed?)" >&2; tail -5 "$out/digests-$mode.txt" >&2; exit 1; }
    result=$(node tests/cases/sha2-differential/check.mjs "$out/digests-$mode.txt" 524288) ||
        { echo "sha2-differential ($mode): $result" >&2; exit 1; }
    echo "ok   $mode: $result"
done
echo "sha2-differential ok"
