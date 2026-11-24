#!/usr/bin/env bash
# What a content provider (`importSource(...)` with a compile-time resolver returning `resolvedImport(revision, entry, files)`) may return is attacker-shaped
# data (#1139 area 2, round 2, item 3). Each case is a resolver with a hostile file list, run by `package update`:
#   a path that git, a case-folding file system or Windows reads as `.git`, a control character, a backslash or a colon, two paths that differ only in case, a
#   file that is also a directory, an over-long component, too many files, and a total over the limit are refused (E_IMPORT_PROVIDER_RESOLUTION) before a
#   lock or a cache entry exists; a total exactly at the limit is accepted; a `.gitattributes` in the result (eol, ident, working-tree-encoding) must not change
#   the digest away from the bytes that were written. ABLA_PACKAGE_CHECKOUT_LIMIT_BYTES lowers the 128 MiB limit so the cases stay small.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$project_root/build"
t=$(mktemp -d "$project_root/build/package-content-paths.XXXXXX")
trap 'rm -rf -- "$t"' EXIT
export ABLA_SYSROOT=$project_root GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$t/gitconfig
: > "$GIT_CONFIG_GLOBAL"
failures=0
fail() { printf 'package content paths: %s\n' "$1" >&2; [ -n "${2:-}" ] && sed 's/^/    /' "$2" >&2; failures=$((failures + 1)); }
n=0
MANIFEST='importFile("abla.toml", "name = \"gen\"\nentry = \"src/gen.ab\"\n"), importFile("src/gen.ab", "fun genAnswer: int = 42\n")'
# provide FILES [PRELUDE]: an application whose provider resolves to FILES (Abla expressions, comma separated) and the entry src/gen.ab
provide() { # provide FILES [BEFORE [AFTER]]: BEFORE runs before the list is built (it can define values), AFTER after (it can append to `files`)
    n=$((n + 1)); app=$t/app$n; cache=$t/cache$n
    mkdir -p "$app/src"
    printf 'name = "app"\nentry = "src/main.ab"\n' > "$app/abla.toml"
    {
        printf 'compile fun resolveGen(): ResolvedImport {\n%s\n    var files: array<ImportFile> = [%s]\n%s\n    resolvedImport("r1", "src/gen.ab", files)\n}\n' "${2:-}" "$1" "${3:-}"
        printf 'compile fun gen(): ImportSource = importSource("gen", "test:gen", "v1", resolveGen)\n'
    } > "$app/src/provider.ab"
    printf 'import "provider.ab"\nimport gen()\nfun main: int = genAnswer()\n' > "$app/src/main.ab"
}
update() { status=0; ABLA_PACKAGE_CACHE=$cache "$compiler" package update --project "$app" > "$t/log$n" 2>&1 || status=$?; }
refused() { # refused WHAT FILES [BEFORE [AFTER]]
    provide "$2" "${3:-}" "${4:-}"; update
    [ "$status" != 0 ] || fail "$1: accepted" "$t/log$n"
    grep -q 'E_IMPORT_PROVIDER_RESOLUTION' "$t/log$n" || fail "$1: no E_IMPORT_PROVIDER_RESOLUTION" "$t/log$n"
    [ ! -f "$app/abla.lock" ] || fail "$1: a lock was written"
    if [ -d "$cache" ] && [ -n "$(find "$cache" -type d -name source -print -quit)" ]; then fail "$1: a cache entry was left"; fi
}
accepted() { provide "$2" "${3:-}" "${4:-}"; update; [ "$status" = 0 ] && [ -f "$app/abla.lock" ] || fail "$1: refused" "$t/log$n"; }
f() { printf 'importFile("%s", "x")' "$1"; }

# Names git, a case-folding file system or Windows takes for the repository directory itself: a `.git/config` there is code git runs.
for bad in '.GIT/config' '.Git/hooks/pre-commit' '.git /config' '.git./config' 'sub/.GIT/x' 'GIT~1/config'; do
    refused "the path '$bad'" "$MANIFEST, $(f "$bad")"
done
refused "two paths that differ only in case" "$MANIFEST, $(f src/Util.ab), $(f src/util.ab)"
refused "a duplicate path" "$MANIFEST, $(f src/u.ab), $(f src/u.ab)"
refused "a file that is also a directory" "$MANIFEST, $(f src/u), $(f src/u/v.ab)"
refused "a newline in a path" "$MANIFEST, importFile(\"src/a\\nb.ab\", \"x\")"
refused "a control character in a path" "$MANIFEST, importFile(\"src/a\\x01b.ab\", \"x\")"
refused "a backslash in a path" "$MANIFEST, importFile(\"src\\\\a.ab\", \"x\")"
refused "a colon in a path" "$MANIFEST, importFile(\"src/a.ab:stream\", \"x\")"
refused "an empty component" "$MANIFEST, $(f 'src//a.ab')"
refused "a dot component" "$MANIFEST, $(f 'src/./a.ab')"
refused "a parent component" "$MANIFEST, $(f 'src/../a.ab')"
refused "an absolute path" "$MANIFEST, $(f '/etc/x')"
refused "a trailing slash" "$MANIFEST, $(f 'src/a/')"
refused "a 300-byte component" "$MANIFEST, importFile(\"src/\" + long, \"x\")" '    var long = "a"
    while (long.size < 300) long = long + long'

# .gitattributes inside the result: the bytes written are the bytes the digest covers.
provide "$MANIFEST, importFile(\".gitattributes\", \"* text eol=crlf ident\\n\"), importFile(\"src/crlf.txt\", \"a\\r\\nb\\r\\n\"), importFile(\"src/id.txt\", \"\\\$Id\\\$\\n\")"
update
if [ "$status" != 0 ]; then fail "attributes: refused" "$t/log$n"; else
    source=$(find "$cache" -type d -name source -print -quit)
    [ "$(od -An -c "$source/src/crlf.txt" | tr -d ' \n')" = '\r\n\r\n' ] || [ "$(wc -c < "$source/src/crlf.txt")" = 6 ] || fail "attributes: src/crlf.txt was rewritten on disk"
    scratch=$t/verify; git init -q "$scratch"; mkdir -p "$scratch/.git/info"; printf '* -text -eol -ident -filter -working-tree-encoding\n' > "$scratch/.git/info/attributes"
    cp -R "$source/." "$scratch/" 2>/dev/null || true; rm -rf "$scratch/.git/hooks"
    git -C "$scratch" -c core.autocrlf=false add -A >/dev/null 2>&1
    expected=$(git -C "$scratch" write-tree)
    grep -q "digest = \"$expected\"" "$app/abla.lock" || fail "attributes: the lock's digest is not the tree of the bytes written ($expected)" "$app/abla.lock"
fi

padding() { printf '    var pad = "x"\n    while (pad.size < %s) pad = pad + pad\n    pad = pad.slice(0, %s)' "$1" "$1"; }
# The limit: a total of paths and contents exactly at it is accepted, one more byte is not (the limit is lowered to 64 KiB for the test).
limit=65536
export ABLA_PACKAGE_CHECKOUT_LIMIT_BYTES=$limit
fixed=$(( 9 + $(printf 'name = "gen"\nentry = "src/gen.ab"\n' | wc -c) + 10 + $(printf 'fun genAnswer: int = 42\n' | wc -c) ))
accepted "a total exactly at the limit" "$MANIFEST, importFile(\"pad\", pad)" "$(padding $((limit - fixed - 3)))"
refused "a total one byte over the limit" "$MANIFEST, importFile(\"pad\", pad)" "$(padding $((limit - fixed - 2)))"
unset ABLA_PACKAGE_CHECKOUT_LIMIT_BYTES
# Many files: more than 50,000 (empty ones, so the size limit is not what refuses them).
refused "50,001 files" "$MANIFEST" "" '    var i = 0
    while (i < 50001) {
        files.append(importFile("f/$i", ""))
        i = i + 1
    }'

[ "$failures" = 0 ] || { printf 'package content paths: %d failure(s)\n' "$failures" >&2; exit 1; }
echo "package content paths: hostile resolver results are refused (git-like names, case, control characters, files that are directories, over-long components, too many files, a total over the limit) and .gitattributes does not change what is locked"
