#!/usr/bin/env bash
# #806 step C, the release side: what a static compiler artifact (build/ablac-static from tools/build-static-compiler.sh) must be before it
# ships next to the dynamic one:
#   1. a static-pie executable with no PT_INTERP and no DT_NEEDED (it needs no loader and no library);
#   2. a smoke compile: it builds and runs a hello-world, and its --version is `ablac <version>` when one is expected;
#   3. the fixpoint: the static compiler builds src/orc_main_static.ab (pass 2), pass 2 builds it again (pass 3), and the two are
#      byte for byte the same. Pass 1, the artifact itself, may differ from pass 2 only when the static table in the generated
#      assembly changed since the compiler that built it (that table comes from the BUILDING compiler's source: two passes before it
#      holds), so pass 1 against pass 2 is reported, and only pass 2 against pass 3 fails the check.
# It needs the static archives again for the self-builds (ABLA_STATIC_LLVM_LIB, ABLA_STATIC_ZLIB; eval "$(tools/static-llvm-env.sh)").
# Usage: tools/test-static-artifact.sh <static-compiler> [expected-version] [--no-fixpoint]
set -euo pipefail
export LC_ALL=C
fixpoint=1
args=()
for argument in "$@"; do
    if [[ $argument == --no-fixpoint ]]; then fixpoint=0; else args+=("$argument"); fi
done
artifact=${args[0]:?usage: tools/test-static-artifact.sh <static-compiler> [expected-version] [--no-fixpoint]}
expected_version=${args[1]:-}
[[ $artifact == /* ]] || artifact="$PWD/$artifact"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'static artifact: Linux only'; exit 0; }
[[ -x $artifact ]] || { echo "static artifact: $artifact is not an executable" >&2; exit 1; }
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-8192}   # the self-builds of the fixpoint need more than the launcher's 2048 MB default
out=${STATIC_ARTIFACT_OUTPUT:-build/static-artifact}
rm -rf "$out"
mkdir -p "$out"
fail() { echo "static artifact: $*" >&2; exit 1; }

# 1. no interpreter, no needed library
segments=$(readelf -lW "$artifact")
if [[ $segments == *INTERP* ]]; then fail "$artifact has a PT_INTERP (it needs a loader)"; fi
needed=$(readelf -dW "$artifact" | grep -c '(NEEDED)' || true)
[[ $needed == 0 ]] || fail "$artifact has $needed DT_NEEDED entries: $(readelf -dW "$artifact" | grep '(NEEDED)' | tr -s ' ' | tr '\n' ' ')"
header=$(readelf -hW "$artifact")
[[ $header == *'Type:'*DYN* ]] || fail "$artifact is not a position-independent executable (static-pie)"
echo "static artifact: no PT_INTERP, no DT_NEEDED"

# 2. smoke compile
if [[ -n $expected_version ]]; then
    version=$("$artifact" --version)
    [[ $version == "ablac $expected_version" ]] || fail "--version is '$version', expected 'ablac $expected_version'"
fi
printf 'import "abla/io"\nfun main: int {\n    println("static hello")\n    0\n}\n' > "$out/hello.ab"
"$artifact" build "$out/hello.ab" -o "$out/hello" --no-cache > "$out/hello.build.log" 2>&1 || { tail -5 "$out/hello.build.log" >&2; fail "the smoke compile failed"; }
[[ $("$out/hello") == "static hello" ]] || fail "the smoke program printed the wrong text"
echo "static artifact: smoke compile ran"

# 3. the fixpoint
if ((fixpoint)); then
    [[ -n ${ABLA_STATIC_LLVM_LIB:-} && -f ${ABLA_STATIC_LLVM_LIB}/libLLVMSupport.a ]] ||
        fail 'the fixpoint needs ABLA_STATIC_LLVM_LIB (eval "$(tools/static-llvm-env.sh)"), or pass --no-fixpoint'
    "$artifact" build src/orc_main_static.ab -o "$out/pass2" --no-cache > "$out/pass2.log" 2>&1 || { tail -8 "$out/pass2.log" >&2; fail "the static compiler cannot build itself (pass 2)"; }
    "$out/pass2" build src/orc_main_static.ab -o "$out/pass3" --no-cache > "$out/pass3.log" 2>&1 || { tail -8 "$out/pass3.log" >&2; fail "pass 2 cannot build the compiler (pass 3)"; }
    cmp -s "$out/pass2" "$out/pass3" || fail "no fixpoint: pass 2 and pass 3 differ ($(sha256sum < "$out/pass2" | cut -c1-12) vs $(sha256sum < "$out/pass3" | cut -c1-12))"
    if cmp -s "$artifact" "$out/pass2"; then echo "static artifact: fixpoint (the artifact, pass 2 and pass 3 are the same $(wc -c < "$out/pass2") bytes)"
    else echo "static artifact: fixpoint (pass 2 == pass 3, $(wc -c < "$out/pass2") bytes; the artifact differs from them: its builder's static table was older)"; fi
fi
echo "static artifact: ok"
