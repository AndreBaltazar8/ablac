#!/usr/bin/env bash
# The runtime's own functions (stdlib/abla/runtime/…: its allocator's free and allocate, memory checkpoints and resets, the host
# registry) are trusted-only outside the standard library (#191; src/sema.ab, trustedOnlySpec). Checked here:
#   - from ordinary code, a call with no import, a call through `import "abla/runtime/memory"`, a reference to one as a value
#     and a call from a `compile fun` are each `native.trust:<name>` with the help, and do not build;
#   - a dependency's ordinary code (no trusted grant) that frees its caller's array the same way is refused too (#122 covers
#     only what a dependency defines);
#   - the same calls inside trusted functions build and run, and stdlib-heavy programs build with no native.trust (the
#     library's own uses are not affected).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=$root/build/runtime-trusted
rm -rf "$out"
mkdir -p "$out"
export ABLA_PACKAGE_CACHE="$out/cache"
fail() { echo "runtime trusted: $1" >&2; exit 1; }
cases=tests/cases/runtime-trusted

build() { # NAME: its output in $out/NAME.log, its status in $status
    status=0
    "$compiler" build "$cases/$1.ab" -o "$out/$1" --fast --no-cache > "$out/$1.log" 2>&1 || status=$?
}
for refused in free-call:__ablaRuntimeHostRegistryLast free-call:__ablaRuntimePlatformFree allocate:__ablaRuntimePlatformAllocateLayout \
    checkpoint:__ablaRuntimePlatformMemoryCheckpoint memory-import:runtimeMemoryCheckpoint memory-import:runtimeMemoryReset \
    reference:__ablaRuntimePlatformFree compile-time:__ablaRuntimePlatformMemoryCheckpoint; do
    IFS=: read -r name what <<< "$refused"
    [[ -f $out/$name.log ]] || build "$name"
    [[ $status != 0 ]] || fail "$name built"
    grep -q "error\[E_SEMANTIC\]: native.trust:$what\b" "$out/$name.log" || fail "$name: no native.trust:$what: $(head -4 "$out/$name.log")"
    grep -q "help: the runtime's own functions are for the standard library" "$out/$name.log" || fail "$name: no help: $(head -5 "$out/$name.log")"
done

build trusted-call
[[ $status == 0 ]] || fail "trusted-call did not build: $(head -4 "$out/trusted-call.log")"
[[ $("$out/trusted-call") == "live true checkpoint true" ]] || fail "trusted-call: $("$out/trusted-call" 2>&1 | head -2)"
for program in tests/cases/modules/bytes.ab tests/cases/modules/linux-net.ab tests/cases/modules/http-async.ab; do
    name=$(basename "$program" .ab)
    "$compiler" build "$program" -o "$out/stdlib-$name" --fast --no-cache > "$out/stdlib-$name.log" 2>&1 ||
        fail "$program did not build: $(head -3 "$out/stdlib-$name.log")"
    ! grep -q 'native.trust' "$out/stdlib-$name.log" || fail "$program: native.trust from the standard library's own uses: $(grep -m2 -A1 native.trust "$out/stdlib-$name.log")"
done

# A dependency, with no trusted grant, frees its caller's array through the runtime's own free.
dependency=$out/package/dependency
mkdir -p "$dependency/src"
git -C "$dependency" init --quiet --initial-branch=main
printf 'name = "dependency"\nversion = "0.1.0"\nentry = "src/dependency.ab"\n' > "$dependency/abla.toml"
cat > "$dependency/src/dependency.ab" <<'EOT'
fun dependencyBreak(words: array<int>): int {
    __ablaRuntimePlatformFree(__ablaRuntimeHostRegistryLast())
    words.size
}
EOT
git -C "$dependency" add -A
git -C "$dependency" -c user.name='Abla package test' -c user.email='abla-package-test@example.invalid' commit --quiet -m dependency
application=$out/package/application
mkdir -p "$application/src"
printf 'name = "runtime-app"\nversion = "0.1.0"\nentry = "src/main.ab"\n' > "$application/abla.toml"
printf 'compile fun dependencySource(): ImportSource = gitImportSource("dependency", "%s", "branch", "main")\n' "$dependency" > "$application/src/provider.ab"
cat > "$application/src/main.ab" <<'EOT'
import "abla/io"
import "provider.ab"
import dependencySource()

fun main {
    val words: array<int> = []
    for (k in 0 until 4096) words.append(7)
    println("size ${dependencyBreak(words)}")
}
EOT
status=0
{ "$compiler" package update --project "$application" &&
  "$compiler" build --project "$application" --fast --no-cache --offline; } > "$out/dependency.log" 2>&1 || status=$?
[[ $status != 0 ]] || fail "the dependency's free built"
grep -q 'native.trust:__ablaRuntimePlatformFree' "$out/dependency.log" || fail "dependency: no native.trust: $(grep -m3 error "$out/dependency.log")"
echo "runtime trusted: 8 refusals, the dependency's, the trusted calls and 3 stdlib programs passed"
