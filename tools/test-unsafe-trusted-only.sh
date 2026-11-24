#!/usr/bin/env bash
# abla/unsafe's raw-address functions and raw constructors can be used only from trusted code (#1226, decision #130 A):
# the standard library marks them `@__abla_trusted_only("<phase>[ <release>]: <help>")` (src/sema.ab), as
# tools/unsafe-trusted-only.tsv lists them. Checked here:
#   - the marks and the list agree: every restricted declaration that is not already a trusted extern carries the marker, and
#     no other declaration of abla/unsafe does;
#   - with the standard library as it is (phase "warn"), a call from code that is not trusted builds and warns
#     (warning[E_SEMANTIC]: native.trust:...), and stdlib-heavy programs build with no such warning (the library's own uses
#     are trusted);
#   - with every marker at "error" (a copy of the standard library), a call, a raw constructor call and a reference to the
#     function as a value from code that is not trusted (run-time or compile-time code alike) are `native.trust:<name>` with the
#     help, and the same call inside a trusted function, the factory, the checked methods and module values made with the
#     open producers of a program-lifetime address (static storage, a function's address) are accepted;
#   - the marker on a program's own declaration is annotation.reserved.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=$root/build/unsafe-trusted-only
rm -rf "$out"
mkdir -p "$out"
fail() { echo "unsafe trusted-only: $1" >&2; exit 1; }
cases=tests/cases/trusted-only

# The list and the marks.
expected=$(awk -F'\t' 'NR > 1 && $6 == "restricted" && $2 != "trusted extern fun" { print $3 }' tools/unsafe-trusted-only.tsv | sort)
marked=$(awk 'previous ~ /^@__abla_trusted_only/ {
        line = $0
        sub(/^(private |trusted |noescape |inline )*/, "", line)
        sub(/^(resource class|class|fun|(noescape )?extern(:"[a-z]+")? fun) /, "", line)
        sub(/[(<].*/, "", line)
        print line
    } { previous = $0 }' $(find stdlib/abla/unsafe -name '*.ab') | sort)
[[ -n $expected ]] || fail 'no restricted declarations in tools/unsafe-trusted-only.tsv'
[[ $expected == "$marked" ]] || fail "the marks and tools/unsafe-trusted-only.tsv differ: $(diff <(echo "$expected") <(echo "$marked") | head -6)"
count=$(wc -l <<< "$expected")

# build <stdlib> <name>: the program's build output in $out/<name>.log, its status in $status.
build() {
    status=0
    ABLA_STDLIB=$1 "$compiler" build "$cases/$2.ab" -o "$out/$2" --fast --no-cache > "$out/$2.log" 2>&1 || status=$?
}

# Phase "warn" (the standard library as it is).
build "$root/stdlib" plain-call
[[ $status == 0 ]] || fail "plain-call did not build in the warn phase: $(head -4 "$out/plain-call.log")"
grep -q 'warning\[E_SEMANTIC\]: native.trust:nativePointerAddress' "$out/plain-call.log" || fail "plain-call: no warning: $(head -4 "$out/plain-call.log")"
grep -q 'from 0.2.73' "$out/plain-call.log" || fail 'plain-call: the warning does not name the release'
for program in tests/cases/modules/bytes.ab tests/cases/modules/linux-net.ab tests/cases/modules/http-async.ab; do
    name=$(basename "$program" .ab)
    "$compiler" build "$program" -o "$out/stdlib-$name" --fast --no-cache > "$out/stdlib-$name.log" 2>&1 ||
        fail "$program did not build: $(head -3 "$out/stdlib-$name.log")"
    ! grep -q 'native.trust' "$out/stdlib-$name.log" || fail "$program warns about the standard library's own uses: $(grep -m2 -A1 native.trust "$out/stdlib-$name.log")"
done

# Phase "error": every marker flipped, in a copy of the standard library.
mkdir -p "$out/stdlib"
cp -R stdlib/. "$out/stdlib/"
find "$out/stdlib/abla/unsafe" -name '*.ab' -exec sed -i 's/^@__abla_trusted_only("warn 0.2.73/@__abla_trusted_only("error/' {} +
for refused in plain-call:nativePointerAddress constructor:NativeByteBuffer reference:nativePointerAddress \
    compile-time:nativePointerAddress; do
    IFS=: read -r name what <<< "$refused"
    build "$out/stdlib" "$name"
    [[ $status != 0 ]] || fail "$name built with the marker at error"
    grep -q "native.trust:$what" "$out/$name.log" || fail "$name: no native.trust:$what: $(head -4 "$out/$name.log")"
done
grep -q 'help: allocate one with nativeByteBuffer(capacity)' "$out/constructor.log" || fail "constructor: no factory help: $(head -5 "$out/constructor.log")"
grep -q 'help: wrap the call in a trusted function' "$out/plain-call.log" || fail "plain-call: no help: $(head -5 "$out/plain-call.log")"
for accepted in trusted-call open; do
    build "$out/stdlib" "$accepted"
    [[ $status == 0 ]] || fail "$accepted was refused: $(head -4 "$out/$accepted.log")"
    ! grep -q 'native.trust' "$out/$accepted.log" || fail "$accepted warned: $(head -3 "$out/$accepted.log")"
    "$out/$accepted" > "$out/$accepted.out" || fail "$accepted did not run"
done

# The marker on a program's own declaration.
build "$root/stdlib" reserved
[[ $status != 0 ]] && grep -q 'annotation.reserved:__abla_trusted_only' "$out/reserved.log" ||
    fail "reserved: status $status: $(head -3 "$out/reserved.log")"
echo "unsafe trusted-only: $count marks agree with the list; warn phase warns and builds, the standard library does not warn; at error a call, a constructor and a reference are refused, trusted code, factories and checked methods are not; the marker is the standard library's"
