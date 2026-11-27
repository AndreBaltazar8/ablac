#!/usr/bin/env bash
# tools/release-check.sh and the browser compiler (tools/build-playground.sh, #1138): abla-playground-<version>.tar.gz is an optional extra (neither
# expected nor an extra in the `assets` check), judged by `playground` when present: a manifest that names the tag's version, a module that matches its
# hash, a stdlib bundle that carries its hash. Fake artifacts and no network (tools/lib/test-offline.sh): a call that reaches for it fails the test.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
. "$root/tools/lib/test-offline.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd "$work"
offline_setup "$work"
mkdir artifacts
printf '#!/bin/sh\necho "ablac 9.9.9"\n' > artifacts/ablac-x86_64-linux
chmod +x artifacts/ablac-x86_64-linux
cp artifacts/ablac-x86_64-linux stage2
(cd artifacts && sha256sum ablac-x86_64-linux > ablac-x86_64-linux.sha256)
ls artifacts | sort > expected
run() { # OUT -> the output lines
    PATH="$offline:$PATH" "$root/tools/release-check.sh" v9.9.9 1 stage2 --artifacts artifacts --assets-from expected --out "$1" "${offline_flags[@]}" 2>&1 || true
}
line() { grep -E "^(PASS|FAIL|SKIP) +$1 " <<< "$2" || true; }
package() { # VERSION-IN-MANIFEST: a fake package, packed as the real one is
    rm -rf pkg abla-playground-9.9.9
    mkdir -p abla-playground-9.9.9
    printf 'wasm' > module.bin
    printf 'bundle' > bundle.bin
    module_hash=$(sha256sum module.bin | cut -d' ' -f1)
    bundle_hash=$(sha256sum bundle.bin | cut -d' ' -f1)
    cp module.bin "abla-playground-9.9.9/compiler-${module_hash:0:16}.wasm"
    cp bundle.bin "abla-playground-9.9.9/stdlib-$bundle_hash.bin.br"
    cat > abla-playground-9.9.9/manifest.json <<JSON
{
  "format": 1,
  "version": "$1",
  "compiler": {
    "file": "compiler-${module_hash:0:16}.wasm",
    "bytes": 4,
    "sha256": "$module_hash"
  },
  "stdlib": {
    "file": "stdlib-$bundle_hash.bin.br",
    "bytes": 6,
    "sha256": "$bundle_hash"
  },
  "host": []
}
JSON
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -czf artifacts/abla-playground-9.9.9.tar.gz abla-playground-9.9.9
    (cd artifacts && sha256sum abla-playground-9.9.9.tar.gz > abla-playground-9.9.9.tar.gz.sha256)
}
without=$(run out1)
[[ $(line assets "$without") == PASS* ]] || { echo "assets without the playground: $(line assets "$without")" >&2; exit 1; }
[[ -z $(line playground "$without") ]] || { echo "a playground line without a playground archive" >&2; exit 1; }
package 9.9.9
good=$(run out2)
[[ $(line assets "$good") == PASS* ]] || { echo "assets with the playground: $(line assets "$good")" >&2; exit 1; }
[[ $(line sha256 "$good") == PASS* ]] || { echo "sha256 with the playground: $(line sha256 "$good")" >&2; exit 1; }
[[ $(line playground "$good") == PASS* ]] || { echo "a good playground package failed: $(line playground "$good")" >&2; exit 1; }
package 9.9.8
wrong=$(run out3)
[[ $(line playground "$wrong") == FAIL*"does not name version 9.9.9"* ]] || { echo "a manifest of another version passed: $(line playground "$wrong")" >&2; exit 1; }
package 9.9.9
printf 'tampered' > "abla-playground-9.9.9/compiler-${module_hash:0:16}.wasm"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -czf artifacts/abla-playground-9.9.9.tar.gz abla-playground-9.9.9
(cd artifacts && sha256sum abla-playground-9.9.9.tar.gz > abla-playground-9.9.9.tar.gz.sha256)
tampered=$(run out4)
[[ $(line playground "$tampered") == FAIL*"does not match its hash"* ]] || { echo "a tampered module passed: $(line playground "$tampered")" >&2; exit 1; }
offline_check
echo "release-check playground: an optional extra, judged by its manifest, its module hash and its stdlib bundle"
