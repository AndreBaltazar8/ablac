#!/usr/bin/env bash
# A bare program name never runs a file of the working directory (linuxExecutablePath, abla/sys/linux/process; Linux and macOS):
# the compiler starts its tools by bare name (ld.lld, clang, llvm-config, codesign, ...) in the tree it builds, so a tree that
# carries one of them must not have it run. tests/cases/exec-path/main.ab starts "abla-exec-path-tool" from a directory that
# holds an executable of that name (it leaves a mark and exits 7), under PATHs that do not name a directory with it, or name
# it only by an empty entry ("::", a leading or trailing ':'), "." or a relative directory: the file never runs, before the fix
# it ran in each of them. An absolute PATH directory with the tool still finds it (it exits 5). Run in the suite and in the
# macOS job (tools/test-darwin-syscalls.sh's step).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=$root/build/exec-path
rm -rf "$out"
mkdir -p "$out/tree/relative" "$out/tools"
fail() { echo "exec path: $1" >&2; exit 1; }
"$compiler" build tests/cases/exec-path/main.ab -o "$out/start" --fast --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; fail 'main.ab did not build'; }
planted() { # planted <file>: a tool that leaves a mark beside itself and exits 7
    printf '#!/bin/sh\n: > "%s.ran"\nexit 7\n' "$1" > "$1"
    chmod +x "$1"
}
planted "$out/tree/abla-exec-path-tool"
planted "$out/tree/relative/abla-exec-path-tool"
printf '#!/bin/sh\nexit 5\n' > "$out/tools/abla-exec-path-tool"
chmod +x "$out/tools/abla-exec-path-tool"
cd "$out/tree"
for search in /usr/bin:/bin /usr/bin::/bin :/usr/bin:/bin /usr/bin:/bin: .:/usr/bin:/bin relative:/usr/bin:/bin; do
    rm -f ./*.ran relative/*.ran
    printed=$(PATH=$search "$out/start")
    [[ ! -e abla-exec-path-tool.ran && ! -e relative/abla-exec-path-tool.ran ]] ||
        fail "PATH=$search ran the working directory's abla-exec-path-tool ($printed)"
    [[ $printed != 'status 7' ]] || fail "PATH=$search: $printed"
done
printed=$(PATH="$out/tools:/usr/bin:/bin" "$out/start")
[[ $printed == 'status 5' ]] || fail "an absolute PATH directory with the tool: $printed (status 5 expected)"
echo "exec path: a bare name runs no file of the working directory under six PATHs (none, empty entries, '.', a relative one), and is found in an absolute one"
