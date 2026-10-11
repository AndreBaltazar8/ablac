#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf 'usage: %s <ablac> <abla-root> <output.tar.gz>\n' "$0" >&2
    exit 2
fi

compiler_binary=$(realpath "$1")
abla_root=$(realpath "$2")
output=$(realpath -m "$3")

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
for tool in clang ld.lld llc lld llvm-ar llvm-config llvm-extract llvm-split \
    opt patchelf wasm-ld wasm-opt; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'missing packaging tool: %s\n' "$tool" >&2
        exit 1
    }
done

working=$(mktemp -d)
trap 'rm -rf -- "$working"' EXIT
bundle="$working/abla-toolchain-x86_64-linux"
mkdir -p "$bundle/bin" "$bundle/lib" "$bundle/libexec" \
    "$bundle/share/abla" "$bundle/share/licenses"

cp "$compiler_binary" "$bundle/libexec/ablac.bin"
for tool in clang ld.lld llc lld llvm-ar llvm-config llvm-extract llvm-split \
    opt wasm-ld wasm-opt; do
    cp "$(realpath "$(command -v "$tool")")" "$bundle/libexec/$tool"
    ln -s "../libexec/$tool" "$bundle/bin/$tool"
done
cp -R "$abla_root/runtime" "$abla_root/stdlib" "$bundle/share/abla/"
cp "$abla_root/LICENSE" "$bundle/share/licenses/abla.txt"
chmod 0755 "$bundle/libexec/ablac.bin" "$bundle"/libexec/*

cat > "$bundle/bin/ablac" <<'SH'
#!/bin/sh
set -eu
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
export ABLA_SYSROOT="$root/share/abla"
export PATH="$root/bin:$PATH"
exec "$root/libexec/ablac.bin" "$@"
SH
chmod 0755 "$bundle/bin/ablac"

copy_dependencies() {
    local executable=$1
    local dependency
    local destination
    while IFS= read -r dependency; do
        case $(basename "$dependency") in
            ld-linux-*.so.*|libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*)
                continue
                ;;
        esac
        destination="$bundle/lib/$(basename "$dependency")"
        if [[ ! -e $destination ]]; then
            cp -L "$dependency" "$destination"
            chmod u+w "$destination"
        fi
    done < <(ldd "$executable" | awk '/=> \/[^ ]+/ { print $3 }')
}

for executable in "$bundle/libexec/ablac.bin" "$bundle"/libexec/*; do
    copy_dependencies "$executable"
done

for executable in "$bundle/libexec/ablac.bin" "$bundle"/libexec/*; do
    if patchelf --print-interpreter "$executable" >/dev/null 2>&1; then
        # $ORIGIN is interpreted by the dynamic loader, not this shell.
        patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$executable"
        # shellcheck disable=SC2016
        patchelf --set-rpath '$ORIGIN/../lib' "$executable"
    fi
done
for library in "$bundle"/lib/*.so*; do
    # shellcheck disable=SC2016
    patchelf --set-rpath '$ORIGIN' "$library"
done

resource_dir=$(clang -print-resource-dir)
if [[ -d $resource_dir ]]; then
    resource_version=$(basename "$resource_dir")
    mkdir -p "$bundle/lib/clang"
    cp -R "$resource_dir" "$bundle/lib/clang/$resource_version"
fi

for package in binaryen clang-23 libbsd0 libedit2 libffi8 libgcc-s1 \
    libicu70 libllvm23 liblzma5 libmd0 libssl3 libstdc++6 libtinfo6 \
    libxml2 libzstd1 zlib1g; do
    copyright="/usr/share/doc/$package/copyright"
    if [[ -r $copyright ]]; then
        cp "$copyright" "$bundle/share/licenses/$package.txt"
    fi
done

mkdir -p "$(dirname "$output")"
tar -C "$working" -czf "$output" abla-toolchain-x86_64-linux
(
    cd "$(dirname "$output")"
    sha256sum "$(basename "$output")" > "$(basename "$output").sha256"
)
