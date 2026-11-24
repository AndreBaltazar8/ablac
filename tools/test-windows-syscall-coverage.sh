#!/usr/bin/env bash
# Every Linux system call number the stdlib and the compiler pass to the generic translator (ablaLinuxSyscall and
# linuxSyscall0..6 with a literal number) is translated by the hosted Windows runtime (the list __ablaRuntimeWindowsTranslated() in
# stdlib/abla/runtime/platform/windows/entry.ab, which tools/test-windows-syscalls.sh holds to its `number == N` cases), or its call site
# is named, with the reason, in tools/windows-syscalls-untranslated.tsv: any other number ends a Windows program with status 70 and
# "unsupported Linux system call N" (copy_file_range 326 was one in v0.2.68 and v0.2.69: a default `ablac build` died publishing an object, and
# nothing said the call was missing). A line whose call site is gone, or whose number is translated now, fails too. The control drops
# copy_file_range (326) from the translated numbers and must be refused.
# Not read: the macOS, WebAssembly and WASI runtimes, the Windows runtime itself (its own calls: 4001 and up) and src/static_libc.
# Usage: tools/test-windows-syscall-coverage.sh
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/windows-syscall-coverage
mkdir -p "$out"
windows=stdlib/abla/runtime/platform/windows/entry.ab
listed=tools/windows-syscalls-untranslated.tsv

# The numbers the runtime translates: the list its dispatcher publishes.
grep -o '__ablaRuntimeWindowsTranslated(): string = "[0-9 ]*"' "$windows" | grep -oE '[0-9]+' | sort -u > "$out/translated.txt"
[[ -s $out/translated.txt ]] || { echo "windows syscall coverage: no list found in $windows" >&2; exit 1; }

# Each call site's number and file, a call spread over lines read as one.
: > "$out/calls.txt"
while IFS= read -r file; do
    case $file in
        stdlib/abla/runtime/platform/darwin/* | stdlib/abla/runtime/platform/windows/* | stdlib/abla/runtime/platform/wasm.ab | stdlib/abla/runtime/platform/wasi.ab | \
            src/static_libc/*) continue ;;
    esac
    { tr '\n' ' ' < "$file" | grep -oE '(ablaLinuxSyscall|linuxSyscall[0-6])\([[:space:]]*[0-9]+' || true; } |
        awk -v file="$file" '{ sub(/.*\(/, ""); gsub(/[[:space:]]/, ""); print $0 "\t" file }' >> "$out/calls.txt"
done < <(git ls-files 'stdlib/*.ab' 'src/*.ab')
sort -u "$out/calls.txt" -o "$out/calls.txt"
[[ -s $out/calls.txt ]] || { echo "windows syscall coverage: no call site found" >&2; exit 1; }
grep -v '^#' "$listed" | awk -F '\t' 'NF >= 3 { print $1 "\t" $2 }' | sort -u > "$out/listed.txt"

# check <translated numbers file>: prints each problem, and returns 1 when there is one.
check() {
    awk -F '\t' -v translated="$1" -v listed="$out/listed.txt" '
        BEGIN {
            while ((getline line < translated) > 0) done[line] = 1
            while ((getline line < listed) > 0) named[line] = 1
        }
        { used[$1 "\t" $2] = 1 }
        !($1 in done) && !(($1 "\t" $2) in named) {
            print "untranslated on Windows (status 70), not in tools/windows-syscalls-untranslated.tsv: " $1 " in " $2
            bad = 1
        }
        END {
            for (entry in named) {
                split(entry, part, "\t")
                if (!(entry in used)) { print "listed but no such call site: " part[1] " in " part[2]; bad = 1 }
                else if (part[1] in done) { print "listed but translated now: " part[1] " in " part[2]; bad = 1 }
            }
            exit bad
        }' "$out/calls.txt"
}

if ! check "$out/translated.txt"; then
    echo "windows syscall coverage: translate the call in $windows, or name the call site and why in $listed" >&2
    exit 1
fi
grep -vx 326 "$out/translated.txt" > "$out/control.txt"
if check "$out/control.txt" > "$out/control.log"; then
    echo "windows syscall coverage: the control (copy_file_range 326 untranslated) was not refused" >&2
    exit 1
fi
grep 'untranslated on Windows (status 70), not in tools/windows-syscalls-untranslated.tsv: 326 in ' "$out/control.log" > /dev/null || {
    echo "windows syscall coverage: the control was refused for something else:" >&2
    cat "$out/control.log" >&2
    exit 1
}
echo "windows syscall coverage: $(wc -l < "$out/calls.txt") call sites, $(wc -l < "$out/translated.txt") translated numbers, $(wc -l < "$out/listed.txt") named untranslated; the control is refused"
