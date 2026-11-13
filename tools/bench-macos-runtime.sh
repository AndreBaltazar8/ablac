#!/usr/bin/env bash
# CI-only measurement using raw published compilers and their exact release trees.
set -euo pipefail
[[ $# == 3 || $# == 5 ]] || { echo 'usage: bench-macos-runtime.sh <old-checkout> <new-checkout> <fresh-report> [<old-version> <new-version>]' >&2; exit 2; }
[[ $(uname -s) == Darwin ]] || { echo 'macOS runtime benchmark requires Darwin' >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
old=$(cd -- "$1" && pwd)
new=$(cd -- "$2" && pwd)
report=$(node -e 'console.log(require("path").resolve(process.argv[1]))' "$3")
old_version=${4:-v0.2.45}
new_version=${5:-v0.2.47}
# The release tag's commit and the published compiler's SHA-256, per version and architecture.
release_commit() {
    case $1 in
        v0.2.45) echo ca9221b0615cd419284a9e8e9f671bf8429ccd3b ;;
        v0.2.47) echo b07265ee1312e6c6a33ba99b4693711423982fa7 ;;
        v0.2.51) echo 1758d94e64b0e7f31f22107f8556fd63dc4351c6 ;;
        *) echo "no pinned commit for $1" >&2; return 1 ;;
    esac
}
release_sha() {
    case $1-$(uname -m) in
        v0.2.45-arm64) echo 1c3ffe43ae747bea2d3c36bd637f02ab40e7c674cb92a8d2b368942e08d05999 ;;
        v0.2.45-x86_64) echo 04b528c49d07b7635ed9ef4805e300e805029f7a0dfbac86e1da12a318688a47 ;;
        v0.2.47-arm64) echo 9dabf38f755b2799bebd26fe6923805505fed0b87a5673af8880984e871d1d35 ;;
        v0.2.47-x86_64) echo 528ea7b619820215b63a678a8c4d43e55a326428014d13f92d9ee64db36c2e4d ;;
        v0.2.51-arm64) echo 5afdb175749e9f6a91b2d6eeda32b1f60e985dca1d35f21ee800f53a88eb774f ;;
        v0.2.51-x86_64) echo 535862923c03c25e808e802770656efcb771ad3fabb620b2453513c30496c7ea ;;
        *) echo "no pinned compiler hash for $1 on $(uname -m)" >&2; return 1 ;;
    esac
}
[[ $(git -C "$old" rev-parse HEAD) == $(release_commit "$old_version") ]]
[[ $(git -C "$new" rev-parse HEAD) == $(release_commit "$new_version") ]]
[[ -z $(git -C "$old" status --porcelain) && -z $(git -C "$new" status --porcelain) ]]
# Do not silently compare different workloads between releases.
git -C "$root" diff --exit-code "$old_version" "$new_version" -- \
    tests/benchmarks examples/event-http-server.ab examples/https-client.ab
mkdir -p "$(dirname -- "$report")"
mkdir "$report"
case $(uname -m) in
    arm64) asset=ablac-arm64-macos ;;
    x86_64) asset=ablac-x86_64-macos ;;
    *) echo 'unsupported macOS architecture' >&2; exit 2 ;;
esac
for version in "$old_version" "$new_version"; do
    curl --fail --location --retry 3 \
        "https://github.com/AndreBaltazar8/ablac/releases/download/$version/$asset" \
        -o "$report/$version.bin"
    printf '%s  %s\n' "$(release_sha "$version")" "$report/$version.bin" | shasum -a 256 --check
    chmod +x "$report/$version.bin"
done
{
    printf 'driver=%s\n' "$(git -C "$root" rev-parse HEAD)"
    date -u
    uname -a
    sw_vers
    sysctl hw.ncpu hw.memsize machdep.cpu.brand_string || true
    xcodebuild -version
    xcrun --sdk macosx --show-sdk-path
    xcrun --sdk macosx --show-sdk-version
    xcrun clang --version
    llvm-config --version --libdir
    strip -V 2>&1 || true
    uptime
} > "$report/provenance.txt" 2>&1
node "$root/tools/bench-macos-runtime.mjs" \
    --old-root "$old" --new-root "$new" \
    --old-compiler "$report/$old_version.bin" --new-compiler "$report/$new_version.bin" \
    --old-version "$old_version" --new-version "$new_version" \
    --output "$report/results"
cat "$report/results/report.md"
