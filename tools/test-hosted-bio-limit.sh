#!/usr/bin/env bash
# The hosted OpenSSL path hands a PEM's length to BIO_new_mem_buf as a C int (CVE-2026-121481's class: a size in an int). A client identity
# of 2 GiB or more is refused before any BIO is made; the program's memory is capped at 1 GiB, so a version that flattens the text first
# (2 GiB) fails the test.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/hosted-bio-limit
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/hosted-bio-limit/main.ab -o "$out/main" --no-cache
result=$(ABLA_MAX_MEMORY_MB=1024 "$root/tools/run-limited.sh" "$out/main" 2>&1) || { echo "hosted-bio-limit: $result" >&2; exit 1; }
[[ $result == *"hosted bio limit ok"* ]] || { echo "hosted-bio-limit: $result" >&2; exit 1; }
echo "hosted bio limit: a 2 GiB client identity is refused before OpenSSL sees its length"
