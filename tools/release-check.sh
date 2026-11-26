#!/usr/bin/env bash
# The "check before release" step of a release (see the release process notes): the
# artifacts of a publish-off Release workflow run, checked before anything is published.
#
#   tools/release-check.sh <tag> <run-id> <local-stage2> [options]
#
# Downloads the run's artifacts (gh), flattens them into one directory and prints one line per
# check, PASS or FAIL, then exits 1 when any failed:
#   assets      every asset name of the previous release is here, and no other
#   sha256      every `.sha256` file matches its asset, and every asset has one
#   version     the Linux binary's --version prints `ablac <tag without v>`
#   stage2      the Linux binary is byte for byte the local stage 2 (cmp)
#   convergence a green bootstrap-convergence run exists for the release's source commit (tools/release-convergence.sh);
#               required: without --source-ref (or the tag) and a run, this check fails
#   static      (when the run built ablac-static-x86_64-linux, #806 step C; `static-aarch64` for ablac-static-aarch64-linux, run natively or under
#               qemu-aarch64, SKIP on a host with neither, never with the fixpoint) it has no PT_INTERP or DT_NEEDED, prints the version, builds and
#               runs a smoke program and, with ABLA_STATIC_LLVM_LIB set, reaches the fixpoint (tools/test-static-artifact.sh)
#   static-input (with the dynamic asset beside the static default) the run's Linux job logged the sha256 of the compiler its static step built from, and it is
#               the published ablac-dynamic-x86_64-linux (FAIL if not; SKIP with a warning when the run logged no such line or its log cannot be read)
#   toolchain   (when the run ships abla-toolchain-dynamic-x86_64-linux.tar.gz beside the default) abla-toolchain-x86_64-linux.tar.gz is the static package: no
#               PT_INTERP or DT_NEEDED, no shared library or external LLVM tool, at most 60 MB (150 MB unpacked), its launcher runs with an empty PATH
#   playground  (when the run ships abla-playground-<version>.tar.gz, the browser compiler of tools/build-playground.sh) its manifest names this
#               version, its module matches the manifest's hash and is at most 8 MB, and its stdlib bundle carries its hash in its name
#   windows     abla-toolchain-x86_64-windows.zip and (as windows-arm64) ablac-windows-arm64.zip, when shipped. Checks layout,
#               size caps and an architecture-matched console ablac.exe carrying this version and importing no C runtime
#   windows-fixpoint / windows-arm64-fixpoint
#               for each Windows zip, its native fixpoint job in <run-id> passed with equal stage 2 and 3 PE hashes
#   siblings    (with --siblings) the downstream repositories build and pass their tests with the candidate
#               (tools/test-siblings.sh over tools/siblings.txt)
#
# Options:
#   --repo OWNER/REPO     (default AndreBaltazar8/ablac)
#   --out DIR             where the flattened artifacts go (default build/release-<tag>)
#   --artifacts DIR       use artifacts already downloaded (any folder layout) instead of `gh run download`
#   --previous TAG        the release whose asset names to compare (default: the highest published
#                         release below <tag>)
#   --assets-from FILE    the expected asset names, one per line, instead of asking GitHub
#   --source-ref SHA      the commit the release is made from, for the convergence check (default: the commit
#                         <tag> already names; while the tag does not exist yet, the head sha of the run <run-id>)
#   --convergence-run ID  the bootstrap-convergence workflow run to check (default: the newest green one that matches)
#   --convergence-comparison FILE
#                         a downloaded comparison.json to check instead (with --lineage, convergence needs no gh)
#   --lineage TAG         the convergence lineage to expect (default: the highest published release below <tag>)
#   --siblings TREE       the downstream step: check 6, siblings, runs tools/test-siblings.sh with TREE (the candidate's
#                         tree, build/ablac built) over tools/siblings.txt; its summary goes to <out>/siblings
#   --siblings-baseline COMPILER
#                         the compiler a sibling program must also fail with to be no regression (the previous
#                         release's); without it every program the candidate can't build counts
set -uo pipefail

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}

repo=AndreBaltazar8/ablac
out=
artifacts=
previous=
assets_from=
source_ref=
convergence_run=
convergence_comparison=
lineage=
siblings=
siblings_baseline=
positional=()
while (($#)); do
    case $1 in
        --repo) repo=${2:?}; shift 2 ;;
        --out) out=${2:?}; shift 2 ;;
        --artifacts) artifacts=${2:?}; shift 2 ;;
        --previous) previous=${2:?}; shift 2 ;;
        --assets-from) assets_from=${2:?}; shift 2 ;;
        --source-ref) source_ref=${2:?}; shift 2 ;;
        --convergence-run) convergence_run=${2:?}; shift 2 ;;
        --convergence-comparison) convergence_comparison=${2:?}; shift 2 ;;
        --lineage) lineage=${2:?}; shift 2 ;;
        --siblings) siblings=${2:?}; shift 2 ;;
        --siblings-baseline) siblings_baseline=${2:?}; shift 2 ;;
        -h | --help) usage ;;
        -*) echo "release-check: unknown option $1" >&2; usage ;;
        *) positional+=("$1"); shift ;;
    esac
done
((${#positional[@]} == 3)) || usage
tag=${positional[0]}
run_id=${positional[1]}
stage2=${positional[2]}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-check: tag must look like v0.2.51, got $tag" >&2; exit 2; }
version=${tag#v}
[[ -f $stage2 ]] || { echo "release-check: no local stage 2 at $stage2" >&2; exit 2; }
out=${out:-build/release-$tag}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Where the flattened artifacts go: refuse a directory this script could wipe by mistake. An existing
# one is only emptied if it is empty or this script made it (it holds the .release-check marker).
physical() { # directory that exists -> its physical path
    (cd -P -- "$1" 2>/dev/null && pwd -P)
}
mkdir -p -- "$(dirname -- "$out")"
out_parent=$(physical "$(dirname -- "$out")") || { echo "release-check: cannot use --out $out" >&2; exit 2; }
out_physical=$out_parent/$(basename -- "$out")
project_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
case $out_physical in
    / | "$HOME" | "$project_root" | "$out_parent" | */. | */..)
        echo "release-check: refusing --out $out (it resolves to $out_physical)" >&2
        exit 2 ;;
esac
if [[ -n $artifacts ]]; then
    artifacts_physical=$(physical "$artifacts") || { echo "release-check: no artifacts directory $artifacts" >&2; exit 2; }
    case $out_physical/ in
        "$artifacts_physical"/* ) echo "release-check: --out $out is inside --artifacts $artifacts" >&2; exit 2 ;;
    esac
    case $artifacts_physical/ in
        "$out_physical"/* ) echo "release-check: --out $out contains --artifacts $artifacts" >&2; exit 2 ;;
    esac
fi
if [[ -e $out ]]; then
    if [[ ! -d $out ]]; then
        echo "release-check: --out $out exists and is not a directory" >&2
        exit 2
    fi
    if [[ -n $(ls -A -- "$out") && ! -f $out/.release-check ]]; then
        echo "release-check: --out $out is not empty and was not made by this script (no .release-check marker)" >&2
        exit 2
    fi
    rm -rf -- "$out"
fi
mkdir -p -- "$out"

# Collect the artifacts in one flat directory.
if [[ -n $artifacts ]]; then
    source_dir=$artifacts
else
    source_dir=$(mktemp -d)
    trap 'rm -rf -- "$source_dir"' EXIT
    # Use the publish job's artifact set. Fixed-point logs and other diagnostics are checked separately.
    if ! gh run download "$run_id" -R "$repo" --pattern 'ablac-*' -D "$source_dir" >/dev/null 2>&1; then
        echo "release-check: gh run download $run_id -R $repo failed" >&2
        exit 2
    fi
    find "$source_dir" -type f -name static-suite-source.sha -delete
fi
# Two artifacts holding a file of the same name would overwrite each other in the flat directory:
# list the names first and report a repeat.
duplicates=$(find "$source_dir" -type f -exec basename {} \; | sort | uniq -d | tr '\n' ' ')
find "$source_dir" -type f -exec cp -f {} "$out"/ \;
count=$(find "$out" -type f ! -name .release-check | wc -l | tr -d ' ')

results=()
failed=0
report() { # PASS|FAIL|SKIP name detail (a SKIP says what this host could not judge and does not fail the check)
    results+=("$(printf '%-5s %-8s %s' "$1" "$2" "$3")")
    [[ $1 == PASS || $1 == SKIP ]] || failed=1
}

# 1. assets: the previous release's names.
expected=$(mktemp)
actual=$(mktemp)
# (This trap replaces the earlier one on purpose: it repeats that cleanup of the download directory, which
# only exists when nothing was given with --artifacts, and also removes the two temporary lists.)
trap 'rm -f -- "$expected" "$actual"; [[ -z ${source_dir:-} || -n $artifacts ]] || rm -rf -- "$source_dir"' EXIT
( cd "$out" && ls ) | sort >"$actual"   # (ls leaves out the .release-check marker)
# The static compilers (#806 step C, one per architecture: x86_64 and aarch64) and the dynamic one that ships beside the static default as an opt-in
# (decision #90 A: `ablac-x86_64-linux` is then the static compiler, `ablac-dynamic-x86_64-linux` the dynamic one) are optional extras: their names are
# neither expected nor an extra; check 4 judges the dynamic one and check 7 each static one that is present.
switched=0
! grep -qxF ablac-dynamic-x86_64-linux "$actual" || switched=1
static_names=$(grep -E "^ablac-static-(x86_64|aarch64)-linux(\.sha256)?\$" "$actual" || true)
toolchain_switched=0
! grep -qxF abla-toolchain-dynamic-x86_64-linux.tar.gz "$actual" || toolchain_switched=1
# The browser compiler (tools/build-playground.sh) is an optional extra with a name that holds the version: neither expected nor an extra; check 10 judges it.
playground_present=0
! grep -qxF "abla-playground-$version.tar.gz" "$actual" || playground_present=1
# The Windows toolchain zips (tools/package-windows-toolchain.sh) are optional the same way: check 11 judges them.
# The publish job adds SHA256SUMS, its signature and the SBOM: they are not build artifacts, so they are neither expected here
# nor counted as extras (check 9, signature, judges them where they exist).
grep -vE "^(SHA256SUMS(\.sig)?|ablac-[0-9.]+\.spdx\.json)\$" "$actual" > "$actual.generated" || true
mv -f "$actual.generated" "$actual"
grep -vE "^(ablac-(static-(x86_64|aarch64)|dynamic-x86_64)-linux|abla-toolchain-dynamic-x86_64-linux\.tar\.gz|abla-playground-[0-9.]+\.tar\.gz|abla-toolchain-x86_64-windows\.zip|ablac-windows-arm64\.zip)(\.sha256)?\$" "$actual" > "$actual.filtered" || true
mv -f "$actual.filtered" "$actual"
if [[ -n $assets_from ]]; then
    sort "$assets_from" >"$expected"
    basis="$assets_from"
else
    if [[ -z $previous ]]; then
        previous=$(gh release list -R "$repo" -L 100 --exclude-drafts --json tagName --jq '.[].tagName' 2>/dev/null |
            grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | sed 's/^/v/' |
            awk -v tag="$tag" 'BEGIN { prior = "" } $0 == tag { print prior; found = 1; exit } { prior = $0 }
                END { if (!found) print prior }')
    fi
    if [[ -n $previous ]] && gh release view "$previous" -R "$repo" --json assets --jq '.assets[].name' 2>/dev/null | sort >"$expected" &&
        [[ -s $expected ]]; then
        basis="$previous"
    else
        : >"$expected"
        basis="(no previous release found)"
    fi
fi
grep -vE "^(SHA256SUMS(\.sig)?|ablac-[0-9.]+\.spdx\.json)\$" "$expected" > "$expected.generated" || true
mv -f "$expected.generated" "$expected"
grep -vE "^(ablac-(static-(x86_64|aarch64)|dynamic-x86_64)-linux|abla-toolchain-dynamic-x86_64-linux\.tar\.gz|abla-playground-[0-9.]+\.tar\.gz|abla-toolchain-x86_64-windows\.zip|ablac-windows-arm64\.zip)(\.sha256)?\$" "$expected" > "$expected.filtered" || true
mv -f "$expected.filtered" "$expected"
if ((count == 0)); then
    report FAIL assets "no files in the artifacts"
elif [[ -n $duplicates ]]; then
    report FAIL assets "the same file name in more than one artifact: ${duplicates% }"
elif [[ ! -s $expected ]]; then
    report FAIL assets "no expected asset names ($basis)"
elif diff -q "$expected" "$actual" >/dev/null; then
    report PASS assets "$count files, the names of $basis"
else
    missing=$(comm -23 "$expected" "$actual" | tr '\n' ' ')
    extra=$(comm -13 "$expected" "$actual" | tr '\n' ' ')
    report FAIL assets "against $basis: missing [${missing% }] extra [${extra% }]"
fi

# 2. sha256: every .sha256 file against its asset, and every asset has one.
bad=
checked=0
for file in "$out"/*; do
    [[ -e $file ]] || continue
    name=$(basename "$file")
    if [[ $name == *.sha256 ]]; then
        asset=${name%.sha256}
        line=$(head -n 1 "$file")
        want=${line%% *}
        named=${line##* }
        if [[ ! -f $out/$asset ]]; then
            bad="$bad $name(no $asset)"
        elif [[ $named != "$asset" ]]; then
            bad="$bad $name(names $named)"
        elif [[ $(sha256 "$out/$asset") != "$want" ]]; then
            bad="$bad $name(differs)"
        else
            checked=$((checked + 1))
        fi
    elif [[ $name == SHA256SUMS || $name == SHA256SUMS.sig || $name == ablac-*.spdx.json ]]; then
        : # made by the publish job, judged by check 2b
    elif [[ ! -f $out/$name.sha256 ]]; then
        bad="$bad $name(no .sha256)"
    fi
done
if [[ -z $bad ]]; then
    report PASS sha256 "$checked files match their .sha256"
else
    report FAIL sha256 "${bad# }"
fi

# 2b. signature: SHA256SUMS is made and signed by the publish job, so a run's artifacts have none (SKIP); a directory that
# has them (a published release downloaded with --artifacts) must verify against release-signing.pub, assets and all.
if [[ -f $out/SHA256SUMS || -f $out/SHA256SUMS.sig ]]; then
    if verification=$("$(dirname -- "${BASH_SOURCE[0]}")/verify-release.sh" "$out" 2>&1); then
        report PASS signature "$verification"
    else
        report FAIL signature "$(tr '\n' ' ' <<< "$verification")"
    fi
else
    report SKIP signature "unsigned before publish (the publish job signs SHA256SUMS)"
fi
# Verify all collected files before adding the marker that lets a later run reuse --out.
[[ -f $out/.release-check ]] || : >"$out/.release-check"

# 3. version: the Linux binary prints the tag's version.
linux=$out/ablac-x86_64-linux
if [[ ! -f $linux ]]; then
    report FAIL version "no ablac-x86_64-linux in $out"
elif [[ $(uname -s)/$(uname -m) != Linux/x86_64 ]]; then
    report FAIL version "this host cannot run ablac-x86_64-linux"
else
    chmod +x "$linux"
    printed=$("$linux" --version 2>&1 | head -n 1)
    if [[ $printed == "ablac $version" ]]; then
        report PASS version "prints '$printed'"
    else
        report FAIL version "prints '$printed', wanted 'ablac $version'"
    fi
fi

# 4. stage2: the dynamic Linux binary is the local stage 2 (with the static compiler as the ablac-x86_64-linux asset, decision #90 A, that is
# ablac-dynamic-x86_64-linux; the static one is judged by check 7, with its fixpoint).
dynamic=$linux
((switched)) && dynamic=$out/ablac-dynamic-x86_64-linux
if [[ ! -f $dynamic ]]; then
    report FAIL stage2 "no $(basename "$dynamic") in $out"
elif cmp -s "$dynamic" "$stage2"; then
    report PASS stage2 "$(basename "$dynamic") cmp equal to $stage2 ($(sha256 "$stage2" | cut -c1-12))"
else
    report FAIL stage2 "$(basename "$dynamic") differs from $stage2 ($(sha256 "$dynamic" | cut -c1-12) against $(sha256 "$stage2" | cut -c1-12))"
fi

# 5. convergence: the historical-seed bootstrap routes agree on this release's source (required).
# The source commit: --source-ref, else the commit the tag names (release-convergence.sh reads it), else, while the tag
# does not exist yet, the commit the publish-off run built (its head sha; the run is dispatched on the ref the Prepare
# commit is on), else release-convergence.sh fails with a message that names --source-ref.
source_note=
if [[ -z $source_ref ]] && ! gh api "repos/$repo/commits/$tag" --jq .sha >/dev/null 2>&1; then
    run_sha=$(gh run view "$run_id" -R "$repo" --json headSha --jq .headSha 2>/dev/null || true)
    if [[ $run_sha =~ ^[0-9a-f]{40}$ ]]; then
        source_ref=$run_sha
        source_note=" [source $run_sha: run $run_id's head, $tag does not exist yet]"
    fi
fi
convergence_args=(verify "$tag" --repo "$repo")
[[ -z $source_ref ]] || convergence_args+=(--source-ref "$source_ref")
[[ -z $lineage ]] || convergence_args+=(--lineage "$lineage")
[[ -z $convergence_run ]] || convergence_args+=(--run "$convergence_run")
[[ -z $convergence_comparison ]] || convergence_args+=(--comparison "$convergence_comparison")
convergence=$("$(dirname -- "${BASH_SOURCE[0]}")/release-convergence.sh" "${convergence_args[@]}" 2>&1 | tail -n 1)
if [[ $convergence == PASS* ]]; then
    report PASS convergence "${convergence#PASS  convergence }$source_note"
else
    report FAIL convergence "${convergence#FAIL  convergence }$source_note"
fi

# 6. siblings (with --siblings): the downstream repositories against the candidate, one list (tools/siblings.txt).
if [[ -n $siblings ]]; then
    sibling_args=("$siblings" --out "$out/siblings")
    [[ -z $siblings_baseline ]] || sibling_args+=(--baseline "$siblings_baseline")
    if "$(dirname -- "${BASH_SOURCE[0]}")/test-siblings.sh" "${sibling_args[@]}" > "$out/siblings.log" 2>&1; then
        report PASS siblings "$(($(wc -l < "$out/siblings/summary.txt") - 1)) repositories, no regression ($out/siblings/summary.txt)"
    else
        bad=$(awk 'NR > 1 && ($3 != "0" || $4 == "FAIL") {printf "%s ", $1}' "$out/siblings/summary.txt" 2>/dev/null)
        report FAIL siblings "${bad:-see $out/siblings.log}"
    fi
fi

# 7. static: the statically linked compilers, when the run built them (#806 step C; extras next to the dynamic default), one line each:
# `static` for ablac-static-x86_64-linux (it runs on a Linux x86-64 host), `static-aarch64` for ablac-static-aarch64-linux (it runs natively on a
# Linux AArch64 host, under qemu-aarch64 on a Linux x86-64 one; with neither, or no qemu, the line is SKIP, not a failure of the file). The
# AArch64 file is never run through the fixpoint here (it is minutes of emulation per build); its release job's own test does the rest.
for static_arch in x86_64 aarch64; do
    grep -qE "^ablac-static-$static_arch-linux(\.sha256)?\$" <<< "$static_names" || { [[ $static_arch == x86_64 ]] && ((switched)); } || continue
    static=$out/ablac-static-$static_arch-linux
    if [[ $static_arch == x86_64 ]] && ((switched)); then static=$linux; fi   # decision #90 A: the static compiler is the default asset
    static_label=static
    [[ $static_arch == x86_64 ]] || static_label=static-$static_arch
    host=$(uname -s)/$(uname -m)
    if [[ ! -f $static ]]; then
        report FAIL "$static_label" "the static compiler's checksum is here but not the compiler"
    elif [[ $static_arch == x86_64 && $host != Linux/x86_64 ]]; then
        report FAIL "$static_label" "this host cannot run ablac-static-x86_64-linux"
    elif [[ $static_arch == aarch64 && $host != Linux/aarch64 && ( $host != Linux/x86_64 || -z $(command -v qemu-aarch64 || true) ) ]]; then
        report SKIP "$static_label" "this host cannot run ablac-static-aarch64-linux (needs Linux AArch64, or Linux x86-64 with qemu-aarch64)"
    else
        chmod +x "$static"
        static_args=("$static" "$version")
        # The default asset (decision #90 A) must reach the fixpoint: its archives come from nix (tools/static-llvm-env.sh) when the caller set none.
        if ((switched)) && [[ $static_arch == x86_64 && -z ${ABLA_STATIC_LLVM_LIB:-} ]]; then
            eval "$("$(dirname -- "${BASH_SOURCE[0]}")/static-llvm-env.sh" 2> "$out/static-llvm-env.log")" || true
        fi
        if [[ $static_arch == aarch64 || -z ${ABLA_STATIC_LLVM_LIB:-} ]]; then static_args+=(--no-fixpoint); fi
        if ((switched)) && [[ $static_arch == x86_64 && -z ${ABLA_STATIC_LLVM_LIB:-} ]]; then
            report FAIL "$static_label" "the default asset needs its fixpoint check: no static LLVM archives (ABLA_STATIC_LLVM_LIB, or nix for tools/static-llvm-env.sh: $out/static-llvm-env.log)"
            continue
        fi
        if (cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && STATIC_ARTIFACT_OUTPUT="$out/static-check-$static_arch" tools/test-static-artifact.sh "${static_args[@]}") > "$out/static-$static_arch.log" 2>&1; then
            report PASS "$static_label" "no PT_INTERP, no DT_NEEDED, smoke compile$([[ $static_arch == x86_64 && -n ${ABLA_STATIC_LLVM_LIB:-} ]] && echo ', fixpoint' || echo ' (no fixpoint)')"
        else
            report FAIL "$static_label" "$(tail -n 1 "$out/static-$static_arch.log") ($out/static-$static_arch.log)"
        fi
    fi
done

# 7b. static-input: the static compiler is built from the compiler that is published as ablac-dynamic-x86_64-linux. The run's Linux job logs the sha256 of
# the compiler the static step builds from (`static input compiler sha256: <hash>`); it must be the dynamic asset's. A run without that line (a release before
# the step logged it) is a SKIP that says so; a different hash is a FAIL (the static asset was built from another stage than the one published).
if ((switched)) && [[ -f $out/ablac-dynamic-x86_64-linux ]]; then
    static_input_job=
    static_input_log=
    if command -v gh > /dev/null 2>&1; then
        static_input_job=$(gh run view "$run_id" -R "$repo" --json workflowName,jobs --jq \
            'select(.workflowName == "Release") | .jobs[] | select(.name | test("^compiler \\(ubuntu-[^,]*, ablac-x86_64-linux,")) | .databaseId' 2>/dev/null | awk 'NR == 1') || static_input_job=
        [[ -z $static_input_job ]] || static_input_log=$(gh run view "$run_id" -R "$repo" --job "$static_input_job" --log 2>/dev/null) || static_input_log=
    fi
    static_input_log=${static_input_log//$'\r'/}
    if [[ -z $static_input_log ]]; then
        report SKIP static-input "cannot read the Linux job log of run $run_id"
    else
        logged=$(awk '/static input compiler sha256: / { print $NF; exit }' <<< "$static_input_log")
        if [[ ! $logged =~ ^[[:xdigit:]]{64}$ ]]; then
            report SKIP static-input "WARNING: run $run_id logged no 'static input compiler sha256' line (a release from before the step printed it): the static asset's input is unchecked"
        elif [[ ${logged,,} == "$(sha256 "$out/ablac-dynamic-x86_64-linux")" ]]; then
            report PASS static-input "the static compiler was built from the published dynamic asset (${logged:0:12})"
        else
            report FAIL static-input "the static compiler was built from ${logged:0:12}, not the published dynamic asset ($(sha256 "$out/ablac-dynamic-x86_64-linux" | cut -c1-12))"
        fi
    fi
fi

# 8. toolchain: when the release ships the dynamic toolchain archive beside the default (abla-toolchain-dynamic-x86_64-linux.tar.gz, an opt-in, like
# decision #90 A), `abla-toolchain-x86_64-linux.tar.gz` is the static package (tools/package-linux-static-toolchain.sh): no PT_INTERP and no
# DT_NEEDED in libexec/ablac.bin and libexec/abla-install-xtensa-native, no shared library, libLLVM, libclang-cpp, clang, ld.lld, opt or llc in
# it, at most 60 MB as an archive and 150 MB unpacked, and its launcher prints the version with an empty PATH.
if ((toolchain_switched)); then
    tarball=$out/abla-toolchain-x86_64-linux.tar.gz
    if [[ ! -f $tarball ]]; then
        report FAIL toolchain "no abla-toolchain-x86_64-linux.tar.gz beside the dynamic one"
    else
        unpack=$(mktemp -d)
        mkdir -p "$unpack/empty"
        bad=
        if ! tar -xzf "$tarball" -C "$unpack" --strip-components=1; then
            bad="the archive does not unpack;"
        else
            size=$(stat -c %s "$tarball")
            ((size <= 60 * 1048576)) || bad="$bad the archive is $((size / 1048576)) MB (cap 60);"
            unpacked=$(du -sb "$unpack" | cut -f1)
            ((unpacked <= 150 * 1048576)) || bad="$bad unpacked it is $((unpacked / 1048576)) MB (cap 150);"
            for executable in libexec/ablac.bin libexec/abla-install-xtensa-native; do
                if [[ ! -f $unpack/$executable ]]; then
                    bad="$bad no $executable;"
                elif ! readelf -h "$unpack/$executable" > /dev/null 2>&1; then
                    bad="$bad $executable is not an ELF file;"
                elif segments=$(readelf -lW "$unpack/$executable") && grep -q 'INTERP\|Shared library' <<< "$segments"; then
                    bad="$bad $executable is not static;"
                fi
            done
            found=$(cd "$unpack" && find . -type f \( -name '*.so' -o -name '*.so.*' -o -name 'libLLVM*' -o -name 'libclang-cpp*' -o -name clang -o -name ld.lld -o -name opt -o -name llc \) -print)
            [[ -z $found ]] || found=$(sed -n 1,5p <<< "$found" | tr '\n' ' ')
            [[ -z $found ]] || bad="$bad it holds ${found% };"
            reported=$(env -i PATH="$unpack/empty" HOME="$unpack" "$unpack/bin/ablac" --version 2>&1 || true)
            [[ $reported == "ablac $version" ]] || bad="$bad its launcher printed '$reported' with an empty PATH;"
        fi
        if [[ -z $bad ]]; then
            report PASS toolchain "the static package: no PT_INTERP, no DT_NEEDED, no shared library or external LLVM tool, $((size / 1048576)) MB, version $version with an empty PATH"
        else
            report FAIL toolchain "${bad# }"
        fi
        rm -rf -- "$unpack"
    fi
fi

# 10. playground: when the run ships the browser compiler (tools/build-playground.sh): the manifest names this version, the module is the one the
# manifest hashes and at most 8 MB, and the stdlib bundle's name carries its hash.
if ((playground_present)); then
    tarball=$out/abla-playground-$version.tar.gz
    unpack=$(mktemp -d)
    bad=
    if ! tar -xzf "$tarball" -C "$unpack" --strip-components=1 || [[ ! -f $unpack/manifest.json ]]; then
        bad="the archive does not unpack to a manifest;"
    else
        manifest=$unpack/manifest.json
        [[ $(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$manifest") == "$version" ]] || bad="$bad the manifest does not name version $version;"
        compiler_file=$(sed -n '/^  "compiler": {/,/^  },/s/^    "file": "\(.*\)",$/\1/p' "$manifest")
        compiler_hash=$(sed -n '/^  "compiler": {/,/^  },/s/^    "sha256": "\(.*\)"$/\1/p' "$manifest")
        stdlib_file=$(sed -n '/^  "stdlib": {/,/^  },/s/^    "file": "\(.*\)",$/\1/p' "$manifest")
        stdlib_hash=$(sed -n '/^  "stdlib": {/,/^  },/s/^    "sha256": "\(.*\)"$/\1/p' "$manifest")
        if [[ -z $compiler_file || ! -f $unpack/$compiler_file ]]; then
            bad="$bad the manifest names no module in the archive;"
        else
            [[ $(sha256sum "$unpack/$compiler_file" | cut -d' ' -f1) == "$compiler_hash" ]] || bad="$bad the module does not match its hash;"
            size=$(wc -c < "$unpack/$compiler_file" | tr -d " ")
            ((size <= 8 * 1048576)) || bad="$bad the module is $((size / 1048576)) MB (cap 8);"
        fi
        [[ -n $stdlib_file && -f $unpack/$stdlib_file && $stdlib_file == *"$stdlib_hash"* && $(sha256sum "$unpack/$stdlib_file" | cut -d' ' -f1) == "$stdlib_hash" ]] ||
            bad="$bad the stdlib bundle is missing or does not carry its hash;"
    fi
    if [[ -z $bad ]]; then
        report PASS playground "version $version, the module matches its hash ($((size / 1048576)) MB), the stdlib bundle carries its hash"
    else
        report FAIL playground "${bad# }"
    fi
    rm -rf -- "$unpack"
fi

# 11. windows: when the run ships either Windows toolchain (tools/package-windows-toolchain.sh): one top
# directory holding bin/ablac.exe, bin/llvm-objcopy.exe (--backtrace), share/abla/{runtime,stdlib} (with runtime/windows/imports/*.txt) and share/licenses; no repository or build
# metadata; at most 150 MB as an archive and 400 MB unpacked; ablac.exe carries this version's string and, read by tools/pe-info (built by the
# release's Linux compiler), is a console PE32+ image for the selected architecture with no C runtime import. The Windows job
# of the release exercises it on a Windows runner. Check its native self-build in the same run against this exact zip.
windows_jobs=
if [[ -f $out/abla-toolchain-x86_64-windows.zip || -f $out/ablac-windows-arm64.zip ]]; then
    windows_jobs=$(gh run view "$run_id" -R "$repo" --json workflowName,jobs --jq \
        'select(.workflowName == "Release") | .jobs[] | [.name, .status, .conclusion, .databaseId] | @tsv' 2>/dev/null) || windows_jobs=
fi

check_windows_fixpoint() {
    local label=$1 archive=$2 job_name=$3 job log zip_hash stages
    local job_pattern='^completed success ([1-9][0-9]*)$'
    local stages_pattern='^([[:xdigit:]]{64}) ([[:xdigit:]]{64})$'
    job=$(awk -F '\t' -v name="$job_name" '$1 == name { print $2, $3, $4 }' <<< "$windows_jobs")
    if [[ ! $job =~ $job_pattern ]]; then
        report FAIL "$label" "run $run_id has no unique successful $job_name job"
        return
    fi
    if ! log=$(gh run view "$run_id" -R "$repo" --job "${BASH_REMATCH[1]}" --log 2>/dev/null); then
        report FAIL "$label" "cannot read $job_name logs for run $run_id"
        return
    fi
    log=${log//$'\r'/}
    zip_hash=$(awk '/ Windows fixed-point zip SHA-256: / { print $NF }' <<< "$log")
    if [[ ! $zip_hash =~ ^[[:xdigit:]]{64}$ || ${zip_hash,,} != "$(sha256 "$archive")" ]]; then
        report FAIL "$label" "$job_name did not verify this Windows zip"
        return
    fi
    stages=$(awk '/ ablac\.exe stage2 / && $(NF-1) == "stage3" {
        sub(/,$/, "", $(NF-2)); print $(NF-2), $NF
    }' <<< "$log")
    if [[ ! $stages =~ $stages_pattern || ${BASH_REMATCH[1],,} != "${BASH_REMATCH[2],,}" ]]; then
        report FAIL "$label" "$job_name has missing or different stage 2/3 PE hashes"
        return
    fi
    local fixed_pe=${BASH_REMATCH[1],,}
    if ! grep -qE ' Windows stage2 == stage3 \(native\)$' <<< "$log"; then
        report FAIL "$label" "$job_name did not complete the native tier"
        return
    fi
    report PASS "$label" "run $run_id native stage 2/3 PE SHA-256 $fixed_pe"
}

for windows_machine in x86_64 aarch64; do
    top=abla-toolchain-$windows_machine-windows
    zipfile=$out/$top.zip
    check=windows
    job_name=windows-fixpoint
    if [[ $windows_machine == aarch64 ]]; then
        zipfile=$out/ablac-windows-arm64.zip
        check=windows-arm64
        job_name='windows-arm64 / Compare two native ARM64 compiler self-builds'
    fi
    [[ -f $zipfile ]] || continue
    check_windows_fixpoint "$check-fixpoint" "$zipfile" "$job_name"
    size=$(stat -c %s "$zipfile")
    if ((size > 150 * 1048576)); then
        report FAIL "$check" "the archive is $((size / 1048576)) MB (cap 150)"
        continue
    fi
    unpack=$(mktemp -d)
    bad=
    if ! command -v unzip > /dev/null; then
        report FAIL "$check" "unzip is not installed"
    elif ! unzip -q "$zipfile" -d "$unpack"; then
        report FAIL "$check" "the archive does not unzip"
    else
        unpacked=$(du -sb "$unpack" | cut -f1)
        ((unpacked <= 400 * 1048576)) || bad="$bad unpacked it is $((unpacked / 1048576)) MB (cap 400);"
        outside=$(unzip -Z1 "$zipfile" | grep -v "^$top/" | head -3 | tr '\n' ' ' || true)
        [[ -z $outside ]] || bad="$bad entries outside $top/: ${outside% };"
        [[ -d $unpack/$top/share/abla/stdlib ]] || bad="$bad no share/abla/stdlib directory;"
        for required in bin/ablac.exe bin/llvm-objcopy.exe share/abla/runtime/windows/imports/kernel32.txt share/licenses/abla.txt; do
            [[ -f $unpack/$top/$required ]] || bad="$bad no $required;"
        done
        metadata=$(unzip -Z1 "$zipfile" | grep -E '(^|/)\.git(/|$)|\.abla-' | head -3 | tr '\n' ' ' || true)
        [[ -z $metadata ]] || bad="$bad it carries repository or build metadata: ${metadata% };"
        exe=$unpack/$top/bin/ablac.exe
        if [[ -f $exe ]]; then
            version_pattern=${version//./\\.}
            grep -azqE "ablac $version_pattern([[:space:]]|$)" "$exe" || bad="$bad ablac.exe does not carry the string 'ablac $version';"
            root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
            host=
            pe_info=${ABLA_PE_INFO:-$unpack/pe-info}
            for candidate in "$out/ablac-x86_64-linux" "$out/ablac-static-x86_64-linux"; do
                [[ -x $candidate ]] && { host=$candidate; break; }
            done
            if [[ -z ${ABLA_PE_INFO:-} ]] && { [[ -z $host ]] || ! ABLA_SYSROOT=$root "$host" build "$root/tools/pe-info/main.ab" -o "$pe_info" --fast --no-cache > "$unpack/pe-info.log" 2>&1; }; then
                bad="$bad tools/pe-info could not be built by the release's Linux compiler;"
            elif ! report_pe=$("$pe_info" "$exe" --no-crt 2> "$unpack/pe-info.err"); then
                bad="$bad ablac.exe: $(tail -n 1 "$unpack/pe-info.err");"
            elif ! grep -qxF "machine $windows_machine" <<< "$report_pe" || ! grep -qx 'subsystem console' <<< "$report_pe"; then
                bad="$bad ablac.exe: expected console PE for $windows_machine;"
            fi
        fi
        if [[ -z $bad ]]; then
            report PASS "$check" "the toolchain layout, $((size / 1048576)) MB, ablac.exe is a console PE for $windows_machine with no C runtime import and carries version $version"
        else
            report FAIL "$check" "${bad# }"
        fi
    fi
    rm -rf -- "$unpack"
done

printf 'release-check %s  run %s  %s\n' "$tag" "$run_id" "$out"
printf '%s\n' "${results[@]}"
if ((failed)); then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS (nothing is published by this script)"
if [[ ! -f $out/SHA256SUMS.sig ]]; then
    printf 'next: sign the assets (the key from a separate clone, never the shared repo), from the release commit checkout:\n'
    printf '  tools/sign-release.sh %s <keyfile> --tag %s   # SBOM + SHA256SUMS + SHA256SUMS.sig in the same directory\n' "$out" "$tag"
    printf '  tools/release-check.sh %s %s <stage2> --artifacts %s ...   # its signature check must now PASS\n' "$tag" "$run_id" "$out"
    printf 'then upload every file of %s with gh release create\n' "$out"
fi
