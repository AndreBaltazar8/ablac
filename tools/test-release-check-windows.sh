#!/usr/bin/env bash
# tools/release-check.sh and the Windows toolchain (tools/package-windows-toolchain.sh): abla-toolchain-x86_64-windows.zip is an
# optional extra (neither expected nor an extra in `assets`), judged by `windows` when present: PASS for a package built by the packager
# from an x86-64 console PE that carries the version's string; FAIL for a zip with no bin/ablac.exe, with no import lists, with an entry
# outside the top directory, with an ablac.exe that is not a PE, that imports a C runtime, or that lacks the version string. Fake
# artifacts and no network; the executables are linked by lld-link (skipped with a message without lld-link, zip or unzip).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for tool in lld-link zip unzip; do
    command -v "$tool" > /dev/null || { echo "release-check windows: skipped ($tool is not installed)"; exit 0; }
done
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { echo "release-check windows: $1" >&2; exit 1; }
cd "$root"
"$compiler" build tools/pe-info/main.ab -o "$work/pe-info" --fast --no-cache > "$work/pe-info.log" 2>&1 || { cat "$work/pe-info.log" >&2; fail "pe-info did not build"; }
"$compiler" build tools/windows/implib.ab -o "$work/implib" --fast --no-cache > "$work/implib.log" 2>&1 || { cat "$work/implib.log" >&2; fail "implib did not build"; }
"$work/implib" "$work/kernel32.lib" kernel32.dll x86_64 runtime/windows/imports/kernel32.txt
printf 'puts\n' > "$work/msvcrt.txt"
"$work/implib" "$work/msvcrt.lib" msvcrt.dll x86_64 "$work/msvcrt.txt"
"$compiler" build tests/cases/windows/exit7.ab --target-triple x86_64-pc-windows-msvc --object-format coff -o "$work/exit7.obj" > "$work/compile.log" 2>&1 || { cat "$work/compile.log" >&2; fail "exit7.ab did not compile"; }
link() { local image=$1; shift; lld-link /nologo /subsystem:console /entry:abla_start /nodefaultlib /machine:x64 /brepro /fixed /highentropyva:no "/out:$image" "$@" "$work/exit7.obj" "$work/kernel32.lib" 2> "$work/link.log" || { cat "$work/link.log" >&2; fail "lld-link failed"; }; }
link "$work/good.exe"
link "$work/crt.exe" /include:puts "$work/msvcrt.lib"
printf 'ablac 9.9.9\0' >> "$work/good.exe"
printf 'ablac 9.9.9\0' >> "$work/crt.exe"
export ABLA_PE_INFO=$work/pe-info

mkdir "$work/base"
printf '#!/bin/sh\necho "ablac 9.9.9"\n' > "$work/base/ablac-x86_64-linux"
chmod +x "$work/base/ablac-x86_64-linux"
cp "$work/base/ablac-x86_64-linux" "$work/stage2"
printf 'toolchain' > "$work/base/abla-toolchain-x86_64-linux.tar.gz"
(cd "$work/base" && for name in ablac-x86_64-linux abla-toolchain-x86_64-linux.tar.gz; do sha256sum "$name" > "$name.sha256"; done; ls | sort) > "$work/expected"
run() { # artifacts-dir out-dir -> the output lines
    "$root/tools/release-check.sh" v9.9.9 1 "$work/stage2" --artifacts "$1" --assets-from "$work/expected" --out "$2" --source-ref 0000000000000000000000000000000000000000 2>&1 || true
}
line() { grep -E "^(PASS|FAIL|SKIP) +$1 " <<< "$2" || true; }
fresh() { rm -rf "$work/artifacts"; cp -R "$work/base" "$work/artifacts"; }
add_zip() { # zip file -> in the artifacts, with its checksum
    cp "$1" "$work/artifacts/abla-toolchain-x86_64-windows.zip"
    (cd "$work/artifacts" && sha256sum abla-toolchain-x86_64-windows.zip > abla-toolchain-x86_64-windows.zip.sha256)
}
judge() { # label expected-prefix needle
    local output
    output=$(run "$work/artifacts" "$work/out-$1")
    [[ $(line assets "$output") == PASS* ]] || fail "$1: assets: $(line assets "$output")"
    [[ $(line sha256 "$output") == PASS* ]] || fail "$1: sha256: $(line sha256 "$output")"
    [[ $(line windows "$output") == $2* ]] || fail "$1: expected $2, got: $(line windows "$output")"
    [[ -z ${3:-} ]] || grep -q -- "$3" <<< "$(line windows "$output")" || fail "$1: the line does not say '$3': $(line windows "$output")"
}

fresh
output=$(run "$work/artifacts" "$work/out-none")
[[ -z $(line windows "$output") ]] || fail "a windows line without a windows asset"

SOURCE_DATE_EPOCH=315532800 tools/package-windows-toolchain.sh "$work/good.exe" "$root" "$work/good.zip" > "$work/package.log" 2>&1 || { cat "$work/package.log" >&2; fail "the package was not built"; }
fresh; add_zip "$work/good.zip"
judge good PASS

# Zips the packager would refuse: made by hand from the good one.
unpack() { rm -rf "$work/tree"; mkdir "$work/tree"; unzip -q "$work/good.zip" -d "$work/tree"; }
repack() { (cd "$work/tree" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | zip -q -X "$work/$1.zip" -@); fresh; add_zip "$work/$1.zip"; }
top=abla-toolchain-x86_64-windows
unpack; rm "$work/tree/$top/bin/ablac.exe"; repack noexe; judge noexe FAIL "bin/ablac.exe"
unpack; rm "$work/tree/$top/share/abla/runtime/windows/imports/kernel32.txt"; repack noimports; judge noimports FAIL "kernel32.txt"
unpack; echo x > "$work/tree/stray.txt"; repack stray; judge stray FAIL "outside"
unpack; printf 'MZ not a PE\0ablac 9.9.9' > "$work/tree/$top/bin/ablac.exe"; repack notpe; judge notpe FAIL "ablac.exe"
unpack; cp "$work/crt.exe" "$work/tree/$top/bin/ablac.exe"; repack crt; judge crt FAIL "C runtime"
unpack; cp "$work/good.exe" "$work/tree/$top/bin/ablac.exe"; printf '' > /dev/null
head -c "$(( $(stat -c %s "$work/good.exe") - 12 ))" "$work/good.exe" > "$work/tree/$top/bin/ablac.exe"; repack noversion; judge noversion FAIL "ablac 9.9.9"
echo "release-check windows: the windows check passes the packaged toolchain and fails a missing compiler, missing import lists, a stray entry, a non-PE compiler, a C runtime import and a missing version string"
