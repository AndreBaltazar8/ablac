#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
export ABLA_SYSROOT="$root"
out=build/tar-reader
rm -rf "$out"
mkdir -p "$out/tree/root/sub"
printf 'payload\n' > "$out/tree/root/file.txt"
printf 'nested\n' > "$out/tree/root/sub/nested.txt"
"$compiler" build tests/cases/tar-reader/probe.ab -o "$out/probe" --fast --no-cache
"$compiler" build tests/cases/tar-reader/companion.ab -o "$out/companion" --fast --no-cache
tar --format=ustar -cf "$out/gnu-ustar.tar" -C "$out/tree" root
tools/verify-fixture-manifest.sh tests/cases/tar-reader/fixtures
cp tests/cases/tar-reader/fixtures/*.tar "$out/"
# Archives damaged from the system tar's output: first byte flipped (header checksum),
# one stray block after the end marker, and a cut inside the first header.
cp "$out/gnu-ustar.tar" "$out/bad-checksum.tar"
first=$(od -An -tu1 -N1 "$out/gnu-ustar.tar" | tr -d ' ')
printf "\\$(printf '%03o' $((first ^ 1)))" | dd of="$out/bad-checksum.tar" bs=1 seek=0 conv=notrunc 2> /dev/null
cmp -s "$out/gnu-ustar.tar" "$out/bad-checksum.tar" && { echo 'tar-reader: bad-checksum.tar was not damaged' >&2; exit 1; }
{ cat "$out/gnu-ustar.tar"; printf X; head -c 511 /dev/zero; } > "$out/bad-trailing.tar"
head -c 100 "$out/gnu-ustar.tar" > "$out/bad-truncated.tar"
"$out/probe" "$out/gnu-ustar.tar" '' verify
"$out/probe" "$out/publisher.tar" '' verify
"$out/probe" "$out/raw.tar" '' raw
"$out/probe" "$out/rawprefix.tar" '' rawprefix
for test in pax gnu-long symlink; do "$out/probe" "$out/$test.tar" unsupported; done
for test in absolute traversal duplicate ancestor-first ancestor-last bad-checksum bad-trailing bad-truncated; do "$out/probe" "$out/$test.tar" invalid; done
"$out/probe" "$out/gnu-ustar.tar" '' mutate
"$compiler" build tests/cases/tar-reader/build.ab -o "$out/build" --fast --no-cache
node --input-type=module - "$out/pure.wasm" <<'JS'
import {readFileSync} from 'node:fs';
const {instance} = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
if (Number(instance.exports.tarCheck()) !== 42) process.exit(1);
JS
"$compiler" build tests/cases/tar-reader/pure.ab --target-triple xtensa-esp-unknown-elf --object-format elf --emit object -o "$out/xtensa.o" --fast --no-cache
if [[ -n ${ABLA_TEST_XTENSA_COMPANION:-} && -f $ABLA_TEST_XTENSA_COMPANION ]]; then
    "$out/companion" "$ABLA_TEST_XTENSA_COMPANION"
    echo 'tar-reader: cached Linux companion gzip + tar passed'
else
    echo 'tar-reader: cached Linux companion absent; gzip + tar check skipped'
fi
echo 'tar-reader: ustar, rejection, mutations, hostless Wasm and Xtensa passed'
