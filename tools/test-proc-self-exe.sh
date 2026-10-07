#!/usr/bin/env bash
# `/proc/self/exe` reads the running program's image (on Darwin too), so the
# build cache keys on the compiler that built an object.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/proc-self-exe"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/proc-self-exe.ab" \
    -o "$output_directory/program" --no-cache
size=$(wc -c < "$output_directory/program" | tr -d ' ')
output=$("$output_directory/program")
[[ $output == "$size $size" ]] || exit 1

# An install renames a new file over a running program. Reading
# `/proc/self/exe` afterwards gives the original image or nothing, never the
# replacement (the build cache would key one compiler's objects by another).
replaced_source="$project_root/tests/cases/modules/proc-self-exe-replaced.ab"
"$compiler" build "$replaced_source" -o "$output_directory/replaced" \
    --no-cache || exit 1
rm -f -- "$output_directory/replaced-run" || exit 1
cp -- "$output_directory/replaced" "$output_directory/replaced-run" || exit 1
printf 'not the program\n' > "$output_directory/replacement" || exit 1
"$output_directory/replaced-run" "$output_directory/replaced-run" \
    "$output_directory/replacement" || exit 1
echo "proc self exe: the program reads its own $size-byte image, never a replacement"
