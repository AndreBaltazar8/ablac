#!/usr/bin/env bash
set -euo pipefail

# Materialize the locked abla-testrunner tree into the test-driver vendor path
# so `ablac build --offline` can resolve the github() import without fetching.
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
package_name=abla-testrunner
submodule_path=tools/abla-test-driver/vendor/abla-testrunner
submodule=$project_root/$submodule_path
lock=$project_root/tools/abla-test-driver/abla.lock

sync_lock=0
if [[ ${1:-} == --sync-lock ]]; then
    sync_lock=1
elif [[ $# -gt 0 ]]; then
    printf 'usage: %s [--sync-lock]\n' "$0" >&2
    exit 2
fi

die() {
    printf '%s\n' "prepare-abla-test-driver: $*" >&2
    exit 1
}

lock_package_field() {
    local field=$1
    awk -v pkg="$package_name" -v field="$field" '
        /^\[\[package\]\]/ { current = "" }
        /^name = "/ {
            current = $0
            sub(/^name = "/, "", current)
            sub(/"$/, "", current)
            next
        }
        current == pkg {
            prefix = field " = \""
            if (index($0, prefix) == 1) {
                value = substr($0, length(prefix) + 1)
                sub(/"$/, "", value)
                print value
                exit
            }
        }
    ' "$lock"
}

sync_lock_package() {
    local revision=$1 digest=$2
    local temporary_lock
    temporary_lock=$(mktemp)
    awk -v pkg="$package_name" -v rev="$revision" -v dig="$digest" '
        BEGIN { updated_rev = 0; updated_dig = 0; target = 0 }
        /^\[\[package\]\]/ { target = 0 }
        /^name = "/ {
            current = $0
            sub(/^name = "/, "", current)
            sub(/"$/, "", current)
            target = (current == pkg)
        }
        target && /^revision = "/ {
            print "revision = \"" rev "\""
            updated_rev = 1
            next
        }
        target && /^digest = "/ {
            print "digest = \"" dig "\""
            updated_dig = 1
            next
        }
        { print }
        END { if (!updated_rev || !updated_dig) exit 1 }
    ' "$lock" > "$temporary_lock"
    mv -- "$temporary_lock" "$lock"
}

require_clean_submodule() {
    local line path
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        path=${line#???}
        case $path in
            .abla-revision|.abla-digest) continue ;;
        esac
        die "submodule working tree does not match HEAD: $line"
    done < <(git -C "$submodule" status --porcelain)
}

checkout_locked_tree() {
    local source=$1 revision=$2 digest=$3
    local temporary tree
    temporary=$(mktemp -d "${TMPDIR:-/tmp}/abla-testrunner.XXXXXX")
    git clone --quiet "$source" "$temporary/repo"
    if ! git -C "$temporary/repo" checkout --quiet "$revision"; then
        rm -rf -- "$temporary"
        die "could not checkout locked revision $revision from $source"
    fi
    tree=$(git -C "$temporary/repo" rev-parse 'HEAD^{tree}')
    if [[ $tree != "$digest" ]]; then
        rm -rf -- "$temporary"
        die "locked digest $digest does not match $source at $revision (tree $tree)"
    fi
    rm -rf -- "$temporary/repo/.git"
    rm -rf -- "$submodule"
    mkdir -p -- "$(dirname -- "$submodule")"
    mv -- "$temporary/repo" "$submodule"
    rm -rf -- "$temporary"
}

write_lock_markers() {
    local revision=$1 digest=$2
    # Markers must match Path.writeText: the exact lock bytes, no trailing newline.
    printf '%s' "$revision" > "$submodule/.abla-revision"
    printf '%s' "$digest" > "$submodule/.abla-digest"
}

ignore_lock_markers() {
    local git_dir exclude
    git_dir=$(git -C "$submodule" rev-parse --absolute-git-dir)
    exclude=$git_dir/info/exclude
    mkdir -p -- "$(dirname -- "$exclude")"
    if [[ ! -f $exclude ]] || ! grep -qxF '.abla-revision' "$exclude"; then
        printf '%s\n' '.abla-revision' '.abla-digest' >> "$exclude"
    fi
}

[[ -f $lock ]] || die "missing package lock $lock"
lock_revision=$(lock_package_field revision)
lock_digest=$(lock_package_field digest)
lock_source=$(lock_package_field source)
[[ -n $lock_revision && -n $lock_digest && -n $lock_source ]] ||
    die "lock is missing $package_name source, revision, or digest"

in_git=0
if [[ -e $project_root/.git ]] &&
    git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1
then
    in_git=1
fi

if [[ $in_git -eq 1 ]]; then
    git -C "$project_root" submodule update --init -- "$submodule_path"
    [[ -e $submodule/.git ]] || die "missing submodule $submodule"
    require_clean_submodule
    revision=$(git -C "$submodule" rev-parse HEAD)
    digest=$(git -C "$submodule" rev-parse 'HEAD^{tree}')
    if [[ $sync_lock -eq 1 ]]; then
        sync_lock_package "$revision" "$digest"
        lock_revision=$revision
        lock_digest=$digest
    elif [[ $revision != "$lock_revision" || $digest != "$lock_digest" ]]; then
        die "submodule HEAD $revision (tree $digest) does not match $lock revision $lock_revision digest $lock_digest; checkout the locked commit, or run $0 --sync-lock"
    fi
    write_lock_markers "$lock_revision" "$lock_digest"
    ignore_lock_markers
    exit 0
fi

if [[ $sync_lock -eq 1 ]]; then
    die "cannot --sync-lock without a git checkout of this repository"
fi

checkout_locked_tree "$lock_source" "$lock_revision" "$lock_digest"
write_lock_markers "$lock_revision" "$lock_digest"
