#!/usr/bin/env bash
# abla/unsafe's raw-address functions and raw constructors (#1226, decision #130 A) and abla/sys's raw system calls (decision
# #133 A) can be used only from trusted code: the standard library marks them
# `@__abla_trusted_only("<phase>[ <release>]: <help>")` (src/sema.ab), as tools/unsafe-trusted-only.tsv and
# tools/sys-trusted-only.tsv list them. Checked here:
#   - the marks and the lists agree: every restricted declaration that is not already a trusted extern carries the marker, and
#     no other declaration of abla/unsafe or abla/sys does;
#   - with a copy of the standard library whose markers are back at "warn 0.2.73" (the phase stays tested), a call from code that is not trusted builds and warns
#     (warning[E_SEMANTIC]: native.trust:...), and stdlib-heavy programs build with no such warning (the library's own uses
#     are trusted);
#   - with the standard library as it is (every marker at "error"), a call, a raw constructor call and a reference to the
#     function as a value from code that is not trusted (run-time or compile-time code alike) are `native.trust:<name>` with the
#     help, and the same call inside a trusted function, the factory, the checked methods and module values made with the
#     open producers of a program-lifetime address (static storage, a function's address) are accepted;
#   - a write of a field of a marked class (reopening a closed buffer) from code that is not trusted is
#     `native.trust:<class>.<field>` (decision #161 A; a warning in the warn phase), and the same write in a trusted function and a
#     read of the field from ordinary code are accepted;
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

# The lists and the marks: tools/unsafe-trusted-only.tsv for abla/unsafe, tools/sys-trusted-only.tsv for abla/sys (#133 A).
count=0
for pair in unsafe-trusted-only.tsv:unsafe sys-trusted-only.tsv:sys; do
    IFS=: read -r list module <<< "$pair"
    expected=$(awk -F'\t' 'NR > 1 && $6 == "restricted" && $2 != "trusted extern fun" { print $3 }' "tools/$list" | sort)
    marked=$(awk 'previous ~ /^@__abla_trusted_only/ {
            line = $0
            sub(/^(private |trusted |noescape |inline )*/, "", line)
            sub(/^(resource class|class|fun|(noescape )?extern(:"[a-z]+")? fun) /, "", line)
            sub(/[(<].*/, "", line)
            print line
        } { previous = $0 }' $(find "stdlib/abla/$module" -name '*.ab') | sort)
    [[ -n $expected ]] || fail "no restricted declarations in tools/$list"
    [[ $expected == "$marked" ]] || fail "the marks and tools/$list differ: $(diff <(echo "$expected") <(echo "$marked") | head -6)"
    count=$((count + $(wc -l <<< "$expected")))
done

# build <stdlib> <name>: the program's build output in $out/<name>.log, its status in $status.
build() {
    status=0
    ABLA_STDLIB=$1 "$compiler" build "$cases/$2.ab" -o "$out/$2" --fast --no-cache > "$out/$2.log" 2>&1 || status=$?
}

# Phase "warn" (a copy of the standard library with every marker back at "warn 0.2.73": the phase stays tested after the flip).
mkdir -p "$out/warn-stdlib"
cp -R stdlib/. "$out/warn-stdlib/"
find "$out/warn-stdlib/abla/unsafe" "$out/warn-stdlib/abla/sys" -name '*.ab' -exec sed -i 's/^@__abla_trusted_only("error/@__abla_trusted_only("warn 0.2.73/' {} +
build "$out/warn-stdlib" plain-call
[[ $status == 0 ]] || fail "plain-call did not build in the warn phase: $(head -4 "$out/plain-call.log")"
grep -q 'warning\[E_SEMANTIC\]: native.trust:nativePointerAddress' "$out/plain-call.log" || fail "plain-call: no warning: $(head -4 "$out/plain-call.log")"
grep -q 'from 0.2.73' "$out/plain-call.log" || fail 'plain-call: the warning does not name the release'
build "$out/warn-stdlib" field-write
[[ $status == 0 ]] && grep -q 'warning\[E_SEMANTIC\]: native.trust:NativeByteBuffer.closed' "$out/field-write.log" ||
    fail "field-write: the warn phase did not build with a warning: $(head -4 "$out/field-write.log")"
for program in tests/cases/modules/bytes.ab tests/cases/modules/linux-net.ab tests/cases/modules/http-async.ab; do
    name=$(basename "$program" .ab)
    "$compiler" build "$program" -o "$out/stdlib-$name" --fast --no-cache > "$out/stdlib-$name.log" 2>&1 ||
        fail "$program did not build: $(head -3 "$out/stdlib-$name.log")"
    ! grep -q 'native.trust' "$out/stdlib-$name.log" || fail "$program warns about the standard library's own uses: $(grep -m2 -A1 native.trust "$out/stdlib-$name.log")"
done

# Phase "error" (the standard library as it is: every marker is at "error").
for refused in plain-call:nativePointerAddress constructor:NativeByteBuffer reference:nativePointerAddress \
    compile-time:nativePointerAddress plain-syscall:linuxSyscall1 field-write:NativeByteBuffer.closed \
    field-extension:NativeByteBuffer.closed; do
    IFS=: read -r name what <<< "$refused"
    build "$root/stdlib" "$name"
    [[ $status != 0 ]] || fail "$name built with the marker at error"
    grep -q "native.trust:$what" "$out/$name.log" || fail "$name: no native.trust:$what: $(head -4 "$out/$name.log")"
done
grep -q 'help: allocate one with nativeByteBuffer(capacity)' "$out/constructor.log" || fail "constructor: no factory help: $(head -5 "$out/constructor.log")"
grep -q 'help: wrap the call in a trusted function' "$out/plain-call.log" || fail "plain-call: no help: $(head -5 "$out/plain-call.log")"
grep -q 'help: call the abla/sys wrapper' "$out/plain-syscall.log" || fail "plain-syscall: no help: $(head -5 "$out/plain-syscall.log")"
grep -q 'help: .NativeByteBuffer.'"'"'s own functions change its fields' "$out/field-write.log" || fail "field-write: no help: $(head -5 "$out/field-write.log")"
[[ $(grep -c 'native.trust:NativeByteBuffer.closed' "$out/field-extension.log") -ge 2 ]] ||
    fail "field-extension: the write by this. and by the bare name are not both refused: $(head -6 "$out/field-extension.log")"
# The classes that own raw memory, or whose fields trusted code writes at, and the string wipes (decision #165): made, written or
# called from ordinary code, each is refused.
build "$root/stdlib" sealed-memory
[[ $status != 0 ]] || fail "sealed-memory built"
for what in ByteBuffer.stage ByteBuffer.staged AesKey AesGcmKey RsaPrivateKey Keccak Keccak.closed LlvmOrcSession.closed \
    LlvmOrcGeneration.closed cryptoWipeString tlsWipe TlsIdentityKeys Sha256Stream Sha256Stream.pending TlsStoredTicket TlsTicketState; do
    grep "error\[E_SEMANTIC\]: native.trust:$what\($\|@\|:\)" "$out/sealed-memory.log" > /dev/null ||
        fail "sealed-memory: $what is not refused: $(head -4 "$out/sealed-memory.log")"
done
# The TLS machines' key material is private to their modules (decision #165): code outside can neither read nor set it, so it cannot
# give a machine a string of its own to wipe.
build "$root/stdlib" machine-secrets
[[ $status != 0 ]] || fail "machine-secrets built"
for what in TlsClient.handshakeSecret TlsClient.keyPairs TlsClient.masterSecret TlsServer.master TlsServer.v12Pair TlsServer.ticketMaster; do
    grep "error\[E_SEMANTIC\]: name.private:$what:" "$out/machine-secrets.log" > /dev/null ||
        fail "machine-secrets: $what is not private: $(head -4 "$out/machine-secrets.log")"
done
for accepted in trusted-call open trusted-syscall trusted-field caller-strings; do
    build "$root/stdlib" "$accepted"
    [[ $status == 0 ]] || fail "$accepted was refused: $(head -4 "$out/$accepted.log")"
    ! grep -q 'native.trust' "$out/$accepted.log" || fail "$accepted warned: $(head -3 "$out/$accepted.log")"
    "$out/$accepted" > "$out/$accepted.out" || fail "$accepted did not run"
done

# Member calls (no extension function of the standard library is marked outside abla/kernel, so a copy adds two probes):
# a marked extension function called as a method, a marked operator function used as an operator and a method of a value
# from an aliased import are refused (they reach the declaration by a member call, not a plain call); the same calls in a
# trusted function are accepted. A method is not a value, a type alias names no class and indexing is no operator
# function, so those routes do not exist.
mkdir -p "$out/probe-stdlib"
cp -R stdlib/. "$out/probe-stdlib/"
cat >> "$out/probe-stdlib/abla/unsafe/memory/entry.ab" <<'PROBE'

/** A probe for the trusted-only check on member calls. */
@__abla_trusted_only("error: call the probe's checked form")
trusted fun NativeByteBuffer.trustedOnlyProbe(index: int): int = index + this.capacity

/** A probe for the trusted-only check on operators. */
@__abla_trusted_only("error: call the probe's checked form")
operator fun NativeByteBuffer.plus(index: int): int = index + this.capacity
PROBE
for refused in member-call:native.trust:NativeByteBuffer.trustedOnlyProbe member-operator:native.trust:NativeByteBuffer.plus \
    member-alias:native.trust:NativeByteBuffer.trustedOnlyProbe alias-call:native.trust:nativePointerAddress \
    member-value:member:NativeByteBuffer.trustedOnlyProbe \
    type-alias:type.underlying:Bytes indexer:operator.declaration:Box.get; do
    IFS=: read -r name rule what <<< "$refused"
    build "$out/probe-stdlib" "$name"
    [[ $status != 0 ]] || fail "$name built"
    grep -q "error\[E_SEMANTIC\]: $rule:$what" "$out/$name.log" || fail "$name: no $rule:$what: $(head -4 "$out/$name.log")"
done
grep -q "help: call the probe's checked form" "$out/member-call.log" || fail "member-call: no help: $(head -5 "$out/member-call.log")"
build "$out/probe-stdlib" trusted-member
[[ $status == 0 ]] || fail "trusted-member was refused: $(head -4 "$out/trusted-member.log")"
[[ $("$out/trusted-member") == 19 ]] || fail "trusted-member did not print 19"

# The marker on a program's own declaration.
build "$root/stdlib" reserved
[[ $status != 0 ]] && grep -q 'annotation.reserved:__abla_trusted_only' "$out/reserved.log" ||
    fail "reserved: status $status: $(head -3 "$out/reserved.log")"
echo "unsafe trusted-only: $count marks agree with the lists; warn phase warns and builds, the standard library does not warn; at error a call, a constructor, a reference, a raw system call and a member call or operator reaching a marked extension are refused, trusted code, factories, checked methods and abla/sys's wrappers are not; the marker is the standard library's"
