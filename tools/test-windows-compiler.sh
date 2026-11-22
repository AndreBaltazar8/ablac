#!/usr/bin/env bash
# The compiler itself on Windows, before its LLVM is there (step 2 of docs/design/windows-target.md; the LLVM and lld archives
# for windows-msvc are #1137): src/orc_main.ab cross-built for x86_64-windows-hosted names nothing outside the Windows runtime's
# imports but LLVM-C functions; linked against a stub LLVM (each function returns 0) and installed as the package lays it out
# (bin/ablac.exe beside share/abla), it runs under Wine from another directory with no ABLA_SYSROOT:
#   - `--version` prints its version;
#   - `fmt` rewrites a file;
#   - `build` finds its standard library beside its own image (/proc/self/exe) and takes a program through parsing, analysis
#     and IR to its first LLVM call, which the stub fails: an LLVM error, not a missing toolchain or a refused system call.
# Without Wine (or lld-link, llvm-mc, llvm-ar) the undefined-symbol check still runs and the rest is skipped with a message.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/windows-compiler
rm -rf "$out"
mkdir -p "$out/libs" "$out/tools"
fail() { echo "windows-compiler: $1" >&2; exit 1; }
command -v llvm-nm > /dev/null || { echo "windows-compiler: skipped (llvm-nm is not installed)"; exit 0; }
"$compiler" build src/orc_main.ab --target x86_64-windows-hosted -o "$out/ablac.exe" > "$out/build.log" 2>&1 || true
[[ -s $out/ablac.exe.o ]] || { tail -20 "$out/build.log" >&2; fail "src/orc_main.ab gave no object for Windows"; }

# What the object needs beyond LLVM is what the runtime imports (runtime/windows/imports), nothing of a C library.
llvm-nm -u "$out/ablac.exe.o" | awk '{ print $NF }' | sort -u > "$out/undefined.txt"
cat runtime/windows/imports/*.txt | grep -vE '^[[:space:]]*(#|$)' | sort -u > "$out/imported.txt"
{ grep -vE '^(LLVM|__ImageBase$)' "$out/undefined.txt" || true; } | comm -23 - "$out/imported.txt" > "$out/unexpected.txt"
[[ ! -s $out/unexpected.txt ]] || fail "the compiler names what Windows does not give it: $(tr '\n' ' ' < "$out/unexpected.txt")"
for tool in lld-link llvm-mc llvm-ar; do
    command -v "$tool" > /dev/null ||
        { echo "windows-compiler: the compiler names only LLVM beyond the runtime's imports; the stub link and Wine runs are skipped ($tool is not installed)"; exit 0; }
done

# Import libraries from the runtime's lists (llvm-ar run as llvm-dlltool) and a stub for every LLVM-C function.
ln -sf "$(command -v llvm-ar)" "$out/tools/llvm-dlltool"
for list in runtime/windows/imports/*.txt; do
    stem=$(basename "$list" .txt)
    { echo "LIBRARY $stem.dll"; echo EXPORTS; grep -vE '^[[:space:]]*(#|$)' "$list"; } > "$out/libs/$stem.def"
    "$out/tools/llvm-dlltool" -m i386:x86-64 -d "$out/libs/$stem.def" -l "$out/libs/$stem.lib"
done
{ echo .text; grep '^LLVM' "$out/undefined.txt" | while read -r symbol; do printf '.globl %s\n%s:\n    xorl %%eax, %%eax\n    ret\n' "$symbol" "$symbol"; done; } > "$out/stub.s"
llvm-mc -triple x86_64-pc-windows-msvc -filetype=obj "$out/stub.s" -o "$out/stub.o"
mkdir -p "$out/package/bin" "$out/package/share/abla" "$out/work"
lld-link /nologo /subsystem:console /entry:abla_windows_start /nodefaultlib /machine:x64 /brepro /stack:134217728 \
    "/out:$out/package/bin/ablac.exe" "$out/ablac.exe.o" "$out/stub.o" "$out"/libs/*.lib > "$out/link.log" 2>&1 ||
    { cat "$out/link.log" >&2; fail "ablac.exe did not link against the stub LLVM"; }
ln -s "$root/stdlib" "$out/package/share/abla/stdlib"
ln -s "$root/runtime" "$out/package/share/abla/runtime"
printf 'import "abla/io"\nfun main {   println("hello")   }\n' > "$out/work/hello.ab"

# run <name> <arguments...>: ablac.exe in work/, no ABLA_SYSROOT; output in $out/<name>.out, status in $status.
run() {
    local name=$1
    shift
    status=0
    (cd "$out/work" && env -u ABLA_SYSROOT -u ABLA_STDLIB "$root/tools/windows/wine-run.sh" ../package/bin/ablac.exe "$@") \
        > "$out/$name.out" 2>&1 || status=$?
    [[ $status != 125 ]] || { echo "windows-compiler: the compiler names only LLVM beyond the runtime's imports and links against a stub LLVM; the Wine runs are skipped (Wine is not installed)"; exit 0; }
    ! grep -q 'unsupported Linux system call' "$out/$name.out" || fail "$name: $(grep 'unsupported Linux system call' "$out/$name.out")"
    return 0
}
run version --version
[[ $status == 0 ]] && grep -q '^ablac [0-9]' "$out/version.out" || fail "--version ($status): $(head -3 "$out/version.out")"
cp "$out/work/hello.ab" "$out/hello.before"
run fmt fmt hello.ab
[[ $status == 0 ]] || fail "fmt exited $status: $(head -3 "$out/fmt.out")"
! cmp -s "$out/hello.before" "$out/work/hello.ab" || fail "fmt left hello.ab as it was"
run build build hello.ab -o hello.exe
grep -q 'E_TOOLCHAIN_ROOT\|no standard library' "$out/build.out" && fail "build found no toolchain: $(head -3 "$out/build.out")"
grep -q 'E_LLVM' "$out/build.out" || fail "build did not reach LLVM ($status): $(head -5 "$out/build.out")"
echo "windows-compiler: ablac.exe (a stub LLVM) runs --version, fmt and build up to its first LLVM call under Wine, its toolchain found beside it"
