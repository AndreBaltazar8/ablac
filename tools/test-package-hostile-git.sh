#!/usr/bin/env bash
# A git dependency is attacker-controlled bytes (#1139 area 2, round 2, item 2). Each case is a repository made with git plumbing and fetched by `package update`:
#   what the build reads must be the blobs the lock's digest covers (.gitattributes eol, ident, filter, user autocrlf must not change them);
#   a tree that is too big, too many files, too deep, has a submodule, a name with a control character or one Windows reads as another file, a linked abla.toml, or is malformed (duplicate or unsorted entries, a
#   .gitmodules link) is refused before anything is checked out, naming the dependency, and leaves no cache entry and no lock.
# Sizes are small: the limits are lowered with ABLA_PACKAGE_CHECKOUT_LIMIT_BYTES and ABLA_PACKAGE_GIT_MAX_BYTES, and ulimit -f makes a checkout that still happens fail.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$project_root/build"
t=$(mktemp -d "$project_root/build/package-hostile-git.XXXXXX")
trap 'rm -rf -- "$t"' EXIT
export ABLA_SYSROOT=$project_root GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=$t/gitconfig
printf '[core]\n\tautocrlf = true\n' > "$GIT_CONFIG_GLOBAL"   # a user whose own settings would rewrite a checkout
failures=0
fail() { printf 'package hostile git: %s\n' "$1" >&2; [ -n "${2:-}" ] && sed 's/^/    /' "$2" >&2; failures=$((failures + 1)); }
g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid "$@"; }
n=0
# newrepo: a fresh repository in $repo with a manifest and lib.ab; blobs are left in $manifest, $lib
newrepo() {
    n=$((n + 1)); repo=$t/repo$n; app=$t/app$n; cache=$t/cache$n
    mkdir -p "$repo" "$app"
    git -C "$repo" init --quiet --initial-branch=main
    manifest=$(printf 'name = "dep"\nversion = "0.1.0"\nentry = "lib.ab"\n' | g hash-object -w --stdin)
    lib=$(printf 'fun f(): int = 1\n// $Id$\n' | g hash-object -w --stdin)
}
# commit TREE: points main at a commit of TREE and writes the app that depends on it
commit() {
    local commit; commit=$(g commit-tree "$1" -m case)
    g update-ref refs/heads/main "$commit"
    printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n\n[dependencies]\ndep = { git = "%s", branch = "main" }\n' "$repo" > "$app/abla.toml"
    printf 'fun main: int = 0\n' > "$app/main.ab"
}
update() { # update LOG: runs package update on $app with its own cache; sets $status
    status=0
    ABLA_PACKAGE_CACHE=$cache "$compiler" package update --project "$app" > "$1" 2>&1 || status=$?
}
refused() { # refused WHAT CODE: the update failed with CODE, left no lock and no cache entry
    update "$t/log$n"
    [ "$status" != 0 ] || fail "$1: the fetch accepted it" "$t/log$n"
    grep -q "$2" "$t/log$n" || fail "$1: no $2 in the diagnostic" "$t/log$n"
    [ ! -f "$app/abla.lock" ] || fail "$1: a lock was written"
    if [ -d "$cache" ] && [ -n "$(find "$cache" -type d -name source -print -quit)" ]; then fail "$1: a cache entry was left"; fi
}
hex2bin() { perl -e 'print pack("H*", $ARGV[0])' "$1"; }
cached() { find "$cache" -type d -name source -print -quit; }
blobs_tree() { # blobs_tree "mode type sha\tname"...: a tree with those entries (a name may hold \n and \xHH)
    local entry
    for entry in "$@"; do printf '%s\t%b\0' "${entry%%\\t*}" "${entry#*\\t}"; done | g mktree -z
}

# 1. .gitattributes: eol, ident and a filter name must not change what is read. A user with core.autocrlf = true is the second source of the same rewrite.
newrepo
attr=$(printf '* text eol=crlf ident filter=nope\n' | g hash-object -w --stdin)
commit "$(blobs_tree "100644 blob $attr\t.gitattributes" "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab")"
update "$t/log$n"
if [ "$status" != 0 ]; then fail "attributes: the fetch failed" "$t/log$n"; else
    source=$(cached)
    if cmp -s "$source/lib.ab" <(g cat-file blob "$lib"); then :; else fail "attributes: lib.ab as checked out is not the blob the digest covers (eol, ident or autocrlf rewrote it)"; fi
    if cmp -s "$source/abla.toml" <(g cat-file blob "$manifest"); then :; else fail "attributes: abla.toml as checked out is not the blob"; fi
fi

# 1b. working-tree-encoding: UTF-8 in the tree, UTF-16 on disk, is the strongest rewrite.
newrepo
attr=$(printf '*.ab working-tree-encoding=UTF-16LE\n' | g hash-object -w --stdin)
commit "$(blobs_tree "100644 blob $attr\t.gitattributes" "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab")"
update "$t/log$n"
if [ "$status" = 0 ] && ! cmp -s "$(cached)/lib.ab" <(g cat-file blob "$lib"); then fail "working-tree-encoding: lib.ab was checked out in another encoding"; fi

# 2. A user's autocrlf alone, with no attributes at all.
newrepo
commit "$(blobs_tree "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab")"
update "$t/log$n"
if [ "$status" = 0 ] && ! cmp -s "$(cached)/lib.ab" <(g cat-file blob "$lib"); then fail "autocrlf: the user's core.autocrlf rewrote lib.ab"; fi

# 3. A submodule: the checkout would hold an empty directory where the digest names a commit.
newrepo
commit "$(blobs_tree "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab" "160000 commit 0123456789abcdef0123456789abcdef01234567\tsub")"
refused "a submodule" E_PACKAGE_TREE

# 4. A name with a newline or another control character.
newrepo
commit "$(blobs_tree "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab" "100644 blob $lib\ta\\nb.ab")"
refused "a newline in a name" E_PACKAGE_TREE
newrepo
commit "$(blobs_tree "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab" "100644 blob $lib\tx\\x01y.ab")"
refused "a control character in a name" E_PACKAGE_TREE

# 5. A leading dash is a legitimate name: it must not be an option anywhere.
newrepo
commit "$(blobs_tree "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab" "100644 blob $lib\t-rf.ab" "100644 blob $lib\t--help")"
update "$t/log$n"
[ "$status" = 0 ] && [ -f "$(cached)/-rf.ab" ] || fail "a leading dash: the fetch failed or lost the file" "$t/log$n"

# 6. Too many files, a path that is too long, a tree that is too deep.
newrepo
{ echo "blob"; echo "mark :1"; echo "data 1"; echo "x"; echo "commit refs/heads/main"; echo "committer t <t@example.invalid> 0 +0000"; echo "data 1"; echo "c"
  echo "M 100644 $manifest abla.toml"; echo "M 100644 $lib lib.ab"
  for i in $(seq 1 60000); do echo "M 100644 :1 many/f$i.ab"; done; } | g fast-import --quiet
printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n\n[dependencies]\ndep = { git = "%s", branch = "main" }\n' "$repo" > "$app/abla.toml"; printf 'fun main: int = 0\n' > "$app/main.ab"
refused "60000 files" E_PACKAGE_SIZE
newrepo
deep=$(printf 'd%.0s/' $(seq 1 300))x.ab
{ echo "commit refs/heads/main"; echo "committer t <t@example.invalid> 0 +0000"; echo "data 1"; echo "c"
  echo "M 100644 $manifest abla.toml"; echo "M 100644 $lib lib.ab"; echo "M 100644 $lib ${deep}"; } | g fast-import --quiet
printf 'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n\n[dependencies]\ndep = { git = "%s", branch = "main" }\n' "$repo" > "$app/abla.toml"; printf 'fun main: int = 0\n' > "$app/main.ab"
refused "a tree 300 levels deep" E_PACKAGE_SIZE

# 7. A malformed tree: a duplicate entry, a symbolic .gitmodules (git's own fsck refuses both; the fetch must ask it to).
newrepo
dup=$({ printf '100644 abla.toml\0'; hex2bin "$manifest"; printf '100644 lib.ab\0'; hex2bin "$lib"; printf '100644 lib.ab\0'; hex2bin "$lib"; } | g hash-object -t tree -w --literally --stdin)
commit "$dup"
refused "a duplicate tree entry" E_PACKAGE_FETCH
newrepo
target=$(printf '/etc/passwd' | g hash-object -w --stdin)
commit "$(blobs_tree "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab" "120000 blob $target\t.gitmodules")"
refused "a symbolic .gitmodules" E_PACKAGE_FETCH

# 8. A blob that is small on the wire and over the checkout limit (here 3 MiB of zeros against a limit lowered to 1 MiB by ABLA_PACKAGE_CHECKOUT_LIMIT_BYTES, so the test stays
#    small): refused from the tree's sizes, never written (ulimit -f stops a write of more than 2 MiB, so a checkout would fail with another diagnostic).
newrepo
big=$(head -c 3145728 /dev/zero | g hash-object -w --stdin)
commit "$(blobs_tree "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab" "100644 blob $big\tbig.bin")"
( export ABLA_PACKAGE_CHECKOUT_LIMIT_BYTES=1048576; ulimit -f 2048; refused "a 3 MiB blob over a 1 MiB limit" E_PACKAGE_SIZE )

# 8b. What the fetch receives is capped too: 3 MiB that do not compress, against a limit of 1 MiB (ABLA_PACKAGE_GIT_MAX_BYTES), stops git on the write of the pack.
newrepo
noise=$(head -c 3145728 /dev/urandom | g hash-object -w --stdin)
commit "$(blobs_tree "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab" "100644 blob $noise\tnoise.bin")"
( export ABLA_PACKAGE_GIT_MAX_BYTES=1048576; refused "a 3 MiB pack over a 1 MiB limit" E_PACKAGE_SIZE )

# 8c. Names that are not the same file on Windows (a vendored copy of the package could not be checked out there): a backslash, a colon,
#     a device name with or without an extension, a name ending in a dot or a space, a character Windows refuses; in a subdirectory too.
for name in 'a\\b.ab' 'a:b.ab' 'CON' 'aux.ab' 'Com1.txt' 'lpt9' 'x.ab.' 'x.ab ' 'a?b' 'a*b' 'a|b' 'a<b' 'a>b' 'a"b'; do
    newrepo
    sub=$(blobs_tree "100644 blob $lib\t$name")
    commit "$(blobs_tree "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab" "040000 tree $sub\tsrc")"
    refused "the name '$name'" E_PACKAGE_TREE
done
# ...while names that only look like them are files like any other.
newrepo
commit "$(blobs_tree "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab" "100644 blob $lib\tconsole.ab" "100644 blob $lib\tcom10" "100644 blob $lib\tnull.ab" "100644 blob $lib\t.hidden")"
update "$t/log$n"
[ "$status" = 0 ] && [ -f "$(cached)/console.ab" ] || fail "names near Windows device names: the fetch failed" "$t/log$n"

# 8d. The manifest is the package's own file, never a symbolic link (to another package's manifest, or out of the tree).
newrepo
link=$(printf 'meta/real.toml' | g hash-object -w --stdin)
meta=$(blobs_tree "100644 blob $manifest\treal.toml")
commit "$(blobs_tree "120000 blob $link\tabla.toml" "100644 blob $lib\tlib.ab" "040000 tree $meta\tmeta")"
refused "a symbolic link as abla.toml" E_PACKAGE_TREE

# 9. The lock's digest is the repository's own tree.
newrepo
tree=$(blobs_tree "100644 blob $manifest\tabla.toml" "100644 blob $lib\tlib.ab")
commit "$tree"
update "$t/log$n"
if [ "$status" != 0 ]; then fail "the plain repository did not fetch" "$t/log$n"; else
    grep -q "digest = \"$tree\"" "$app/abla.lock" || fail "the lock's digest is not the tree $tree" "$app/abla.lock"
fi

[ "$failures" = 0 ] || { printf 'package hostile git: %d failure(s)\n' "$failures" >&2; exit 1; }
echo "package hostile git: attributes and autocrlf leave the blobs as locked; a submodule, control-character names, Windows-only names, a linked manifest, too many files, too deep, malformed trees, a blob over the limit and a pack over the limit are refused before checkout"
