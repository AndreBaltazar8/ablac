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

cat > "$bundle/bin/ablac" <<'SH'
#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export ABLA_SYSROOT="$root/share/abla"
export PATH="$root/bin:$PATH"
exec "$root/libexec/ablac.bin" "$@"
SH
chmod 0755 "$bundle/bin/ablac"

tar -C "$working" -czf "$output" "abla-toolchain-$architecture-macos"
(
    cd "$output_directory"
    shasum -a 256 "$(basename -- "$output")" > "$(basename -- "$output").sha256"
)
