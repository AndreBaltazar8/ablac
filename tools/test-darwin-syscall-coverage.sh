#!/usr/bin/env bash
# Every Linux system call number the stdlib and the compiler pass to the generic translator (ablaLinuxSyscall and
# linuxSyscall0..6 with a literal number) has a case in macOS's translation (stdlib/abla/runtime/platform/darwin/entry.ab,
# __ablaRuntimeDarwinSyscall), or its call site is named, with the reason, in tools/darwin-syscalls-untranslated.tsv: an
# untranslated call answers ENOSYS (-38) on macOS and nothing else says so. mprotect 10 was such a call from v0.2.62 to
# v0.2.68, and every macOS program that froze a value died with SIGBUS. A line whose call site is gone, or whose number is
# translated now, fails too. The control drops mprotect from the translated numbers and must be refused.
# Not read: the Windows, WebAssembly and WASI runtimes (their own translations) and src/static_libc (the Linux static
# compiler's C library, which src/ct_native.ab loads only off macOS).
# Usage: tools/test-darwin-syscall-coverage.sh
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/darwin-syscall-coverage
mkdir -p "$out"
darwin=stdlib/abla/runtime/platform/darwin/entry.ab
listed=tools/darwin-syscalls-untranslated.tsv

# The numbers the dispatcher translates: every `number == N` in its body.
awk '/^trusted fun __ablaRuntimeDarwinSyscall\(/ { inside = 1 } inside && /^}/ { exit } inside { print }' "$darwin" |
    grep -oE 'number == [0-9]+' | awk '{ print $3 }' | sort -u > "$out/translated.txt"
[[ -s $out/translated.txt ]] || { echo "darwin syscall coverage: no case found in $darwin" >&2; exit 1; }

# Each call site's number and file, a call spread over lines read as one.
: > "$out/calls.txt"
while IFS= read -r file; do
    case $file in
        stdlib/abla/runtime/platform/windows/* | stdlib/abla/runtime/platform/wasm.ab | stdlib/abla/runtime/platform/wasi.ab | \
            src/static_libc/*) continue ;;
    esac
    { tr '\n' ' ' < "$file" | grep -oE '(ablaLinuxSyscall|linuxSyscall[0-6])\([[:space:]]*[0-9]+' || true; } |
        awk -v file="$file" '{ sub(/.*\(/, ""); gsub(/[[:space:]]/, ""); print $0 "\t" file }' >> "$out/calls.txt"
done < <(git ls-files 'stdlib/*.ab' 'src/*.ab')
sort -u "$out/calls.txt" -o "$out/calls.txt"
[[ -s $out/calls.txt ]] || { echo "darwin syscall coverage: no call site found" >&2; exit 1; }
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
            print "untranslated on macOS (ENOSYS), not in tools/darwin-syscalls-untranslated.tsv: " $1 " in " $2
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
    echo "darwin syscall coverage: translate the call in $darwin, or name the call site and why in $listed" >&2
    exit 1
fi
grep -vx 10 "$out/translated.txt" > "$out/control.txt"
if check "$out/control.txt" > "$out/control.log"; then
    echo "darwin syscall coverage: the control (mprotect 10 untranslated) was not refused" >&2
    exit 1
fi
grep 'untranslated on macOS (ENOSYS), not in tools/darwin-syscalls-untranslated.tsv: 10 in ' "$out/control.log" > /dev/null || {
    echo "darwin syscall coverage: the control was refused for something else:" >&2
    cat "$out/control.log" >&2
    exit 1
}
echo "darwin syscall coverage: $(wc -l < "$out/calls.txt") call sites, $(wc -l < "$out/translated.txt") translated numbers, $(wc -l < "$out/listed.txt") named untranslated; the control is refused"
