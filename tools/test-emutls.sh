#!/usr/bin/env bash
# abla/runtime/emutls (#826): the emulated thread-local storage the macOS compiler exports for `ablac run`, instead of
# compiler-rt's. tests/cases/emutls drives it through its interface with LLVM's control blocks (alignment, initial values,
# one copy per thread, forty rounds of nine threads racing on first use, the memory a thread leaves behind), release and
# --fast. Then, on any host: the object of a Mach-O (arm64-macos) program that exports it is made from the LLVM IR the
# compiler writes before it needs a macOS SDK, and `llvm-nm` must show ___emutls_get_address defined and no
# libSystem allocation or pthread-key symbol that the module adds (the compiler's own link on a Mac is judged by
# tools/test-libsystem-imports.sh in the macOS CI job).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/emutls
rm -rf "$out"
mkdir -p "$out/mach"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/emutls/main.ab -o "$out/main.$mode" "${flags[@]}"
    status=0
    result=$("$root/tools/run-limited.sh" "$out/main.$mode") || status=$?
    [[ $status -eq 42 ]] || { echo "emutls ($mode): exit $status: $result" >&2; exit 1; }
    [[ $result == *"emutls leak per thread: "* ]] || { echo "emutls ($mode): no leak line: $result" >&2; exit 1; }
    printf '%s\n' "$result" | grep 'emutls leak'
done
# A JIT-compiled program (`ablac run`): its runtime's own thread-locals (transaction descriptor, root-frame head) go through the
# compiler's ___emutls_get_address while five threads run transactions and force collections of the program's heap.
result=$("$compiler" run tests/cases/emutls/jit.ab 2>&1) || { echo "emutls (run): $result" >&2; exit 1; }
[[ $result == *"jit emutls ok"* ]] || { echo "emutls (run): $result" >&2; exit 1; }
tools_dir=${ABLA_LLVM_TOOLS:-}
if [[ -z $tools_dir ]] || [[ ! -x $tools_dir/llc || ! -x $tools_dir/llvm-nm ]]; then
    tools_dir=$(dirname "$(command -v llc 2>/dev/null || true)")
fi
if [[ ! -x $tools_dir/llc || ! -x $tools_dir/llvm-nm ]]; then
    echo "emutls: no llc/llvm-nm (ABLA_LLVM_TOOLS): the Mach-O object check is skipped"
    echo "emutls ok"
    exit 0
fi
cat > "$out/mach/with.ab" <<'AB'
import "abla/runtime/emutls"
@export("__emutls_get_address")
fun ablaEmutlsGetAddress(control: int): int = emutlsGetAddress(control)
fun main: int = 0
AB
cat > "$out/mach/without.ab" <<'AB'
fun main: int = 0
AB
sdk="$out/mach/no-sdk"
mkdir -p "$sdk"
for name in with without; do
    # The link needs an SDK; the IR is written before that, so the build is expected to fail after writing it.
    ABLA_MACOS_SDK="$PWD/$sdk" "$compiler" build "$out/mach/$name.ab" --target arm64-macos --no-cache -o "$out/mach/$name" \
        > "$out/mach/$name.log" 2>&1 || true
    [[ -s $out/mach/$name.ll ]] || { echo "emutls: no LLVM IR for $name: $(head -3 "$out/mach/$name.log")" >&2; exit 1; }
    "$tools_dir/llc" -mtriple=arm64-apple-macosx11.0.0 -O1 -filetype=obj "$out/mach/$name.ll" -o "$out/mach/$name.o"
    "$tools_dir/llvm-nm" -u "$out/mach/$name.o" | sort > "$out/mach/$name.undefined"
done
"$tools_dir/llvm-nm" "$out/mach/with.o" > "$out/mach/with.defined"
grep -q ' T ___emutls_get_address$' "$out/mach/with.defined" ||
    { echo "emutls: ___emutls_get_address is not defined by the Mach-O object" >&2; exit 1; }
added=$(comm -13 "$out/mach/without.undefined" "$out/mach/with.undefined" | grep -v '^$' || true)
# The export adapter brings __longjmp (the compiler already imports it); nothing else may be new.
bad=$(printf '%s\n' "$added" | grep -v '^__longjmp$' | grep -v '^$' || true)
[[ -z $bad ]] || { echo "emutls: the module adds imports: $bad" >&2; exit 1; }
for symbol in _malloc _free _realloc _pthread_key_create _pthread_getspecific _pthread_setspecific; do
    ! grep -qx "$symbol" "$out/mach/with.undefined" || { echo "emutls: the Mach-O object imports $symbol" >&2; exit 1; }
done
echo "emutls ok"
