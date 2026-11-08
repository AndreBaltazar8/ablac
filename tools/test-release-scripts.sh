#!/usr/bin/env bash
# tools/release-check.sh and tools/release-pin.sh on a made-up release (no network, no gh):
# what they accept, and each way they must refuse.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s)/$(uname -m) != Linux/x86_64 ]]; then
    echo "release scripts: skipped (release-check runs the Linux binary)"
    exit 0
fi
check=$project_root/tools/release-check.sh
pin=$project_root/tools/release-pin.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

sha() { sha256sum "$1" | cut -d' ' -f1; }
# Changes the first hex digit of a .sha256 file to a different one.
doctor() {
    local line first
    line=$(cat "$1")
    first=${line:0:1}
    printf '%s%s\n' "$([[ $first == a ]] && echo b || echo a)" "${line:1}" >"$1"
    [[ $(cat "$1") != "$line" ]] || fail "doctor changed nothing in $1"
}
fail() { echo "release scripts: $*" >&2; exit 1; }
expect_fail() { # description command...  (the command must exit non-zero and print FAIL or an error)
    local description=$1
    shift
    if "$@" >"$work/out.txt" 2>&1; then
        cat "$work/out.txt" >&2
        fail "$description: accepted"
    fi
}

# --- A made-up release v9.9.9: a Linux "binary" that prints its version, and the rest as files.
release=$work/release
mkdir -p "$release"
printf '#!/bin/sh\necho "ablac 9.9.9"\n' >"$release/ablac-x86_64-linux"
chmod +x "$release/ablac-x86_64-linux"
printf 'intel mac binary\n' >"$release/ablac-x86_64-macos"
printf 'arm mac binary\n' >"$release/ablac-arm64-macos"
for platform in x86_64-linux x86_64-macos arm64-macos; do
    printf 'toolchain %s\n' "$platform" >"$release/abla-toolchain-$platform.tar.gz"
done
for file in "$release"/*; do
    [[ $file == *.sha256 ]] && continue
    printf '%s  %s\n' "$(sha "$file")" "$(basename "$file")" >"$file.sha256"
done
( cd "$release" && ls ) >"$work/names.txt"
[[ $(wc -l <"$work/names.txt") -eq 12 ]] || fail "fixture has the wrong number of files"
stage2=$work/stage2
cp "$release/ablac-x86_64-linux" "$stage2"

run_check() { # artifacts-dir tag stage2 [extra...]
    local directory=$1 tag=$2 local_stage2=$3
    shift 3
    "$check" "$tag" 1 "$local_stage2" --artifacts "$directory" --assets-from "$work/names.txt" \
        --out "$work/out-$RANDOM" "$@"
}

# --- release-check: accepts the good release.
output=$(run_check "$release" v9.9.9 "$stage2") || { echo "$output" >&2; fail "release-check refused a good release"; }
for name in assets sha256 version stage2; do
    grep -q "^PASS  $name" <<<"$output" || { echo "$output" >&2; fail "no PASS line for $name"; }
done
grep -q '^RESULT: PASS' <<<"$output" || fail "no RESULT: PASS"

# Layout as `gh run download` leaves it (a folder per artifact) is flattened.
nested=$work/nested
mkdir -p "$nested/ablac-x86_64-linux" "$nested/rest"
for file in "$release"/*; do
    if [[ $file == *x86_64-linux* && $file != *toolchain* ]]; then cp "$file" "$nested/ablac-x86_64-linux/"; else cp "$file" "$nested/rest/"; fi
done
run_check "$nested" v9.9.9 "$stage2" >/dev/null || fail "release-check refused a nested layout"

# --- release-check: each way it must refuse.
mutated() { # name  -> a copy of the release in $work/m-<name>
    rm -rf "$work/m-$1"
    cp -r "$release" "$work/m-$1"
    echo "$work/m-$1"
}
directory=$(mutated doctored-sha)
doctor "$directory/ablac-x86_64-macos.sha256"
expect_fail "a doctored sha256" run_check "$directory" v9.9.9 "$stage2"
grep -q '^FAIL  sha256' "$work/out.txt" || fail "a doctored sha256 did not fail the sha256 check"

directory=$(mutated doctored-asset)
printf 'x' >>"$directory/abla-toolchain-arm64-macos.tar.gz"
expect_fail "an asset changed after its sha256" run_check "$directory" v9.9.9 "$stage2"
grep -q '^FAIL  sha256' "$work/out.txt" || fail "a changed asset did not fail the sha256 check"

directory=$(mutated missing)
rm "$directory/abla-toolchain-x86_64-macos.tar.gz" "$directory/abla-toolchain-x86_64-macos.tar.gz.sha256"
expect_fail "a missing asset" run_check "$directory" v9.9.9 "$stage2"
grep -q '^FAIL  assets.*missing' "$work/out.txt" || fail "a missing asset did not fail the assets check"

directory=$(mutated extra)
printf 'x\n' >"$directory/surprise.txt"
expect_fail "an extra asset" run_check "$directory" v9.9.9 "$stage2"
grep -q '^FAIL  assets.*extra' "$work/out.txt" || fail "an extra asset did not fail the assets check"

expect_fail "a wrong version" run_check "$release" v9.9.8 "$stage2"
grep -q "^FAIL  version.*wanted 'ablac 9.9.8'" "$work/out.txt" || fail "a wrong version did not fail the version check"

printf 'a different compiler\n' >"$work/other-stage2"
expect_fail "a different local stage 2" run_check "$release" v9.9.9 "$work/other-stage2"
grep -q '^FAIL  stage2' "$work/out.txt" || fail "a different stage 2 did not fail the stage2 check"

# --- release-pin: a checkout pinned to v9.9.8 moves to v9.9.9.
root=$work/root
mkdir -p "$root/tools" "$root/docs"
cat >"$root/tools/bootstrap-compiler.sh" <<'EOF'
version=v9.9.8
case "$platform/$machine" in
    Linux/x86_64)
        artifact=ablac-x86_64-linux
        platform_sha256=1111111111111111111111111111111111111111111111111111111111111111
        ;;
    Darwin/x86_64)
        artifact=ablac-x86_64-macos
        platform_sha256=2222222222222222222222222222222222222222222222222222222222222222
        ;;
    Darwin/arm64)
        artifact=ablac-arm64-macos
        platform_sha256=3333333333333333333333333333333333333333333333333333333333333333
        ;;
esac
EOF
printf 'compiler from `v9.9.8`, then recompiles\nsetup-abla version: '"'"'9.9.8'"'"'\n' >"$root/README.md"
printf 'native `v9.9.8` artifact\nstable v9.9.8 binaries\nv9.9.8 bootstrap\npinned v9.9.8 compiler\nthe v9.9.7 bridge\n' >"$root/docs/bootstrap.md"
snapshot() { cat "$root/tools/bootstrap-compiler.sh" "$root/README.md" "$root/docs/bootstrap.md" | sha256sum; }
before=$(snapshot)

# Refusals leave the checkout untouched: a sha256 asset that does not match its binary, a malformed one,
# a missing one, a release that is not there.
directory=$work/pin-doctored
cp -r "$release" "$directory"
doctor "$directory/ablac-x86_64-linux.sha256"
expect_fail "a .sha256 that does not match its binary" "$pin" v9.9.9 --dir "$directory" --root "$root"
[[ $(snapshot) == "$before" ]] || fail "a refused pin changed the checkout"
directory=$work/pin-malformed
cp -r "$release" "$directory"
printf 'not a checksum\n' >"$directory/ablac-arm64-macos.sha256"
expect_fail "a malformed .sha256" "$pin" v9.9.9 --dir "$directory" --root "$root"
[[ $(snapshot) == "$before" ]] || fail "a refused pin changed the checkout"
directory=$work/pin-missing
cp -r "$release" "$directory"
rm "$directory/ablac-x86_64-macos.sha256"
expect_fail "a missing .sha256" "$pin" v9.9.9 --dir "$directory" --root "$root"
[[ $(snapshot) == "$before" ]] || fail "a refused pin changed the checkout"
expect_fail "a bad tag" "$pin" 9.9.9 --dir "$release" --root "$root"

# The good release pins.
"$pin" v9.9.9 --dir "$release" --root "$root" >"$work/out.txt" 2>&1 || { cat "$work/out.txt" >&2; fail "release-pin refused a good release"; }
grep -q '^version=v9.9.9$' "$root/tools/bootstrap-compiler.sh" || fail "the version was not moved"
for platform in x86_64-linux x86_64-macos arm64-macos; do
    grep -A1 "artifact=ablac-$platform$" "$root/tools/bootstrap-compiler.sh" | grep -q "platform_sha256=$(sha "$release/ablac-$platform")$" ||
        fail "the $platform sha256 was not pinned"
done
grep -q 'from `v9.9.9`' "$root/README.md" || fail "README.md was not moved"
grep -q "'9.9.8'" "$root/README.md" || fail "the setup-abla version (the Prepare commit's) was changed"
grep -q '^note: README.md still has' "$work/out.txt" || fail "no note about the setup-abla version"
[[ $(grep -c 'v9.9.9' "$root/docs/bootstrap.md") -eq 4 ]] || fail "docs/bootstrap.md has the wrong number of v9.9.9 mentions"
grep -q 'v9.9.7 bridge' "$root/docs/bootstrap.md" || fail "a mention of another version was changed"
echo "release scripts: a good release is accepted; a doctored sha256, a changed asset, a missing or extra asset, a wrong version and another stage 2 are refused; a pin moves the version and three sha256s and refuses a bad .sha256"
