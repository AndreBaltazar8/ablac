#!/usr/bin/env bash
# Generates source-synchronized private RSA tests and a tagged A64 libc shim.
#
# All guest loads/stores really carry their tags under qemu-aarch64 TBI. The allocator never
# strips returned pointers. free/realloc reject a changed tag. This tests TBI, not MTE,
# bionic, real TLS interoperability or an Android device.
# Usage: prepare.sh ROOT SYSROOT OUTPUT
set -euo pipefail
root=$(cd "$1" && pwd)
sysroot=$(cd "$2" && pwd)
mkdir -p "$3"
out=$(cd "$3" && pwd)
here=$root/tests/cases/android-pointer-tags
printf 'compileCapabilities = ["filesystem.write"]\n' > "$out/abla.toml"

# The RSA secret bignum primitives of the sysroot's library, between their markers.
source=$sysroot/stdlib/abla/crypto/rsa/entry.ab
begin='// BEGIN RSA SECRET BIGNUM PRIMITIVES'
end='// END RSA SECRET BIGNUM PRIMITIVES'
[[ $(grep -cxF "$begin" "$source") == 1 && $(grep -cxF "$end" "$source") == 1 ]] ||
    { echo "prepare.sh: the RSA primitive markers must each occur once in $source" >&2; exit 1; }
host=$sysroot/stdlib/abla/runtime/platform/host.ab
[[ -f $host ]] || { echo "prepare.sh: no $host" >&2; exit 1; }
[[ $(grep -cF '"@HOST_PLATFORM@"' "$here/main.ab") == 1 ]] ||
    { echo 'prepare.sh: main.ab must name "@HOST_PLATFORM@" once' >&2; exit 1; }
# The platform path as a string literal (backslash and quote escaped).
escaped=${host//\\/\\\\}
escaped=${escaped//\"/\\\"}
{
    awk -v path="\"$escaped\"" '{ i = index($0, "\"@HOST_PLATFORM@\""); if (i) $0 = substr($0, 1, i - 1) path substr($0, i + 17); print }' "$here/main.ab"
    printf '\n'
    awk -v b="$begin" -v e="$end" '$0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$source"
} > "$out/fixture.ab"

# Relative to the repository root, as the driver names them.
relative=${out#"$root"/}
[[ $relative != "$out" ]] || { echo "prepare.sh: $out is not under $root" >&2; exit 1; }
for profile in release fast; do
    fast=false
    [[ $profile != fast ]] || fast=true
    cat > "$out/$profile-build.ab" <<DRIVER
import "abla/build"
import "abla/compiler"
#compilerGrant("filesystem.write")
compile fun taggedObject(): bool {
    val target = defineTarget("tagged-arm64", "aarch64-unknown-linux-gnu", "elf", "none", "none", false, false)
    target && buildProgram("tagged-pointers", "$relative/fixture.ab", "$relative/$profile.o", "tagged-arm64", "object", $fast, false)
}
val built = #taggedObject()
fun main: int = if (built) 0 else 1
DRIVER
done

awk -v fragments="$here" -f "$here/tagged.awk" "$root/tests/cases/simd/aarch64-start.s" > "$out/tagged-base.s"
for entry in values pages descriptor rsa bad_free bad_realloc; do
    [[ $(grep -cx '    bl simd_checks' "$out/tagged-base.s") == 1 ]] ||
        { echo 'prepare.sh: the start file must call simd_checks once' >&2; exit 1; }
    sed "s/^    bl simd_checks\$/    bl tagged_$entry/" "$out/tagged-base.s" > "$out/$entry-start.s"
done
rm -f "$out/tagged-base.s"
echo 'tagged pointer fixture: real RSA helpers + A64 tagged allocator generated'
