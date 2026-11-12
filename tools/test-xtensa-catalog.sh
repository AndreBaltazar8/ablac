#!/usr/bin/env bash
# Native catalog and published metadata verification. The optional network
# mode downloads only bounded metadata; it never downloads an archive.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
mode=${2:-}
cd "$root"
export ABLA_SYSROOT="$root"
out="$root/build/xtensa-catalog-check"
mkdir -p "$out"
"$compiler" build tools/xtensa-catalog-check/main.ab -o "$out/check" --fast --no-cache
catalog=tools/xtensa-companions.json
fixtures=tests/cases/xtensa-catalog/metadata
"$out/check" check "$catalog" "$fixtures"
reject() { if "$@" > "$out/negative.out" 2>&1; then echo "unexpected catalog acceptance: $*" >&2; exit 1; fi; }
mkdir -p "$out/bad"
cp "$fixtures"/* "$out/bad/"
sed 's/6026ef035ce44b680075ef6a3c3ebc81179b6959b77387877695b14de270f8ba/0000000000000000000000000000000000000000000000000000000000000000/' "$fixtures/23.1.3-1.x86_64-linux" > "$out/bad/23.1.3-1.x86_64-linux"
reject "$out/check" check "$catalog" "$out/bad"
cp "$fixtures/23.1.3-1.x86_64-linux" "$out/bad/23.1.3-1.x86_64-linux"
sed 's/"buildRun":/"unexpected": true, "buildRun":/' "$fixtures/23.1.3-1.index" > "$out/bad/23.1.3-1.index"
reject "$out/check" check "$catalog" "$out/bad"
sed 's/x86_64-linux/arm64-macos/g' "$fixtures/23.1.3-1.index" > "$out/bad/23.1.3-1.index"
reject "$out/check" check "$catalog" "$out/bad"
printf '[]\n' > "$out/bad-catalog.json"
reject "$out/check" urls "$out/bad-catalog.json" "$out/bad"
printf '{"schema":1,"releases":{}}\n' > "$out/bad-catalog.json"
reject "$out/check" urls "$out/bad-catalog.json" "$out/bad"
printf '{"schema":1,"releases":{"23.1.3-1":[]}}\n' > "$out/bad-catalog.json"
reject "$out/check" urls "$out/bad-catalog.json" "$out/bad"
reject "$out/check" urls tools/fixtures/xtensa-companion-unpublished.json "$out/bad"
"$out/check" fixture tools/fixtures/xtensa-companion-unpublished.json "$out/bad"
sed 's/"status": "published"/"status": "pending-publication"/' "$catalog" > "$out/bad-catalog.json"
reject "$out/check" urls "$out/bad-catalog.json" "$out/bad"
sed 's/"x86_64-macos": {/"missing-platform": {/' "$catalog" > "$out/bad-catalog.json"
reject "$out/check" urls "$out/bad-catalog.json" "$out/bad"
sed 's@github.com/AndreBaltazar8/llvm-project@elsewhere.example/other@g' "$catalog" > "$out/bad-catalog.json"
reject "$out/check" urls "$out/bad-catalog.json" "$out/bad"
sed 's/6026ef035ce44b680075ef6a3c3ebc81179b6959b77387877695b14de270f8ba/0000000000000000000000000000000000000000000000000000000000000000/' "$catalog" > "$out/bad-catalog.json"
reject "$out/check" check "$out/bad-catalog.json" "$fixtures"
if [[ $mode == --published ]]; then
    mkdir -p "$out/published"
    "$out/check" urls "$catalog" "$out/published" > "$out/urls"
    while read -r name url; do
        limit=4096
        [[ $name == *.index ]] && limit=1048576
        curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 --max-filesize "$limit" "$url" -o "$out/published/$name"
        [[ $(wc -c < "$out/published/$name") -le $limit ]]
    done < "$out/urls"
    "$out/check" check "$catalog" "$out/published"
fi
printf '%s\n' 'xtensa catalog: native schema, pinned published metadata and negative controls passed'
