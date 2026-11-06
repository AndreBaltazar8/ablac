#!/usr/bin/env bash
# CI-only measurement using raw published compilers and their exact release trees.
set -euo pipefail
[[ $# == 3 ]] || { echo 'usage: bench-macos-runtime.sh <v045-checkout> <v047-checkout> <fresh-report>' >&2; exit 2; }
[[ $(uname -s) == Darwin ]] || { echo 'macOS runtime benchmark requires Darwin' >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
old=$(cd -- "$1" && pwd)
new=$(cd -- "$2" && pwd)
report=$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$3")
[[ $(git -C "$old" rev-parse HEAD) == ca9221b0615cd419284a9e8e9f671bf8429ccd3b ]]
[[ $(git -C "$new" rev-parse HEAD) == b07265ee1312e6c6a33ba99b4693711423982fa7 ]]
[[ -z $(git -C "$old" status --porcelain) && -z $(git -C "$new" status --porcelain) ]]
# Do not silently compare different workloads between releases.
git -C "$root" diff --exit-code v0.2.45 v0.2.47 -- \
    tests/benchmarks examples/event-http-server.ab examples/https-client.ab
mkdir -p "$(dirname -- "$report")"
mkdir "$report"
case $(uname -m) in
    arm64)
        asset=ablac-arm64-macos
        old_sha=1c3ffe43ae747bea2d3c36bd637f02ab40e7c674cb92a8d2b368942e08d05999
        new_sha=9dabf38f755b2799bebd26fe6923805505fed0b87a5673af8880984e871d1d35
        ;;
    x86_64)
        asset=ablac-x86_64-macos
        old_sha=04b528c49d07b7635ed9ef4805e300e805029f7a0dfbac86e1da12a318688a47
        new_sha=528ea7b619820215b63a678a8c4d43e55a326428014d13f92d9ee64db36c2e4d
        ;;
    *) echo 'unsupported macOS architecture' >&2; exit 2 ;;
esac
for version in v0.2.45 v0.2.47; do
    curl --fail --location --retry 3 \
        "https://github.com/AndreBaltazar8/ablac/releases/download/$version/$asset" \
        -o "$report/$version.bin"
    if [[ $version == v0.2.45 ]]; then expected=$old_sha; else expected=$new_sha; fi
    printf '%s  %s\n' "$expected" "$report/$version.bin" | shasum -a 256 --check
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
python3 "$root/tools/bench-macos-runtime.py" \
    --old-root "$old" --new-root "$new" \
    --old-compiler "$report/v0.2.45.bin" --new-compiler "$report/v0.2.47.bin" \
    --output "$report/results"
cat "$report/results/report.md"
