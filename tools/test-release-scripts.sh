#!/usr/bin/env bash
# tools/release-check.sh, release-convergence.sh, release-notes.sh, release-pin.sh and gate.sh and gate-release.sh (--dry-run) on a made-up release (no network, no gh):
# what they accept, and each way they must refuse.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s)/$(uname -m) != Linux/x86_64 ]]; then
    echo "release scripts: skipped (release-check runs the Linux binary)"
    exit 0
fi
check=$project_root/tools/release-check.sh
convergence=$project_root/tools/release-convergence.sh
pin=$project_root/tools/release-pin.sh
compiler=${1:-build/ablac}
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

# The comparison.json a green bootstrap-convergence run leaves: lineage v9.9.8 (route A its release, route B v9.9.7),
# the candidate being the commit the release is made from.
source_ref=0123456789abcdef0123456789abcdef01234567
hex64() { printf '%064d' "$1" | tr 0 "$2"; }
comparison=$work/comparison.json
cat >"$comparison" <<JSON
{"passed": true, "candidate": {"revision": "$source_ref", "tree": "t"}, "lineage": "v9.9.8",
 "seeds": {"a": {"version": "v9.9.8", "sha256": "$(hex64 0 a)"}, "b": {"version": "v9.9.7", "sha256": "$(hex64 0 b)"}},
 "historical_revision": "$(printf '%040d' 0 | tr 0 c)", "canonical_root": "/build/source", "entry": "src/orc_main.ab",
 "canonical_ir_sha256": "$(hex64 0 1)", "stage2_binary_sha256": "$(hex64 0 2)", "stage2_object_sha256": "$(hex64 0 3)",
 "toolchain": {"environment_sha256": "$(hex64 0 4)", "closure_sha256": "$(hex64 0 5)"}}
JSON
convergence_flags=(--lineage v9.9.8 --source-ref "$source_ref" --convergence-comparison "$comparison")
run_check() { # artifacts-dir tag stage2 [extra...]
    local directory=$1 tag=$2 local_stage2=$3
    shift 3
    "$check" "$tag" 1 "$local_stage2" --artifacts "$directory" --assets-from "$work/names.txt" \
        --out "$work/out-$RANDOM" "${convergence_flags[@]}" "$@"
}

# --- release-check: accepts the good release.
output=$(run_check "$release" v9.9.9 "$stage2") || { echo "$output" >&2; fail "release-check refused a good release"; }
for name in assets sha256 version stage2 convergence; do
    grep -q "^PASS  $name" <<<"$output" || { echo "$output" >&2; fail "no PASS line for $name"; }
done
grep -q '^RESULT: PASS' <<<"$output" || fail "no RESULT: PASS"
grep -q '^SKIP  signature' <<<"$output" || { echo "$output" >&2; fail "an unsigned run's artifacts: no SKIP for the signature check"; }
if grep -qE '^(PASS|FAIL)  windows(-arm64)?-fixpoint' <<<"$output"; then
    fail "a release without Windows zips required Windows fixed points"
fi
grep -q 'tools/sign-release.sh' <<<"$output" || fail "a passing unsigned release names no next step (sign it)"
# A directory signed by a key that is not release-signing.pub fails the signature check.
ssh-keygen -q -t ed25519 -N '' -C stranger -f "$work/stranger" >/dev/null
signed_dir=$work/signed-by-stranger
cp -r "$release" "$signed_dir"
(cd "$signed_dir" && sha256sum -- * > SHA256SUMS)
ssh-keygen -Y sign -f "$work/stranger" -n abla-release "$signed_dir/SHA256SUMS" >/dev/null 2>&1
expect_fail "a release signed by a key that is not release-signing.pub" run_check "$signed_dir" v9.9.9 "$stage2"
grep -q '^FAIL  signature' "$work/out.txt" || fail "a foreign signature did not fail the signature check"

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

# Exercise release-check with real PE files and the same PE reader it uses for a release.
if command -v llvm-mc >/dev/null && command -v lld-link >/dev/null &&
    command -v zip >/dev/null && command -v unzip >/dev/null && command -v jq >/dev/null; then
    ABLA_SYSROOT="$project_root" "$compiler" build "$project_root/tools/pe-info/main.ab" -o "$work/pe-info" --fast --no-cache
    pe_fixture() {
        local arch=$1 machine=$2 version=$3 output=$4
        shift 4
        printf '.text\n.globl entry\nentry:\n  ret\n.section .rdata,"dr"\n.asciz "ablac %s"\n' "$version" |
            llvm-mc -triple "$arch-pc-windows-msvc" -filetype=obj -o "$work/windows.obj"
        lld-link /nologo /subsystem:console /entry:entry /nodefaultlib /opt:noref \
            "/machine:$machine" "/out:$output" "$work/windows.obj" "$@"
    }
    package_fixture() {
        local image=$1
        cp "$image" "$windows_tree/$top/bin/ablac.exe"
        rm -f "$directory/$asset"
        (cd "$windows_tree" && zip -q -r "$directory/$asset" "$top")
        (cd "$directory" && sha256sum "$asset" > "$asset.sha256")
    }
    windows_gh=$work/windows-gh
    mkdir "$windows_gh"
    cat > "$windows_gh/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == run && $3 == 1 && $4 == -R && $5 == AndreBaltazar8/ablac ]] || exit 2
if [[ $2 == download ]]; then
    [[ $6 == --pattern && $7 == 'ablac-*' && $8 == -D ]] || exit 2
    cp -p "$FIXPOINT_ASSETS/"* "$9/"
    touch "$9/static-suite-source.sha"
    exit 0
fi
[[ $2 == view ]] || exit 2
case $6 in
    --json) [[ $7 == workflowName,jobs ]] && cat "$FIXPOINT_RESPONSE/jobs" ;;
    --job) [[ $8 == --log ]] && cat "$FIXPOINT_RESPONSE/job-$7" ;;
    *) exit 2 ;;
esac
SH
    chmod +x "$windows_gh/gh"
    windows_jobs() {
        printf 'windows-fixpoint\tcompleted\t%s\t11\n' "$1"
        printf 'windows-arm64 / Compare two native ARM64 compiler self-builds\tcompleted\t%s\t22\n' "$2"
    }
    fixture_fixpoint_log() { # zip, stage 2, stage 3, tier
        printf 'job\tstep\t2026-01-01T00:00:00Z Windows fixed-point zip SHA-256: %s\r\n' "$(sha "$1")"
        printf 'job\tstep\t2026-01-01T00:00:00Z ablac.exe stage2 %s, stage3 %s\r\n' "$2" "$3"
        printf 'job\tstep\t2026-01-01T00:00:00Z Windows stage2 == stage3 (%s)\r\n' "$4"
    }
    check_windows() {
        PATH="$windows_gh:$PATH" FIXPOINT_RESPONSE="$windows_gh" ABLA_PE_INFO="$work/pe-info" \
            run_check "$directory" v9.9.9 "$stage2"
    }

    directory=$(mutated windows-arm64)
    asset=ablac-windows-arm64.zip
    top=abla-toolchain-aarch64-windows
    windows_tree=$work/windows-tree
    mkdir -p "$windows_tree/$top"/{bin,share/abla/stdlib,share/abla/runtime/windows/imports,share/licenses}
    touch "$windows_tree/$top/share/abla/runtime/windows/imports/kernel32.txt" "$windows_tree/$top/share/licenses/abla.txt"
    pe_fixture aarch64 arm64 9.9.9 "$work/arm64.exe"
    cp "$work/arm64.exe" "$windows_tree/$top/bin/llvm-objcopy.exe"
    package_fixture "$work/arm64.exe"
    fixed_pe=$(hex64 0 a)
    windows_jobs skipped success > "$windows_gh/jobs"
    fixture_fixpoint_log "$directory/$asset" "$fixed_pe" "${fixed_pe^^}" native > "$windows_gh/job-22"
    output=$(check_windows) || { echo "$output" >&2; fail 'release-check rejected the ARM64 zip'; }
    grep -q '^PASS  windows-arm64 ' <<< "$output" || fail 'no PASS for the ARM64 zip'
    grep -q "^PASS  windows-arm64-fixpoint .* $fixed_pe$" <<< "$output" || fail 'no matching ARM64 stage 2/3 PE hash'

    # A two-architecture release must have independent green, native jobs for its exact zips.
    arm_asset=$asset arm_top=$top
    asset=abla-toolchain-x86_64-windows.zip
    top=abla-toolchain-x86_64-windows
    cp -R "$windows_tree/$arm_top" "$windows_tree/$top"
    pe_fixture x86_64 x64 9.9.9 "$work/x64.exe"
    cp "$work/x64.exe" "$windows_tree/$top/bin/llvm-objcopy.exe"
    package_fixture "$work/x64.exe"
    windows_jobs success success > "$windows_gh/jobs"
    fixture_fixpoint_log "$directory/$asset" "$fixed_pe" "$fixed_pe" native > "$windows_gh/job-11"
    output=$(PATH="$windows_gh:$PATH" FIXPOINT_RESPONSE="$windows_gh" FIXPOINT_ASSETS="$directory" \
        ABLA_PE_INFO="$work/pe-info" "$check" v9.9.9 1 "$stage2" --assets-from "$work/names.txt" \
        --out "$work/windows-both-out" "${convergence_flags[@]}") ||
        { echo "$output" >&2; fail 'release-check rejected two green fixed points'; }
    for label in windows-fixpoint windows-arm64-fixpoint; do
        grep -q "^PASS  $label " <<< "$output" || fail "no PASS for $label"
    done
    windows_jobs success failure > "$windows_gh/jobs"
    expect_fail 'a red ARM64 fixed point next to a green x64 one' check_windows
    grep -q '^FAIL  windows-arm64-fixpoint .*no unique successful' "$work/out.txt"
    windows_jobs success skipped > "$windows_gh/jobs"
    expect_fail 'an ARM64 zip with a skipped fixed point' check_windows
    grep -q '^FAIL  windows-arm64-fixpoint .*no unique successful' "$work/out.txt"
    windows_jobs success success > "$windows_gh/jobs"
    fixture_fixpoint_log "$directory/$asset" "$fixed_pe" "$(hex64 0 b)" native > "$windows_gh/job-11"
    expect_fail 'different x64 stage 2/3 PE hashes' check_windows
    grep -q '^FAIL  windows-fixpoint .*different stage 2/3 PE hashes' "$work/out.txt"
    fixture_fixpoint_log "$directory/$asset" "$fixed_pe" "$fixed_pe" interp > "$windows_gh/job-11"
    expect_fail 'a green interpreter run for a release zip' check_windows
    grep -q '^FAIL  windows-fixpoint .*did not complete the native tier' "$work/out.txt"
    fixture_fixpoint_log "$directory/$arm_asset" "$fixed_pe" "$fixed_pe" native > "$windows_gh/job-11"
    expect_fail 'a fixed point for different zip bytes' check_windows
    grep -q '^FAIL  windows-fixpoint .*did not verify this Windows zip' "$work/out.txt"
    rm "$directory/$asset" "$directory/$asset.sha256"
    asset=$arm_asset top=$arm_top

    "$project_root/tools/release-sbom.sh" v9.9.9 "$directory" "$work/windows-arm64.spdx.json"
    sdk_pin=$project_root/nix/llvm-windows-arm64-static-pin.json
    jq --slurpfile pin "$sdk_pin" -e '
        any(.packages[]; .SPDXID == "SPDXRef-llvm-windows-arm64"
            and .downloadLocation == $pin[0].url
            and any(.checksums[]; .algorithm == "SHA256" and .checksumValue == $pin[0].sha256))
        and any(.relationships[]; .spdxElementId == "SPDXRef-ablac" and .relationshipType == "DEPENDS_ON"
            and .relatedSpdxElement == "SPDXRef-llvm-windows-arm64")
    ' "$work/windows-arm64.spdx.json" >/dev/null || fail 'the SBOM does not record the pinned ARM64 SDK'
    nix_sha=$(sed -n 's/.*echo "\([0-9a-f]\{64\}\)  \$installer".*/\1/p' "$project_root/.github/actions/install-nix/action.yml" | head -n 1)
    jq --arg sha "$nix_sha" -e '
        any(.packages[]; .SPDXID == "SPDXRef-nix" and any(.checksums[]; .algorithm == "SHA256" and .checksumValue == $sha))
        and any(.relationships[]; .spdxElementId == "SPDXRef-ablac" and .relationshipType == "DEPENDS_ON" and .relatedSpdxElement == "SPDXRef-nix")
    ' "$work/windows-arm64.spdx.json" >/dev/null || fail 'the SBOM does not record the pinned Nix installer'

    # The artifacts of a release run (one directory each) become one directory for the signer; a file name two artifacts share is refused.
    parts=$work/artifact-parts; flat=$work/artifact-flat
    rm -rf "$parts" "$flat"; mkdir -p "$parts/ablac-a" "$parts/ablac-b"
    printf one > "$parts/ablac-a/a.bin"; printf s > "$parts/ablac-a/a.bin.sha256"; printf two > "$parts/ablac-b/b.bin"
    "$project_root/tools/release-flatten-artifacts.sh" "$parts" "$flat" > /dev/null || fail 'distinct artifacts were not flattened'
    [[ $(cat "$flat/a.bin") == one && $(cat "$flat/b.bin") == two && -f $flat/a.bin.sha256 && ! -e $parts/ablac-a/a.bin ]] || fail 'the flattened release is not the artifacts'"'"' files'
    expect_fail 'a flatten into a directory that exists' "$project_root/tools/release-flatten-artifacts.sh" "$parts" "$flat"
    rm -rf "$parts" "$flat"; mkdir -p "$parts/ablac-a" "$parts/ablac-b"
    printf one > "$parts/ablac-a/same"; printf two > "$parts/ablac-b/same"
    expect_fail 'a file name two artifacts share' "$project_root/tools/release-flatten-artifacts.sh" "$parts" "$flat"
    grep 'the same file name in two artifacts: same' "$work/out.txt" > /dev/null || fail 'the refusal does not name the shared file'
    [[ ! -e $flat ]] || fail 'something was flattened before the refusal'

    pe_fixture x86_64 x64 9.9.9 "$work/x64.exe"
    package_fixture "$work/x64.exe"
    expect_fail 'an x64 executable in the ARM64 zip' check_windows
    grep -q '^FAIL  windows-arm64.*expected console PE for aarch64' "$work/out.txt"

    pe_fixture aarch64 arm64 9.9.90 "$work/wrong-version.exe"
    package_fixture "$work/wrong-version.exe"
    expect_fail 'an ARM64 executable for another release' check_windows
    grep -q '^FAIL  windows-arm64.*does not carry.*ablac 9.9.9' "$work/out.txt"

    ABLA_SYSROOT="$project_root" "$compiler" build "$project_root/tools/windows/implib.ab" -o "$work/implib" --fast --no-cache
    printf 'puts\n' > "$work/msvcrt.txt"
    "$work/implib" "$work/msvcrt.lib" msvcrt.dll aarch64 "$work/msvcrt.txt"
    pe_fixture aarch64 arm64 9.9.9 "$work/crt.exe" /include:puts "$work/msvcrt.lib"
    package_fixture "$work/crt.exe"
    expect_fail 'an ARM64 executable with a dynamic CRT import' check_windows
    grep -q '^FAIL  windows-arm64.*msvcrt.dll' "$work/out.txt"

    rm "$windows_tree/$top/bin/llvm-objcopy.exe"
    package_fixture "$work/arm64.exe"
    expect_fail 'an ARM64 zip without llvm-objcopy.exe' check_windows
    grep -q '^FAIL  windows-arm64.*no bin/llvm-objcopy.exe' "$work/out.txt"
    echo 'release scripts: Windows native fixed points, ARM64 zip and SDK SBOM passed; bad evidence and bad PE packages refused'
else
    echo 'release scripts: skipped the Windows ARM64 fixtures (requires LLVM tools, jq, zip and unzip)'
fi

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

# --out is never wiped by mistake; a repeated file name and an empty directory are reported.
expect_fail "--out ." run_check "$release" v9.9.9 "$stage2" --out .
expect_fail "--out /" run_check "$release" v9.9.9 "$stage2" --out /
mkdir -p "$work/not-ours"
printf 'x\n' >"$work/not-ours/file"
expect_fail "--out a non-empty directory not made by the script" run_check "$release" v9.9.9 "$stage2" --out "$work/not-ours"
[[ -f $work/not-ours/file ]] || fail "release-check wiped a directory it did not make"
expect_fail "--out inside --artifacts" run_check "$release" v9.9.9 "$stage2" --out "$release/inside"
expect_fail "--out containing --artifacts" run_check "$release" v9.9.9 "$stage2" --out "$work"
[[ -f $release/ablac-x86_64-linux ]] || fail "release-check wiped the artifacts"
directory=$(mutated duplicated)
mkdir -p "$directory/second"
cp "$directory/ablac-arm64-macos.sha256" "$directory/second/"
expect_fail "the same file name in two places" run_check "$directory" v9.9.9 "$stage2"
grep -q '^FAIL  assets.*same file name' "$work/out.txt" || fail "a repeated file name did not fail the assets check"
mkdir -p "$work/empty-artifacts"
expect_fail "no artifacts" run_check "$work/empty-artifacts" v9.9.9 "$stage2"
grep -q '^FAIL  assets.*no files' "$work/out.txt" || fail "an empty artifacts directory did not fail clearly"
# The convergence check is required: no run, a run of another source or lineage, a failed or incomplete comparison.
no_gh=$work/no-gh
mkdir -p "$no_gh"
printf '#!/bin/sh\nexit 1\n' >"$no_gh/gh"
chmod +x "$no_gh/gh"
convergence_only() { # extra release-check options: the convergence line, with gh unavailable
    PATH=$no_gh:$PATH "$check" v9.9.9 1 "$stage2" --artifacts "$release" --assets-from "$work/names.txt" --out "$work/out-$RANDOM" "$@"
}
expect_fail "no convergence run" convergence_only --lineage v9.9.8 --source-ref "$source_ref"
grep -q '^FAIL  convergence' "$work/out.txt" || fail "a release with no convergence run did not fail the convergence check"
expect_fail "no source commit" convergence_only --lineage v9.9.8 --convergence-comparison "$comparison"
grep -q '^FAIL  convergence' "$work/out.txt" || fail "no source commit did not fail the convergence check"
expect_fail "another source commit" convergence_only --lineage v9.9.8 --source-ref ffffffffffffffffffffffffffffffffffffffff --convergence-comparison "$comparison"
grep -q '^FAIL  convergence.*not the release' "$work/out.txt" || fail "another source did not fail the convergence check"
expect_fail "another lineage" convergence_only --lineage v9.9.7 --source-ref "$source_ref" --convergence-comparison "$comparison"
grep -q '^FAIL  convergence.*lineage' "$work/out.txt" || fail "another lineage did not fail the convergence check"
sed 's/"passed": true/"passed": false, "error": "route a: broken bootstrap chain"/' "$comparison" >"$work/failed.json"
expect_fail "a failed comparison" convergence_only --lineage v9.9.8 --source-ref "$source_ref" --convergence-comparison "$work/failed.json"
grep -q '^FAIL  convergence.*did not pass' "$work/out.txt" || fail "a failed comparison did not fail the convergence check"
sed 's/"stage2_binary_sha256": "[0-9a-f]*", //' "$comparison" >"$work/incomplete.json"
expect_fail "a comparison with no stage 2 hash" convergence_only --lineage v9.9.8 --source-ref "$source_ref" --convergence-comparison "$work/incomplete.json"
expect_fail "a short source commit" convergence_only --lineage v9.9.8 --source-ref 0123456 --convergence-comparison "$comparison"

# --- release-convergence: the PASS line and the release-notes text.
"$convergence" verify v9.9.9 --lineage v9.9.8 --source-ref "$source_ref" --comparison "$comparison" >"$work/out.txt" ||
    fail "release-convergence refused a good comparison"
grep -q '^PASS  convergence v9.9.8 seeds' "$work/out.txt" || fail "no PASS line from release-convergence"
expect_fail "release-convergence run without a source commit" env PATH="$no_gh:$PATH" "$convergence" run v9.9.9 --lineage v9.9.8

# A second run into the directory the script made is allowed.
out2=$work/out-again
"$check" v9.9.9 1 "$stage2" --artifacts "$release" --assets-from "$work/names.txt" --out "$out2" "${convergence_flags[@]}" >/dev/null || fail "release-check refused a first run"
"$check" v9.9.9 1 "$stage2" --artifacts "$release" --assets-from "$work/names.txt" --out "$out2" "${convergence_flags[@]}" >/dev/null || fail "release-check refused its own directory"

# --- release-check, a tag that does not exist yet: the source commit is the head sha of the publish-off run.
fake_gh=$work/fake-gh
mkdir -p "$fake_gh"
cat >"$fake_gh/gh" <<'SH'
#!/bin/sh
# api repos/.../commits/<tag>: the tag does not exist (exit 1); run view: FAKE_RUN_SHA.
case $1 in
    api) exit 1 ;;
    run) [ -n "${FAKE_RUN_SHA:-}" ] && echo "$FAKE_RUN_SHA" ; exit 0 ;;
esac
exit 1
SH
chmod +x "$fake_gh/gh"
no_source() { # extra release-check options: no --source-ref, the fake gh in front
    PATH=$fake_gh:$PATH "$check" v9.9.9 1 "$stage2" --artifacts "$release" --assets-from "$work/names.txt" --out "$work/out-$RANDOM" \
        --lineage v9.9.8 --convergence-comparison "$comparison" "$@"
}
FAKE_RUN_SHA=$source_ref no_source >"$work/out.txt" 2>&1 || { cat "$work/out.txt" >&2; fail "release-check did not use the run's head sha for a tag that does not exist"; }
grep -q "^PASS  convergence.*source $source_ref: run 1's head" "$work/out.txt" || fail "the run's head sha was not reported as the source"
FAKE_RUN_SHA=ffffffffffffffffffffffffffffffffffffffff expect_fail "a run built another commit than the comparison's" no_source
grep -q '^FAIL  convergence.*not the release' "$work/out.txt" || fail "another run head did not fail the convergence check"
FAKE_RUN_SHA= expect_fail "no head sha from the run" no_source
grep -q '^FAIL  convergence.*--source-ref' "$work/out.txt" || fail "no head sha did not name --source-ref"
FAKE_RUN_SHA=notasha expect_fail "a malformed head sha" no_source
grep -q '^FAIL  convergence.*--source-ref' "$work/out.txt" || fail "a malformed head sha did not name --source-ref"
# --source-ref still wins over the run.
FAKE_RUN_SHA=ffffffffffffffffffffffffffffffffffffffff no_source --source-ref "$source_ref" >/dev/null 2>&1 || fail "--source-ref did not win over the run's head sha"

# --- release-notes: the draft without its header, Housekeeping and At release time, plus the convergence notes.
notes=$project_root/tools/release-notes.sh
draft=$work/draft.md
cat >"$draft" <<'MD'
DRAFT for v9.9.9, complete. Nothing is [pending] any more.

## Behaviour changes and migration (read first)

- a change

## Fixes

- a fix

## Housekeeping (not for the notes)
- tests only: abc

## Highlights

- a highlight

## At release time (do not forget)
- push the tag
MD
convergence_notes=$work/convergence-notes.md
"$convergence" verify v9.9.9 --lineage v9.9.8 --source-ref "$source_ref" --comparison "$comparison" --notes "$convergence_notes" >/dev/null || fail "no convergence notes were written"
"$notes" v9.9.9 "$draft" --convergence "$convergence_notes" --out "$work/publish.md" >/dev/null || fail "release-notes refused a good draft"
grep -q '^## Behaviour changes' "$work/publish.md" && grep -q '^## Fixes' "$work/publish.md" && grep -q '^## Highlights' "$work/publish.md" || fail "a section is missing from the publish notes"
grep -q 'DRAFT for' "$work/publish.md" && fail "the header line is in the publish notes"
grep -q 'Housekeeping\|tests only: abc' "$work/publish.md" && fail "Housekeeping is in the publish notes"
grep -q 'At release time\|push the tag' "$work/publish.md" && fail "At release time is in the publish notes"
grep -q -- '- a highlight' "$work/publish.md" || fail "the section after Housekeeping was dropped"
[[ $(head -n 1 "$work/publish.md") == '## Behaviour changes and migration (read first)' ]] || fail "the publish notes do not start at the first section"
[[ $(grep -c '^### Bootstrap convergence' "$work/publish.md") -eq 1 ]] || fail "the convergence notes are not in the publish notes once"
grep -q "^- route A: v9.9.8" "$work/publish.md" || fail "the convergence notes' route A line is missing"
[[ $(tail -n 1 "$work/publish.md") == *'seed compromise'* ]] || fail "the publish notes do not end with the convergence notes"
# Refusals.
sed 's/^- a fix$/- a fix [pending]/' "$draft" >"$work/pending.md"
expect_fail "a draft with a [pending] line" "$notes" v9.9.9 "$work/pending.md" --convergence "$convergence_notes" --out "$work/p1.md"
[[ ! -e $work/p1.md ]] || fail "release-notes wrote notes for a draft with [pending]"
sed '1d' "$draft" >"$work/headerless.md"
expect_fail "a draft without its header line" "$notes" v9.9.9 "$work/headerless.md" --convergence "$convergence_notes" --out "$work/p2.md"
expect_fail "no convergence notes" "$notes" v9.9.9 "$draft" --convergence "$work/missing.md" --out "$work/p3.md"
expect_fail "convergence notes of another tag" "$notes" v9.9.8 "$draft" --convergence "$convergence_notes" --out "$work/p4.md"
expect_fail "a draft that is not a notes draft" "$notes" v9.9.9 "$convergence_notes" --convergence "$convergence_notes" --out "$work/p5.md"
expect_fail "a bad tag" "$notes" 9.9.9 "$draft" --convergence "$convergence_notes"

# --- gate.sh and gate-release.sh --dry-run, on two made-up trees: one with tools/bootstrap-stages.sh, one without.
gate=$project_root/tools/gate.sh
release_gate=$project_root/tools/gate-release.sh
old_tree=$work/tree-old
new_tree=$work/tree-new
mkdir -p "$old_tree/tools" "$new_tree/tools"
for tree in "$old_tree" "$new_tree"; do
    printf '#!/bin/sh\nexit 0\n' >"$tree/tools/bootstrap-compiler.sh"
    chmod +x "$tree/tools/bootstrap-compiler.sh"
done
printf '#!/bin/sh\nexit 0\n' >"$new_tree/tools/bootstrap-stages.sh"
chmod +x "$new_tree/tools/bootstrap-stages.sh"
# The regular gate, a tree without bootstrap-stages.sh: the pinned seed, three builds and a cmp, the suite (not the full one), no reproducibility check.
out=$("$gate" "$old_tree" 3 --dry-run 2>&1) || { echo "$out" >&2; fail "gate --dry-run failed"; }
grep -q 'tools/bootstrap-compiler.sh build/gate/seed.bin' <<<"$out" || fail "the gate does not take its seed from the pin"
grep -q 'taskset -c 16-23 tools/build-self-hosted-release.sh build/gate/seed.bin build/gate/stage1' <<<"$out" || fail "stage 1 does not start from the seed on slot 3's cores"
grep -q 'taskset -c 16-23 tools/build-self-hosted-release.sh build/gate/stage2 build/gate/stage3' <<<"$out" || fail "slot 3 does not pin stage 3 to 16-23"
grep -q "cmp build/gate/stage2 build/gate/stage3 && echo 'stage2 == stage3'" <<<"$out" || fail "no cmp of stage 2 and 3 without bootstrap-stages.sh"
grep -q 'bootstrap-stages' <<<"$out" && fail "a tree without bootstrap-stages.sh was given it"
grep -q ' JOBS=8 taskset -c 16-23 tools/run-tests.sh' <<<"$out" || fail "the suite is not on slot 3's cores"
grep -q 'RUN_TESTS_FULL' <<<"$out" && fail "the regular gate runs the full suite"
grep -q 'reproducible-elsewhere' <<<"$out" && fail "the regular gate checks reproducibility"
grep -q 'make self-rebuild' <<<"$out" || fail "make self-rebuild is missing"
grep -q 'taskset -c 8-11' <<<"$out" && fail "slot 3's gate touches slot 2's cores"
# A tree with bootstrap-stages.sh: the quick stage 3, no separate stage builds.
out=$("$gate" "$new_tree" 4 --dry-run 2>&1) || fail "gate --dry-run failed on a tree with bootstrap-stages.sh"
grep -q 'taskset -c 24-31 tools/bootstrap-stages.sh build/gate/seed.bin build/gate$' <<<"$out" || { echo "$out" >&2; fail "the quick stages are not used (or --full is given) by the regular gate"; }
grep -q 'build-self-hosted-release.sh' <<<"$out" && fail "a tree with bootstrap-stages.sh also builds the stages one by one"
grep -q ' JOBS=8 taskset -c 24-31 tools/run-tests.sh' <<<"$out" || fail "slot 4 is not 8 jobs on 24-31"
out5=$("$gate" "$new_tree" 5 --dry-run 2>&1)
grep -q ' JOBS=8 taskset -c 20-27 tools/run-tests.sh' <<<"$out5" || fail "slot 5 is not 8 jobs on 20-27"
# The release gate: --full stages, the full suite, reproducibility; gate-release.sh is gate.sh --release.
out=$("$release_gate" "$new_tree" 1 --dry-run 2>&1) || fail "gate-release --dry-run failed"
grep -q 'tools/bootstrap-stages.sh build/gate/seed.bin build/gate --full' <<<"$out" || fail "the release gate does not build stage 3 whole"
grep -q 'RUN_TESTS_FULL=1 JOBS=8 taskset -c 0-7 tools/run-tests.sh' <<<"$out" || fail "the release gate's suite is not the full one"
grep -q 'test-reproducible-elsewhere.sh --self build/ablac.bin' <<<"$out" || fail "the reproducibility check is missing"
[[ $("$release_gate" "$old_tree" 2 --dry-run 2>&1) == "$("$gate" "$old_tree" 2 --release --dry-run 2>&1)" ]] || fail "gate-release.sh is not gate.sh --release"
# The slot table.
out=$("$gate" "$old_tree" 2 --dry-run 2>&1)
grep -q ' JOBS=6 taskset -c 8-11,14-15 ' <<<"$out" || fail "slot 2 is not 6 jobs on 8-11,14-15"
out=$(GATE_CPUS=0-1 GATE_JOBS=2 "$gate" "$old_tree" 1 --dry-run 2>&1)
grep -q ' JOBS=2 taskset -c 0-1 ' <<<"$out" || fail "GATE_CPUS and GATE_JOBS are not honoured"
for expected in '1: 0-7' '2: 8-11,14-15' '3: 16-23' '4: 24-31' 'efficiency cores' 'performance cores'; do
    grep -q -- "$expected" "$gate" || fail "the slot table in gate.sh lost '$expected'"
done
# Nothing is written by a dry run, and the refusals.
[[ ! -e $old_tree/build ]] || fail "a dry run wrote into the tree"
expect_fail "a gate on a directory that is not a worktree" "$gate" "$work" 2 --dry-run
expect_fail "a non-numeric slot" "$gate" "$old_tree" two --dry-run
expect_fail "no arguments" "$gate"
expect_fail "three positional arguments" "$gate" "$old_tree" 2 3 --dry-run

# --- release-pin: a checkout pinned to v9.9.8 moves to v9.9.9.
root=$work/root
mkdir -p "$root/tools" "$root/docs"
# No release of this fixture is signed yet (release-pin.sh reads tools/first-signed-release); the signed case is below.
printf 'v99.0.0\n' >"$root/tools/first-signed-release"
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
printf 'native `v9.9.8` artifact\nstable v9.9.8 binaries\nv9.9.8 bootstrap\npinned v9.9.8 compiler\nends a sentence at v9.9.8.\n(v9.9.8) in brackets\nthe v9.9.7 bridge\nand v9.9.80 is another\n' >"$root/docs/bootstrap.md"
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
# A bootstrap-compiler.sh the rewrite cannot place (no version line; a platform without its sha256)
# is refused and left as it was.
good=$(cat "$root/tools/bootstrap-compiler.sh")
sed '/^version=/d' <<<"$good" >"$root/tools/bootstrap-compiler.sh"
broken=$(cat "$root/tools/bootstrap-compiler.sh")
expect_fail "a bootstrap-compiler.sh without a version line" "$pin" v9.9.9 --dir "$release" --root "$root"
[[ $(cat "$root/tools/bootstrap-compiler.sh") == "$broken" ]] || fail "a refused rewrite changed bootstrap-compiler.sh"
sed '/platform_sha256=2222/d' <<<"$good" >"$root/tools/bootstrap-compiler.sh"
broken=$(cat "$root/tools/bootstrap-compiler.sh")
expect_fail "a bootstrap-compiler.sh without the Intel macOS sha256" "$pin" v9.9.9 --dir "$release" --root "$root"
[[ $(cat "$root/tools/bootstrap-compiler.sh") == "$broken" ]] || fail "a refused rewrite changed bootstrap-compiler.sh"
printf '%s\n' "$good" >"$root/tools/bootstrap-compiler.sh"
[[ $(snapshot) == "$before" ]] || fail "the fixture was not restored"

# The good release pins.
"$pin" v9.9.9 --dir "$release" --root "$root" >"$work/out.txt" 2>&1 || { cat "$work/out.txt" >&2; fail "release-pin refused a good release"; }
grep -q '^version=v9.9.9$' "$root/tools/bootstrap-compiler.sh" || fail "the version was not moved"
for platform in x86_64-linux x86_64-macos arm64-macos; do
    grep -A1 "artifact=ablac-$platform$" "$root/tools/bootstrap-compiler.sh" | grep "platform_sha256=$(sha "$release/ablac-$platform")$" >/dev/null ||
        fail "the $platform sha256 was not pinned"
done
grep -q 'from `v9.9.9`' "$root/README.md" || fail "README.md was not moved"
grep -q "'9.9.8'" "$root/README.md" || fail "the setup-abla version (the Prepare commit's) was changed"
grep -q '^note: README.md still has' "$work/out.txt" || fail "no note about the setup-abla version"
[[ $(grep -c 'v9.9.9' "$root/docs/bootstrap.md") -eq 6 ]] || fail "docs/bootstrap.md has the wrong number of v9.9.9 mentions"
grep -q 'v9.9.80 is another' "$root/docs/bootstrap.md" || fail "v9.9.80 was changed with v9.9.8"
grep -q 'ends a sentence at v9.9.9\.' "$root/docs/bootstrap.md" || fail "a mention at the end of a sentence was not moved"
grep -q '(v9.9.9) in brackets' "$root/docs/bootstrap.md" || fail "a bracketed mention was not moved"
grep -q 'v9.9.7 bridge' "$root/docs/bootstrap.md" || fail "a mention of another version was changed"
# release-pin does not write into a main checkout that is on master, but does in a linked worktree.
main=$work/main-checkout
mkdir -p "$main/tools" "$main/docs"
cp "$pin" "$main/tools/release-pin.sh"
printf 'v99.0.0\n' >"$main/tools/first-signed-release"
cp "$root/tools/bootstrap-compiler.sh" "$main/tools/bootstrap-compiler.sh"
sed -i "s/^version=v9.9.9$/version=v9.9.8/" "$main/tools/bootstrap-compiler.sh"
[[ $(grep -c "^version=v9.9.8$" "$main/tools/bootstrap-compiler.sh") -eq 1 ]] || fail "the main checkout fixture is not at v9.9.8"
git -C "$main" init -q -b master
git -C "$main" -c user.name=t -c user.email=t@t add -A
git -C "$main" -c user.name=t -c user.email=t@t commit -q -m start
printf 'v9.9.9 stays\n' >"$work/unused"
expect_fail "pinning in a main checkout on master" "$main/tools/release-pin.sh" v9.9.9 --dir "$release"
grep -q 'main checkout' "$work/out.txt" || fail "no explanation for refusing the main checkout"
grep -q "^version=v9.9.8$" "$main/tools/bootstrap-compiler.sh" || fail "the refused pin changed the main checkout"
git -C "$main" worktree add -q -b pin "$work/linked"
"$work/linked/tools/release-pin.sh" v9.9.9 --dir "$release" >/dev/null 2>&1 || fail "release-pin refused a linked worktree"
grep -q '^version=v9.9.9$' "$work/linked/tools/bootstrap-compiler.sh" || fail "the linked worktree was not pinned"
# --- release-pin of a signed release (from tools/first-signed-release on): the signature must verify against
# release-signing.pub, and the files fetched must be the signed ones.
signed_root=$work/signed-root
mkdir -p "$signed_root/tools" "$signed_root/docs"
cp "$root/tools/bootstrap-compiler.sh" "$signed_root/tools/bootstrap-compiler.sh"
sed -i "s/^version=v9.9.9$/version=v9.9.8/" "$signed_root/tools/bootstrap-compiler.sh"
cp "$project_root/tools/verify-release.sh" "$signed_root/tools/verify-release.sh"
printf 'v9.9.9\n' >"$signed_root/tools/first-signed-release"
printf 'compiler from `v9.9.8`\n' >"$signed_root/README.md"
printf 'native `v9.9.8` artifact\n' >"$signed_root/docs/bootstrap.md"
ssh-keygen -q -t ed25519 -N '' -C test -f "$work/sign-key" >/dev/null
cp "$work/sign-key.pub" "$signed_root/release-signing.pub"
signed_release() { # a copy of the made-up release with SHA256SUMS signed by the key given (default: the repository's test key)
    rm -rf "$work/signed-release"; cp -r "$release" "$work/signed-release"
    (cd "$work/signed-release" && sha256sum -- * >SHA256SUMS)
    ssh-keygen -Y sign -f "${1:-$work/sign-key}" -n abla-release "$work/signed-release/SHA256SUMS" >/dev/null 2>&1
}
signed_snapshot() { cat "$signed_root/tools/bootstrap-compiler.sh" | sha256sum; }
signed_before=$(signed_snapshot)
rm -rf "$work/signed-release"; cp -r "$release" "$work/signed-release"
expect_fail "an unsigned release (no SHA256SUMS) from the first signed release on" "$pin" v9.9.9 --dir "$work/signed-release" --root "$signed_root"
grep -q 'not signed' "$work/out.txt" || fail "no explanation for refusing an unsigned release"
ssh-keygen -q -t ed25519 -N '' -C other -f "$work/other-key" >/dev/null
signed_release "$work/other-key"
expect_fail "a release signed by another key" "$pin" v9.9.9 --dir "$work/signed-release" --root "$signed_root"
signed_release; printf 'x' >>"$work/signed-release/ablac-x86_64-macos"
expect_fail "a binary changed after signing" "$pin" v9.9.9 --dir "$work/signed-release" --root "$signed_root"
[[ $(signed_snapshot) == "$signed_before" ]] || fail "a refused signed pin changed the checkout"
signed_release
"$pin" v9.9.9 --dir "$work/signed-release" --root "$signed_root" >"$work/out.txt" 2>&1 || { cat "$work/out.txt" >&2; fail "release-pin refused a good signed release"; }
grep -q '^version=v9.9.9$' "$signed_root/tools/bootstrap-compiler.sh" || fail "the signed release was not pinned"

# release-check flattens the same signed artifacts and creates its own output marker.
cp "$check" "$convergence" "$signed_root/tools/"
output=$(check="$signed_root/tools/release-check.sh" run_check "$work/signed-release" v9.9.9 "$stage2" \
    --out "$work/signed-check-out") || { echo "$output" >&2; fail "release-check refused a good signed release"; }
grep -q '^PASS  signature' <<<"$output" || { echo "$output" >&2; fail "no PASS line for the signature"; }
[[ -f $work/signed-check-out/.release-check ]] || fail "release-check did not mark its output directory"
printf 'extra\n' >"$work/signed-release/.unlisted"
check="$signed_root/tools/release-check.sh" expect_fail "a signed release containing an unlisted file" \
    run_check "$work/signed-release" v9.9.9 "$stage2" --out "$work/signed-check-out"
grep -q '^FAIL  signature.*\.unlisted is not listed' "$work/out.txt" || fail "signature check did not reject the unlisted file"

echo "release scripts: a good release is accepted; a doctored sha256, a changed asset, a missing or extra asset, a wrong version and another stage 2 are refused; a pin moves the version and three sha256s and refuses a bad .sha256"
