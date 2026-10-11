#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
    printf 'usage: %s <architecture> <ablac> <abla-root> <output.tar.gz>\n' "$0" >&2
    exit 2
fi

architecture=$1
case "$architecture" in
    arm64|x86_64) ;;
    *) printf 'unsupported macOS architecture: %s\n' "$architecture" >&2; exit 2 ;;
esac

compiler_binary=$(cd -- "$(dirname -- "$2")" && pwd)/$(basename -- "$2")
abla_root=$(cd -- "$3" && pwd)
output_directory=$(cd -- "$(dirname -- "$4")" && pwd)
output="$output_directory/$(basename -- "$4")"

[[ -x $compiler_binary ]] || {
    printf 'missing compiler executable: %s\n' "$compiler_binary" >&2
    exit 1
}
for directory in "$abla_root/runtime" "$abla_root/stdlib"; do
    [[ -d $directory ]] || {
        printf 'missing Abla sysroot directory: %s\n' "$directory" >&2
        exit 1
    }
done

working=$(mktemp -d)
trap 'rm -rf -- "$working"' EXIT
bundle="$working/abla-toolchain-$architecture-macos"
mkdir -p "$bundle/bin" "$bundle/libexec" "$bundle/share/abla" \
    "$bundle/share/licenses"

cp "$compiler_binary" "$bundle/libexec/ablac.bin"
cp -R "$abla_root/runtime" "$abla_root/stdlib" "$bundle/share/abla/"
cp "$abla_root/LICENSE" "$bundle/share/licenses/abla.txt"
chmod 0755 "$bundle/libexec/ablac.bin"

# The compiler holds libLLVM in process and reads opt's bitcode back, so it
# runs only with the tools of the LLVM it links. The launcher records that
# LLVM's Homebrew formulas (llvm@N and lld@N, under the prefix the binary loads
# libLLVM from) and puts them first on PATH, whatever the caller's PATH holds.
libllvm=$(otool -L "$bundle/libexec/ablac.bin" |
    sed -n 's/^[[:space:]]*\([^ ]*libLLVM[^ ]*\) (.*current version \([0-9][0-9]*\)\..*/\1 \2/p' |
    sed -n 1p)
llvm_major=${libllvm##* }
libllvm=${libllvm% *}
if [[ -z $libllvm || $libllvm != */opt/llvm* ]]; then
    printf '%s does not load a Homebrew libLLVM\n' "$compiler_binary" >&2
    exit 1
fi
homebrew_prefix=${libllvm%%/opt/llvm*}
llvm_prefix=$homebrew_prefix/opt/llvm@$llvm_major
lld_prefix=$homebrew_prefix/opt/lld@$llvm_major
# Homebrew names the library by the unversioned keg (opt/llvm), which moves to
# the next LLVM on an upgrade; load it through llvm@N, which keeps this one.
if [[ $libllvm != "$llvm_prefix/"* && -e $llvm_prefix/lib/libLLVM.dylib ]]; then
    install_name_tool -change "$libllvm" "$llvm_prefix/lib/libLLVM.dylib" \
        "$bundle/libexec/ablac.bin" 2>/dev/null
    codesign --force --sign - "$bundle/libexec/ablac.bin"
    libllvm=$llvm_prefix/lib/libLLVM.dylib
fi

{
    printf '%s\n' '#!/bin/sh' 'set -eu'
    printf "llvm_major=%s\n" "$llvm_major"
    printf "libllvm='%s'\n" "$libllvm"
    printf "llvm=\${ABLA_LLVM:-'%s'}\n" "$llvm_prefix"
    printf "lld=\${ABLA_LLD:-'%s'}\n" "$lld_prefix"
    cat <<'SH'
# Resolve links to the launcher (a bin directory elsewhere may link to it), so
# the root and its sysroot are the toolchain's own.
launcher=$0
while [ -L "$launcher" ]; do
    target=$(readlink "$launcher")
    case $target in
        /*) launcher=$target ;;
        *) launcher=$(dirname -- "$launcher")/$target ;;
    esac
done
root=$(CDPATH= cd -- "$(dirname -- "$launcher")/.." && pwd)
# Deeply nested programs (large JSON literals, typed source graphs) need more
# than the default stack: take up to 128 MiB, within the hard limit, as the
# repository launcher does. ABLA_MAX_STACK_KB chooses another size.
stack_kb=${ABLA_MAX_STACK_KB:-131072}
hard_stack_kb=$(ulimit -H -s)
case $hard_stack_kb in
    ''|*[!0-9]*) ;;
    *) if [ "$hard_stack_kb" -lt "$stack_kb" ]; then stack_kb=$hard_stack_kb; fi ;;
esac
ulimit -S -s "$stack_kb" 2>/dev/null || :
# libexec/ablac.bin links LLVM $llvm_major and reads opt's bitcode back in
# process, so it runs with that LLVM's opt, llc, clang and linkers, never with
# the ones on the caller's PATH. ABLA_LLVM and ABLA_LLD name other prefixes of
# the same LLVM.
missing() {
    printf 'ablac: %s is missing; this toolchain needs LLVM %s: brew install llvm@%s lld@%s\n' \
        "$1" "$llvm_major" "$llvm_major" "$llvm_major" >&2
    exit 127
}
[ -e "$libllvm" ] || missing "$libllvm"
[ -x "$llvm/bin/opt" ] || missing "$llvm/bin/opt"
[ -x "$lld/bin/wasm-ld" ] || missing "$lld/bin/wasm-ld"
if [ -n "${ABLA_LLVM:-}" ]; then
    case $("$llvm/bin/llvm-config" --version 2>/dev/null || :) in
        "$llvm_major".*) ;;
        *) printf 'ablac: ABLA_LLVM=%s is not LLVM %s\n' "$llvm" "$llvm_major" >&2
           exit 127 ;;
    esac
fi
export ABLA_SYSROOT="$root/share/abla"
export PATH="$llvm/bin:$lld/bin:$root/bin:$PATH"
exec "$root/libexec/ablac.bin" "$@"
SH
} > "$bundle/bin/ablac"
chmod 0755 "$bundle/bin/ablac"

tar -C "$working" -czf "$output" "abla-toolchain-$architecture-macos"
(
    cd "$output_directory"
    shasum -a 256 "$(basename -- "$output")" > "$(basename -- "$output").sha256"
)
