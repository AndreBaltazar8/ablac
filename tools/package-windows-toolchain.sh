#!/usr/bin/env bash
# The Windows toolchain package, abla-toolchain-x86_64-windows.zip, laid out like the Linux and macOS ones (share/abla beside bin) so
# that setup-abla and the release checks treat the three alike. It is assembled on Linux from the linked ablac.exe (the
# release's Windows job links it: tools/windows/build-static-compiler.ps1) so the archive is the same bytes every time:
#
#   abla-toolchain-x86_64-windows/bin/ablac.exe              the compiler: lld in its own process, the static C runtime inside it
#   abla-toolchain-x86_64-windows/bin/llvm-objcopy.exe       the tool --backtrace runs, beside the compiler
#   abla-toolchain-x86_64-windows/share/abla/{runtime,stdlib} the sysroot (runtime/windows/imports/*.txt become the import libraries)
#   abla-toolchain-x86_64-windows/share/licenses/            abla.txt and NOTICE-windows.txt
#
# There is no launcher: ablac.exe finds the sysroot beside its own image (src/module_paths.ab, bootstrapWindowsToolchainRoot), and its
# PE header reserves the stack the Unix launchers raise with ulimit. The compiler is checked before anything is packed (tools/pe-info):
# a PE32+ x86-64 console image that imports no C runtime DLL under any name (the runtime is linked in).
#
#   tools/package-windows-toolchain.sh <ablac.exe> <llvm-objcopy.exe> <abla-root> <output.zip>
#
# bin/llvm-objcopy.exe (the Windows LLVM SDK's) is carried beside ablac.exe: `ablac --backtrace` runs it, and CreateProcess searches the
# compiler's own directory first, so it is found with an empty PATH. It is checked like the compiler.
#
# ABLA_PE_INFO names a built tools/pe-info/main.ab; without it ABLA_HOST_COMPILER (a Linux ablac) builds it. SOURCE_DATE_EPOCH
# (default 315532800, the earliest zip date) stamps every entry. Needs zip. Prints the archive's size and sha256.
set -euo pipefail
export TZ=UTC   # the zip format stores local times
if [[ $# -ne 4 ]]; then
    printf 'usage: %s <ablac.exe> <llvm-objcopy.exe> <abla-root> <output.zip>\n' "$0" >&2
    exit 2
fi
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
compiler_binary=$(realpath "$1")
objcopy_binary=$(realpath "$2")
abla_root=$(realpath "$3")
output=$(realpath -m "$4")
fail() { printf 'package-windows-toolchain: %s\n' "$1" >&2; exit 1; }

[[ -f $compiler_binary ]] || fail "missing compiler executable: $compiler_binary"
[[ -f $objcopy_binary ]] || fail "missing llvm-objcopy executable: $objcopy_binary"
for directory in "$abla_root/runtime" "$abla_root/stdlib"; do
    [[ -d $directory ]] || fail "missing Abla sysroot directory: $directory"
done
[[ -f $abla_root/LICENSE ]] || fail "missing $abla_root/LICENSE"
[[ -d $abla_root/runtime/windows/imports ]] || fail "the runtime has no windows/imports lists: the compiler could not make its import libraries"
command -v zip > /dev/null || fail "zip is not installed"

working=$(mktemp -d)
trap 'rm -rf -- "$working"' EXIT

pe_info=${ABLA_PE_INFO:-}
if [[ -z $pe_info ]]; then
    [[ -n ${ABLA_HOST_COMPILER:-} ]] || fail "set ABLA_PE_INFO (a built tools/pe-info) or ABLA_HOST_COMPILER (a Linux ablac to build it)"
    pe_info=$working/pe-info
    ABLA_SYSROOT=$abla_root "$ABLA_HOST_COMPILER" build "$here/pe-info/main.ab" -o "$pe_info" --fast --no-cache > "$working/pe-info.log" 2>&1 ||
        { cat "$working/pe-info.log" >&2; fail "tools/pe-info/main.ab did not build"; }
fi
report=$("$pe_info" "$compiler_binary" --no-crt) || fail "$compiler_binary is not a PE image without a C runtime import"
grep -qx 'machine x86_64' <<< "$report" || fail "$compiler_binary is not an x86-64 image"
grep -qx 'subsystem console' <<< "$report" || fail "$compiler_binary is not a console image"
objcopy_report=$("$pe_info" "$objcopy_binary" --no-crt) || fail "$objcopy_binary is not a PE image without a C runtime import"
grep -qx 'machine x86_64' <<< "$objcopy_report" || fail "$objcopy_binary is not an x86-64 image"

name=abla-toolchain-x86_64-windows
bundle=$working/$name
mkdir -p "$bundle/bin" "$bundle/share/abla" "$bundle/share/licenses"
cp "$compiler_binary" "$bundle/bin/ablac.exe"
cp "$objcopy_binary" "$bundle/bin/llvm-objcopy.exe"
cp -R "$abla_root/runtime" "$abla_root/stdlib" "$bundle/share/abla/"
cp "$abla_root/LICENSE" "$bundle/share/licenses/abla.txt"
cat > "$bundle/share/licenses/NOTICE-windows.txt" <<'NOTICE'
bin/ablac.exe is one statically linked executable. Besides Abla's own code (abla.txt) it contains:
  LLVM and lld          Apache License 2.0 with LLVM Exceptions (https://llvm.org/LICENSE.txt)
  The C and C++ runtime the compiler's C++ parts need, linked statically (/MT): Microsoft's Visual C++ runtime libraries,
                        redistributable under the terms of the Microsoft Visual Studio license it was built with
Programs the compiler builds import only Windows system DLLs (kernel32 and the like): none of them links a C runtime.
NOTICE

# Modes do not depend on the packaging user's umask or the source tree's modes.
find "$bundle" -type d -exec chmod 0755 {} +
find "$bundle" -type f -exec chmod 0644 {} +
epoch=${SOURCE_DATE_EPOCH:-315532800}
find "$bundle" -exec touch -h -d "@$epoch" {} +
list=$working/files
(cd "$working" && find "$name" | LC_ALL=C sort) > "$list"
mkdir -p "$(dirname "$output")"
rm -f "$output"
(cd "$working" && zip -q -X -D -9 "$output" -@ < "$list")
printf 'package-windows-toolchain: %s: %d bytes, sha256 %s\n' "$(basename "$output")" "$(stat -c %s "$output")" "$(sha256sum "$output" | cut -d' ' -f1)"
