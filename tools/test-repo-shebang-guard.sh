#!/usr/bin/env bash
# Every tracked shell script under tools/ and tests/ (*.sh), and every file tracked as executable, starts with `#!`
# on its first line. Lines that slipped above a shebang left a script with none (test-emutls, test-runtime-checks:
# run by `bash script` it still ran, as the commands before the setup it meant to follow). A sourced library has
# one too, for the editors and checkers that read it.
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
found=""
while IFS= read -r -d '' entry; do
    mode=${entry%% *}
    path=${entry#*$'\t'}
    checked=false
    case $path in tools/*.sh | tests/*.sh) checked=true ;; esac
    [[ $mode == 100755 ]] && checked=true
    [[ $checked == true && -f $path ]] || continue
    [[ $(head -c 2 -- "$path") == '#!' ]] || found+="$mode $path"$'\n'
done < <(git ls-files -s -z)
if [[ -n $found ]]; then
    printf 'shebang guard: these scripts do not start with #! on their first line:\n%s' "$found" >&2
    exit 1
fi
printf 'shebang guard: every tracked script and executable starts with #!\n'
