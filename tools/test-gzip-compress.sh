#!/usr/bin/env bash
# gzipCompress (abla/compression/gzip): tests/cases/gzip-compress/main.ab compresses a corpus (tiny and empty inputs, runs, repetitions at the edges of the 32 KiB window and
# the 258-byte match, incompressible data at the sizes where stored blocks split, many-literal data past a block of 16383 tokens, mixes, and real text and JSON) and checks
# each with our own decoder; here every .gz is also decoded by gzip and by Node's zlib and compared with the original, and the sizes of the text and JSON samples are
# held within 3% of `gzip -6`'s. Usage: tools/test-gzip-compress.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/gzip-compress
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/gzip-compress/main.ab -o "$out/main" --no-cache
result=$("$root/tools/run-limited.sh" "$out/main" "$out" docs/networking.md docs/tls.md tests/vectors/crypto/wycheproof/ecdsa_secp256r1_sha256_test.json) || { echo "gzip-compress: $result" >&2; exit 1; }
case $result in *'gzip-compress ok '*) ;; *) echo "gzip-compress: $result" >&2; exit 1 ;; esac
count=0
for packed in "$out"/*.gz; do
    name=${packed%.gz}
    gzip -t "$packed" || { echo "gzip -t refused $packed" >&2; exit 1; }
    gzip -dc "$packed" | cmp - "$name.raw" || { echo "gzip -d gave other bytes for $packed" >&2; exit 1; }
    count=$((count + 1))
done
node --input-type=module - "$out" <<'JS'
import {readdirSync, readFileSync} from 'node:fs';
import {gunzipSync} from 'node:zlib';
let checked = 0;
for (const entry of readdirSync(process.argv[2]).filter(name => name.endsWith('.gz'))) {
    const packed = readFileSync(`${process.argv[2]}/${entry}`);
    const raw = readFileSync(`${process.argv[2]}/${entry.slice(0, -3)}.raw`);
    if (!gunzipSync(packed).equals(raw)) { console.error(`node zlib: other bytes for ${entry}`); process.exit(1); }
    checked += 1;
}
console.log(`node zlib decoded ${checked} members`);
JS
# The ratio against gzip -6 on the real files.
for file in file-1 file-2 file-3; do
    ours=$(wc -c < "$out/$file.gz")
    theirs=$(gzip -6 -c "$out/$file.raw" | wc -c)
    (( ours * 100 <= theirs * 103 )) || { echo "gzip-compress: $file is $ours bytes, gzip -6 gives $theirs" >&2; exit 1; }
done
echo "gzip-compress: $count members decoded by gzip, Node's zlib and ours; samples within 3% of gzip -6"
