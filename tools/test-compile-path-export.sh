#!/usr/bin/env bash
# #1141: a project's compile-time paths are bounded the same in a git checkout and in a `git archive` export of it, when
# the project names itself in a root abla.toml (`name = ...`). The bound is the nearest abla.toml with a `name`, else
# the repository root (.git), else the working directory (docs/compile-time.md). A site in sub/ (with a
# capability-only sub/abla.toml, as a game's client folder has) reads ../assets/data.txt at compile time and is built
# from sub/:
#   - checkout and export with the named root manifest: both build, both print the data;
#   - without it: the checkout builds (the .git root), the export is bounded to the working directory, sub/, and
#     gets E_BUILD_PATH_OUTSIDE. That is the documented fallback; a tree that is exported names its root.
# Mutation check: bootstrapBuildCallPackageManifest answering false makes the named export fail like the unnamed one.
set -euo pipefail
compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
fail() { echo "compile-path-export: $1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }
# Outside the repository, so that no .git or abla.toml above the fixture takes part.
work=$(mktemp -d "${TMPDIR:-/tmp}/abla-path-export.XXXXXX")
trap 'rm -rf "${work:?}"' EXIT

make_project() { # $1 = directory, $2 = "named" or "unnamed"
    mkdir -p "$1/sub" "$1/assets"
    printf 'from the assets folder\n' > "$1/assets/data.txt"
    printf 'compileCapabilities = ["filesystem.read"]\n' > "$1/sub/abla.toml"
    cat > "$1/sub/main.ab" <<'EOF'
import "abla/io"
import "abla/fs"
import "abla/compiler"

#compilerGrant("filesystem.read")

val data = #path("../assets/data.txt").readText()

fun main {
    print(data)
}
EOF
    if [[ $2 == named ]]; then printf 'name = "export-fixture"\n' > "$1/abla.toml"; fi
    git -C "$1" init -q
    git -C "$1" add -A
    git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
    mkdir -p "$1-export"
    git -C "$1" archive HEAD | tar -x -C "$1-export"
    [[ ! -e $1-export/.git ]] || fail "the export of $1 has a .git"
}

build() { # $1 = project directory; builds sub/main.ab from sub/, prints the log path
    local log=$work/$(basename "$1").log
    (cd "$1/sub" && "$compiler" build main.ab -o "$work/$(basename "$1").bin" --no-cache) > "$log" 2>&1
}

expect_data() { # $1 = project directory
    build "$1" || fail "$(basename "$1") didn't build from sub/" "$work/$(basename "$1").log"
    [[ $("$work/$(basename "$1").bin") == "from the assets folder" ]] ||
        fail "$(basename "$1") printed something else" "$work/$(basename "$1").log"
}

make_project "$work/named" named
make_project "$work/unnamed" unnamed

expect_data "$work/named"
expect_data "$work/named-export"
expect_data "$work/unnamed"
if build "$work/unnamed-export"; then
    fail "the unnamed export built: its bound should be the working directory, sub/" "$work/unnamed-export.log"
fi
grep -q 'E_BUILD_PATH_OUTSIDE' "$work/unnamed-export.log" ||
    fail "the unnamed export failed, but not with E_BUILD_PATH_OUTSIDE" "$work/unnamed-export.log"
grep -qF "project $work/unnamed-export/sub (" "$work/unnamed-export.log" ||
    fail "the unnamed export's bound isn't its working directory" "$work/unnamed-export.log"
echo "compile-path-export: checkout and export bounded alike with a named root manifest; without it the export is bounded to sub/"
