#!/usr/bin/env bash
# List tracked legacy files that contain the interpreter or invoke it.
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# Split the name so the inventory does not count this scanner itself.
interpreter='py'"thon"
pattern="(^|[^[:alnum:]_])${interpreter}(3([.][0-9]+)?)?([^[:alnum:]_]|$)"
suffix=p"y"
# Also retain scripts that execute a tracked helper directly by filename.
file_pattern="(^|[[:space:]\"'(/])[^[:space:]\"']*[.]${suffix}([[:space:]\"');|&]|$)"
tracked=$(mktemp "${TMPDIR:-/tmp}/abla-lang-tracked.XXXXXXXX")
trap 'rm -f "$tracked"' EXIT
if ! git ls-files --stage -z >"$tracked"; then
    echo 'language inventory: cannot read the Git index' >&2
    exit 1
fi
while IFS= read -r -d '' record; do
    metadata=${record%%$'\t'*}
    path=${record#*$'\t'}
    mode=${metadata%% *}
    if [[ $path == *$'\n'* ]]; then
        echo 'language inventory: a tracked path contains a newline' >&2
        exit 1
    fi
    [[ -f $path ]] || continue
    case $path in
        *.p"y") printf '%s\n' "$path"; continue ;;
    esac
    first=
    IFS= read -r first <"$path" || true
    if [[ $first == '#!'* ]] && [[ $first =~ $pattern ]]; then
        printf '%s\n' "$path"
        continue
    fi
    case $path in
        *.sh|*.bash|*.zsh|*.mjs|*.js|*.pl|*.rb|*.nix|*.yml|*.yaml|Makefile) script=1 ;;
        *) script=0 ;;
    esac
    [[ $first == '#!'* ]] && script=1
    [[ $mode == 100755 ]] && script=1
    if [[ $script == 1 ]] && grep -Ev '^[[:space:]]*#' -- "$path" |
        grep -E "$pattern|$file_pattern" >/dev/null; then
        printf '%s\n' "$path"
    fi
done <"$tracked"
