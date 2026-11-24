#!/usr/bin/env bash
# Compile-time code's paths are held inside its project by where they lead, not by their spelling (src/eval.ab,
# bootstrapContainBuildCallPath and bootstrapBuildCallRealPath): a symbolic link inside the project that points out of it is
# outside. Before, the check was lexical, and `#path("escape/x").writeText(...)` with `escape -> /elsewhere` wrote
# /elsewhere/x. Each case is a project with filesystem.read and filesystem.write and one `#` file operation:
#   - a write through a linked directory in the middle of the path, into a linked parent, and onto a link that is the last
#     name: refused (E_BUILD_PATH_OUTSIDE), nothing written outside;
#   - a read through a linked directory: refused;
#   - `..` after a link: the path is read as written ("link/../x" is "x", in the project), never where the link led;
#   - a link that stays inside the project: followed, the write lands where it points.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/compile-path-symlinks"
rm -rf "$out"
mkdir -p "$out"
fail() { echo "compile-path-symlinks: $1" >&2; exit 1; }

# case <name> <expression>: a project at $out/<name>/project beside $out/<name>/outside (holding secret.txt and deep/),
# whose main.ab evaluates `expression` at compile time; the build's status in $status, its output in $out/<name>.log.
case_project() {
    local name=$1 expression=$2
    local project="$out/$name/project"
    mkdir -p "$project/src" "$project/data" "$out/$name/outside/deep"
    printf 'secret' > "$out/$name/outside/secret.txt"
    printf 'kept' > "$out/$name/outside/target.txt"
    cat > "$project/abla.toml" <<'EOF'
name = "symlink-case"
version = "0.1.0"
entry = "src/main.ab"
compileCapabilities = ["filesystem.read", "filesystem.write"]
EOF
    cat > "$project/src/main.ab" <<EOF
import "abla/io"
import "abla/fs"
import "abla/compiler"
#compilerGrant("filesystem.read")
#compilerGrant("filesystem.write")
val result = #$expression
fun main { println("result \$result") }
EOF
}
build() {
    status=0
    "$compiler" build --project "$out/$1/project" --fast --no-cache -o "$out/$1.program" > "$out/$1.log" 2>&1 || status=$?
}
refused() {
    build "$1"
    [[ $status != 0 ]] && grep -q 'E_BUILD_PATH_OUTSIDE' "$out/$1.log" ||
        fail "$1: not refused (status $status): $(grep -m2 '^error' "$out/$1.log")"
}

case_project middle 'path("../escape/written.txt").writeText("x")'
ln -s "$out/middle/outside" "$out/middle/project/escape"
refused middle
[[ ! -e $out/middle/outside/written.txt ]] || fail "middle: a write through a linked directory reached outside"

case_project parent 'path("../linked/new.txt").writeText("x")'
ln -s "$out/parent/outside/deep" "$out/parent/project/linked"
refused parent
[[ ! -e $out/parent/outside/deep/new.txt ]] || fail "parent: a new file in a linked parent was written outside"

case_project last 'path("../out.txt").writeText("changed")'
ln -s "$out/last/outside/target.txt" "$out/last/project/out.txt"
refused last
[[ $(< "$out/last/outside/target.txt") == kept ]] || fail "last: a write onto a link changed its target outside"

case_project read 'path("../escape/secret.txt").readText()'
ln -s "$out/read/outside" "$out/read/project/escape"
refused read

case_project dots 'path("../link/../dots.txt").writeText("here")'
ln -s "$out/dots/outside/deep" "$out/dots/project/link"
build dots
[[ $status == 0 ]] || fail "dots: refused (status $status): $(grep -m2 '^error' "$out/dots.log")"
[[ -e $out/dots/project/dots.txt && ! -e $out/dots/outside/dots.txt ]] || fail "dots: link/.. was read where the link led"

case_project inside 'path("../inner/ok.txt").writeText("inside")'
ln -s "$out/inside/project/data" "$out/inside/project/inner"
build inside
[[ $status == 0 ]] || fail "inside: a link within the project was refused (status $status): $(grep -m2 '^error' "$out/inside.log")"
[[ $(< "$out/inside/project/data/ok.txt") == inside ]] || fail "inside: the write did not land where the link points"

# An operation on the link itself (a removal, a move, a link test) takes the link, not where it leads, as unlink, rename and
# lstat do: removing a link removed its target before (the parity sample's module/filesystem, check 20), and a link that
# points out of the project is still the project's own entry to remove.
case_project removelink 'path("../link.txt").remove()'
printf 'kept' > "$out/removelink/project/data/kept.txt"
ln -s data/kept.txt "$out/removelink/project/link.txt"
build removelink
[[ $status == 0 ]] || fail "removelink: refused (status $status): $(grep -m2 '^error' "$out/removelink.log")"
[[ ! -L $out/removelink/project/link.txt && -e $out/removelink/project/data/kept.txt ]] ||
    fail "removelink: removing a link did not remove the link alone (its target removed, or the link kept)"
case_project removeout 'path("../out.txt").remove()'
ln -s "$out/removeout/outside/target.txt" "$out/removeout/project/out.txt"
build removeout
[[ $status == 0 && ! -L $out/removeout/project/out.txt && -e $out/removeout/outside/target.txt ]] ||
    fail "removeout: a link out of the project was not removed alone (status $status)"
case_project movelink 'path("../link.txt").moveTo(path("../moved.txt"))'
printf 'kept' > "$out/movelink/project/data/kept.txt"
ln -s data/kept.txt "$out/movelink/project/link.txt"
build movelink
[[ $status == 0 && -L $out/movelink/project/moved.txt && -e $out/movelink/project/data/kept.txt ]] ||
    fail "movelink: moving a link did not move the link (status $status)"
case_project islink 'path("../link.txt").isSymbolicLink()'
printf 'kept' > "$out/islink/project/data/kept.txt"
ln -s data/kept.txt "$out/islink/project/link.txt"
build islink
[[ $status == 0 && $("$out/islink.program") == 'result true' ]] || fail "islink: isSymbolicLink did not see the link (status $status)"

echo "compile-path-symlinks: links out of the project are outside it (through a directory, a parent, the last name, a read); link/.. is read as written; links within it are followed; a removal, a move and a link test take the link itself"
