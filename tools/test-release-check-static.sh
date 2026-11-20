#!/usr/bin/env bash
# tools/release-check.sh and the static compiler (#806 step C): the static asset is an optional extra (neither expected nor an extra in
# the `assets` check, with or without it in the previous release's names), checked by `static` when present, and that check fails a
# file that is not a static-pie executable. Fake artifacts, no network: the convergence line fails without a run and is not judged.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd "$work"
mkdir artifacts
printf '#!/bin/sh\necho "ablac 9.9.9"\n' > artifacts/ablac-x86_64-linux
chmod +x artifacts/ablac-x86_64-linux
cp artifacts/ablac-x86_64-linux stage2
printf 'toolchain' > artifacts/abla-toolchain-x86_64-linux.tar.gz
for name in ablac-x86_64-linux abla-toolchain-x86_64-linux.tar.gz; do (cd artifacts && sha256sum "$name" > "$name.sha256"); done
ls artifacts | sort > expected-without
run() { # EXPECTED-FILE OUT -> the output lines
    "$root/tools/release-check.sh" v9.9.9 1 stage2 --artifacts artifacts --assets-from "$1" --out "$2" --source-ref 0000000000000000000000000000000000000000 2>&1 || true
}
line() { grep -E "^(PASS|FAIL) +$1 " <<< "$2" || true; }
without=$(run expected-without out1)
[[ $(line assets "$without") == PASS* ]] || { echo "assets without the static asset: $(line assets "$without")" >&2; exit 1; }
[[ -z $(line static "$without") ]] || { echo "a static line without a static asset" >&2; exit 1; }
# a static asset that is a script, not an executable image
printf '#!/bin/sh\necho "ablac 9.9.9"\n' > artifacts/ablac-static-x86_64-linux
(cd artifacts && sha256sum ablac-static-x86_64-linux > ablac-static-x86_64-linux.sha256)
with=$(run expected-without out2)
[[ $(line assets "$with") == PASS* ]] || { echo "assets with the static asset: $(line assets "$with")" >&2; exit 1; }
[[ $(line sha256 "$with") == PASS* ]] || { echo "sha256 with the static asset: $(line sha256 "$with")" >&2; exit 1; }
[[ $(line static "$with") == FAIL* ]] || { echo "a script passed as the static compiler: $(line static "$with")" >&2; exit 1; }
# the previous release's names include the static asset: a release without it is not missing it
(cd artifacts && ls | sort) > expected-with
rm -f artifacts/ablac-static-x86_64-linux artifacts/ablac-static-x86_64-linux.sha256
again=$(run expected-with out3)
[[ $(line assets "$again") == PASS* ]] || { echo "assets, static expected, none built: $(line assets "$again")" >&2; exit 1; }
echo "release-check static: the optional asset is judged by its own check"
