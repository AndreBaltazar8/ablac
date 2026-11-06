#!/usr/bin/env bash
# Rebuild exact v0.2.47 sources from that tag's seed, then compare the raw asset.
# Two builds mirror release.yml; keep fixed-compiler as the final link name.
set -euo pipefail
if [[ $# != 2 ]]; then
    echo 'usage: test-macos-published-rebuild.sh <v0.2.47-checkout> <fresh-report-directory>' >&2
    exit 2
fi
[[ $(uname -s) == Darwin ]] || { echo 'published Mach-O rebuild requires Darwin' >&2; exit 2; }
driver_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_root=$(cd -- "$1" && pwd)
report=$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$2")
mkdir -p "$(dirname -- "$report")"
mkdir "$report"  # Refuse stale artifacts instead of deleting them.
case $(uname -m) in
    arm64)
        asset=ablac-arm64-macos
        expected=9dabf38f755b2799bebd26fe6923805505fed0b87a5673af8880984e871d1d35
        ;;
    x86_64)
        asset=ablac-x86_64-macos
        expected=528ea7b619820215b63a678a8c4d43e55a326428014d13f92d9ee64db36c2e4d
        ;;
    *) echo 'unsupported macOS host architecture' >&2; exit 2 ;;
esac
commit=$(git -C "$source_root" rev-parse HEAD)
[[ $commit == b07265ee1312e6c6a33ba99b4693711423982fa7 ]]
[[ -z $(git -C "$source_root" status --porcelain --untracked-files=normal) ]]
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
{
    printf 'tag=v0.2.47\nsource_commit=%s\nsource_path=%s\nasset=%s\n' "$commit" "$source_root" "$asset"
    printf 'source_tree=%s\n' "$(git -C "$source_root" rev-parse 'HEAD^{tree}')"
    printf 'driver_commit=%s\n' "$(git -C "$driver_root" rev-parse HEAD)"
    uname -a
    sw_vers
    xcodebuild -version
    xcrun --sdk macosx --show-sdk-path
    xcrun --sdk macosx --show-sdk-version
    xcrun clang --version
    llvm-config --version --libdir
    opt --version
    llc --version
    xcrun ld -v 2>&1 || true
    brew list --versions llvm llvm@23 lld lld@23 openssl@3 binaryen || true
} > "$report/provenance.txt" 2>&1
curl --fail --location --retry 3 \
    "https://github.com/AndreBaltazar8/ablac/releases/download/v0.2.47/$asset" \
    -o "$report/published"
printf '%s  %s\n' "$expected" "$report/published" | shasum -a 256 --check
chmod +x "$report/published"
python3 "$driver_root/tools/test-macos-binary-comparison.py" "$report/published" \
    > "$report/comparator-controls.log" 2>&1
# Use the SOURCE TAG's pin (v0.2.46), not the driver's current moving pin.
unset ABLA_BOOTSTRAP_URL ABLA_BOOTSTRAP_SHA256 ABLA_SYSROOT ABLA_STDLIB ABLA_COMPILER_PAYLOAD
export ABLA_CACHE_DIR="$report/cache"
export ABLA_NATIVE_JOBS=4 ABLA_CODEGEN_JOBS=4 JOBS=4
(
    cd "$source_root"
    tools/bootstrap-compiler.sh build/bootstrap-ablac
) > "$report/seed-download.log" 2>&1
printf 'seed_sha256=%s\n' "$(sha "$source_root/build/bootstrap-ablac")" >> "$report/provenance.txt"
printf 'seed_version=%s\n' "$("$source_root/build/bootstrap-ablac" --version)" >> "$report/provenance.txt"
"$source_root/tools/build-self-hosted-current.sh" \
    "$source_root/build/bootstrap-ablac" "build/release/$asset" \
    > "$report/stage1.log" 2>&1
printf 'stage1_sha256=%s\n' "$(sha "$source_root/build/release/$asset")" >> "$report/provenance.txt"
"$source_root/tools/build-self-hosted-current.sh" \
    "$source_root/build/release/$asset" build/release/fixed-compiler \
    > "$report/stage2.log" 2>&1
cp "$source_root/build/release/fixed-compiler" "$report/rebuilt"
printf 'stage2_sha256=%s\n' "$(sha "$report/rebuilt")" >> "$report/provenance.txt"
# Retain ordinary compiler/adapter objects for attribution, without rebuilding.
for suffix in o host.o ll; do
    if [[ -f $source_root/build/release/fixed-compiler.$suffix ]]; then
        cp "$source_root/build/release/fixed-compiler.$suffix" "$report/rebuilt.$suffix"
    fi
done
[[ $("$report/rebuilt" --version) == 'ablac 0.2.47' ]]
[[ $("$report/published" --version) == 'ablac 0.2.47' ]]
for label in published rebuilt; do
    otool -l "$report/$label" > "$report/$label.load-commands.txt"
    otool -L "$report/$label" > "$report/$label.dependencies.txt"
    llvm-nm -n "$report/$label" > "$report/$label.symbols.txt"
    # Intel images may be unsigned. Record that instead of re-signing them.
    codesign -d --verbose=4 "$report/$label" > "$report/$label.codesign.txt" 2>&1 || true
    if grep -q 'CodeDirectory' "$report/$label.codesign.txt"; then
        codesign --verify --strict --verbose=4 "$report/$label" \
            >> "$report/$label.codesign.txt" 2>&1
    fi
done
python3 "$driver_root/tools/compare-macos-binaries.py" \
    "$report/published" "$report/rebuilt" "$report/comparison" \
    | tee "$report/comparison.log"
